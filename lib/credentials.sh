#!/usr/bin/env bash
# forge-lite/lib/credentials.sh — Password generation + credential storage
set -euo pipefail

CREDENTIALS_FILE="/root/.forge-lite-credentials"

# ---------------------------------------------------------------------------
# generate_password [length]
#   Generates a random alphanumeric password (default 32 chars).
# ---------------------------------------------------------------------------
generate_password() {
    local length="${1:-32}"
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$length"
}

# ---------------------------------------------------------------------------
# store_credential <key> <value>
#   Stores KEY=VALUE in the credentials file. Will NOT overwrite existing keys.
#   Creates the file with mode 600 if it doesn't exist.
# ---------------------------------------------------------------------------
store_credential() {
    local key="$1" value="$2"

    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        install -m 600 /dev/null "$CREDENTIALS_FILE"
    fi

    # Do not overwrite an existing key
    if grep -qF "${key}=" "$CREDENTIALS_FILE" 2>/dev/null && grep -q "^${key}=" "$CREDENTIALS_FILE" 2>/dev/null; then
        return 0
    fi

    echo "${key}=${value}" >> "$CREDENTIALS_FILE"
}

# ---------------------------------------------------------------------------
# get_credential <key>
#   Retrieves the value for a given key. Returns 1 if not found.
# ---------------------------------------------------------------------------
get_credential() {
    local key="$1"

    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        return 1
    fi

    local line
    line=$(grep -F "${key}=" "$CREDENTIALS_FILE" 2>/dev/null | grep "^${key}=" | head -1) || return 1
    echo "${line#*=}"
}

# ---------------------------------------------------------------------------
# resolve_mariadb_root_password
#   Returns the MariaDB root password on stdout. Tries the stored credential
#   first; if missing OR rejected by MariaDB, prompts interactively and offers
#   to persist the new value. Dies if authentication still fails after a
#   prompt.
#
#   Side effects:
#     - chmod 600 on CREDENTIALS_FILE if it exists (idempotent perms fix)
#     - may write a new MARIADB_ROOT_PASSWORD entry to CREDENTIALS_FILE
#
#   Logging goes to stderr; only the password is printed to stdout.
# ---------------------------------------------------------------------------
resolve_mariadb_root_password() {
    local pw="" prompted=false ans

    if [[ -f "$CREDENTIALS_FILE" ]]; then
        chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true
        if pw=$(get_credential "MARIADB_ROOT_PASSWORD"); then
            if mysql_safe "$pw" -e 'SELECT 1' >/dev/null 2>&1; then
                printf '%s' "$pw"
                return 0
            fi
            log_warn "Stored MariaDB root password was rejected — re-prompting."
        fi
    fi

    log_warn "MariaDB root password not available — prompting."
    read -rsp "MariaDB root password: " pw
    echo >&2
    prompted=true

    [[ -n "$pw" ]] || die "Empty password — aborting."
    mysql_safe "$pw" -e 'SELECT 1' >/dev/null 2>&1 \
        || die "MariaDB authentication failed."

    if [[ "$prompted" == true ]]; then
        read -rp "Save to ${CREDENTIALS_FILE}? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            store_credential "MARIADB_ROOT_PASSWORD" "$pw"
            log_ok "Saved MARIADB_ROOT_PASSWORD to ${CREDENTIALS_FILE}"
        fi
    fi

    printf '%s' "$pw"
}
