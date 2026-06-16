# ============================================================
# ORG_PUBLIC_ALL.ps1 (Action1 build) — Kazuha Hub policy for PUBLIC / shared
# devices (kiosks, meeting-room PCs): 20m idle logoff, short power timeouts,
# logoff-on-resume, 8-day profile cleanup.
#
# Built for Action1 batch push: runs as LocalSystem, non-interactive, no menu,
# no GitHub self-update. Push with NO arguments to apply.
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
$ScriptName          = "ORG_PUBLIC_ALL"

# Idle logoff threshold (minutes) — what makes this script "PUBLIC"
$IdleLogoffMinutes   = 20
$IdleTaskName        = "Idle ${IdleLogoffMinutes}m Logoff"

# Power policy timeouts (minutes)
$DisplayOffMinutes   = 30
$SleepAfterMinutes   = 60

# Profile cleanup days (set to 0 to skip — PUBLIC enables this, LIMITED does not)
$ProfileCleanupDays  = 8

# Lock screen + desktop wallpaper, enforced & locked via PersonalizationCSP.
# Enterprise/Education only (Pro needs SharedPC; ignored on Home). Set a URL to
# '' to skip the download (pre-stage the file). Paths must contain NO spaces.
$LockScreenImageUrl    = 'https://cdn.jsdelivr.net/gh/KKazuhaK/picx-images-hosting@master/download.26m4zsywfz.jpeg'
$LockScreenImagePath   = 'C:\ProgramData\KazuhaHub\lockscreen.jpeg'
$LockScreenImageSha256 = ''
$DesktopImageUrl       = 'https://dl.kazuha.org/wallpaper/desktop.jpg'
$DesktopImagePath      = 'C:\ProgramData\KazuhaHub\desktop.jpg'
$DesktopImageSha256    = ''

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
# Apply policies (the actual ORG profile)
# ============================================================
function Invoke-ApplyPolicies {
    Assert-IsAdmin

    # ===========================
    # LAPS policy (Windows)
    # ===========================
    $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS"
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }

    New-ItemProperty -Path $path -Name "BackupDirectory" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordComplexity" -PropertyType DWord -Value 4 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordLength" -PropertyType DWord -Value 16 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PasswordAgeDays" -PropertyType DWord -Value 30 -Force | Out-Null

    New-ItemProperty -Path $path -Name "PostAuthenticationResetDelay" -PropertyType DWord -Value 8 -Force | Out-Null
    New-ItemProperty -Path $path -Name "PostAuthenticationActions" -PropertyType DWord -Value 3 -Force | Out-Null

    try { Invoke-LapsPolicyProcessing } catch { Write-LogWarn "Invoke-LapsPolicyProcessing not available: $($_.Exception.Message)" }

    # --- LAPS backup prerequisites (warn-only; the policy is written regardless) ---
    if (-not (Get-Command Invoke-LapsPolicyProcessing -ErrorAction SilentlyContinue)) {
        Write-LogWarn "Windows LAPS not present on this OS (needs Win11/Server2022 or the 2023-04 cumulative update). LAPS policy is written but stays inert until the OS supports it."
    }
    $dsreg = ''
    if (Get-Command dsregcmd.exe -ErrorAction SilentlyContinue) { $dsreg = (& dsregcmd /status 2>$null | Out-String) }
    if ($dsreg -and ($dsreg -notmatch 'AzureAdJoined\s*:\s*YES')) {
        Write-LogWarn "Device is not Entra (Azure AD) joined. LAPS BackupDirectory=1 (backup to Entra) will not take effect until it is."
    }

    # ===========================
    # Windows Hello for Business / PIN (disable)
    # ===========================
    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork")) { New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -Force | Out-Null }
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" `
        -Name "Enabled" -PropertyType DWord -Value 0 -Force | Out-Null

    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System")) { New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null }
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
        -Name "AllowDomainPINLogon" -PropertyType DWord -Value 0 -Force | Out-Null

    if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions")) { New-Item -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" -Force | Out-Null }
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" `
        -Name "value" -PropertyType DWord -Value 0 -Force | Out-Null

    # ===========================
    # Lock workstation / Switch User restrictions
    # ===========================
    if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System")) { New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Force | Out-Null }

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

    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System")) { New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null }
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
        -Name "EnumerateLocalUsers" -PropertyType DWord -Value 0 -Force | Out-Null

    # ===========================
    # Default User hive (HKU\.DEFAULT)
    # ===========================
    & reg.exe add "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "reg add HKU\.DEFAULT\...\DisableLockWorkstation failed (exit $LASTEXITCODE)." }  # native exit is invisible to the #5 scan otherwise

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

    if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon")) { New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Force | Out-Null }
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -Name "LegalNoticeCaption" -PropertyType String -Value $LegalNoticeTitle -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        -Name "LegalNoticeText" -PropertyType String -Value $LegalNoticeText -Force | Out-Null

    # ===========================
    # Lock screen + desktop wallpaper (PersonalizationCSP). Enterprise/Education
    # only (Pro needs SharedPC; ignored on Home) and LOCKS the images so users
    # cannot change them. Download is best-effort: a CDN/network failure warns and
    # skips enforcement (never enforces a missing path) without failing the run; a
    # registry write failure DOES fail it (caught by the #5 scan).
    # ===========================
    function Test-IsImage {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $false }
        $b = $null
        try { $b = Get-Content -LiteralPath $Path -Encoding Byte -TotalCount 4 -ErrorAction Stop } catch { return $false }
        if (-not $b -or $b.Count -lt 4) { return $false }
        if ($b[0] -eq 255 -and $b[1] -eq 216 -and $b[2] -eq 255) { return $true }                  # JPEG  FF D8 FF
        if ($b[0] -eq 137 -and $b[1] -eq 80 -and $b[2] -eq 78 -and $b[3] -eq 71) { return $true }   # PNG   89 50 4E 47
        return $false
    }
    function Set-PersonalizationImage {
        param([string]$Prefix, [string]$Url, [string]$Path, [string]$Sha256)
        if (-not $Path) { return }
        $imgDir = Split-Path $Path -Parent
        if (-not (Test-Path $imgDir)) { New-Item -Path $imgDir -ItemType Directory -Force | Out-Null }

        # Fetch if the on-disk file is missing or not a real image -- this catches a
        # 0-byte/partial download AND an HTTP-200 "soft error" HTML body (a CDN can
        # return 200 + an error page) -- or when pinned-by-checksum and stale.
        $need = $false
        if ($Url) {
            if (-not (Test-IsImage $Path)) {
                $need = $true
            } elseif ($Sha256) {
                $cur = ''
                try { $cur = (Get-FileHash -Path $Path -Algorithm SHA256).Hash } catch {}
                if ($cur -ne $Sha256.ToUpper()) { $need = $true }
            }
        }
        if ($need) {
            try {
                try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
                Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            } catch {
                Write-LogWarn "$Prefix image download failed: $($_.Exception.Message) (best-effort; not enforcing)"
            }
            # Whatever landed, if it is not a real image (download error, partial, or a
            # 200 HTML error page) delete it so it is never enforced and never sticky
            # (the next run re-downloads); only log success for a valid image.
            if ((Test-Path $Path) -and -not (Test-IsImage $Path)) {
                Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
            } elseif (Test-IsImage $Path) {
                Write-LogOk "Downloaded $Prefix image -> $Path"
            }
        }

        # Enforce only a real image file (optionally checksum-pinned).
        $ok = Test-IsImage $Path
        if ($ok -and $Sha256) {
            $h = ''
            try { $h = (Get-FileHash -Path $Path -Algorithm SHA256).Hash } catch {}
            if ($h -ne $Sha256.ToUpper()) { Write-LogWarn "$Prefix image checksum mismatch ($h); not enforcing."; $ok = $false }
        }
        if (-not $ok) { Write-LogWarn "$Prefix image unavailable/invalid; PersonalizationCSP ${Prefix}Image* NOT set."; return }

        $cspKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
        if (-not (Test-Path $cspKey)) { New-Item -Path $cspKey -Force | Out-Null }
        New-ItemProperty -Path $cspKey -Name "${Prefix}ImageStatus" -PropertyType DWord  -Value 1     -Force | Out-Null
        New-ItemProperty -Path $cspKey -Name "${Prefix}ImagePath"   -PropertyType String -Value $Path -Force | Out-Null
        New-ItemProperty -Path $cspKey -Name "${Prefix}ImageUrl"    -PropertyType String -Value $Path -Force | Out-Null
        Write-LogOk "$Prefix image enforced & locked via PersonalizationCSP (Enterprise/Education; ignored on Home/Pro)."
    }

    Set-PersonalizationImage -Prefix 'LockScreen' -Url $LockScreenImageUrl -Path $LockScreenImagePath -Sha256 $LockScreenImageSha256
    Set-PersonalizationImage -Prefix 'Desktop'    -Url $DesktopImageUrl    -Path $DesktopImagePath    -Sha256 $DesktopImageSha256

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

# Locale- and SKU-independent idle logoff via the WTS API (wtsapi32.dll, present
# on every Windows SKU). Replaces the old quser/logoff.exe text parsing, which
# broke on non-English Windows (localized column headers) and editions without
# quser.exe. Fails SAFE: if a session's input/clock times cannot be read or look
# implausible, the session is SKIPPED -- never force-logged-off on a guess.
# Scope: ANY session past the idle threshold is logged off, including disconnected
# RDP sessions (idle counts from disconnect) -- intentional for shared/kiosk use.

$ErrorActionPreference = 'Continue'

try {
    if (-not ('KhWts' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class KhWts {
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern int WTSEnumerateSessions(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);
    [DllImport("wtsapi32.dll")]
    public static extern void WTSFreeMemory(IntPtr pMemory);
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern bool WTSQuerySessionInformation(IntPtr hServer, int SessionId, int WTSInfoClass, out IntPtr ppBuffer, out int pBytesReturned);
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern bool WTSLogoffSession(IntPtr hServer, int SessionId, bool bWait);
    [StructLayout(LayoutKind.Sequential)]
    public struct SESSION_INFO { public int SessionId; public IntPtr pName; public int State; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct WTSINFO {
        public int State; public int SessionId;
        public int IncomingBytes; public int OutgoingBytes;
        public int IncomingFrames; public int OutgoingFrames;
        public int IncomingCompressedBytes; public int OutgoingCompressedBytes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string WinStationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=17)] public string Domain;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=21)] public string UserName;
        public long ConnectTime; public long DisconnectTime;
        public long LastInputTime; public long LogonTime; public long CurrentTime;
    }
}
"@
    }
} catch { return }   # WTS API/Add-Type unavailable -> do nothing (safe)

$server = [IntPtr]::Zero   # WTS_CURRENT_SERVER_HANDLE
$pp = [IntPtr]::Zero
$count = 0
if (-not [KhWts]::WTSEnumerateSessions($server, 0, 1, [ref]$pp, [ref]$count)) { return }

try {
    $sz = [System.Runtime.InteropServices.Marshal]::SizeOf([KhWts+SESSION_INFO])
    for ($i = 0; $i -lt $count; $i++) {
        $entry = [IntPtr]($pp.ToInt64() + ($i * $sz))
        $si = [System.Runtime.InteropServices.Marshal]::PtrToStructure($entry, [KhWts+SESSION_INFO])
        $sid = $si.SessionId
        if ($sid -le 0) { continue }   # skip session 0 (services) and the console listener

        $buf = [IntPtr]::Zero
        $rb = 0
        if (-not [KhWts]::WTSQuerySessionInformation($server, $sid, 24, [ref]$buf, [ref]$rb)) { continue }   # 24 = WTSSessionInfo
        try {
            $wi = [System.Runtime.InteropServices.Marshal]::PtrToStructure($buf, [KhWts+WTSINFO])
        } catch {
            continue
        } finally {
            if ($buf -ne [IntPtr]::Zero) { [KhWts]::WTSFreeMemory($buf) }
        }

        if (-not $wi.UserName) { continue }                                  # no logged-on user
        if ($wi.LastInputTime -le 0 -or $wi.CurrentTime -le 0) { continue }  # times unreadable
        $diff = $wi.CurrentTime - $wi.LastInputTime                          # 100ns ticks
        if ($diff -lt 0) { continue }
        $idleMin = [int]($diff / 600000000)                                  # ticks -> minutes
        if ($idleMin -gt 44640) { continue }                                 # > 31 days -> implausible, skip

        if ($idleMin -ge $Minutes) {
            [KhWts]::WTSLogoffSession($server, $sid, $false) | Out-Null
        }
    }
} finally {
    if ($pp -ne [IntPtr]::Zero) { [KhWts]::WTSFreeMemory($pp) }
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

    # schtasks is native: a nonzero exit is invisible to the #5 $Error scan (empty
    # CategoryInfo.Activity). This task IS the profile's core feature, so surface a
    # failure via Write-Error so #5 fails the Action1 run instead of false-success.
    if ($LASTEXITCODE -ne 0) {
        Write-Error "schtasks /Create failed for '$IdleTaskName' (exit $LASTEXITCODE) -- idle logoff NOT installed."
    } else {
        Write-LogOk "Scheduled task created: $IdleTaskName (logs off sessions idle >= $IdleLogoffMinutes minutes)"
    }

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
    )) { if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }

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
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        New-ItemProperty -Path $p -Name "value" -PropertyType DWord -Value 1 -Force | Out-Null
    }

    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer")) { New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Force | Out-Null }
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" `
        -Name "ShowSleepOption" -PropertyType DWord -Value 0 -Force | Out-Null

    # ===========================
    # Lid close: Sleep + Logoff on resume
    # ===========================
    $subButtons = "4f971e89-eebd-4455-a8de-9e59040e7347"
    $lidAction  = "5ca83367-6e45-459f-a27b-476b1d01c936"

    if (-not (Test-Path "$powerPolicyPath\$subButtons\$lidAction")) { New-Item -Path "$powerPolicyPath\$subButtons\$lidAction" -Force | Out-Null }
    New-ItemProperty -Path "$powerPolicyPath\$subButtons\$lidAction" `
        -Name "ACSettingIndex" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path "$powerPolicyPath\$subButtons\$lidAction" `
        -Name "DCSettingIndex" -PropertyType DWord -Value 1 -Force | Out-Null

    powercfg /SETACVALUEINDEX SCHEME_CURRENT $subButtons $lidAction 1 2>$null | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT $subButtons $lidAction 1 2>$null | Out-Null
    powercfg /SETACTIVE SCHEME_CURRENT 2>$null | Out-Null

    $resumeScriptPath = Join-Path $logoffScriptDir "LogoffOnResume.ps1"

    @'
# Locale- and SKU-independent "logoff on resume": enumerate sessions via the WTS
# API and log off any that have a logged-on user (no quser/logoff.exe). Fails
# SAFE: only sessions with a non-empty user name and a positive id are touched.

$ErrorActionPreference = 'Continue'

try {
    if (-not ('KhWtsR' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class KhWtsR {
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern int WTSEnumerateSessions(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);
    [DllImport("wtsapi32.dll")]
    public static extern void WTSFreeMemory(IntPtr pMemory);
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern bool WTSQuerySessionInformation(IntPtr hServer, int SessionId, int WTSInfoClass, out IntPtr ppBuffer, out int pBytesReturned);
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern bool WTSLogoffSession(IntPtr hServer, int SessionId, bool bWait);
    [StructLayout(LayoutKind.Sequential)]
    public struct SESSION_INFO { public int SessionId; public IntPtr pName; public int State; }
}
"@
    }
} catch { return }

$server = [IntPtr]::Zero
$pp = [IntPtr]::Zero
$count = 0
if (-not [KhWtsR]::WTSEnumerateSessions($server, 0, 1, [ref]$pp, [ref]$count)) { return }

try {
    $sz = [System.Runtime.InteropServices.Marshal]::SizeOf([KhWtsR+SESSION_INFO])
    for ($i = 0; $i -lt $count; $i++) {
        $entry = [IntPtr]($pp.ToInt64() + ($i * $sz))
        $si = [System.Runtime.InteropServices.Marshal]::PtrToStructure($entry, [KhWtsR+SESSION_INFO])
        $sid = $si.SessionId
        if ($sid -le 0) { continue }

        $buf = [IntPtr]::Zero
        $rb = 0
        $user = ''
        if ([KhWtsR]::WTSQuerySessionInformation($server, $sid, 5, [ref]$buf, [ref]$rb)) {   # 5 = WTSUserName
            try { $user = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($buf) }
            catch { $user = '' }
            finally { if ($buf -ne [IntPtr]::Zero) { [KhWtsR]::WTSFreeMemory($buf) } }
        }
        if (-not $user) { continue }

        [KhWtsR]::WTSLogoffSession($server, $sid, $false) | Out-Null
    }
} finally {
    if ($pp -ne [IntPtr]::Zero) { [KhWtsR]::WTSFreeMemory($pp) }
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

    # --- Warn on Modern Standby (S0): resume logoff relies on Power-Troubleshooter
    #     Event 1, which S0 / Connected Standby devices may not log on wake ---
    $csEnabled = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "CsEnabled" -ErrorAction SilentlyContinue).CsEnabled
    if ($csEnabled -eq 1) {
        Write-LogWarn "Modern Standby (S0 / Connected Standby) is enabled. 'Logoff On Resume' may not fire on this device (no Power-Troubleshooter Event 1 on wake)."
    }

    # ===========================
    # Apply Group Policy
    # ===========================
    Write-LogInfo "Forcing Group Policy update to apply all settings immediately..."
    gpupdate /force | Out-Null

    Write-Host ""
    Write-LogOk "All Kazuha Hub Windows PC Policies configured."
    Write-Host ""
}

# ============================================================
# Action1 entry point
#
# Action1 pushes this with NO arguments and runs it as LocalSystem in a
# non-interactive session — so there is no menu, no GitHub self-update, and no
# daily auto-update task (Action1 owns deployment and versioning). It just
# applies the profile and reports the result through the exit code:
#   exit 0 = success
#   exit 1 = failure (Action1 marks the run as Error)
# ============================================================
$Error.Clear()
try {
    Invoke-ApplyPolicies
} catch {
    Write-LogErr "Policy apply aborted (terminating error): $($_.Exception.Message)"
    exit 1
}

# Best-effort writes are non-terminating, so they wouldn't fail the job on their
# own. Inspect the error stream for REAL failures and fail the Action1 run if any
# occurred — excluding expected no-ops (reads, value clears, absent LAPS/tasks).
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
    Write-LogErr "$($realFailures.Count) error(s) during apply — reporting failure to Action1:"
    $realFailures | Select-Object -First 25 | ForEach-Object {
        Write-LogErr "  - [$($_.CategoryInfo.Activity)] $($_.Exception.Message)"
    }
    exit 1
}

# This endpoint is managed by Action1 now — remove any legacy GitHub self-update
# task left by the iex / Install.ps1 deployment so the two don't fight.
try { Unregister-ScheduledTask -TaskName "Kazuha Hub Auto Update" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}

Write-LogOk "Done — no reboot required (settings apply at next sign-in / gpupdate)."
exit 0
