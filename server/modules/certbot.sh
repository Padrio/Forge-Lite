#!/usr/bin/env bash
# forge-lite/server/modules/certbot.sh — Certbot + nginx plugin + renewal timer
provision_certbot() {
    log_info "=== Provisioning: Certbot ==="

    ensure_packages certbot python3-certbot-nginx

    # Verify the systemd renewal timer is active
    if systemctl list-timers | grep -q "certbot"; then
        log_info "Certbot renewal timer is active"
    else
        # Enable the timer if it exists but is not active
        systemctl enable --now certbot.timer 2>/dev/null || \
            log_warn "Certbot timer not found — renewals depend on cron or manual setup"
    fi

    log_ok "Certbot provisioning complete"
}
