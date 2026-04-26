#!/usr/bin/env bash
#
# One-shot installer: SSH + Duo 2FA (PAM-based) on Debian/Ubuntu systems.
#
# Result:
#   - duo-unix installed from official Duo repository (pkg.duosecurity.com)
#   - /etc/duo/pam_duo.conf populated with your Duo application credentials
#   - /etc/pam.d/sshd patched to require Duo (common-auth disabled)
#   - /etc/ssh/sshd_config: AuthenticationMethods publickey,keyboard-interactive:pam
#
# Login flow after install: SSH publickey  +  Duo Push/Passcode
# Password-only login is rejected.
#
# Usage:
#   sudo ./install-duo-ssh.sh                      # interactive: prompts for creds
#   sudo ./install-duo-ssh.sh --ikey X --skey Y --host Z
#   sudo DUO_IKEY=X DUO_SKEY=Y DUO_HOST=Z ./install-duo-ssh.sh
#   sudo ./install-duo-ssh.sh --breakglass emergency   # exempt a user from Duo
#   sudo ./install-duo-ssh.sh --allow-password         # also allow password + Duo
#   sudo ./install-duo-ssh.sh --uninstall              # revert to stock SSH config
#
# Safe to re-run: idempotent, creates timestamped backups, rolls back on error.

set -euo pipefail

### ─── Defaults / args ────────────────────────────────────────────────────
IKEY="${DUO_IKEY:-}"
SKEY="${DUO_SKEY:-}"
HOST="${DUO_HOST:-}"
BREAKGLASS_USER=""
ALLOW_PASSWORD=0
SKIP_KEY_CHECK=0
UNINSTALL=0
ASSUME_YES=0

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/duo-install-backup-${TS}"

SSHD_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
PAM_DUO_CONF="/etc/duo/pam_duo.conf"
LOGIN_DUO_CONF="/etc/duo/login_duo.conf"

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ikey)         IKEY="$2"; shift 2 ;;
        --skey)         SKEY="$2"; shift 2 ;;
        --host)         HOST="$2"; shift 2 ;;
        --breakglass)   BREAKGLASS_USER="$2"; shift 2 ;;
        --allow-password) ALLOW_PASSWORD=1; shift ;;
        --skip-key-check) SKIP_KEY_CHECK=1; shift ;;
        --uninstall)    UNINSTALL=1; shift ;;
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
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    warn "Rolled back. Original config restored."
}

### ─── Helpers ───────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root."
}

detect_os() {
    [[ -f /etc/os-release ]] || die "Cannot detect OS (no /etc/os-release)"
    . /etc/os-release
    case "${ID_LIKE:-$ID}" in
        *debian*|*ubuntu*) ;;
        *) die "Only Debian/Ubuntu supported. Detected: ${PRETTY_NAME:-unknown}" ;;
    esac
    ok "OS: ${PRETTY_NAME:-$ID}"
}

find_pam_duo_so() {
    local candidates=(
        /lib/x86_64-linux-gnu/security/pam_duo.so
        /usr/lib/x86_64-linux-gnu/security/pam_duo.so
        /lib64/security/pam_duo.so
        /usr/lib64/security/pam_duo.so
        /lib/security/pam_duo.so
        /usr/lib/security/pam_duo.so
    )
    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

check_authorized_keys() {
    [[ $SKIP_KEY_CHECK -eq 1 ]] && { warn "Skipping authorized_keys check (--skip-key-check)"; return; }

    local found=0
    # Check root and the invoking user's authorized_keys
    for home in /root "${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"; do
        [[ -z "$home" ]] && continue
        for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
            if [[ -s "$f" ]]; then
                ok "Found SSH key(s) in $f"
                found=1
            fi
        done
    done
    if [[ $found -eq 0 ]]; then
        err "No SSH authorized_keys found for root or $SUDO_USER."
        err "This config requires publickey auth. Add your key first, or re-run with --allow-password."
        [[ $ALLOW_PASSWORD -eq 1 ]] || die "Aborting to prevent lockout."
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
# Strip our block (banner + AuthenticationMethods) and any stray AuthenticationMethods we added
text = re.sub(
    r'\n*# === Duo 2FA for SSH.*?AuthenticationMethods\s+publickey,keyboard-interactive:pam[^\n]*\n',
    '\n', text, flags=re.DOTALL)
text = re.sub(r'^\s*AuthenticationMethods\s+publickey,keyboard-interactive:pam\b[^\n]*\n',
              '', text, flags=re.MULTILINE)
p.write_text(text)
PYEOF

    # Restore @include common-auth; remove pam_duo lines
    python3 - "$PAM_SSHD" <<'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
out = []
for line in lines:
    if re.search(r'pam_duo\.so', line):
        continue
    if re.match(r'^\s*#\s*@include\s+common-auth', line):
        out.append(re.sub(r'^\s*#\s*', '', line))
        continue
    if re.search(r'common-auth disabled', line):
        continue
    out.append(line)
p.write_text("".join(out))
PYEOF

    # Remove Duo packages
    if dpkg -l duo-unix 2>/dev/null | grep -q '^ii'; then
        log "Removing duo-unix package"
        apt-get remove -y duo-unix >/dev/null 2>&1 || true
    fi
    if dpkg -l libpam-duo 2>/dev/null | grep -q '^ii'; then
        log "Removing libpam-duo package"
        apt-get remove -y libpam-duo libduo3 >/dev/null 2>&1 || true
    fi
    # Remove Duo repo
    rm -f /etc/apt/sources.list.d/duosecurity.list
    rm -f /usr/share/keyrings/duo-archive-keyring.gpg

    sshd -t
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    ok "Uninstalled. Duo no longer enforced on SSH."
    exit 0
}

### ─── Main ───────────────────────────────────────────────────────────────
require_root
detect_os

[[ $UNINSTALL -eq 1 ]] && do_uninstall

check_authorized_keys

### 1. Install duo-unix from official Duo repository
install_duo_repo() {
    log "Adding Duo official APT repository (pkg.duosecurity.com)"
    apt-get install -y -qq apt-transport-https curl gnupg >/dev/null 2>&1

    # Add Duo GPG key
    curl -sSL https://duo.com/DUO-GPG-PUBLIC-KEY.asc | gpg --dearmor -o /usr/share/keyrings/duo-archive-keyring.gpg

    # Determine distro codename
    . /etc/os-release
    local codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo stable)}"

    # Add repo (try Debian first, fall back to Ubuntu)
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
}

if [[ -z "$(find_pam_duo_so || true)" ]]; then
    # Remove old Debian-packaged libpam-duo if present (outdated, causes HTTP 403)
    if dpkg -l libpam-duo 2>/dev/null | grep -q '^ii'; then
        warn "Removing outdated libpam-duo from Debian repo"
        apt-get remove -y libpam-duo libduo3 >/dev/null 2>&1 || true
    fi
    install_duo_repo
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y duo-unix
elif dpkg -l libpam-duo 2>/dev/null | grep -q '^ii'; then
    # Old package installed — upgrade to official duo-unix
    warn "Found outdated libpam-duo — upgrading to official duo-unix"
    apt-get remove -y libpam-duo libduo3 >/dev/null 2>&1 || true
    install_duo_repo
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y duo-unix
elif ! dpkg -l duo-unix 2>/dev/null | grep -q '^ii'; then
    install_duo_repo
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y duo-unix
else
    ok "duo-unix already installed: $(dpkg -l duo-unix | awk '/^ii/{print $3}')"
fi
PAM_DUO_SO="$(find_pam_duo_so)" || die "pam_duo.so not found after install"
ok "Using pam_duo.so at: $PAM_DUO_SO"

### 2. Collect credentials
if [[ -z "$IKEY" || -z "$SKEY" || -z "$HOST" ]]; then
    # Try to read from an existing login_duo.conf
    if [[ -f "$LOGIN_DUO_CONF" ]]; then
        [[ -z "$IKEY" ]] && IKEY="$(awk -F'= *' '/^[[:space:]]*ikey/{print $2; exit}' "$LOGIN_DUO_CONF")"
        [[ -z "$SKEY" ]] && SKEY="$(awk -F'= *' '/^[[:space:]]*skey/{print $2; exit}' "$LOGIN_DUO_CONF")"
        [[ -z "$HOST" ]] && HOST="$(awk -F'= *' '/^[[:space:]]*host/{print $2; exit}' "$LOGIN_DUO_CONF")"
        [[ -n "$IKEY" ]] && ok "Found credentials in $LOGIN_DUO_CONF"
    fi
fi

if [[ -z "$IKEY" || -z "$SKEY" || -z "$HOST" ]]; then
    echo
    echo "Enter Duo application credentials (from the Duo Admin panel → Applications → UNIX)"
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

# Enable error trap only AFTER backups are in place
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
if grep -q "pam_duo.so" "$PAM_SSHD"; then
    ok "pam_duo.so already present"
else
    python3 - "$PAM_SSHD" "$PAM_DUO_SO" <<'PYEOF'
import sys, re, pathlib
path, pam_duo_so = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
lines = p.read_text().splitlines(keepends=True)
out, injected = [], False
for line in lines:
    if not injected and re.match(r'^\s*@include\s+common-auth\s*$', line):
        out.append("# common-auth disabled by install-duo-ssh.sh (Duo-only auth stack)\n")
        out.append("#" + line)
        out.append(f"auth  required {pam_duo_so}\n")
        injected = True
        continue
    out.append(line)
if not injected:
    out.append(f"\n# Added by install-duo-ssh.sh\nauth  required {pam_duo_so}\n")
p.write_text("".join(out))
PYEOF
    ok "Patched $PAM_SSHD"
fi

### 6. Patch /etc/ssh/sshd_config
log "Patching $SSHD_CONFIG"

# 6a. KbdInteractiveAuthentication yes
if ! grep -qE '^\s*KbdInteractiveAuthentication\s+yes\b' "$SSHD_CONFIG"; then
    if grep -qE '^\s*#?\s*KbdInteractiveAuthentication\b' "$SSHD_CONFIG"; then
        sed -i -E 's|^\s*#?\s*KbdInteractiveAuthentication\s+.*|KbdInteractiveAuthentication yes|' "$SSHD_CONFIG"
    else
        printf '\nKbdInteractiveAuthentication yes\n' >> "$SSHD_CONFIG"
    fi
    ok "Set KbdInteractiveAuthentication yes"
fi

# 6b. UsePAM yes
if ! grep -qE '^\s*UsePAM\s+yes\b' "$SSHD_CONFIG"; then
    if grep -qE '^\s*#?\s*UsePAM\b' "$SSHD_CONFIG"; then
        sed -i -E 's|^\s*#?\s*UsePAM\s+.*|UsePAM yes|' "$SSHD_CONFIG"
    else
        printf 'UsePAM yes\n' >> "$SSHD_CONFIG"
    fi
    ok "Set UsePAM yes"
fi

# 6c. Remove any old ForceCommand login_duo Match block + stray AuthenticationMethods
python3 - "$SSHD_CONFIG" <<'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
out, i = [], 0
while i < len(lines):
    line = lines[i]
    # Drop Match blocks that contain ForceCommand login_duo
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
    # Strip stray ForceCommand login_duo lines
    if re.search(r'^\s*ForceCommand\s+/usr/sbin/login_duo', line):
        i += 1; continue
    # Strip old Duo banners
    if re.search(r'Duo 2FA for SSH', line):
        i += 1; continue
    # Strip previous AuthenticationMethods lines (we'll re-add ours)
    if re.match(r'^\s*AuthenticationMethods\b', line):
        i += 1; continue
    out.append(line); i += 1
p.write_text("".join(out))
PYEOF

# 6d. Build our AuthenticationMethods line
if [[ $ALLOW_PASSWORD -eq 1 ]]; then
    AUTH_LINE='AuthenticationMethods publickey,keyboard-interactive:pam password,keyboard-interactive:pam'
else
    AUTH_LINE='AuthenticationMethods publickey,keyboard-interactive:pam'
fi

{
    echo ""
    echo "# === Duo 2FA for SSH (PAM mode, added by install-duo-ssh.sh) ==="
    echo "$AUTH_LINE"
    if [[ -n "$BREAKGLASS_USER" ]]; then
        echo ""
        echo "# Emergency access: bypass Duo for this user (publickey-only)"
        echo "Match User $BREAKGLASS_USER"
        echo "    AuthenticationMethods publickey"
    fi
} >> "$SSHD_CONFIG"
ok "Added AuthenticationMethods"
[[ -n "$BREAKGLASS_USER" ]] && ok "Breakglass user: $BREAKGLASS_USER (bypasses Duo)"

### 7. Validate and restart
log "Validating sshd config (sshd -t)"
sshd -t
ok "Config syntax OK"

log "Restarting SSH"
systemctl restart ssh 2>/dev/null || systemctl restart sshd
STATE="$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd)"
[[ "$STATE" == "active" ]] || die "SSH service not active after restart"
ok "SSH is $STATE"

trap - ERR

### 8. Final output
cat <<EOF

╔═══════════════════════════════════════════════════════════════════════╗
║  Duo 2FA for SSH — installation complete                               ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Login requirement:  publickey $( [[ $ALLOW_PASSWORD -eq 1 ]] && echo 'OR password' ) + Duo (keyboard-interactive) ║
$( [[ -n "$BREAKGLASS_USER" ]] && printf '║  Breakglass user:    %-48s ║\n' "$BREAKGLASS_USER (publickey only — no Duo)" )
║  Backups:            $(printf '%-48s' "$BACKUP_DIR") ║
║                                                                        ║
║  ⚠  DO NOT CLOSE THIS SESSION YET.                                     ║
║     Open a NEW terminal and test SSH login first.                      ║
║                                                                        ║
║  To uninstall:                                                         ║
║    sudo $0 --uninstall
╚═══════════════════════════════════════════════════════════════════════╝

EOF
