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
    local required_version="${1:-22.04}"
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
