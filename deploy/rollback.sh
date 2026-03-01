#!/usr/bin/env bash
# forge-lite/deploy/rollback.sh — Quick rollback to previous release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FORGE_LITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${FORGE_LITE_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
DOMAIN="${1:-}"
[[ -n "$DOMAIN" ]] || die "Usage: rollback.sh <domain>"

# Load site config
SITE_CONFIG="/etc/forge-lite/${DOMAIN}.conf"
[[ -f "$SITE_CONFIG" ]] || die "Site config not found: ${SITE_CONFIG}"
# shellcheck disable=SC1090
source "$SITE_CONFIG"

SITE_DIR="${SITE_DIR:-/home/deployer/sites/$DOMAIN}"
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_BIN="php${PHP_VERSION}"
CURRENT_LINK="${SITE_DIR}/current"
RELEASES_DIR="${SITE_DIR}/releases"

# ---------------------------------------------------------------------------
# Find previous release
# ---------------------------------------------------------------------------
CURRENT_RELEASE=$(readlink -f "$CURRENT_LINK" 2>/dev/null) || die "No current release found"
CURRENT_RELEASE_NAME=$(basename "$CURRENT_RELEASE")

# Get sorted list of releases (newest first), find the one before current
PREVIOUS_RELEASE=""
FOUND_CURRENT=false

while read -r release_dir; do
    release_name=$(basename "$release_dir")
    if [[ "$FOUND_CURRENT" == true ]]; then
        PREVIOUS_RELEASE="$release_dir"
        break
    fi
    if [[ "$release_name" == "$CURRENT_RELEASE_NAME" ]]; then
        FOUND_CURRENT=true
    fi
done < <(ls -1dt "${RELEASES_DIR}"/*/ 2>/dev/null)

[[ -n "$PREVIOUS_RELEASE" ]] || die "No previous release found to rollback to."
PREVIOUS_NAME=$(basename "$PREVIOUS_RELEASE")

log_info "=========================================="
log_info "  Rolling back ${DOMAIN}"
log_info "  From: ${CURRENT_RELEASE_NAME}"
log_info "  To:   ${PREVIOUS_NAME}"
log_info "=========================================="

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------

# Maintenance mode
log_info "Entering maintenance mode..."
cd "$CURRENT_LINK"
sudo -u deployer "$PHP_BIN" artisan down --retry=60 || true

# Swap symlink back
log_info "Swapping symlink..."
ln -sfn "$PREVIOUS_RELEASE" "$CURRENT_LINK"

# Re-cache
log_info "Re-caching..."
cd "$CURRENT_LINK"
sudo -u deployer "$PHP_BIN" artisan config:cache
sudo -u deployer "$PHP_BIN" artisan route:cache
sudo -u deployer "$PHP_BIN" artisan view:cache
sudo -u deployer "$PHP_BIN" artisan event:cache

# Reload services
log_info "Reloading services..."
systemctl reload "php${PHP_VERSION}-fpm"

# Ensure supervisor picks up any config changes
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true

# Restart supervisor processes for this domain
for conf in /etc/supervisor/conf.d/${DOMAIN}-*.conf; do
    if [[ -f "$conf" ]]; then
        local_name=$(basename "$conf" .conf)
        if supervisorctl status "$local_name" 2>/dev/null | grep -qE "RUNNING|STOPPED|EXITED|FATAL"; then
            supervisorctl restart "$local_name" 2>/dev/null || log_warn "Failed to restart ${local_name}"
        fi
    fi
done

# Exit maintenance mode
log_info "Exiting maintenance mode..."
cd "$CURRENT_LINK"
sudo -u deployer "$PHP_BIN" artisan up

log_ok "=========================================="
log_ok "  Rollback complete!"
log_ok "  Active release: ${PREVIOUS_NAME}"
log_ok "=========================================="
