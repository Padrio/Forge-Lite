#!/usr/bin/env bash
# forge-lite/lib/logrotate.sh — managed logrotate config lifecycle helpers
set -euo pipefail

# ---------------------------------------------------------------------------
# ensure_logrotate_config <template> [target]
#   Installs the forge-lite logrotate template when the target is missing or
#   differs. Idempotent: an identical target is left untouched and nothing is
#   logged. A differing target is backed up to <target>.pre-migration first.
#   When logrotate is available the installed file is syntax-checked; on
#   failure the previous file is restored and the function returns 1.
# ---------------------------------------------------------------------------
ensure_logrotate_config() {
    local template="$1"
    local target="${2:-${FORGE_LITE_LOGROTATE_TARGET:-/etc/logrotate.d/forge-lite}}"
    local backup="${target}.pre-migration"
    local had_target=false

    [[ -f "${template}" ]] || {
        log_error "logrotate template not found: ${template}"
        return 1
    }

    if [[ -f "${target}" ]] && cmp -s "${template}" "${target}"; then
        return 0
    fi

    if [[ -f "${target}" ]]; then
        had_target=true
        cp -a "${target}" "${backup}" || return 1
    fi

    install -m 644 "${template}" "${target}" || return 1

    if [[ -f "${target}" ]] && command -v logrotate >/dev/null 2>&1; then
        if ! logrotate -d "${target}" >/dev/null 2>&1; then
            log_error "logrotate rejected ${target}; restoring previous config"
            if [[ "${had_target}" == true ]]; then
                mv -f "${backup}" "${target}" || return 1
            else
                rm -f "${target}"
            fi
            return 1
        fi
    fi

    if [[ "${had_target}" == true ]]; then
        log_info "Migrated logrotate config: ${target} (backup: ${backup})"
    else
        log_info "Installed logrotate config: ${target}"
    fi
}
