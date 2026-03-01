#!/usr/bin/env bash
# forge-lite/lib/validation.sh — Domain, PHP version, identifier sanitization
set -euo pipefail

# ---------------------------------------------------------------------------
# validate_domain <domain>
#   Validates that the string looks like a valid domain name.
# ---------------------------------------------------------------------------
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        die "Invalid domain name: ${domain}"
    fi
}

# ---------------------------------------------------------------------------
# validate_php_version <version>
#   Checks that the PHP version is one of the supported versions.
# ---------------------------------------------------------------------------
validate_php_version() {
    local version="$1"
    local supported=("8.1" "8.2" "8.3" "8.4")
    local v
    for v in "${supported[@]}"; do
        [[ "$version" == "$v" ]] && return 0
    done
    die "Unsupported PHP version: ${version}. Supported: ${supported[*]}"
}

# ---------------------------------------------------------------------------
# sanitize_for_identifier <string>
#   Converts a string (e.g. domain) to a safe identifier for database names,
#   unix usernames, etc.  example.com → example_com
# ---------------------------------------------------------------------------
sanitize_for_identifier() {
    local input="$1"
    echo "$input" | tr '.-' '_' | tr -cd 'a-zA-Z0-9_' | tr '[:upper:]' '[:lower:]'
}
