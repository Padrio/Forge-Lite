#!/usr/bin/env bash
# forge-lite/server/modules/node.sh — Node.js via NodeSource
provision_node() {
    log_info "=== Provisioning: Node.js ==="

    local node_version="${FORGE_LITE_NODE_VERSION:-20}"

    if command -v node &>/dev/null; then
        local current
        current=$(node --version | grep -oP '\d+' | head -1)
        if [[ "$current" == "$node_version" ]]; then
            log_info "Node.js v${node_version} already installed, skipping"
            return 0
        fi
    fi

    # Install via NodeSource
    log_info "Installing Node.js v${node_version} via NodeSource..."
    curl -fsSL "https://deb.nodesource.com/setup_${node_version}.x" | bash -
    ensure_packages nodejs

    log_ok "Node.js $(node --version) installed"
}
