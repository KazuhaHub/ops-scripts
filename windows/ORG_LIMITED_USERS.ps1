[CmdletBinding()]
param(
    [switch]$Apply,         # apply policies (skip menu)
    [switch]$Uninstall,     # run CLEAN_ALL
    [switch]$CheckUpdate,   # check upstream version (no admin required)
    [switch]$SelfUpdate,    # download latest, replace, and (in -Unattended) auto-apply
    [switch]$Version,       # print version and exit (no admin required)
    [switch]$Unattended,    # no menu, no Read-Host prompts (used by SYSTEM scheduled task)
    [switch]$NoMenu,        # alias for -Unattended
    [switch]$Help
)

if ($NoMenu) { $Unattended = $true }

# ============================================================
# Constants
# ============================================================
$ScriptVersion       = "1.5.0"
$ScriptName          = "ORG_LIMITED_USERS"
$AutoUpdateTaskName  = "Kazuha Hub Auto Update"
$TrustedUrlPrefix    = "https://raw.githubusercontent.com/"
$DefaultRawUrl       = "https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/$ScriptName.ps1"
$ScriptRawUrl        = if ($env:KH_WIN_UPDATE_URL) { $env:KH_WIN_UPDATE_URL } else { $DefaultRawUrl }

# Idle logoff threshold (minutes) — LIMITED is more permissive than PUBLIC
$IdleLogoffMinutes   = 120
$IdleTaskName        = "Idle ${IdleLogoffMinutes}m Logoff"

# Power policy timeouts (minutes) — LIMITED is more permissive than PUBLIC
$DisplayOffMinutes   = 10
$SleepAfterMinutes   = 180

# Profile cleanup days (set to 0 to skip — LIMITED keeps user profiles)
$ProfileCleanupDays  = 0

# ============================================================
# Logging helpers
# ============================================================
function Write-LogInfo  { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-LogOk    { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-LogWarn  { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-LogErr   { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }
function Die            { param([string]$Msg) Write-LogErr $Msg; exit 1 }

# ============================================================
# Privilege / security checks
# ============================================================
function Test-IsAdmin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-IsAdmin {
    if (-not (Test-IsAdmin)) {
        Die "This action requires Administrator privileges. Re-run from an elevated PowerShell session."
    }
}

function Assert-TrustedUrl {
    if ($ScriptRawUrl -notlike "$TrustedUrlPrefix*") {
        Die "Refusing untrusted update URL '$ScriptRawUrl' — must start with $TrustedUrlPrefix"
    }
}

# Refuse privileged self-update / auto-task registration when the script lives in
# a directory the caller doesn't trust (e.g. /Users/<user>/Downloads/). Otherwise
# a user could swap the file under SYSTEM between scheduled-task firings.
function Assert-ScriptOwnedByPrivilegedPrincipal {
    if (-not $PSCommandPath -or -not (Test-Path $PSCommandPath)) { return }
    try {
        $owner = (Get-Acl -Path $PSCommandPath).Owner
    } catch {
        Write-LogWarn "Could not determine owner of $PSCommandPath — proceeding"
        return
    }
    $trusted = @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM', 'NT SERVICE\TrustedInstaller')
    if ($owner -notin $trusted) {
        Die "Refusing privileged operation: $PSCommandPath is owned by '$owner', not a privileged principal. Move it to a system-owned location (e.g. C:\ProgramData\KazuhaHub\) and re-run."
    }
}

# ============================================================
# Version handling / self-update
# ============================================================
function Get-RemoteVersion {
    try {
        $content = Invoke-RestMethod -Uri $ScriptRawUrl -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
    } catch {
        return $null
    }
    $m = [regex]::Match($content, '^\$ScriptVersion\s*=\s*"([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Test-VersionNewer {
    param([string]$Remote, [string]$Local)
    try { return ([version]$Remote -gt [version]$Local) } catch { return $false }
}

function Invoke-CheckUpdate {
    Assert-TrustedUrl
    Write-LogInfo "Local version: $ScriptVersion"
    Write-LogInfo "Checking $ScriptRawUrl ..."
    $remote = Get-RemoteVersion
    if (-not $remote) {
        Write-LogWarn "Could not fetch remote version (offline or upstream unreachable)"
        return $false
    }
    if ($remote -eq $ScriptVersion) {
        Write-LogOk "You are on the latest version ($ScriptVersion)"
        return $false
    }
    if (-not (Test-VersionNewer $remote $ScriptVersion)) {
        Write-LogOk "Local $ScriptVersion is ahead of upstream $remote (development build)"
        return $false
    }
    Write-LogWarn "Update available: $ScriptVersion -> $remote (run with -SelfUpdate to apply)"
    return $true
}

function Invoke-SelfUpdate {
    param([switch]$AutoApply)

    Assert-IsAdmin
    Assert-TrustedUrl
    Assert-ScriptOwnedByPrivilegedPrincipal

    if (-not $PSCommandPath) {
        Die "Cannot self-update: \$PSCommandPath is empty (script not invoked from a file)."
    }

    Write-LogInfo "Downloading $ScriptRawUrl ..."

    $tmp = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $ScriptRawUrl -OutFile $tmp.FullName -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
    } catch {
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
        Die "Download failed: $($_.Exception.Message)"
    }

    $content = Get-Content -Raw $tmp.FullName
    if (-not $content) { Remove-Item $tmp.FullName -Force; Die "Downloaded file is empty" }

    if ($content -notmatch '(?m)^\s*(\[CmdletBinding|param\s*\(|#)') {
        Remove-Item $tmp.FullName -Force
        Die "Downloaded file does not look like a PowerShell script — refusing to install"
    }

    $tokens = $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        Remove-Item $tmp.FullName -Force
        Die "Downloaded file failed PowerShell parse — refusing to install ($($errors[0].Message))"
    }

    $newVersion = "(unknown)"
    $vm = [regex]::Match($content, '^\$ScriptVersion\s*=\s*"([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($vm.Success) { $newVersion = $vm.Groups[1].Value }

    $ts     = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$PSCommandPath.bak.$ts"
    Copy-Item -Path $PSCommandPath -Destination $backup -Force
    Move-Item -Path $tmp.FullName  -Destination $PSCommandPath -Force

    Write-LogOk "Self-update complete: $ScriptVersion -> $newVersion (backup: $backup)"

    if ($AutoApply) {
        Write-LogInfo "Auto-applying new version (unattended)..."
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Apply', '-Unattended')
        $proc = Start-Process powershell.exe -ArgumentList $psArgs -Wait -PassThru -NoNewWindow
        Write-LogOk "Apply finished with exit code $($proc.ExitCode)"
        exit $proc.ExitCode
    }
}

# ============================================================
# Daily auto-update scheduled task
# ============================================================
function Register-AutoUpdateTask {
    Assert-IsAdmin
    Assert-ScriptOwnedByPrivilegedPrincipal

    if (-not $PSCommandPath) {
        Write-LogWarn "Cannot register auto-update task: \$PSCommandPath is empty"
        return
    }

    try { Unregister-ScheduledTask -TaskName $AutoUpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Unattended -SelfUpdate"

    $trigger = New-ScheduledTaskTrigger -Daily -At "04:00"

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask `
        -TaskName $AutoUpdateTaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Write-LogOk "Auto-update task '$AutoUpdateTaskName' registered (daily 04:00 as SYSTEM, points to $PSCommandPath)"
}

# ============================================================
# Uninstall (delegate to CLEAN_ALL.ps1)
# ============================================================
function Invoke-Uninstall {
    Assert-IsAdmin

    $scriptDir = Split-Path $PSCommandPath -Parent
    $cleanAll  = Join-Path $scriptDir "CLEAN_ALL.ps1"

    if (Test-Path $cleanAll) {
        Write-LogInfo "Running $cleanAll ..."
        & $cleanAll -Apply -Unattended:$Unattended
        return
    }

    $cleanUrl = $ScriptRawUrl -replace '[^/]+\.ps1$', 'CLEAN_ALL.ps1'
    if ($cleanUrl -notlike "$TrustedUrlPrefix*") { Die "Could not derive trusted CLEAN_ALL URL" }

    Write-LogInfo "CLEAN_ALL.ps1 not found locally, downloading from $cleanUrl ..."
    $tmp = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $cleanUrl -OutFile $tmp.FullName -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
    } catch {
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
        Die "Download failed: $($_.Exception.Message)"
    }

    $content = Get-Content -Raw $tmp.FullName
    $tokens = $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) { Remove-Item $tmp.FullName -Force; Die "Downloaded CLEAN_ALL failed parse" }

    & $tmp.FullName -Apply -Unattended:$Unattended
    Remove-Item $tmp.FullName -Force
}

# ============================================================
# Interactive menu
# ============================================================
function Show-Menu {
    Write-Host ""
    Write-Host "  +-----------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("  | Kazuha Hub Windows Policy   {0,-41} |" -f "$ScriptName v$ScriptVersion") -ForegroundColor Cyan
    Write-Host "  +-----------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "What would you like to do?"
    Write-Host "  1) Apply this profile  (default)"
    Write-Host "  2) Uninstall (revert all Kazuha Hub policies via CLEAN_ALL)"
    Write-Host "  3) Check for script updates"
    Write-Host "  4) Self-update now (download latest and re-apply)"
    Write-Host "  5) Quit"
    Write-Host ""

    $choice = Read-Host "Choice [1]"
    if (-not $choice) { $choice = "1" }
    return $choice
}

# ============================================================
# Apply policies (the actual ORG profile)
# ============================================================
function Invoke-ApplyPolicies {
    Assert-IsAdmin

    # ===========================
    # LAPS policy (Windows)
    # ===========================
    $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS"
    New-Item -Path $path -Force | Out-Null

    New-ItemProperty -Path $path -Name "BackupDirectory" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordComplexity" -PropertyType DWord -Value 4 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordLength" -PropertyType DWord -Value 16 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordAgeDays" -PropertyType DWord -Value 30 -Force | Out-Null

    New-ItemProperty -Path $path -Name "PostAuthenticationResetDelay" -PropertyType DWord -Value 8 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PostAuthenticationActions" -PropertyType DWord -Value 3 -Force | Out-Null

    try { Invoke-LapsPolicyProcessing } catch { Write-LogWarn "Invoke-LapsPolicyProcessing not available: $($_.Exception.Message)" }

    # ===========================
    # Windows Hello for Business / PIN (disable)
    # ===========================
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" `
        -Name "Enabled" -PropertyType DWord -Value 0 -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
        -Name "AllowDomainPINLogon" -PropertyType DWord -Value 0 -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" `
        -Name "value" -PropertyType DWord -Value 0 -Force | Out-Null

    # ===========================
    # Lock workstation / Switch User restrictions
    # ===========================
    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Force | Out-Null

    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "DisableLockWorkstation" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "HideFastUserSwitching" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -Name "DisableLockWorkstation" -PropertyType DWord -Value 1 -Force | Out-Null

    # ===========================
    # Require Ctrl+Alt+Delete at sign-in
    # ===========================
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "DisableCAD" -PropertyType DWord -Value 0 -Force | Out-Null

    # ===========================
    # Sign-in name display and ID type
    # ===========================
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "DontDisplayLastUserName" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "DontDisplayUserName" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "DontDisplayUserNameOnLockScreen" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "DontDisplayLockedUserId" -PropertyType DWord -Value 3 -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
        -Name "EnumerateLocalUsers" -PropertyType DWord -Value 0 -Force | Out-Null

    # ===========================
    # Default User hive (HKU\.DEFAULT)
    # ===========================
    & reg.exe add "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f | Out-Null

    # ===========================
    # Legal Notice before Ctrl+Alt+Delete
    # ===========================
    $LegalNoticeTitle = "ATTENTION USERS - 系统访问须知"
    $LegalNoticeText = @"
Please sign in with your Kazuha Hub account and remember to LOG OUT after your session to protect your account. You are responsible for any misuse or unauthorized use of your account. Please make sure to backup your files appropriately by saving onto a portable USB drive or online (i.e. OneDrive). Use of this system is subject to Kazuha Hub Network and Computer Use Policies.

请使用您的 Kazuha Hub 账户登录，并在会话结束后务必注销（LOG OUT）以保护您的账户安全。您将对任何误用或未经授权使用您的账户行为承担全部责任。请确保妥善备份您的文件，可以将其保存到便携式 USB 驱动器或在线存储（例如 OneDrive）。使用本系统即表示您同意遵守 Kazuha Hub 网络与计算机使用政策。

$ScriptName-v$ScriptVersion
"@

    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "legalnoticecaption" -PropertyType String -Value $LegalNoticeTitle -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "legalnoticetext" -PropertyType String -Value $LegalNoticeText -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -Name "LegalNoticeCaption" -PropertyType String -Value $LegalNoticeTitle -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -Name "LegalNoticeText" -PropertyType String -Value $LegalNoticeText -Force | Out-Null

    # ===========================
    # Profile cleanup after N days (PUBLIC only)
    # ===========================
    if ($ProfileCleanupDays -gt 0) {
        $CleanupPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        if (-not (Test-Path $CleanupPolicyPath)) { New-Item -Path $CleanupPolicyPath -Force | Out-Null }
        New-ItemProperty -Path $CleanupPolicyPath `
            -Name "CleanupProfiles" -PropertyType DWord -Value $ProfileCleanupDays -Force | Out-Null
    }

    # ===========================
    # Idle logoff task (every minute, logoff if idle >= threshold)
    # ===========================
    $logoffScriptDir  = "C:\ProgramData\KazuhaHub"
    $logoffScriptPath = Join-Path $logoffScriptDir "IdleLogoffAll.ps1"

    if (-not (Test-Path $logoffScriptDir)) {
        New-Item -Path $logoffScriptDir -ItemType Directory -Force | Out-Null
    }

    @'
param([int]$Minutes = 20)

$ErrorActionPreference = 'Continue'

$output = @(quser 2>$null)
if ($output.Count -lt 2) { return }

$header   = $output[0]
$idCol    = $header.IndexOf('ID')
$stateCol = $header.IndexOf('STATE')
$idleCol  = $header.IndexOf('IDLE TIME')
$logonCol = $header.IndexOf('LOGON TIME')

if ($idCol -lt 0 -or $stateCol -lt 0 -or $idleCol -lt 0 -or $logonCol -lt 0) { return }

$idLen    = $stateCol - $idCol
$stateLen = $idleCol  - $stateCol
$idleLen  = $logonCol - $idleCol

function Get-IdleMinutes {
    param([string]$idle)
    if ($null -eq $idle) { return 0 }
    $idle = $idle.Trim()
    if (-not $idle -or $idle -eq '.' -or $idle -eq 'none' -or $idle -eq '-') { return 0 }
    if ($idle -match '^(\d+)\+(\d{1,2}):(\d{2})$') { return [int]$matches[1]*1440 + [int]$matches[2]*60 + [int]$matches[3] }
    if ($idle -match '^(\d{1,2}):(\d{2})$') { return [int]$matches[1]*60 + [int]$matches[2] }
    if ($idle -match '^\d+$') { return [int]$idle }
    return 0
}

for ($i = 1; $i -lt $output.Count; $i++) {
    $line = $output[$i]
    if (-not $line -or -not $line.Trim()) { continue }
    if ($line.Length -lt ($idleCol + 1)) { continue }

    $sessionId = $line.Substring($idCol, $idLen).Trim()
    $idleStr   = if ($line.Length -ge ($idleCol + $idleLen)) {
        $line.Substring($idleCol, $idleLen).Trim()
    } else {
        $line.Substring($idleCol).Trim()
    }

    if ($sessionId -notmatch '^\d+$') { continue }
    if ([int]$sessionId -le 0) { continue }

    if ((Get-IdleMinutes $idleStr) -ge $Minutes) {
        & logoff.exe $sessionId 2>$null
    }
}
'@ | Set-Content -Path $logoffScriptPath -Encoding UTF8

    foreach ($oldName in @("AutoLogoff-RealIdle", "Idle 2h Logoff", "Idle 20m Logoff", $IdleTaskName)) {
        try { schtasks /Delete /TN "$oldName" /F 2>$null | Out-Null } catch {}
    }

    $logoffCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$logoffScriptPath`" -Minutes $IdleLogoffMinutes"

    schtasks /Create `
        /TN "$IdleTaskName" `
        /SC MINUTE `
        /MO 1 `
        /TR $logoffCmd `
        /F `
        /RU "SYSTEM" | Out-Null

    Write-LogOk "Scheduled task created: $IdleTaskName (logs off sessions idle >= $IdleLogoffMinutes minutes)"

    # ===========================
    # Display power policy (display off / sleep) and lock it
    # ===========================
    $powerPolicyPath       = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings"
    $subVideo              = "7516b95f-f776-4464-8c53-06167f40cc99"
    $displayTimeoutSetting = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"
    $subSleep              = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
    $sleepTimeoutSetting   = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"

    foreach ($p in @(
        "$powerPolicyPath\$subVideo\$displayTimeoutSetting",
        "$powerPolicyPath\$subSleep\$sleepTimeoutSetting"
    )) { New-Item -Path $p -Force | Out-Null }

    New-ItemProperty -Path "$powerPolicyPath\$subVideo\$displayTimeoutSetting" `
        -Name "ACSettingIndex" -PropertyType DWord -Value $DisplayOffMinutes -Force | Out-Null
    New-ItemProperty -Path "$powerPolicyPath\$subVideo\$displayTimeoutSetting" `
        -Name "DCSettingIndex" -PropertyType DWord -Value $DisplayOffMinutes -Force | Out-Null
    New-ItemProperty -Path "$powerPolicyPath\$subSleep\$sleepTimeoutSetting" `
        -Name "ACSettingIndex" -PropertyType DWord -Value $SleepAfterMinutes -Force | Out-Null
    New-ItemProperty -Path "$powerPolicyPath\$subSleep\$sleepTimeoutSetting" `
        -Name "DCSettingIndex" -PropertyType DWord -Value $SleepAfterMinutes -Force | Out-Null

    powercfg /X monitor-timeout-ac $DisplayOffMinutes | Out-Null
    powercfg /X monitor-timeout-dc $DisplayOffMinutes | Out-Null
    powercfg /X standby-timeout-ac $SleepAfterMinutes | Out-Null
    powercfg /X standby-timeout-dc $SleepAfterMinutes | Out-Null

    foreach ($p in @(
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Start",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\Start"
    )) {
        New-Item -Path $p -Force | Out-Null
        New-ItemProperty -Path $p -Name "value" -PropertyType DWord -Value 1 -Force | Out-Null
    }

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" `
        -Name "ShowSleepOption" -PropertyType DWord -Value 0 -Force | Out-Null

    # ===========================
    # Lid close: Sleep + Logoff on resume
    # ===========================
    $subButtons = "4f971e89-eebd-4455-a8de-9e59040e7347"
    $lidAction  = "5ca83367-6e45-459f-a27b-476b1d01c936"

    New-Item -Path "$powerPolicyPath\$subButtons\$lidAction" -Force | Out-Null
    New-ItemProperty -Path "$powerPolicyPath\$subButtons\$lidAction" `
        -Name "ACSettingIndex" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "$powerPolicyPath\$subButtons\$lidAction" `
        -Name "DCSettingIndex" -PropertyType DWord -Value 1 -Force | Out-Null

    powercfg /SETACVALUEINDEX SCHEME_CURRENT $subButtons $lidAction 1 2>$null | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT $subButtons $lidAction 1 2>$null | Out-Null
    powercfg /SETACTIVE SCHEME_CURRENT 2>$null | Out-Null

    $resumeScriptPath = Join-Path $logoffScriptDir "LogoffOnResume.ps1"

    @'
$ErrorActionPreference = 'Continue'

$output = @(quser 2>$null)
if ($output.Count -lt 2) { return }

$header   = $output[0]
$idCol    = $header.IndexOf('ID')
$stateCol = $header.IndexOf('STATE')

if ($idCol -lt 0 -or $stateCol -lt 0) { return }
$idLen = $stateCol - $idCol

for ($i = 1; $i -lt $output.Count; $i++) {
    $line = $output[$i]
    if (-not $line -or -not $line.Trim()) { continue }
    if ($line.Length -lt $stateCol) { continue }

    $sessionId = $line.Substring($idCol, $idLen).Trim()
    if ($sessionId -notmatch '^\d+$') { continue }
    if ([int]$sessionId -le 0) { continue }

    & logoff.exe $sessionId 2>$null
}
'@ | Set-Content -Path $resumeScriptPath -Encoding UTF8

    $resumeTaskName = "Logoff On Resume"
    try { schtasks /Delete /TN "$resumeTaskName" /F 2>$null | Out-Null } catch {}

    $resumeAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$resumeScriptPath`""

    $cimTriggerClass = Get-CimClass `
        -ClassName MSFT_TaskEventTrigger `
        -Namespace Root/Microsoft/Windows/TaskScheduler

    $resumeTrigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly
    $resumeTrigger.Enabled = $true
    $resumeTrigger.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'

    $resumePrincipal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $resumeSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    Register-ScheduledTask `
        -TaskName $resumeTaskName `
        -Action $resumeAction `
        -Trigger $resumeTrigger `
        -Principal $resumePrincipal `
        -Settings $resumeSettings `
        -Force | Out-Null

    Write-LogOk "Scheduled task created: $resumeTaskName (logs off active sessions on wake/lid open)"

    # ===========================
    # Daily auto-update task
    # ===========================
    Register-AutoUpdateTask

    # ===========================
    # Apply Group Policy + restart prompt
    # ===========================
    Write-LogInfo "Forcing Group Policy update to apply all settings immediately..."
    gpupdate /force | Out-Null

    Write-Host ""
    Write-LogOk "All Kazuha Hub Windows PC Policies configured. Please RESTART the computer to fully apply all settings."
    Write-Host ""

    if ($Unattended) {
        Write-LogInfo "Unattended mode: skipping restart prompt."
        return
    }

    $resp = Read-Host "Do you want to RESTART now? (Y/N)"
    if ($resp -in @('Y','y')) {
        Restart-Computer -Force
    }
}

# ============================================================
# Main dispatch
# ============================================================
if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

if ($Version) {
    "$ScriptName $ScriptVersion"
    exit 0
}

# -CheckUpdate is read-only and does not require admin
if ($CheckUpdate -and -not $SelfUpdate) {
    Invoke-CheckUpdate | Out-Null
    exit 0
}

if ($SelfUpdate) {
    # Auto-apply when running unattended (e.g. from the daily task)
    Invoke-SelfUpdate -AutoApply:$Unattended
    exit 0
}

if ($Uninstall) {
    Invoke-Uninstall
    exit 0
}

if ($Apply -or $Unattended) {
    Invoke-ApplyPolicies
    exit 0
}

# No flags + interactive -> menu loop
while ($true) {
    $choice = Show-Menu
    switch ($choice) {
        '1' { Invoke-ApplyPolicies; exit 0 }
        '2' { Invoke-Uninstall;     exit 0 }
        '3' { Invoke-CheckUpdate | Out-Null }
        '4' { Invoke-SelfUpdate -AutoApply; exit 0 }
        '5' { Write-LogOk "No changes made."; exit 0 }
        default { Write-LogWarn "Invalid choice '$choice'" }
    }
}
