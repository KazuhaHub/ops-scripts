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
#        ./install-duo-ssh.sh --check-update           # read-only, no root required
#   sudo ./install-duo-ssh.sh --update                 # download latest and replace
#                                                        (--self-update kept as deprecated alias)
#        ./install-duo-ssh.sh --version                # print version and exit (no root)
#        ./install-duo-ssh.sh --show-config            # print effective update URL + auto-update status
#   sudo ./install-duo-ssh.sh --set-channel <stable|beta>  # pick update channel
#                                                            (stable = master branch, beta = beta branch)
#   sudo ./install-duo-ssh.sh --use-cdn <provider>     # one-shot CDN preset: github | jsdelivr | statically
#                                                        (recommended for CN: --use-cdn jsdelivr)
#   sudo ./install-duo-ssh.sh --set-mirror <url>       # persist a custom update URL (overrides channel)
#   sudo ./install-duo-ssh.sh --clear-mirror           # remove persistent mirror, revert to channel default
#   sudo ./install-duo-ssh.sh --install-auto-update    # register daily 04:00 systemd timer (cron fallback)
#   sudo ./install-duo-ssh.sh --remove-auto-update     # remove the timer / cron entry
#   sudo ./install-duo-ssh.sh --no-auto-update         # don't auto-register the timer during install
#   sudo ./install-duo-ssh.sh --reinstall              # full uninstall + reinstall, keeping
#                                                        existing creds (forces baseline reapply
#                                                        of PAM / sshd / Duo config)
#
# Env vars:
#   DUO_IKEY / DUO_SKEY / DUO_HOST   Duo application credentials (skip prompts)
#   KH_DUO_CHANNEL                   override channel (stable/beta) — IGNORED when
#                                    invoked via sudo from a non-root caller.
#   KH_DUO_UPDATE_URL                override update URL — IGNORED when invoked
#                                    via sudo from a non-root caller (anti-tamper).
#                                    Use --set-mirror for persistent overrides.
#   KH_DUO_PIN_SHA256                if set, downloaded script must match this
#                                    SHA256 hash before installation (out-of-band
#                                    trust for hosts that cannot reach canonical).
#   KH_DUO_SHORTCUT                  override shortcut path (must be under
#                                    /usr/local/{bin,sbin}/ or /usr/{bin,sbin}/)
#   KH_DUO_BACKUP_KEEP               number of /root/duo-install-backup-* dirs and
#                                    .bak.<TS> script files to keep (default 5;
#                                    0 disables auto-cleanup).
#
# Modes:
#   - No flags + TTY            → interactive menu (install / uninstall / update / shortcut)
#   - Any flag passed           → flag-driven, no menu (back-compatible automation)
#   - Non-TTY (pipe/Ansible)    → flag-driven; missing creds will fail-fast
#
# Safe to re-run: idempotent, creates timestamped backups, rolls back on error.

set -euo pipefail

### ─── Hardening ──────────────────────────────────────────────────────────
# Pin PATH so that bare command names (curl, awk, install, …) cannot be
# hijacked by an attacker-controlled PATH leaking through `sudo -E` or a
# sudoers `Defaults env_keep += "PATH"` rule.
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

### ─── Defaults / args ────────────────────────────────────────────────────
IKEY="${DUO_IKEY:-}"
SKEY="${DUO_SKEY:-}"
HOST="${DUO_HOST:-}"
BREAKGLASS_USER=""
BYPASS_LOCAL=1
BYPASS_ADDRS=""
ALLOW_PASSWORD=0
SKIP_KEY_CHECK=0
STRICT_PUBLICKEY=0
UNINSTALL=0
NO_AUTO_UPDATE=0          # set by --no-auto-update to skip the install of the daily timer/cron job
ASSUME_YES=0
NO_MENU=0
INTERACTIVE_FLAGS_USED=0
ACTION_CHECK_UPDATE=0
ACTION_SELF_UPDATE=0
ACTION_INSTALL_SHORTCUT=0
ACTION_SET_MIRROR=0
ACTION_CLEAR_MIRROR=0
ACTION_SET_CHANNEL=0
ACTION_USE_CDN=0
ACTION_SHOW_CONFIG=0
ACTION_INSTALL_AUTO_UPDATE=0
ACTION_REMOVE_AUTO_UPDATE=0
ACTION_REINSTALL=0
SET_MIRROR_URL=""
SET_CHANNEL_VALUE=""

# Auto-cleanup retention.  After each successful install / self-update we keep
# the N most recent backup artifacts and drop older ones.  Override via env
# KH_DUO_BACKUP_KEEP=N (0 disables cleanup; 20 keeps longer rollback history).
BACKUP_RETENTION_COUNT="${KH_DUO_BACKUP_KEEP:-5}"
USE_CDN_PROVIDER=""

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/duo-install-backup-${TS}"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

# Self-update / shortcut — both URL and path can be overridden via env var
# (useful for forks, internal mirrors, or non-standard PATH layouts), but the
# overrides are validated below so an attacker who can leak env through sudo
# cannot redirect self-update to an arbitrary host or place the shortcut in
# a sensitive location.
SCRIPT_VERSION="1.7.2"

# Update channel URLs.  `stable` is the default and what most fleet hosts
# should track.  `beta` is for hosts willing to validate new releases — push
# changes there first, soak-test for a few days, then merge into master so
# the rest of the fleet picks them up at the next 04:00 cycle.
#
# Default download is canonical GitHub.  Mainland-China users who can't reach
# raw.githubusercontent.com can opt into a CDN mirror via `--set-mirror`
# (jsDelivr / Statically / ghproxy / etc — see README).  Whatever URL the
# script ends up downloading from, the multi-anchor SHA256 quorum check in
# verify_downloaded_file() (see HASH_ANCHORS_* below) catches tampering by
# any single mirror — including the canonical default itself.
SCRIPT_STABLE_URL="https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh"
SCRIPT_BETA_URL="https://raw.githubusercontent.com/KazuhaHub/ops-scripts/beta/ssh/install-duo-ssh.sh"

# Trust anchors for the .sha256 hash file — TIERED model:
#
#   Tier 1 — canonical github (HASH_CANONICAL_*).  When reachable, this is
#   AUTHORITATIVE: matches → accept; mismatches → refuse (CDN status irrelevant).
#   Reasoning: github is already the source of truth for the source code, so
#   trusting its .sha256 adds no new attack surface beyond what already exists.
#
#   Tier 2 — CDN fallback anchors (HASH_FALLBACK_*).  Used ONLY when canonical
#   github is unreachable (mainland China commonly blocks raw.githubusercontent.com).
#   All reachable fallback anchors must agree with each other AND match the
#   downloaded content, defeating any single compromised CDN.
#
# Why tiered, not flat-quorum: jsDelivr/Statically use long-TTL edge caches
# on `@<branch>` refs (~12h).  After a release push, multiple CDN edges may
# return stale .sha256 simultaneously, outvoting fresh canonical github in a
# flat-quorum scheme.  That's a CDN-coherence false-positive, not an attack —
# canonical-first eliminates it without weakening the trust model.
#
# Maintained by .github/workflows/update-sha256.yml on every push (which also
# purges jsDelivr cache to shrink the CDN-stale window).
HASH_CANONICAL_STABLE="https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh.sha256"
HASH_CANONICAL_BETA="https://raw.githubusercontent.com/KazuhaHub/ops-scripts/beta/ssh/install-duo-ssh.sh.sha256"
HASH_FALLBACK_STABLE=(
    "https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@master/ssh/install-duo-ssh.sh.sha256"
    "https://cdn.statically.io/gh/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh.sha256"
)
HASH_FALLBACK_BETA=(
    "https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@beta/ssh/install-duo-ssh.sh.sha256"
    "https://cdn.statically.io/gh/KazuhaHub/ops-scripts/beta/ssh/install-duo-ssh.sh.sha256"
)

# Per-host config file owned by root, mode 600.  Only root can write here, so
# unprivileged users cannot tamper with the update URL even if they manage to
# leak environment variables to root via `sudo -E`.
SCRIPT_CONFIG_FILE="/etc/duo/install-duo-ssh.conf"

SCRIPT_RAW_URL=""   # set by resolve_update_url() before any URL fetch
SHORTCUT_PATH="${KH_DUO_SHORTCUT:-/usr/local/bin/kh-duo}"

# Auto-update task — daily check at 04:00, with up to 15 min jitter to spread
# fleet load.  Tries systemd first, falls back to cron if systemd is absent.
AUTO_UPDATE_HOUR="04"
AUTO_UPDATE_SYSTEMD_SERVICE="/etc/systemd/system/kh-duo-update.service"
AUTO_UPDATE_SYSTEMD_TIMER="/etc/systemd/system/kh-duo-update.timer"
AUTO_UPDATE_CRON_FILE="/etc/cron.d/kh-duo-update"

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
        --strict-publickey) STRICT_PUBLICKEY=1; shift ;;
        --uninstall)    UNINSTALL=1; shift ;;
        --no-menu)      NO_MENU=1; shift ;;
        --check-update) ACTION_CHECK_UPDATE=1; shift ;;
        --update|--self-update) ACTION_SELF_UPDATE=1; shift ;;
        --install-shortcut) ACTION_INSTALL_SHORTCUT=1; shift ;;
        --set-mirror)   ACTION_SET_MIRROR=1; SET_MIRROR_URL="$2"; shift 2 ;;
        --clear-mirror) ACTION_CLEAR_MIRROR=1; shift ;;
        --set-channel)  ACTION_SET_CHANNEL=1; SET_CHANNEL_VALUE="$2"; shift 2 ;;
        --use-cdn)      ACTION_USE_CDN=1; USE_CDN_PROVIDER="${2:-}"; shift 2 ;;
        --reinstall)    ACTION_REINSTALL=1; shift ;;
        --show-config)  ACTION_SHOW_CONFIG=1; shift ;;
        --install-auto-update) ACTION_INSTALL_AUTO_UPDATE=1; shift ;;
        --remove-auto-update)  ACTION_REMOVE_AUTO_UPDATE=1; shift ;;
        --no-auto-update)      NO_AUTO_UPDATE=1; shift ;;
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

# --- Persistent config helpers -------------------------------------------
# /etc/duo/install-duo-ssh.conf format (managed by this script):
#   channel    = stable | beta
#   update_url = <full URL>     ← optional, overrides channel-derived URL
#
# Any unprivileged user can READ the file (just ikey hostname etc, no creds),
# but only root can WRITE — so an attacker leaking env via `sudo -E` cannot
# redirect updates here, only through KH_DUO_* vars (which we ignore under
# sudo, see resolve_update_url).

# Read `channel` from disk config; defaults to "stable" if absent / unreadable.
get_persistent_channel() {
    [[ -r "$SCRIPT_CONFIG_FILE" ]] || { echo ""; return; }
    awk -F'[[:space:]]*=[[:space:]]*' '/^[[:space:]]*channel[[:space:]]*=/{print $2; exit}' "$SCRIPT_CONFIG_FILE" 2>/dev/null
}

# Read explicit `update_url` from disk config (empty if not set).
get_persistent_url() {
    [[ -r "$SCRIPT_CONFIG_FILE" ]] || { echo ""; return; }
    awk -F'[[:space:]]*=[[:space:]]*' '/^[[:space:]]*update_url[[:space:]]*=/{print $2; exit}' "$SCRIPT_CONFIG_FILE" 2>/dev/null
}

# Effective channel (config > env > default).  KH_DUO_CHANNEL is ignored when
# invoked via sudo from a non-root caller (anti-tamper).
get_effective_channel() {
    local c
    c="$(get_persistent_channel)"
    if [[ -n "$c" ]]; then echo "$c"; return; fi
    if [[ -n "${KH_DUO_CHANNEL:-}" && -z "${SUDO_USER:-}" ]]; then
        echo "$KH_DUO_CHANNEL"; return
    fi
    echo "stable"
}

# Map channel name -> default URL.  Unknown name falls back to stable.
channel_url() {
    case "$1" in
        beta)   echo "$SCRIPT_BETA_URL" ;;
        stable) echo "$SCRIPT_STABLE_URL" ;;
        *)      echo "$SCRIPT_STABLE_URL" ;;
    esac
}

# Map (provider, branch) -> full download URL for the script.  Drives
# `--use-cdn <provider>` shortcut (and the menu picker) so users don't have
# to know each CDN's path conventions.  Unknown provider returns non-zero.
#
# Provider names match what `--use-cdn` accepts.  `github` is special — it
# represents "use the canonical default" and is implemented as
# clear_mirror() rather than set_mirror() so users can revert cleanly.
cdn_url() {
    local provider="$1" branch="$2"
    case "$provider" in
        jsdelivr)
            echo "https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@${branch}/ssh/install-duo-ssh.sh"
            ;;
        statically)
            echo "https://cdn.statically.io/gh/KazuhaHub/ops-scripts/${branch}/ssh/install-duo-ssh.sh"
            ;;
        github)
            # Canonical — no mirror needed.  Caller checks for this name and
            # routes to clear_mirror() instead of set_mirror().
            echo "https://raw.githubusercontent.com/KazuhaHub/ops-scripts/${branch}/ssh/install-duo-ssh.sh"
            ;;
        *)
            return 1
            ;;
    esac
}

# Atomically rewrite /etc/duo/install-duo-ssh.conf with given channel + url.
# Empty channel arg -> default "stable" (line omitted).  Empty url -> no
# update_url line.  Caller must already be root.
write_config() {
    local channel="$1"
    local url="$2"

    require_root
    mkdir -p "$(dirname "$SCRIPT_CONFIG_FILE")"

    umask 077
    local tmp
    tmp="$(mktemp)" || die "mktemp failed"
    {
        echo "# Kazuha Hub Duo installer config (managed by install-duo-ssh.sh)"
        echo "# Loaded before each --update / --check-update."
        echo "# Root-only; unprivileged users cannot redirect updates here."
        echo ""
        if [[ -n "$channel" && "$channel" != "stable" ]]; then
            echo "channel = $channel"
        fi
        if [[ -n "$url" ]]; then
            echo "update_url = $url"
        fi
    } > "$tmp"

    install -m 600 -o root -g root "$tmp" "$SCRIPT_CONFIG_FILE" 2>/dev/null || {
        cp "$tmp" "$SCRIPT_CONFIG_FILE"
        chmod 600 "$SCRIPT_CONFIG_FILE"
        chown root:root "$SCRIPT_CONFIG_FILE" 2>/dev/null || true
    }
    rm -f "$tmp"
}

# Resolve the URL for self-update / version checks.  Order of trust:
#   1. /etc/duo/install-duo-ssh.conf  `update_url = ...`  (highest)
#      Set via `--set-mirror <url>`. Persistent, root-only.
#   2. KH_DUO_UPDATE_URL env var, ONLY when not invoked via sudo from a
#      non-root caller.  Otherwise rejected with a warning.
#   3. Channel-derived URL (config > env > default "stable").
resolve_update_url() {
    local conf_url
    conf_url="$(get_persistent_url)"
    if [[ -n "$conf_url" ]]; then
        SCRIPT_RAW_URL="$conf_url"
        return 0
    fi

    if [[ -n "${KH_DUO_UPDATE_URL:-}" ]]; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            warn "Ignoring KH_DUO_UPDATE_URL — invoked via sudo (SUDO_USER=$SUDO_USER), so the env var could be supplied by an unprivileged caller."
            warn "Set a persistent URL with:  sudo kh-duo --set-mirror <url>"
        else
            SCRIPT_RAW_URL="$KH_DUO_UPDATE_URL"
            return 0
        fi
    fi

    SCRIPT_RAW_URL="$(channel_url "$(get_effective_channel)")"
}

# --- Public setters (called from CLI flags + menu) -----------------------

# `--set-channel <stable|beta>` writes the channel to the config; preserves any
# existing custom mirror URL.
set_channel() {
    local channel="$1"
    case "$channel" in
        stable|beta) ;;
        *) die "Unknown channel '$channel' (must be 'stable' or 'beta')" ;;
    esac
    write_config "$channel" "$(get_persistent_url)"
    if [[ "$channel" == "stable" ]]; then
        ok "Channel set to 'stable'"
    else
        ok "Channel set to '$channel'  (URL: $(channel_url "$channel"))"
        warn "Beta channel pulls from the 'beta' branch — use only on test hosts."
    fi
}

# `--set-mirror <url>` writes a custom URL (overrides channel-derived URL);
# preserves existing channel setting.
set_mirror() {
    local url="$1"
    [[ -n "$url" ]] || die "set_mirror: empty URL"
    case "$url" in
        https://*) ;;
        *) die "Refusing non-https URL: $url" ;;
    esac
    write_config "$(get_persistent_channel)" "$url"
    ok "Persistent mirror URL set in $SCRIPT_CONFIG_FILE"
    ok "  $url"
}

# `--use-cdn <provider>` is a UX shortcut over --set-mirror: it knows the
# URL templates for each supported CDN provider so the user just names the
# provider.  The current channel determines the branch (master/beta).
#
# Provider 'github' is special — it routes to clear_mirror(), reverting to
# the canonical default (no persistent mirror).
use_cdn() {
    local provider="$1"
    [[ -n "$provider" ]] || die "use_cdn: empty provider name (try: github | jsdelivr | statically)"

    if [[ "$provider" == "github" ]]; then
        clear_mirror
        return 0
    fi

    local branch
    case "$(get_persistent_channel)" in
        beta) branch="beta" ;;
        *)    branch="master" ;;
    esac

    local url
    if ! url="$(cdn_url "$provider" "$branch")"; then
        die "Unknown CDN provider '$provider'.  Supported: github | jsdelivr | statically"
    fi

    write_config "$(get_persistent_channel)" "$url"
    ok "CDN preset applied: $provider  (branch: $branch)"
    ok "  $url"
}

# `--clear-mirror` drops the custom URL, keeps channel.  If channel is also at
# default ("stable"), the config file is removed entirely for cleanliness.
clear_mirror() {
    require_root
    local channel
    channel="$(get_persistent_channel)"
    if [[ -z "$channel" || "$channel" == "stable" ]]; then
        if [[ -f "$SCRIPT_CONFIG_FILE" ]]; then
            rm -f "$SCRIPT_CONFIG_FILE"
            ok "Removed $SCRIPT_CONFIG_FILE — reverting to default canonical URL on stable channel"
        else
            ok "No persistent config to clear (already on default)"
        fi
    else
        write_config "$channel" ""
        ok "Cleared custom mirror URL — channel '$channel' default URL will be used"
        ok "  $(channel_url "$channel")"
    fi
}

# Map effective channel to its canonical .sha256 URL (Tier 1 anchor).
canonical_hash_url() {
    case "$1" in
        beta) echo "$HASH_CANONICAL_BETA" ;;
        *)    echo "$HASH_CANONICAL_STABLE" ;;
    esac
}

# Map effective channel to its CDN fallback .sha256 URLs (Tier 2 anchors).
fallback_hash_urls() {
    case "$1" in
        beta) printf '%s\n' "${HASH_FALLBACK_BETA[@]}" ;;
        *)    printf '%s\n' "${HASH_FALLBACK_STABLE[@]}" ;;
    esac
}

# Anti-tamper SHA256 verification of a downloaded script file.
#
# Threat: script downloaded from some mirror (default canonical github, or a
# CDN/mirror via --set-mirror).  A compromised mirror could serve a tampered
# script.  Shebang + `bash -n` checks don't help (attacker writes valid bash).
#
# Tiered model:
#   1. KH_DUO_PIN_SHA256 — out-of-band trust, highest priority.  Skips
#      everything else.  Use case: fully-isolated host that can't reach any
#      anchor; hash delivered via VPN/sneakernet.
#
#   2. Tier 1 — canonical github (raw.githubusercontent.com).  When reachable,
#      AUTHORITATIVE: downloaded content must match its hash; CDN anchors
#      are not consulted.  github is already the source of truth for the
#      script's source code, so trusting its .sha256 here is the same trust
#      boundary.  Eliminates the false-positive failure mode where multiple
#      CDN edges return stale .sha256 simultaneously and outvote fresh github.
#
#   3. Tier 2 — CDN fallback quorum (jsDelivr + Statically).  Used ONLY when
#      Tier 1 is unreachable (mainland China commonly blocks raw.github).
#      All reachable fallback anchors must agree AND match downloaded.  Single
#      compromised CDN cannot bypass; full quorum across independent CDNs
#      required.
verify_downloaded_file() {
    local file="$1"
    command -v sha256sum >/dev/null 2>&1 \
        || die "sha256sum required for anti-tamper verification"

    local actual_sha
    actual_sha="$(sha256sum "$file" | awk '{print $1}')"
    log "Downloaded SHA256: $actual_sha"

    # ── 1. PIN (out-of-band trust) ──────────────────────────────────────
    if [[ -n "${KH_DUO_PIN_SHA256:-}" ]]; then
        if [[ "$actual_sha" != "$KH_DUO_PIN_SHA256" ]]; then
            die "Anti-tamper check FAILED: pinned=$KH_DUO_PIN_SHA256 actual=$actual_sha"
        fi
        ok "SHA256 matches KH_DUO_PIN_SHA256"
        return 0
    fi

    local channel canonical_url
    channel="$(get_effective_channel)"
    canonical_url="$(canonical_hash_url "$channel")"

    local -a fallback_urls
    mapfile -t fallback_urls < <(fallback_hash_urls "$channel")
    local n_fallback=${#fallback_urls[@]}

    # Fetch canonical + all fallbacks in parallel — small files, fast.
    local tmpdir
    tmpdir="$(mktemp -d)" || die "mktemp -d failed"

    log "Verifying download (canonical-first, with $n_fallback CDN fallback anchors)..."

    ( curl -fsSL --max-time 8 "$canonical_url" 2>/dev/null \
        | awk 'NF{print $1; exit}' > "$tmpdir/canonical" ) &
    local canonical_pid=$!

    local -a fb_pids
    local i
    for (( i=0; i<n_fallback; i++ )); do
        ( curl -fsSL --max-time 8 "${fallback_urls[i]}" 2>/dev/null \
            | awk 'NF{print $1; exit}' > "$tmpdir/fb_$i" ) &
        fb_pids+=($!)
    done

    wait "$canonical_pid" 2>/dev/null || true
    for pid in "${fb_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # ── 2. Tier 1: canonical github (authoritative when reachable) ──────
    local canonical_hash
    canonical_hash="$(cat "$tmpdir/canonical" 2>/dev/null || true)"
    if [[ -n "$canonical_hash" ]]; then
        rm -rf "$tmpdir"
        if [[ "$actual_sha" == "$canonical_hash" ]]; then
            ok "SHA256 matches canonical github (${canonical_hash:0:16}…) — CDN anchors not consulted"
            return 0
        fi
        # Canonical reachable + mismatch = authoritative refusal.
        die "Anti-tamper check FAILED — canonical github says expected=$canonical_hash, actual=$actual_sha. (Authoritative source disagrees; refusing regardless of CDN status. If you downloaded via a CDN, the CDN may be serving stale/wrong content — try 'sudo kh-duo --use-cdn github' to download from canonical.)"
    fi

    # ── 3. Tier 2: canonical unreachable, fall back to CDN quorum ───────
    warn "Canonical github unreachable — falling back to CDN quorum ($n_fallback anchors)"

    local -a results=() reachable_urls=()
    local hash
    for (( i=0; i<n_fallback; i++ )); do
        hash="$(cat "$tmpdir/fb_$i" 2>/dev/null || true)"
        if [[ -n "$hash" ]]; then
            results+=("$hash")
            reachable_urls+=("${fallback_urls[i]}")
        fi
    done
    rm -rf "$tmpdir"

    local reachable=${#results[@]}
    if (( reachable == 0 )); then
        die "Anti-tamper: canonical github AND all $n_fallback CDN fallback anchors unreachable. Set KH_DUO_PIN_SHA256=<hash> for out-of-band trust, or check your network."
    fi

    # All reachable fallback anchors must agree — disagreement = possible CDN compromise
    local first="${results[0]}" j
    for (( i=1; i<reachable; i++ )); do
        if [[ "${results[i]}" != "$first" ]]; then
            err "Anti-tamper: CDN anchors DISAGREE — possible CDN compromise."
            for (( j=0; j<reachable; j++ )); do
                err "  ${reachable_urls[j]} -> ${results[j]}"
            done
            die "Refusing to install with conflicting trust anchors."
        fi
    done

    if [[ "$actual_sha" != "$first" ]]; then
        die "Anti-tamper check FAILED — downloaded content does not match CDN anchor SHA256. expected=$first actual=$actual_sha"
    fi

    if (( reachable < n_fallback )); then
        warn "Only $reachable/$n_fallback CDN fallback anchors reachable + canonical also unreachable — accepted on agreement, but consider setting KH_DUO_PIN_SHA256 for stronger guarantees."
    fi

    ok "SHA256 matches CDN fallback quorum ($reachable/$n_fallback anchors, canonical unreachable)"
}

# self_update / install_shortcut both treat $SCRIPT_PATH as trusted.  If the
# script lives in a directory the caller can write to (e.g. /home/<user>/),
# they could swap the file under us between root invocations.  Refuse to run
# privileged operations unless the on-disk script is root-owned.
require_root_owned_script() {
    local owner=""
    owner="$(stat -c '%U' "$SCRIPT_PATH" 2>/dev/null || true)"
    if [[ "$owner" != "root" ]]; then
        die "Refusing privileged operation: $SCRIPT_PATH is owned by '${owner:-unknown}', not root. Move it to a root-owned location (e.g. /usr/local/sbin/install-duo-ssh.sh) and re-run."
    fi
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
#
# Caller does not need to print further status — this function emits a clear
# end-state line:
#   "Already on latest version (X) — no changes"          (no-op)
#   "Updated X → Y  (backup: …)" + re-run hint             (upgrade)
#   "Reinstalled X  (content changed without version bump)" + re-run hint
#   "Downgraded X → Y  (backup: …)" + re-run hint          (warn)
#
# The hash short-circuit avoids creating a useless backup every day at 04:00
# when the cron auto-update runs and finds no new release.
self_update() {
    command -v curl >/dev/null 2>&1 || die "curl is required for self-update"
    require_root_owned_script    # refuse to update a script in a user-writable dir
    resolve_update_url           # belt-and-braces: refresh URL from disk config

    local old_ver="$SCRIPT_VERSION"
    log "Local version: $old_ver"
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
    verify_downloaded_file "$tmp" || { rm -f "$tmp"; die "Anti-tamper verification failed"; }

    # Parse version of the downloaded file (informational; hash compare below
    # is the source of truth for "is it actually different content?").
    local new_ver
    new_ver="$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$tmp")"
    [[ -n "$new_ver" ]] || new_ver="(unknown)"

    # No-op short-circuit: byte-identical content → already on latest, skip
    # backup + install entirely.  Avoids cron leaving daily *.bak files.
    local current_hash new_hash
    current_hash="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
    new_hash="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ -n "$current_hash" && "$current_hash" == "$new_hash" ]]; then
        rm -f "$tmp"
        ok "Already on latest version ($old_ver) — no changes"
        return 0
    fi

    local backup="${SCRIPT_PATH}.bak.${TS}"
    cp -a "$SCRIPT_PATH" "$backup" || die "Backup of current script failed"
    if ! install -m 755 "$tmp" "$SCRIPT_PATH" 2>/dev/null; then
        # /usr/bin/install may not exist on truly minimal images — fall back
        cp "$tmp" "$SCRIPT_PATH" && chmod 755 "$SCRIPT_PATH" || {
            rm -f "$tmp"; die "Install of new script failed"
        }
    fi
    rm -f "$tmp"

    if [[ "$old_ver" == "$new_ver" ]]; then
        ok "Reinstalled $new_ver  (script content changed without version bump; backup: $backup)"
    elif ver_lt "$old_ver" "$new_ver"; then
        ok "Updated $old_ver → $new_ver  (backup: $backup)"
    else
        warn "Downgraded $old_ver → $new_ver  (backup: $backup)"
    fi

    # Self-heal auto-update task on hosts that already have one configured.
    # The newly installed code may include fixes to install_auto_update itself
    # (e.g. v1.6.7 SIGPIPE fix, v1.6.8 duplicate-state cleanup).  Best-effort —
    # auto-update is not a hard dependency of self-update.
    if [[ -f "$AUTO_UPDATE_SYSTEMD_TIMER" || -f "$AUTO_UPDATE_CRON_FILE" ]]; then
        log "Refreshing auto-update task with the freshly-installed code..."
        if "$SCRIPT_PATH" --install-auto-update >/dev/null 2>&1; then
            ok "Auto-update task refreshed"
        else
            warn "Auto-update task refresh failed; run 'sudo kh-duo --remove-auto-update && sudo kh-duo --install-auto-update' to recover"
        fi
    fi

    # Trim old script .bak.* files (keep newest N — see BACKUP_RETENTION_COUNT).
    cleanup_old_backups "${SCRIPT_PATH}.bak.*" file

    log "Re-run to load the new code: sudo $SCRIPT_PATH"
}

# Creates /usr/local/bin/kh-duo (or $KH_DUO_SHORTCUT) → $SCRIPT_PATH.
install_shortcut() {
    [[ -f "$SCRIPT_PATH" ]] || die "Cannot find script at '$SCRIPT_PATH'"
    require_root_owned_script    # otherwise sudo kh-duo would later run a user-owned target

    # Whitelist shortcut destinations.  An attacker leaking KH_DUO_SHORTCUT
    # through sudo could otherwise drop a symlink into /etc/cron.hourly/,
    # /etc/init.d/, or any other auto-execution path.
    case "$SHORTCUT_PATH" in
        /usr/local/bin/*|/usr/local/sbin/*|/usr/bin/*|/usr/sbin/*) ;;
        *) die "Refusing shortcut path '$SHORTCUT_PATH' — must be under /usr/local/{bin,sbin}/ or /usr/{bin,sbin}/" ;;
    esac

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

### ─── Auto-update timer/cron ─────────────────────────────────────────────
# Goal (mirrors the Windows scheduled task model): every day at 04:00 the
# host should `kh-duo --update --no-menu --yes` itself.  We try systemd
# timer first; if systemd is absent (Alpine + OpenRC, BSD jails, very old
# distros) we fall back to /etc/cron.d.  Verify after install — refuse to
# claim success if neither sticks.

has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

# Returns 0 if a cron daemon is installed AND running (so /etc/cron.d
# entries will actually fire).  We accept multiple ways to detect this
# because cron services have inconsistent names across distros.
has_cron_daemon() {
    [[ -d /etc/cron.d ]] || return 1
    if has_systemd; then
        for svc in cron crond; do
            systemctl is-active "$svc" >/dev/null 2>&1 && return 0
        done
        for svc in cron crond; do
            systemctl is-enabled "$svc" >/dev/null 2>&1 && return 0
        done
    fi
    if command -v service >/dev/null 2>&1; then
        for svc in cron crond; do
            service "$svc" status >/dev/null 2>&1 && return 0
        done
    fi
    pgrep -x cron  >/dev/null 2>&1 && return 0
    pgrep -x crond >/dev/null 2>&1 && return 0
    return 1
}

install_auto_update_systemd() {
    log "Writing systemd timer for daily auto-update at ${AUTO_UPDATE_HOUR}:00"

    cat > "$AUTO_UPDATE_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Kazuha Hub Duo SSH installer auto-update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --update --no-menu --yes
StandardOutput=journal
StandardError=journal
EOF

    cat > "$AUTO_UPDATE_SYSTEMD_TIMER" <<EOF
[Unit]
Description=Daily auto-update for Kazuha Hub Duo SSH installer

[Timer]
OnCalendar=*-*-* ${AUTO_UPDATE_HOUR}:00:00
Persistent=true
RandomizedDelaySec=15min
Unit=kh-duo-update.service

[Install]
WantedBy=timers.target
EOF

    chmod 644 "$AUTO_UPDATE_SYSTEMD_SERVICE" "$AUTO_UPDATE_SYSTEMD_TIMER"

    systemctl daemon-reload || { warn "systemctl daemon-reload failed"; return 1; }
    systemctl enable --now kh-duo-update.timer >/dev/null 2>&1 \
        || { warn "systemctl enable --now kh-duo-update.timer failed"; return 1; }

    # Verify it's actually scheduled.  We capture list-timers output to a
    # local var BEFORE pattern-matching: piping into `grep -q` makes grep
    # close its stdin as soon as it finds a match, which sends SIGPIPE to
    # `systemctl list-timers`, and `set -o pipefail` (set at the top of the
    # script) then propagates that 141 exit code as the pipe's exit — the
    # whole `&&` chain falsely reads as "verify failed" even when the timer
    # is actually scheduled.  Capturing first sidesteps the SIGPIPE entirely.
    if ! systemctl is-enabled kh-duo-update.timer >/dev/null 2>&1; then
        return 1
    fi
    local timers_out
    timers_out="$(systemctl list-timers kh-duo-update.timer --no-pager 2>/dev/null)"
    if [[ "$timers_out" != *"kh-duo-update"* ]]; then
        return 1
    fi
    local nextrun
    nextrun="$(printf '%s\n' "$timers_out" | awk '/kh-duo-update/{print $1, $2; exit}')"
    ok "systemd timer enabled  (next run: ${nextrun:-unknown})"
    return 0
}

install_auto_update_cron() {
    log "Writing cron entry for daily auto-update at ${AUTO_UPDATE_HOUR}:00"

    # Up to 15 min jitter to spread fleet load.  awk srand() works across
    # /bin/sh, dash, ash, etc — unlike $RANDOM which is bash-specific.
    cat > "$AUTO_UPDATE_CRON_FILE" <<EOF
# Kazuha Hub Duo SSH installer auto-update (managed by install-duo-ssh.sh)
# Daily at ${AUTO_UPDATE_HOUR}:00 with up to 15 minutes of randomized jitter.
SHELL=/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
0 ${AUTO_UPDATE_HOUR} * * * root sleep \$(awk 'BEGIN{srand();print int(rand()*900)}'); $SCRIPT_PATH --update --no-menu --yes >/dev/null 2>&1
EOF
    chmod 644 "$AUTO_UPDATE_CRON_FILE"
    chown root:root "$AUTO_UPDATE_CRON_FILE" 2>/dev/null || true

    [[ -f "$AUTO_UPDATE_CRON_FILE" ]] || { err "Failed to write $AUTO_UPDATE_CRON_FILE"; return 1; }
    ok "Cron entry written: $AUTO_UPDATE_CRON_FILE"
    return 0
}

# Public entrypoint — try systemd, fall back to cron, hard-fail if neither.
# Self-heals duplicate state: when one path succeeds, any artifacts of the
# OTHER path are removed.  This cleans up hosts left in dual-task state by
# the v1.5.0-v1.6.6 SIGPIPE bug (where systemd timer was installed, then
# the verify check falsely failed and the script also wrote a cron entry).
install_auto_update() {
    [[ -n "${SCRIPT_PATH:-}" ]] || die "install_auto_update: SCRIPT_PATH not set"

    log "Setting up daily auto-update (mirrors --update --no-menu --yes)"

    if has_systemd; then
        if install_auto_update_systemd; then
            # systemd is the authoritative path on this host — drop any cron
            # leftover so the daily 04:00 update doesn't fire twice.
            if [[ -f "$AUTO_UPDATE_CRON_FILE" ]]; then
                rm -f "$AUTO_UPDATE_CRON_FILE"
                log "Cleaned up duplicate cron entry left over from older releases"
            fi
            return 0
        fi
        warn "systemd timer install failed — falling back to cron"
    else
        log "systemd not detected — using cron"
    fi

    if has_cron_daemon; then
        if install_auto_update_cron; then
            # cron is the authoritative path — tear down any stale systemd units.
            if [[ -f "$AUTO_UPDATE_SYSTEMD_TIMER" || -f "$AUTO_UPDATE_SYSTEMD_SERVICE" ]]; then
                if has_systemd; then
                    systemctl disable --now kh-duo-update.timer >/dev/null 2>&1 || true
                fi
                rm -f "$AUTO_UPDATE_SYSTEMD_TIMER" "$AUTO_UPDATE_SYSTEMD_SERVICE"
                if has_systemd; then
                    systemctl daemon-reload >/dev/null 2>&1 || true
                fi
                log "Cleaned up duplicate systemd timer left over from older releases"
            fi
            ok "cron entry will run daily at ${AUTO_UPDATE_HOUR}:00 (with up to 15m jitter)"
            return 0
        fi
        return 1
    fi

    err "Could not enable auto-update: no working systemd timer, and no cron daemon detected."
    err "Schedule '$SCRIPT_PATH --update --no-menu --yes' yourself (Ansible / cron / etc.)"
    return 1
}

# Idempotent removal: drops both systemd units and the cron file regardless
# of which one is currently in use.
uninstall_auto_update() {
    local removed=0
    if [[ -f "$AUTO_UPDATE_SYSTEMD_TIMER" || -f "$AUTO_UPDATE_SYSTEMD_SERVICE" ]]; then
        if has_systemd; then
            systemctl disable --now kh-duo-update.timer >/dev/null 2>&1 || true
        fi
        rm -f "$AUTO_UPDATE_SYSTEMD_TIMER" "$AUTO_UPDATE_SYSTEMD_SERVICE"
        if has_systemd; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        ok "Removed systemd auto-update timer"
        removed=1
    fi
    if [[ -f "$AUTO_UPDATE_CRON_FILE" ]]; then
        rm -f "$AUTO_UPDATE_CRON_FILE"
        ok "Removed cron auto-update entry: $AUTO_UPDATE_CRON_FILE"
        removed=1
    fi
    [[ $removed -eq 0 ]] && log "No auto-update entries to remove"
    return 0
}

# One-line status string for show_current_config / final banner.
auto_update_status() {
    if [[ -f "$AUTO_UPDATE_SYSTEMD_TIMER" ]]; then
        if has_systemd && systemctl is-enabled kh-duo-update.timer >/dev/null 2>&1; then
            # Capture list-timers output first; awk's `exit` would otherwise
            # SIGPIPE the upstream systemctl and pipefail would surface that
            # as a non-zero exit (cosmetic effect: shows "unknown" timer time
            # in the status string).
            local timers_out nextrun
            timers_out="$(systemctl list-timers kh-duo-update.timer --no-pager 2>/dev/null)"
            nextrun="$(printf '%s\n' "$timers_out" | awk '/kh-duo-update/{print $1, $2; exit}')"
            printf 'systemd timer (next: %s)' "${nextrun:-unknown}"
            return
        fi
        printf 'systemd timer (file present, NOT enabled)'
        return
    fi
    if [[ -f "$AUTO_UPDATE_CRON_FILE" ]]; then
        printf 'cron (%s)' "$AUTO_UPDATE_CRON_FILE"
        return
    fi
    printf '(disabled)'
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
    warn "Update available: $SCRIPT_VERSION → $remote (run 'sudo $SCRIPT_PATH --update' to install, or pick the menu option below)"
    confirm "Download and install now?" || { ok "Skipped."; return 0; }
    self_update
    exit 0
}

# Read current Duo config from disk into the global vars (IKEY/SKEY/HOST,
# ALLOW_PASSWORD, BYPASS_LOCAL, BYPASS_ADDRS, BREAKGLASS_USER).  Used by the
# "Adjust settings" and "Show current config" menu items.  Scopes parsing of
# Match Address / Match User to the Duo block we wrote, so user-managed
# unrelated Match blocks elsewhere in sshd_config aren't confused for ours.
read_existing_config() {
    if [[ -f "$PAM_DUO_CONF" ]]; then
        IKEY="$(awk -F'[[:space:]]*=[[:space:]]*' '/^[[:space:]]*ikey[[:space:]]*=/{print $2; exit}' "$PAM_DUO_CONF")"
        SKEY="$(awk -F'[[:space:]]*=[[:space:]]*' '/^[[:space:]]*skey[[:space:]]*=/{print $2; exit}' "$PAM_DUO_CONF")"
        HOST="$(awk -F'[[:space:]]*=[[:space:]]*' '/^[[:space:]]*host[[:space:]]*=/{print $2; exit}' "$PAM_DUO_CONF")"
    fi

    if [[ ! -f "$SSHD_CONFIG" ]]; then return 0; fi

    # Slice out only the script-managed block.  Prefer the v1.6.5+ sentinels
    # (kh-duo-sshd-begin / kh-duo-sshd-end) which give exact boundaries; fall
    # back to the legacy "# === Duo 2FA for SSH (PAM mode" header → EOF for
    # older installs that haven't been re-applied under v1.6.5.
    local duo_block
    duo_block="$(awk '
        /^# kh-duo-sshd-begin/ {flag=1; next}
        /^# kh-duo-sshd-end/   {flag=0; exit}
        flag {print}
    ' "$SSHD_CONFIG")"
    if [[ -z "$duo_block" ]]; then
        duo_block="$(awk '/^# === Duo 2FA for SSH \(PAM mode/{flag=1} flag' "$SSHD_CONFIG")"
    fi
    [[ -z "$duo_block" ]] && return 0

    if printf '%s\n' "$duo_block" | grep -qE '^[[:space:]]*AuthenticationMethods[[:space:]]+publickey,keyboard-interactive:pam[[:space:]]+keyboard-interactive:pam'; then
        ALLOW_PASSWORD=1
    else
        ALLOW_PASSWORD=0
    fi

    local addr_line
    addr_line="$(printf '%s\n' "$duo_block" | awk '/^[[:space:]]*Match Address /{sub(/^[[:space:]]*Match Address /,""); print; exit}')"
    if [[ -n "$addr_line" ]]; then
        local addrs="$addr_line"
        if [[ "$addrs" == 127.0.0.0/8,::1* ]]; then
            BYPASS_LOCAL=1
            addrs="${addrs#127.0.0.0/8,::1}"
            addrs="${addrs#,}"
        else
            BYPASS_LOCAL=0
        fi
        BYPASS_ADDRS="$addrs"
    else
        BYPASS_LOCAL=0
        BYPASS_ADDRS=""
    fi

    BREAKGLASS_USER="$(printf '%s\n' "$duo_block" | awk '/^[[:space:]]*Match User /{print $3; exit}')"
}

# Classify a persisted mirror URL into a human-readable provider label.
# Used by print_config_summary so users can see at a glance whether they're
# on canonical github vs a CDN preset vs a custom URL.
classify_mirror_url() {
    local url="$1"
    case "$url" in
        "")
            echo "canonical github  (default — no mirror configured)"
            ;;
        https://cdn.jsdelivr.net/gh/KazuhaHub/ops-scripts@*)
            echo "jsDelivr CDN  (--use-cdn jsdelivr)"
            ;;
        https://cdn.statically.io/gh/KazuhaHub/ops-scripts/*)
            echo "Statically CDN  (--use-cdn statically)"
            ;;
        https://raw.githubusercontent.com/KazuhaHub/ops-scripts/*)
            echo "canonical github  (explicit override)"
            ;;
        *)
            echo "custom mirror"
            ;;
    esac
}

# Pretty-print whatever is currently in the global vars.  This does NOT touch
# disk — useful inside the adjust-settings loop where the in-memory state
# already reflects the user's pending toggles (calling read_existing_config
# here would clobber those toggles by overwriting them with disk values).
print_config_summary() {
    echo
    log "Current Duo SSH configuration"
    if [[ ! -f "$PAM_DUO_CONF" || -z "$IKEY" ]]; then
        warn "  No Duo config found at $PAM_DUO_CONF — Duo is not installed yet."
        return
    fi
    local _ch _url _src
    _ch="$(get_effective_channel)"
    _url="$(get_persistent_url)"
    _src="$(classify_mirror_url "$_url")"
    cat <<EOF
  Duo
    Application key:  ${IKEY:0:8}…
    API host:         ${HOST:-(not set)}

  Login policy
    Auth mode:        $([[ $ALLOW_PASSWORD -eq 1 ]] && echo 'publickey OR password + Duo' || echo 'publickey + Duo only')
    Localhost bypass: $([[ $BYPASS_LOCAL -eq 1 ]] && echo 'ON  (127.0.0.0/8, ::1)' || echo 'OFF')
    Extra bypass:     ${BYPASS_ADDRS:-(none)}
    Breakglass user:  ${BREAKGLASS_USER:-(none)}

  Updates
    Channel:          $_ch
    Source:           $_src${_url:+
    URL:              $_url}
    Auto-update task: $(auto_update_status)
EOF
}

# Read disk state, then print.  Use this for the main menu's "Show current
# configuration" option, where the user wants the on-disk truth.
show_current_config() {
    read_existing_config
    print_config_summary
}

# Sub-menu: toggle individual settings without re-asking for credentials.
# Returns 0 on "Apply" → caller (interactive_menu) returns to main, which then
# runs the normal install pipeline using the updated globals.  Returns 1 (or
# exits) if the user cancels.
menu_adjust_settings() {
    if [[ ! -f "$PAM_DUO_CONF" ]]; then
        warn "Cannot adjust settings — no Duo config at $PAM_DUO_CONF."
        warn "Use option 1 (Install / configure) for first-time setup."
        return 1
    fi

    # Read disk state ONCE on entry.  The loop below uses print_config_summary
    # (no disk read) so user toggles persist in-memory across iterations and
    # are correctly reflected in the next render.
    read_existing_config

    if [[ -z "$IKEY" || -z "$SKEY" || -z "$HOST" ]]; then
        die "Could not read existing Duo credentials from $PAM_DUO_CONF"
    fi

    while true; do
        print_config_summary
        echo
        echo "Adjust which setting?"
        echo "  1) Toggle password fallback         (currently: $([[ $ALLOW_PASSWORD -eq 1 ]] && echo ON || echo OFF))"
        echo "  2) Toggle localhost bypass          (currently: $([[ $BYPASS_LOCAL -eq 1 ]] && echo ON || echo OFF))"
        echo "  3) Set/clear extra bypass CIDRs     (currently: ${BYPASS_ADDRS:-none})"
        echo "  4) Set/clear breakglass user        (currently: ${BREAKGLASS_USER:-none})"
        echo "  5) Apply pending changes (re-run install)"
        echo "  q) Cancel (no changes applied)"
        echo
        local action=""
        read -r -p "Choice: " action
        case "$action" in
            1)  ALLOW_PASSWORD=$((1 - ALLOW_PASSWORD));  ok "Password fallback now: $([[ $ALLOW_PASSWORD -eq 1 ]] && echo ON || echo OFF)" ;;
            2)  BYPASS_LOCAL=$((1 - BYPASS_LOCAL));      ok "Localhost bypass now: $([[ $BYPASS_LOCAL -eq 1 ]] && echo ON || echo OFF)" ;;
            3)
                local cidrs=""
                read -r -p "  Bypass CIDRs (comma-separated, empty to clear): " cidrs
                BYPASS_ADDRS="$cidrs"
                ok "Extra bypass CIDRs: ${BYPASS_ADDRS:-(none)}"
                ;;
            4)
                local bg=""
                read -r -p "  Breakglass username (empty to clear): " bg
                BREAKGLASS_USER="$bg"
                ok "Breakglass user: ${BREAKGLASS_USER:-(none)}"
                ;;
            5)
                # Show in-memory state (NOT disk) — this is what we are about to apply.
                print_config_summary
                echo
                # Bypass install_wizard prompts; install pipeline still runs normally.
                ASSUME_YES=1
                NO_MENU=1
                INTERACTIVE_FLAGS_USED=1
                if confirm "Re-apply with these settings (will restart sshd)?"; then
                    return 0
                fi
                ok "Cancelled."
                return 1
                ;;
            q|Q)
                ok "No changes applied."
                exit 0
                ;;
            *)  warn "Invalid choice '$action'" ;;
        esac
    done
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

    # Detect existing SSH keys to choose a smart default.
    local has_keys=0
    for home in /root "${SUDO_USER:+$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)}"; do
        [[ -z "$home" ]] && continue
        for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
            [[ -s "$f" ]] && { has_keys=1; break 2; }
        done
    done

    local pw_default
    if [[ $has_keys -eq 1 ]]; then
        ok   "  Detected SSH key(s) — recommending publickey-only mode."
        echo "  Allow password+Duo as a fallback for users without SSH keys?"
        pw_default="n"
    else
        warn "  No SSH keys detected on this server."
        warn "  Without a key, you can ONLY log in with password+Duo."
        warn "  STRONGLY RECOMMENDED: add an SSH public key first, then re-run this script."
        echo "  Defaulting to ALLOW password+Duo to prevent lockout. Force publickey-only?"
        pw_default="y"   # default to "yes allow password" (i.e. answer "n" to the inverted "force publickey-only")
    fi

    if [[ $has_keys -eq 1 ]]; then
        if menu_yes_no "Allow password fallback?" "$pw_default"; then
            ALLOW_PASSWORD=1
        fi
    else
        # Inverted prompt — defaults to "n" (don't force publickey-only).
        if menu_yes_no "Force publickey-only anyway? (you WILL be locked out without keys)" "n"; then
            ALLOW_PASSWORD=0
        else
            ALLOW_PASSWORD=1
        fi
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
    local _ch _ch_label
    _ch="$(get_effective_channel)"
    case "$_ch" in
        beta)   _ch_label=$'\033[1;33mbeta\033[0m' ;;   # warn-color: beta = soak-test, careful
        stable) _ch_label="stable" ;;
        *)      _ch_label="$_ch" ;;
    esac

    cat <<BANNER

╔═══════════════════════════════════════════════════════════════════════╗
║         Duo 2FA for SSH — Interactive Setup                           ║
╚═══════════════════════════════════════════════════════════════════════╝
  install-duo-ssh.sh v${SCRIPT_VERSION}  •  channel: ${_ch_label}   (use --no-menu or any flag to skip the wizard)
BANNER

    while true; do
        cat <<'EOF'

What would you like to do?
  1) Install / configure              (full setup with new credentials)
  2) Adjust login policy              (auth, bypass, breakglass)
  3) Show current configuration
  4) Check for and install updates
  5) Update settings                  (channel, mirror, auto-update task)
  6) Uninstall Duo 2FA
  q) Quit
EOF
        echo
        local action=""
        read -r -p "Choice [1]: " action
        case "${action:-1}" in
            1|"") install_wizard; return 0 ;;
            2)    menu_adjust_settings && return 0 ;;
            3)    show_current_config ;;
            4)    menu_check_and_update ;;
            5)    menu_update_settings ;;
            6)    menu_uninstall_flow; return 0 ;;
            q|Q)  ok "No changes made."; exit 0 ;;
            *)    warn "Invalid choice '$action'" ;;
        esac
    done
}

# Sub-menu: everything related to where/when updates come from.
menu_update_settings() {
    while true; do
        local _ch _url _src _auto
        _ch="$(get_effective_channel)"
        _url="$(get_persistent_url)"
        _src="$(classify_mirror_url "$_url")"
        _auto="$(auto_update_status)"

        echo
        log "Update settings"
        echo "  Channel:          $_ch"
        echo "  Source:           $_src"
        [[ -n "$_url" ]] && echo "  URL:              $_url"
        echo "  Auto-update task: $_auto"
        echo
        local _toggle_label
        if [[ "$_auto" == "(disabled)" ]]; then
            _toggle_label="Enable auto-update task   (daily 04:00 via systemd timer / cron)"
        else
            _toggle_label="Disable auto-update task  (currently active)"
        fi
        cat <<EOF
  1) Switch update channel  ($_ch -> $([[ "$_ch" == "stable" ]] && echo beta || echo stable))
  2) Set mirror URL         (override channel default — for CN proxies, internal forks)
  3) Clear mirror URL       (revert to channel default)
  4) $_toggle_label
  5) Check for and install updates
  q) Back to main menu
EOF
        echo
        local action=""
        read -r -p "Choice: " action
        case "$action" in
            1) menu_switch_channel; resolve_update_url ;;
            2) menu_prompt_mirror_url; resolve_update_url ;;
            3) clear_mirror; resolve_update_url ;;
            4) menu_toggle_auto_update ;;
            5) menu_check_and_update ;;
            q|Q) return 0 ;;
            *)   warn "Invalid choice '$action'" ;;
        esac
    done
}

menu_switch_channel() {
    local cur target
    cur="$(get_effective_channel)"
    if [[ "$cur" == "stable" ]]; then target="beta"; else target="stable"; fi

    echo
    if [[ "$target" == "beta" ]]; then
        warn "Switching to BETA channel"
        echo "  beta = preview branch, gets new releases first."
        echo "  Test hosts only — don't use on production fleet until validated."
        echo "  Effective URL will become:  $SCRIPT_BETA_URL"
    else
        warn "Switching back to STABLE channel"
        echo "  Effective URL will become:  $SCRIPT_STABLE_URL"
    fi
    echo
    if confirm "Persist channel '$target' to $SCRIPT_CONFIG_FILE?"; then
        set_channel "$target"
    else
        ok "Cancelled."
    fi
}

menu_prompt_mirror_url() {
    echo
    echo "  Pick a mirror source:"
    echo "    1) jsDelivr     (recommended for CN — public CDN, mirrors GitHub)"
    echo "    2) Statically   (alternate CDN, also CN-friendly)"
    echo "    3) Custom URL   (paste your own — ghproxy / internal mirror / etc.)"
    echo "    q) Cancel"
    echo
    local pick=""
    read -r -p "  Choice [1]: " pick
    case "${pick:-1}" in
        1) use_cdn jsdelivr ;;
        2) use_cdn statically ;;
        3)
            echo
            echo "  Examples:"
            echo "    https://ghproxy.com/https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh"
            echo "    https://ghfast.top/https://raw.githubusercontent.com/KazuhaHub/ops-scripts/master/ssh/install-duo-ssh.sh"
            echo
            local url=""
            read -r -p "  Mirror URL (https://...): " url
            [[ -z "$url" ]] && { warn "Empty URL — cancelled."; return 0; }
            set_mirror "$url"
            ;;
        q|Q) ok "Cancelled."; return 0 ;;
        *)   warn "Invalid choice '$pick' — cancelled."; return 0 ;;
    esac
}

menu_toggle_auto_update() {
    if [[ -f "$AUTO_UPDATE_SYSTEMD_TIMER" || -f "$AUTO_UPDATE_CRON_FILE" ]]; then
        echo
        warn "Disabling daily auto-update means this host won't pick up new versions"
        warn "automatically.  You'll need to run 'sudo kh-duo --update' manually."
        if confirm "Disable auto-update task?"; then
            uninstall_auto_update
        else
            ok "No change."
        fi
    else
        echo
        log "Will register a daily 04:00 task running '$SCRIPT_PATH --update --no-menu --yes'"
        log "(systemd timer if available, cron fallback)."
        if confirm "Enable auto-update task?"; then
            install_auto_update
        else
            ok "No change."
        fi
    fi
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
        apt_get update -qq
        apt_get install -y python3 >/dev/null
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

# Trim old backup artifacts, keeping the N most recent (by name — our
# backups all carry a YYYYMMDD-HHMMSS suffix so lexical sort = chronological).
# Called after a SUCCESSFUL install / self-update so we never delete the
# safety net for the operation that just ran.
#   $1 — glob pattern (must match the YYYYMMDD-HHMMSS-suffixed artifacts)
#   $2 — operand: file | dir
cleanup_old_backups() {
    local pattern="$1"
    local kind="$2"
    local keep="$BACKUP_RETENTION_COUNT"

    [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
    (( keep <= 0 )) && return 0   # 0 disables cleanup

    # Collect matching paths via shell glob (no eval — pattern is a literal).
    local matches=()
    case "$kind" in
        dir)
            while IFS= read -r -d '' d; do
                matches+=("$d")
            done < <(find "$(dirname "$pattern")" -maxdepth 1 -type d -name "$(basename "$pattern")" -print0 2>/dev/null | sort -z)
            ;;
        file)
            while IFS= read -r -d '' f; do
                matches+=("$f")
            done < <(find "$(dirname "$pattern")" -maxdepth 1 -type f -name "$(basename "$pattern")" -print0 2>/dev/null | sort -z)
            ;;
        *) return 0 ;;
    esac

    local total="${#matches[@]}"
    (( total > keep )) || return 0

    local trim=$(( total - keep ))
    local i removed=0
    for (( i=0; i<trim; i++ )); do
        rm -rf "${matches[$i]}" 2>/dev/null && (( removed++ ))
    done
    (( removed > 0 )) && log "Backup cleanup: removed $removed old artifact(s) ($pattern), keeping $keep most recent"
    return 0
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
    [[ $SKIP_KEY_CHECK -eq 1 ]] && { warn "Skipping authorized_keys check (--skip-key-check)"; return 0; }

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

    if [[ $found -eq 1 ]]; then
        # Keys present — publickey-only is safe.  Whatever ALLOW_PASSWORD was
        # set to (default 0, or 1 from --allow-password / wizard) stays.
        return 0
    fi

    # No keys found.
    if [[ $STRICT_PUBLICKEY -eq 1 ]]; then
        die "No SSH authorized_keys found and --strict-publickey is set. Add a key first, or drop --strict-publickey to auto-enable password fallback."
    fi

    if [[ $ALLOW_PASSWORD -eq 1 ]]; then
        warn "No SSH keys found — proceeding with password+key+Duo (--allow-password set)."
        warn "STRONGLY RECOMMENDED: add an SSH public key and rerun this script to disable password fallback."
        return 0
    fi

    # Auto-adapt: enable password fallback so admin doesn't lock themselves out.
    warn "============================================================"
    warn "  No SSH authorized_keys found for root${SUDO_USER:+ or $SUDO_USER}."
    warn "  Auto-enabling password fallback (publickey OR password + Duo)."
    warn "  Without a key, every login uses your account password + Duo."
    warn ""
    warn "  STRONGLY RECOMMENDED: add an SSH public key and rerun this"
    warn "  script (or pass --strict-publickey) to switch to key-only mode."
    warn "============================================================"
    ALLOW_PASSWORD=1
    return 0
}

### ─── Package installation ──────────────────────────────────────────────
# apt-get wrapper that waits up to 2 minutes for the dpkg lock instead of
# failing immediately.  Without this, --reinstall hits a race: Phase 1's
# `apt-get remove duo-unix` releases the lock; before Phase 2 grabs it,
# Debian's apt-daily.timer (or unattended-upgrades) can sneak in and hold
# the lock for several minutes — Phase 2's `apt-get install` then dies and
# leaves the host with sshd_config Duo block already torn down by Phase 1
# but no Duo binary back in place.  DPkg::Lock::Timeout is supported by
# apt 1.9.11+ (Debian 12 has 2.6+, Ubuntu 20.04+ has 2.0+, all fine).
APT_GET_OPTS=(-o DPkg::Lock::Timeout=120)
apt_get() { apt-get "${APT_GET_OPTS[@]}" "$@"; }

install_duo_apt() {
    log "Adding Duo official APT repository (pkg.duosecurity.com)"
    apt_get install -y -qq apt-transport-https curl gnupg >/dev/null 2>&1

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
    apt_get update -qq
    apt_get install -y duo-unix
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
            apt_get remove -y libpam-duo libduo3 >/dev/null 2>&1 || true
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
    uninstall_auto_update
    backup_file "$SSHD_CONFIG"
    backup_file "$PAM_SSHD"

    # Remove the script-managed Duo block from sshd_config.
    # Same two-pass strip as apply_sshd: new sentinel format first, then
    # legacy-format fallback (covers v1.6.4-and-earlier installs that may
    # have accumulated multiple stale Match blocks).
    python3 - "$SSHD_CONFIG" <<'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()

text = re.sub(
    r'(?ms)\n*^# kh-duo-sshd-begin\b.*?^# kh-duo-sshd-end\b[^\n]*\n?',
    '\n', text)

text = re.sub(
    r'(?ms)\n*^# === Duo 2FA for SSH\b.*\Z',
    '\n', text)

# Belt-and-braces: also strip any remaining stray top-level AuthMethods
# the script could have written outside both formats.
text = re.sub(
    r'(?m)^\s*AuthenticationMethods\s+publickey,keyboard-interactive:pam\b[^\n]*\n',
    '', text)

text = re.sub(r'\n{3,}', '\n\n', text)
text = text.rstrip() + '\n'
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
        dpkg -l duo-unix    2>/dev/null | grep -q '^ii' && apt_get remove -y duo-unix              >/dev/null 2>&1 || true
        dpkg -l libpam-duo  2>/dev/null | grep -q '^ii' && apt_get remove -y libpam-duo libduo3    >/dev/null 2>&1 || true
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

    # ── Strip ANY previously-written Duo block FIRST (idempotent) ──────
    # Order matters: this MUST run before the directive checks below.  The
    # legacy strip is anchored to EOF (^# === Duo 2FA for SSH\b.*\Z), so
    # any line a directive check below appends to the END of the file
    # would land inside the legacy block and be silently eaten by this
    # strip.  Repro: re-run on a v1.6.4 host whose stock sshd_config has
    # no PasswordAuthentication line at all → printf appends it past the
    # legacy header, then the strip wipes it, and the rewritten Duo block
    # is left without it.
    #
    # Two passes:
    #
    #   1. New format (v1.6.5+): everything between "# kh-duo-sshd-begin"
    #      and "# kh-duo-sshd-end" sentinel comments.  Single regex, robust
    #      across multiple re-runs.
    #
    #   2. Legacy format (≤ v1.6.4): from the first "# === Duo 2FA for SSH"
    #      header through EOF.  Pre-1.6.5 always *appended* its block at the
    #      end of the file, so anything from that header onwards was ours.
    #      This catches the broken-state where re-running the installer
    #      stacked multiple Match blocks (the bug fixed by v1.6.5 — a stray
    #      "AuthenticationMethods publickey,keyboard-interactive:pam" line
    #      ended up nested inside a Match block, only enforcing Duo for
    #      127.0.0.0/8 connections while leaving the global scope as 'any').
    python3 - "$SSHD_CONFIG" <<'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()

# (1) Strip new-format sentinel block (current and future installs)
text = re.sub(
    r'(?ms)\n*^# kh-duo-sshd-begin\b.*?^# kh-duo-sshd-end\b[^\n]*\n?',
    '\n', text)

# (2) Legacy strip: from first "# === Duo 2FA for SSH" header to EOF.
#     This deletes the v1.6.4-and-earlier appended block, including all
#     accumulated stale Match blocks left behind by the old broken cleanup.
text = re.sub(
    r'(?ms)\n*^# === Duo 2FA for SSH\b.*\Z',
    '\n', text)

# Tidy: collapse runs of 3+ blank lines down to exactly one
text = re.sub(r'\n{3,}', '\n\n', text)
# Ensure file ends with a single newline
text = text.rstrip() + '\n'
p.write_text(text)
PYEOF

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
        printf 'PasswordAuthentication %s\n' "$pw_val" >> "$SSHD_CONFIG"
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

    # ── Write fresh Duo block, fully wrapped in sentinels ──────────────
    # Default:           publickey + Duo (PAM stack = pam_duo only)
    # --allow-password:  publickey path runs the full pam_unix+pam_duo stack
    #                    (so publickey users see one password+Duo prompt set);
    #                    the second alternative `keyboard-interactive:pam`
    #                    lets keyless users authenticate via password+Duo.
    #                    We avoid `password,keyboard-interactive:pam` because
    #                    it would invoke PAM twice and double-prompt.
    local auth_line
    if [[ $ALLOW_PASSWORD -eq 1 ]]; then
        auth_line='AuthenticationMethods publickey,keyboard-interactive:pam keyboard-interactive:pam'
    else
        auth_line='AuthenticationMethods publickey,keyboard-interactive:pam'
    fi

    {
        echo ""
        echo "# kh-duo-sshd-begin (managed by install-duo-ssh.sh — do not edit between markers)"
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

        echo "# kh-duo-sshd-end"
    } >> "$SSHD_CONFIG"
    ok "Added AuthenticationMethods"
    if [[ $BYPASS_LOCAL -eq 1 ]];      then ok "Bypass Duo for localhost and self connections"; fi
    if [[ -n "$BYPASS_ADDRS" ]];       then ok "Bypass Duo for: $BYPASS_ADDRS"; fi
    if [[ -n "$BREAKGLASS_USER" ]];    then ok "Breakglass user: $BREAKGLASS_USER (bypasses Duo)"; fi
    return 0   # explicit success — bare `[[ ]] && ...` chains above can leak a non-zero exit when all conditions are false, which set -e would treat as a function failure and roll back the whole install
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

### ─── Migration patches (version-targeted) ──────────────────────────────
# One-shot fixes for vestigial state left by past bugs.  Each patch is named
# patch_<introduced_version>_<short_label> and registered in MIGRATION_PATCHES
# in version order.
#
# Runtime model:
#   1. /var/lib/install-duo-ssh/last_applied records the last-applied version.
#   2. On every root invocation we compute the gap (last_applied, current].
#   3. Any patch whose target version sits in that gap runs once, then the
#      file is updated to the current version so subsequent invocations skip.
#
# Each patch ALSO validates its own preconditions before mutating.  Version
# targeting decides "when to consider running"; the condition check decides
# "is it safe to actually mutate".  Belt-and-suspenders for fresh installs
# (which have no residue but whose last_applied also reads as 0.0.0).
#
# Removal lifecycle: a patch becomes safe to drop once the fleet has all
# hosts on a version >= patch.target + a safety margin.  Drop both the
# function definition and its MIGRATION_PATCHES entry — the runner ignores
# missing functions silently.

PATCH_STATE_DIR="/var/lib/install-duo-ssh"
PATCH_STATE_FILE="$PATCH_STATE_DIR/last_applied"

# (target_version function_name) — keep ordered ascending by version.
MIGRATION_PATCHES=(
    "1.6.9 patch_1_6_9_dual_task_cleanup"
)

# patch_1_6_9_dual_task_cleanup
#   Introduced: v1.6.9
#   Drop after: fleet on >= 1.6.9 for one --update cycle (target: v2.0)
#   Fixes:      install_auto_update_systemd SIGPIPE bug in v1.5.0-v1.6.6 left
#               a duplicate /etc/cron.d/kh-duo-update on hosts where systemd
#               actually worked.  Both fired daily, doubling --update load.
patch_1_6_9_dual_task_cleanup() {
    [[ -f "$AUTO_UPDATE_SYSTEMD_TIMER" ]] || return 0
    [[ -f "$AUTO_UPDATE_CRON_FILE" ]] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl is-enabled kh-duo-update.timer >/dev/null 2>&1 || return 0
    rm -f "$AUTO_UPDATE_CRON_FILE"
    log "Patch 1.6.9: removed cron leftover from v1.5.0-v1.6.6 SIGPIPE bug"
}

get_last_applied_version() {
    [[ -r "$PATCH_STATE_FILE" ]] || { echo "0.0.0"; return; }
    local v
    v="$(cat "$PATCH_STATE_FILE" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$v" ]] && echo "$v" || echo "0.0.0"
}

set_last_applied_version() {
    local ver="$1"
    mkdir -p "$PATCH_STATE_DIR" 2>/dev/null || return
    chmod 755 "$PATCH_STATE_DIR" 2>/dev/null || true
    local tmp="$PATCH_STATE_FILE.tmp"
    printf '%s\n' "$ver" > "$tmp" 2>/dev/null && mv "$tmp" "$PATCH_STATE_FILE" 2>/dev/null
    chmod 644 "$PATCH_STATE_FILE" 2>/dev/null || true
}

run_migration_patches() {
    [[ $EUID -eq 0 ]] || return 0
    [[ -n "${SCRIPT_VERSION:-}" ]] || return 0

    local last_applied current
    last_applied="$(get_last_applied_version)"
    current="$SCRIPT_VERSION"

    # No new versions to apply patches for.
    if ! ver_lt "$last_applied" "$current"; then
        return 0
    fi

    local entry target fn ran_any=0
    for entry in "${MIGRATION_PATCHES[@]}"; do
        target="${entry%% *}"
        fn="${entry##* }"

        # Run if last_applied < target <= current
        if ver_lt "$last_applied" "$target" && ! ver_lt "$current" "$target"; then
            if declare -f "$fn" >/dev/null 2>&1; then
                "$fn" || warn "Migration patch $fn returned non-zero (continuing)"
                ran_any=1
            fi
        fi
    done

    set_last_applied_version "$current"
}
run_migration_patches

### ─── Main ───────────────────────────────────────────────────────────────

# Resolve which URL self-update / check-update will use.  Persistent file
# beats env var beats default.  Env var is ignored under sudo from a
# non-root caller (anti-tamper against unprivileged users).
resolve_update_url

# --show-config: read-only diagnostic (no admin needed)
if [[ $ACTION_SHOW_CONFIG -eq 1 ]]; then
    echo
    log "Update configuration"
    _eff_ch="$(get_effective_channel)"
    _conf_ch="$(get_persistent_channel)"
    _conf_url="$(get_persistent_url)"
    echo "  Channel:            $_eff_ch ${_conf_ch:+(persisted)}"
    echo "  Channel URLs:"
    echo "    stable          = $SCRIPT_STABLE_URL"
    echo "    beta            = $SCRIPT_BETA_URL"
    if [[ -r "$SCRIPT_CONFIG_FILE" ]]; then
        echo "  Persistent config:  $SCRIPT_CONFIG_FILE"
        echo "    channel         = ${_conf_ch:-(default = stable)}"
        echo "    update_url      = ${_conf_url:-(none — using channel URL)}"
    else
        echo "  Persistent config:  (none)"
    fi
    if [[ -n "${KH_DUO_UPDATE_URL:-}" ]]; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            echo "  Env KH_DUO_UPDATE_URL: $KH_DUO_UPDATE_URL  (IGNORED — running via sudo)"
        else
            echo "  Env KH_DUO_UPDATE_URL: $KH_DUO_UPDATE_URL"
        fi
    fi
    if [[ -n "${KH_DUO_CHANNEL:-}" ]]; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            echo "  Env KH_DUO_CHANNEL:    $KH_DUO_CHANNEL    (IGNORED — running via sudo)"
        else
            echo "  Env KH_DUO_CHANNEL:    $KH_DUO_CHANNEL"
        fi
    fi
    echo "  Effective URL:      $SCRIPT_RAW_URL"
    echo "  Auto-update task:   $(auto_update_status)"
    exit 0
fi

# --check-update is read-only — no system state is touched, only a curl + awk
# of the upstream version field.  Run it without requiring root so users can
# tell whether an update is available before bothering with sudo.
if [[ $ACTION_CHECK_UPDATE -eq 1 ]]; then
    log "Local version: $SCRIPT_VERSION"
    log "Checking $SCRIPT_RAW_URL ..."
    remote_ver="$(fetch_remote_version)" || { warn "Could not fetch remote version (offline?)"; exit 1; }
    if [[ "$remote_ver" == "$SCRIPT_VERSION" ]]; then
        ok "You are on the latest version ($SCRIPT_VERSION)"
    elif ver_lt "$remote_ver" "$SCRIPT_VERSION"; then
        ok "Local $SCRIPT_VERSION is ahead of upstream $remote_ver (development build)"
    else
        warn "Update available: $SCRIPT_VERSION → $remote_ver  (run sudo $0 --update to apply)"
    fi
    exit 0
fi

require_root
detect_os

# Mirror config writes happen as root, before any heavier setup.
if [[ $ACTION_SET_MIRROR -eq 1 ]]; then
    set_mirror "$SET_MIRROR_URL"
    exit 0
fi
if [[ $ACTION_CLEAR_MIRROR -eq 1 ]]; then
    clear_mirror
    exit 0
fi
if [[ $ACTION_SET_CHANNEL -eq 1 ]]; then
    set_channel "$SET_CHANNEL_VALUE"
    exit 0
fi
if [[ $ACTION_USE_CDN -eq 1 ]]; then
    use_cdn "$USE_CDN_PROVIDER"
    exit 0
fi

# Remaining quick-exit actions touch the filesystem as root, so they sit
# after require_root.  Each one re-validates its preconditions internally.
if [[ $ACTION_SELF_UPDATE -eq 1 ]]; then
    self_update
    exit 0
fi
if [[ $ACTION_INSTALL_SHORTCUT -eq 1 ]]; then
    install_shortcut
    exit 0
fi
if [[ $ACTION_INSTALL_AUTO_UPDATE -eq 1 ]]; then
    install_auto_update
    exit 0
fi
if [[ $ACTION_REMOVE_AUTO_UPDATE -eq 1 ]]; then
    uninstall_auto_update
    exit 0
fi

# --reinstall: read existing creds + toggles, full uninstall (in subshell so
# its exit doesn't kill us), then exec self with the saved state to redo a
# clean install.  Use case: force a baseline reapply of PAM/sshd config from
# the latest script's templates without writing version-targeted patches for
# every config change.
if [[ $ACTION_REINSTALL -eq 1 ]]; then
    require_root_owned_script
    read_existing_config
    if [[ -z "$IKEY" || -z "$SKEY" || -z "$HOST" ]]; then
        die "Cannot --reinstall: no existing Duo credentials at $PAM_DUO_CONF.  Run a fresh install with --ikey/--skey/--host instead."
    fi

    log "Reinstall: snapshot existing config, uninstall, re-apply"
    log "  ikey=${IKEY:0:8}…  host=$HOST  channel=$(get_effective_channel)"

    saved_ikey="$IKEY"
    saved_skey="$SKEY"
    saved_host="$HOST"
    saved_allow="$ALLOW_PASSWORD"
    saved_bypass_local="$BYPASS_LOCAL"
    saved_bypass_addrs="$BYPASS_ADDRS"
    saved_breakglass="$BREAKGLASS_USER"

    log "Phase 1/2: uninstalling..."
    # do_uninstall ends with exit 0; subshell isolates that so we can continue.
    ( UNINSTALL=1 ASSUME_YES=1 do_uninstall ) || die "Uninstall phase failed"

    log "Phase 2/2: reinstalling with saved configuration..."
    reinstall_args=(
        --ikey "$saved_ikey"
        --skey "$saved_skey"
        --host "$saved_host"
        --yes
        --no-menu
    )
    [[ $saved_allow -eq 1 ]]            && reinstall_args+=(--allow-password)
    [[ $saved_bypass_local -eq 0 ]]     && reinstall_args+=(--no-bypass-local)
    [[ -n "$saved_bypass_addrs" ]]      && reinstall_args+=(--bypass-addr "$saved_bypass_addrs")
    [[ -n "$saved_breakglass" ]]        && reinstall_args+=(--breakglass "$saved_breakglass")

    exec "$SCRIPT_PATH" "${reinstall_args[@]}"
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

### 8.4. Trim old install backup directories (keep newest BACKUP_RETENTION_COUNT)
cleanup_old_backups "/root/duo-install-backup-*" dir

### 8.5. Auto-update task — register if not opted out
if [[ $NO_AUTO_UPDATE -eq 1 ]]; then
    log "Skipping auto-update setup (--no-auto-update)"
elif [[ -f "$AUTO_UPDATE_SYSTEMD_TIMER" ]] || [[ -f "$AUTO_UPDATE_CRON_FILE" ]]; then
    # Already configured — just refresh in case the script path changed
    install_auto_update || warn "Could not refresh auto-update task — existing one still active"
else
    install_auto_update || warn "Auto-update setup failed; you'll need to schedule '$SCRIPT_PATH --update --no-menu --yes' yourself"
fi

### 9. Final output
cat <<EOF

╔═══════════════════════════════════════════════════════════════════════╗
║  Duo 2FA for SSH — installation complete                              ║
╠═══════════════════════════════════════════════════════════════════════╣
║  OS:                 $(printf '%-49s' "${PRETTY_NAME:-$ID}")║
║  Duo version:        $(printf '%-49s' "$(get_duo_version)")║
║  pam_duo.so:         $(printf '%-49s' "$PAM_DUO_SO")║
║  Login requirement:  $(printf '%-49s' "publickey$( [[ $ALLOW_PASSWORD -eq 1 ]] && echo ' OR password') + Duo")║
EOF
# Conditional row — split out of the heredoc so an empty BREAKGLASS_USER
# doesn't leave a blank, borderless line in the box.
if [[ -n "$BREAKGLASS_USER" ]]; then
    printf '║  Breakglass user:    %-49s║\n' "$BREAKGLASS_USER (publickey only)"
fi
cat <<EOF
║  Backups:            $(printf '%-49s' "$BACKUP_DIR")║
║  Channel:            $(printf '%-49s' "$(get_effective_channel)")║
║  Auto-update:        $(printf '%-49s' "$(auto_update_status)")║
║                                                                       ║
║  DO NOT CLOSE THIS SESSION YET.                                       ║
║  Open a NEW terminal and test SSH login first.                        ║
║                                                                       ║
║  To uninstall:                                                        ║
║    $(printf '%-67s' "sudo $SCRIPT_PATH --uninstall")║
╚═══════════════════════════════════════════════════════════════════════╝

EOF
