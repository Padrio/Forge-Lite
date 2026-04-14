#!/usr/bin/env bash
# forge-lite/server/modules/system.sh — Base packages, deployer user, timezone, locale, limits
provision_system() {
    log_info "=== Provisioning: System Base ==="

    # Add ondrej/php PPA
    if [[ ! -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list ]] && \
       [[ ! -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.sources ]]; then
        log_info "Adding ondrej/php PPA..."
        ensure_packages software-properties-common
        add-apt-repository -y ppa:ondrej/php
    fi

    # Update and upgrade
    log_info "Updating package lists..."
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q

    # Base packages
    ensure_packages \
        curl wget git unzip zip htop ncdu tree jq \
        build-essential gcc make \
        acl \
        ufw \
        cron \
        logrotate

    # Create deployer user
    ensure_user deployer /bin/bash /home/deployer

    # Add deployer to sudo + www-data groups
    usermod -aG sudo deployer 2>/dev/null || true
    usermod -aG www-data deployer 2>/dev/null || true

    # Make home directory traversable by www-data (nginx)
    # 711 = owner rwx, group --x, others --x (traverse only, no listing)
    chmod 711 /home/deployer

    # Passwordless sudo for deployer
    if [[ ! -f /etc/sudoers.d/deployer ]]; then
        echo "deployer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deployer
        chmod 440 /etc/sudoers.d/deployer
        log_info "Configured passwordless sudo for deployer"
    fi

    # Create sites directory
    mkdir -p /home/deployer/sites
    chown deployer:deployer /home/deployer/sites

    # Set timezone to UTC
    if [[ "$(timedatectl show --property=Timezone --value 2>/dev/null)" != "UTC" ]]; then
        timedatectl set-timezone UTC
        log_info "Set timezone to UTC"
    fi

    # Locale
    if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        locale-gen en_US.UTF-8
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
        log_info "Generated en_US.UTF-8 locale"
    fi

    # Pre-populate SSH known_hosts for common Git hosts (GitHub, GitLab, Bitbucket)
    # Prevents interactive "authenticity of host" prompts during git clone
    for ssh_user_home in /root /home/deployer; do
        local ssh_dir="${ssh_user_home}/.ssh"
        local known_hosts="${ssh_dir}/known_hosts"
        mkdir -p "$ssh_dir"
        for host in github.com gitlab.com bitbucket.org; do
            if ! grep -qF "$host" "$known_hosts" 2>/dev/null; then
                ssh-keyscan -t ed25519,rsa "$host" >> "$known_hosts" 2>/dev/null || true
            fi
        done
        chmod 700 "$ssh_dir"
        chmod 644 "$known_hosts"
    done
    chown -R deployer:deployer /home/deployer/.ssh
    log_info "SSH known_hosts populated for GitHub, GitLab, Bitbucket"

    # Open file limits
    ensure_line_in_file /etc/security/limits.conf "deployer soft nofile 65535" "deployer soft nofile"
    ensure_line_in_file /etc/security/limits.conf "deployer hard nofile 65535" "deployer hard nofile"
    ensure_line_in_file /etc/security/limits.conf "www-data soft nofile 65535" "www-data soft nofile"
    ensure_line_in_file /etc/security/limits.conf "www-data hard nofile 65535" "www-data hard nofile"

    log_ok "System base provisioning complete"
}
