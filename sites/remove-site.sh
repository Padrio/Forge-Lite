#!/usr/bin/env bash
# forge-lite/sites/remove-site.sh — Clean site removal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FORGE_LITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${FORGE_LITE_DIR}/lib/common.sh"
source "${FORGE_LITE_DIR}/lib/credentials.sh"
source "${FORGE_LITE_DIR}/lib/validation.sh"

require_root

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
DOMAIN=""
KEEP_DB=false
KEEP_FILES=false
YES=false

usage() {
    cat <<'USAGE'
Usage: remove-site.sh <domain> [OPTIONS]

Options:
    --keep-db       Don't drop the database and user
    --keep-files    Don't delete site files
    --yes           Skip confirmation prompt
    -h, --help      Show this help
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-db)      KEEP_DB=true; shift ;;
        --keep-files)   KEEP_FILES=true; shift ;;
        --yes)          YES=true; shift ;;
        -h|--help)      usage ;;
        -*)             die "Unknown option: $1" ;;
        *)              DOMAIN="$1"; shift ;;
    esac
done

[[ -n "$DOMAIN" ]] || die "Domain is required."

SITE_CONFIG="/etc/forge-lite/${DOMAIN}.conf"
[[ -f "$SITE_CONFIG" ]] || die "Site config not found: ${SITE_CONFIG}"

# Source site config
# shellcheck disable=SC1090
source "$SITE_CONFIG"

SITE_ID=$(sanitize_for_identifier "$DOMAIN")

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ "$YES" != true ]]; then
    echo ""
    echo "This will remove site: ${DOMAIN}"
    [[ "$KEEP_DB" == true ]] && echo "  - Database will be KEPT" || echo "  - Database '${DB_NAME:-$SITE_ID}' will be DROPPED"
    [[ "$KEEP_FILES" == true ]] && echo "  - Files will be KEPT" || echo "  - Files in ${SITE_DIR:-/home/deployer/sites/$DOMAIN} will be DELETED"
    echo ""
    read -rp "Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }
fi

log_info "=========================================="
log_info "  Removing site: ${DOMAIN}"
log_info "=========================================="

# ---------------------------------------------------------------------------
# 1. Remove supervisor configs
# ---------------------------------------------------------------------------
log_info "Removing supervisor configs..."
for conf in /etc/supervisor/conf.d/${DOMAIN}-*.conf; do
    if [[ -f "$conf" ]]; then
        local_name=$(basename "$conf" .conf)
        supervisorctl stop "${local_name}:*" 2>/dev/null || true
        rm -f "$conf"
        log_info "Removed ${conf}"
    fi
done
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Remove cron
# ---------------------------------------------------------------------------
if [[ -f "/etc/cron.d/${DOMAIN}-scheduler" ]]; then
    rm -f "/etc/cron.d/${DOMAIN}-scheduler"
    log_info "Removed scheduler cron"
fi

# ---------------------------------------------------------------------------
# 3. Remove NGINX vhost
# ---------------------------------------------------------------------------
rm -f "/etc/nginx/sites-enabled/${DOMAIN}.conf"
rm -f "/etc/nginx/sites-available/${DOMAIN}.conf"
rm -f "/etc/nginx/sites-extra/${DOMAIN}.conf"
rm -f "/etc/forge-lite/auth/${DOMAIN}.conf"
rm -f "/etc/forge-lite/auth/${DOMAIN}.htpasswd"
if nginx -t 2>/dev/null; then
    systemctl reload nginx
    log_info "Removed NGINX vhost and Basic Auth config"
fi

# ---------------------------------------------------------------------------
# 4. Remove PHP-FPM pool
# ---------------------------------------------------------------------------
php_v="${PHP_VERSION:-8.3}"
rm -f "/etc/php/${php_v}/fpm/pool.d/${DOMAIN}.conf"
systemctl restart "php${php_v}-fpm" 2>/dev/null || true
log_info "Removed FPM pool"

# ---------------------------------------------------------------------------
# 5. Drop database (unless --keep-db) — via mysql_safe (no password in ps)
# ---------------------------------------------------------------------------
if [[ "$KEEP_DB" != true ]]; then
    ROOT_PASS=$(get_credential "MARIADB_ROOT_PASSWORD" 2>/dev/null) || true
    if [[ -n "${ROOT_PASS:-}" ]]; then
        mysql_safe "${ROOT_PASS}" -e "DROP DATABASE IF EXISTS \`${SITE_ID}\`;" 2>/dev/null || true
        mysql_safe "${ROOT_PASS}" -e "DROP USER IF EXISTS '${SITE_ID}'@'localhost';" 2>/dev/null || true
        mysql_safe "${ROOT_PASS}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        log_info "Dropped database and user"
    else
        log_warn "Could not read MariaDB root password — skipping database removal"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Remove site files (unless --keep-files)
# ---------------------------------------------------------------------------
if [[ "$KEEP_FILES" != true ]]; then
    site_dir="${SITE_DIR:-/home/deployer/sites/$DOMAIN}"
    if [[ -d "$site_dir" ]]; then
        rm -rf "$site_dir"
        log_info "Removed site files"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Remove site config
# ---------------------------------------------------------------------------
rm -f "$SITE_CONFIG"
log_info "Removed site config"

log_ok "=========================================="
log_ok "  Site ${DOMAIN} removed"
log_ok "=========================================="
