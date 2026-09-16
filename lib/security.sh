#!/usr/bin/env bash
# forge-lite/lib/security.sh — repeatable security catch-up helpers
set -euo pipefail

# repair_storage_permissions [sites_root]
# Remove world-write access from Laravel's shared runtime directories while
# preserving the documented deployer-owned 0775 directory policy.
repair_storage_permissions() {
    local sites_root="${1:-/home/deployer/sites}" storage

    [[ -d "${sites_root}" ]] || return 0
    for storage in "${sites_root}"/*/shared/storage; do
        [[ -d "${storage}" ]] || continue
        chown -R deployer:deployer "${storage}"
        find "${storage}" -type d -exec chmod 775 {} +
    done
}

# ensure_fail2ban_scanner_config [template_dir] [filter_target] [jail_target]
# Install the forge-lite scanner filter/jail only when content changed. The
# complete Fail2Ban configuration is validated before the daemon is restarted.
ensure_fail2ban_scanner_config() {
    local template_dir="${1:-${FORGE_LITE_DIR}/server/config/templates/fail2ban}"
    local filter_target="${2:-${FORGE_LITE_FAIL2BAN_FILTER_TARGET:-/etc/fail2ban/filter.d/nginx-scanner.conf}}"
    local jail_target="${3:-${FORGE_LITE_FAIL2BAN_JAIL_TARGET:-/etc/fail2ban/jail.d/99-forge-lite.local}}"
    local security_log="${FORGE_LITE_SECURITY_LOG:-/var/log/nginx/forge-lite-security.log}"
    local filter_source="${template_dir}/nginx-scanner.conf"
    local jail_source="${template_dir}/forge-lite.local"
    local changed=false filter_changed=false jail_changed=false
    local filter_backup="" jail_backup=""

    [[ -f "${filter_source}" && -f "${jail_source}" ]] || {
        log_error "Fail2Ban scanner templates are missing in ${template_dir}"
        return 1
    }

    mkdir -p "$(dirname "${filter_target}")" "$(dirname "${jail_target}")"
    if ! cmp -s "${filter_source}" "${filter_target}"; then
        if [[ -f "${filter_target}" ]]; then
            filter_backup="$(mktemp)"
            cp -a "${filter_target}" "${filter_backup}"
        fi
        install -m 644 "${filter_source}" "${filter_target}"
        changed=true
        filter_changed=true
    fi
    if ! cmp -s "${jail_source}" "${jail_target}"; then
        if [[ -f "${jail_target}" ]]; then
            jail_backup="$(mktemp)"
            cp -a "${jail_target}" "${jail_backup}"
        fi
        install -m 644 "${jail_source}" "${jail_target}"
        changed=true
        jail_changed=true
    fi

    [[ "${changed}" == true ]] || return 0

    # Fail2Ban refuses to start a file-backed jail if its log does not exist.
    mkdir -p "$(dirname "${security_log}")"
    if [[ ! -e "${security_log}" ]]; then
        if [[ "${security_log}" == /var/log/nginx/* ]]; then
            install -o www-data -g adm -m 640 /dev/null "${security_log}"
        else
            install -m 640 /dev/null "${security_log}"
        fi
    else
        if [[ "${security_log}" == /var/log/nginx/* ]]; then
            chown www-data:adm "${security_log}"
        fi
        chmod 640 "${security_log}"
    fi

    if command -v fail2ban-client >/dev/null 2>&1 && ! fail2ban-client -t >/dev/null 2>&1; then
        log_error "Fail2Ban validation failed; restoring previous scanner configuration"
        if [[ "${filter_changed}" == true ]]; then
            if [[ -n "${filter_backup}" ]]; then cp -a "${filter_backup}" "${filter_target}"; else rm -f "${filter_target}"; fi
        fi
        if [[ "${jail_changed}" == true ]]; then
            if [[ -n "${jail_backup}" ]]; then cp -a "${jail_backup}" "${jail_target}"; else rm -f "${jail_target}"; fi
        fi
        [[ -z "${filter_backup}" ]] || rm -f "${filter_backup}"
        [[ -z "${jail_backup}" ]] || rm -f "${jail_backup}"
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then
        if ! systemctl restart fail2ban; then
            log_error "Fail2Ban restart failed; restoring previous scanner configuration"
            if [[ "${filter_changed}" == true ]]; then
                if [[ -n "${filter_backup}" ]]; then cp -a "${filter_backup}" "${filter_target}"; else rm -f "${filter_target}"; fi
            fi
            if [[ "${jail_changed}" == true ]]; then
                if [[ -n "${jail_backup}" ]]; then cp -a "${jail_backup}" "${jail_target}"; else rm -f "${jail_target}"; fi
            fi
            systemctl restart fail2ban || true
            [[ -z "${filter_backup}" ]] || rm -f "${filter_backup}"
            [[ -z "${jail_backup}" ]] || rm -f "${jail_backup}"
            return 1
        fi
    fi
    [[ -z "${filter_backup}" ]] || rm -f "${filter_backup}"
    [[ -z "${jail_backup}" ]] || rm -f "${jail_backup}"
    log_ok "Fail2Ban scanner jail synchronized"
}
