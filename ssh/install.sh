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
#   # CN-friendly: download both bootstrap and main script via jsDelivr CDN
#   # (raw.githubusercontent.com is often blocked in mainland China).  The
#   # --cdn flag is also persisted so future `kh-duo --update` calls go via
#   # the same CDN.
#   curl -fsSL https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@master/ssh/install.sh \
#       | sudo bash -s -- --cdn jsdelivr
#
#   # Beta channel (preview branch — for test hosts only).  Adds
#   # --channel beta to the bootstrap; the bootstrap downloads from the
#   # beta branch and persists the channel so subsequent --update calls
#   # also stay on beta.
#   curl -fsSL https://raw.githubusercontent.com/KazuhaHub/ops-scripts/beta/ssh/install.sh \
#       | sudo bash -s -- --channel beta
#
# Behavior:
#   1. Verify root
#   2. Download install-duo-ssh.sh (default: canonical GitHub; --cdn picks a CDN)
#   3. Validate (#! line + `bash -n` syntax + multi-anchor SHA256 quorum)
#   4. Install owner=root:root mode=755
#   5. Install the `kh-duo` shortcut at /usr/local/bin/kh-duo
#   6. Persist --channel / --cdn to /etc/duo/install-duo-ssh.conf
#   7. If args were forwarded -> exec the script with them
#      Otherwise -> print "next step" hint and exit
#

set -euo pipefail

### ─── Hardening ──────────────────────────────────────────────────────────
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

BOOTSTRAP_VERSION="1.2.0"

# Strip our own --channel <name> and --cdn <provider> from $@ before we
# forward the rest to install-duo-ssh.sh (which has its own --set-channel /
# --use-cdn for persistence, but doesn't consume these "during install"
# flags directly).  Defaults come from env vars, then fall back.
CHANNEL="${KH_DUO_CHANNEL:-stable}"
CDN=""
FORWARD_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)    CHANNEL="${2:-stable}"; shift 2 ;;
        --channel=*)  CHANNEL="${1#--channel=}"; shift ;;
        --cdn)        CDN="${2:-}"; shift 2 ;;
        --cdn=*)      CDN="${1#--cdn=}"; shift ;;
        *)            FORWARD_ARGS+=("$1"); shift ;;
    esac
done
set -- "${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}"

case "$CHANNEL" in
    stable) BRANCH="master" ;;
    beta)   BRANCH="beta" ;;
    *)      printf '\033[1;31m[x]\033[0m Unknown channel %q (must be stable or beta)\n' "$CHANNEL" >&2; exit 1 ;;
esac

# Resolve BASE_URL.  Precedence: --cdn flag > KH_DUO_BOOTSTRAP_URL env > default canonical GitHub.
case "$CDN" in
    "")
        # No CDN flag — use env override if present, else canonical
        BASE_URL="${KH_DUO_BOOTSTRAP_URL:-https://raw.githubusercontent.com/KazuhaHub/ops-scripts/$BRANCH/ssh}"
        ;;
    github)
        BASE_URL="https://raw.githubusercontent.com/KazuhaHub/ops-scripts/$BRANCH/ssh"
        ;;
    jsdelivr)
        BASE_URL="https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@$BRANCH/ssh"
        ;;
    statically)
        BASE_URL="https://cdn.statically.io/gh/KazuhaHub/ops-scripts/$BRANCH/ssh"
        ;;
    *)
        printf '\033[1;31m[x]\033[0m Unknown --cdn provider %q (must be github | jsdelivr | statically)\n' "$CDN" >&2
        exit 1
        ;;
esac

# Trusted prefix whitelist for BASE_URL (defends against socially-engineered
# KH_DUO_BOOTSTRAP_URL pointing at a fork or random host).  Each entry must
# match the start of BASE_URL exactly.  --cdn-derived URLs are always in
# this list; only env-var-supplied URLs need to pass the check.
TRUSTED_PREFIXES=(
    "https://raw.githubusercontent.com/KazuhaHub/ops-scripts/"
    "https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@"
    "https://cdn.statically.io/gh/KazuhaHub/ops-scripts/"
)

SCRIPT_NAME="install-duo-ssh.sh"
INSTALL_DIR="/usr/local/sbin"
TARGET="$INSTALL_DIR/$SCRIPT_NAME"

# Multi-anchor SHA256 trust anchors — same design as install-duo-ssh.sh's
# verify_downloaded_file().  We fetch all 3 in parallel and require all
# reachable ones to agree.  Fixes both the original "single anchor" gap and
# the CN-reachability problem (jsDelivr + Statically usually form quorum
# even when raw.github is blocked).
HASH_ANCHORS=(
    "https://raw.githubusercontent.com/KazuhaHub/ops-scripts/$BRANCH/ssh/$SCRIPT_NAME.sha256"
    "https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@$BRANCH/ssh/$SCRIPT_NAME.sha256"
    "https://cdn.statically.io/gh/KazuhaHub/ops-scripts/$BRANCH/ssh/$SCRIPT_NAME.sha256"
)

### ─── UI helpers ─────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

### ─── Preconditions ──────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Must run as root.  Try:  curl ... | sudo bash"

# BASE_URL must match one of the trusted prefixes.
url_trusted=0
for prefix in "${TRUSTED_PREFIXES[@]}"; do
    case "$BASE_URL" in
        "$prefix"*) url_trusted=1; break ;;
    esac
done
if [[ $url_trusted -ne 1 ]]; then
    err "Refusing untrusted BASE_URL: $BASE_URL"
    err "Must start with one of:"
    for prefix in "${TRUSTED_PREFIXES[@]}"; do err "  $prefix"; done
    exit 1
fi

command -v curl >/dev/null 2>&1 || die "curl is required (apt install curl / yum install curl)"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required for anti-tamper verification"

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

### ─── Anti-tamper SHA256 quorum check ────────────────────────────────────
# Compute local hash, then fetch .sha256 from every trust anchor in parallel
# and require all reachable ones to agree.  An attacker has to compromise
# ≥2 independent CDNs (raw.github + jsDelivr + Statically) to bypass.
#
# KH_DUO_PIN_SHA256 short-circuits this with out-of-band trust — useful for
# fully-isolated hosts that can't reach any CDN at all.
actual_sha="$(sha256sum "$tmp" | awk '{print $1}')"
log "Downloaded SHA256: $actual_sha"

if [[ -n "${KH_DUO_PIN_SHA256:-}" ]]; then
    if [[ "$actual_sha" != "$KH_DUO_PIN_SHA256" ]]; then
        die "Anti-tamper check FAILED: pinned=$KH_DUO_PIN_SHA256 actual=$actual_sha"
    fi
    ok "SHA256 matches KH_DUO_PIN_SHA256"
else
    log "Fetching SHA256 from ${#HASH_ANCHORS[@]} independent anchor(s) in parallel..."
    anchor_dir="$(mktemp -d)" || die "mktemp -d failed"
    pids=()
    i=0
    for url in "${HASH_ANCHORS[@]}"; do
        ( curl -fsSL --max-time 8 "$url" 2>/dev/null \
            | awk 'NF{print $1; exit}' > "$anchor_dir/$i" ) &
        pids+=($!)
        i=$((i+1))
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    results=()
    reachable_urls=()
    for (( i=0; i<${#HASH_ANCHORS[@]}; i++ )); do
        h="$(cat "$anchor_dir/$i" 2>/dev/null || true)"
        if [[ -n "$h" ]]; then
            results+=("$h")
            reachable_urls+=("${HASH_ANCHORS[i]}")
        fi
    done
    rm -rf "$anchor_dir"

    if [[ ${#results[@]} -eq 0 ]]; then
        die "Anti-tamper: no trust anchor reachable (tried ${#HASH_ANCHORS[@]} CDNs). Set KH_DUO_PIN_SHA256=<hash> for out-of-band trust."
    fi

    first="${results[0]}"
    for (( i=1; i<${#results[@]}; i++ )); do
        if [[ "${results[i]}" != "$first" ]]; then
            err "Anti-tamper: anchors DISAGREE — possible CDN compromise."
            for (( j=0; j<${#results[@]}; j++ )); do
                err "  ${reachable_urls[j]} -> ${results[j]}"
            done
            die "Refusing to install with conflicting trust anchors."
        fi
    done

    if [[ ${#results[@]} -lt ${#HASH_ANCHORS[@]} ]]; then
        warn "Only ${#results[@]}/${#HASH_ANCHORS[@]} trust anchors reachable — accepted on agreement."
    fi

    if [[ "$actual_sha" != "$first" ]]; then
        die "Anti-tamper check FAILED — downloaded content does not match anchor SHA256. expected=$first actual=$actual_sha"
    fi

    ok "SHA256 matches ${#results[@]}/${#HASH_ANCHORS[@]} trust anchor(s) (${first:0:16}…)"
fi

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

### ─── Persist channel selection ──────────────────────────────────────────
# If user picked something other than stable, write it into the persistent
# config so future --update / auto-update tasks honor it.  Channel must be
# persisted BEFORE --use-cdn (use_cdn reads channel to compute the URL).
if [[ "$CHANNEL" != "stable" ]]; then
    if "$TARGET" --set-channel "$CHANNEL" >/dev/null 2>&1; then
        ok "Channel persisted: $CHANNEL"
    else
        warn "Failed to persist channel '$CHANNEL' — run 'sudo kh-duo --set-channel $CHANNEL' manually"
    fi
fi

### ─── Persist CDN selection ──────────────────────────────────────────────
# If user picked a CDN, persist it via --use-cdn so future self-updates use
# the same CDN (otherwise they'd fall back to canonical GitHub, which is the
# whole reason the user picked a CDN in the first place).
if [[ -n "$CDN" && "$CDN" != "github" ]]; then
    if "$TARGET" --use-cdn "$CDN" >/dev/null 2>&1; then
        ok "CDN persisted: $CDN"
    else
        warn "Failed to persist CDN '$CDN' — run 'sudo kh-duo --use-cdn $CDN' manually"
    fi
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
