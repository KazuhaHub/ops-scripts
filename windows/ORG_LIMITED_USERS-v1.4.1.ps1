# Must run as admin or HKLM writes will fail
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run in an elevated PowerShell session (Run as Administrator)."
    exit 1
}

# ===========================
# LAPS policy (Windows)
# ===========================

# Run as Administrator
$path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS"
New-Item -Path $path -Force | Out-Null

New-ItemProperty -Path $path -Name "BackupDirectory" -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $path -Name "PasswordComplexity" -PropertyType DWord -Value 4 -Force | Out-Null
New-ItemProperty -Path $path -Name "PasswordLength" -PropertyType DWord -Value 16 -Force | Out-Null
New-ItemProperty -Path $path -Name "PasswordAgeDays" -PropertyType DWord -Value 30 -Force | Out-Null

New-ItemProperty -Path $path -Name "PostAuthenticationResetDelay" -PropertyType DWord -Value 8 -Force | Out-Null
New-ItemProperty -Path $path -Name "PostAuthenticationActions" -PropertyType DWord -Value 3 -Force | Out-Null

# Trigger immediately
Invoke-LapsPolicyProcessing

# ===========================
# Windows Hello for Business / PIN (disable)
# ===========================

# HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" `
    -Name "Enabled" -PropertyType DWord -Value 0 -Force | Out-Null

# HKLM:\SOFTWARE\Policies\Microsoft\Windows\System
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
    -Name "AllowDomainPINLogon" -PropertyType DWord -Value 0 -Force | Out-Null

# HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions
New-Item -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" `
    -Name "value" -PropertyType DWord -Value 0 -Force | Out-Null

# ===========================
# Lock workstation / Switch User restrictions
# ===========================

New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Force | Out-Null

# Disable Lock (HKLM)
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "DisableLockWorkstation" -PropertyType DWord -Value 1 -Force | Out-Null
# Hide Switch User
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "HideFastUserSwitching" -PropertyType DWord -Value 1 -Force | Out-Null

# Disable Lock (Winlogon)
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

# Control username visibility (lock/sign-in)
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "DontDisplayLastUserName" -PropertyType DWord -Value 1 -Force | Out-Null

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "DontDisplayUserName" -PropertyType DWord -Value 0 -Force | Out-Null

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "DontDisplayUserNameOnLockScreen" -PropertyType DWord -Value 1 -Force | Out-Null

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "DontDisplayLockedUserId" -PropertyType DWord -Value 3 -Force | Out-Null

# Hide local users enumeration on domain/Entra sign-in
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
    -Name "EnumerateLocalUsers" -PropertyType DWord -Value 0 -Force | Out-Null

# ===========================
# Default User hive (HKU\.DEFAULT)
# ===========================
# Use reg.exe because PowerShell cannot mount HKU in this context
& reg.exe add "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f | Out-Null

# ===========================
# Legal Notice before Ctrl+Alt+Delete
# ===========================

$LegalNoticeTitle = "ATTENTION USERS - 系统访问须知"

$LegalNoticeText = @"
Please sign in with your Kazuha Hub account and remember to LOG OUT after your session to protect your account. You are responsible for any misuse or unauthorized use of your account. Please make sure to backup your files appropriately by saving onto a portable USB drive or online (i.e. OneDrive). Use of this system is subject to Kazuha Hub Network and Computer Use Policies.

请使用您的 Kazuha Hub 账户登录，并在会话结束后务必注销（LOG OUT）以保护您的账户安全。您将对任何误用或未经授权使用您的账户行为承担全部责任。请确保妥善备份您的文件，可以将其保存到便携式 USB 驱动器或在线存储（例如 OneDrive）。使用本系统即表示您同意遵守 Kazuha Hub 网络与计算机使用政策。

ORG_LIMITED_USERS-v1.4.1
"@

# Apply notice (Policies keys)
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "legalnoticecaption" -PropertyType String -Value $LegalNoticeTitle -Force | Out-Null

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "legalnoticetext" -PropertyType String -Value $LegalNoticeText -Force | Out-Null

# Apply notice (Winlogon keys)
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Force | Out-Null

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
    -Name "LegalNoticeCaption" -PropertyType String -Value $LegalNoticeTitle -Force | Out-Null

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
    -Name "LegalNoticeText" -PropertyType String -Value $LegalNoticeText -Force | Out-Null

# ===========================
# Idle logoff task (2 hours, ONIDLE trigger)
# ===========================

$taskName = "Idle 2h Logoff"
$logoffScriptDir  = "C:\ProgramData\KazuhaHub"
$logoffScriptPath = Join-Path $logoffScriptDir "IdleLogoffAll.ps1"

# Ensure folder exists and write a helper script to log off all active user sessions (only if idle >= threshold)
if (-not (Test-Path $logoffScriptDir)) {
    New-Item -Path $logoffScriptDir -ItemType Directory -Force | Out-Null
}

@'
param(
    [int]$Minutes = 120
)

$ErrorActionPreference = 'Continue'

# Capture quser output as an array of lines. Empty/no-user cases become an empty array.
$output = @(quser 2>$null)
if ($output.Count -lt 2) { return }

$header = $output[0]
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
    $state     = $line.Substring($stateCol, $stateLen).Trim()
    $idleStr   = if ($line.Length -ge ($idleCol + $idleLen)) {
        $line.Substring($idleCol, $idleLen).Trim()
    } else {
        $line.Substring($idleCol).Trim()
    }

    if ($sessionId -notmatch '^\d+$') { continue }
    if ([int]$sessionId -le 0) { continue }

    $idleMinutes = Get-IdleMinutes $idleStr

    if ($idleMinutes -ge $Minutes) {
        & logoff.exe $sessionId 2>$null
    }
}
'@ | Set-Content -Path $logoffScriptPath -Encoding UTF8

# Remove previous auto-logoff tasks to avoid duplicates
foreach ($oldName in @("AutoLogoff-RealIdle-Limited", "AutoLogoff-RealIdle", $taskName)) {
    try {
        schtasks /Delete /TN "$oldName" /F 2>$null | Out-Null
    } catch {
        Write-Host "Could not remove scheduled task $oldName : $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# Create scheduled task that checks every minute and logs off sessions idle >= 120 minutes
$logoffCmd  = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$logoffScriptPath`" -Minutes 120"

schtasks /Create `
    /TN "Idle 2h Logoff" `
    /SC MINUTE `
    /MO 1 `
    /TR $logoffCmd `
    /F `
    /RU "SYSTEM" | Out-Null

Write-Host "Scheduled task created: $taskName (logs off all active user sessions after 2 hours idle)" -ForegroundColor Green

# ===========================
# Display power policy (screen off after 10 minutes, sleep after 3 hours) and lock it
# ===========================

$powerPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings"
$subVideo = "7516b95f-f776-4464-8c53-06167f40cc99" # VIDEO subgroup
$displayTimeoutSetting = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e" # Turn off display after
$subSleep = "238c9fa8-0aad-41ed-83f4-97be242c8f20" # SLEEP subgroup
$sleepTimeoutSetting = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da" # Sleep after

$displayOffMinutes = 10
$sleepAfterMinutes = 180

foreach ($path in @(
    "$powerPolicyPath\$subVideo\$displayTimeoutSetting",
    "$powerPolicyPath\$subSleep\$sleepTimeoutSetting"
)) {
    New-Item -Path $path -Force | Out-Null
}

# Enforce via policy so users cannot change the timeouts
New-ItemProperty -Path "$powerPolicyPath\$subVideo\$displayTimeoutSetting" `
    -Name "ACSettingIndex" -PropertyType DWord -Value $displayOffMinutes -Force | Out-Null
New-ItemProperty -Path "$powerPolicyPath\$subVideo\$displayTimeoutSetting" `
    -Name "DCSettingIndex" -PropertyType DWord -Value $displayOffMinutes -Force | Out-Null
New-ItemProperty -Path "$powerPolicyPath\$subSleep\$sleepTimeoutSetting" `
    -Name "ACSettingIndex" -PropertyType DWord -Value $sleepAfterMinutes -Force | Out-Null
New-ItemProperty -Path "$powerPolicyPath\$subSleep\$sleepTimeoutSetting" `
    -Name "DCSettingIndex" -PropertyType DWord -Value $sleepAfterMinutes -Force | Out-Null

# Apply immediately to the active power plan
powercfg /X monitor-timeout-ac $displayOffMinutes | Out-Null
powercfg /X monitor-timeout-dc $displayOffMinutes | Out-Null
powercfg /X standby-timeout-ac $sleepAfterMinutes | Out-Null
powercfg /X standby-timeout-dc $sleepAfterMinutes | Out-Null

# Remove Sleep from Start menu power options
$startPolicyDefault = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Start"
$startPolicyCurrent = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\Start"

foreach ($path in @($startPolicyDefault, $startPolicyCurrent)) {
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -Path $path -Name "value" -PropertyType DWord -Value 1 -Force | Out-Null
}

# Hide Sleep from Start/power menu via policy path
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" `
    -Name "ShowSleepOption" -PropertyType DWord -Value 0 -Force | Out-Null


# ===========================
# Lid close: Sleep + Logoff on resume
# ===========================
# Closing the lid puts the laptop into sleep; on wake (lid open) we log off all
# active sessions so the user lands on the sign-in screen instead of the previous
# desktop. Desktop machines without a lid simply ignore the LIDACTION setting.

$subButtons = "4f971e89-eebd-4455-a8de-9e59040e7347" # BUTTONS subgroup
$lidAction  = "5ca83367-6e45-459f-a27b-476b1d01c936" # Lid close action

New-Item -Path "$powerPolicyPath\$subButtons\$lidAction" -Force | Out-Null

# Enforce via policy: 1 = Sleep
New-ItemProperty -Path "$powerPolicyPath\$subButtons\$lidAction" `
    -Name "ACSettingIndex" -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path "$powerPolicyPath\$subButtons\$lidAction" `
    -Name "DCSettingIndex" -PropertyType DWord -Value 1 -Force | Out-Null

# Apply to the active power plan (best-effort; harmless on lid-less machines)
powercfg /SETACVALUEINDEX SCHEME_CURRENT $subButtons $lidAction 1 2>$null | Out-Null
powercfg /SETDCVALUEINDEX SCHEME_CURRENT $subButtons $lidAction 1 2>$null | Out-Null
powercfg /SETACTIVE SCHEME_CURRENT 2>$null | Out-Null

# Helper script: log off every active user session
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

# Event-triggered scheduled task: fires when the system resumes from sleep/hibernate
$resumeTaskName = "Logoff On Resume"

# Remove any previous instance to avoid duplicates
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

Write-Host "Scheduled task created: $resumeTaskName (logs off active sessions when the laptop wakes from sleep, e.g. lid open)" -ForegroundColor Green


# ===========================
# Apply and prompt restart
# ===========================

Write-Host "Forcing Group Policy update to apply all settings immediately..."
# Force gpupdate
gpupdate /force

Write-Host ""
Write-Host "All Kazuha Hub Windows PC Policies Configured. Please RESTART the computer to fully apply all settings!" -ForegroundColor Green
Write-Host ""

# Restart prompt
$Response = Read-Host "Do you want to RESTART now? (Y/N)"
if ($Response -eq "Y" -or $Response -eq "y") {
    Restart-Computer -Force
}
