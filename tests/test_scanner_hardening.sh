#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() { rm -rf "${TEST_TMP}"; }
trap cleanup EXIT

# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/nginx.sh"

fail() { printf '    %s\n' "$*" >&2; return 1; }
run_test() {
    local name="$1" function_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if "${function_name}"; then
        printf 'ok %d - %s\n' "${TESTS_RUN}" "${name}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'not ok %d - %s\n' "${TESTS_RUN}" "${name}"
    fi
}

write_legacy_vhost() {
    cat > "$1" <<'VHOST'
server {
    access_log /var/log/nginx/example.com-access.log observability_json;
    error_log /var/log/nginx/example.com-error.log;
    location / { try_files $uri $uri/ /index.php?$query_string; }
    error_page 404 /index.php;
    location ~ \.php$ {
        fastcgi_pass unix:/run/php/example.sock;
    }
    location ~ /\.(?!well-known).* {
        deny all;
    }
    location ~* \.(js|css|png|jpg)$ {
        access_log off;
    }
}
VHOST
}

test_templates_have_quiet_scanner_handling() {
    local template
    for template in vhost.conf vhost-ssl.conf; do
        template="${PROJECT_ROOT}/server/config/templates/nginx/${template}"
        # Literal NGINX variable in the template.
        # shellcheck disable=SC2016
        grep -qF 'try_files $uri =404;' "${template}" || return 1
        grep -qF 'location @forge_lite_scanner {' "${template}" || return 1
        grep -qF 'log_not_found off;' "${template}" || return 1
        ! grep -qF 'error_page 404 /index.php;' "${template}" || return 1
    done
    grep -qF 'log_format forge_lite_security' \
        "${PROJECT_ROOT}/server/config/templates/nginx/nginx.conf"
}

test_legacy_vhost_migration_is_targeted_and_idempotent() {
    local vhost="${TEST_TMP}/legacy.conf"
    write_legacy_vhost "${vhost}"
    harden_vhost_scanner_handling "${vhost}" >/dev/null

    # Literal NGINX variable in the migrated file.
    # shellcheck disable=SC2016
    grep -qF 'try_files $uri =404;' "${vhost}" || return 1
    grep -qF 'error_page 404 = @forge_lite_scanner;' "${vhost}" || return 1
    grep -qF 'location @forge_lite_scanner {' "${vhost}" || return 1
    grep -qF 'log_not_found off;' "${vhost}" || return 1
    ! grep -qF 'deny all;' "${vhost}" || return 1
    ! grep -qF 'error_page 404 /index.php;' "${vhost}" || return 1
    grep -qF 'fastcgi_pass unix:/run/php/example.sock;' "${vhost}" || return 1

    cp "${vhost}" "${TEST_TMP}/first.conf"
    harden_vhost_scanner_handling "${vhost}" >/dev/null
    cmp -s "${TEST_TMP}/first.conf" "${vhost}" ||
        { fail "second migration changed the vhost"; return 1; }
}

test_log_format_migration_is_idempotent() {
    local config="${TEST_TMP}/nginx.conf"
    cat > "${config}" <<'NGINX'
http {
    log_format observability_json '{"status":$status}';
    access_log /var/log/nginx/access.log observability_json;
}
NGINX
    ensure_nginx_security_log_format "${config}" >/dev/null
    grep -qF 'log_format forge_lite_security' "${config}" || return 1
    cp "${config}" "${TEST_TMP}/nginx-first.conf"
    ensure_nginx_security_log_format "${config}" >/dev/null
    cmp -s "${TEST_TMP}/nginx-first.conf" "${config}"
}

test_fail2ban_templates_match_minimal_log() {
    local filter="${PROJECT_ROOT}/server/config/templates/fail2ban/nginx-scanner.conf"
    local jail="${PROJECT_ROOT}/server/config/templates/fail2ban/forge-lite.local"
    grep -qF 'logpath = /var/log/nginx/forge-lite-security.log' "${jail}" || return 1
    grep -qF '[nginx-botsearch]' "${jail}" || return 1
    grep -qF 'enabled = false' "${jail}" || return 1
    grep -qF '<HOST>' "${filter}"
}

test_update_runs_all_catch_up_helpers() {
    local cli="${PROJECT_ROOT}/cli/forge-lite"
    grep -qF 'migrate_nginx_scanner_handling' "${cli}" || return 1
    grep -qF 'ensure_fail2ban_scanner_config' "${cli}" || return 1
    grep -qF 'repair_storage_permissions' "${cli}"
}

run_test "templates use quiet scanner handling" test_templates_have_quiet_scanner_handling
run_test "legacy vhost migration is targeted and idempotent" test_legacy_vhost_migration_is_targeted_and_idempotent
run_test "security log format migration is idempotent" test_log_format_migration_is_idempotent
run_test "Fail2Ban consumes the minimal security log" test_fail2ban_templates_match_minimal_log
run_test "forge-lite update runs every catch-up helper" test_update_runs_all_catch_up_helpers

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
    printf '%d of %d test(s) failed\n' "${TESTS_FAILED}" "${TESTS_RUN}" >&2
    exit 1
fi
printf 'All %d scanner hardening tests passed\n' "${TESTS_RUN}"
