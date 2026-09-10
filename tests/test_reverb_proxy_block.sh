#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVERB_CLI="${PROJECT_ROOT}/cli/forge-lite-reverb"

TESTS_RUN=0
TESTS_FAILED=0

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

# Extract the regex nginx evaluates from the managed block. nginx uses PCRE;
# for this character-class/alternation pattern Bash ERE behaves identically.
proxy_location_regex() {
    sed -n "/^_reverb_proxy_block()/,/^BLOCK$/p" "${REVERB_CLI}" |
        sed -nE 's/^location ~ (\^[^ ]+) \{$/\1/p' |
        head -1
}

REGEX="$(proxy_location_regex)"

assert_matches() {
    local path="$1"
    [[ "${path}" =~ ${REGEX} ]] || { fail "Expected proxy match for ${path}"; return 1; }
}

assert_not_matches() {
    local path="$1"
    if [[ "${path}" =~ ${REGEX} ]]; then
        fail "Expected Laravel (no proxy) for ${path}"
        return 1
    fi
}

test_regex_is_extractable() {
    [[ -n "${REGEX}" ]] || { fail "Could not extract location regex from _reverb_proxy_block"; return 1; }
}

test_pusher_client_websocket_paths_are_proxied() {
    assert_matches "/app/f55cda4903f069f2c43c05939b88177e" &&
        assert_matches "/app/local-key_1"
}

test_pusher_server_api_paths_are_proxied() {
    assert_matches "/apps/c9d5fcc493ae05fe/events" &&
        assert_matches "/apps/123/channels" &&
        assert_matches "/apps/abc/channels/presence-room/users"
}

test_bot_probes_stay_with_laravel() {
    assert_not_matches "/app/settings.py" &&
        assert_not_matches "/app/.env" &&
        assert_not_matches "/app/config/database.php"
}

test_bare_and_unrelated_app_paths_stay_with_laravel() {
    assert_not_matches "/app" &&
        assert_not_matches "/app/" &&
        assert_not_matches "/apps" &&
        assert_not_matches "/apps/" &&
        assert_not_matches "/apps/123" &&
        assert_not_matches "/applications" &&
        assert_not_matches "/appointments/1" &&
        assert_not_matches "/approvals/app/x"
}

test_block_keeps_management_markers() {
    local block
    block="$(sed -n "/^_reverb_proxy_block()/,/^BLOCK$/p" "${REVERB_CLI}")"
    grep -qF '# BEGIN forge-lite reverb' <<< "${block}" || { fail "BEGIN marker missing"; return 1; }
    grep -qF '# END forge-lite reverb' <<< "${block}" || { fail "END marker missing"; return 1; }
    grep -qF 'proxy_pass http://127.0.0.1:8080;' <<< "${block}" || { fail "proxy_pass missing"; return 1; }
    # nginx variable is intentional literal text.
    # shellcheck disable=SC2016
    grep -qF 'proxy_set_header Upgrade $http_upgrade;' <<< "${block}" || { fail "Upgrade header missing"; return 1; }
}

run_test "location regex is extractable from the managed block" test_regex_is_extractable
run_test "Pusher client websocket paths are proxied" test_pusher_client_websocket_paths_are_proxied
run_test "Pusher server API paths are proxied" test_pusher_server_api_paths_are_proxied
run_test "bot probes under /app stay with Laravel" test_bot_probes_stay_with_laravel
run_test "bare and unrelated /app* paths stay with Laravel" test_bare_and_unrelated_app_paths_stay_with_laravel
run_test "block keeps management markers and websocket headers" test_block_keeps_management_markers

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
    printf '%d of %d test(s) failed\n' "${TESTS_FAILED}" "${TESTS_RUN}" >&2
    exit 1
fi

printf 'All %d reverb proxy block tests passed\n' "${TESTS_RUN}"
