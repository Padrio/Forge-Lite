#!/usr/bin/env bash
# forge-lite/lib/templates.sh — {{VAR}} template renderer (sed-based)
set -euo pipefail

# ---------------------------------------------------------------------------
# render_template <template_file> <output_file> KEY=VALUE ...
#   Replaces every {{KEY}} in template_file with VALUE and writes to output_file.
#   Values are properly escaped for sed. Writes atomically via temp file + mv.
# ---------------------------------------------------------------------------
render_template() {
    local template="$1" output="$2"
    shift 2

    [[ -f "$template" ]] || { log_error "Template not found: ${template}"; return 1; }

    local content
    if ! content="$(cat "$template")"; then
        log_error "Could not read template: ${template}"
        return 1
    fi

    local pair key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        # Escape sed special characters in the value (including pipe delimiter)
        if ! value="$(printf '%s' "$value" | sed -e 's/[&/\|]/\\&/g')"; then
            log_error "Could not escape template value for ${key}"
            return 1
        fi
        if ! content="$(printf '%s' "$content" | sed "s|{{${key}}}|${value}|g")"; then
            log_error "Could not render template key ${key}"
            return 1
        fi
    done

    # Warn about unreplaced placeholders
    local remaining
    remaining=$(printf '%s' "$content" | grep -oE '\{\{[A-Z_]+\}\}' | head -5) || true
    if [[ -n "$remaining" ]]; then
        log_warn "Unreplaced placeholders in ${output}: ${remaining}"
    fi

    # Atomic write: temp file + mv
    local tmp_output
    if ! tmp_output="$(mktemp "${output}.XXXXXX")"; then
        log_error "Could not create temporary template output for ${output}"
        return 1
    fi
    if ! printf '%s\n' "$content" > "$tmp_output"; then
        rm -f "$tmp_output"
        log_error "Could not write temporary template output for ${output}"
        return 1
    fi

    # Set the final mode before activation. Callers that need a different mode
    # (for example redis.sh) override it after rendering.
    if ! chmod 644 "$tmp_output"; then
        rm -f "$tmp_output"
        log_error "Could not set template output mode for ${output}"
        return 1
    fi
    if ! mv -f "$tmp_output" "$output"; then
        rm -f "$tmp_output"
        log_error "Could not activate rendered template: ${output}"
        return 1
    fi
}
