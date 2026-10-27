#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${PROJECT_ROOT}/server/config/templates/php/php-fpm-pool.conf"
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
source "${PROJECT_ROOT}/lib/templates.sh"

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

render_pool() {
    render_template "${TEMPLATE}" "${TEST_TMP}/pool.conf" \
        "POOL_NAME=example_com" \
        "FPM_SOCKET=/var/run/php/php8.4-example.com-fpm.sock" \
        "PHP_VERSION=8.4" \
        "PM_MAX_CHILDREN=10" \
        "PM_START_SERVERS=2" \
        "PM_MIN_SPARE=2" \
        "PM_MAX_SPARE=5"
}

test_template_uses_ini_comments() {
    # PHP-FPM pool files are INI: only ';' starts a comment. A '#' line makes
    # php-fpm refuse to start, which takes down every pool on the server when
    # add-site restarts the service.
    if grep -nE '^[[:space:]]*#' "${TEMPLATE}" >&2; then
        fail "Pool template must use ';' for comments, not '#'"
        return 1
    fi
}

test_rendered_pool_parses_as_ini() {
    if ! command -v php >/dev/null 2>&1; then
        printf '    php not installed, skipping INI parse check\n' >&2
        return 0
    fi
    render_pool || { fail "Template did not render"; return 1; }
    # shellcheck disable=SC2016 # PHP code, \$argv must not expand
    php -r 'exit(@parse_ini_file($argv[1], true, INI_SCANNER_RAW) === false ? 1 : 0);' "${TEST_TMP}/pool.conf" ||
        { fail "Rendered pool is not valid INI"; return 1; }
}

run_test "pool template uses INI comments" test_template_uses_ini_comments
run_test "rendered pool parses as INI" test_rendered_pool_parses_as_ini

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
    printf '%d of %d test(s) failed\n' "${TESTS_FAILED}" "${TESTS_RUN}" >&2
    exit 1
fi

printf 'All %d PHP-FPM pool template tests passed\n' "${TESTS_RUN}"
