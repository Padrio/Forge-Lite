#!/usr/bin/env bash
# server/modules/github-runner.sh — GitHub Actions self-hosted runner management
set -euo pipefail

if [[ -z "${FORGE_LITE_DIR:-}" ]]; then
    FORGE_LITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export FORGE_LITE_DIR

source "${FORGE_LITE_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
RUNNER_USER="github-runner"
RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_DIR="${RUNNER_HOME}/actions-runner"
RUNNER_ARCH="linux-x64"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Get the latest runner version from GitHub API
get_latest_runner_version() {
    local version
    version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | grep -oP '"tag_name":\s*"v\K[^"]+')
    [[ -n "$version" ]] || die "Failed to determine latest runner version"
    echo "$version"
}

# ---------------------------------------------------------------------------
# provision_github_runner — Install and register the runner
# ---------------------------------------------------------------------------
provision_github_runner() {
    local repo_url="" token="" labels="forge-lite"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo=*)   repo_url="${1#*=}" ;;
            --token=*)  token="${1#*=}" ;;
            --labels=*) labels="${1#*=}" ;;
            *)          die "Unknown option: $1" ;;
        esac
        shift
    done

    [[ -n "$repo_url" ]] || die "Required: --repo=URL"
    [[ -n "$token" ]]    || die "Required: --token=TOKEN"

    log_info "=== Setting up GitHub Actions Runner ==="

    # 1. Create runner user
    ensure_user "$RUNNER_USER" "/bin/bash" "$RUNNER_HOME"

    # 2. Configure sudoers — only deploy.sh and rollback.sh as root
    local sudoers_file="/etc/sudoers.d/github-runner"
    if [[ ! -f "$sudoers_file" ]]; then
        cat > "$sudoers_file" <<'SUDOERS'
# github-runner: limited sudo for forge-lite deployments only
github-runner ALL=(root) NOPASSWD: /opt/forge-lite/deploy/deploy.sh *
github-runner ALL=(root) NOPASSWD: /opt/forge-lite/deploy/rollback.sh *
SUDOERS
        chmod 440 "$sudoers_file"
        log_ok "Sudoers configured for ${RUNNER_USER}"
    else
        log_info "Sudoers already configured"
    fi

    # Validate sudoers
    visudo -cf "$sudoers_file" || die "Invalid sudoers file: ${sudoers_file}"

    # 3. Download and extract runner
    if [[ ! -f "${RUNNER_DIR}/config.sh" ]]; then
        local version
        version="$(get_latest_runner_version)"
        local tarball="actions-runner-${RUNNER_ARCH}-${version}.tar.gz"
        local download_url="https://github.com/actions/runner/releases/download/v${version}/${tarball}"

        log_info "Downloading runner v${version} ..."
        mkdir -p "$RUNNER_DIR"
        chown "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"

        local tmp_tar
        tmp_tar="$(mktemp)"
        trap "rm -f '${tmp_tar}'" EXIT

        curl -fsSL -o "$tmp_tar" "$download_url"
        tar -xzf "$tmp_tar" -C "$RUNNER_DIR"
        chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
        rm -f "$tmp_tar"
        trap - EXIT

        log_ok "Runner v${version} downloaded"
    else
        log_info "Runner already downloaded"
    fi

    # 4. Configure runner (as runner user)
    if [[ ! -f "${RUNNER_DIR}/.runner" ]]; then
        log_info "Registering runner with GitHub ..."
        sudo -u "$RUNNER_USER" -- "${RUNNER_DIR}/config.sh" \
            --url "$repo_url" \
            --token "$token" \
            --labels "$labels" \
            --name "$(hostname)" \
            --work "${RUNNER_DIR}/_work" \
            --unattended \
            --replace
        log_ok "Runner registered"
    else
        log_info "Runner already registered"
    fi

    # 5. Install and start systemd service (using bundled svc.sh)
    if ! systemctl is-active --quiet "actions.runner."*".$(hostname).service" 2>/dev/null; then
        log_info "Installing runner as systemd service ..."
        cd "$RUNNER_DIR"
        ./svc.sh install "$RUNNER_USER"
        ./svc.sh start
        cd - > /dev/null
        log_ok "Runner service started"
    else
        log_info "Runner service already running"
    fi

    log_ok "GitHub Actions Runner setup complete"
    log_info "  User:   ${RUNNER_USER}"
    log_info "  Dir:    ${RUNNER_DIR}"
    log_info "  Labels: ${labels}"
}

# ---------------------------------------------------------------------------
# remove_github_runner — Deregister and remove the runner
# ---------------------------------------------------------------------------
remove_github_runner() {
    local token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token=*) token="${1#*=}" ;;
            *)         die "Unknown option: $1" ;;
        esac
        shift
    done

    [[ -n "$token" ]] || die "Required: --token=TOKEN (generate a removal token from GitHub)"

    log_info "=== Removing GitHub Actions Runner ==="

    # 1. Stop and uninstall systemd service
    if [[ -f "${RUNNER_DIR}/svc.sh" ]]; then
        cd "$RUNNER_DIR"
        ./svc.sh stop 2>/dev/null || true
        ./svc.sh uninstall 2>/dev/null || true
        cd - > /dev/null
        log_ok "Runner service removed"
    fi

    # 2. Deregister from GitHub
    if [[ -f "${RUNNER_DIR}/config.sh" ]]; then
        sudo -u "$RUNNER_USER" -- "${RUNNER_DIR}/config.sh" remove --token "$token" || true
        log_ok "Runner deregistered from GitHub"
    fi

    # 3. Clean up files
    rm -rf "$RUNNER_DIR"
    log_ok "Runner directory removed"

    # 4. Remove sudoers
    rm -f /etc/sudoers.d/github-runner
    log_ok "Sudoers entry removed"

    log_ok "GitHub Actions Runner fully removed"
    log_info "Note: User '${RUNNER_USER}' was not deleted. Remove manually with: userdel -r ${RUNNER_USER}"
}

# ---------------------------------------------------------------------------
# status_github_runner — Show runner status
# ---------------------------------------------------------------------------
status_github_runner() {
    log_info "=== GitHub Actions Runner Status ==="

    # Check user
    if id "$RUNNER_USER" &>/dev/null; then
        log_ok "User: ${RUNNER_USER} exists"
    else
        log_warn "User: ${RUNNER_USER} does not exist"
        return 0
    fi

    # Check runner directory
    if [[ -d "$RUNNER_DIR" ]]; then
        log_ok "Runner dir: ${RUNNER_DIR}"
    else
        log_warn "Runner dir: not found"
        return 0
    fi

    # Check registration
    if [[ -f "${RUNNER_DIR}/.runner" ]]; then
        log_ok "Registration: configured"
    else
        log_warn "Registration: not configured"
    fi

    # Check systemd service
    local service_name
    service_name=$(systemctl list-units --type=service --no-pager 2>/dev/null \
        | grep -oP 'actions\.runner\.[^\s]+' | head -1) || true

    if [[ -n "$service_name" ]]; then
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            log_ok "Service: ${service_name} (running)"
        else
            log_warn "Service: ${service_name} (stopped)"
        fi
    else
        log_warn "Service: not installed"
    fi

    # Check sudoers
    if [[ -f /etc/sudoers.d/github-runner ]]; then
        log_ok "Sudoers: configured"
    else
        log_warn "Sudoers: not configured"
    fi
}
