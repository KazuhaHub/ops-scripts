#!/usr/bin/env bash
#
# One-shot installer: SSH + Duo 2FA (PAM-based).
#
# Supported:
#   - Debian 11+ / Ubuntu 20.04+
#   - RHEL 8+ / CentOS Stream 8+ / Rocky / Alma / Oracle Linux
#   - Fedora 39+
#   - Amazon Linux 2023
#
# Result:
#   - duo-unix / duo_unix installed from official Duo repository (pkg.duosecurity.com)
#   - /etc/duo/pam_duo.conf populated with your Duo application credentials
#   - /etc/pam.d/sshd patched to require Duo
#   - /etc/ssh/sshd_config: AuthenticationMethods publickey,keyboard-interactive:pam
#
# Login flow after install: SSH publickey  +  Duo Push/Passcode
# Password-only login is rejected.
#
# Usage:
#   sudo ./install-duo-ssh.sh                      # interactive menu (TTY) — guided setup
#   sudo kh-duo                                     # same, after --install-shortcut
#   sudo ./install-duo-ssh.sh --ikey X --skey Y --host Z
#   sudo DUO_IKEY=X DUO_SKEY=Y DUO_HOST=Z ./install-duo-ssh.sh --yes
#   sudo ./install-duo-ssh.sh --breakglass emergency   # exempt a user from Duo
#   sudo ./install-duo-ssh.sh --no-bypass-local         # disable default localhost bypass
#   sudo ./install-duo-ssh.sh --bypass-addr 10.0.0.0/8 # extra CIDRs to bypass Duo
#   sudo ./install-duo-ssh.sh --allow-password         # also allow password+Duo via PAM (publickey users still skip password)
#   sudo ./install-duo-ssh.sh --uninstall              # revert to stock SSH config
#   sudo ./install-duo-ssh.sh --no-menu                # force flag-driven mode even on TTY
#
# Maintenance:
#   sudo ./install-duo-ssh.sh --install-shortcut       # create /usr/local/bin/kh-duo → this script
#   sudo ./install-duo-ssh.sh --check-update           # compare local SCRIPT_VERSION to upstream
#   sudo ./install-duo-ssh.sh --self-update            # download latest from GitHub and replace
#   sudo ./install-duo-ssh.sh --version                # print version and exit
#
# Env vars:
#   DUO_IKEY / DUO_SKEY / DUO_HOST   Duo application credentials (skip prompts)
#   KH_DUO_UPDATE_URL                override upstream raw URL (forks / mirrors)
#   KH_DUO_SHORTCUT                  override shortcut path (default /usr/local/bin/kh-duo)
#
# Modes:
#   - No flags + TTY            → interactive menu (install / uninstall / update / shortcut)
#   - Any flag passed           → flag-driven, no menu (back-compatible automation)
#   - Non-TTY (pipe/Ansible)    → flag-driven; missing creds will fail-fast
#
# Safe to re-run: idempotent, creates timestamped backups, rolls back on error.

set -euo pipefail

### ─── Defaults / args ────────────────────────────────────────────────────
IKEY="${DUO_IKEY:-}"
SKEY="${DUO_SKEY:-}"
HOST="${DUO_HOST:-}"
BREAKGLASS_USER=""
BYPASS_LOCAL=1
BYPASS_ADDRS=""
ALLOW_PASSWORD=0
SKIP_KEY_CHECK=0
UNINSTALL=0
ASSUME_YES=0
NO_MENU=0
INTERACTIVE_FLAGS_USED=0
ACTION_CHECK_UPDATE=0
ACTION_SELF_UPDATE=0
ACTION_INSTALL_SHORTCUT=0

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/duo-install-backup-${TS}"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

# Self-update / shortcut — both URL and path can be overridden via env var
# (useful for forks, internal mirrors, or non-standard PATH layouts).
SCRIPT_VERSION="1.1.0"
SCRIPT_RAW_URL="${KH_DUO_UPDATE_URL:-https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh}"
SHORTCUT_PATH="${KH_DUO_SHORTCUT:-/usr/local/bin/kh-duo}"

# Minimum required Duo Unix version (CA bundle expiry on 2026-04-15 — see docs)
DUO_MIN_MAJOR=2
DUO_MIN_MINOR=1

SSHD_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
PAM_DUO_CONF="/etc/duo/pam_duo.conf"
LOGIN_DUO_CONF="/etc/duo/login_duo.conf"

# Detected at runtime
OS_FAMILY=""    # debian | rhel
PKG_MGR=""      # apt | yum | dnf

usage() {
    # Print every contiguous comment line at the top of the file (header
    # block).  Stops at the first non-comment line so adding code below
    # doesn't break --help.
    awk '/^#!/{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    INTERACTIVE_FLAGS_USED=1
    case "$1" in
        --ikey)         IKEY="$2"; shift 2 ;;
        --skey)         SKEY="$2"; shift 2 ;;
        --host)         HOST="$2"; shift 2 ;;
        --breakglass)   BREAKGLASS_USER="$2"; shift 2 ;;
        --bypass-local)   BYPASS_LOCAL=1; shift ;;
        --no-bypass-local) BYPASS_LOCAL=0; shift ;;
        --bypass-addr)    BYPASS_ADDRS="${BYPASS_ADDRS:+$BYPASS_ADDRS,}$2"; shift 2 ;;
        --allow-password) ALLOW_PASSWORD=1; shift ;;
        --skip-key-check) SKIP_KEY_CHECK=1; shift ;;
        --uninstall)    UNINSTALL=1; shift ;;
        --no-menu)      NO_MENU=1; shift ;;
        --check-update) ACTION_CHECK_UPDATE=1; shift ;;
        --self-update)  ACTION_SELF_UPDATE=1; shift ;;
        --install-shortcut) ACTION_INSTALL_SHORTCUT=1; shift ;;
        --version|-V)   printf 'install-duo-ssh.sh %s\n' "${SCRIPT_VERSION:-unknown}"; exit 0 ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        -h|--help)      usage 0 ;;
        *) echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done

### ─── UI helpers ─────────────────────────────────────────────────────────
log()   { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local prompt="$1"
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

### ─── Self-update / shortcut ────────────────────────────────────────────
ver_lt() {
    [[ "$1" == "$2" ]] && return 1
    local lower
    lower="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)"
    [[ "$lower" == "$1" ]]
}

# Echoes the SCRIPT_VERSION value found in the upstream file.  Empty/non-zero
# return means the network or parse failed — caller decides what to do.
fetch_remote_version() {
    command -v curl >/dev/null 2>&1 || return 1
    local tmp version
    tmp="$(mktemp)" || return 1
    if ! curl -fsSL --max-time 10 "$SCRIPT_RAW_URL" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    version="$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$tmp")"
    rm -f "$tmp"
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

# Downloads the upstream script, sanity-checks it, then atomically replaces
# the running script.  Backup of the previous version is kept alongside.
self_update() {
    command -v curl >/dev/null 2>&1 || die "curl is required for self-update"
    log "Downloading $SCRIPT_RAW_URL ..."
    local tmp
    tmp="$(mktemp)" || die "mktemp failed"
    if ! curl -fsSL --max-time 30 "$SCRIPT_RAW_URL" -o "$tmp"; then
        rm -f "$tmp"; die "Download failed"
    fi
    head -1 "$tmp" | grep -qE '^#!/(usr/bin/env[[:space:]]+bash|bin/bash)' || {
        rm -f "$tmp"; die "Downloaded file is not a bash script — refusing to install"
    }
    bash -n "$tmp" 2>/dev/null || {
        rm -f "$tmp"; die "Downloaded file failed syntax check — refusing to install"
    }
    local backup="${SCRIPT_PATH}.bak.${TS}"
    cp -a "$SCRIPT_PATH" "$backup" || die "Backup of current script failed"
    if ! install -m 755 "$tmp" "$SCRIPT_PATH" 2>/dev/null; then
        # /usr/bin/install may not exist on truly minimal images — fall back
        cp "$tmp" "$SCRIPT_PATH" && chmod 755 "$SCRIPT_PATH" || {
            rm -f "$tmp"; die "Install of new script failed"
        }
    fi
    rm -f "$tmp"
    ok "Self-update complete (backup: $backup)"
}

# Creates /usr/local/bin/kh-duo (or $KH_DUO_SHORTCUT) → $SCRIPT_PATH.
install_shortcut() {
    [[ -f "$SCRIPT_PATH" ]] || die "Cannot find script at '$SCRIPT_PATH'"
    case "$SCRIPT_PATH" in
        /tmp/*|/var/tmp/*)
            warn "Script lives at $SCRIPT_PATH — temp filesystems may be cleared on reboot,"
            warn "leaving '$SHORTCUT_PATH' broken.  Move the script somewhere persistent first"
            warn "(e.g. /usr/local/sbin/install-duo-ssh.sh) before installing the shortcut."
            confirm "Install shortcut anyway?" || return 0
            ;;
    esac
    if [[ -e "$SHORTCUT_PATH" || -L "$SHORTCUT_PATH" ]]; then
        local existing=""
        existing="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
        if [[ "$existing" == "$SCRIPT_PATH" ]]; then
            ok "Shortcut already installed: $SHORTCUT_PATH → $SCRIPT_PATH"
            return 0
        fi
        warn "$SHORTCUT_PATH already exists${existing:+ (currently → $existing)}"
        confirm "Replace it?" || return 0
        rm -f "$SHORTCUT_PATH"
    fi
    mkdir -p "$(dirname "$SHORTCUT_PATH")"
    ln -s "$SCRIPT_PATH" "$SHORTCUT_PATH" || die "Failed to create symlink at $SHORTCUT_PATH"
    ok "Shortcut installed: $SHORTCUT_PATH → $SCRIPT_PATH"
    ok "From now on, just run:  sudo $(basename "$SHORTCUT_PATH")"
}

### ─── Interactive menu ──────────────────────────────────────────────────
# Triggered when no flags are passed AND stdin is a TTY.  Sets the same
# globals that the flag parser sets, so the rest of the script doesn't
# care which path produced the configuration.
menu_should_run() {
    [[ $NO_MENU -eq 1 ]] && return 1
    [[ $INTERACTIVE_FLAGS_USED -eq 1 ]] && return 1
    [[ -t 0 && -t 1 ]] || return 1
    return 0
}

# read into the named variable, with a default and a one-line prompt.
menu_ask() {
    local var="$1" prompt="$2" default="${3:-}" ans=""
    if [[ -n "$default" ]]; then
        read -r -p "  $prompt [$default]: " ans
        ans="${ans:-$default}"
    else
        read -r -p "  $prompt: " ans
    fi
    printf -v "$var" '%s' "$ans"
}

menu_yes_no() {
    local prompt="$1" default="$2" ans=""
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    read -r -p "  $prompt $hint: " ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

menu_uninstall_flow() {
    UNINSTALL=1
    echo
    warn "Uninstall will:"
    echo "    - remove the Duo PAM stack from $PAM_SSHD"
    echo "    - remove AuthenticationMethods from $SSHD_CONFIG"
    echo "    - uninstall the duo-unix package and its repo entry"
    echo "    - restart sshd"
    echo
    confirm "Proceed with uninstall?" || { ok "Cancelled."; exit 0; }
}

menu_check_and_update() {
    log "Local version: $SCRIPT_VERSION"
    log "Checking $SCRIPT_RAW_URL ..."
    local remote
    if ! remote="$(fetch_remote_version)" || [[ -z "$remote" ]]; then
        warn "Could not fetch remote version (offline or upstream unreachable)"
        return 0
    fi
    if [[ "$remote" == "$SCRIPT_VERSION" ]]; then
        ok "You are on the latest version ($SCRIPT_VERSION)"
        return 0
    fi
    if ver_lt "$remote" "$SCRIPT_VERSION"; then
        ok "Local $SCRIPT_VERSION is ahead of upstream $remote (development build)"
        return 0
    fi
    warn "Update available: $SCRIPT_VERSION → $remote"
    confirm "Download and install now?" || { ok "Skipped."; return 0; }
    self_update
    ok "Re-run the script to use the new version: sudo $SCRIPT_PATH"
    exit 0
}

install_wizard() {
    # ── Step 1/5 — credentials ─────────────────────────────────────────
    echo
    log "Step 1/5 — Duo Application Credentials"
    echo "  Find these in: Duo Admin Panel → Applications → UNIX Application"
    if [[ -n "$IKEY" ]]; then
        ok "  ikey already provided (${IKEY:0:6}…) — keeping it"
    else
        menu_ask IKEY "Integration key (ikey)"
    fi
    if [[ -n "$SKEY" ]]; then
        ok "  skey already provided — keeping it"
    else
        read -r -s -p "  Secret key (skey): " SKEY; echo
    fi
    if [[ -n "$HOST" ]]; then
        ok "  host already provided ($HOST) — keeping it"
    else
        menu_ask HOST "API host (api-XXXXXXXX.duosecurity.com)"
    fi

    # ── Step 2/5 — login methods ───────────────────────────────────────
    echo
    log "Step 2/5 — Login Methods"
    echo "  Default: only publickey+Duo logins are allowed (password is rejected)."
    echo "  Allow password+Duo as a fallback for users without SSH keys?"
    if menu_yes_no "Allow password fallback?" "n"; then
        ALLOW_PASSWORD=1
    fi

    # ── Step 3/5 — localhost bypass ────────────────────────────────────
    echo
    log "Step 3/5 — Localhost Bypass"
    echo "  Skip Duo for connections from 127.0.0.0/8 and ::1"
    echo "  (recommended — lets local cron jobs and scripts SSH to themselves)."
    if menu_yes_no "Bypass Duo for localhost?" "y"; then
        BYPASS_LOCAL=1
    else
        BYPASS_LOCAL=0
    fi

    # ── Step 4/5 — extra bypass CIDRs ──────────────────────────────────
    echo
    log "Step 4/5 — Extra Bypass CIDRs (optional)"
    echo "  Comma-separated networks that skip Duo (e.g. 10.0.0.0/8,192.168.0.0/16)."
    echo "  Press Enter to skip."
    local extra=""
    menu_ask extra "Bypass CIDRs"
    [[ -n "$extra" ]] && BYPASS_ADDRS="$extra"

    # ── Step 5/5 — breakglass user ─────────────────────────────────────
    echo
    log "Step 5/5 — Breakglass User (optional)"
    echo "  A username that bypasses Duo entirely (publickey only)."
    echo "  For emergency recovery — use sparingly.  Press Enter to skip."
    local bg=""
    menu_ask bg "Breakglass username"
    [[ -n "$bg" ]] && BREAKGLASS_USER="$bg"

    # ── Confirmation summary ───────────────────────────────────────────
    echo
    cat <<EOF
─────────────────────────────────────────────────────────────────────────
  Summary
  -------
  Action:               Install / configure
  ikey:                 ${IKEY:0:8}…
  host:                 $HOST
  Password fallback:    $([[ $ALLOW_PASSWORD -eq 1 ]] && echo "yes (publickey OR password+Duo)" || echo "no  (publickey+Duo only)")
  Localhost bypass:     $([[ $BYPASS_LOCAL -eq 1 ]] && echo "yes (127.0.0.0/8, ::1)" || echo "no")
  Extra bypass CIDRs:   ${BYPASS_ADDRS:-(none)}
  Breakglass user:      ${BREAKGLASS_USER:-(none)}
─────────────────────────────────────────────────────────────────────────
EOF
    if ! confirm "Proceed with this configuration?"; then
        ok "Cancelled. No changes made."
        exit 0
    fi
    ASSUME_YES=1   # user already confirmed; don't ask again later
}

interactive_menu() {
    cat <<BANNER

╔═══════════════════════════════════════════════════════════════════════╗
║         Duo 2FA for SSH — Interactive Setup                          ║
╚═══════════════════════════════════════════════════════════════════════╝
  install-duo-ssh.sh v${SCRIPT_VERSION}   (use --no-menu or any flag to skip the wizard)
BANNER

    while true; do
        cat <<'EOF'

What would you like to do?
  1) Install / configure Duo 2FA  (default)
  2) Uninstall Duo 2FA
  3) Check for script updates
  4) Install / refresh the 'kh-duo' shortcut
  5) Quit without changes

EOF
        local action=""
        read -r -p "Choice [1]: " action
        case "${action:-1}" in
            1|"") install_wizard; return 0 ;;
            2)    menu_uninstall_flow; return 0 ;;
            3)    menu_check_and_update ;;
            4)    install_shortcut ;;
            5)    ok "No changes made."; exit 0 ;;
            *)    warn "Invalid choice '$action'" ;;
        esac
    done
}

### ─── OS detection ──────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root."
}

ensure_python3() {
    command -v python3 >/dev/null 2>&1 && return 0
    log "Installing python3 (required for safe PAM/sshd_config patching)"
    if [[ "$OS_FAMILY" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y python3 >/dev/null
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
        $PKG_MGR install -y python3 >/dev/null
    fi
    command -v python3 >/dev/null 2>&1 || die "python3 is required but could not be installed."
}

detect_os() {
    [[ -f /etc/os-release ]] || die "Cannot detect OS (no /etc/os-release)"
    . /etc/os-release

    case "${ID}" in
        debian|ubuntu|linuxmint|pop)
            OS_FAMILY="debian"
            PKG_MGR="apt"
            ;;
        rhel|centos|rocky|alma|ol)
            OS_FAMILY="rhel"
            PKG_MGR="$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)"
            ;;
        fedora)
            OS_FAMILY="rhel"
            PKG_MGR="dnf"
            ;;
        amzn)
            OS_FAMILY="rhel"
            PKG_MGR="$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)"
            ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*)
                    OS_FAMILY="debian"
                    PKG_MGR="apt"
                    ;;
                *rhel*|*centos*|*fedora*)
                    OS_FAMILY="rhel"
                    PKG_MGR="$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)"
                    ;;
                *)
                    die "Unsupported OS: ${PRETTY_NAME:-$ID}. Supported: Debian/Ubuntu, RHEL/CentOS/Fedora, Amazon Linux."
                    ;;
            esac
            ;;
    esac
    ok "OS: ${PRETTY_NAME:-$ID} (family=$OS_FAMILY, pkg=$PKG_MGR)"
}

### ─── Backup / rollback ─────────────────────────────────────────────────
backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$src" "$BACKUP_DIR/$(basename "$src")"
}

rollback() {
    err "Error encountered — rolling back from $BACKUP_DIR"
    [[ -d "$BACKUP_DIR" ]] || { err "No backup directory."; return; }
    [[ -f "$BACKUP_DIR/sshd_config" ]]  && cp -a "$BACKUP_DIR/sshd_config"  "$SSHD_CONFIG"
    [[ -f "$BACKUP_DIR/sshd" ]]         && cp -a "$BACKUP_DIR/sshd"         "$PAM_SSHD"
    [[ -f "$BACKUP_DIR/pam_duo.conf" ]] && cp -a "$BACKUP_DIR/pam_duo.conf" "$PAM_DUO_CONF"
    restart_sshd
    warn "Rolled back. Original config restored."
}

### ─── Helpers ───────────────────────────────────────────────────────────
find_pam_duo_so() {
    local candidates=(
        /lib64/security/pam_duo.so
        /lib/security/pam_duo.so
        /lib/x86_64-linux-gnu/security/pam_duo.so
        /usr/lib64/security/pam_duo.so
        /usr/lib/x86_64-linux-gnu/security/pam_duo.so
        /usr/lib/security/pam_duo.so
    )
    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

restart_sshd() {
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null
}

sshd_service_state() {
    systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo "unknown"
}

check_authorized_keys() {
    [[ $SKIP_KEY_CHECK -eq 1 ]] && { warn "Skipping authorized_keys check (--skip-key-check)"; return; }

    local found=0
    for home in /root "${SUDO_USER:+$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)}"; do
        [[ -z "$home" ]] && continue
        for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
            if [[ -s "$f" ]]; then
                ok "Found SSH key(s) in $f"
                found=1
            fi
        done
    done
    if [[ $found -eq 0 ]]; then
        err "No SSH authorized_keys found for root${SUDO_USER:+ or $SUDO_USER}."
        err "This config requires publickey auth. Add your key first, or re-run with --allow-password."
        [[ $ALLOW_PASSWORD -eq 1 ]] || die "Aborting to prevent lockout."
    fi
}

### ─── Package installation ──────────────────────────────────────────────
install_duo_apt() {
    log "Adding Duo official APT repository (pkg.duosecurity.com)"
    apt-get install -y -qq apt-transport-https curl gnupg >/dev/null 2>&1

    curl -sSL https://duo.com/DUO-GPG-PUBLIC-KEY.asc | gpg --dearmor -o /usr/share/keyrings/duo-archive-keyring.gpg

    . /etc/os-release
    local codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo stable)}"
    # Mint / Pop!_OS / elementary etc. ship their own codename (e.g. "vanessa")
    # which Duo's repo doesn't carry — fall back to the upstream Ubuntu/Debian one.
    case "${ID:-}" in
        linuxmint|pop|elementary|zorin|neon)
            codename="${UBUNTU_CODENAME:-${DEBIAN_CODENAME:-$codename}}"
            ;;
    esac

    local repo_url=""
    for distro in Debian Ubuntu; do
        local test_url="https://pkg.duosecurity.com/${distro}/dists/${codename}/Release"
        if curl -sSf -o /dev/null "$test_url" 2>/dev/null; then
            repo_url="https://pkg.duosecurity.com/${distro}"
            break
        fi
    done
    [[ -n "$repo_url" ]] || die "Could not find Duo repo for ${PRETTY_NAME:-$ID} ($codename)"

    echo "deb [signed-by=/usr/share/keyrings/duo-archive-keyring.gpg] ${repo_url} ${codename} main" \
        > /etc/apt/sources.list.d/duosecurity.list
    ok "Added Duo repo: ${repo_url} ${codename}"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y duo-unix
}

install_duo_yum() {
    log "Adding Duo official YUM repository (pkg.duosecurity.com)"

    . /etc/os-release
    local base_url=""
    case "${ID}" in
        fedora)
            base_url="https://pkg.duosecurity.com/Fedora/\$releasever/\$basearch"
            ;;
        amzn)
            base_url="https://pkg.duosecurity.com/AmazonLinux/\$releasever/\$basearch"
            ;;
        centos)
            if [[ "${VERSION_ID%%.*}" -ge 8 ]]; then
                base_url="https://pkg.duosecurity.com/CentOSStream/\$releasever/\$basearch"
            else
                base_url="https://pkg.duosecurity.com/CentOS/\$releasever/\$basearch"
            fi
            ;;
        *)
            # RHEL, Rocky, Alma, Oracle Linux
            base_url="https://pkg.duosecurity.com/CentOSStream/\$releasever/\$basearch"
            ;;
    esac

    cat > /etc/yum.repos.d/duosecurity.repo <<EOF
[duosecurity]
name=Duo Security Repository
baseurl=$base_url
enabled=1
gpgcheck=1
EOF

    rpm --import https://duo.com/DUO-GPG-PUBLIC-KEY.asc
    ok "Added Duo repo"

    $PKG_MGR install -y duo_unix
}

remove_old_packages() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        if dpkg -l libpam-duo 2>/dev/null | grep -q '^ii'; then
            warn "Removing outdated libpam-duo from distro repo"
            apt-get remove -y libpam-duo libduo3 >/dev/null 2>&1 || true
        fi
    fi
}

install_duo() {
    remove_old_packages
    if [[ "$OS_FAMILY" == "debian" ]]; then
        install_duo_apt
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
        install_duo_yum
    fi
}

is_duo_installed() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        dpkg -l duo-unix 2>/dev/null | grep -q '^ii'
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
        rpm -q duo_unix >/dev/null 2>&1
    fi
}

is_old_duo_installed() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        dpkg -l libpam-duo 2>/dev/null | grep -q '^ii'
    else
        return 1
    fi
}

get_duo_version() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        dpkg -l duo-unix 2>/dev/null | awk '/^ii/{print $3}'
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
        rpm -q --qf '%{VERSION}' duo_unix 2>/dev/null
    fi
}

# Returns 0 if installed Duo Unix is >= DUO_MIN_MAJOR.DUO_MIN_MINOR.
# Older builds bundle a CA root that Duo retired on 2026-04-15 — they cannot
# reach the Duo API any more, regardless of network/DNS health.
duo_version_ok() {
    local raw
    raw="$(get_duo_version)"
    [[ -n "$raw" ]] || return 1
    # Strip Debian/RPM release suffix (e.g. 2.0.4-1+deb11u1 → 2.0.4)
    local ver="${raw%%-*}"
    local major="${ver%%.*}"
    local rest="${ver#*.}"
    local minor="${rest%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    if (( major > DUO_MIN_MAJOR )); then return 0; fi
    if (( major == DUO_MIN_MAJOR && minor >= DUO_MIN_MINOR )); then return 0; fi
    return 1
}

### ─── PAM patching ──────────────────────────────────────────────────────
#
# Two distinct stacks depending on --allow-password:
#
#   default (publickey + Duo only):
#       auth  required  pam_duo.so
#     With AuthenticationMethods publickey,keyboard-interactive:pam this means
#     SSH validates the key, then PAM only checks Duo.  No password prompt.
#
#   --allow-password (also accept password+Duo via PAM):
#       auth  requisite  pam_unix.so nullok try_first_pass
#       auth  sufficient pam_duo.so
#       auth  required   pam_deny.so
#     With AuthenticationMethods 'publickey,keyboard-interactive:pam keyboard-interactive:pam'
#     keyless users can log in with password+Duo.  Publickey users get an
#     extra password prompt during the kbdint stage — accepted trade-off.
#
# The block is wrapped in begin/end markers so re-runs (including mode
# switches) replace it cleanly.
patch_pam() {
    local pam_duo_so="$1"
    local allow_password="$2"
    local os_family="$3"

    python3 - "$PAM_SSHD" "$pam_duo_so" "$allow_password" "$os_family" <<'PYEOF'
import sys, re, pathlib

path, pam_duo_so, allow_password, os_family = sys.argv[1:5]
allow_password = (allow_password == "1")
p = pathlib.Path(path)
text = p.read_text()

# 1. Strip any previously managed block (this script, current or older versions).
text = re.sub(
    r'(?:^# Disabled by install-duo-ssh\.sh[^\n]*\n)?'
    r'^# duo-stack-begin[^\n]*\n.*?^# duo-stack-end[^\n]*\n',
    '', text, flags=re.MULTILINE | re.DOTALL)

# 2. Strip leftover comments/lines that older versions of this script wrote
#    outside markers, so re-running doesn't accumulate duplicates.
text = re.sub(r'^# common-auth disabled by install-duo-ssh\.sh.*\n', '', text, flags=re.MULTILINE)
text = re.sub(r'^# Disabled by install-duo-ssh\.sh.*\n', '', text, flags=re.MULTILINE)
text = re.sub(r'^# Added by install-duo-ssh\.sh\s*\n', '', text, flags=re.MULTILINE)
text = re.sub(r'^\s*auth\s+(?:required|sufficient)\s+\S*pam_duo\.so\b.*\n', '', text, flags=re.MULTILINE)
text = re.sub(r'^\s*auth\s+requisite\s+pam_unix\.so\s+nullok\s+try_first_pass\s*\n', '', text, flags=re.MULTILINE)
text = re.sub(r'^\s*auth\s+required\s+pam_deny\.so\s*\n', '', text, flags=re.MULTILINE)

# 3. Build the new managed block.
if allow_password:
    new_block = (
        "# duo-stack-begin (managed by install-duo-ssh.sh — do not edit)\n"
        "auth  requisite  pam_unix.so nullok try_first_pass\n"
        f"auth  sufficient {pam_duo_so}\n"
        "auth  required   pam_deny.so\n"
        "# duo-stack-end\n"
    )
else:
    new_block = (
        "# duo-stack-begin (managed by install-duo-ssh.sh — do not edit)\n"
        f"auth  required   {pam_duo_so}\n"
        "# duo-stack-end\n"
    )

# 4. Locate the upstream auth source line and force it commented (we own auth).
if os_family == "debian":
    target_re = re.compile(r'^(\s*)(#?\s*)(@include\s+common-auth\s*)$')
else:
    target_re = re.compile(
        r'^(\s*)(#?\s*)(auth\s+(?:substack|include)\s+(?:password-auth|system-auth)\s*)$'
    )

lines = text.splitlines(keepends=True)
out, injected = [], False
for line in lines:
    m = target_re.match(line.rstrip("\n"))
    if m and not injected:
        indent, prefix, body = m.group(1), m.group(2), m.group(3)
        already_commented = "#" in prefix
        out.append("# Disabled by install-duo-ssh.sh (Duo-managed auth stack)\n")
        if already_commented:
            out.append(line if line.endswith("\n") else line + "\n")
        else:
            out.append(f"{indent}#{body}\n")
        out.append(new_block)
        injected = True
    else:
        out.append(line)

if not injected:
    if out and not out[-1].endswith("\n"):
        out.append("\n")
    out.append("\n")
    out.append(new_block)

p.write_text("".join(out))
PYEOF
    if [[ "$allow_password" == "1" ]]; then
        ok "Patched $PAM_SSHD (publickey+Duo OR password+Duo)"
    else
        ok "Patched $PAM_SSHD (publickey+Duo only)"
    fi
}

### ─── Uninstall path ─────────────────────────────────────────────────────
do_uninstall() {
    log "Reverting SSH/Duo configuration"
    backup_file "$SSHD_CONFIG"
    backup_file "$PAM_SSHD"

    # Remove AuthenticationMethods + Duo banner from sshd_config
    python3 - "$SSHD_CONFIG" <<'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
text = re.sub(
    r'\n*# === Duo 2FA for SSH.*?AuthenticationMethods\s+publickey,keyboard-interactive:pam[^\n]*\n',
    '\n', text, flags=re.DOTALL)
text = re.sub(r'^\s*AuthenticationMethods\s+publickey,keyboard-interactive:pam\b[^\n]*\n',
              '', text, flags=re.MULTILINE)
p.write_text(text)
PYEOF

    # Restore PAM config
    python3 - "$PAM_SSHD" <<'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
# Drop the entire managed block (including any preceding "Disabled by" comment).
text = re.sub(
    r'(?:^# Disabled by install-duo-ssh\.sh[^\n]*\n)?'
    r'^# duo-stack-begin[^\n]*\n.*?^# duo-stack-end[^\n]*\n',
    '', text, flags=re.MULTILINE | re.DOTALL)

lines = text.splitlines(keepends=True)
out = []
for line in lines:
    if re.search(r'pam_duo\.so', line):
        continue
    if re.search(r'install-duo-ssh\.sh', line):
        continue
    # Debian: uncomment common-auth
    if re.match(r'^\s*#\s*@include\s+common-auth', line):
        out.append(re.sub(r'^\s*#\s*', '', line))
        continue
    # RHEL: uncomment password-auth/system-auth
    if re.match(r'^\s*#\s*auth\s+(substack|include)\s+(password-auth|system-auth)', line):
        out.append(re.sub(r'^\s*#\s*', '', line))
        continue
    # Remove injected pam_unix requisite and pam_deny lines
    if re.match(r'^\s*auth\s+requisite\s+pam_unix\.so\s+nullok\s+try_first_pass\s*$', line):
        continue
    if re.match(r'^\s*auth\s+required\s+pam_deny\.so\s*$', line):
        continue
    out.append(line)
p.write_text("".join(out))
PYEOF

    # Remove packages and repos
    if [[ "$OS_FAMILY" == "debian" ]]; then
        dpkg -l duo-unix 2>/dev/null | grep -q '^ii' && apt-get remove -y duo-unix >/dev/null 2>&1 || true
        dpkg -l libpam-duo 2>/dev/null | grep -q '^ii' && apt-get remove -y libpam-duo libduo3 >/dev/null 2>&1 || true
        rm -f /etc/apt/sources.list.d/duosecurity.list
        rm -f /usr/share/keyrings/duo-archive-keyring.gpg
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
        rpm -q duo_unix >/dev/null 2>&1 && $PKG_MGR remove -y duo_unix >/dev/null 2>&1 || true
        rm -f /etc/yum.repos.d/duosecurity.repo
    fi

    sshd -t
    restart_sshd
    ok "Uninstalled. Duo no longer enforced on SSH."
    exit 0
}

### ─── Patch sshd_config ─────────────────────────────────────────────────
patch_sshd_config() {
    log "Patching $SSHD_CONFIG"

    # KbdInteractiveAuthentication / ChallengeResponseAuthentication
    if grep -qE '^\s*#?\s*KbdInteractiveAuthentication\b' "$SSHD_CONFIG"; then
        if ! grep -qE '^\s*KbdInteractiveAuthentication\s+yes\b' "$SSHD_CONFIG"; then
            sed -i -E 's|^\s*#?\s*KbdInteractiveAuthentication\s+.*|KbdInteractiveAuthentication yes|' "$SSHD_CONFIG"
            ok "Set KbdInteractiveAuthentication yes"
        fi
    elif grep -qE '^\s*#?\s*ChallengeResponseAuthentication\b' "$SSHD_CONFIG"; then
        if ! grep -qE '^\s*ChallengeResponseAuthentication\s+yes\b' "$SSHD_CONFIG"; then
            sed -i -E 's|^\s*#?\s*ChallengeResponseAuthentication\s+.*|ChallengeResponseAuthentication yes|' "$SSHD_CONFIG"
            ok "Set ChallengeResponseAuthentication yes"
        fi
    else
        printf '\nKbdInteractiveAuthentication yes\n' >> "$SSHD_CONFIG"
        ok "Set KbdInteractiveAuthentication yes"
    fi

    # UsePAM yes
    if ! grep -qE '^\s*UsePAM\s+yes\b' "$SSHD_CONFIG"; then
        if grep -qE '^\s*#?\s*UsePAM\b' "$SSHD_CONFIG"; then
            sed -i -E 's|^\s*#?\s*UsePAM\s+.*|UsePAM yes|' "$SSHD_CONFIG"
        else
            printf 'UsePAM yes\n' >> "$SSHD_CONFIG"
        fi
        ok "Set UsePAM yes"
    fi

    # UseDNS no — Duo docs require this alongside UsePAM/KbdInteractive to
    # avoid reverse-DNS hangs that would otherwise stall the kbdint exchange.
    if ! grep -qE '^\s*UseDNS\s+no\b' "$SSHD_CONFIG"; then
        if grep -qE '^\s*#?\s*UseDNS\b' "$SSHD_CONFIG"; then
            sed -i -E 's|^\s*#?\s*UseDNS\s+.*|UseDNS no|' "$SSHD_CONFIG"
        else
            printf 'UseDNS no\n' >> "$SSHD_CONFIG"
        fi
        ok "Set UseDNS no"
    fi

    # PasswordAuthentication — auto-managed by AuthenticationMethods
    local pw_val="no"
    [[ $ALLOW_PASSWORD -eq 1 ]] && pw_val="yes"
    if grep -qE '^\s*#?\s*PasswordAuthentication\b' "$SSHD_CONFIG"; then
        sed -i -E "s|^\s*#?\s*PasswordAuthentication\s+.*|PasswordAuthentication $pw_val|" "$SSHD_CONFIG"
    else
        printf "PasswordAuthentication $pw_val\n" >> "$SSHD_CONFIG"
    fi
    ok "Set PasswordAuthentication $pw_val (managed by --allow-password)"

    # Fedora 33+: fix /etc/ssh/sshd_config.d/50-redhat.conf
    local redhat_conf="/etc/ssh/sshd_config.d/50-redhat.conf"
    if [[ -f "$redhat_conf" ]]; then
        if grep -qE '^\s*ChallengeResponseAuthentication\s+no' "$redhat_conf"; then
            backup_file "$redhat_conf"
            sed -i -E 's|^\s*ChallengeResponseAuthentication\s+no|#ChallengeResponseAuthentication no|' "$redhat_conf"
            ok "Disabled ChallengeResponseAuthentication=no in $redhat_conf"
        fi
    fi

    # Clean up old ForceCommand login_duo / stray AuthenticationMethods
    python3 - "$SSHD_CONFIG" <<'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
out, i = [], 0
while i < len(lines):
    line = lines[i]
    if re.match(r'^\s*Match\s+', line):
        block = [line]; j = i + 1; has_login_duo = False
        while j < len(lines):
            nxt = lines[j]
            if re.match(r'^\s*Match\b', nxt): break
            if re.match(r'^\S', nxt) and not re.match(r'^\s*#', nxt) and nxt.strip():
                break
            block.append(nxt)
            if re.search(r'ForceCommand\s+/usr/sbin/login_duo', nxt):
                has_login_duo = True
            j += 1
        if has_login_duo:
            i = j; continue
        out.extend(block); i = j; continue
    if re.search(r'^\s*ForceCommand\s+/usr/sbin/login_duo', line):
        i += 1; continue
    if re.search(r'Duo 2FA for SSH', line):
        i += 1; continue
    if re.match(r'^\s*AuthenticationMethods\b', line):
        i += 1; continue
    out.append(line); i += 1
p.write_text("".join(out))
PYEOF

    # Add AuthenticationMethods
    #   Default:           publickey + Duo (PAM stack = pam_duo only)
    #   --allow-password:  publickey path runs the full pam_unix+pam_duo stack
    #                      (so publickey users see one password+Duo prompt set);
    #                      the second alternative `keyboard-interactive:pam`
    #                      lets keyless users authenticate via password+Duo.
    #                      We avoid `password,keyboard-interactive:pam` because
    #                      it would invoke PAM twice and double-prompt the user.
    local auth_line
    if [[ $ALLOW_PASSWORD -eq 1 ]]; then
        auth_line='AuthenticationMethods publickey,keyboard-interactive:pam keyboard-interactive:pam'
    else
        auth_line='AuthenticationMethods publickey,keyboard-interactive:pam'
    fi

    {
        echo ""
        echo "# === Duo 2FA for SSH (PAM mode, added by install-duo-ssh.sh) ==="
        echo "$auth_line"

        # Bypass Duo for localhost / self
        if [[ $BYPASS_LOCAL -eq 1 ]]; then
            local local_addrs="127.0.0.0/8,::1"
            [[ -n "$BYPASS_ADDRS" ]] && local_addrs="${local_addrs},${BYPASS_ADDRS}"

            echo ""
            echo "# Bypass Duo for localhost (publickey-only)"
            echo "Match Address $local_addrs"
            echo "    AuthenticationMethods publickey"
        elif [[ -n "$BYPASS_ADDRS" ]]; then
            echo ""
            echo "# Bypass Duo for specified addresses (publickey-only)"
            echo "Match Address $BYPASS_ADDRS"
            echo "    AuthenticationMethods publickey"
        fi

        if [[ -n "$BREAKGLASS_USER" ]]; then
            echo ""
            echo "# Emergency access: bypass Duo for this user (publickey-only)"
            echo "Match User $BREAKGLASS_USER"
            echo "    AuthenticationMethods publickey"
        fi
    } >> "$SSHD_CONFIG"
    ok "Added AuthenticationMethods"
    [[ $BYPASS_LOCAL -eq 1 ]] && ok "Bypass Duo for localhost and self connections"
    [[ -n "$BYPASS_ADDRS" ]] && ok "Bypass Duo for: $BYPASS_ADDRS"
    [[ -n "$BREAKGLASS_USER" ]] && ok "Breakglass user: $BREAKGLASS_USER (bypasses Duo)"
}

### ─── SELinux (RHEL only) ───────────────────────────────────────────────
fix_selinux() {
    [[ "$OS_FAMILY" != "rhel" ]] && return
    command -v getenforce >/dev/null 2>&1 || return
    [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || return

    log "SELinux is enforcing — checking Duo policy"
    if command -v semodule >/dev/null 2>&1; then
        if ! semodule -l 2>/dev/null | grep -q authlogin_duo; then
            warn "SELinux: authlogin_duo module not found."
            warn "If Duo fails, build from source and run: sudo make -C pam_duo semodule-install"
        else
            ok "SELinux: authlogin_duo module is loaded"
        fi
    fi
}

### ─── Main ───────────────────────────────────────────────────────────────
require_root
detect_os

# Quick-exit action flags — these don't touch SSH/PAM at all, so they bypass
# the heavier ensure_python3 / install / patch path entirely.
if [[ $ACTION_CHECK_UPDATE -eq 1 ]]; then
    log "Local version: $SCRIPT_VERSION"
    log "Checking $SCRIPT_RAW_URL ..."
    remote_ver="$(fetch_remote_version)" || { warn "Could not fetch remote version (offline?)"; exit 1; }
    if [[ "$remote_ver" == "$SCRIPT_VERSION" ]]; then
        ok "You are on the latest version ($SCRIPT_VERSION)"
    elif ver_lt "$remote_ver" "$SCRIPT_VERSION"; then
        ok "Local $SCRIPT_VERSION is ahead of upstream $remote_ver (development build)"
    else
        warn "Update available: $SCRIPT_VERSION → $remote_ver  (run --self-update to apply)"
    fi
    exit 0
fi
if [[ $ACTION_SELF_UPDATE -eq 1 ]]; then
    self_update
    ok "Done. Re-run: sudo $SCRIPT_PATH"
    exit 0
fi
if [[ $ACTION_INSTALL_SHORTCUT -eq 1 ]]; then
    install_shortcut
    exit 0
fi

ensure_python3

if menu_should_run; then
    interactive_menu
fi

[[ $UNINSTALL -eq 1 ]] && do_uninstall

check_authorized_keys

### 1. Install duo-unix from official Duo repository
if is_old_duo_installed; then
    warn "Found outdated distro-packaged Duo — upgrading to official duo-unix"
    install_duo
elif ! is_duo_installed; then
    install_duo
elif [[ -z "$(find_pam_duo_so || true)" ]]; then
    warn "Duo package installed but pam_duo.so not found — reinstalling"
    install_duo
elif ! duo_version_ok; then
    warn "Installed duo-unix $(get_duo_version) is older than ${DUO_MIN_MAJOR}.${DUO_MIN_MINOR}.0"
    warn "(Duo retired the bundled CA on 2026-04-15; older builds can't reach the API.) Upgrading..."
    install_duo
    duo_version_ok || die "Upgrade failed — installed version $(get_duo_version) is still < ${DUO_MIN_MAJOR}.${DUO_MIN_MINOR}.0"
else
    ok "duo-unix already installed: $(get_duo_version)"
fi
PAM_DUO_SO="$(find_pam_duo_so)" || die "pam_duo.so not found after install"
ok "Using pam_duo.so at: $PAM_DUO_SO"

### 2. Collect credentials
if [[ -z "$IKEY" || -z "$SKEY" || -z "$HOST" ]]; then
    if [[ -f "$LOGIN_DUO_CONF" ]]; then
        [[ -z "$IKEY" ]] && IKEY="$(awk -F'= *' '/^[[:space:]]*ikey/{print $2; exit}' "$LOGIN_DUO_CONF")"
        [[ -z "$SKEY" ]] && SKEY="$(awk -F'= *' '/^[[:space:]]*skey/{print $2; exit}' "$LOGIN_DUO_CONF")"
        [[ -z "$HOST" ]] && HOST="$(awk -F'= *' '/^[[:space:]]*host/{print $2; exit}' "$LOGIN_DUO_CONF")"
        [[ -n "$IKEY" ]] && ok "Found credentials in $LOGIN_DUO_CONF"
    fi
    if [[ -f "$PAM_DUO_CONF" ]]; then
        [[ -z "$IKEY" ]] && IKEY="$(awk -F'= *' '/^[[:space:]]*ikey/{print $2; exit}' "$PAM_DUO_CONF")"
        [[ -z "$SKEY" ]] && SKEY="$(awk -F'= *' '/^[[:space:]]*skey/{print $2; exit}' "$PAM_DUO_CONF")"
        [[ -z "$HOST" ]] && HOST="$(awk -F'= *' '/^[[:space:]]*host/{print $2; exit}' "$PAM_DUO_CONF")"
        [[ -n "$IKEY" ]] && ok "Found credentials in $PAM_DUO_CONF"
    fi
fi

if [[ -z "$IKEY" || -z "$SKEY" || -z "$HOST" ]]; then
    echo
    echo "Enter Duo application credentials (from the Duo Admin panel -> Applications -> UNIX)"
    [[ -z "$IKEY" ]] && { read -r -p "  Integration key (ikey): " IKEY; }
    [[ -z "$SKEY" ]] && { read -r -s -p "  Secret key (skey): " SKEY; echo; }
    [[ -z "$HOST" ]] && { read -r -p "  API host (e.g. api-xxxxxxxx.duosecurity.com): " HOST; }
fi

[[ -n "$IKEY" && -n "$SKEY" && -n "$HOST" ]] || die "ikey/skey/host all required."

### 3. Backup everything we're about to touch
log "Backing up to $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
backup_file "$SSHD_CONFIG"
backup_file "$PAM_SSHD"
backup_file "$PAM_DUO_CONF"
ok "Backups saved"

trap 'rollback' ERR

### 4. Write /etc/duo/pam_duo.conf
log "Writing $PAM_DUO_CONF"
mkdir -p "$(dirname "$PAM_DUO_CONF")"
cat > "$PAM_DUO_CONF" <<EOF
[duo]
ikey = $IKEY
skey = $SKEY
host = $HOST
failmode = safe
pushinfo = yes
autopush = no
EOF
chmod 600 "$PAM_DUO_CONF"
chown root:root "$PAM_DUO_CONF"
ok "Credentials written"

### 5. Patch /etc/pam.d/sshd
log "Patching $PAM_SSHD"
patch_pam "$PAM_DUO_SO" "$ALLOW_PASSWORD" "$OS_FAMILY"

### 6. Patch /etc/ssh/sshd_config
patch_sshd_config

### 7. SELinux check (RHEL only)
fix_selinux

### 8. Validate and restart
log "Validating sshd config (sshd -t)"
sshd -t
ok "Config syntax OK"

log "Restarting SSH"
restart_sshd
STATE="$(sshd_service_state)"
[[ "$STATE" == "active" ]] || die "SSH service not active after restart (state: $STATE)"
ok "SSH is $STATE"

trap - ERR

### 9. Final output
cat <<EOF

╔═══════════════════════════════════════════════════════════════════════╗
║  Duo 2FA for SSH — installation complete                            ║
╠═══════════════════════════════════════════════════════════════════════╣
║  OS:                 $(printf '%-48s' "${PRETTY_NAME:-$ID}")║
║  Duo version:        $(printf '%-48s' "$(get_duo_version)")║
║  pam_duo.so:         $(printf '%-48s' "$PAM_DUO_SO")║
║  Login requirement:  $(printf '%-48s' "publickey$( [[ $ALLOW_PASSWORD -eq 1 ]] && echo ' OR password') + Duo")║
$( [[ -n "$BREAKGLASS_USER" ]] && printf '║  Breakglass user:    %-48s║\n' "$BREAKGLASS_USER (publickey only)")
║  Backups:            $(printf '%-48s' "$BACKUP_DIR")║
║                                                                     ║
║  DO NOT CLOSE THIS SESSION YET.                                     ║
║  Open a NEW terminal and test SSH login first.                      ║
║                                                                     ║
║  To uninstall:                                                      ║
║    sudo $SCRIPT_PATH --uninstall
╚═══════════════════════════════════════════════════════════════════════╝

EOF
