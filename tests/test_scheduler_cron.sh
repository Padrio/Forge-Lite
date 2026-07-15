#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULER_LIB="${PROJECT_ROOT}/lib/scheduler.sh"
SCHEDULER_TEMPLATE="${PROJECT_ROOT}/server/config/templates/cron/laravel-scheduler"
TEST_TMP="$(mktemp -d)"
SITE_CONFIG_DIR="${TEST_TMP}/sites"
FORGE_LITE_CRON_DIR="${TEST_TMP}/cron.d"
FORGE_LITE_LOCK_DIR="${TEST_TMP}/locks"
FORGE_LITE_CRONTAB_SPOOL_DIR="${TEST_TMP}/crontabs"

TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
    rm -rf "${TEST_TMP}"
}

trap cleanup EXIT

# Sourced validation helpers invoke this function indirectly.
# shellcheck disable=SC2329
die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

# Test root is resolved at runtime.
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/validation.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/templates.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/sites.sh"
if [[ -f "${SCHEDULER_LIB}" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${SCHEDULER_LIB}"
fi
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/cli/forge-lite"

if ! command -v flock >/dev/null 2>&1; then
    # macOS test fallback; production Ubuntu supplies flock via util-linux.
    # shellcheck disable=SC2329
    flock() { return 0; }
    export -f flock
fi

mkdir -p \
    "${SITE_CONFIG_DIR}" \
    "${FORGE_LITE_CRON_DIR}" \
    "${FORGE_LITE_LOCK_DIR}" \
    "${FORGE_LITE_CRONTAB_SPOOL_DIR}"

fail() {
    printf '    %s\n' "$*" >&2
    return 1
}

assert_equals() {
    local expected="$1" actual="$2"
    [[ "${actual}" == "${expected}" ]] || {
        fail "Expected '${expected}', got '${actual}'"
        return 1
    }
}

assert_file_contains() {
    local file="$1" needle="$2"
    [[ -f "${file}" ]] || {
        fail "Expected file to exist: ${file}"
        return 1
    }
    grep -Fq -- "${needle}" "${file}" || {
        fail "Expected ${file} to contain: ${needle}"
        return 1
    }
}

assert_file_missing() {
    local file="$1"
    [[ ! -e "${file}" ]] || {
        fail "Expected file to be absent: ${file}"
        return 1
    }
}

require_scheduler_api() {
    local function_name
    local -a functions=(
        get_scheduler_cron_path
        get_legacy_scheduler_cron_path
        ensure_scheduler_cron
        remove_scheduler_cron
        migrate_scheduler_crons
        get_site_lock_path
        acquire_site_lock
    )

    for function_name in "${functions[@]}"; do
        declare -F "${function_name}" >/dev/null || {
            fail "Missing scheduler helper: ${function_name}"
            return 1
        }
    done
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

reset_sandbox() {
    rm -rf \
        "${SITE_CONFIG_DIR}" \
        "${FORGE_LITE_CRON_DIR}" \
        "${FORGE_LITE_LOCK_DIR}" \
        "${FORGE_LITE_CRONTAB_SPOOL_DIR}"
    mkdir -p \
        "${SITE_CONFIG_DIR}" \
        "${FORGE_LITE_CRON_DIR}" \
        "${FORGE_LITE_LOCK_DIR}" \
        "${FORGE_LITE_CRONTAB_SPOOL_DIR}"
}

write_site_config() {
    local domain="$1" enable_scheduler="${2:-true}"

    {
        printf 'DOMAIN=%s\n' "${domain}"
        printf 'ENABLE_SCHEDULER=%s\n' "${enable_scheduler}"
    } > "${SITE_CONFIG_DIR}/${domain}.conf"
}

test_domain_with_dots_gets_cron_compatible_path() {
    require_scheduler_api || return 1

    local domain="feuerwehr-coburg.de" cron_path basename domain_hash
    domain_hash="$(printf '%s' "${domain}" | sha256sum)"
    domain_hash="${domain_hash%% *}"
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    basename="${cron_path##*/}"

    assert_equals \
        "${FORGE_LITE_CRON_DIR}/feuerwehr_coburg_de-${domain_hash}-scheduler" \
        "${cron_path}" || return 1
    [[ "${basename}" =~ ^[a-zA-Z0-9_-]+$ ]] ||
        fail "Cron filename is not Debian-compatible: ${basename}"
}

test_subdomain_gets_deterministic_cron_compatible_path() {
    require_scheduler_api || return 1

    local first second
    first="$(get_scheduler_cron_path "app.eu.example.com" "${FORGE_LITE_CRON_DIR}")"
    second="$(get_scheduler_cron_path "app.eu.example.com" "${FORGE_LITE_CRON_DIR}")"

    assert_equals "${first}" "${second}"
}

test_colliding_identifiers_get_distinct_scheduler_paths() {
    require_scheduler_api || return 1
    reset_sandbox

    local first_domain="a-b.example.com" second_domain="a.b.example.com"
    local first_path second_path
    first_path="$(get_scheduler_cron_path "${first_domain}" "${FORGE_LITE_CRON_DIR}")"
    second_path="$(get_scheduler_cron_path "${second_domain}" "${FORGE_LITE_CRON_DIR}")"

    [[ "${first_path}" != "${second_path}" ]] || {
        fail "Distinct domains collide at scheduler path: ${first_path}"
        return 1
    }

    ensure_scheduler_cron \
        "${first_domain}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1
    ensure_scheduler_cron \
        "${second_domain}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1

    assert_file_contains "${first_path}" "/sites/${first_domain}/current" || return 1
    assert_file_contains "${second_path}" "/sites/${second_domain}/current"
}

test_case_variant_domains_get_distinct_scheduler_paths() {
    require_scheduler_api || return 1

    local uppercase_path lowercase_path
    uppercase_path="$(get_scheduler_cron_path \
        "Example.com" "${FORGE_LITE_CRON_DIR}")"
    lowercase_path="$(get_scheduler_cron_path \
        "example.com" "${FORGE_LITE_CRON_DIR}")"

    [[ "${uppercase_path}" != "${lowercase_path}" ]] ||
        fail "Case-variant site paths collide: ${uppercase_path}"
}

test_maximum_length_domain_stays_within_cron_name_limit() {
    require_scheduler_api || return 1
    reset_sandbox

    local label_63 label_61 domain cron_path cron_filename before after
    printf -v label_63 '%063d' 0
    printf -v label_61 '%061d' 0
    label_63="${label_63//0/a}"
    label_61="${label_61//0/a}"
    domain="${label_63}.${label_63}.${label_63}.${label_61}"
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    cron_filename="${cron_path##*/}"

    assert_equals "253" "${#domain}" || return 1
    [[ ${#cron_filename} -le 248 ]] || {
        fail "Cron filename leaves no room for atomic temp suffix: ${#cron_filename} chars"
        return 1
    }
    [[ "${cron_filename}" =~ ^[a-zA-Z0-9_-]+$ ]] || {
        fail "Maximum-length cron filename is not compatible: ${cron_filename}"
        return 1
    }

    ensure_scheduler_cron \
        "${domain}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1
    before="$(cksum "${cron_path}")"
    ensure_scheduler_cron \
        "${domain}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1
    after="$(cksum "${cron_path}")"
    assert_equals "${before}" "${after}" || return 1
    remove_scheduler_cron "${domain}" "${FORGE_LITE_CRON_DIR}" || return 1
    assert_file_missing "${cron_path}"
}

test_scheduler_rerun_cleans_site_specific_orphan_candidates() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path cron_filename
    local orphan_candidate orphan_render_tmp
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    cron_filename="${cron_path##*/}"
    orphan_candidate="${FORGE_LITE_CRON_DIR}/.${cron_filename}.candidate.deadbeef"
    orphan_render_tmp="${orphan_candidate}.deadbeef"
    printf 'orphan candidate\n' > "${orphan_candidate}"
    printf 'orphan render tempfile\n' > "${orphan_render_tmp}"

    ensure_scheduler_cron \
        "${domain}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1

    assert_file_missing "${orphan_candidate}" || return 1
    assert_file_missing "${orphan_render_tmp}" || return 1
    assert_file_contains "${cron_path}" "/sites/${domain}/current" || return 1

    printf 'later orphan candidate\n' > "${orphan_candidate}"
    remove_scheduler_cron "${domain}" "${FORGE_LITE_CRON_DIR}" || return 1
    assert_file_missing "${orphan_candidate}" || return 1
    assert_file_missing "${cron_path}"
}

test_scheduler_creation_uses_compatible_name_and_correct_content() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path mode
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"

    ensure_scheduler_cron \
        "${domain}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1

    assert_file_contains "${cron_path}" \
        "* * * * * deployer cd /home/deployer/sites/${domain}/current && php artisan schedule:run >> /home/deployer/sites/${domain}/shared/storage/logs/scheduler.log 2>&1" || return 1
    assert_file_missing "${legacy_path}" || return 1

    if mode="$(stat -f '%Lp' "${cron_path}" 2>/dev/null)"; then
        :
    else
        mode="$(stat -c '%a' "${cron_path}")"
    fi
    assert_equals "644" "${mode}"
}

test_scheduler_removal_cleans_new_and_legacy_paths() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'new\n' > "${cron_path}"
    printf 'legacy\n' > "${legacy_path}"

    remove_scheduler_cron "${domain}" "${FORGE_LITE_CRON_DIR}" || return 1

    assert_file_missing "${cron_path}" || return 1
    assert_file_missing "${legacy_path}"
}

test_legacy_scheduler_migration_renders_new_file_and_removes_old_file() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"

    migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1

    assert_file_contains "${cron_path}" \
        "/home/deployer/sites/${domain}/current && php artisan schedule:run" || return 1
    assert_file_missing "${legacy_path}"
}

test_failed_scheduler_migration_preserves_legacy_file() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"

    if migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${TEST_TMP}/missing-template" "${FORGE_LITE_CRON_DIR}" \
        >/dev/null 2>&1; then
        fail "Migration unexpectedly succeeded without its scheduler template"
        return 1
    fi

    assert_file_missing "${cron_path}" || return 1
    assert_file_contains "${legacy_path}" "ignored legacy scheduler"
}

test_render_failure_preserves_existing_scheduler_and_legacy_file() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path before after
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'known-good scheduler\n' > "${cron_path}"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"
    before="$(cksum "${cron_path}")"

    # render_template invokes this test double indirectly.
    # shellcheck disable=SC2329
    cat() {
        if [[ "${1:-}" == "${SCHEDULER_TEMPLATE}" ]]; then
            return 1
        fi
        command cat "$@"
    }
    if ensure_scheduler_cron \
        "${domain}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" \
        >/dev/null 2>&1; then
        unset -f cat
        fail "Scheduler render unexpectedly succeeded after template read failure"
        return 1
    fi
    unset -f cat

    after="$(cksum "${cron_path}")"
    assert_equals "${before}" "${after}" || return 1
    assert_file_contains "${legacy_path}" "ignored legacy scheduler"
}

test_scheduler_migration_repairs_drift_then_becomes_noop() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path mode
    local repaired_inode rerun_inode
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'wrong scheduler content\n' > "${cron_path}"
    chmod 600 "${cron_path}"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"

    migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1

    assert_file_contains "${cron_path}" \
        "/home/deployer/sites/${domain}/current && php artisan schedule:run" || return 1
    assert_file_missing "${legacy_path}" || return 1
    if mode="$(stat -f '%Lp' "${cron_path}" 2>/dev/null)"; then
        repaired_inode="$(stat -f '%i' "${cron_path}")"
    else
        mode="$(stat -c '%a' "${cron_path}")"
        repaired_inode="$(stat -c '%i' "${cron_path}")"
    fi
    assert_equals "644" "${mode}" || return 1

    migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1
    if rerun_inode="$(stat -f '%i' "${cron_path}" 2>/dev/null)"; then
        :
    else
        rerun_inode="$(stat -c '%i' "${cron_path}")"
    fi
    assert_equals "${repaired_inode}" "${rerun_inode}"
}

test_scheduler_migration_skips_global_backup_config() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path before after
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"
    printf 'BACKUP_S3_ENABLED=true\nBACKUP_S3_BUCKET=example\n' > \
        "${SITE_CONFIG_DIR}/backup.conf"
    before="$(cksum "${SITE_CONFIG_DIR}/backup.conf")"

    migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1
    after="$(cksum "${SITE_CONFIG_DIR}/backup.conf")"

    assert_equals "${before}" "${after}" || return 1
    assert_file_contains "${cron_path}" "/sites/${domain}/current" || return 1
    assert_file_missing "${legacy_path}"
}

test_scheduler_migration_preflights_all_sites_before_mutation() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="aaa.example.com" cron_path legacy_path
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"
    printf 'ENABLE_SCHEDULER=true\n' > "${SITE_CONFIG_DIR}/zzz.example.com.conf"

    if migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" \
        >/dev/null 2>&1; then
        fail "Migration unexpectedly accepted a site config without DOMAIN"
        return 1
    fi

    assert_file_missing "${cron_path}" || return 1
    assert_file_contains "${legacy_path}" "ignored legacy scheduler"
}

test_scheduler_migration_preflights_special_targets_before_mutation() {
    require_scheduler_api || return 1
    reset_sandbox

    local first_domain="aaa.example.com" second_domain="zzz.example.com"
    local first_path first_legacy second_path symlink_target
    write_site_config "${first_domain}" true
    write_site_config "${second_domain}" true
    first_path="$(get_scheduler_cron_path \
        "${first_domain}" "${FORGE_LITE_CRON_DIR}")"
    first_legacy="$(get_legacy_scheduler_cron_path \
        "${first_domain}" "${FORGE_LITE_CRON_DIR}")"
    second_path="$(get_scheduler_cron_path \
        "${second_domain}" "${FORGE_LITE_CRON_DIR}")"
    symlink_target="${TEST_TMP}/unexpected-target"
    printf 'ignored legacy scheduler\n' > "${first_legacy}"
    printf 'must remain unchanged\n' > "${symlink_target}"
    ln -s "${symlink_target}" "${second_path}"

    if migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" \
        >/dev/null 2>&1; then
        fail "Migration unexpectedly accepted a scheduler target symlink"
        return 1
    fi

    assert_file_missing "${first_path}" || return 1
    assert_file_contains "${first_legacy}" "ignored legacy scheduler" || return 1
    assert_file_contains "${symlink_target}" "must remain unchanged"
}

test_invalid_scheduler_flag_reports_configured_value_without_mutation() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path output
    write_site_config "${domain}" invalid
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"

    if output="$(migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" \
        2>&1)"; then
        fail "Migration unexpectedly accepted invalid ENABLE_SCHEDULER"
        return 1
    fi

    [[ "${output}" == *"Invalid ENABLE_SCHEDULER value"*"invalid"* ]] || {
        fail "Migration did not report the invalid configured value: ${output}"
        return 1
    }
    assert_file_missing "${cron_path}" || return 1
    assert_file_contains "${legacy_path}" "ignored legacy scheduler"
}

test_manual_deployer_scheduler_blocks_migration_without_mutation() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"

    # Scheduler helper invokes this test double indirectly.
    # shellcheck disable=SC2329
    crontab() {
        printf '* * * * * cd /home/deployer/sites/%s/current && php artisan schedule:run\n' \
            "${domain}"
    }

    if migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" \
        >/dev/null 2>&1; then
        unset -f crontab
        fail "Migration unexpectedly accepted a duplicate deployer crontab scheduler"
        return 1
    fi
    unset -f crontab

    assert_file_missing "${cron_path}" || return 1
    assert_file_contains "${legacy_path}" "ignored legacy scheduler"
}

test_manual_schedule_work_blocks_migration_without_mutation() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"

    # A long-running manual scheduler conflicts just like schedule:run.
    # shellcheck disable=SC2329
    crontab() {
        printf '@reboot cd /home/deployer/sites/%s/current && php artisan schedule:work\n' \
            "${domain}"
    }

    if migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" \
        >/dev/null 2>&1; then
        unset -f crontab
        fail "Migration unexpectedly accepted a manual schedule:work process"
        return 1
    fi
    unset -f crontab

    assert_file_missing "${cron_path}" || return 1
    assert_file_contains "${legacy_path}" "ignored legacy scheduler"
}

test_unreadable_deployer_crontab_blocks_migration_without_mutation() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"
    printf '* * * * * unreadable fixture\n' > \
        "${FORGE_LITE_CRONTAB_SPOOL_DIR}/deployer"

    # An unreadable active spool must not be treated as an empty crontab.
    # shellcheck disable=SC2329
    crontab() { return 2; }

    if migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" \
        >/dev/null 2>&1; then
        unset -f crontab
        fail "Migration unexpectedly ignored an unreadable deployer crontab"
        return 1
    fi
    unset -f crontab

    assert_file_missing "${cron_path}" || return 1
    assert_file_contains "${legacy_path}" "ignored legacy scheduler"
}

test_scheduler_migration_uses_domain_lifecycle_lock() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" lock_path
    write_site_config "${domain}" true
    lock_path="$(get_site_lock_path "${domain}" "${FORGE_LITE_LOCK_DIR}")"

    migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1

    [[ -f "${lock_path}" ]] || fail "Migration did not use site lock: ${lock_path}"
}

test_scheduler_migration_is_idempotent() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path before after
    local before_inode after_inode file_count
    write_site_config "${domain}" true
    printf 'ignored legacy scheduler\n' > \
        "$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"

    migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    before="$(cksum "${cron_path}")"
    if before_inode="$(stat -f '%i' "${cron_path}" 2>/dev/null)"; then
        :
    else
        before_inode="$(stat -c '%i' "${cron_path}")"
    fi

    migrate_scheduler_crons \
        "${SITE_CONFIG_DIR}" "${SCHEDULER_TEMPLATE}" "${FORGE_LITE_CRON_DIR}" || return 1
    after="$(cksum "${cron_path}")"
    if after_inode="$(stat -f '%i' "${cron_path}" 2>/dev/null)"; then
        :
    else
        after_inode="$(stat -c '%i' "${cron_path}")"
    fi
    file_count="$(find "${FORGE_LITE_CRON_DIR}" -maxdepth 1 -type f -name '*-scheduler' | wc -l | awk '{print $1}')"

    assert_equals "${before}" "${after}" || return 1
    assert_equals "${before_inode}" "${after_inode}" || return 1
    assert_equals "1" "${file_count}"
}

test_update_runs_scheduler_catch_up_migration() {
    require_scheduler_api || return 1
    reset_sandbox

    local domain="feuerwehr-coburg.de" cron_path legacy_path
    write_site_config "${domain}" true
    cron_path="$(get_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    legacy_path="$(get_legacy_scheduler_cron_path "${domain}" "${FORGE_LITE_CRON_DIR}")"
    printf 'ignored legacy scheduler\n' > "${legacy_path}"

    # The repository CLI subprocess invokes this exported test double.
    # shellcheck disable=SC2329
    install() { return 0; }
    export -f install
    if ! SITE_CONFIG_DIR="${SITE_CONFIG_DIR}" \
        FORGE_LITE_CRON_DIR="${FORGE_LITE_CRON_DIR}" \
        FORGE_LITE_LOCK_DIR="${FORGE_LITE_LOCK_DIR}" \
        FORGE_LITE_CRONTAB_SPOOL_DIR="${FORGE_LITE_CRONTAB_SPOOL_DIR}" \
        bash -c 'source "$1"; cmd_update' _ "${PROJECT_ROOT}/cli/forge-lite"; then
        export -n -f install
        unset -f install
        return 1
    fi
    export -n -f install
    unset -f install

    assert_file_contains "${cron_path}" \
        "/home/deployer/sites/${domain}/current && php artisan schedule:run" || return 1
    assert_file_missing "${legacy_path}"
}

test_readme_documents_upgrade_bootstrap_and_rollback_floor() {
    local readme="${PROJECT_ROOT}/README.md"
    # Backticks and the role name are intentional literal documentation text.
    # shellcheck disable=SC2016
    local rollback_text='Do not roll forge-lite back to a revision that lacks `lib/scheduler.sh`'
    # shellcheck disable=SC2016
    local crontab_text='remove the matching manual `deployer` crontab'
    local catch_up_text='entry before running the catch-up'
    local rollback_remove_text='verify that no digest-named managed cron remains'
    local rollback_manual_text='Only then add a temporary manual scheduler'

    assert_file_contains "${readme}" \
        'sudo /opt/forge-lite/cli/forge-lite update' || return 1
    assert_file_contains "${readme}" "${rollback_text}" || return 1
    assert_file_contains "${readme}" "${crontab_text}" || return 1
    assert_file_contains "${readme}" "${catch_up_text}" || return 1
    assert_file_contains "${readme}" "${rollback_remove_text}" || return 1
    assert_file_contains "${readme}" "${rollback_manual_text}" || return 1
}

test_site_lifecycle_scripts_use_shared_scheduler_helpers() {
    local add_site="${PROJECT_ROOT}/sites/add-site.sh"
    local remove_site="${PROJECT_ROOT}/sites/remove-site.sh"
    # The searched text intentionally contains the literal variable expansion.
    # shellcheck disable=SC2016
    local removal_call='remove_scheduler_cron "${DOMAIN}"'
    # shellcheck disable=SC2016
    local lock_call='acquire_site_lock "${DOMAIN}"'

    grep -Fq 'ensure_scheduler_cron ' "${add_site}" || {
        fail "add-site.sh does not create scheduler cron through the shared helper"
        return 1
    }
    [[ "$(grep -Fc "${removal_call}" "${add_site}")" -eq 1 ]] || {
        fail "add-site.sh failure cleanup does not use the shared removal helper exactly once"
        return 1
    }
    grep -Fq "${removal_call}" "${remove_site}" || {
        fail "remove-site.sh does not remove scheduler cron through the shared helper"
        return 1
    }
    grep -Fq "${lock_call}" "${add_site}" || {
        fail "add-site.sh does not hold the shared site lifecycle lock"
        return 1
    }
    grep -Fq "${lock_call}" "${remove_site}" || {
        fail "remove-site.sh does not hold the shared site lifecycle lock"
        return 1
    }
}

run_test \
    "domain with dots gets a cron-compatible filename" \
    test_domain_with_dots_gets_cron_compatible_path
run_test \
    "subdomain gets a deterministic cron-compatible filename" \
    test_subdomain_gets_deterministic_cron_compatible_path
run_test \
    "colliding identifiers get distinct scheduler paths" \
    test_colliding_identifiers_get_distinct_scheduler_paths
run_test \
    "case-variant domains get distinct scheduler paths" \
    test_case_variant_domains_get_distinct_scheduler_paths
run_test \
    "maximum-length domain stays within the cron filename limit" \
    test_maximum_length_domain_stays_within_cron_name_limit
run_test \
    "scheduler rerun cleans site-specific orphan candidates" \
    test_scheduler_rerun_cleans_site_specific_orphan_candidates
run_test \
    "scheduler creation uses compatible name and correct content" \
    test_scheduler_creation_uses_compatible_name_and_correct_content
run_test \
    "scheduler removal cleans new and legacy paths" \
    test_scheduler_removal_cleans_new_and_legacy_paths
run_test \
    "legacy scheduler migration renders new file and removes old file" \
    test_legacy_scheduler_migration_renders_new_file_and_removes_old_file
run_test \
    "failed scheduler migration preserves the legacy file" \
    test_failed_scheduler_migration_preserves_legacy_file
run_test \
    "render failure preserves existing scheduler and legacy file" \
    test_render_failure_preserves_existing_scheduler_and_legacy_file
run_test \
    "scheduler migration repairs drift then becomes a no-op" \
    test_scheduler_migration_repairs_drift_then_becomes_noop
run_test \
    "scheduler migration skips global backup config" \
    test_scheduler_migration_skips_global_backup_config
run_test \
    "scheduler migration preflights all sites before mutation" \
    test_scheduler_migration_preflights_all_sites_before_mutation
run_test \
    "scheduler migration preflights special targets before mutation" \
    test_scheduler_migration_preflights_special_targets_before_mutation
run_test \
    "invalid scheduler flag is reported before mutation" \
    test_invalid_scheduler_flag_reports_configured_value_without_mutation
run_test \
    "manual deployer scheduler blocks migration without mutation" \
    test_manual_deployer_scheduler_blocks_migration_without_mutation
run_test \
    "manual schedule:work blocks migration without mutation" \
    test_manual_schedule_work_blocks_migration_without_mutation
run_test \
    "unreadable deployer crontab blocks migration without mutation" \
    test_unreadable_deployer_crontab_blocks_migration_without_mutation
run_test \
    "scheduler migration uses the domain lifecycle lock" \
    test_scheduler_migration_uses_domain_lifecycle_lock
run_test \
    "scheduler migration is idempotent" \
    test_scheduler_migration_is_idempotent
run_test \
    "forge-lite update runs scheduler catch-up migration" \
    test_update_runs_scheduler_catch_up_migration
run_test \
    "README documents upgrade bootstrap and rollback floor" \
    test_readme_documents_upgrade_bootstrap_and_rollback_floor
run_test \
    "site lifecycle scripts use shared scheduler helpers" \
    test_site_lifecycle_scripts_use_shared_scheduler_helpers

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
    printf '%d of %d test(s) failed\n' "${TESTS_FAILED}" "${TESTS_RUN}" >&2
    exit 1
fi

printf 'All %d scheduler cron tests passed\n' "${TESTS_RUN}"
