#!/usr/bin/env bash
# forge-lite/lib/sites.sh — Site-config resolution helpers
#
# Sourced by CLIs that need to map a domain → site config keys. Designed to
# grow as sibling CLIs (forge-lite-env, forge-lite-ssl, forge-lite-auth)
# migrate off their inlined duplicates.
set -euo pipefail

SITE_CONFIG_DIR="${SITE_CONFIG_DIR:-/etc/forge-lite}"

# Read one KEY=VALUE entry without sourcing the complete site config.
_site_config_value() {
    local conf="$1" key="$2" line=""
    line="$(grep -m1 "^${key}=" "$conf" 2>/dev/null)" || true
    printf '%s' "${line#*=}"
}

# ---------------------------------------------------------------------------
# resolve_site <requested-domain>
#   Prints PRIMARY_DOMAIN<TAB>CONFIG_PATH. A direct config wins. Otherwise,
#   ALIASES entries are compared exactly across all configs. Missing and
#   multiply assigned aliases are fatal configuration errors.
# ---------------------------------------------------------------------------
resolve_site() {
    local requested_domain="${1:-}"
    [[ -n "$requested_domain" ]] || die "Domain required."
    validate_domain "$requested_domain"

    local direct_conf="${SITE_CONFIG_DIR}/${requested_domain}.conf"
    local primary_domain
    if [[ -f "$direct_conf" ]]; then
        primary_domain="$(_site_config_value "$direct_conf" DOMAIN)"
        printf '%s\t%s' "${primary_domain:-$requested_domain}" "$direct_conf"
        return 0
    fi

    local conf aliases alias available="" matches_display=""
    local -a alias_list=() match_configs=() match_domains=()
    for conf in "${SITE_CONFIG_DIR}"/*.conf; do
        [[ -f "$conf" ]] || continue
        primary_domain="$(_site_config_value "$conf" DOMAIN)"
        [[ -n "$primary_domain" ]] || primary_domain="${conf##*/}"
        primary_domain="${primary_domain%.conf}"
        available="${available:+${available}, }${primary_domain}"

        aliases="$(_site_config_value "$conf" ALIASES)"
        [[ -n "$aliases" ]] || continue
        IFS=',' read -r -a alias_list <<< "$aliases"
        for alias in "${alias_list[@]}"; do
            alias="${alias#"${alias%%[![:space:]]*}"}"
            alias="${alias%"${alias##*[![:space:]]}"}"
            if [[ "$alias" == "$requested_domain" ]]; then
                match_configs+=("$conf")
                match_domains+=("$primary_domain")
                matches_display="${matches_display:+${matches_display}, }${primary_domain}"
                break
            fi
        done
    done

    if [[ ${#match_configs[@]} -eq 0 ]]; then
        die "Site '${requested_domain}' not found. Available: ${available:-<none>}"
    fi
    if [[ ${#match_configs[@]} -gt 1 ]]; then
        die "Alias '${requested_domain}' is assigned to multiple sites: ${matches_display}. Fix ALIASES in ${SITE_CONFIG_DIR}."
    fi

    printf '%s\t%s' "${match_domains[0]}" "${match_configs[0]}"
}

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
