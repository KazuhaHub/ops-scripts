[CmdletBinding()]
param(
    [switch]$Apply,         # run cleanup (skip menu)
    [switch]$CheckUpdate,   # check upstream version (no admin required)
    [switch]$SelfUpdate,    # download latest, replace, and (in -Unattended) auto-apply
    [switch]$Version,       # print version and exit (no admin required)
    [switch]$Unattended,    # no menu, no Read-Host prompts
    [switch]$NoMenu,        # alias for -Unattended
    [switch]$Help
)

if ($NoMenu) { $Unattended = $true }

# ============================================================
# Constants
# ============================================================
$ScriptVersion       = "1.5.0"
$ScriptName          = "CLEAN_ALL"
$AutoUpdateTaskName  = "Kazuha Hub Auto Update"
$TrustedUrlPrefix    = "https://raw.githubusercontent.com/"
$DefaultRawUrl       = "https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/$ScriptName.ps1"
$ScriptRawUrl        = if ($env:KH_WIN_UPDATE_URL) { $env:KH_WIN_UPDATE_URL } else { $DefaultRawUrl }

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
        Die "Refusing privileged operation: $PSCommandPath is owned by '$owner', not a privileged principal."
    }
}

# ============================================================
# Version handling / self-update
# ============================================================
function Get-RemoteVersion {
    try {
        $content = Invoke-RestMethod -Uri $ScriptRawUrl -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
    } catch { return $null }
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
    if (-not $remote) { Write-LogWarn "Could not fetch remote version (offline or upstream unreachable)"; return $false }
    if ($remote -eq $ScriptVersion) { Write-LogOk "You are on the latest version ($ScriptVersion)"; return $false }
    if (-not (Test-VersionNewer $remote $ScriptVersion)) { Write-LogOk "Local $ScriptVersion is ahead of upstream $remote (development build)"; return $false }
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
# Interactive menu
# ============================================================
function Show-Menu {
    Write-Host ""
    Write-Host "  +-----------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("  | Kazuha Hub Windows Policy   {0,-41} |" -f "$ScriptName v$ScriptVersion") -ForegroundColor Cyan
    Write-Host "  +-----------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "What would you like to do?"
    Write-Host "  1) Revert all Kazuha Hub policies  (default)"
    Write-Host "  2) Check for script updates"
    Write-Host "  3) Self-update now (download latest)"
    Write-Host "  4) Quit"
    Write-Host ""

    $choice = Read-Host "Choice [1]"
    if (-not $choice) { $choice = "1" }
    return $choice
}

# ============================================================
# Apply cleanup (the actual revert logic)
# ============================================================
function Invoke-ApplyPolicies {
    Assert-IsAdmin

    Write-LogWarn "Reverting Kazuha Hub ORG policies..."

    # ===========================
    # LAPS policy — keep enforced (LAPS is generally desired even when ORG profile is removed)
    # ===========================
    $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS"
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -Path $path -Name "BackupDirectory" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordComplexity" -PropertyType DWord -Value 4 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordLength" -PropertyType DWord -Value 16 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordAgeDays" -PropertyType DWord -Value 30 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PostAuthenticationResetDelay" -PropertyType DWord -Value 8 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PostAuthenticationActions" -PropertyType DWord -Value 3 -Force | Out-Null
    try { Invoke-LapsPolicyProcessing } catch {}

    # ===========================
    # Helper: safely remove a registry value if it exists
    # ===========================
    function Clear-RegistryValue {
        param([string]$Path, [string]$Name)
        try {
            if (Test-Path $Path) {
                Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
                Write-Host "  Cleared [$Name] in $Path" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  Skip [$Name] in $Path : $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    # ===========================
    # 1. Remove Windows Hello / PIN restrictions
    # ===========================
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -Name "Enabled"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "AllowDomainPINLogon"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" -Name "value"

    # ===========================
    # 2. Allow Lock / Switch User / Ctrl+Alt+Del options
    # ===========================
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableLockWorkstation"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "HideFastUserSwitching"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DisableLockWorkstation"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableCAD"

    # ===========================
    # 3. Allow usernames to show on sign-in/lock screens
    # ===========================
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayLastUserName"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayUserName"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayUserNameOnLockScreen"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayLockedUserId"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnumerateLocalUsers"

    # ===========================
    # 4. Clear Legal Notice banner
    # ===========================
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "legalnoticecaption"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "legalnoticetext"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "LegalNoticeCaption"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "LegalNoticeText"

    # ===========================
    # 5. Remove CleanupProfiles policy
    # ===========================
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "CleanupProfiles"

    # ===========================
    # 6. Default User hive lock cleanup (HKU\.DEFAULT)
    # ===========================
    try {
        & reg.exe delete "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
            /v DisableLockWorkstation /f 2>$null | Out-Null
        Write-Host "  Cleared DisableLockWorkstation for HKU\.DEFAULT" -ForegroundColor DarkGray
    } catch {}

    # ===========================
    # 7. Remove all Kazuha Hub scheduled tasks (idle logoff, resume logoff, auto-update)
    # ===========================
    # Hardcoded historical names + auto-update task name
    $knownTasks = @(
        "AutoLogoff-RealIdle",
        "AutoLogoff-Idle",
        "AutoLogoff-RealIdle-Limited",
        "Idle 2h Logoff",
        "Logoff On Resume",
        $AutoUpdateTaskName
    )
    foreach ($t in $knownTasks) {
        try {
            $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            if ($task) {
                Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "  Removed scheduled task: $t" -ForegroundColor DarkGray
            }
        } catch {}
    }

    # Pattern-match: any "Idle <N>m Logoff" task (covers PUBLIC's 20m, LIMITED's 120m, future variants)
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^Idle \d+m Logoff$' } | ForEach-Object {
        try {
            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  Removed scheduled task: $($_.TaskName)" -ForegroundColor DarkGray
        } catch {}
    }

    # Helper scripts
    foreach ($script in @(
        "C:\ProgramData\KazuhaHub\IdleLogoff.ps1",
        "C:\ProgramData\KazuhaHub\IdleLogoffAll.ps1",
        "C:\ProgramData\KazuhaHub\LogoffOnResume.ps1"
    )) {
        if (Test-Path $script) {
            try {
                Remove-Item -Path $script -Force
                Write-Host "  Removed helper script: $script" -ForegroundColor DarkGray
            } catch {}
        }
    }

    # ===========================
    # 8. Display / Sleep / Lid policy cleanup
    # ===========================
    $powerPolicyPath       = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings"
    $subVideo              = "7516b95f-f776-4464-8c53-06167f40cc99"
    $displayTimeoutSetting = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"
    $subSleep              = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
    $sleepTimeoutSetting   = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"
    $subButtons            = "4f971e89-eebd-4455-a8de-9e59040e7347"
    $lidAction             = "5ca83367-6e45-459f-a27b-476b1d01c936"

    Clear-RegistryValue -Path "$powerPolicyPath\$subVideo\$displayTimeoutSetting" -Name "ACSettingIndex"
    Clear-RegistryValue -Path "$powerPolicyPath\$subVideo\$displayTimeoutSetting" -Name "DCSettingIndex"
    Clear-RegistryValue -Path "$powerPolicyPath\$subSleep\$sleepTimeoutSetting"   -Name "ACSettingIndex"
    Clear-RegistryValue -Path "$powerPolicyPath\$subSleep\$sleepTimeoutSetting"   -Name "DCSettingIndex"
    Clear-RegistryValue -Path "$powerPolicyPath\$subButtons\$lidAction"           -Name "ACSettingIndex"
    Clear-RegistryValue -Path "$powerPolicyPath\$subButtons\$lidAction"           -Name "DCSettingIndex"

    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Start" -Name "value"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\Start" -Name "value"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "ShowSleepOption"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "ShowSleepOption"

    # ===========================
    # 9. Re-enable Lock Workstation policy everywhere
    # ===========================
    function Set-LockEnabled {
        param([string]$Path)
        try {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -Path $Path -Name "DisableLockWorkstation" -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Host "  Set DisableLockWorkstation = 0 at $Path" -ForegroundColor DarkGray
        } catch {
            Write-LogWarn "Failed to set DisableLockWorkstation at $Path : $($_.Exception.Message)"
        }
    }

    Write-LogInfo "Re-enabling Lock Workstation policy..."
    Set-LockEnabled -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-LockEnabled -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    try {
        if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System") {
            New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
                -Name "DisableLockWorkstation" -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Host "  Set DisableLockWorkstation = 0 at HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -ForegroundColor DarkGray
        }
    } catch {}

    Set-LockEnabled -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"

    try {
        & reg.exe add "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
            /v DisableLockWorkstation /t REG_DWORD /d 0 /f 2>$null | Out-Null
    } catch {}

    # ===========================
    # 10. Finalize and prompt for restart
    # ===========================
    Write-LogInfo "Forcing Group Policy update to apply ALL revert + lock settings..."
    gpupdate /force | Out-Null

    Write-Host ""
    Write-LogOk "All revert actions completed. It is recommended to SIGN OUT or RESTART the computer."
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
if ($Help)    { Get-Help $PSCommandPath -Detailed; exit 0 }
if ($Version) { "$ScriptName $ScriptVersion"; exit 0 }

if ($CheckUpdate -and -not $SelfUpdate) {
    Invoke-CheckUpdate | Out-Null
    exit 0
}

if ($SelfUpdate) {
    Invoke-SelfUpdate -AutoApply:$Unattended
    exit 0
}

if ($Apply -or $Unattended) {
    Invoke-ApplyPolicies
    exit 0
}

while ($true) {
    $choice = Show-Menu
    switch ($choice) {
        '1' { Invoke-ApplyPolicies; exit 0 }
        '2' { Invoke-CheckUpdate | Out-Null }
        '3' { Invoke-SelfUpdate -AutoApply; exit 0 }
        '4' { Write-LogOk "No changes made."; exit 0 }
        default { Write-LogWarn "Invalid choice '$choice'" }
    }
}
