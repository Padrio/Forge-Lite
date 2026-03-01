#!/usr/bin/env bash
# forge-lite/server/modules/nginx.sh — NGINX + DH params + base config + catch-all
provision_nginx() {
    log_info "=== Provisioning: NGINX ==="

    # Install NGINX (mainline from ondrej PPA or default)
    ensure_packages nginx

    # Create forge-lite config directory
    mkdir -p /etc/nginx/forge-lite-conf.d

    # Generate DH params (if not already present)
    local dh_params="/etc/nginx/dhparams.pem"
    if [[ ! -f "$dh_params" ]]; then
        log_info "Generating DH params (2048-bit)... this may take a moment"
        openssl dhparam -out "$dh_params" 2048
        log_ok "DH params generated"
    fi

    # Deploy main nginx.conf from template
    local template_dir="${FORGE_LITE_DIR}/server/config/templates/nginx"
    render_template "${template_dir}/nginx.conf" /etc/nginx/nginx.conf \
        "WORKER_CONNECTIONS=1024"

    # Deploy catch-all server block
    render_template "${template_dir}/catch-all.conf" /etc/nginx/sites-available/catch-all.conf

    # Enable catch-all, disable default
    ln -sf /etc/nginx/sites-available/catch-all.conf /etc/nginx/sites-enabled/catch-all.conf
    rm -f /etc/nginx/sites-enabled/default

    # Test and reload
    nginx -t || die "NGINX configuration test failed"
    ensure_service nginx restart

    log_ok "NGINX provisioning complete"
}
