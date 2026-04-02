#!/usr/bin/env bash
# forge-lite/lib/common.sh — Shared logging, colors, idempotent helpers, OS checks
set -euo pipefail

# ---------------------------------------------------------------------------
# Color constants (disabled when not connected to a terminal)
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

# ---------------------------------------------------------------------------
# Logging — all output goes to stderr so stdout stays clean for piping
# ---------------------------------------------------------------------------
log_info()  { echo -e "${BLUE}[INFO]${RESET}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

die() { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Auto-resolve FORGE_LITE_DIR (root of the forge-lite repo)
# ---------------------------------------------------------------------------
if [[ -z "${FORGE_LITE_DIR:-}" ]]; then
    FORGE_LITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export FORGE_LITE_DIR

# ---------------------------------------------------------------------------
# Environment guards
# ---------------------------------------------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

require_ubuntu() {
    local required_version="${1:-24.04}"
    [[ -f /etc/os-release ]] || die "Cannot detect OS — /etc/os-release missing."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "This script requires Ubuntu (detected: ${ID:-unknown})."
    [[ "${VERSION_ID:-}" == "$required_version" ]] || \
        die "This script targets Ubuntu ${required_version} (detected: ${VERSION_ID:-unknown})."
}

# ---------------------------------------------------------------------------
# Idempotent helpers
# ---------------------------------------------------------------------------

# ensure_line_in_file <file> <line> [marker]
#   Adds <line> to <file> if not already present. Optional marker for grep.
ensure_line_in_file() {
    local file="$1" line="$2" marker="${3:-$2}"
    if ! grep -qF "$marker" "$file" 2>/dev/null; then
        echo "$line" >> "$file"
        log_info "Added line to ${file}"
    fi
}

# ensure_packages <pkg1> [pkg2] ...
#   Installs packages only if not already installed.
ensure_packages() {
    local to_install=()
    for pkg in "$@"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            to_install+=("$pkg")
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        log_info "Installing packages: ${to_install[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${to_install[@]}"
    fi
}

# ensure_service <service> [action: enable|start|restart]
#   Enables and starts a service if not already active.
ensure_service() {
    local service="$1" action="${2:-start}"
    systemctl enable "$service" 2>/dev/null || true
    case "$action" in
        start)
            if ! systemctl is-active --quiet "$service"; then
                systemctl start "$service"
                log_info "Started ${service}"
            fi
            ;;
        restart)
            systemctl restart "$service"
            log_info "Restarted ${service}"
            ;;
        enable)
            log_info "Enabled ${service}"
            ;;
    esac
}

# retry <max_attempts> <delay_seconds> <command...>
#   Retries a command up to max_attempts times with delay between attempts.
retry() {
    local max="${1:-3}" delay="${2:-5}"; shift 2
    local attempt=1
    while [[ $attempt -le $max ]]; do
        if "$@"; then return 0; fi
        log_warn "Attempt ${attempt}/${max} failed, retrying in ${delay}s..."
        sleep "$delay"; ((attempt++))
    done
    return 1
}

# sed_escape_value <string>
#   Escapes a string for safe use as a sed replacement value (pipe delimiter).
sed_escape_value() {
    printf '%s' "$1" | sed -e 's/[&/\|]/\\&/g'
}

# mysql_safe <root_password> [mysql_args...]
#   Runs mysql with password via --defaults-extra-file (avoids ps aux exposure).
mysql_safe() {
    local root_pass="$1"; shift
    local cnf
    cnf="$(mktemp)"
    chmod 600 "$cnf"
    printf '[client]\nuser=root\npassword=%s\n' "$root_pass" > "$cnf"
    mysql --defaults-extra-file="$cnf" "$@"
    local rc=$?
    rm -f "$cnf"
    return $rc
}

# mysqldump_safe <root_password> [mysqldump_args...]
#   Runs mysqldump with password via --defaults-extra-file (avoids ps aux exposure).
mysqldump_safe() {
    local root_pass="$1"; shift
    local cnf
    cnf="$(mktemp)"
    chmod 600 "$cnf"
    printf '[client]\nuser=root\npassword=%s\n' "$root_pass" > "$cnf"
    mysqldump --defaults-extra-file="$cnf" "$@"
    local rc=$?
    rm -f "$cnf"
    return $rc
}

# ---------------------------------------------------------------------------
# Network helpers — IPv4/IPv6 detection
# ---------------------------------------------------------------------------

# get_server_ipv4 — returns the public IPv4 address or empty string
get_server_ipv4() {
    local ip
    ip="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)" || true
    if [[ -z "$ip" ]]; then
        ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)" || true
    fi
    printf '%s' "${ip:-}"
}

# get_server_ipv6 — returns the public IPv6 address or empty string
get_server_ipv6() {
    local ip
    ip="$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null)" || true
    if [[ -z "$ip" ]]; then
        ip="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -1)" || true
    fi
    printf '%s' "${ip:-}"
}

# has_ipv6 — returns 0 if server has a public/global IPv6 address
has_ipv6() {
    local ipv6
    ipv6="$(get_server_ipv6)"
    [[ -n "$ipv6" ]]
}

# ensure_user <username> [shell] [home]
#   Creates a system user if it does not already exist.
ensure_user() {
    local username="$1"
    local shell="${2:-/bin/bash}"
    local home="${3:-/home/$username}"
    if ! id "$username" &>/dev/null; then
        useradd --create-home --home-dir "$home" --shell "$shell" "$username"
        log_info "Created user ${username}"
    fi
}
