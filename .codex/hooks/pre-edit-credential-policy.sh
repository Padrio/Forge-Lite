#!/usr/bin/env bash
set -euo pipefail

extract_patch_paths() {
    local line

    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "${line}" in
            "*** Add File: "*)
                printf '%s\n' "${line#\*\*\* Add File: }"
                ;;
            "*** Update File: "*)
                printf '%s\n' "${line#\*\*\* Update File: }"
                ;;
            "*** Delete File: "*)
                printf '%s\n' "${line#\*\*\* Delete File: }"
                ;;
            "*** Move to: "*)
                printf '%s\n' "${line#\*\*\* Move to: }"
                ;;
        esac
    done
}

is_protected_path() {
    local path="$1"

    case "${path}" in
        *.credentials|*.pem|*.key|*/.forge-lite-credentials|.forge-lite-credentials)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

main() {
    local payload patch path

    payload="$(cat)"
    patch="$(jq -r '.tool_input.command // empty' <<<"${payload}")"
    [[ -n "${patch}" ]] || return 0

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        if is_protected_path "${path}"; then
            jq -nc --arg path "${path}" '{
                hookSpecificOutput: {
                    hookEventName: "PreToolUse",
                    permissionDecision: "deny",
                    permissionDecisionReason: (
                        "Blocked " + $path +
                        ": matches credential/secret policy (*.credentials, *.pem, *.key, .forge-lite-credentials). " +
                        "Editing secrets via Codex is disabled by project policy."
                    )
                }
            }'
            return 0
        fi
    done < <(extract_patch_paths <<<"${patch}")
}

main "$@"
