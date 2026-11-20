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

# ---------------------------------------------------------------------------
# harden_vhost_scanner_handling <vhost_file>
#   Surgically upgrades a legacy forge-lite PHP vhost. Legitimate Laravel
#   routing is unchanged; only missing PHP scripts, hidden files and missing
#   static assets receive specialized handling. Prints "changed" on mutation.
# ---------------------------------------------------------------------------
harden_vhost_scanner_handling() {
    local vhost="$1" tmp

    [[ -f "${vhost}" ]] || return 0
    grep -qF 'location ~ \.php$ {' "${vhost}" || return 0
    grep -qF 'location @forge_lite_scanner {' "${vhost}" && return 0

    tmp="$(mktemp "${vhost}.XXXXXX")" || return 1
    awk '
        index($0, "error_page 404 /index.php;") { next }

        index($0, "location ~ \\.php$ {") {
            print
            print "        # Reject scanner probes before they reach PHP-FPM."
            print "        try_files $uri =404;"
            print "        error_page 404 = @forge_lite_scanner;"
            next
        }

        index($0, "location ~ /\\.(?!well-known).* {") {
            print "    location @forge_lite_scanner {"
            print "        access_log /var/log/nginx/forge-lite-security.log forge_lite_security;"
            print "        return 404;"
            print "    }"
            print ""
            print
            hidden = 1
            next
        }

        hidden && $0 ~ /^[[:space:]]*deny all;[[:space:]]*$/ {
            print "        error_page 404 = @forge_lite_scanner;"
            print "        return 404;"
            next
        }

        index($0, "location ~* \\.(js|css|") { static_assets = 1 }
        static_assets && $0 ~ /^[[:space:]]*access_log off;[[:space:]]*$/ {
            print
            print "        log_not_found off;"
            next
        }

        { print }
        (hidden || static_assets) && $0 ~ /^    }[[:space:]]*$/ {
            hidden = 0
            static_assets = 0
        }
    ' "${vhost}" > "${tmp}" || { rm -f "${tmp}"; return 1; }

    chmod --reference="${vhost}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    mv -f "${tmp}" "${vhost}" || { rm -f "${tmp}"; return 1; }
    printf 'changed\n'
}

# ---------------------------------------------------------------------------
# ensure_nginx_security_log_format <nginx_conf>
#   Adds the minimal scanner-only log format to an existing nginx.conf without
#   replacing host-specific tuning. Prints "changed" on mutation.
# ---------------------------------------------------------------------------
ensure_nginx_security_log_format() {
    local nginx_conf="${1:-/etc/nginx/nginx.conf}" tmp

    [[ -f "${nginx_conf}" ]] || return 0
    grep -qE '^[[:space:]]*log_format[[:space:]]+forge_lite_security[[:space:]]' "${nginx_conf}" && return 0

    tmp="$(mktemp "${nginx_conf}.XXXXXX")" || return 1
    awk '
        !inserted && /^[[:space:]]*access_log[[:space:]]/ {
            print "    log_format forge_lite_security '\''$remote_addr [$time_local] \"$request_method $uri\" $status'\'';"
            print ""
            inserted = 1
        }
        { print }
    ' "${nginx_conf}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
    grep -qE '^[[:space:]]*log_format[[:space:]]+forge_lite_security[[:space:]]' "${tmp}" || {
        rm -f "${tmp}"
        return 1
    }
    chmod --reference="${nginx_conf}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    mv -f "${tmp}" "${nginx_conf}" || { rm -f "${tmp}"; return 1; }
    printf 'changed\n'
}

# ---------------------------------------------------------------------------
# migrate_nginx_scanner_handling [sites_available] [nginx_conf]
#   Applies scanner handling to existing managed PHP vhosts, validates the
#   complete NGINX configuration, restores every changed file on failure, and
#   reloads only after a successful test. Persistent pre-change backups remain.
# ---------------------------------------------------------------------------
migrate_nginx_scanner_handling() {
    local sites_available="${1:-${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}}"
    local nginx_conf="${2:-/etc/nginx/nginx.conf}"
    local vhost result
    local -a changed=()

    [[ -d "${sites_available}" ]] || return 0

    if ! grep -qE '^[[:space:]]*log_format[[:space:]]+forge_lite_security[[:space:]]' "${nginx_conf}"; then
        cp -a "${nginx_conf}" "${nginx_conf}.pre-scanner-hardening" || return 1
        result="$(ensure_nginx_security_log_format "${nginx_conf}")" || {
            mv -f "${nginx_conf}.pre-scanner-hardening" "${nginx_conf}"
            return 1
        }
        [[ "${result}" != "changed" ]] || changed+=("${nginx_conf}")
    fi

    for vhost in "${sites_available}"/*.conf; do
        [[ -f "${vhost}" ]] || continue
        grep -qF 'location ~ \.php$ {' "${vhost}" || continue
        grep -qF 'location @forge_lite_scanner {' "${vhost}" && continue
        if ! cp -a "${vhost}" "${vhost}.pre-scanner-hardening"; then
            for result in "${changed[@]}"; do
                mv -f "${result}.pre-scanner-hardening" "${result}" || true
            done
            return 1
        fi
        if ! result="$(harden_vhost_scanner_handling "${vhost}")"; then
            mv -f "${vhost}.pre-scanner-hardening" "${vhost}" || true
            for result in "${changed[@]}"; do
                mv -f "${result}.pre-scanner-hardening" "${result}" || true
            done
            return 1
        fi
        [[ "${result}" != "changed" ]] || changed+=("${vhost}")
    done

    [[ ${#changed[@]} -gt 0 ]] || return 0

    if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
        log_error "nginx validation failed after scanner hardening; restoring changed files"
        for vhost in "${changed[@]}"; do
            mv -f "${vhost}.pre-scanner-hardening" "${vhost}" || true
        done
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
        if ! systemctl reload nginx; then
            log_error "nginx reload failed; restoring changed files"
            for vhost in "${changed[@]}"; do
                mv -f "${vhost}.pre-scanner-hardening" "${vhost}" || true
            done
            nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
            return 1
        fi
    fi
    for vhost in "${changed[@]}"; do
        log_info "Hardened scanner handling in ${vhost} (backup: ${vhost}.pre-scanner-hardening)"
    done
}

# migrate_nginx_catch_all [template] [target] [nginx_conf]
# Syncs the managed catch-all server from its template (security log for the
# nginx-catchall jail, TLS default that rejects unknown SNI).
migrate_nginx_catch_all() {
    local template="${1:-${FORGE_LITE_DIR}/server/config/templates/nginx/catch-all.conf}"
    local target="${2:-${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}/catch-all.conf}"
    local nginx_conf="${3:-/etc/nginx/nginx.conf}"
    local backup="${target}.pre-catchall-hardening"

    [[ -f "${template}" && -f "${target}" ]] || return 0
    cmp -s "${template}" "${target}" && return 0
    if ! grep -qE '^[[:space:]]*log_format[[:space:]]+forge_lite_security[[:space:]]' "${nginx_conf}"; then
        log_error "forge_lite_security log format missing in ${nginx_conf}; catch-all not migrated"
        return 1
    fi

    cp -a "${target}" "${backup}" || return 1
    install -m 644 "${template}" "${target}" || { mv -f "${backup}" "${target}"; return 1; }

    if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
        log_error "nginx validation failed after catch-all migration; restoring ${target}"
        mv -f "${backup}" "${target}" || true
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
        if ! systemctl reload nginx; then
            log_error "nginx reload failed; restoring ${target}"
            mv -f "${backup}" "${target}" || true
            nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
            return 1
        fi
    fi
    log_info "Synchronized catch-all server (backup: ${backup})"
}
