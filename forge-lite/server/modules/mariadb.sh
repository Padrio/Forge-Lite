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

    mysql -u root -p"${root_pass}" -e \
        "CREATE USER IF NOT EXISTS 'forgelite'@'localhost' IDENTIFIED BY '${admin_pass}';
         GRANT ALL PRIVILEGES ON *.* TO 'forgelite'@'localhost' WITH GRANT OPTION;
         FLUSH PRIVILEGES;" 2>/dev/null || true

    # InnoDB tuning — 70% of RAM for buffer pool
    local template_dir="${FORGE_LITE_DIR}/server/config/templates/mariadb"
    local ram_mb
    ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
    local buffer_pool_mb=$(( ram_mb * 70 / 100 ))

    render_template "${template_dir}/50-server.cnf" \
        /etc/mysql/mariadb.conf.d/50-server.cnf \
        "INNODB_BUFFER_POOL_SIZE=${buffer_pool_mb}M"

    ensure_service mariadb restart
    log_ok "MariaDB provisioning complete"
}
