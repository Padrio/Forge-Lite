#!/usr/bin/env bash
# forge-lite/lib/sites.sh — Site-config resolution helpers
#
# Sourced by CLIs that need to map a domain → site config keys. Designed to
# grow as sibling CLIs (forge-lite-env, forge-lite-ssl, forge-lite-auth)
# migrate off their inlined duplicates. For now: one function.
set -euo pipefail

SITE_CONFIG_DIR="${SITE_CONFIG_DIR:-/etc/forge-lite}"

# ---------------------------------------------------------------------------
# resolve_site_db <domain>
#   Validates the domain, locates its site config, and prints DB_NAME on
#   stdout. Dies with a helpful message (including the list of available
#   sites) if the config or the DB_NAME key is missing.
# ---------------------------------------------------------------------------
resolve_site_db() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || die "Domain required."
    validate_domain "$domain"

    local conf="${SITE_CONFIG_DIR}/${domain}.conf"
    if [[ ! -f "$conf" ]]; then
        local f names=() available
        for f in "${SITE_CONFIG_DIR}"/*.conf; do
            [[ -f "$f" ]] || continue
            f="${f##*/}"
            names+=("${f%.conf}")
        done
        local IFS=,
        available="${names[*]:-}"
        die "Site '${domain}' not found. Available: ${available:-<none>}"
    fi

    local db_name
    db_name=$(
        # shellcheck disable=SC1090
        source "$conf"
        printf '%s' "${DB_NAME:-}"
    )
    [[ -n "$db_name" ]] || die "Site config '${conf}' lacks DB_NAME — old or manually edited."
    printf '%s' "$db_name"
}
