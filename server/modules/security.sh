#!/usr/bin/env bash
# forge-lite/server/modules/security.sh — SSH hardening, UFW, Fail2Ban, unattended-upgrades
provision_security() {
    log_info "=== Provisioning: Security ==="

    # --- SSH Hardening ---
    local sshd_config="/etc/ssh/sshd_config"
    local sshd_changed=false

    set_sshd_option() {
        local key="$1" value="$2"
        if grep -qE "^#?${key}\s" "$sshd_config"; then
            sed -i "s/^#*${key}\s.*/${key} ${value}/" "$sshd_config"
        else
            echo "${key} ${value}" >> "$sshd_config"
        fi
        sshd_changed=true
    }

    set_sshd_option "PermitRootLogin" "no"
    set_sshd_option "PasswordAuthentication" "no"
    set_sshd_option "MaxAuthTries" "3"
    set_sshd_option "X11Forwarding" "no"
    set_sshd_option "AllowAgentForwarding" "no"

    if [[ "$sshd_changed" == true ]]; then
        sshd -t && systemctl reload sshd
        log_ok "SSH hardened (key-only, no root, MaxAuthTries=3)"
    fi

    # --- UFW ---
    ensure_packages ufw
    if ! ufw status | grep -q "Status: active"; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp comment "SSH"
        ufw allow 80/tcp comment "HTTP"
        ufw allow 443/tcp comment "HTTPS"
        ufw --force enable
        log_ok "UFW enabled (22/80/443)"
    else
        log_info "UFW already active, skipping"
    fi

    # --- Fail2Ban ---
    ensure_packages fail2ban
    local f2b_local="/etc/fail2ban/jail.local"
    if [[ ! -f "$f2b_local" ]]; then
        cat > "$f2b_local" <<'F2B'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ssh
filter  = sshd

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
backend  = auto

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
backend  = auto
F2B
        ensure_service fail2ban restart
        log_ok "Fail2Ban configured (sshd + nginx jails)"
    fi

    # --- Unattended Upgrades ---
    ensure_packages unattended-upgrades apt-listchanges
    local auto_upgrades="/etc/apt/apt.conf.d/20auto-upgrades"
    if [[ ! -f "$auto_upgrades" ]] || ! grep -q "Unattended-Upgrade" "$auto_upgrades"; then
        cat > "$auto_upgrades" <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
        log_ok "Unattended upgrades enabled"
    fi

    log_ok "Security provisioning complete"
}
