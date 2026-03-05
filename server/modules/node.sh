#!/usr/bin/env bash
# forge-lite/server/modules/node.sh — Node.js via NodeSource
provision_node() {
    log_info "=== Provisioning: Node.js ==="

    local node_version="${FORGE_LITE_NODE_VERSION:-22}"

    if command -v node &>/dev/null; then
        local current
        current=$(node --version | grep -oP '\d+' | head -1)
        if [[ "$current" == "$node_version" ]]; then
            log_info "Node.js v${node_version} already installed, skipping"
            return 0
        fi
    fi

    # Install via NodeSource APT repository (no curl|bash)
    log_info "Installing Node.js v${node_version} via NodeSource..."
    local keyring="/usr/share/keyrings/nodesource.gpg"
    if [[ ! -f "$keyring" ]]; then
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor -o "$keyring"
    fi
    echo "deb [signed-by=${keyring}] https://deb.nodesource.com/node_${node_version}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -q
    ensure_packages nodejs

    log_ok "Node.js $(node --version) installed"
}
