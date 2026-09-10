#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${PROJECT_ROOT}/server/config/templates/logrotate/forge-lite"
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
source "${PROJECT_ROOT}/lib/logrotate.sh"

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

test_template_does_not_rotate_laravel_daily_logs() {
    if grep -qE '^/home/deployer/sites/\*/shared/storage/logs/\*\.log' "${TEMPLATE}"; then
        fail "Template still matches every *.log (would rotate laravel-*.log)"
        return 1
    fi
    if grep -q 'laravel' "${TEMPLATE}" && grep -qE '^/.*laravel' "${TEMPLATE}"; then
        fail "Template must not list laravel-*.log as a rotation target"
        return 1
    fi
}

test_template_covers_every_supervisor_and_scheduler_log() {
    local log
    for log in worker reverb horizon ssr scheduler; do
        grep -qF "/home/deployer/sites/*/shared/storage/logs/${log}.log" "${TEMPLATE}" ||
            { fail "Template misses ${log}.log"; return 1; }
    done
}

test_template_rotates_as_deployer() {
    # storage/logs is deployer:deployer 0775; without `su` logrotate skips every
    # file with "parent directory has insecure permissions".
    grep -qE '^[[:space:]]+su deployer deployer$' "${TEMPLATE}" ||
        { fail "Template must rotate as deployer (su deployer deployer)"; return 1; }
}

test_template_leaves_nginx_logs_to_nginx_package() {
    # Comments may explain the nginx package's own entry; only directives count.
    if grep -v '^[[:space:]]*#' "${TEMPLATE}" | grep -q '/var/log/nginx'; then
        fail "Template duplicates /etc/logrotate.d/nginx (logrotate fails on duplicate entries)"
        return 1
    fi
}

test_template_passes_logrotate_syntax_check() {
    command -v logrotate >/dev/null 2>&1 || return 0
    logrotate -d "${TEMPLATE}" >/dev/null 2>&1 ||
        { fail "logrotate -d rejected the template"; return 1; }
}

test_ensure_installs_missing_target_once() {
    local target="${TEST_TMP}/install/forge-lite"
    mkdir -p "${TEST_TMP}/install"

    ensure_logrotate_config "${TEMPLATE}" "${target}" 2>/dev/null || return 1
    cmp -s "${TEMPLATE}" "${target}" || { fail "Target differs from template"; return 1; }
    [[ ! -e "${target}.pre-migration" ]] || { fail "Fresh install must not create a backup"; return 1; }

    local before after
    before="$(stat -f '%m' "${target}" 2>/dev/null || stat -c '%Y' "${target}")"
    sleep 1
    ensure_logrotate_config "${TEMPLATE}" "${target}" 2>/dev/null || return 1
    after="$(stat -f '%m' "${target}" 2>/dev/null || stat -c '%Y' "${target}")"
    [[ "${before}" == "${after}" ]] || { fail "Second run rewrote an identical target"; return 1; }
}

test_ensure_replaces_legacy_target_and_keeps_backup() {
    local target="${TEST_TMP}/legacy/forge-lite"
    mkdir -p "${TEST_TMP}/legacy"
    cat > "${target}" <<'LEGACY'
/home/deployer/sites/*/shared/storage/logs/*.log {
    daily
}
/var/log/nginx/*-access.log {
    daily
}
LEGACY

    ensure_logrotate_config "${TEMPLATE}" "${target}" 2>/dev/null || return 1
    cmp -s "${TEMPLATE}" "${target}" || { fail "Legacy target was not replaced"; return 1; }
    [[ -f "${target}.pre-migration" ]] || { fail "Backup of legacy target missing"; return 1; }
    grep -q '/var/log/nginx' "${target}.pre-migration" ||
        { fail "Backup does not hold the legacy content"; return 1; }
}

test_ensure_fails_on_missing_template() {
    local target="${TEST_TMP}/missing/forge-lite"
    mkdir -p "${TEST_TMP}/missing"
    if ensure_logrotate_config "${TEST_TMP}/does-not-exist" "${target}" 2>/dev/null; then
        fail "Missing template must fail"
        return 1
    fi
    [[ ! -e "${target}" ]] || { fail "Nothing may be written when the template is missing"; return 1; }
}

test_provision_and_update_share_the_helper() {
    grep -q 'ensure_logrotate_config' "${PROJECT_ROOT}/server/provision.sh" ||
        { fail "provision.sh must install logrotate via ensure_logrotate_config"; return 1; }
    grep -q 'ensure_logrotate_config' "${PROJECT_ROOT}/cli/forge-lite" ||
        { fail "forge-lite update catch-up must call ensure_logrotate_config"; return 1; }
    if grep -q 'cp .*logrotate/forge-lite' "${PROJECT_ROOT}/server/provision.sh"; then
        fail "provision.sh still copies the logrotate template by hand"
        return 1
    fi
}

run_test "template does not rotate laravel daily logs" test_template_does_not_rotate_laravel_daily_logs
run_test "template covers every supervisor and scheduler log" test_template_covers_every_supervisor_and_scheduler_log
run_test "template rotates as deployer" test_template_rotates_as_deployer
run_test "template leaves nginx logs to the nginx package" test_template_leaves_nginx_logs_to_nginx_package
run_test "template passes logrotate syntax check" test_template_passes_logrotate_syntax_check
run_test "ensure installs a missing target exactly once" test_ensure_installs_missing_target_once
run_test "ensure replaces a legacy target and keeps a backup" test_ensure_replaces_legacy_target_and_keeps_backup
run_test "ensure fails on a missing template" test_ensure_fails_on_missing_template
run_test "provision and update share the helper" test_provision_and_update_share_the_helper

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
    printf '%d of %d test(s) failed\n' "${TESTS_FAILED}" "${TESTS_RUN}" >&2
    exit 1
fi

printf 'All %d logrotate template tests passed\n' "${TESTS_RUN}"
