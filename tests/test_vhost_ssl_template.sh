#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${PROJECT_ROOT}/server/config/templates/nginx"
TEST_TMP="$(mktemp -d)"

TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
    rm -rf "${TEST_TMP}"
}

trap cleanup EXIT

# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/nginx.sh"

fail() {
    printf '    %s\n' "$*" >&2
    return 1
}

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

# Legacy vhost exactly as the pre-fix template rendered it (excerpt).
write_legacy_vhost() {
    cat > "$1" <<'VHOST'
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # OCSP stapling — serve a cached OCSP response so clients skip the CA
    # round-trip. Needs the issuer chain + a resolver (defined in nginx.conf).
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;

    # HSTS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root /home/deployer/sites/example.com/current/public;
}
VHOST
}

write_expected_vhost() {
    cat > "$1" <<'VHOST'
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # HSTS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root /home/deployer/sites/example.com/current/public;
}
VHOST
}

test_templates_do_not_configure_ocsp_stapling() {
    local file
    for file in vhost-ssl.conf vhost.conf nginx.conf; do
        if grep -v '^[[:space:]]*#' "${TEMPLATE_DIR}/${file}" |
            grep -qE 'ssl_stapling|ssl_trusted_certificate'; then
            fail "${file} still configures OCSP stapling"
            return 1
        fi
    done
}

test_ssl_template_keeps_certificate_and_hsts() {
    local file="${TEMPLATE_DIR}/vhost-ssl.conf"
    grep -q 'ssl_certificate /etc/letsencrypt/live/{{DOMAIN}}/fullchain.pem;' "${file}" || return 1
    grep -q 'ssl_certificate_key /etc/letsencrypt/live/{{DOMAIN}}/privkey.pem;' "${file}" || return 1
    grep -q 'Strict-Transport-Security' "${file}" || return 1
}

test_migration_strips_exactly_the_stapling_block() {
    local dir="${TEST_TMP}/strip" expected="${TEST_TMP}/expected.conf"
    mkdir -p "${dir}"
    write_legacy_vhost "${dir}/example.com.conf"
    write_expected_vhost "${expected}"

    migrate_vhost_ocsp_stapling "${dir}" 2>/dev/null || return 1

    cmp -s "${expected}" "${dir}/example.com.conf" ||
        { fail "Migrated vhost differs from expected"; diff "${expected}" "${dir}/example.com.conf" >&2 || true; return 1; }
    [[ -f "${dir}/example.com.conf.pre-migration" ]] || { fail "Backup missing"; return 1; }
    grep -q 'ssl_stapling on;' "${dir}/example.com.conf.pre-migration" ||
        { fail "Backup does not hold legacy content"; return 1; }
}

test_migration_is_idempotent() {
    local dir="${TEST_TMP}/idempotent"
    mkdir -p "${dir}"
    write_legacy_vhost "${dir}/example.com.conf"

    migrate_vhost_ocsp_stapling "${dir}" 2>/dev/null || return 1
    cp "${dir}/example.com.conf" "${TEST_TMP}/after-first.conf"
    rm -f "${dir}/example.com.conf.pre-migration"

    migrate_vhost_ocsp_stapling "${dir}" 2>/dev/null || return 1
    cmp -s "${TEST_TMP}/after-first.conf" "${dir}/example.com.conf" ||
        { fail "Second run changed the vhost"; return 1; }
    [[ ! -e "${dir}/example.com.conf.pre-migration" ]] ||
        { fail "Second run must not create a backup"; return 1; }
}

test_migration_leaves_clean_vhosts_untouched() {
    local dir="${TEST_TMP}/clean"
    mkdir -p "${dir}"
    write_expected_vhost "${dir}/clean.conf"
    printf 'server { listen 80; }\n' > "${dir}/http-only.conf"
    cp "${dir}/clean.conf" "${TEST_TMP}/clean-before.conf"

    migrate_vhost_ocsp_stapling "${dir}" 2>/dev/null || return 1

    cmp -s "${TEST_TMP}/clean-before.conf" "${dir}/clean.conf" || { fail "Clean vhost was modified"; return 1; }
    [[ ! -e "${dir}/clean.conf.pre-migration" ]] || { fail "Clean vhost must not get a backup"; return 1; }
    [[ ! -e "${dir}/http-only.conf.pre-migration" ]] || { fail "HTTP vhost must not get a backup"; return 1; }
}

test_migration_tolerates_missing_directory() {
    migrate_vhost_ocsp_stapling "${TEST_TMP}/does-not-exist" 2>/dev/null
}

test_update_runs_stapling_catch_up() {
    # The variable reference is intentional literal source text.
    # shellcheck disable=SC2016
    grep -q 'migrate_vhost_ocsp_stapling "${NGINX_SITES_AVAILABLE}"' "${PROJECT_ROOT}/cli/forge-lite" ||
        { fail "forge-lite update must call migrate_vhost_ocsp_stapling"; return 1; }
}

test_readme_no_longer_advertises_stapling() {
    if grep -q 'OCSP stapling, CSP' "${PROJECT_ROOT}/README.md"; then
        fail "README feature table still lists OCSP stapling"
        return 1
    fi
    grep -q 'ssl_stapling' "${PROJECT_ROOT}/README.md" ||
        { fail "README should document the stapling catch-up migration"; return 1; }
}

run_test "templates do not configure OCSP stapling" test_templates_do_not_configure_ocsp_stapling
run_test "ssl template keeps certificate and HSTS directives" test_ssl_template_keeps_certificate_and_hsts
run_test "migration strips exactly the stapling block" test_migration_strips_exactly_the_stapling_block
run_test "migration is idempotent" test_migration_is_idempotent
run_test "migration leaves clean vhosts untouched" test_migration_leaves_clean_vhosts_untouched
run_test "migration tolerates a missing sites-available directory" test_migration_tolerates_missing_directory
run_test "forge-lite update runs the stapling catch-up" test_update_runs_stapling_catch_up
run_test "README no longer advertises OCSP stapling" test_readme_no_longer_advertises_stapling

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
    printf '%d of %d test(s) failed\n' "${TESTS_FAILED}" "${TESTS_RUN}" >&2
    exit 1
fi

printf 'All %d vhost SSL template tests passed\n' "${TESTS_RUN}"
