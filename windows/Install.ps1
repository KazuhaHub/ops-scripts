[CmdletBinding()]
param(
    [ValidateSet('Public', 'Limited', 'Cleanup')]
    [string]$Profile,    # skip the menu by passing this
    [switch]$Unattended, # for fully-hands-off: applies/cleans up without prompts
    [switch]$Help
)

# ============================================================
# Kazuha Hub Windows policy bootstrap installer
#
# One-liners (run from an elevated PowerShell):
#
#   # Interactive (pick profile via menu):
#   iex (irm 'https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/Install.ps1')
#
#   # Hands-off install of a specific profile:
#   & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/Install.ps1'))) -Profile Public -Unattended
#
# Behavior:
#   1. Verify Administrator
#   2. Download {ORG_PUBLIC_ALL.ps1 or ORG_LIMITED_USERS.ps1} + CLEAN_ALL.ps1 to
#      C:\ProgramData\KazuhaHub\
#   3. Validate each downloaded file (PowerShell parse)
#   4. Force file Owner = BUILTIN\Administrators so the ORG script's ownership
#      check passes when SYSTEM later invokes self-update
#   5. Launch the chosen script (menu by default, -Apply -Unattended otherwise)
# ============================================================

$BootstrapVersion   = "1.0.0"
$BaseUrl            = "https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows"
$InstallDir         = Join-Path $env:ProgramData "KazuhaHub"
$TrustedUrlPrefix   = "https://raw.githubusercontent.com/"

function Write-LogInfo  { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-LogOk    { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-LogWarn  { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-LogErr   { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }
function Die            { param([string]$Msg) Write-LogErr $Msg; exit 1 }

if ($Help) {
    Write-Host @"
Kazuha Hub Windows installer (v$BootstrapVersion)

Usage:
  iex (irm 'https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/windows/Install.ps1')

Skip the menu by passing -Profile:
  & ([scriptblock]::Create((irm '<this URL>'))) -Profile Public
  & ([scriptblock]::Create((irm '<this URL>'))) -Profile Limited
  & ([scriptblock]::Create((irm '<this URL>'))) -Profile Cleanup

Add -Unattended for hands-off automated runs (no Read-Host prompts).
"@
    exit 0
}

# ============================================================
# Admin check
# ============================================================
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "This installer must be run from an elevated PowerShell session (Run as Administrator)."
}

# ============================================================
# Menu (only if no -Profile passed)
# ============================================================
if (-not $Profile) {
    Write-Host ""
    Write-Host "  +-----------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("  | Kazuha Hub Windows installer   v{0,-37} |" -f $BootstrapVersion)        -ForegroundColor Cyan
    Write-Host "  +-----------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Which profile would you like to install / apply?"
    Write-Host "  1) Public   - shared/kiosk machines (20m idle logoff, 30m display off, 8d profile cleanup)"
    Write-Host "  2) Limited  - personal user machines (2h idle logoff, 10m display off)"
    Write-Host "  3) Cleanup  - revert all Kazuha Hub policies (run CLEAN_ALL.ps1)"
    Write-Host "  4) Quit"
    Write-Host ""
    $choice = Read-Host "Choice [1]"
    if (-not $choice) { $choice = "1" }
    switch ($choice) {
        '1' { $Profile = 'Public' }
        '2' { $Profile = 'Limited' }
        '3' { $Profile = 'Cleanup' }
        '4' { Write-LogOk "No changes made."; exit 0 }
        default { Die "Invalid choice '$choice'" }
    }
}

# ============================================================
# Resolve which scripts to fetch
# ============================================================
switch ($Profile) {
    'Public'  { $entryName = 'ORG_PUBLIC_ALL.ps1' }
    'Limited' { $entryName = 'ORG_LIMITED_USERS.ps1' }
    'Cleanup' { $entryName = 'CLEAN_ALL.ps1' }
}

# Always pull CLEAN_ALL alongside, so the ORG script's "Uninstall" menu option
# can run it locally without re-downloading.
$filesToFetch = @($entryName)
if ($entryName -ne 'CLEAN_ALL.ps1') { $filesToFetch += 'CLEAN_ALL.ps1' }

# ============================================================
# Download + validate + lock down
# ============================================================
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Write-LogOk "Created $InstallDir"
}

foreach ($name in $filesToFetch) {
    $url = "$BaseUrl/$name"
    $dst = Join-Path $InstallDir $name

    if ($url -notlike "$TrustedUrlPrefix*") {
        Die "Refusing to fetch from untrusted URL: $url"
    }

    Write-LogInfo "Downloading $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    } catch {
        Die "Download failed for $url : $($_.Exception.Message)"
    }

    # PowerShell syntax check
    $tokens = $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($dst, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        Die "Downloaded $name failed PowerShell parse — refusing to install ($($errors[0].Message))"
    }

    # Force Owner = BUILTIN\Administrators so the ORG script's
    # Assert-ScriptOwnedByPrivilegedPrincipal check passes.
    try {
        $acl   = Get-Acl -Path $dst
        $admin = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")
        $acl.SetOwner($admin)
        Set-Acl -Path $dst -AclObject $acl
    } catch {
        Write-LogWarn "Could not set Owner=Administrators on $dst : $($_.Exception.Message)"
    }

    Write-LogOk "Installed: $dst"
}

# ============================================================
# Hand off to the chosen script
# ============================================================
$entryPath = Join-Path $InstallDir $entryName

Write-Host ""
Write-LogOk "Bootstrap complete. Handing off to $entryName ..."
Write-Host ""

if ($Unattended) {
    & $entryPath -Apply -Unattended
} else {
    & $entryPath
}

exit $LASTEXITCODE
