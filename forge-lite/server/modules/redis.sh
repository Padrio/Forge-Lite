#!/usr/bin/env bash
# forge-lite/server/modules/redis.sh — Redis + password + AOF + maxmemory tuning
provision_redis() {
    log_info "=== Provisioning: Redis ==="

    ensure_packages redis-server

    # Generate or retrieve Redis password
    local redis_pass
    redis_pass=$(get_credential "REDIS_PASSWORD" 2>/dev/null) || {
        redis_pass="${FORGE_LITE_REDIS_PASSWORD:-$(generate_password 32)}"
        store_credential "REDIS_PASSWORD" "$redis_pass"
    }

    # Calculate maxmemory (~25% of RAM)
    local ram_mb
    ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
    local max_memory_mb=$(( ram_mb * 25 / 100 ))

    # Deploy Redis config from template
    local template_dir="${FORGE_LITE_DIR}/server/config/templates/redis"
    render_template "${template_dir}/redis.conf" /etc/redis/redis.conf \
        "REDIS_PASSWORD=${redis_pass}" \
        "MAXMEMORY=${max_memory_mb}mb"

    ensure_service redis-server restart
    log_ok "Redis provisioning complete"
}
