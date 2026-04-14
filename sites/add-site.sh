#!/usr/bin/env bash
# forge-lite/sites/add-site.sh — Full site provisioning
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FORGE_LITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${FORGE_LITE_DIR}/lib/common.sh"
source "${FORGE_LITE_DIR}/lib/credentials.sh"
source "${FORGE_LITE_DIR}/lib/templates.sh"
source "${FORGE_LITE_DIR}/lib/validation.sh"

require_root

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
DOMAIN=""
PHP_VERSION="8.3"
QUEUE_WORKERS=2
ENABLE_SSR=false
ENABLE_HORIZON=false
ENABLE_SCHEDULER=true
SSL=false
declare -a EXTRA_ENV_VARS=()

usage() {
    cat <<'USAGE'
Usage: add-site.sh --domain=DOMAIN [OPTIONS]

Options:
    --domain=DOMAIN         Domain name (required)
    --php=VERSION           PHP version (default: 8.3)
    --queue-workers=N       Number of queue worker processes (default: 2)
    --enable-ssr            Enable Inertia SSR process
    --enable-horizon        Enable Laravel Horizon (replaces queue workers)
    --no-scheduler          Disable Laravel scheduler cron
    --ssl                   Issue SSL certificate via Let's Encrypt
    --env=KEY=VALUE         Set extra .env variable (can be repeated)
    -h, --help              Show this help
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain=*)         DOMAIN="${1#*=}"; shift ;;
        --php=*)            PHP_VERSION="${1#*=}"; shift ;;
        --queue-workers=*)  QUEUE_WORKERS="${1#*=}"; shift ;;
        --enable-ssr)       ENABLE_SSR=true; shift ;;
        --enable-horizon)   ENABLE_HORIZON=true; shift ;;
        --no-scheduler)     ENABLE_SCHEDULER=false; shift ;;
        --ssl)              SSL=true; shift ;;
        --env=*)            EXTRA_ENV_VARS+=("${1#*=}"); shift ;;
        -h|--help)          usage ;;
        *)                  die "Unknown option: $1" ;;
    esac
done

[[ -n "$DOMAIN" ]] || die "Domain is required. Use --domain=example.com"

# Validate inputs
validate_domain "$DOMAIN"
validate_php_version "$PHP_VERSION"

SITE_ID=$(sanitize_for_identifier "$DOMAIN")
SITE_DIR="/home/deployer/sites/${DOMAIN}"
FPM_SOCKET="/var/run/php/php${PHP_VERSION}-${DOMAIN}-fpm.sock"
TEMPLATE_DIR="${FORGE_LITE_DIR}/server/config/templates"
SITE_CONFIG="/etc/forge-lite/${DOMAIN}.conf"

# Check if site already exists
if [[ -f "$SITE_CONFIG" ]]; then
    die "Site ${DOMAIN} already exists. Remove it first with remove-site.sh"
fi

log_info "=========================================="
log_info "  Adding site: ${DOMAIN}"
log_info "=========================================="

# ---------------------------------------------------------------------------
# Cleanup trap — remove partially created resources on failure
# ---------------------------------------------------------------------------
ADD_SITE_FAILED=true
cleanup_add_site() {
    if [[ "$ADD_SITE_FAILED" == true ]]; then
        log_warn "Site creation failed -- cleaning up..."
        rm -f "/etc/php/${PHP_VERSION}/fpm/pool.d/${DOMAIN}.conf" 2>/dev/null || true
        rm -f "/etc/nginx/sites-enabled/${DOMAIN}.conf" 2>/dev/null || true
        rm -f "/etc/nginx/sites-available/${DOMAIN}.conf" 2>/dev/null || true
        rm -f /etc/supervisor/conf.d/${DOMAIN}-*.conf 2>/dev/null || true
        rm -f "/etc/cron.d/${DOMAIN}-scheduler" 2>/dev/null || true
        rm -f "$SITE_CONFIG" 2>/dev/null || true
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi
}
trap cleanup_add_site EXIT

# ---------------------------------------------------------------------------
# 1. Create directory layout
# ---------------------------------------------------------------------------
log_info "Creating directory structure..."
mkdir -p "${SITE_DIR}"/{releases,shared/storage/{app/public,framework/{cache/data,sessions,testing,views},logs}}
touch "${SITE_DIR}/shared/.env"
chown -R deployer:deployer "$SITE_DIR"

log_ok "Directory structure created"

# Create empty Basic Auth include files (nginx requires the include to exist)
mkdir -p /etc/forge-lite/auth
touch "/etc/forge-lite/auth/${DOMAIN}.conf"
touch "/etc/forge-lite/auth/${DOMAIN}.htpasswd"
chmod 644 "/etc/forge-lite/auth/${DOMAIN}.conf"
chown root:www-data "/etc/forge-lite/auth/${DOMAIN}.htpasswd"
chmod 640 "/etc/forge-lite/auth/${DOMAIN}.htpasswd"

# ---------------------------------------------------------------------------
# 2. PHP-FPM pool (multi-site aware sizing)
# ---------------------------------------------------------------------------
log_info "Creating PHP-FPM pool..."

# Calculate pool sizes based on available RAM and number of sites
RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
site_count=1
if [[ -d /etc/forge-lite ]]; then
    site_count=$(( $(find /etc/forge-lite -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l) + 1 ))
fi
ram_pct=$(( 70 / site_count ))
[[ $ram_pct -gt 30 ]] && ram_pct=30
[[ $ram_pct -lt 5 ]] && ram_pct=5
# Rough: each worker ~40MB
PM_MAX_CHILDREN=$(( RAM_MB * ram_pct / 100 / 40 ))
[[ $PM_MAX_CHILDREN -lt 5 ]] && PM_MAX_CHILDREN=5
PM_START_SERVERS=$(( PM_MAX_CHILDREN / 4 ))
[[ $PM_START_SERVERS -lt 2 ]] && PM_START_SERVERS=2
PM_MIN_SPARE=$(( PM_START_SERVERS ))
PM_MAX_SPARE=$(( PM_MAX_CHILDREN / 2 ))

render_template "${TEMPLATE_DIR}/php/php-fpm-pool.conf" \
    "/etc/php/${PHP_VERSION}/fpm/pool.d/${DOMAIN}.conf" \
    "POOL_NAME=${SITE_ID}" \
    "FPM_SOCKET=${FPM_SOCKET}" \
    "PHP_VERSION=${PHP_VERSION}" \
    "PM_MAX_CHILDREN=${PM_MAX_CHILDREN}" \
    "PM_START_SERVERS=${PM_START_SERVERS}" \
    "PM_MIN_SPARE=${PM_MIN_SPARE}" \
    "PM_MAX_SPARE=${PM_MAX_SPARE}"

log_ok "PHP-FPM pool created"

# ---------------------------------------------------------------------------
# 3. NGINX vhost
# ---------------------------------------------------------------------------
log_info "Creating NGINX vhost..."

render_template "${TEMPLATE_DIR}/nginx/vhost.conf" \
    "/etc/nginx/sites-available/${DOMAIN}.conf" \
    "DOMAIN=${DOMAIN}" \
    "FPM_SOCKET=${FPM_SOCKET}"

ln -sf "/etc/nginx/sites-available/${DOMAIN}.conf" "/etc/nginx/sites-enabled/${DOMAIN}.conf"

log_ok "NGINX vhost created"

# ---------------------------------------------------------------------------
# 4. MariaDB database + user (via mysql_safe — no password in ps)
# ---------------------------------------------------------------------------
log_info "Creating database..."

ROOT_PASS=$(get_credential "MARIADB_ROOT_PASSWORD") || die "MariaDB root password not found"
DB_NAME="$SITE_ID"
DB_USER="$SITE_ID"
DB_PASS=$(generate_password 32)

mysql_safe "${ROOT_PASS}" <<MYSQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL

store_credential "DB_${SITE_ID}_PASSWORD" "$DB_PASS"
log_ok "Database '${DB_NAME}' created"

# ---------------------------------------------------------------------------
# 5. Supervisor queue workers
# ---------------------------------------------------------------------------
if [[ "$ENABLE_HORIZON" == true ]]; then
    log_info "Creating Horizon supervisor config..."
    render_template "${TEMPLATE_DIR}/supervisor/laravel-horizon.conf" \
        "/etc/supervisor/conf.d/${DOMAIN}-horizon.conf" \
        "DOMAIN=${DOMAIN}"
    log_ok "Horizon config created"
else
    log_info "Creating queue worker supervisor config..."
    render_template "${TEMPLATE_DIR}/supervisor/laravel-worker.conf" \
        "/etc/supervisor/conf.d/${DOMAIN}-worker.conf" \
        "DOMAIN=${DOMAIN}" \
        "NUM_PROCS=${QUEUE_WORKERS}"
    log_ok "Queue worker config created (${QUEUE_WORKERS} processes)"
fi

# ---------------------------------------------------------------------------
# 6. Inertia SSR (optional)
# ---------------------------------------------------------------------------
if [[ "$ENABLE_SSR" == true ]]; then
    log_info "Creating SSR supervisor config..."
    render_template "${TEMPLATE_DIR}/supervisor/laravel-ssr.conf" \
        "/etc/supervisor/conf.d/${DOMAIN}-ssr.conf" \
        "DOMAIN=${DOMAIN}"
    log_ok "SSR config created"
fi

# ---------------------------------------------------------------------------
# 7. Scheduler cron
# ---------------------------------------------------------------------------
if [[ "$ENABLE_SCHEDULER" == true ]]; then
    log_info "Creating scheduler cron..."
    render_template "${TEMPLATE_DIR}/cron/laravel-scheduler" \
        "/etc/cron.d/${DOMAIN}-scheduler" \
        "DOMAIN=${DOMAIN}"
    chmod 644 "/etc/cron.d/${DOMAIN}-scheduler"
    log_ok "Scheduler cron created"
fi

# ---------------------------------------------------------------------------
# 8. SSL certificate (optional)
# ---------------------------------------------------------------------------
if [[ "$SSL" == true ]]; then
    log_info "Issuing SSL certificate..."
    # We need nginx running with the HTTP vhost first for the challenge
    nginx -t && systemctl reload nginx

    certbot certonly --nginx \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email || log_warn "SSL issuance failed — site will work on HTTP only"

    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        render_template "${TEMPLATE_DIR}/nginx/vhost-ssl.conf" \
            "/etc/nginx/sites-available/${DOMAIN}.conf" \
            "DOMAIN=${DOMAIN}" \
            "FPM_SOCKET=${FPM_SOCKET}"
        log_ok "SSL certificate issued and vhost updated"
    else
        SSL=false
        log_warn "SSL certificate was not obtained — site will use HTTP"
        log_info "Enable SSL later with: forge-lite ssl issue ${DOMAIN}"
    fi
fi

# ---------------------------------------------------------------------------
# 9. Pre-fill .env template
# ---------------------------------------------------------------------------
REDIS_PASS=$(get_credential "REDIS_PASSWORD" 2>/dev/null) || REDIS_PASS=""
APP_URL="http://${DOMAIN}"
[[ "$SSL" == true ]] && APP_URL="https://${DOMAIN}"

cat > "${SITE_DIR}/shared/.env" <<ENV
APP_NAME="${DOMAIN}"
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=${APP_URL}

LOG_CHANNEL=stack
LOG_LEVEL=error

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=${REDIS_PASS}
REDIS_PORT=6379
ENV

# Apply --env overrides (with sed-safe escaping)
for env_pair in "${EXTRA_ENV_VARS[@]+"${EXTRA_ENV_VARS[@]}"}"; do
    [[ -z "$env_pair" ]] && continue
    env_key="${env_pair%%=*}"
    env_val="${env_pair#*=}"
    escaped_val=$(sed_escape_value "$env_val")
    if grep -qF "${env_key}=" "${SITE_DIR}/shared/.env" && grep -q "^${env_key}=" "${SITE_DIR}/shared/.env"; then
        sed -i "s|^${env_key}=.*|${env_key}=${escaped_val}|" "${SITE_DIR}/shared/.env"
    else
        echo "${env_key}=${env_val}" >> "${SITE_DIR}/shared/.env"
    fi
done

# Generate APP_KEY if still empty
if grep -q "^APP_KEY=$" "${SITE_DIR}/shared/.env"; then
    APP_KEY_VALUE="base64:$(openssl rand -base64 32)"
    escaped_key=$(sed_escape_value "$APP_KEY_VALUE")
    sed -i "s|^APP_KEY=.*|APP_KEY=${escaped_key}|" "${SITE_DIR}/shared/.env"
    log_info "APP_KEY auto-generated"
fi

chown deployer:deployer "${SITE_DIR}/shared/.env"
chmod 600 "${SITE_DIR}/shared/.env"
log_ok ".env template created"

# ---------------------------------------------------------------------------
# 10. Save site config
# ---------------------------------------------------------------------------
mkdir -p /etc/forge-lite
cat > "$SITE_CONFIG" <<CONF
# forge-lite site configuration
# Generated: $(date -Iseconds)
DOMAIN=${DOMAIN}
SITE_DIR=${SITE_DIR}
PHP_VERSION=${PHP_VERSION}
FPM_SOCKET=${FPM_SOCKET}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
QUEUE_WORKERS=${QUEUE_WORKERS}
ENABLE_HORIZON=${ENABLE_HORIZON}
ENABLE_SSR=${ENABLE_SSR}
ENABLE_SCHEDULER=${ENABLE_SCHEDULER}
SSL=${SSL}
CONF

log_ok "Site config saved to ${SITE_CONFIG}"

# ---------------------------------------------------------------------------
# 11. Reload services
# ---------------------------------------------------------------------------
log_info "Reloading services..."
systemctl restart "php${PHP_VERSION}-fpm"
nginx -t && systemctl reload nginx
supervisorctl reread
supervisorctl update

# Mark success (disables cleanup trap)
ADD_SITE_FAILED=false

log_ok "=========================================="
log_ok "  Site ${DOMAIN} added successfully!"
log_ok "=========================================="
log_info "Site directory: ${SITE_DIR}"
if [[ "$SSL" == false ]]; then
    log_info "SSL: not enabled. Add later with: forge-lite ssl issue ${DOMAIN}"
fi
log_info "Deploy with: deploy.sh ${DOMAIN} --repo=<url> --branch=main"
log_info "Or from CI:  deploy.sh ${DOMAIN} --artifact=<path.tar.gz>"
