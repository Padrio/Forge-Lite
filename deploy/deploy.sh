#!/usr/bin/env bash
# forge-lite/deploy/deploy.sh — Zero-downtime deployment (symlink swap)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FORGE_LITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${FORGE_LITE_DIR}/lib/common.sh"
source "${FORGE_LITE_DIR}/lib/credentials.sh"
source "${FORGE_LITE_DIR}/lib/validation.sh"

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
DOMAIN=""
ARTIFACT=""
REPO=""
BRANCH=""
SKIP_MIGRATE=false
KEEP=5

usage() {
    cat <<'USAGE'
Usage: deploy.sh <domain> [OPTIONS]

Modes (choose one):
    --artifact=PATH         Deploy from pre-built tar.gz archive
    --repo=URL --branch=BR  Deploy via git clone on server

Options:
    --skip-migrate          Don't run database migrations
    --keep=N                Number of releases to keep (default: 5)
    -h, --help              Show this help
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact=*)    ARTIFACT="${1#*=}"; shift ;;
        --repo=*)        REPO="${1#*=}"; shift ;;
        --branch=*)      BRANCH="${1#*=}"; shift ;;
        --skip-migrate)  SKIP_MIGRATE=true; shift ;;
        --keep=*)        KEEP="${1#*=}"; shift ;;
        -h|--help)       usage ;;
        -*)              die "Unknown option: $1" ;;
        *)               DOMAIN="$1"; shift ;;
    esac
done

[[ -n "$DOMAIN" ]] || die "Domain is required."

# Validate deployment mode
if [[ -n "$ARTIFACT" ]] && [[ -n "$REPO" ]]; then
    die "Cannot use both --artifact and --repo. Choose one mode."
fi
if [[ -z "$ARTIFACT" ]] && [[ -z "$REPO" ]]; then
    die "Must specify either --artifact=PATH or --repo=URL --branch=BRANCH"
fi
if [[ -n "$REPO" ]] && [[ -z "$BRANCH" ]]; then
    die "--branch is required when using --repo"
fi

# Load site config
SITE_CONFIG="/etc/forge-lite/${DOMAIN}.conf"
[[ -f "$SITE_CONFIG" ]] || die "Site config not found: ${SITE_CONFIG}. Add the site first."
# shellcheck disable=SC1090
source "$SITE_CONFIG"

SITE_DIR="${SITE_DIR:-/home/deployer/sites/$DOMAIN}"
PHP_VERSION="${PHP_VERSION:-8.3}"

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------
RELEASE_ID=$(date +%Y%m%d_%H%M%S)
RELEASE_DIR="${SITE_DIR}/releases/${RELEASE_ID}"
CURRENT_LINK="${SITE_DIR}/current"
SHARED_DIR="${SITE_DIR}/shared"
PHP_BIN="php${PHP_VERSION}"

log_info "=========================================="
log_info "  Deploying ${DOMAIN}"
log_info "  Release: ${RELEASE_ID}"
log_info "=========================================="

# ---------------------------------------------------------------------------
# 1. Create release directory
# ---------------------------------------------------------------------------
if [[ -n "$ARTIFACT" ]]; then
    # Artifact mode: extract tar.gz
    [[ -f "$ARTIFACT" ]] || die "Artifact not found: ${ARTIFACT}"
    log_info "Extracting artifact..."
    mkdir -p "$RELEASE_DIR"
    tar -xzf "$ARTIFACT" -C "$RELEASE_DIR"
else
    # Repo mode: git clone
    log_info "Cloning ${REPO} (branch: ${BRANCH})..."
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$RELEASE_DIR"
    rm -rf "${RELEASE_DIR}/.git"
fi

chown -R deployer:deployer "$RELEASE_DIR"

# ---------------------------------------------------------------------------
# 2. Symlink shared resources
# ---------------------------------------------------------------------------
log_info "Linking shared resources..."

# .env
ln -sfn "${SHARED_DIR}/.env" "${RELEASE_DIR}/.env"

# storage directory
rm -rf "${RELEASE_DIR}/storage"
ln -sfn "${SHARED_DIR}/storage" "${RELEASE_DIR}/storage"

# ---------------------------------------------------------------------------
# 3. Composer install
# ---------------------------------------------------------------------------
if [[ -n "$REPO" ]] || [[ ! -d "${RELEASE_DIR}/vendor" ]]; then
    log_info "Installing Composer dependencies..."
    cd "$RELEASE_DIR"
    sudo -u deployer composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader
fi

# ---------------------------------------------------------------------------
# 4. Node.js build (repo mode only, if package.json exists)
# ---------------------------------------------------------------------------
if [[ -n "$REPO" ]] && [[ -f "${RELEASE_DIR}/package.json" ]]; then
    log_info "Building frontend assets..."
    cd "$RELEASE_DIR"
    sudo -u deployer npm ci
    sudo -u deployer npm run build
    # Remove node_modules to save disk space
    rm -rf "${RELEASE_DIR}/node_modules"
    log_ok "Frontend assets built"
fi

# ---------------------------------------------------------------------------
# 5. Maintenance mode (on current release if it exists)
# ---------------------------------------------------------------------------
if [[ -L "$CURRENT_LINK" ]] && [[ -f "${CURRENT_LINK}/artisan" ]]; then
    log_info "Entering maintenance mode..."
    cd "$CURRENT_LINK"
    sudo -u deployer "$PHP_BIN" artisan down --retry=60 || true
fi

# ---------------------------------------------------------------------------
# 6. Database migrations
# ---------------------------------------------------------------------------
if [[ "$SKIP_MIGRATE" != true ]]; then
    log_info "Running migrations..."
    cd "$RELEASE_DIR"
    sudo -u deployer "$PHP_BIN" artisan migrate --force
fi

# ---------------------------------------------------------------------------
# 7. Cache optimization
# ---------------------------------------------------------------------------
log_info "Optimizing caches..."
cd "$RELEASE_DIR"
sudo -u deployer "$PHP_BIN" artisan config:cache
sudo -u deployer "$PHP_BIN" artisan route:cache
sudo -u deployer "$PHP_BIN" artisan view:cache
sudo -u deployer "$PHP_BIN" artisan event:cache

# ---------------------------------------------------------------------------
# 8. Atomic symlink swap
# ---------------------------------------------------------------------------
log_info "Swapping symlink..."
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

# ---------------------------------------------------------------------------
# 9. Reload services
# ---------------------------------------------------------------------------
log_info "Reloading services..."
systemctl reload "php${PHP_VERSION}-fpm"

# Restart supervisor workers for this domain
for conf in /etc/supervisor/conf.d/${DOMAIN}-*.conf; do
    if [[ -f "$conf" ]]; then
        local_name=$(basename "$conf" .conf)
        supervisorctl restart "$local_name" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------------------
# 10. Exit maintenance mode
# ---------------------------------------------------------------------------
log_info "Exiting maintenance mode..."
cd "$RELEASE_DIR"
sudo -u deployer "$PHP_BIN" artisan up

# ---------------------------------------------------------------------------
# 11. Cleanup old releases
# ---------------------------------------------------------------------------
log_info "Cleaning up old releases (keeping ${KEEP})..."
cd "${SITE_DIR}/releases"
# List directories sorted oldest first, remove all but the newest $KEEP
# shellcheck disable=SC2012
ls -1dt */ 2>/dev/null | tail -n +$(( KEEP + 1 )) | while read -r old_release; do
    rm -rf "${SITE_DIR}/releases/${old_release}"
    log_info "Removed old release: ${old_release}"
done

log_ok "=========================================="
log_ok "  Deployment complete!"
log_ok "  Domain:  ${DOMAIN}"
log_ok "  Release: ${RELEASE_ID}"
log_ok "=========================================="
