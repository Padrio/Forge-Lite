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
        touch "$CREDENTIALS_FILE"
        chmod 600 "$CREDENTIALS_FILE"
    fi

    # Do not overwrite an existing key
    if grep -q "^${key}=" "$CREDENTIALS_FILE" 2>/dev/null; then
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
    line=$(grep "^${key}=" "$CREDENTIALS_FILE" 2>/dev/null) || return 1
    echo "${line#*=}"
}
