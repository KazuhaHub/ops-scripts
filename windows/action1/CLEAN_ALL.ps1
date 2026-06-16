# ============================================================
# CLEAN_ALL.ps1 (Action1 build) — revert ALL Kazuha Hub ORG policies plus the
# logoff / auto-update scheduled tasks and helper scripts, and re-enable
# workstation lock. LAPS configuration is intentionally left in place.
#
# Built for Action1 batch push: runs as LocalSystem, non-interactive, no menu,
# no GitHub self-update. Push with NO arguments to clean up.
#
# No param()/[CmdletBinding()] on purpose: Action1 prepends preference statements
# ahead of the script, which makes a top-level param() block a parse error
# ("Unexpected attribute 'CmdletBinding'" / "Unexpected token 'param'").
# ============================================================
$ErrorActionPreference = 'Continue'   # best-effort; overrides Action1's preamble

# ============================================================
# Constants
# ============================================================
$ScriptVersion       = "1.6.0"
$ScriptName          = "CLEAN_ALL"
$AutoUpdateTaskName  = "Kazuha Hub Auto Update"

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
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name "BackupDirectory" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordComplexity" -PropertyType DWord -Value 4 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordLength" -PropertyType DWord -Value 16 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordAgeDays" -PropertyType DWord -Value 30 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PostAuthenticationResetDelay" -PropertyType DWord -Value 8 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PostAuthenticationActions" -PropertyType DWord -Value 3 -Force | Out-Null
    try { Invoke-LapsPolicyProcessing } catch {}

    # --- LAPS is kept enforced; warn if this OS can't honor it yet (warn-only) ---
    if (-not (Get-Command Invoke-LapsPolicyProcessing -ErrorAction SilentlyContinue)) {
        Write-LogWarn "Windows LAPS not present on this OS (needs Win11/Server2022 or the 2023-04 cumulative update). LAPS policy is kept but stays inert until the OS supports it."
    }

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
    # 5b. Remove enforced lock screen + desktop wallpaper (PersonalizationCSP)
    # ===========================
    $cspKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
    foreach ($n in @("LockScreenImageStatus","LockScreenImagePath","LockScreenImageUrl",
                     "DesktopImageStatus","DesktopImagePath","DesktopImageUrl")) {
        Clear-RegistryValue -Path $cspKey -Name $n
    }
    foreach ($img in @("C:\ProgramData\KazuhaHub\lockscreen.jpeg", "C:\ProgramData\KazuhaHub\desktop.jpg")) {
        if (Test-Path $img) {
            try { Remove-Item -Path $img -Force; Write-Host "  Removed $img" -ForegroundColor DarkGray } catch {}
        }
    }

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

    # The ORG apply also wrote display/sleep timeouts into the LIVE active power
    # scheme via 'powercfg /X' — clearing the GPO keys above does NOT undo that.
    # Restore the active scheme to Windows "Balanced" defaults so cleanup actually
    # returns normal power behavior. (Lid action is left as-is: sleep-on-lid is the
    # Windows laptop default, and the kiosk logoff-on-resume task is removed above.)
    powercfg /X monitor-timeout-ac 10 2>$null | Out-Null
    powercfg /X monitor-timeout-dc 5  2>$null | Out-Null
    powercfg /X standby-timeout-ac 30 2>$null | Out-Null
    powercfg /X standby-timeout-dc 15 2>$null | Out-Null

    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Start" -Name "value"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\Start" -Name "value"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "ShowSleepOption"
    Clear-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "ShowSleepOption"

    # ===========================
    # 9. Re-enable Lock Workstation policy everywhere
    # ===========================
    function Set-LockEnabled {
        param([string]$Path)
        $errSnap = $Error.Count
        try {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -Path $Path -Name "DisableLockWorkstation" -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Host "  Set DisableLockWorkstation = 0 at $Path" -ForegroundColor DarkGray
        } catch {
            Write-LogWarn "Failed to set DisableLockWorkstation at $Path : $($_.Exception.Message)"
        }
        # Best-effort across redundant lock paths: a tolerated per-path failure here
        # must not flip the Action1 result, so drop any error it added to $Error.
        while ($Error.Count -gt $errSnap) { $Error.RemoveAt(0) }
    }

    Write-LogInfo "Re-enabling Lock Workstation policy..."
    Set-LockEnabled -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-LockEnabled -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    $errSnap = $Error.Count
    try {
        if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System") {
            New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
                -Name "DisableLockWorkstation" -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Host "  Set DisableLockWorkstation = 0 at HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -ForegroundColor DarkGray
        }
    } catch {}
    while ($Error.Count -gt $errSnap) { $Error.RemoveAt(0) }

    # No HKCU revert: under Action1 the script runs as LocalSystem, so HKCU maps to
    # the SYSTEM hive (S-1-5-18), not a real user. The HKLM + HKU\.DEFAULT reverts
    # (here and above) are what actually govern the lock for real users.

    try {
        & reg.exe add "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
            /v DisableLockWorkstation /t REG_DWORD /d 0 /f 2>$null | Out-Null
    } catch {}

    # ===========================
    # 10. Finalize
    # ===========================
    Write-LogInfo "Forcing Group Policy update to apply ALL revert + lock settings..."
    gpupdate /force | Out-Null

    Write-Host ""
    Write-LogOk "All revert actions completed. It is recommended to SIGN OUT or RESTART the computer."
    Write-Host ""
}

# ============================================================
# Action1 entry point
#
# Action1 pushes this with NO arguments and runs it as LocalSystem in a
# non-interactive session — so there is no menu and no GitHub self-update. It
# reverts everything and reports the result through the exit code:
#   exit 0 = success
#   exit 1 = failure (Action1 marks the run as Error)
# ============================================================
$Error.Clear()
try {
    Invoke-ApplyPolicies
} catch {
    Write-LogErr "Cleanup aborted (terminating error): $($_.Exception.Message)"
    exit 1
}

# Best-effort writes are non-terminating, so they wouldn't fail the job on their
# own. Inspect the error stream for REAL failures and fail the Action1 run if any
# occurred — excluding expected no-ops (value clears, removing absent tasks/files).
$benignActivities = @(
    'Remove-ItemProperty','Remove-Item','Unregister-ScheduledTask','Get-ScheduledTask',
    'Get-Command','Get-Content','Get-Item','Get-ItemProperty','Invoke-LapsPolicyProcessing','Invoke-WebRequest'
)
$realFailures = @($Error | Where-Object {
    $_ -is [System.Management.Automation.ErrorRecord] -and
    $_.CategoryInfo.Activity -and
    ($benignActivities -notcontains $_.CategoryInfo.Activity)
})
if ($realFailures.Count -gt 0) {
    Write-LogErr "$($realFailures.Count) error(s) during cleanup — reporting failure to Action1:"
    $realFailures | Select-Object -First 25 | ForEach-Object {
        Write-LogErr "  - [$($_.CategoryInfo.Activity)] $($_.Exception.Message)"
    }
    exit 1
}

Write-LogOk "Done — no reboot required (lock re-enabled; sign out for a clean state)."
exit 0
