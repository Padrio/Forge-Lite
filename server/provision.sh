#!/usr/bin/env bash
# forge-lite/server/provision.sh — Main server provisioning orchestrator
set -euo pipefail

# Resolve project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FORGE_LITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${FORGE_LITE_DIR}/lib/common.sh"
source "${FORGE_LITE_DIR}/lib/credentials.sh"
source "${FORGE_LITE_DIR}/lib/templates.sh"
source "${FORGE_LITE_DIR}/lib/validation.sh"

# Source all modules (defines provision_* functions without executing them)
for module in "${FORGE_LITE_DIR}/server/modules/"*.sh; do
    source "$module"
done

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
FORGE_LITE_PHP_DEFAULT="8.3"
FORGE_LITE_DB_PASSWORD=""
FORGE_LITE_REDIS_PASSWORD=""
FORGE_LITE_NODE_VERSION="20"
SKIP_REBOOT=false
FORCE=false

usage() {
    cat <<'USAGE'
Usage: provision.sh [OPTIONS]

Options:
    --php-default=VERSION   Default PHP CLI version (default: 8.3)
    --db-password=PASS      MariaDB root password (auto-generated if omitted)
    --redis-password=PASS   Redis password (auto-generated if omitted)
    --node-version=VERSION  Node.js major version (default: 20)
    --skip-reboot           Don't reboot after provisioning
    --force                 Re-provision even if already provisioned
    -h, --help              Show this help message
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --php-default=*)    FORGE_LITE_PHP_DEFAULT="${1#*=}"; shift ;;
        --db-password=*)    FORGE_LITE_DB_PASSWORD="${1#*=}"; shift ;;
        --redis-password=*) FORGE_LITE_REDIS_PASSWORD="${1#*=}"; shift ;;
        --node-version=*)   FORGE_LITE_NODE_VERSION="${1#*=}"; shift ;;
        --skip-reboot)      SKIP_REBOOT=true; shift ;;
        --force)            FORCE=true; shift ;;
        -h|--help)          usage ;;
        *)                  die "Unknown option: $1" ;;
    esac
done

export FORGE_LITE_PHP_DEFAULT FORGE_LITE_DB_PASSWORD FORGE_LITE_REDIS_PASSWORD FORGE_LITE_NODE_VERSION

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_root
require_ubuntu "24.04"

MARKER="/root/.forge-lite-provisioned"
if [[ -f "$MARKER" ]] && [[ "$FORCE" != true ]]; then
    log_warn "Server already provisioned (${MARKER} exists). Use --force to re-provision."
    exit 0
fi

log_info "=========================================="
log_info "  forge-lite server provisioning"
log_info "=========================================="
log_info "PHP default: ${FORGE_LITE_PHP_DEFAULT}"
log_info "Node.js:     v${FORGE_LITE_NODE_VERSION}"
log_info ""

# ---------------------------------------------------------------------------
# Execute modules in dependency order
# ---------------------------------------------------------------------------
MODULES=(
    system
    swap
    security
    nginx
    php
    composer
    mariadb
    redis
    node
    supervisor
    certbot
)

for mod in "${MODULES[@]}"; do
    provision_"$mod"
    echo ""
done

# ---------------------------------------------------------------------------
# Install CLI helpers
# ---------------------------------------------------------------------------
log_info "Installing CLI helpers..."
install -m 755 "${FORGE_LITE_DIR}/cli/php-switch" /usr/local/bin/php-switch
install -m 755 "${FORGE_LITE_DIR}/cli/forge-lite-db" /usr/local/bin/forge-lite-db
install -m 755 "${FORGE_LITE_DIR}/cli/forge-lite-ssl" /usr/local/bin/forge-lite-ssl

# Deploy logrotate config
cp "${FORGE_LITE_DIR}/server/config/templates/logrotate/forge-lite" /etc/logrotate.d/forge-lite

# Create site config directory
mkdir -p /etc/forge-lite

# ---------------------------------------------------------------------------
# Mark as provisioned
# ---------------------------------------------------------------------------
date -Iseconds > "$MARKER"
log_ok "=========================================="
log_ok "  Server provisioning complete!"
log_ok "=========================================="
log_info "Credentials saved to: ${CREDENTIALS_FILE}"
log_info "Run 'cat ${CREDENTIALS_FILE}' to view them."

if [[ "$SKIP_REBOOT" != true ]]; then
    log_info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    reboot
fi
