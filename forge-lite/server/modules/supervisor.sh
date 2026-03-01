#!/usr/bin/env bash
# forge-lite/server/modules/supervisor.sh — Supervisor daemon + conf.d directory
provision_supervisor() {
    log_info "=== Provisioning: Supervisor ==="

    ensure_packages supervisor

    # Ensure conf.d directory exists
    mkdir -p /etc/supervisor/conf.d

    ensure_service supervisor start

    log_ok "Supervisor provisioning complete"
}
