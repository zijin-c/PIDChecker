#!/usr/bin/env bash
# PID Checker — one-click installer for Linux servers (systemd).
#
#   curl -fsSL https://raw.githubusercontent.com/zijin-c/PIDChecker/main/deploy/install.sh | sudo bash
#
# Pass options as environment variables *after* sudo, for example:
#
#   curl -fsSL .../install.sh | sudo PORT=8675 PUBLIC_CHECK=true bash
#   curl -fsSL .../install.sh | sudo DOMAIN=pkc.example.com bash      # HTTPS via Caddy
#   sudo ./deploy/install.sh                                           # from a local checkout
#
# Options (defaults in brackets):
#   PORT               [8675]      port pkc listens on
#   HOST               [0.0.0.0]   bind address (127.0.0.1 automatically when DOMAIN is set)
#   DOMAIN             []          domain (or public IP) for automatic HTTPS through Caddy
#   PUBLIC_CHECK       [false]     allow key checks without an API key (admin endpoints still need one)
#   ONLINE_CHECK       [true]      query Microsoft for MAK counts by default
#   REPO               [zijin-c/PIDChecker]
#   VERSION            [latest]    release tag to install, e.g. v5.1.0
#   BRANCH             [main]      branch used when building from source
#   BUILD_FROM_SOURCE  [0]         1 = skip the release download and compile
#   RECONFIGURE        [0]         1 = back up and regenerate /var/lib/pidchecker/config.toml
#   OPEN_FIREWALL      [1]         0 = leave ufw / firewalld alone
#
# Re-running the script upgrades the binary and data in place; the existing
# config.toml, API keys and blocked-key database are kept.

# Everything runs inside main(), so bash parses the whole script before executing
# anything: with `curl | bash`, no command can consume the rest of the script from stdin.
main() {
set -Eeuo pipefail
umask 022
exec </dev/null

PORT="${PORT:-8675}"
DOMAIN="${DOMAIN:-}"
PUBLIC_CHECK="${PUBLIC_CHECK:-false}"
ONLINE_CHECK="${ONLINE_CHECK:-true}"
REPO="${REPO:-zijin-c/PIDChecker}"
VERSION="${VERSION:-latest}"
BRANCH="${BRANCH:-main}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-0}"
RECONFIGURE="${RECONFIGURE:-0}"
OPEN_FIREWALL="${OPEN_FIREWALL:-1}"
if [ -n "${HOST:-}" ]; then
    BIND_HOST="$HOST"
elif [ -n "$DOMAIN" ]; then
    BIND_HOST="127.0.0.1"
else
    BIND_HOST="0.0.0.0"
fi

APP_DIR=/opt/pidchecker
STATE_DIR=/var/lib/pidchecker
CONF_FILE="$STATE_DIR/config.toml"
ETC_DIR=/etc/pidchecker
SERVICE_USER=pidchecker
ADMIN_KEY_FILE=/root/pidchecker-admin.key
BROWSER_KEY_FILE=/root/pidchecker-browser.key

# ---------------------------------------------------------------- helpers
if [ -t 1 ]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; C_DIM=; C_OFF=
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s ✓ %s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s !  %s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s ✗  %s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
is_true() { case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }

WORK_DIR="$(mktemp -d /tmp/pidchecker-install.XXXXXX)"
SWAP_FILE=""
cleanup() {
    if [ -n "$SWAP_FILE" ] && [ -f "$SWAP_FILE" ]; then
        swapoff "$SWAP_FILE" 2>/dev/null || true
        rm -f "$SWAP_FILE"
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

# ---------------------------------------------------------------- checks
[ "$(id -u)" -eq 0 ] || die "please run as root, e.g.  curl -fsSL <url> | sudo bash"
[ "$(uname -s)" = "Linux" ] || die "this installer supports Linux only"
have systemctl && [ -d /run/systemd/system ] || die "systemd is required (use Docker otherwise, see README)"
case "$PORT" in ''|*[!0-9]*) die "PORT must be a number" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "PORT must be 1-65535"
is_true "$PUBLIC_CHECK" && PUBLIC_CHECK=true || PUBLIC_CHECK=false
is_true "$ONLINE_CHECK" && ONLINE_CHECK=true || ONLINE_CHECK=false

case "$(uname -m)" in
    x86_64|amd64)  ARCH=x64;   CADDY_ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64; CADDY_ARCH=arm64 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
esac

PKG=""
if have apt-get; then PKG=apt
elif have dnf; then PKG=dnf
elif have yum; then PKG=yum
elif have zypper; then PKG=zypper
elif have pacman; then PKG=pacman
fi
APT_UPDATED=0
pkg_install() {
    case "$PKG" in
        apt)
            if [ "$APT_UPDATED" = 0 ]; then DEBIAN_FRONTEND=noninteractive apt-get update -qq; APT_UPDATED=1; fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >/dev/null ;;
        dnf)    dnf install -y -q "$@" >/dev/null ;;
        yum)    yum install -y -q "$@" >/dev/null ;;
        zypper) zypper --non-interactive --quiet install "$@" >/dev/null ;;
        pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
        *) die "no supported package manager found; install manually: $*" ;;
    esac
}

need=()
have curl || need+=(curl)
have tar  || need+=(tar)
have gzip || need+=(gzip)
[ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] || need+=(ca-certificates)
if [ "${#need[@]}" -gt 0 ]; then
    log "installing prerequisites: ${need[*]}"
    pkg_install "${need[@]}"
fi

# A local checkout is used when the script is run from one (not piped).
SRC_DIR=""
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    candidate="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
    [ -f "$candidate/Cargo.toml" ] && [ -d "$candidate/data" ] && SRC_DIR="$candidate"
fi

FIRST_INSTALL=1
[ -x "$APP_DIR/pkc" ] && FIRST_INSTALL=0

log "PID Checker installer — arch $ARCH, port $PORT, bind $BIND_HOST${DOMAIN:+, HTTPS for $DOMAIN}"

# ---------------------------------------------------------------- obtain pkc
BIN=""        # path to the pkc binary to install
ASSETS=""     # directory holding data/ and deploy/

download_release() {
    local name="pkc-linux-$ARCH.tar.gz" base
    if [ "$VERSION" = latest ]; then
        base="https://github.com/$REPO/releases/latest/download"
    else
        base="https://github.com/$REPO/releases/download/$VERSION"
    fi
    log "downloading $base/$name"
    curl -fsSL --retry 3 --connect-timeout 15 -o "$WORK_DIR/$name" "$base/$name" || return 1
    if curl -fsSL --retry 2 --connect-timeout 15 -o "$WORK_DIR/$name.sha256" "$base/$name.sha256" 2>/dev/null; then
        local expected actual
        expected="$(awk '{print $1; exit}' "$WORK_DIR/$name.sha256")"
        actual="$(sha256sum "$WORK_DIR/$name" | awk '{print $1}')"
        [ "$expected" = "$actual" ] || die "checksum mismatch for $name (expected $expected, got $actual)"
        ok "checksum verified"
    else
        warn "no checksum published for $name; skipping verification"
    fi
    mkdir -p "$WORK_DIR/release"
    tar -xzf "$WORK_DIR/$name" -C "$WORK_DIR/release"
    local found
    found="$(find "$WORK_DIR/release" -type f -name pkc -perm -u+x | head -n1)"
    [ -n "$found" ] || return 1
    BIN="$found"
    ASSETS="$(dirname "$found")"
    [ -d "$ASSETS/data" ] || return 1
    return 0
}

ensure_build_deps() {
    log "installing build dependencies"
    case "$PKG" in
        apt)    pkg_install pkg-config libssl-dev build-essential git ;;
        dnf|yum) pkg_install pkgconf-pkg-config openssl-devel gcc gcc-c++ make git || pkg_install pkgconfig openssl-devel gcc make git ;;
        zypper) pkg_install pkg-config libopenssl-devel gcc make git ;;
        pacman) pkg_install pkgconf openssl base-devel git ;;
        *) die "cannot install build dependencies automatically" ;;
    esac
    if ! have cargo && [ -x "$HOME/.cargo/bin/cargo" ]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
    if ! have cargo; then
        log "installing the Rust toolchain (rustup, minimal profile)"
        curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable >/dev/null
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
    have cargo || die "cargo is not available after installing rustup"
}

maybe_add_build_swap() {
    local mem_kb swap_kb
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    if [ "$((mem_kb + swap_kb))" -lt 2000000 ]; then
        SWAP_FILE="/var/tmp/pidchecker-build.swap"
        warn "less than 2 GiB of memory; adding a temporary 2 GiB swap file for the build"
        if fallocate -l 2G "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=none; then
            chmod 600 "$SWAP_FILE"
            if ! { mkswap "$SWAP_FILE" >/dev/null && swapon "$SWAP_FILE"; }; then
                warn "could not enable the swap file; continuing without it"
                rm -f "$SWAP_FILE"; SWAP_FILE=""
            fi
        else
            SWAP_FILE=""
        fi
    fi
}

build_from_source() {
    local src
    ensure_build_deps
    if [ -n "$SRC_DIR" ]; then
        src="$SRC_DIR"
        log "building from local checkout $src"
    else
        src="$WORK_DIR/src"
        log "cloning https://github.com/$REPO ($BRANCH)"
        git clone --quiet --depth 1 --branch "$BRANCH" "https://github.com/$REPO.git" "$src"
    fi
    maybe_add_build_swap
    log "compiling pkc (this can take several minutes on a small VPS)"
    (cd "$src" && cargo build --release --locked --no-default-features --bin pkc)
    BIN="$src/target/release/pkc"
    ASSETS="$src"
    [ -x "$BIN" ] || die "build finished but $BIN is missing"
}

if [ "$BUILD_FROM_SOURCE" != 1 ] && download_release; then
    if "$BIN" --version >/dev/null 2>&1; then
        ok "using prebuilt release binary"
    else
        warn "the prebuilt binary does not run here (older glibc?); building from source instead"
        build_from_source
    fi
else
    [ "$BUILD_FROM_SOURCE" = 1 ] || warn "no prebuilt release found for linux-$ARCH; building from source instead"
    build_from_source
fi
"$BIN" --version >/dev/null 2>&1 || die "the pkc binary does not run on this system"
ok "$("$BIN" --version)"

# Deployment files: from the source/release tree, else straight from GitHub.
deploy_file() {
    local name="$1" dest="$2"
    if [ -n "$ASSETS" ] && [ -f "$ASSETS/deploy/$name" ]; then
        install -m 0644 "$ASSETS/deploy/$name" "$dest"
    elif [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/deploy/$name" ]; then
        install -m 0644 "$SRC_DIR/deploy/$name" "$dest"
    else
        curl -fsSL --retry 3 -o "$dest" "https://raw.githubusercontent.com/$REPO/$BRANCH/deploy/$name"
        chmod 0644 "$dest"
    fi
    sed -i 's/\r$//' "$dest"
}

# ---------------------------------------------------------------- install files
getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
getent passwd "$SERVICE_USER" >/dev/null || \
    useradd --system --gid "$SERVICE_USER" --no-create-home --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"

if systemctl is-active --quiet pidchecker.service 2>/dev/null; then
    log "stopping the running service for the upgrade"
    systemctl stop pidchecker.service
fi

install -d -m 0755 "$APP_DIR" "$ETC_DIR"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR"
install -m 0755 "$BIN" "$APP_DIR/pkc.new"
mv -f "$APP_DIR/pkc.new" "$APP_DIR/pkc"
rm -rf "$APP_DIR/data.new"
cp -a "$ASSETS/data" "$APP_DIR/data.new"
chown -R root:root "$APP_DIR/data.new"
chmod -R u=rwX,go=rX "$APP_DIR/data.new"
rm -rf "$APP_DIR/data.old"
[ -d "$APP_DIR/data" ] && mv "$APP_DIR/data" "$APP_DIR/data.old"
mv "$APP_DIR/data.new" "$APP_DIR/data"
rm -rf "$APP_DIR/data.old"
ok "installed $APP_DIR/pkc and $APP_DIR/data"

# ---------------------------------------------------------------- configuration
TRUST_PROXY=false
[ -n "$DOMAIN" ] && TRUST_PROXY=true

write_config() {
    cat > "$CONF_FILE.new" <<EOF
# PID Checker production configuration (generated by deploy/install.sh).
# Edit and run  systemctl restart pidchecker  to apply.

[server]
host = "$BIND_HOST"
port = $PORT
autostart = false
cors = false
max_body_kb = 1024

[rate_limit]
enabled = true
requests_per_minute = 120
burst = 30
# Only true behind a reverse proxy (Caddy) that sets X-Forwarded-For.
trust_proxy_headers = $TRUST_PROXY

[checker]
data_dir = "$APP_DIR/data"
blocklist_db = "blocked.redb"
max_batch_size = 500
max_blocklist_batch = 10000
online_check = $ONLINE_CHECK
online_key_types = ["MAK"]
online_timeout_secs = 15
online_chunk_size = 25
online_concurrency = 4
record_blocked = true
record_revoked = true
cache_enabled = true
cache_ttl_secs = 3600
cache_max_entries = 100000
# pidgenx.dll (legacy Win7 / Office 2010 keys) exists on Windows only.
pidgenx_enabled = false
pidgenx_path = "pidgenx.dll"
pidgenx_instances = 0

[api]
require_auth = true
# true = anyone may check keys without an API key; admin endpoints still need one.
public_check = $PUBLIC_CHECK
keys_file = "api_keys.json"

[catalog]
# $APP_DIR/data is read-only for the service; re-run the installer to update it.
auto_sync = false
url = "https://raw.githubusercontent.com/ja7ad/PIDChecker/main/data"
interval_hours = 24
EOF
    chown root:"$SERVICE_USER" "$CONF_FILE.new"
    chmod 0640 "$CONF_FILE.new"
    mv -f "$CONF_FILE.new" "$CONF_FILE"
}

if [ ! -s "$CONF_FILE" ]; then
    write_config
    ok "wrote $CONF_FILE"
elif [ "$RECONFIGURE" = 1 ]; then
    backup="$CONF_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONF_FILE" "$backup"
    write_config
    ok "regenerated $CONF_FILE (previous file saved as $backup)"
else
    ok "keeping existing $CONF_FILE (set RECONFIGURE=1 to regenerate)"
fi

# Values actually in effect (an existing config may differ from the options).
conf_value() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"#]*\)\"\{0,1\}.*/\1/p" "$CONF_FILE" | head -n1 | tr -d '[:space:]'; }
EFFECTIVE_PORT="$(conf_value port)"; EFFECTIVE_PORT="${EFFECTIVE_PORT:-$PORT}"
EFFECTIVE_HOST="$(conf_value host)"; EFFECTIVE_HOST="${EFFECTIVE_HOST:-$BIND_HOST}"
EFFECTIVE_PUBLIC="$(conf_value public_check)"; EFFECTIVE_PUBLIC="${EFFECTIVE_PUBLIC:-false}"
if [ "$EFFECTIVE_PORT" != "$PORT" ] || [ "$EFFECTIVE_HOST" != "$BIND_HOST" ]; then
    warn "existing config listens on $EFFECTIVE_HOST:$EFFECTIVE_PORT (requested $BIND_HOST:$PORT); RECONFIGURE=1 applies the new values"
fi

# ---------------------------------------------------------------- API keys
create_key() {
    local name="$1" role="$2" file="$3" token
    if [ -s "$file" ]; then
        ok "keeping existing $role key $file"
        return
    fi
    token="$(cd "$STATE_DIR" && runuser -u "$SERVICE_USER" -- "$APP_DIR/pkc" -c "$CONF_FILE" --log-level warn \
        apikey create --name "$name" --role "$role" | sed -n 's/^Token (shown once): //p')"
    [ -n "$token" ] || die "could not create the $role API key"
    (umask 077 && printf '%s\n' "$token" > "$file")
    chmod 0600 "$file"
    ok "created $role key → $file"
}
create_key admin admin "$ADMIN_KEY_FILE"
create_key browser user "$BROWSER_KEY_FILE"
if [ -f "$STATE_DIR/api_keys.json" ]; then
    chown "$SERVICE_USER:$SERVICE_USER" "$STATE_DIR/api_keys.json"
    chmod 0600 "$STATE_DIR/api_keys.json"
fi

# ---------------------------------------------------------------- systemd
deploy_file pidchecker.service /etc/systemd/system/pidchecker.service
systemctl daemon-reload
systemctl enable --quiet pidchecker.service
systemctl restart pidchecker.service
ok "pidchecker.service enabled and started"

# ---------------------------------------------------------------- HTTPS (Caddy)
install_caddy() {
    if [ -x "$APP_DIR/caddy" ] && "$APP_DIR/caddy" version >/dev/null 2>&1; then
        ok "Caddy already installed ($("$APP_DIR/caddy" version | awk '{print $1}'))"
        return
    fi
    if have caddy; then
        install -m 0755 "$(command -v caddy)" "$APP_DIR/caddy"
        ok "using system Caddy"
        return
    fi
    log "downloading Caddy"
    if curl -fsSL --retry 3 -o "$WORK_DIR/caddy" "https://caddyserver.com/api/download?os=linux&arch=$CADDY_ARCH"; then
        :
    else
        local tag
        tag="$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n1)"
        [ -n "$tag" ] || die "could not download Caddy"
        curl -fsSL --retry 3 -o "$WORK_DIR/caddy.tar.gz" \
            "https://github.com/caddyserver/caddy/releases/download/v$tag/caddy_${tag}_linux_${CADDY_ARCH}.tar.gz"
        tar -xzf "$WORK_DIR/caddy.tar.gz" -C "$WORK_DIR" caddy
    fi
    install -m 0755 "$WORK_DIR/caddy" "$APP_DIR/caddy"
    "$APP_DIR/caddy" version >/dev/null || die "downloaded Caddy does not run"
    ok "installed $APP_DIR/caddy"
}

if [ -n "$DOMAIN" ]; then
    install_caddy
    profile=classic
    # Let's Encrypt only issues IP-address certificates with the short-lived profile.
    if [[ "$DOMAIN" =~ ^[0-9.]+$ || "$DOMAIN" == *:* ]]; then profile=shortlived; fi
    deploy_file Caddyfile "$APP_DIR/Caddyfile"
    cat > "$ETC_DIR/https.env" <<EOF
PIDCHECKER_HOST=$DOMAIN
PIDCHECKER_PORT=$EFFECTIVE_PORT
PIDCHECKER_ACME_PROFILE=$profile
EOF
    chmod 0644 "$ETC_DIR/https.env"
    PIDCHECKER_HOST="$DOMAIN" PIDCHECKER_PORT="$EFFECTIVE_PORT" PIDCHECKER_ACME_PROFILE="$profile" \
        "$APP_DIR/caddy" validate --config "$APP_DIR/Caddyfile" --adapter caddyfile >/dev/null 2>&1 \
        || die "Caddyfile validation failed; run: $APP_DIR/caddy validate --config $APP_DIR/Caddyfile"
    deploy_file pidchecker-https.service /etc/systemd/system/pidchecker-https.service
    systemctl daemon-reload
    systemctl enable --quiet pidchecker-https.service
    systemctl restart pidchecker-https.service
    ok "pidchecker-https.service enabled (certificates are obtained on first request)"
    if [ "$EFFECTIVE_HOST" != "127.0.0.1" ]; then
        warn "pkc still listens on $EFFECTIVE_HOST:$EFFECTIVE_PORT; with HTTPS it should bind 127.0.0.1 (RECONFIGURE=1)"
    fi
fi

# ---------------------------------------------------------------- firewall
open_port() {
    local port="$1"
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "$port/tcp" >/dev/null && ok "ufw: allowed $port/tcp"
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --quiet --permanent --add-port="$port/tcp" && firewall-cmd --quiet --reload && ok "firewalld: allowed $port/tcp"
    fi
}
if [ "$OPEN_FIREWALL" = 1 ]; then
    if [ -n "$DOMAIN" ]; then
        open_port 80; open_port 443
    fi
    if [ "$EFFECTIVE_HOST" != "127.0.0.1" ] && [ "$EFFECTIVE_HOST" != "localhost" ]; then
        open_port "$EFFECTIVE_PORT"
    fi
fi

# ---------------------------------------------------------------- health check
probe_host="$EFFECTIVE_HOST"
case "$probe_host" in 0.0.0.0|::|'[::]'|'') probe_host=127.0.0.1 ;; esac
HEALTH_URL="http://$probe_host:$EFFECTIVE_PORT/api/v1/health"
healthy=0
for _ in $(seq 1 30); do
    if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then healthy=1; break; fi
    sleep 1
done
if [ "$healthy" = 1 ]; then
    ok "health check passed: $HEALTH_URL"
else
    journalctl -u pidchecker.service -n 30 --no-pager >&2 || true
    die "service did not become healthy at $HEALTH_URL (see the log above)"
fi

# ---------------------------------------------------------------- summary
LOCAL_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
LOCAL_IP="${LOCAL_IP:-<server-ip>}"

echo
if [ "$FIRST_INSTALL" = 1 ]; then action=installed; else action=upgraded; fi
printf '%s━━━ PID Checker %s and running ━━━%s\n' "$C_GREEN" "$action" "$C_OFF"
if [ -n "$DOMAIN" ]; then
    echo "  Web UI       https://$DOMAIN/"
fi
if [ "$EFFECTIVE_HOST" = "127.0.0.1" ] || [ "$EFFECTIVE_HOST" = "localhost" ]; then
    echo "  Local API    http://127.0.0.1:$EFFECTIVE_PORT/api/v1/   (bound to localhost only)"
else
    echo "  Web UI       http://$LOCAL_IP:$EFFECTIVE_PORT/"
    echo "  REST API     http://$LOCAL_IP:$EFFECTIVE_PORT/api/v1/"
    printf '  %sIf this is a private address, use the server'"'"'s public IP and open the port in your cloud security group.%s\n' "$C_DIM" "$C_OFF"
fi
echo "  Public check $EFFECTIVE_PUBLIC (no API key needed for checks when true)"
echo
echo "  Browser key  (role user,  paste into the Web UI):  $(cat "$BROWSER_KEY_FILE" 2>/dev/null || echo '-')"
echo "  Admin key    (role admin, keep private):           $(cat "$ADMIN_KEY_FILE" 2>/dev/null || echo '-')"
echo "  Key files    $BROWSER_KEY_FILE, $ADMIN_KEY_FILE (mode 0600)"
echo
echo "  Common commands"
echo "    systemctl status pidchecker            # service state"
echo "    journalctl -u pidchecker -f            # live logs"
echo "    systemctl restart pidchecker           # apply config changes"
echo "    nano $CONF_FILE"
echo "    curl -s http://127.0.0.1:$EFFECTIVE_PORT/api/v1/health"
echo "    curl -s -H \"Authorization: Bearer \$(cat $ADMIN_KEY_FILE)\" http://127.0.0.1:$EFFECTIVE_PORT/api/v1/apikeys"
[ -n "$DOMAIN" ] && echo "    journalctl -u pidchecker-https -f      # Caddy / certificate logs"
echo "    re-run this installer to upgrade (config and keys are kept)"
echo
}

main "$@"
