#!/usr/bin/env bash
# forge-lite/server/modules/php.sh — PHP 8.1-8.4 parallel install + FPM + production php.ini
provision_php() {
    log_info "=== Provisioning: PHP ==="

    # Installed versions. 8.1 is EOL (no upstream security fixes) and is NOT
    # installed by default; opt in explicitly with:
    #   provision --php-versions=8.1,8.2,8.3,8.4
    local php_versions_csv="${FORGE_LITE_PHP_VERSIONS:-8.2,8.3,8.4}"
    local php_default="${FORGE_LITE_PHP_DEFAULT:-8.3}"
    local template_dir="${FORGE_LITE_DIR}/server/config/templates/php"

    # Split the CSV into an array (IFS scoped to the read only).
    local php_versions
    IFS=',' read -r -a php_versions <<< "$php_versions_csv"

    # The default version is always installed, even if absent from the list.
    local v found_default=false
    for v in "${php_versions[@]}"; do
        [[ "$v" == "$php_default" ]] && found_default=true
    done
    [[ "$found_default" == true ]] || php_versions+=("$php_default")

    # Laravel extensions
    local extensions=(
        cli fpm common mysql zip gd mbstring curl xml bcmath
        intl readline soap imap tokenizer sqlite3 msgpack
        igbinary redis swoole opcache
    )

    local version ext
    for version in "${php_versions[@]}"; do
        local pkgs=()
        for ext in "${extensions[@]}"; do
            pkgs+=("php${version}-${ext}")
        done

        log_info "Installing PHP ${version}..."
        ensure_packages "${pkgs[@]}"

        # Deploy production php.ini overrides (FPM + CLI)
        render_template "${template_dir}/php.ini" \
            "/etc/php/${version}/fpm/conf.d/99-forge-lite.ini" \
            "PHP_VERSION=${version}"

        render_template "${template_dir}/php.ini" \
            "/etc/php/${version}/cli/conf.d/99-forge-lite.ini" \
            "PHP_VERSION=${version}"

        # FPM lifecycle: only the provisioning default version is enabled and
        # started. Other versions stay installed (so php-switch and per-site
        # --php=X can bring them up on demand) but are stopped + disabled to
        # save RAM and shrink the attack surface — nginx only ever talks to the
        # sockets of versions an actual site uses. add-site.sh re-enables a
        # site's chosen version when it is created.
        if [[ "$version" == "$php_default" ]]; then
            ensure_service "php${version}-fpm" start
            log_ok "PHP ${version} installed, FPM enabled (default)"
        else
            systemctl stop "php${version}-fpm" 2>/dev/null || true
            systemctl disable "php${version}-fpm" 2>/dev/null || true
            log_ok "PHP ${version} installed, FPM stopped+disabled (on-demand)"
        fi
    done

    # Set default PHP CLI version
    update-alternatives --set php "/usr/bin/php${php_default}" 2>/dev/null || true
    update-alternatives --set phar "/usr/bin/phar${php_default}" 2>/dev/null || true
    update-alternatives --set phar.phar "/usr/bin/phar.phar${php_default}" 2>/dev/null || true

    log_ok "PHP provisioning complete (default: ${php_default}, installed: ${php_versions[*]})"
}
