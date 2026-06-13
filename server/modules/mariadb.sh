#!/usr/bin/env bash
# forge-lite/server/modules/mariadb.sh — MariaDB + secure install + InnoDB RAM tuning
provision_mariadb() {
    log_info "=== Provisioning: MariaDB ==="

    ensure_packages mariadb-server mariadb-client

    ensure_service mariadb start

    # Generate or retrieve root password
    local root_pass
    root_pass=$(get_credential "MARIADB_ROOT_PASSWORD" 2>/dev/null) || {
        root_pass="${FORGE_LITE_DB_PASSWORD:-$(generate_password 32)}"
        store_credential "MARIADB_ROOT_PASSWORD" "$root_pass"
    }

    # Secure installation (idempotent — check if root already has password)
    if mysql -u root -e "SELECT 1" &>/dev/null; then
        log_info "Securing MariaDB installation..."
        mysql -u root <<MYSQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${root_pass}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
MYSQL
        log_ok "MariaDB secured"
    else
        log_info "MariaDB root already secured, skipping"
    fi

    # Create forge-lite admin user
    local admin_pass
    admin_pass=$(get_credential "MARIADB_ADMIN_PASSWORD" 2>/dev/null) || {
        admin_pass=$(generate_password 32)
        store_credential "MARIADB_ADMIN_PASSWORD" "$admin_pass"
    }

    mysql_safe "${root_pass}" -e \
        "CREATE USER IF NOT EXISTS 'forgelite'@'localhost' IDENTIFIED BY '${admin_pass}';
         GRANT ALL PRIVILEGES ON *.* TO 'forgelite'@'localhost' WITH GRANT OPTION;
         FLUSH PRIVILEGES;" 2>/dev/null || true

    # InnoDB tuning. Conservative defaults for a multi-service host where PHP-FPM
    # and Redis share the RAM: buffer pool = 20% of RAM, capped at 1024M, floor
    # 256M. Small app DBs do not need a 40-70% pool, and over-provisioning here
    # is exactly what pushed configured RAM past physical on small boxes.
    # Override the absolute size with: provision --db-buffer-pool=512M (or 2G).
    local template_dir="${FORGE_LITE_DIR}/server/config/templates/mariadb"
    local ram_mb buffer_pool_mb
    ram_mb=$(free -m | awk '/^Mem:/ {print $2}')

    if [[ -n "${FORGE_LITE_DB_BUFFER_POOL:-}" ]]; then
        # Explicit override (respected as-is, no cap/floor). Accept 512, 512M or 2G.
        local raw="${FORGE_LITE_DB_BUFFER_POOL}" num
        num="${raw%[MmGg]}"
        [[ "$num" =~ ^[0-9]+$ ]] || die "Invalid --db-buffer-pool='${raw}' (use e.g. 512M or 2G)."
        case "$raw" in
            *[Gg]) buffer_pool_mb=$(( num * 1024 )) ;;
            *)     buffer_pool_mb="$num" ;;
        esac
    else
        buffer_pool_mb=$(( ram_mb * 20 / 100 ))
        [[ $buffer_pool_mb -gt 1024 ]] && buffer_pool_mb=1024
        [[ $buffer_pool_mb -lt 256 ]] && buffer_pool_mb=256
    fi

    # Redo log ~1/4 of the buffer pool, clamped 64-512M (over-sizing wastes disk
    # on tiny DBs; under-sizing throttles write throughput).
    local log_file_mb=$(( buffer_pool_mb / 4 ))
    [[ $log_file_mb -lt 64 ]] && log_file_mb=64
    [[ $log_file_mb -gt 512 ]] && log_file_mb=512

    # Durability default 1 (full ACID, no data loss on crash). Override for higher
    # write throughput with: provision --db-flush-log=2 (~1s loss window on crash).
    local flush_commit="${FORGE_LITE_DB_FLUSH_LOG:-1}"
    [[ "$flush_commit" =~ ^[012]$ ]] || die "Invalid --db-flush-log='${flush_commit}' (use 0, 1, or 2)."

    render_template "${template_dir}/50-server.cnf" \
        /etc/mysql/mariadb.conf.d/50-server.cnf \
        "INNODB_BUFFER_POOL_SIZE=${buffer_pool_mb}M" \
        "INNODB_LOG_FILE_SIZE=${log_file_mb}M" \
        "INNODB_FLUSH_LOG_AT_TRX_COMMIT=${flush_commit}"

    log_info "InnoDB: buffer_pool=${buffer_pool_mb}M log_file=${log_file_mb}M flush_log_at_trx_commit=${flush_commit}"

    ensure_service mariadb restart
    log_ok "MariaDB provisioning complete"
}
