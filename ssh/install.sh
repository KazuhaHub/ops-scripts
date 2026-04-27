#!/usr/bin/env bash
#
# Kazuha Hub Duo SSH bootstrap installer.
#
# One-liners (run from any user account that can `sudo`):
#
#   # Interactive: download, install /usr/local/sbin/install-duo-ssh.sh and the
#   # `kh-duo` shortcut, then drop you back at the prompt.  Run `sudo kh-duo`
#   # to enter the menu.
#   curl -fsSL https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install.sh | sudo bash
#
#   # Hands-off (any args after `--` are forwarded to install-duo-ssh.sh):
#   curl -fsSL https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install.sh \
#       | sudo bash -s -- --ikey DIXXXXXXXXXXXXXXXXXX \
#                         --skey YOUR-SECRET-KEY \
#                         --host api-xxxxxxxx.duosecurity.com \
#                         --yes
#
# Behavior:
#   1. Verify root
#   2. Download install-duo-ssh.sh to /usr/local/sbin/install-duo-ssh.sh
#   3. Validate (#! line + `bash -n` syntax check)
#   4. Install owner=root:root mode=755
#   5. Install the `kh-duo` shortcut at /usr/local/bin/kh-duo
#   6. If args were forwarded -> exec the script with them
#      Otherwise -> print "next step" hint and exit
#

set -euo pipefail

### ─── Hardening ──────────────────────────────────────────────────────────
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

BOOTSTRAP_VERSION="1.0.0"
BASE_URL="${KH_DUO_BOOTSTRAP_URL:-https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh}"
TRUSTED_PREFIX="https://raw.githubusercontent.com/"
SCRIPT_NAME="install-duo-ssh.sh"
INSTALL_DIR="/usr/local/sbin"
TARGET="$INSTALL_DIR/$SCRIPT_NAME"

### ─── UI helpers ─────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

### ─── Preconditions ──────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Must run as root.  Try:  curl ... | sudo bash"

case "$BASE_URL" in
    "$TRUSTED_PREFIX"*) ;;
    *) die "Refusing untrusted KH_DUO_BOOTSTRAP_URL '$BASE_URL' — must start with $TRUSTED_PREFIX" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required (apt install curl / yum install curl)"

### ─── Download ───────────────────────────────────────────────────────────
log "Bootstrap v$BOOTSTRAP_VERSION — downloading $BASE_URL/$SCRIPT_NAME"

tmp="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL --max-time 60 "$BASE_URL/$SCRIPT_NAME" -o "$tmp"; then
    die "Download failed"
fi

### ─── Validate ───────────────────────────────────────────────────────────
head -1 "$tmp" | grep -qE '^#!/(usr/bin/env[[:space:]]+bash|bin/bash)' \
    || die "Downloaded file is not a bash script — refusing to install"

bash -n "$tmp" 2>/dev/null \
    || die "Downloaded file failed bash -n syntax check — refusing to install"

new_version="$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$tmp")"
[[ -n "$new_version" ]] || warn "Could not parse SCRIPT_VERSION from downloaded file"

### ─── Install ────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

if ! install -m 755 -o root -g root "$tmp" "$TARGET" 2>/dev/null; then
    cp "$tmp" "$TARGET"
    chmod 755 "$TARGET"
    chown root:root "$TARGET" 2>/dev/null || true
fi

ok "Installed: $TARGET${new_version:+  (v$new_version)}"

### ─── Install kh-duo shortcut ────────────────────────────────────────────
# --install-shortcut needs --yes to skip the "Replace it?" prompt if the link
# already exists.  Failure here is non-fatal — the user can run the script by
# its full path either way.
if "$TARGET" --install-shortcut --yes >/dev/null 2>&1; then
    ok "Shortcut installed: /usr/local/bin/kh-duo -> $TARGET"
else
    warn "Could not install kh-duo shortcut (run '$TARGET --install-shortcut' manually)"
fi

### ─── Hand off ───────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
    log "Forwarding args to $TARGET: $*"
    echo
    exec "$TARGET" "$@"
fi

cat <<EOF

$(ok "Bootstrap complete.")

Next step — run the installer interactively:

  sudo kh-duo

Or with credentials in one shot:

  sudo kh-duo --ikey DIXXXXXXXXXXXXXXXXXX \\
              --skey your-secret-key \\
              --host api-xxxxxxxx.duosecurity.com \\
              --yes

Other handy commands:

  kh-duo --version       # print version (no root required)
  kh-duo --check-update  # see if upstream is newer (no root required)
  sudo kh-duo --help     # full usage / flag list
EOF
