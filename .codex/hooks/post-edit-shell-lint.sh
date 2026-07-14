#!/usr/bin/env bash
set -euo pipefail

extract_shell_paths() {
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
            "*** Move to: "*)
                printf '%s\n' "${line#\*\*\* Move to: }"
                ;;
        esac
    done
}

resolve_path() {
    local cwd="$1" path="$2"

    if [[ "${path}" == /* ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s/%s\n' "${cwd%/}" "${path}"
    fi
}

lint_shell_file() {
    local path="$1" output

    if ! output="$(bash -n -- "${path}" 2>&1)"; then
        printf 'bash -n failed: %s\n%s\n' "${path}" "${output}" >&2
        return 2
    fi

    if command -v shellcheck >/dev/null 2>&1; then
        if ! output="$(shellcheck -x -- "${path}" 2>&1)"; then
            printf 'shellcheck failed: %s\n%s\n' "${path}" "${output}" >&2
            return 2
        fi
    fi
}

main() {
    local payload cwd patch patch_path resolved_path

    payload="$(cat)"
    cwd="$(jq -r '.cwd // empty' <<<"${payload}")"
    patch="$(jq -r '.tool_input.command // empty' <<<"${payload}")"
    [[ -n "${patch}" ]] || return 0
    [[ -n "${cwd}" ]] || cwd="${PWD}"

    while IFS= read -r patch_path; do
        [[ "${patch_path}" == *.sh ]] || continue
        resolved_path="$(resolve_path "${cwd}" "${patch_path}")"
        [[ -f "${resolved_path}" ]] || continue
        lint_shell_file "${resolved_path}"
    done < <(extract_shell_paths <<<"${patch}")
}

main "$@"
