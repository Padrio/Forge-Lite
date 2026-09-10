#!/usr/bin/env bash
# forge-lite/lib/nginx.sh — managed nginx vhost lifecycle helpers
set -euo pipefail

# ---------------------------------------------------------------------------
# strip_vhost_ocsp_stapling <vhost_file>
#   Removes the OCSP stapling directives (and the two-line comment the old
#   template placed above them) from a single vhost. Prints "changed" when the
#   file was modified, nothing when it already lacked stapling. Idempotent.
# ---------------------------------------------------------------------------
strip_vhost_ocsp_stapling() {
    local vhost="$1" tmp

    [[ -f "${vhost}" ]] || return 0
    grep -qE '^[[:space:]]*(ssl_stapling|ssl_stapling_verify|ssl_trusted_certificate)[[:space:]]' "${vhost}" ||
        return 0

    tmp="$(mktemp "${vhost}.XXXXXX")" || return 1
    sed -E \
        -e '/^[[:space:]]*# OCSP stapling — serve a cached OCSP response so clients skip the CA$/d' \
        -e '/^[[:space:]]*# round-trip\. Needs the issuer chain \+ a resolver \(defined in nginx\.conf\)\.$/d' \
        -e '/^[[:space:]]*ssl_stapling[[:space:]]/d' \
        -e '/^[[:space:]]*ssl_stapling_verify[[:space:]]/d' \
        -e '/^[[:space:]]*ssl_trusted_certificate[[:space:]]/d' \
        "${vhost}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
    # Collapse the blank line the removed block leaves behind (max one blank).
    cat -s "${tmp}" > "${tmp}.s" && mv -f "${tmp}.s" "${tmp}"
    chmod --reference="${vhost}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    mv -f "${tmp}" "${vhost}" || { rm -f "${tmp}"; return 1; }
    printf 'changed\n'
}

# ---------------------------------------------------------------------------
# migrate_vhost_ocsp_stapling [sites_available]
#   Catch-up migration: strips OCSP stapling from every managed vhost. Each
#   changed file is backed up to <file>.pre-migration. When nginx is installed
#   the result is validated with `nginx -t`; on failure every changed vhost is
#   restored from its backup and the function returns 1. nginx is reloaded only
#   when at least one vhost changed and the config test passed.
# ---------------------------------------------------------------------------
migrate_vhost_ocsp_stapling() {
    local sites_available="${1:-${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}}"
    local vhost result
    local -a changed=()

    [[ -d "${sites_available}" ]] || return 0

    for vhost in "${sites_available}"/*.conf; do
        [[ -f "${vhost}" ]] || continue
        grep -qE '^[[:space:]]*(ssl_stapling|ssl_stapling_verify|ssl_trusted_certificate)[[:space:]]' "${vhost}" ||
            continue
        cp -a "${vhost}" "${vhost}.pre-migration" || return 1
        result="$(strip_vhost_ocsp_stapling "${vhost}")" || {
            mv -f "${vhost}.pre-migration" "${vhost}"
            return 1
        }
        if [[ "${result}" == "changed" ]]; then
            changed+=("${vhost}")
        else
            rm -f "${vhost}.pre-migration"
        fi
    done

    [[ ${#changed[@]} -gt 0 ]] || return 0

    if command -v nginx >/dev/null 2>&1; then
        if ! nginx -t >/dev/null 2>&1; then
            log_error "nginx config test failed after removing OCSP stapling; restoring vhosts"
            for vhost in "${changed[@]}"; do
                mv -f "${vhost}.pre-migration" "${vhost}" || true
            done
            return 1
        fi
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
            systemctl reload nginx || return 1
        fi
    fi

    for vhost in "${changed[@]}"; do
        log_info "Removed OCSP stapling from ${vhost} (backup: ${vhost}.pre-migration)"
    done
}
