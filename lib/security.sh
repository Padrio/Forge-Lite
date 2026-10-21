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

# _deployer_sudoers_placeholder
# Comment-only content for /etc/sudoers.d/deployer. Keeping the file (instead
# of deleting it) stops older forge-lite checkouts, whose system.sh only
# created the blanket rule when the file was missing, from re-granting it.
_deployer_sudoers_placeholder() {
    cat <<'SUDOERS'
# Managed by forge-lite: deployer intentionally has NO sudo rights.
# PHP-FPM pools, queue workers, Reverb, Horizon and scheduler crons run as
# deployer, so any rule here turns application code execution into root.
# Administer the server as root; do not add rules to this file.
SUDOERS
}

# _refuse_self_revoke
# Revoking sudo from inside deployer's own sudo session would cut the
# operator's admin path mid-session. Require root or an explicit override.
_refuse_self_revoke() {
    [[ "${SUDO_USER:-}" == "deployer" && "${FORGE_LITE_ALLOW_SELF_REVOKE:-false}" != true ]] || return 0
    log_error "Invoked through deployer's sudo; revoking it would remove your own admin path."
    log_error "Confirm 'ssh root@<host>' works, then re-run as root (or set FORGE_LITE_ALLOW_SELF_REVOKE=true)."
    return 1
}

# revoke_deployer_sudo [sudoers_dir] [backup_dir]
# Replace any sudo grant in <sudoers_dir>/deployer with the comment-only
# placeholder and remove deployer from the sudo/admin groups. The previous
# file is kept under <backup_dir> (first backup is never overwritten), the
# candidate is checked with `visudo -c -f` before it is moved into place, and
# the complete configuration is re-checked with `visudo -c` afterwards; on
# failure the previous file is restored. A converged server is left untouched.
# Serialized with flock: overlapping update/provision runs share the staging
# file and the first backup.
revoke_deployer_sudo() {
    local lock_dir="${FORGE_LITE_LOCK_DIR:-/var/run}"
    mkdir -p "${lock_dir}" || return 1
    (
        flock 9 || exit 1
        _revoke_deployer_sudo_unlocked "$@"
    ) 9>"${lock_dir}/forge-lite-deployer-sudo.lock"
}

_revoke_deployer_sudo_unlocked() {
    local sudoers_dir="${1:-${FORGE_LITE_SUDOERS_DIR:-/etc/sudoers.d}}"
    local backup_dir="${2:-${FORGE_LITE_BACKUP_DIR:-/var/backups/forge-lite}}"
    local visudo_bin="${FORGE_LITE_VISUDO:-visudo}"
    local target="${sudoers_dir}/deployer"
    # sudo skips include files whose name contains a dot.
    local staging="${sudoers_dir}/.deployer.forge-lite-new"
    local backup="${backup_dir}/sudoers.d-deployer.pre-revoke"
    local groups_backup="${backup_dir}/deployer-groups.pre-revoke"
    local had_target=false group member_of listing
    local -a full_check=("${visudo_bin}" -c)

    [[ -z "${FORGE_LITE_SUDOERS_FILE:-}" ]] || full_check+=(-f "${FORGE_LITE_SUDOERS_FILE}")

    # A killed earlier run may have left its candidate behind.
    rm -f "${staging}" || return 1

    if [[ ! -f "${target}" ]] || ! _deployer_sudoers_placeholder | cmp -s - "${target}"; then
        _refuse_self_revoke || return 1
        command -v "${visudo_bin}" >/dev/null 2>&1 || {
            log_error "visudo not found; refusing to change ${target}"
            return 1
        }
        "${full_check[@]}" >/dev/null || {
            log_error "visudo -c fails before any change (syntax error, or an include not root:root mode 0440); refusing to change ${target}"
            return 1
        }

        if [[ -e "${target}" ]]; then
            had_target=true
            mkdir -p "${backup_dir}" || return 1
            chmod 700 "${backup_dir}" 2>/dev/null || true
            if [[ -s "${backup}" ]] && ! cmp -s "${target}" "${backup}"; then
                backup="${backup}.$(date +%Y%m%d%H%M%S)"
            fi
            if ! { cp -a "${target}" "${backup}.tmp" && mv -f "${backup}.tmp" "${backup}"; }; then
                rm -f "${backup}.tmp"
                return 1
            fi
        fi

        _deployer_sudoers_placeholder > "${staging}" || { rm -f "${staging}"; return 1; }
        chmod 440 "${staging}" || { rm -f "${staging}"; return 1; }
        if ! "${visudo_bin}" -c -f "${staging}" >/dev/null; then
            rm -f "${staging}"
            log_error "visudo rejected the deployer sudoers placeholder; ${target} left unchanged"
            return 1
        fi
        mv -f "${staging}" "${target}" || { rm -f "${staging}"; return 1; }

        if ! "${full_check[@]}" >/dev/null; then
            log_error "visudo rejected the resulting sudoers configuration; restoring ${target}"
            if [[ "${had_target}" == true ]]; then
                cp -a "${backup}" "${staging}" && mv -f "${staging}" "${target}" || return 1
            else
                rm -f "${target}"
            fi
            return 1
        fi

        if [[ "${had_target}" == true ]]; then
            log_ok "Revoked deployer sudo rule in ${target} (backup: ${backup})"
        else
            log_ok "Installed deployer no-sudo placeholder: ${target}"
        fi
    fi

    id deployer >/dev/null 2>&1 || return 0
    for group in sudo admin; do
        member_of=" $(id -nG deployer) "
        [[ "${member_of}" == *" ${group} "* ]] || continue
        _refuse_self_revoke || return 1
        if [[ ! -s "${groups_backup}" ]]; then
            mkdir -p "${backup_dir}" || return 1
            chmod 700 "${backup_dir}" 2>/dev/null || true
            if ! { id -nG deployer > "${groups_backup}.tmp" && mv -f "${groups_backup}.tmp" "${groups_backup}"; }; then
                rm -f "${groups_backup}.tmp"
                return 1
            fi
        fi
        if ! gpasswd -d deployer "${group}" >/dev/null; then
            member_of=" $(id -nG deployer) "
            [[ "${member_of}" == *" ${group} "* ]] || continue
            log_error "deployer is still in group ${group} (primary group or non-local account source?); remove it manually"
            return 1
        fi
        log_ok "Removed deployer from group ${group} (previous groups: ${groups_backup})"
    done

    # Rules from other sudoers sources are not edited automatically; surface them.
    if command -v sudo >/dev/null 2>&1; then
        listing="$(LC_ALL=C sudo -n -l -U deployer 2>&1 || true)"
        [[ "${listing}" == *"is not allowed to run sudo"* ]] ||
            log_warn "deployer still has sudo rights from another sudoers source (check 'sudo -l -U deployer'): ${listing}"
    fi
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
