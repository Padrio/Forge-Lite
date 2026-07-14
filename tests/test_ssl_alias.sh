#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAB=$'\t'

TESTS_RUN=0
TESTS_FAILED=0
declare -a TEST_FILTERS=("$@")

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

# Test root is resolved at runtime.
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/validation.sh"
# Test root is resolved at runtime.
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/sites.sh"
# Test root is resolved at runtime.
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/cli/forge-lite-ssl"
# Test root is resolved at runtime.
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/cli/forge-lite"

fail() {
    printf '    %s\n' "$*" >&2
    return 1
}

assert_equals() {
    local expected="$1" actual="$2"
    [[ "$actual" == "$expected" ]] || {
        fail "Expected '${expected}', got '${actual}'"
        return 1
    }
}

assert_contains() {
    local haystack="$1" needle="$2"
    [[ "$haystack" == *"$needle"* ]] || {
        fail "Expected output to contain '${needle}', got: ${haystack}"
        return 1
    }
}

assert_not_contains() {
    local haystack="$1" needle="$2"
    [[ "$haystack" != *"$needle"* ]] || {
        fail "Expected output not to contain '${needle}', got: ${haystack}"
        return 1
    }
}

assert_file_contains() {
    local file="$1" needle="$2" content=""
    [[ -f "$file" ]] && content="$(command cat "$file")"
    assert_contains "$content" "$needle"
}

assert_file_empty() {
    local file="$1"
    if [[ -s "$file" ]]; then
        fail "Expected '${file}' to be empty, got: $(command cat "$file")"
        return 1
    fi
}

should_run() {
    local group="$1" name="$2" filter
    [[ ${#TEST_FILTERS[@]} -eq 0 ]] && return 0
    for filter in "${TEST_FILTERS[@]}"; do
        [[ "$group" == "$filter" || "$name" == *"$filter"* ]] && return 0
    done
    return 1
}

run_test() {
    local group="$1" name="$2" function_name="$3"
    should_run "$group" "$name" || return 0
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$function_name"; then
        printf 'ok %d - %s\n' "$TESTS_RUN" "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'not ok %d - %s\n' "$TESTS_RUN" "$name"
    fi
}

new_site_sandbox() {
    TEST_TMP="$(mktemp -d)"
    SITE_CONFIG_DIR="${TEST_TMP}/sites"
    mkdir -p "$SITE_CONFIG_DIR"
}

remove_site_sandbox() {
    rm -rf "$TEST_TMP"
}

write_site() {
    local domain="$1" aliases="${2:-}" ssl="${3:-false}"
    {
        printf 'DOMAIN=%s\n' "$domain"
        printf 'SITE_DIR=%s/site\n' "$TEST_TMP"
        printf 'PHP_VERSION=8.3\n'
        printf 'FPM_SOCKET=%s/php-fpm.sock\n' "$TEST_TMP"
        printf 'SSL=%s\n' "$ssl"
        printf 'ALIASES=%s\n' "$aliases"
    } > "${SITE_CONFIG_DIR}/${domain}.conf"
}

new_dns_sandbox() {
    TEST_TMP="$(mktemp -d)"
    DNS_FIXTURE_DIR="${TEST_TMP}/dns"
    mkdir -p "$DNS_FIXTURE_DIR"
}

dns_fixture() {
    local domain="$1" record_type="$2" content="$3"
    printf '%s\n' "$content" > "${DNS_FIXTURE_DIR}/${domain}.${record_type}"
}

dig() {
    local domain="${2:-}" record_type="${3:-}" fixture
    fixture="${DNS_FIXTURE_DIR:-/nonexistent}/${domain}.${record_type}"
    [[ -f "$fixture" ]] && command cat "$fixture"
    return 0
}

sed() {
    if [[ "${1:-}" == "-i" ]]; then
        shift
        if command sed --version >/dev/null 2>&1; then
            command sed -i "$@"
        else
            command sed -i '' "$@"
        fi
    else
        command sed "$@"
    fi
}

get_server_ipv4() {
    printf '%s' "${SERVER_IPV4:-}"
}

get_server_ipv6() {
    printf '%s' "${SERVER_IPV6:-}"
}

certbot() {
    local argument
    for argument in "$@"; do
        printf '<%s>\n' "$argument" >> "$CERTBOT_LOG"
    done
    [[ -n "${CERTBOT_OUTPUT:-}" ]] && printf '%s\n' "$CERTBOT_OUTPUT"
    [[ "${CERTBOT_FAIL:-false}" != true ]]
}

openssl() {
    local argument previous="" checked_host=""
    for argument in "$@"; do
        if [[ "$previous" == "-checkhost" ]]; then
            checked_host="$argument"
        fi
        previous="$argument"
    done
    printf '<checkhost=%s>\n' "$checked_host" >> "$OPENSSL_LOG"
    [[ -z "${OPENSSL_MISSING_HOST:-}" || "$checked_host" != "$OPENSSL_MISSING_HOST" ]]
}

nginx() {
    printf '<%s>\n' "$*" >> "$NGINX_LOG"
    [[ "${NGINX_TEST_FAIL:-false}" != true ]]
}

systemctl() {
    printf '<%s>\n' "$*" >> "$SYSTEMCTL_LOG"
    [[ "${SYSTEMCTL_FAIL:-false}" != true ]]
}

forge-lite-ssl() {
    local subcommand="${1:-}" primary_domain="${2:-}" aliases server_names
    printf '<%s>\n<%s>\n' "$subcommand" "$primary_domain" >> "$ALIAS_SSL_LOG"
    aliases="$(_site_config_value "${SITE_CONFIG_DIR}/${primary_domain}.conf" ALIASES)"
    if [[ "$aliases" != *"${ALIAS_UNDER_TEST}"* ]]; then
        printf '<desired-alias-missing>\n' >> "$ALIAS_SSL_LOG"
        return 1
    fi
    if grep -qF "$ALIAS_UNDER_TEST" "${NGINX_SITES_AVAILABLE}/${primary_domain}.conf"; then
        printf '<alias-exposed-before-certificate>\n' >> "$ALIAS_SSL_LOG"
        return 1
    fi
    [[ "${ALIAS_SSL_FAIL:-false}" != true ]] || return 1

    server_names="$(_build_server_names "$primary_domain" "$aliases")"
    sed -i "s|server_name .*$|server_name ${server_names};|" \
        "${NGINX_SITES_AVAILABLE}/${primary_domain}.conf"
}

test_direct_site_resolution() {
    new_site_sandbox
    write_site example.com www.example.com

    local resolved
    resolved="$(resolve_site example.com)" || {
        remove_site_sandbox
        return 1
    }
    assert_equals "example.com${TAB}${SITE_CONFIG_DIR}/example.com.conf" "$resolved" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_unique_alias_resolution() {
    new_site_sandbox
    write_site example.com www.example.com

    local resolved
    resolved="$(resolve_site www.example.com)" || {
        remove_site_sandbox
        return 1
    }
    assert_equals "example.com${TAB}${SITE_CONFIG_DIR}/example.com.conf" "$resolved" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_unknown_site_resolution_fails() {
    new_site_sandbox
    write_site example.com www.example.com

    local output
    if output="$(resolve_site unknown.example 2>&1)"; then
        remove_site_sandbox
        fail "Unknown site unexpectedly resolved"
        return 1
    fi
    assert_contains "$output" "Site 'unknown.example' not found" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_duplicate_alias_resolution_fails() {
    new_site_sandbox
    write_site example.com shared.example.com
    write_site example.net shared.example.com

    local output
    if output="$(resolve_site shared.example.com 2>&1)"; then
        remove_site_sandbox
        fail "Duplicate alias unexpectedly resolved"
        return 1
    fi
    assert_contains "$output" "multiple sites" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_ssl_cli_can_be_sourced_without_dispatch() {
    local output
    output="$(bash -c 'file="$1"; set -- sentinel; source "$file"; type resolve_site >/dev/null; printf source-ok' _ "${PROJECT_ROOT}/cli/forge-lite-ssl" 2>&1)" || return 1
    assert_equals "source-ok" "$output"
}

test_main_cli_can_be_sourced_without_dispatch() {
    local output
    output="$(bash -c 'file="$1"; set -- sentinel; source "$file"; type resolve_site >/dev/null; printf source-ok' _ "${PROJECT_ROOT}/cli/forge-lite" 2>&1)" || return 1
    assert_equals "source-ok" "$output"
}

test_installed_ssl_cli_fallback_resolves_alias() {
    new_site_sandbox
    write_site example.com www.example.com
    mkdir -p "${TEST_TMP}/bin"
    cp "${PROJECT_ROOT}/cli/forge-lite-ssl" "${TEST_TMP}/bin/forge-lite-ssl"

    local output
    output="$(bash -c 'export SITE_CONFIG_DIR="$1"; source "$2"; resolve_site www.example.com' _ \
        "$SITE_CONFIG_DIR" "${TEST_TMP}/bin/forge-lite-ssl" 2>&1)" || {
        remove_site_sandbox
        return 1
    }
    assert_equals "example.com${TAB}${SITE_CONFIG_DIR}/example.com.conf" "$output" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_installed_main_cli_fallback_resolves_alias() {
    new_site_sandbox
    write_site example.com www.example.com
    mkdir -p "${TEST_TMP}/bin"
    cp "${PROJECT_ROOT}/cli/forge-lite" "${TEST_TMP}/bin/forge-lite"

    local output
    output="$(bash -c 'export SITE_CONFIG_DIR="$1"; source "$2"; resolve_site www.example.com' _ \
        "$SITE_CONFIG_DIR" "${TEST_TMP}/bin/forge-lite" 2>&1)" || {
        remove_site_sandbox
        return 1
    }
    assert_equals "example.com${TAB}${SITE_CONFIG_DIR}/example.com.conf" "$output" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_direct_ipv4_matches_server() {
    new_dns_sandbox
    dns_fixture example.com A "5.75.157.10"

    local output
    output="$(_check_dns_records example.com 5.75.157.10 "" 2>&1)" || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$output" "[WARN]" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_cname_ipv4_matches_server() {
    new_dns_sandbox
    dns_fixture www.example.com A $'example.com.\n5.75.157.10'

    local output
    output="$(_check_dns_records www.example.com 5.75.157.10 "" 2>&1)" || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$output" "[WARN]" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_cname_ipv6_matches_server() {
    new_dns_sandbox
    dns_fixture www.example.com A $'example.com.\n5.75.157.10'
    dns_fixture www.example.com AAAA $'example.com.\n2a01:4f8:1c1c:29b8::1'

    local output
    output="$(_check_dns_records www.example.com 5.75.157.10 2a01:4f8:1c1c:29b8::1 2>&1)" || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$output" "[WARN]" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_multiple_addresses_accept_any_match() {
    new_dns_sandbox
    dns_fixture example.com A $'192.0.2.1\n5.75.157.10'
    dns_fixture example.com AAAA $'2001:db8::1\n2a01:4f8:1c1c:29b8::1'

    local output
    output="$(_check_dns_records example.com 5.75.157.10 2a01:4f8:1c1c:29b8::1 2>&1)" || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$output" "[WARN]" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_mismatch_lists_only_final_addresses() {
    new_dns_sandbox
    dns_fixture www.example.com A $'example.com.\n192.0.2.1\n192.0.2.2'

    local output
    output="$(_check_dns_records www.example.com 5.75.157.10 "" 2>&1)" || {
        remove_site_sandbox
        return 1
    }
    assert_contains "$output" "points to 192.0.2.1, 192.0.2.2" || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$output" "points to example.com." || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_cname_without_final_address_is_missing() {
    new_dns_sandbox
    dns_fixture www.example.com A "example.com."

    local output
    output="$(_check_dns_records www.example.com 5.75.157.10 "" 2>&1)" || {
        remove_site_sandbox
        return 1
    }
    assert_contains "$output" "No A record found for 'www.example.com'" || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$output" "points to example.com." || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

new_issue_sandbox() {
    new_site_sandbox
    DNS_FIXTURE_DIR="${TEST_TMP}/dns"
    LE_LIVE_DIR="${TEST_TMP}/letsencrypt/live"
    NGINX_SITES_AVAILABLE="${TEST_TMP}/nginx/sites-available"
    FORGE_LITE_TEMPLATES="${PROJECT_ROOT}/server/config/templates"
    CERTBOT_LOG="${TEST_TMP}/certbot.log"
    OPENSSL_LOG="${TEST_TMP}/openssl.log"
    NGINX_LOG="${TEST_TMP}/nginx.log"
    SYSTEMCTL_LOG="${TEST_TMP}/systemctl.log"
    SERVER_IPV4="5.75.157.10"
    SERVER_IPV6=""
    CERTBOT_OUTPUT=""
    CERTBOT_FAIL=false
    OPENSSL_MISSING_HOST=""
    NGINX_TEST_FAIL=false
    SYSTEMCTL_FAIL=false
    mkdir -p "$DNS_FIXTURE_DIR" "$LE_LIVE_DIR" "$NGINX_SITES_AVAILABLE"
    : > "$CERTBOT_LOG"
    : > "$OPENSSL_LOG"
    : > "$NGINX_LOG"
    : > "$SYSTEMCTL_LOG"
}

prepare_issue_site() {
    local aliases="${1:-www.example.com}" ssl="${2:-false}" name cert_dir
    write_site example.com "$aliases" "$ssl"
    for name in example.com ${aliases//,/ }; do
        dns_fixture "$name" A "$SERVER_IPV4"
    done
    cert_dir="${LE_LIVE_DIR}/example.com"
    mkdir -p "$cert_dir"
    touch "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem" "$cert_dir/chain.pem"
    printf 'old-vhost-for-example.com\n' > "${NGINX_SITES_AVAILABLE}/example.com.conf"
}

run_issue() {
    local requested_domain="$1" output
    if ! output="$(cmd_issue "$requested_domain" 2>&1)"; then
        fail "cmd_issue failed unexpectedly: ${output}"
        return 1
    fi
    ISSUE_OUTPUT="$output"
}

test_issue_alias_uses_primary_lineage_and_all_names() {
    new_issue_sandbox
    prepare_issue_site "www.example.com,app.example.com"

    run_issue www.example.com || {
        remove_site_sandbox
        return 1
    }
    assert_contains "$ISSUE_OUTPUT" "www.example.com is an alias of example.com" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "$CERTBOT_LOG" $'<--cert-name>\n<example.com>' || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "$CERTBOT_LOG" $'<-d>\n<example.com>' || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "$CERTBOT_LOG" $'<-d>\n<www.example.com>' || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "$CERTBOT_LOG" $'<-d>\n<app.example.com>' || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "${NGINX_SITES_AVAILABLE}/example.com.conf" "/etc/letsencrypt/live/example.com/fullchain.pem" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "${NGINX_SITES_AVAILABLE}/example.com.conf" "server_name example.com www.example.com app.example.com;" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "$SYSTEMCTL_LOG" "<reload nginx>" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "${SITE_CONFIG_DIR}/example.com.conf" "SSL=true" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_unknown_issue_domain_stops_before_certbot() {
    new_issue_sandbox
    prepare_issue_site

    local output
    if output="$(cmd_issue unknown.example 2>&1)"; then
        remove_site_sandbox
        fail "Unknown domain unexpectedly reached SSL success"
        return 1
    fi
    assert_contains "$output" "Site 'unknown.example' not found" || {
        remove_site_sandbox
        return 1
    }
    assert_file_empty "$CERTBOT_LOG" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_unchanged_certificate_is_ready_not_issued() {
    new_issue_sandbox
    prepare_issue_site
    CERTBOT_OUTPUT="Certificate not yet due for renewal; no action taken."

    run_issue example.com || {
        remove_site_sandbox
        return 1
    }
    assert_contains "$ISSUE_OUTPUT" "SSL certificate ready for example.com" || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$ISSUE_OUTPUT" "certificate issued" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_missing_san_prevents_vhost_change_and_reload() {
    new_issue_sandbox
    prepare_issue_site
    OPENSSL_MISSING_HOST="www.example.com"

    local output
    if output="$(cmd_issue example.com 2>&1)"; then
        remove_site_sandbox
        fail "Certificate missing an alias SAN unexpectedly succeeded"
        return 1
    fi
    assert_contains "$output" "does not cover" || {
        remove_site_sandbox
        return 1
    }
    assert_equals "old-vhost-for-example.com" "$(command cat "${NGINX_SITES_AVAILABLE}/example.com.conf")" || {
        remove_site_sandbox
        return 1
    }
    assert_file_empty "$SYSTEMCTL_LOG" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "${SITE_CONFIG_DIR}/example.com.conf" "SSL=false" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_nginx_validation_failure_restores_vhost_without_reload() {
    new_issue_sandbox
    prepare_issue_site
    NGINX_TEST_FAIL=true

    local output
    if output="$(cmd_issue example.com 2>&1)"; then
        remove_site_sandbox
        fail "Invalid NGINX candidate unexpectedly succeeded"
        return 1
    fi
    assert_contains "$output" "NGINX config test failed" || {
        remove_site_sandbox
        return 1
    }
    assert_equals "old-vhost-for-example.com" "$(command cat "${NGINX_SITES_AVAILABLE}/example.com.conf")" || {
        remove_site_sandbox
        return 1
    }
    assert_file_empty "$SYSTEMCTL_LOG" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

new_alias_sandbox() {
    new_issue_sandbox
    ALIAS_SSL_LOG="${TEST_TMP}/alias-ssl.log"
    ALIAS_UNDER_TEST="www.example.com"
    ALIAS_SSL_FAIL=false
    : > "$ALIAS_SSL_LOG"
}

prepare_alias_site() {
    local aliases="${1:-}" ssl="${2:-true}"
    write_site example.com "$aliases" "$ssl"
    printf 'server_name example.com%s;\n' "${aliases:+ ${aliases//,/ }}" \
        > "${NGINX_SITES_AVAILABLE}/example.com.conf"
}

run_alias() {
    local output
    if ! output="$(cmd_site_alias "$@" 2>&1)"; then
        fail "cmd_site_alias failed unexpectedly: ${output}"
        return 1
    fi
    ALIAS_OUTPUT="$output"
}

test_ssl_alias_add_expands_certificate_before_vhost() {
    new_alias_sandbox
    prepare_alias_site old.example.com true

    run_alias example.com --add=www.example.com || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "$ALIAS_SSL_LOG" $'<issue>\n<example.com>' || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$(command cat "$ALIAS_SSL_LOG")" "alias-exposed-before-certificate" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "${SITE_CONFIG_DIR}/example.com.conf" "ALIASES=old.example.com,www.example.com" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "${NGINX_SITES_AVAILABLE}/example.com.conf" "server_name example.com old.example.com www.example.com;" || {
        remove_site_sandbox
        return 1
    }
    assert_file_empty "$SYSTEMCTL_LOG" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_ssl_alias_failure_rolls_back_without_success() {
    new_alias_sandbox
    prepare_alias_site old.example.com true
    ALIAS_SSL_FAIL=true

    local output
    if output="$(cmd_site_alias example.com --add=www.example.com 2>&1)"; then
        remove_site_sandbox
        fail "Failed certificate expansion unexpectedly reported success"
        return 1
    fi
    assert_file_contains "$ALIAS_SSL_LOG" $'<issue>\n<example.com>' || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "${SITE_CONFIG_DIR}/example.com.conf" "ALIASES=old.example.com" || {
        remove_site_sandbox
        return 1
    }
    assert_equals "server_name example.com old.example.com;" "$(command cat "${NGINX_SITES_AVAILABLE}/example.com.conf")" || {
        remove_site_sandbox
        return 1
    }
    assert_not_contains "$output" "added for example.com" || {
        remove_site_sandbox
        return 1
    }
    assert_file_empty "$SYSTEMCTL_LOG" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_alias_command_accepts_known_alias_for_primary_site() {
    new_alias_sandbox
    prepare_alias_site old.example.com true
    ALIAS_UNDER_TEST="www.example.com"

    run_alias old.example.com --add=www.example.com || {
        remove_site_sandbox
        return 1
    }
    assert_contains "$ALIAS_OUTPUT" "old.example.com is an alias of example.com" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "$ALIAS_SSL_LOG" $'<issue>\n<example.com>' || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

test_http_alias_nginx_failure_restores_config_and_vhost() {
    new_alias_sandbox
    prepare_alias_site old.example.com false
    NGINX_TEST_FAIL=true

    local output
    if output="$(cmd_site_alias example.com --add=www.example.com 2>&1)"; then
        remove_site_sandbox
        fail "Invalid HTTP vhost unexpectedly reported alias success"
        return 1
    fi
    assert_contains "$output" "NGINX config test failed" || {
        remove_site_sandbox
        return 1
    }
    assert_file_contains "${SITE_CONFIG_DIR}/example.com.conf" "ALIASES=old.example.com" || {
        remove_site_sandbox
        return 1
    }
    assert_equals "server_name example.com old.example.com;" "$(command cat "${NGINX_SITES_AVAILABLE}/example.com.conf")" || {
        remove_site_sandbox
        return 1
    }
    assert_file_empty "$SYSTEMCTL_LOG" || {
        remove_site_sandbox
        return 1
    }
    remove_site_sandbox
}

run_test site_resolution "direct primary site is resolved" test_direct_site_resolution
run_test site_resolution "unique alias resolves to primary site" test_unique_alias_resolution
run_test site_resolution "unknown domain fails site resolution" test_unknown_site_resolution_fails
run_test site_resolution "duplicate alias fails site resolution" test_duplicate_alias_resolution_fails
run_test source_safety "forge-lite-ssl can be sourced without dispatch" test_ssl_cli_can_be_sourced_without_dispatch
run_test source_safety "forge-lite can be sourced without dispatch" test_main_cli_can_be_sourced_without_dispatch
run_test source_safety "installed forge-lite-ssl fallback resolves an alias" test_installed_ssl_cli_fallback_resolves_alias
run_test source_safety "installed forge-lite fallback resolves an alias" test_installed_main_cli_fallback_resolves_alias
run_test dns "direct A record matches server IPv4" test_direct_ipv4_matches_server
run_test dns "CNAME resolves to matching IPv4" test_cname_ipv4_matches_server
run_test dns "CNAME resolves to matching IPv6" test_cname_ipv6_matches_server
run_test dns "multiple addresses accept any matching IP" test_multiple_addresses_accept_any_match
run_test dns "mismatch lists only final addresses" test_mismatch_lists_only_final_addresses
run_test dns "CNAME without a final address is reported missing" test_cname_without_final_address_is_missing
run_test ssl_issue "alias issue uses primary lineage and every configured name" test_issue_alias_uses_primary_lineage_and_all_names
run_test ssl_issue "unknown issue domain stops before Certbot" test_unknown_issue_domain_stops_before_certbot
run_test ssl_issue "unchanged certificate is ready rather than issued" test_unchanged_certificate_is_ready_not_issued
run_test ssl_issue "missing SAN prevents vhost change and reload" test_missing_san_prevents_vhost_change_and_reload
run_test ssl_issue "NGINX validation failure restores vhost without reload" test_nginx_validation_failure_restores_vhost_without_reload
run_test alias_transaction "SSL alias expands certificate before vhost activation" test_ssl_alias_add_expands_certificate_before_vhost
run_test alias_transaction "SSL alias failure rolls config back without success" test_ssl_alias_failure_rolls_back_without_success
run_test alias_transaction "alias command accepts a known alias for its primary site" test_alias_command_accepts_known_alias_for_primary_site
run_test alias_transaction "HTTP alias NGINX failure restores config and vhost" test_http_alias_nginx_failure_restores_config_and_vhost

printf '1..%d\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
    printf '%d test(s) failed\n' "$TESTS_FAILED" >&2
    exit 1
fi
