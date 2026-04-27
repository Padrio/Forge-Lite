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
# Deploy lock (prevent concurrent deployments)
# ---------------------------------------------------------------------------
LOCKFILE="/var/run/forge-lite-deploy-${DOMAIN}.lock"
exec 200>"$LOCKFILE"
flock -n 200 || die "Another deployment for ${DOMAIN} is already running."

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------
RELEASE_ID=$(date +%Y%m%d_%H%M%S)
RELEASE_DIR="${SITE_DIR}/releases/${RELEASE_ID}"
CURRENT_LINK="${SITE_DIR}/current"
SHARED_DIR="${SITE_DIR}/shared"
PHP_BIN="php${PHP_VERSION}"

# ---------------------------------------------------------------------------
# Cleanup trap — remove half-finished release + exit maintenance on failure
# ---------------------------------------------------------------------------
DEPLOY_FAILED=true
cleanup_on_failure() {
    if [[ "$DEPLOY_FAILED" == true ]]; then
        log_warn "Deployment failed -- cleaning up..."
        [[ -d "$RELEASE_DIR" ]] && rm -rf "$RELEASE_DIR"
        if [[ -L "$CURRENT_LINK" ]] && [[ -f "${CURRENT_LINK}/artisan" ]]; then
            cd "$CURRENT_LINK"
            sudo -u deployer "$PHP_BIN" artisan up 2>/dev/null || true
        fi
    fi
}
trap cleanup_on_failure EXIT

log_info "=========================================="
log_info "  Deploying ${DOMAIN}"
log_info "  Release: ${RELEASE_ID}"
log_info "=========================================="

# ---------------------------------------------------------------------------
# Disk space check
# ---------------------------------------------------------------------------
avail_mb=$(df -BM "${SITE_DIR}" | awk 'NR==2 {print int($4)}')
if [[ "$avail_mb" -lt 500 ]]; then
    die "Insufficient disk space: ${avail_mb}MB available, 500MB minimum required."
fi

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
    retry 3 5 timeout 60 git clone --depth 1 --branch "$BRANCH" "$REPO" "$RELEASE_DIR"
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

# Generate APP_KEY if not set (first deployment)
if grep -q "^APP_KEY=$" "${SHARED_DIR}/.env" 2>/dev/null; then
    log_info "Generating APP_KEY (first deployment)..."
    APP_KEY_VALUE="base64:$(openssl rand -base64 32)"
    local_escaped_key=$(sed_escape_value "$APP_KEY_VALUE")
    sed -i "s|^APP_KEY=.*|APP_KEY=${local_escaped_key}|" "${SHARED_DIR}/.env"
    log_ok "APP_KEY generated"
fi

# ---------------------------------------------------------------------------
# 3. Composer install
# ---------------------------------------------------------------------------
if [[ -n "$REPO" ]] || [[ ! -d "${RELEASE_DIR}/vendor" ]]; then
    log_info "Installing Composer dependencies..."
    cd "$RELEASE_DIR"
    retry 3 5 timeout 600 sudo -u deployer composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader
fi

# ---------------------------------------------------------------------------
# 4. Node.js build (repo mode only, if package.json exists)
# ---------------------------------------------------------------------------
if [[ -n "$REPO" ]] && [[ -f "${RELEASE_DIR}/package.json" ]]; then
    log_info "Building frontend assets..."
    cd "$RELEASE_DIR"
    retry 3 5 timeout 300 sudo -u deployer npm ci
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
# 6. Pre-migration database backup
# ---------------------------------------------------------------------------
if [[ "$SKIP_MIGRATE" != true ]] && [[ -n "${DB_NAME:-}" ]]; then
    log_info "Creating pre-migration database backup..."
    backup_dir="/home/deployer/backups"
    mkdir -p "$backup_dir"
    backup_file="${backup_dir}/${DB_NAME}_pre_${RELEASE_ID}.sql.gz"
    root_pass=""
    root_pass=$(get_credential "MARIADB_ROOT_PASSWORD" 2>/dev/null) || true
    if [[ -n "$root_pass" ]]; then
        if mysql_safe "$root_pass" "$DB_NAME" -e "SELECT 1" 2>/dev/null; then
            mysqldump_safe "$root_pass" "$DB_NAME" --single-transaction | gzip > "$backup_file" && \
                log_ok "Pre-migration backup saved: ${backup_file}" || \
                log_warn "Pre-migration backup failed (non-fatal)"
            chown deployer:deployer "$backup_file" 2>/dev/null || true
        else
            log_warn "Could not connect to database for backup (non-fatal)"
        fi
    else
        log_warn "No database root password found, skipping pre-migration backup"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Database migrations
# ---------------------------------------------------------------------------
if [[ "$SKIP_MIGRATE" != true ]]; then
    cd "$RELEASE_DIR"

    # Optional: separate migrations-user override. Sites that revoke
    # destructive grants from the runtime user (e.g. append-only enforcement
    # on audit/ledger tables) can set DB_USERNAME_MIGRATIONS /
    # DB_PASSWORD_MIGRATIONS in their shared .env to use a privileged user
    # for the migrate step only. Backwards-compatible: absence falls through
    # to the standard runtime-user migration call.
    mig_user=""
    mig_pass=""
    if [[ -f "${SHARED_DIR}/.env" ]]; then
        if grep -qE '^DB_USERNAME_MIGRATIONS=' "${SHARED_DIR}/.env"; then
            mig_user=$(grep -E '^DB_USERNAME_MIGRATIONS=' "${SHARED_DIR}/.env" | head -1 | cut -d= -f2-)
            mig_user="${mig_user%\"}"; mig_user="${mig_user#\"}"
        fi
        if grep -qE '^DB_PASSWORD_MIGRATIONS=' "${SHARED_DIR}/.env"; then
            mig_pass=$(grep -E '^DB_PASSWORD_MIGRATIONS=' "${SHARED_DIR}/.env" | head -1 | cut -d= -f2-)
            mig_pass="${mig_pass%\"}"; mig_pass="${mig_pass#\"}"
        fi
    fi

    if [[ -n "$mig_user" ]] && [[ -n "$mig_pass" ]]; then
        log_info "Running migrations with override user: ${mig_user}"
        sudo -u deployer env DB_USERNAME="$mig_user" DB_PASSWORD="$mig_pass" \
            "$PHP_BIN" artisan migrate --force
    else
        log_info "Running migrations..."
        sudo -u deployer "$PHP_BIN" artisan migrate --force
    fi
fi

# ---------------------------------------------------------------------------
# 8. Cache optimization
# ---------------------------------------------------------------------------
log_info "Optimizing caches..."
cd "$RELEASE_DIR"
sudo -u deployer "$PHP_BIN" artisan config:cache || log_warn "config:cache failed (non-fatal)"
sudo -u deployer "$PHP_BIN" artisan route:cache  || log_warn "route:cache failed (non-fatal)"
sudo -u deployer "$PHP_BIN" artisan view:cache   || log_warn "view:cache failed (non-fatal)"
sudo -u deployer "$PHP_BIN" artisan event:cache  || log_warn "event:cache failed (non-fatal)"

# ---------------------------------------------------------------------------
# 9. Atomic symlink swap
# ---------------------------------------------------------------------------
log_info "Swapping symlink..."
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

# ---------------------------------------------------------------------------
# 10. Reload services
# ---------------------------------------------------------------------------
log_info "Reloading services..."
systemctl reload "php${PHP_VERSION}-fpm"

# Ensure supervisor picks up any config changes
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true

# Soft-signal queue workers to exit at end of current job — belt-and-braces with
# the supervisorctl restart below. If supervisorctl restart silently fails
# (transient socket error, status-loop short-circuit), the worker self-terminates
# next loop iteration; autorestart=true in the worker template brings it back
# reading the new /current symlink with a fresh autoload. Without this, an
# orphaned worker can survive up to --max-time=3600s with stale class cache and
# fail with __PHP_Incomplete_Class on the next dequeued job.
log_info "Signaling queue workers to restart (queue:restart)..."
cd "$RELEASE_DIR"
sudo -u deployer "$PHP_BIN" artisan queue:restart || log_warn "queue:restart failed (non-fatal)"

# Restart supervisor processes for this domain.
# The :* suffix targets the full process group — required for numprocs>1 and
# harmless for numprocs=1. Without it, supervisorctl errors on multi-process
# programs, leaving FATAL workers stuck after a deploy.
for conf in /etc/supervisor/conf.d/${DOMAIN}-*.conf; do
    if [[ -f "$conf" ]]; then
        local_name=$(basename "$conf" .conf)
        if supervisorctl status "${local_name}:*" 2>/dev/null | grep -qE "RUNNING|STOPPED|EXITED|FATAL|BACKOFF"; then
            supervisorctl restart "${local_name}:*" 2>/dev/null || log_warn "Failed to restart ${local_name}:*"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 11. Exit maintenance mode
# ---------------------------------------------------------------------------
log_info "Exiting maintenance mode..."
cd "$RELEASE_DIR"
sudo -u deployer "$PHP_BIN" artisan up

# ---------------------------------------------------------------------------
# 12. Health check
# ---------------------------------------------------------------------------
log_info "Running health check..."
http_code=$(curl -4 -s -o /dev/null -w '%{http_code}' \
    -H "Host: ${DOMAIN}" --max-time 10 "http://127.0.0.1") || true
if [[ "${http_code:-0}" -ge 200 && "${http_code:-0}" -lt 400 ]]; then
    log_ok "Health check passed (HTTP ${http_code})"
else
    log_warn "Health check returned HTTP ${http_code:-timeout} -- verify manually"
fi

# IPv6 health check (non-blocking, only if server has IPv6)
if has_ipv6 2>/dev/null; then
    http_code_v6=$(curl -6 -s -o /dev/null -w '%{http_code}' \
        -H "Host: ${DOMAIN}" --max-time 5 "http://[::1]") || true
    if [[ "${http_code_v6:-0}" -ge 200 && "${http_code_v6:-0}" -lt 400 ]]; then
        log_ok "IPv6 health check passed (HTTP ${http_code_v6})"
    else
        log_warn "IPv6 health check returned HTTP ${http_code_v6:-timeout}"
    fi
fi

# ---------------------------------------------------------------------------
# 13. Cleanup old releases
# ---------------------------------------------------------------------------
log_info "Cleaning up old releases (keeping ${KEEP})..."
cd "${SITE_DIR}/releases"
# List directories sorted oldest first, remove all but the newest $KEEP
# shellcheck disable=SC2012
ls -1dt */ 2>/dev/null | tail -n +$(( KEEP + 1 )) | while read -r old_release; do
    rm -rf "${SITE_DIR}/releases/${old_release}"
    log_info "Removed old release: ${old_release}"
done

# ---------------------------------------------------------------------------
# 14. Cleanup old pre-migration backups
# ---------------------------------------------------------------------------
if [[ -n "${DB_NAME:-}" ]]; then
    backup_dir="/home/deployer/backups"
    if [[ -d "$backup_dir" ]]; then
        log_info "Cleaning up old pre-migration backups (keeping ${KEEP})..."
        cd "$backup_dir"
        # `|| true` guards pipefail: `ls` exits 2 when the glob has no matches
        # (e.g. a fresh site with no prior pre-migration backups yet).
        # shellcheck disable=SC2012
        ls -1t "${DB_NAME}_pre_"*.sql.gz 2>/dev/null | tail -n +$(( KEEP + 1 )) | while read -r old_backup; do
            rm -f "${backup_dir}/${old_backup}"
            log_info "Removed old backup: ${old_backup}"
        done || true
    fi
fi

# Mark deployment successful (disables cleanup trap)
DEPLOY_FAILED=false

log_ok "=========================================="
log_ok "  Deployment complete!"
log_ok "  Domain:  ${DOMAIN}"
log_ok "  Release: ${RELEASE_ID}"
log_ok "=========================================="
