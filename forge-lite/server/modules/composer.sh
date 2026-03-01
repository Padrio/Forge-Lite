#!/usr/bin/env bash
# forge-lite/server/modules/composer.sh — Global Composer install + auto-update cron
provision_composer() {
    log_info "=== Provisioning: Composer ==="

    local composer_bin="/usr/local/bin/composer"

    if [[ ! -f "$composer_bin" ]]; then
        log_info "Installing Composer..."
        local expected_sig
        expected_sig=$(curl -fsSL https://composer.github.io/installer.sig)
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        local actual_sig
        actual_sig=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")

        if [[ "$expected_sig" != "$actual_sig" ]]; then
            rm -f /tmp/composer-setup.php
            die "Composer installer signature mismatch!"
        fi

        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
        log_ok "Composer installed"
    else
        log_info "Composer already installed, skipping"
    fi

    # Auto-update cron (weekly)
    local cron_file="/etc/cron.weekly/composer-update"
    if [[ ! -f "$cron_file" ]]; then
        cat > "$cron_file" <<'CRON'
#!/bin/bash
/usr/local/bin/composer self-update --quiet 2>/dev/null
CRON
        chmod +x "$cron_file"
        log_ok "Composer auto-update cron installed"
    fi

    log_ok "Composer provisioning complete"
}
