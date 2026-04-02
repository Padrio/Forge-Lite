#!/usr/bin/env bash
# forge-lite/server/modules/swap.sh — Swap file, sysctl tuning, OOM priorities
set -euo pipefail

provision_swap() {
    log_info "=== Provisioning: Swap & Kernel Tuning ==="

    # Create swap file based on RAM (1x RAM for <=2GB, else 2GB)
    if [[ ! -f /swapfile ]]; then
        local ram_mb
        ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
        local swap_mb
        if [[ $ram_mb -le 2048 ]]; then
            swap_mb=$ram_mb
        else
            swap_mb=2048
        fi
        log_info "Creating ${swap_mb}MB swap file..."
        fallocate -l "${swap_mb}M" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        ensure_line_in_file /etc/fstab "/swapfile none swap sw 0 0" "/swapfile"
        log_ok "Swap file created (${swap_mb}MB)"
    else
        log_info "Swap file already exists, skipping"
    fi

    # Sysctl tuning
    local sysctl_file="/etc/sysctl.d/99-forge-lite.conf"
    if [[ ! -f "$sysctl_file" ]]; then
        cat > "$sysctl_file" <<'SYSCTL'
# forge-lite kernel tuning

# Memory & file limits
vm.swappiness = 30
vm.overcommit_memory = 1
fs.file-max = 2097152

# Network — core
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# TCP tuning (net.ipv4.tcp_* applies to BOTH IPv4 and IPv6 in Linux 4.9+)
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 65535

# IPv6 — ensure enabled and accepting Router Advertisements
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 1
net.ipv6.conf.default.accept_ra = 1
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
SYSCTL
        sysctl -p "$sysctl_file"
        log_ok "Sysctl tuning applied (IPv4 + IPv6)"
    fi

    # OOM score adjustments (lower = less likely to be killed)
    # These are applied via systemd drop-ins for persistence
    local nginx_oom="/etc/systemd/system/nginx.service.d"
    if [[ ! -d "$nginx_oom" ]]; then
        mkdir -p "$nginx_oom"
        cat > "${nginx_oom}/oom.conf" <<'EOF'
[Service]
OOMScoreAdjust=-500
EOF
        log_info "Set OOM priority for nginx"
    fi

    local mariadb_oom="/etc/systemd/system/mariadb.service.d"
    if [[ ! -d "$mariadb_oom" ]]; then
        mkdir -p "$mariadb_oom"
        cat > "${mariadb_oom}/oom.conf" <<'EOF'
[Service]
OOMScoreAdjust=-500
EOF
        log_info "Set OOM priority for MariaDB"
    fi

    systemctl daemon-reload 2>/dev/null || true

    log_ok "Swap & kernel tuning complete"
}
