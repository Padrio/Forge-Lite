#!/usr/bin/env bash
# forge-lite/server/modules/php.sh — PHP 8.1-8.4 parallel install + FPM + production php.ini
provision_php() {
    log_info "=== Provisioning: PHP ==="

    local php_versions=("8.1" "8.2" "8.3" "8.4")
    local php_default="${FORGE_LITE_PHP_DEFAULT:-8.3}"
    local template_dir="${FORGE_LITE_DIR}/server/config/templates/php"

    # Laravel extensions
    local extensions=(
        cli fpm common mysql zip gd mbstring curl xml bcmath
        intl readline soap imap tokenizer sqlite3 msgpack
        igbinary redis swoole opcache
    )

    for version in "${php_versions[@]}"; do
        local pkgs=()
        for ext in "${extensions[@]}"; do
            pkgs+=("php${version}-${ext}")
        done

        log_info "Installing PHP ${version}..."
        ensure_packages "${pkgs[@]}"

        # Deploy production php.ini overrides
        render_template "${template_dir}/php.ini" \
            "/etc/php/${version}/fpm/conf.d/99-forge-lite.ini" \
            "PHP_VERSION=${version}"

        render_template "${template_dir}/php.ini" \
            "/etc/php/${version}/cli/conf.d/99-forge-lite.ini" \
            "PHP_VERSION=${version}"

        # Ensure FPM is enabled and running
        ensure_service "php${version}-fpm" start
        log_ok "PHP ${version} installed and FPM started"
    done

    # Set default PHP CLI version
    update-alternatives --set php "/usr/bin/php${php_default}" 2>/dev/null || true
    update-alternatives --set phar "/usr/bin/phar${php_default}" 2>/dev/null || true
    update-alternatives --set phar.phar "/usr/bin/phar.phar${php_default}" 2>/dev/null || true

    log_ok "PHP provisioning complete (default: ${php_default})"
}
