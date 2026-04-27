# Kazuha Hub policy cleanup
# Revert settings applied by ORG_PUBLIC_ALL / ORG_LIMITED_USERS v1.3.6 - v1.4.1

Write-Host "Reverting Kazuha Hub ORG policies (v1.4.1)..." -ForegroundColor Yellow

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

# ------------------------------------------------
# Helper: safely remove a registry value if it exists
# ------------------------------------------------
function Clear-RegistryValue {
    param(
        [string]$Path,
        [string]$Name
    )

    try {
        if (Test-Path $Path) {
            Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
            Write-Host "Cleared [$Name] in $Path" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "Skip [$Name] in $Path : $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# ------------------------------------------------
# 1. Remove Windows Hello / PIN restrictions
# ------------------------------------------------

# HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork\Enabled
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -Name "Enabled"

# HKLM:\SOFTWARE\Policies\Microsoft\Windows\System\AllowDomainPINLogon
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "AllowDomainPINLogon"

# HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions\value
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" -Name "value"


# ------------------------------------------------
# 2. Allow Lock / Switch User / Ctrl+Alt+Del options
# ------------------------------------------------

# Remove lock and fast user switching blocks
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableLockWorkstation"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "HideFastUserSwitching"

# Remove Winlogon-level lock restriction
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DisableLockWorkstation"

# Allow Ctrl+Alt+Del (DisableCAD)
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableCAD"


# ------------------------------------------------
# 3. Allow usernames to show on sign-in/lock screens
# ------------------------------------------------

Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayLastUserName"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayUserName"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayUserNameOnLockScreen"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayLockedUserId"

# Allow local user enumeration (domain/Entra scenarios)
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnumerateLocalUsers"


# ------------------------------------------------
# 4. Clear Legal Notice banner
# ------------------------------------------------

# System policy values
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "legalnoticecaption"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "legalnoticetext"

# Winlogon values
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "LegalNoticeCaption"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "LegalNoticeText"


# ------------------------------------------------
# 5. Remove CleanupProfiles policy
# ------------------------------------------------

Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "CleanupProfiles"


# ------------------------------------------------
# 6. Default User hive lock cleanup (HKU\.DEFAULT)
# ------------------------------------------------

try {
    & reg.exe delete "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
        /v DisableLockWorkstation /f | Out-Null
    Write-Host "Cleared DisableLockWorkstation for HKU\.DEFAULT" -ForegroundColor DarkGray
} catch {
    Write-Host "Skip HKU\.DEFAULT DisableLockWorkstation delete: $($_.Exception.Message)" -ForegroundColor DarkYellow
}


# ------------------------------------------------
# 7. Remove idle logoff scheduled tasks
# ------------------------------------------------

$autoLogoffTasks = @(
    "AutoLogoff-RealIdle",
    "AutoLogoff-Idle",
    "AutoLogoff-RealIdle-Limited",
    "Idle 20m Logoff",
    "Idle 2h Logoff",
    "Logoff On Resume"
)

foreach ($taskName in $autoLogoffTasks) {
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "Removed scheduled task: $taskName" -ForegroundColor DarkGray
        } else {
            Write-Host "Scheduled task not found: $taskName" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "Failed to remove scheduled task $taskName : $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

$idleScripts = @(
    "C:\ProgramData\KazuhaHub\IdleLogoff.ps1",
    "C:\ProgramData\KazuhaHub\IdleLogoffAll.ps1",
    "C:\ProgramData\KazuhaHub\LogoffOnResume.ps1"
)

foreach ($script in $idleScripts) {
    if (Test-Path $script) {
        try {
            Remove-Item -Path $script -Force
            Write-Host "Removed idle watcher script: $script" -ForegroundColor DarkGray
        } catch {
            Write-Host "Failed to remove idle watcher script $script : $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
}


# ------------------------------------------------
# 8. Display / Sleep policy cleanup (remove enforced timeouts and restore Sleep button)
# ------------------------------------------------

$powerPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings"
$subVideo = "7516b95f-f776-4464-8c53-06167f40cc99" # VIDEO subgroup
$displayTimeoutSetting = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e" # Turn off display after
$subSleep = "238c9fa8-0aad-41ed-83f4-97be242c8f20" # SLEEP subgroup
$sleepTimeoutSetting = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da" # Sleep after
$subButtons = "4f971e89-eebd-4455-a8de-9e59040e7347" # BUTTONS subgroup
$lidAction  = "5ca83367-6e45-459f-a27b-476b1d01c936" # Lid close action

# Remove enforced timeouts
Clear-RegistryValue -Path "$powerPolicyPath\$subVideo\$displayTimeoutSetting" -Name "ACSettingIndex"
Clear-RegistryValue -Path "$powerPolicyPath\$subVideo\$displayTimeoutSetting" -Name "DCSettingIndex"
Clear-RegistryValue -Path "$powerPolicyPath\$subSleep\$sleepTimeoutSetting" -Name "ACSettingIndex"
Clear-RegistryValue -Path "$powerPolicyPath\$subSleep\$sleepTimeoutSetting" -Name "DCSettingIndex"

# Remove enforced lid close action (release LIDACTION back to user/default)
Clear-RegistryValue -Path "$powerPolicyPath\$subButtons\$lidAction" -Name "ACSettingIndex"
Clear-RegistryValue -Path "$powerPolicyPath\$subButtons\$lidAction" -Name "DCSettingIndex"

# Remove Start menu Sleep hide policy
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Start" -Name "value"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\Start" -Name "value"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "ShowSleepOption"
Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "ShowSleepOption"


# ------------------------------------------------
# 9. Re-enable Lock Workstation policy everywhere
# ------------------------------------------------

function Set-LockEnabled {
    param(
        [string]$Path
    )

    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }

        New-ItemProperty -Path $Path `
            -Name "DisableLockWorkstation" `
            -PropertyType DWord `
            -Value 0 `
            -Force | Out-Null

        Write-Host "Set DisableLockWorkstation = 0 at $Path" -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "Failed to set DisableLockWorkstation at $Path : $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Re-enabling Lock Workstation policy..." -ForegroundColor Yellow

# HKLM keys
Set-LockEnabled -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-LockEnabled -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

# HKLM Policies path
try {
    if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System") {
        New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
            -Name "DisableLockWorkstation" `
            -PropertyType DWord `
            -Value 0 `
            -Force | Out-Null
        Write-Host "Set DisableLockWorkstation = 0 at HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -ForegroundColor DarkGray
    }
} catch {
    Write-Warning "Failed at HKLM Policies path: $($_.Exception.Message)"
}

# HKCU key
Set-LockEnabled -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"

# Default User hive (HKU\.DEFAULT)
try {
    & reg.exe add "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
        /v DisableLockWorkstation /t REG_DWORD /d 0 /f | Out-Null
    Write-Host "Set DisableLockWorkstation = 0 for HKU\.DEFAULT" -ForegroundColor DarkGray
} catch {
    Write-Warning "Failed to update HKU\.DEFAULT : $($_.Exception.Message)"
}


# ------------------------------------------------
# 10. Finalize and prompt for restart
# ------------------------------------------------

Write-Host ""
Write-Host "Forcing Group Policy update to apply ALL revert & lock settings..." -ForegroundColor Yellow
gpupdate /force | Out-Null

Write-Host ""
Write-Host "All revert actions completed. It is recommended to SIGN OUT or RESTART the computer." -ForegroundColor Green
Write-Host ""

$Response = Read-Host "Do you want to RESTART now? (Y/N)"
if ($Response -eq "Y" -or $Response -eq "y") {
    Restart-Computer -Force
}
