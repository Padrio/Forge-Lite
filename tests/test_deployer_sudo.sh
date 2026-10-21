#!/usr/bin/env bash
# The helper is called without its optional path arguments on purpose: the
# tests drive it through the same FORGE_LITE_* overrides production leaves unset.
# shellcheck disable=SC2119
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0

# Byte-exact /etc/sudoers.d/github-runner as rendered by github-runner.sh and
# deployed on web1. The deployer change must never alter it.
GITHUB_RUNNER_SUDOERS_SHA256="aaaf4dc2e6a366266421089c89d3a15ff1fd512fedbde4b6b01f68b394968a80"

cleanup() { rm -rf "${TEST_TMP}"; }
trap cleanup EXIT

# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/security.sh"

command -v visudo >/dev/null 2>&1 || {
    printf 'visudo is required to validate sudoers syntax\n' >&2
    exit 1
}

SUDOERS_DIR="${TEST_TMP}/sudoers.d"
BACKUP_DIR="${TEST_TMP}/backups"
GPASSWD_LOG="${TEST_TMP}/gpasswd.log"
GROUPS_STATE="${TEST_TMP}/deployer-groups"
SUDO_LISTING="${TEST_TMP}/sudo-listing"
export FORGE_LITE_SUDOERS_DIR="${SUDOERS_DIR}"
export FORGE_LITE_SUDOERS_FILE="${TEST_TMP}/sudoers"
export FORGE_LITE_BACKUP_DIR="${BACKUP_DIR}"
export FORGE_LITE_LOCK_DIR="${TEST_TMP}/lock"
unset SUDO_USER FORGE_LITE_ALLOW_SELF_REVOKE

REAL_FLOCK=true
if ! command -v flock >/dev/null 2>&1; then
    # macOS test fallback; production Ubuntu supplies flock via util-linux.
    REAL_FLOCK=false
    # shellcheck disable=SC2329
    flock() { return 0; }
    export -f flock
fi

# Stands in for `sudo -n -l -U deployer`; prints SUDO_LISTING when present.
# shellcheck disable=SC2329
sudo() {
    if [[ -f "${SUDO_LISTING}" ]]; then cat "${SUDO_LISTING}"; else
        printf 'User deployer is not allowed to run sudo on test.\n'; fi
}

# Test doubles for the group database; revoke_deployer_sudo calls them by name.
# shellcheck disable=SC2329
id() {
    [[ "${*: -1}" == "deployer" ]] || { command id "$@"; return; }
    [[ -f "${GROUPS_STATE}" ]] || return 1
    [[ "${1:-}" == "-nG" ]] && cat "${GROUPS_STATE}"
    return 0
}
# shellcheck disable=SC2329
gpasswd() {
    printf '%s\n' "$*" >> "${GPASSWD_LOG}"
    local user="$2" group="$3" groups
    [[ "$1" == "-d" && "${user}" == "deployer" ]] || return 1
    groups=" $(cat "${GROUPS_STATE}") "
    groups="${groups/ ${group} / }"
    groups="${groups# }"
    printf '%s\n' "${groups% }" > "${GROUPS_STATE}"
    # Simulates a concurrent removal: membership is gone, exit status says error.
    [[ ! -f "${TEST_TMP}/gpasswd-fails" ]] || return 3
}

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

skip_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf 'ok %d - %s # SKIP %s\n' "${TESTS_RUN}" "$1" "$2"
}

reset_sandbox() {
    rm -rf "${SUDOERS_DIR}" "${BACKUP_DIR}" "${GPASSWD_LOG}" "${GROUPS_STATE}" "${SUDO_LISTING}"
    mkdir -p "${SUDOERS_DIR}"
    printf 'root ALL=(ALL:ALL) ALL\n%%sudo ALL=(ALL:ALL) ALL\n@includedir %s\n' \
        "${SUDOERS_DIR}" > "${FORGE_LITE_SUDOERS_FILE}"
    : > "${GPASSWD_LOG}"
}

write_github_runner_rule() {
    sed -n "/<<'SUDOERS'$/,/^SUDOERS$/p" \
        "${PROJECT_ROOT}/server/modules/github-runner.sh" | sed '1d;$d' > "$1"
    chmod 440 "$1"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Lines that are neither blank nor comments, i.e. actual sudoers rules.
rule_lines() { grep -vE '^[[:space:]]*(#|$)' "$1" || true; }

test_provisioning_grants_no_sudo() {
    local system="${PROJECT_ROOT}/server/modules/system.sh" hits
    grep -qF 'revoke_deployer_sudo' "${system}" ||
        { fail "system.sh does not call revoke_deployer_sudo"; return 1; }
    ! grep -qE 'NOPASSWD|sudoers' "${system}" ||
        { fail "system.sh still writes sudoers itself"; return 1; }
    ! grep -qE 'usermod[^#]*(sudo|admin)' "${system}" ||
        { fail "system.sh still adds deployer to an admin group"; return 1; }

    # No provisioning path anywhere may grant deployer sudo.
    hits="$(grep -rnE '^[^#]*deployer[[:space:]]+ALL[[:space:]]*=' \
        "${PROJECT_ROOT}/server" "${PROJECT_ROOT}/sites" "${PROJECT_ROOT}/cli" \
        "${PROJECT_ROOT}/lib" "${PROJECT_ROOT}/deploy" "${PROJECT_ROOT}/cloud-init" \
        "${PROJECT_ROOT}/templates" 2>/dev/null || true)"
    [[ -z "${hits}" ]] || { fail "deployer sudo grant found: ${hits}"; return 1; }
}

test_fresh_install_writes_rule_free_placeholder() {
    reset_sandbox
    revoke_deployer_sudo >/dev/null 2>&1 || { fail "revoke_deployer_sudo failed"; return 1; }

    [[ -f "${SUDOERS_DIR}/deployer" ]] || { fail "placeholder missing"; return 1; }
    [[ -z "$(rule_lines "${SUDOERS_DIR}/deployer")" ]] ||
        { fail "placeholder contains sudoers rules"; return 1; }
    [[ ! -e "${BACKUP_DIR}/sudoers.d-deployer.pre-revoke" ]] ||
        { fail "backup created although no previous file existed"; return 1; }
    [[ ! -s "${GPASSWD_LOG}" ]] || { fail "gpasswd called for a non-member"; return 1; }
    [[ -z "$(find "${SUDOERS_DIR}" -name '.*' -type f)" ]] ||
        { fail "staging file left behind"; return 1; }
}

test_migration_replaces_blanket_rule_idempotently() {
    local before_rule="${TEST_TMP}/blanket" first backups
    reset_sandbox
    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
    chmod 440 "${SUDOERS_DIR}/deployer"
    cp -p "${SUDOERS_DIR}/deployer" "${before_rule}"
    printf 'deployer sudo www-data\n' > "${GROUPS_STATE}"

    revoke_deployer_sudo >/dev/null 2>&1 || { fail "first run failed"; return 1; }

    cmp -s "${before_rule}" "${BACKUP_DIR}/sudoers.d-deployer.pre-revoke" ||
        { fail "previous rule was not backed up verbatim"; return 1; }
    ! grep -q 'NOPASSWD' "${SUDOERS_DIR}/deployer" ||
        { fail "blanket rule still active"; return 1; }
    [[ -z "$(rule_lines "${SUDOERS_DIR}/deployer")" ]] ||
        { fail "replacement contains sudoers rules"; return 1; }
    grep -qx 'deployer sudo www-data' "${BACKUP_DIR}/deployer-groups.pre-revoke" ||
        { fail "previous group list was not recorded"; return 1; }
    grep -qx -- '-d deployer sudo' "${GPASSWD_LOG}" ||
        { fail "deployer was not removed from group sudo"; return 1; }
    [[ " $(cat "${GROUPS_STATE}") " != *" sudo "* ]] ||
        { fail "deployer still in group sudo"; return 1; }

    # Second run: nothing changes, nothing is logged, no new backups.
    first="$(cksum "${SUDOERS_DIR}/deployer" "${BACKUP_DIR}"/*)"
    : > "${GPASSWD_LOG}"
    revoke_deployer_sudo >/dev/null 2>&1 || { fail "second run failed"; return 1; }
    [[ "$(cksum "${SUDOERS_DIR}/deployer" "${BACKUP_DIR}"/*)" == "${first}" ]] ||
        { fail "second run changed the placeholder or backups"; return 1; }
    [[ ! -s "${GPASSWD_LOG}" ]] || { fail "second run called gpasswd"; return 1; }
    backups="$(find "${BACKUP_DIR}" -type f | wc -l | awk '{print $1}')"
    [[ "${backups}" == "2" ]] || { fail "expected 2 backup files, got ${backups}"; return 1; }
}

test_later_drift_keeps_first_backup() {
    reset_sandbox
    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
    revoke_deployer_sudo >/dev/null 2>&1 || return 1
    rm -f "${SUDOERS_DIR}/deployer"
    printf 'deployer ALL=(root) NOPASSWD: /usr/bin/true\n' > "${SUDOERS_DIR}/deployer"
    revoke_deployer_sudo >/dev/null 2>&1 || return 1

    grep -qx 'deployer ALL=(ALL) NOPASSWD:ALL' "${BACKUP_DIR}/sudoers.d-deployer.pre-revoke" ||
        { fail "first backup was overwritten"; return 1; }
    compgen -G "${BACKUP_DIR}/sudoers.d-deployer.pre-revoke.*" >/dev/null ||
        { fail "drifted rule was not backed up separately"; return 1; }
    [[ -z "$(rule_lines "${SUDOERS_DIR}/deployer")" ]]
}

test_invalid_existing_config_is_left_untouched() {
    reset_sandbox
    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
    # In the main file: non-root visudo on Ubuntu skips include dirs it does
    # not consider root-owned, which would hide a broken include file.
    printf 'this is not sudoers syntax\n' >> "${FORGE_LITE_SUDOERS_FILE}"
    cp -p "${SUDOERS_DIR}/deployer" "${TEST_TMP}/expected"

    if revoke_deployer_sudo >/dev/null 2>&1; then
        fail "succeeded although the sudoers tree was already invalid"; return 1
    fi
    cmp -s "${TEST_TMP}/expected" "${SUDOERS_DIR}/deployer" ||
        { fail "file changed despite invalid configuration"; return 1; }
    [[ ! -e "${BACKUP_DIR}" ]] || { fail "backup dir created before guard"; return 1; }
}

test_failed_final_check_restores_previous_rule() {
    local wrapper="${TEST_TMP}/visudo-fails-after-swap" rc=0
    reset_sandbox
    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
    cp -p "${SUDOERS_DIR}/deployer" "${TEST_TMP}/expected"
    # Real visudo, except the post-swap full check reports failure.
    cat > "${wrapper}" <<WRAPPER
#!/usr/bin/env bash
if [[ "\$*" == "-c -f ${FORGE_LITE_SUDOERS_FILE}" ]] && grep -q 'NO sudo rights' "${SUDOERS_DIR}/deployer"; then
    exit 1
fi
exec visudo "\$@"
WRAPPER
    chmod 755 "${wrapper}"

    FORGE_LITE_VISUDO="${wrapper}" revoke_deployer_sudo >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -ne 0 ]] || { fail "failure was not reported"; return 1; }
    cmp -s "${TEST_TMP}/expected" "${SUDOERS_DIR}/deployer" ||
        { fail "previous rule was not restored"; return 1; }
}

test_sudoers_syntax_is_valid() {
    local placeholder="${TEST_TMP}/placeholder" runner="${TEST_TMP}/github-runner"
    _deployer_sudoers_placeholder > "${placeholder}"
    write_github_runner_rule "${runner}"
    visudo -c -f "${placeholder}" >/dev/null || { fail "placeholder rejected"; return 1; }
    visudo -c -f "${runner}" >/dev/null || { fail "github-runner rule rejected"; return 1; }

    reset_sandbox
    write_github_runner_rule "${SUDOERS_DIR}/github-runner"
    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
    revoke_deployer_sudo >/dev/null 2>&1 || return 1
    local output
    output="$(visudo -c -f "${FORGE_LITE_SUDOERS_FILE}" 2>&1)" ||
        { fail "resulting sudoers tree rejected: ${output}"; return 1; }
    visudo -c -f "${SUDOERS_DIR}/deployer" >/dev/null ||
        { fail "migrated deployer file rejected"; return 1; }
}

test_github_runner_rule_is_unchanged() {
    local runner="${SUDOERS_DIR}/github-runner" before
    reset_sandbox
    write_github_runner_rule "${runner}"
    [[ "$(sha256_of "${runner}")" == "${GITHUB_RUNNER_SUDOERS_SHA256}" ]] ||
        { fail "github-runner.sh no longer renders the deployed rule"; return 1; }

    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
    before="$(ls -l "${runner}")"
    revoke_deployer_sudo >/dev/null 2>&1 || return 1
    revoke_deployer_sudo >/dev/null 2>&1 || return 1
    [[ "$(sha256_of "${runner}")" == "${GITHUB_RUNNER_SUDOERS_SHA256}" ]] ||
        { fail "migration modified the github-runner rule"; return 1; }
    [[ "$(ls -l "${runner}")" == "${before}" ]] ||
        { fail "migration changed github-runner metadata"; return 1; }
}

test_concurrent_runs_are_serialized() {
    local i pid_a pid_b rc_a rc_b
    for i in 1 2 3 4 5 6 7 8 9 10; do
        reset_sandbox
        printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
        printf 'deployer sudo www-data\n' > "${GROUPS_STATE}"
        revoke_deployer_sudo >/dev/null 2>&1 & pid_a=$!
        revoke_deployer_sudo >/dev/null 2>&1 & pid_b=$!
        rc_a=0 rc_b=0
        wait "${pid_a}" || rc_a=$?
        wait "${pid_b}" || rc_b=$?
        [[ "${rc_a}" -eq 0 && "${rc_b}" -eq 0 ]] ||
            { fail "round ${i}: exit ${rc_a}/${rc_b}"; return 1; }
        grep -qx 'deployer ALL=(ALL) NOPASSWD:ALL' "${BACKUP_DIR}/sudoers.d-deployer.pre-revoke" ||
            { fail "round ${i}: first backup lost"; return 1; }
        grep -qx 'deployer sudo www-data' "${BACKUP_DIR}/deployer-groups.pre-revoke" ||
            { fail "round ${i}: group backup lost"; return 1; }
        [[ -z "$(rule_lines "${SUDOERS_DIR}/deployer")" ]] ||
            { fail "round ${i}: rule still active"; return 1; }
    done
}

test_self_revoke_is_refused() {
    reset_sandbox
    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
    cp -p "${SUDOERS_DIR}/deployer" "${TEST_TMP}/expected"
    printf 'deployer sudo www-data\n' > "${GROUPS_STATE}"

    if SUDO_USER=deployer revoke_deployer_sudo >/dev/null 2>&1; then
        fail "revoked from inside deployer's own sudo session"; return 1
    fi
    cmp -s "${TEST_TMP}/expected" "${SUDOERS_DIR}/deployer" ||
        { fail "file changed despite refusal"; return 1; }
    [[ ! -s "${GPASSWD_LOG}" ]] || { fail "gpasswd called despite refusal"; return 1; }

    SUDO_USER=deployer FORGE_LITE_ALLOW_SELF_REVOKE=true revoke_deployer_sudo >/dev/null 2>&1 ||
        { fail "explicit override was not honoured"; return 1; }
    [[ -z "$(rule_lines "${SUDOERS_DIR}/deployer")" ]] || return 1
    grep -qx -- '-d deployer sudo' "${GPASSWD_LOG}"
}

test_interrupted_run_leftovers_are_repaired() {
    reset_sandbox
    _deployer_sudoers_placeholder > "${SUDOERS_DIR}/deployer"
    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/.deployer.forge-lite-new"
    mkdir -p "${BACKUP_DIR}"
    : > "${BACKUP_DIR}/deployer-groups.pre-revoke"
    printf 'deployer sudo www-data\n' > "${GROUPS_STATE}"

    revoke_deployer_sudo >/dev/null 2>&1 || { fail "recovery run failed"; return 1; }
    [[ ! -e "${SUDOERS_DIR}/.deployer.forge-lite-new" ]] ||
        { fail "stale candidate left behind"; return 1; }
    grep -qx 'deployer sudo www-data' "${BACKUP_DIR}/deployer-groups.pre-revoke" ||
        { fail "empty group backup was not re-recorded"; return 1; }
    grep -qx -- '-d deployer sudo' "${GPASSWD_LOG}"
}

test_already_removed_group_is_tolerated() {
    local rc=0
    reset_sandbox
    printf 'deployer sudo www-data\n' > "${GROUPS_STATE}"
    : > "${TEST_TMP}/gpasswd-fails"
    revoke_deployer_sudo >/dev/null 2>&1 || rc=$?
    rm -f "${TEST_TMP}/gpasswd-fails"
    [[ "${rc}" -eq 0 ]] || { fail "failed although membership is gone"; return 1; }
}

test_rules_elsewhere_are_reported() {
    local out
    reset_sandbox
    printf 'deployer www-data\n' > "${GROUPS_STATE}"
    printf 'User deployer may run the following commands on test:\n    (ALL) NOPASSWD: ALL\n' > "${SUDO_LISTING}"
    out="$(revoke_deployer_sudo 2>&1)" || { fail "revoke failed"; return 1; }
    [[ "${out}" == *"another sudoers source"* ]] || { fail "no warning: ${out}"; return 1; }

    rm -f "${SUDO_LISTING}"
    out="$(revoke_deployer_sudo 2>&1)" || return 1
    [[ -z "${out}" ]] || { fail "converged run is not silent: ${out}"; return 1; }
}

# Runs _run_catch_up_migrations with every other catch-up replaced by a stub
# that records its name in <calls>.
run_catch_up_with_stubs() {
    local calls="$1" drop_helper="${2:-false}"
    (
        # shellcheck disable=SC1091
        source "${PROJECT_ROOT}/cli/forge-lite"
        # shellcheck disable=SC2329
        migrate_scheduler_crons() { printf 'scheduler\n' >> "${calls}"; }
        # shellcheck disable=SC2329
        ensure_logrotate_config() { printf 'logrotate\n' >> "${calls}"; }
        # shellcheck disable=SC2329
        migrate_vhost_ocsp_stapling() { printf 'ocsp\n' >> "${calls}"; }
        # shellcheck disable=SC2329
        migrate_nginx_scanner_handling() { printf 'scanner\n' >> "${calls}"; }
        # shellcheck disable=SC2329
        ensure_fail2ban_scanner_config() { printf 'fail2ban\n' >> "${calls}"; }
        # shellcheck disable=SC2329
        repair_storage_permissions() { printf 'storage\n' >> "${calls}"; }
        [[ "${drop_helper}" != true ]] || unset -f revoke_deployer_sudo
        _run_catch_up_migrations
    )
}

test_update_reports_revocation_failure_after_other_repairs() {
    local calls="${TEST_TMP}/calls" rc=0
    reset_sandbox
    printf 'deployer ALL=(ALL) NOPASSWD:ALL\n' > "${SUDOERS_DIR}/deployer"
    printf 'this is not sudoers syntax\n' >> "${FORGE_LITE_SUDOERS_FILE}"
    : > "${calls}"

    run_catch_up_with_stubs "${calls}" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -ne 0 ]] || { fail "update reported success"; return 1; }
    [[ "$(tr '\n' ' ' < "${calls}")" == "scheduler logrotate ocsp scanner fail2ban storage " ]] ||
        { fail "later repairs skipped: $(tr '\n' ' ' < "${calls}")"; return 1; }
    grep -q 'NOPASSWD' "${SUDOERS_DIR}/deployer" ||
        { fail "sudoers changed despite invalid configuration"; return 1; }
}

test_update_warns_when_helper_missing() {
    local calls="${TEST_TMP}/calls" out
    reset_sandbox
    : > "${calls}"
    out="$(run_catch_up_with_stubs "${calls}" true 2>&1)" || { fail "update failed"; return 1; }
    [[ "${out}" == *"deployer sudo NOT revoked"* ]] || { fail "no warning: ${out}"; return 1; }
}

test_update_runs_revocation() {
    grep -qF 'revoke_deployer_sudo' "${PROJECT_ROOT}/cli/forge-lite"
}

run_test "provisioning grants deployer no sudo" test_provisioning_grants_no_sudo
run_test "fresh install writes a rule-free placeholder" test_fresh_install_writes_rule_free_placeholder
run_test "migration replaces a blanket rule idempotently" test_migration_replaces_blanket_rule_idempotently
run_test "later drift keeps the first backup" test_later_drift_keeps_first_backup
run_test "invalid existing sudoers config is left untouched" test_invalid_existing_config_is_left_untouched
run_test "failed final visudo check restores the previous rule" test_failed_final_check_restores_previous_rule
run_test "sudoers syntax is valid" test_sudoers_syntax_is_valid
run_test "github-runner rule is unchanged" test_github_runner_rule_is_unchanged
if [[ "${REAL_FLOCK}" == true ]]; then
    run_test "concurrent runs are serialized" test_concurrent_runs_are_serialized
else
    skip_test "concurrent runs are serialized" "flock unavailable"
fi
run_test "revoking from deployer's own sudo session is refused" test_self_revoke_is_refused
run_test "interrupted-run leftovers are repaired" test_interrupted_run_leftovers_are_repaired
run_test "already removed group membership is tolerated" test_already_removed_group_is_tolerated
run_test "sudo rules from other sources are reported" test_rules_elsewhere_are_reported
run_test "update reports a revocation failure after the other repairs" test_update_reports_revocation_failure_after_other_repairs
run_test "update warns when the helper is missing" test_update_warns_when_helper_missing
run_test "forge-lite update runs the revocation" test_update_runs_revocation

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
    printf '%d of %d test(s) failed\n' "${TESTS_FAILED}" "${TESTS_RUN}" >&2
    exit 1
fi
printf 'All %d deployer sudo tests passed\n' "${TESTS_RUN}"
