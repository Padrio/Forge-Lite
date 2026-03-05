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
    content=$(cat "$template")

    local pair key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        # Escape sed special characters in the value (including pipe delimiter)
        value=$(printf '%s' "$value" | sed -e 's/[&/\|]/\\&/g')
        content=$(printf '%s' "$content" | sed "s|{{${key}}}|${value}|g")
    done

    # Warn about unreplaced placeholders
    local remaining
    remaining=$(printf '%s' "$content" | grep -oE '\{\{[A-Z_]+\}\}' | head -5) || true
    if [[ -n "$remaining" ]]; then
        log_warn "Unreplaced placeholders in ${output}: ${remaining}"
    fi

    # Atomic write: temp file + mv
    local tmp_output
    tmp_output=$(mktemp "${output}.XXXXXX")
    printf '%s\n' "$content" > "$tmp_output"
    mv -f "$tmp_output" "$output"
}
