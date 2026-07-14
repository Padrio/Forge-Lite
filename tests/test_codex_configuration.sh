#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEGACY_FAMILY="clau""de"
LEGACY_DIR=".${LEGACY_FAMILY}"
LEGACY_GUIDANCE="CLAU""DE.md"
TEST_TMP="$(mktemp -d)"

TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
    rm -rf "${TEST_TMP}"
}

trap cleanup EXIT

fail() {
    printf '    %s\n' "$*" >&2
    return 1
}

assert_equals() {
    local expected="$1" actual="$2"

    [[ "${actual}" == "${expected}" ]] ||
        fail "Expected '${expected}', got '${actual}'"
}

assert_file_contains() {
    local file="$1" needle="$2"

    grep -Fq -- "${needle}" "${file}" ||
        fail "Expected ${file#"${PROJECT_ROOT}/"} to contain: ${needle}"
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

test_narrow_legacy_ignore() {
    local ignore_path="/${LEGACY_DIR}/settings.local.json" count

    count="$(grep -Fxc -- "${ignore_path}" "${PROJECT_ROOT}/.gitignore" || true)"
    assert_equals "1" "${count}" || return 1

    if grep -Fxq -- "${LEGACY_DIR}/" "${PROJECT_ROOT}/.gitignore" ||
        grep -Fxq -- "/${LEGACY_DIR}/" "${PROJECT_ROOT}/.gitignore"; then
        fail "The broad legacy configuration directory must not be ignored"
        return 1
    fi
}

test_readme_onboarding() {
    local readme="${PROJECT_ROOT}/README.md"

    assert_file_contains "${readme}" "## Codex contributor setup" || return 1
    assert_file_contains "${readme}" \
        "Codex project configuration loads only after the repository is trusted." || return 1
    assert_file_contains "${readme}" \
        "Review and trust the project hooks with \`/hooks\`, and repeat this after hook changes." || return 1
    assert_file_contains "${readme}" \
        "Confirm the project-scoped Context7 server \`deployment-context7\` is available with \`/mcp\`." || return 1
    assert_file_contains "${readme}" \
        "Existing users should move the stale \`${LEGACY_DIR}\` directory outside the repository as a backup, then remove it after verifying the Codex setup." || return 1
    assert_file_contains "${readme}" \
        "Start a new Codex session after setup changes." || return 1
}

test_legacy_artifacts_and_guidance_size() {
    local tracked_legacy guidance_size

    if ! tracked_legacy="$(git -C "${PROJECT_ROOT}" ls-files -- \
        "${LEGACY_DIR}" "${LEGACY_DIR}/**")"; then
        fail "Could not inspect tracked legacy paths"
        return 1
    fi
    [[ -z "${tracked_legacy}" ]] || {
        fail "Legacy configuration remains tracked: ${tracked_legacy}"
        return 1
    }
    [[ ! -e "${PROJECT_ROOT}/${LEGACY_GUIDANCE}" ]] || {
        fail "Legacy root guidance still exists"
        return 1
    }
    if ! guidance_size="$(wc -c < "${PROJECT_ROOT}/AGENTS.md")"; then
        fail "Could not measure AGENTS.md"
        return 1
    fi
    [[ "${guidance_size}" -lt 32768 ]] || {
        fail "AGENTS.md is ${guidance_size} bytes; expected fewer than 32768"
        return 1
    }
}

test_native_codex_paths() {
    local path
    local -a required_paths=(
        "AGENTS.md"
        ".agents/skills/backward-compat-guardian/SKILL.md"
        ".agents/skills/backward-compat-guardian/agents/openai.yaml"
        ".agents/skills/backward-compat-guardian/references/vhost-includes-and-rerender.md"
        ".agents/skills/idempotency-auditor/SKILL.md"
        ".agents/skills/idempotency-auditor/agents/openai.yaml"
        ".agents/skills/idempotency-auditor/references/config-upsert-patterns.md"
        ".agents/skills/idempotency-auditor/references/confirmed-idempotent.md"
        ".agents/skills/idempotency-auditor/references/vhost-rerender-hazard.md"
        ".codex/agents/backward-compat-guardian.toml"
        ".codex/agents/idempotency-auditor.toml"
        ".codex/config.toml"
        ".codex/hooks.json"
        ".codex/hooks/pre-edit-credential-policy.sh"
        ".codex/hooks/post-edit-shell-lint.sh"
    )

    for path in "${required_paths[@]}"; do
        [[ -f "${PROJECT_ROOT}/${path}" ]] || {
            fail "Missing native project configuration: ${path}"
            return 1
        }
    done
}

test_json_toml_and_context7() {
    jq empty "${PROJECT_ROOT}/.codex/hooks.json" || return 1
    python3 - "${PROJECT_ROOT}" <<'PY'
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
config_paths = (
    root / ".codex/config.toml",
    root / ".codex/agents/backward-compat-guardian.toml",
    root / ".codex/agents/idempotency-auditor.toml",
)
parsed = {path: tomllib.loads(path.read_text()) for path in config_paths}
servers = parsed[root / ".codex/config.toml"]["mcp_servers"]
assert "context7" not in servers, servers
context7 = servers["deployment-context7"]
assert context7 == {"url": "https://mcp.context7.com/mcp"}, context7
PY
}

test_hook_scripts_are_executable_and_valid() {
    local hook
    local -a hooks=(
        "${PROJECT_ROOT}/.codex/hooks/pre-edit-credential-policy.sh"
        "${PROJECT_ROOT}/.codex/hooks/post-edit-shell-lint.sh"
    )

    for hook in "${hooks[@]}"; do
        [[ -x "${hook}" ]] || {
            fail "Hook is not executable: ${hook#"${PROJECT_ROOT}/"}"
            return 1
        }
        bash -n -- "${hook}" || return 1
    done
}

test_pre_edit_hook_policy() {
    local hook="${PROJECT_ROOT}/.codex/hooks/pre-edit-credential-policy.sh"
    local fixture header path patch payload output decision
    local -a protected_cases=(
        "Add File|test.key"
        "Update File|secret.pem"
        "Delete File|config.credentials"
        "Move to|.forge-lite-credentials"
    )

    for fixture in "${protected_cases[@]}"; do
        header="${fixture%%|*}"
        path="${fixture#*|}"
        patch="$(printf '*** Begin Patch\n*** %s: %s\n*** End Patch' \
            "${header}" "${path}")"
        if ! payload="$(jq -nc --arg cwd "${PROJECT_ROOT}" \
            --arg command "${patch}" \
            '{cwd: $cwd, tool_input: {command: $command}}')"; then
            fail "Could not build protected-path hook payload"
            return 1
        fi
        output="$(printf '%s\n' "${payload}" | "${hook}")" || return 1
        if ! decision="$(jq -r \
            '.hookSpecificOutput.permissionDecision // empty' <<<"${output}")"; then
            fail "Could not parse protected-path hook decision"
            return 1
        fi
        assert_equals "deny" "${decision}" || return 1
    done

    if ! payload="$(jq -nc --arg cwd "${PROJECT_ROOT}" \
        --arg command $'*** Begin Patch\n*** Update File: README.md\n*** End Patch' \
        '{cwd: $cwd, tool_input: {command: $command}}')"; then
        fail "Could not build harmless-edit hook payload"
        return 1
    fi
    output="$(printf '%s\n' "${payload}" | "${hook}")" || return 1
    assert_equals "" "${output}" || return 1
}

test_post_edit_hook_shell_results() {
    local hook="${PROJECT_ROOT}/.codex/hooks/post-edit-shell-lint.sh"
    local payload output status

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        "printf '%s\\n' 'valid'" > "${TEST_TMP}/valid.sh"
    if ! payload="$(jq -nc --arg cwd "${TEST_TMP}" \
        --arg command $'*** Begin Patch\n*** Update File: valid.sh\n*** End Patch' \
        '{cwd: $cwd, tool_input: {command: $command}}')"; then
        fail "Could not build valid-shell hook payload"
        return 1
    fi
    output="$(printf '%s\n' "${payload}" | "${hook}" 2>&1)" || {
        fail "Valid shell was rejected: ${output}"
        return 1
    }
    assert_equals "" "${output}" || return 1

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'if true; then' > "${TEST_TMP}/invalid.sh"
    if ! payload="$(jq -nc --arg cwd "${TEST_TMP}" \
        --arg command $'*** Begin Patch\n*** Update File: invalid.sh\n*** End Patch' \
        '{cwd: $cwd, tool_input: {command: $command}}')"; then
        fail "Could not build invalid-shell hook payload"
        return 1
    fi
    if output="$(printf '%s\n' "${payload}" | "${hook}" 2>&1)"; then
        fail "Invalid shell was accepted"
        return 1
    else
        status=$?
    fi
    assert_equals "2" "${status}" || return 1
    [[ "${output}" == *"bash -n failed"* ]] || {
        fail "Invalid shell rejection did not explain the bash syntax failure"
        return 1
    }
}

run_test "narrow legacy local-settings ignore" test_narrow_legacy_ignore
run_test "README Codex contributor onboarding" test_readme_onboarding
run_test "no legacy artifacts and bounded root guidance" test_legacy_artifacts_and_guidance_size
run_test "native Codex agent, skill, hook, and config paths" test_native_codex_paths
run_test "JSON/TOML parsing and collision-free keyless Context7 configuration" test_json_toml_and_context7
run_test "hook scripts are executable and syntactically valid" test_hook_scripts_are_executable_and_valid
run_test "pre-edit hook denies protected paths and allows harmless edits" test_pre_edit_hook_policy
run_test "post-edit hook accepts valid shell and rejects invalid shell with exit 2" test_post_edit_hook_shell_results

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
    printf '%d of %d Codex configuration contract tests failed\n' \
        "${TESTS_FAILED}" "${TESTS_RUN}" >&2
    exit 1
fi

printf 'All %d Codex configuration contract tests passed\n' "${TESTS_RUN}"
