#!/usr/bin/env bash
# server/modules/github-runner.sh — GitHub Actions self-hosted runner management (multi-runner)
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
RUNNER_BASE_DIR="${RUNNER_HOME}/runners"
RUNNER_ARCH="linux-x64"

# Legacy single-runner path (pre multi-runner)
RUNNER_LEGACY_DIR="${RUNNER_HOME}/actions-runner"

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

# Convert git@github.com:org/repo.git or https://.../*.git to https://github.com/org/repo
normalize_repo_url() {
    local url="$1"

    # SSH format: git@github.com:org/repo.git -> https://github.com/org/repo
    if [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
        url="https://github.com/${BASH_REMATCH[1]}"
    fi

    # Strip trailing .git
    url="${url%.git}"

    echo "$url"
}

# Extract repo name from URL as default runner name
# https://github.com/org/repo -> repo
derive_runner_name() {
    local url="$1"
    url="$(normalize_repo_url "$url")"
    basename "$url" | tr '[:upper:]' '[:lower:]'
}

# Validate runner name: lowercase alphanumeric, hyphens, underscores
validate_runner_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        die "Invalid runner name '${name}': must be lowercase alphanumeric, hyphens, underscores (start with alphanumeric)"
    fi
}

# Return runner directory for a given name
get_runner_dir() {
    echo "${RUNNER_BASE_DIR}/${1}"
}

# Find systemd service name from a runner directory
find_runner_service() {
    local runner_dir="$1"
    local svc_file="${runner_dir}/.service"
    if [[ -f "$svc_file" ]]; then
        cat "$svc_file"
        return 0
    fi
    # Fallback: scan systemd for service matching this runner's name
    local runner_name=""
    if [[ -f "${runner_dir}/.runner" ]]; then
        runner_name=$(grep -oP '"agentName":\s*"\K[^"]+' "${runner_dir}/.runner" 2>/dev/null) || true
    fi
    if [[ -n "$runner_name" ]]; then
        local service_name
        service_name=$(systemctl list-units --type=service --no-pager 2>/dev/null \
            | grep -oP "actions\.runner\.[^\s]*${runner_name}[^\s]*\.service" | head -1) || true
        if [[ -n "$service_name" ]]; then
            echo "$service_name"
            return 0
        fi
    fi
    return 1
}

# Idempotent sudoers setup for github-runner user
ensure_sudoers() {
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
    visudo -cf "$sudoers_file" || die "Invalid sudoers file: ${sudoers_file}"
}

# Migrate legacy single-runner layout to multi-runner layout
migrate_legacy_runner() {
    # Only migrate if legacy dir exists and new layout doesn't
    [[ -d "$RUNNER_LEGACY_DIR" ]] || return 0
    [[ -d "$RUNNER_BASE_DIR" ]] && [[ -n "$(ls -A "$RUNNER_BASE_DIR" 2>/dev/null)" ]] && return 0

    log_info "Migrating legacy runner layout to multi-runner ..."

    local target_name="default"
    local target_dir
    target_dir="$(get_runner_dir "$target_name")"

    mkdir -p "$RUNNER_BASE_DIR"

    # Check if there's an active systemd service for the old runner
    local old_service=""
    old_service=$(systemctl list-units --type=service --no-pager 2>/dev/null \
        | grep -oP 'actions\.runner\.[^\s]+' | head -1) || true

    if [[ -n "$old_service" ]]; then
        # Stop old service before moving
        systemctl stop "$old_service" 2>/dev/null || true
    fi

    mv "$RUNNER_LEGACY_DIR" "$target_dir"
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "$target_dir"

    if [[ -n "$old_service" ]]; then
        # Reinstall service from new location
        cd "$target_dir"
        ./svc.sh install "$RUNNER_USER" 2>/dev/null || true
        ./svc.sh start 2>/dev/null || true
        cd - > /dev/null
    fi

    log_ok "Legacy runner migrated to ${target_dir}"
}

# ---------------------------------------------------------------------------
# Usage helpers
# ---------------------------------------------------------------------------
usage_setup() {
    cat <<'USAGE'
Usage: forge-lite runner setup [flags]

Flags:
    --repo=URL        GitHub repository URL (required, SSH or HTTPS)
    --token=TOKEN     Runner registration token (required)
    --name=NAME       Runner name (default: derived from repo name)
    --labels=LABELS   Comma-separated labels (default: forge-lite)
    -h, --help        Show this help

Examples:
    forge-lite runner setup \
      --repo=git@github.com:org/app.git \
      --token=AXXXXXXXXXXXX

    forge-lite runner setup \
      --repo=https://github.com/org/app \
      --token=AXXXXXXXXXXXX \
      --name=app-production \
      --labels=forge-lite,production
USAGE
    exit 0
}

usage_remove() {
    cat <<'USAGE'
Usage: forge-lite runner remove --name=NAME --token=TOKEN

Flags:
    --name=NAME       Runner name (required)
    --token=TOKEN     Runner removal token (required, from GitHub)
    -h, --help        Show this help

Example:
    forge-lite runner remove --name=myapp --token=AXXXXXXXXXXXX
USAGE
    exit 0
}

# ---------------------------------------------------------------------------
# provision_github_runner — Install and register a runner
# ---------------------------------------------------------------------------
provision_github_runner() {
    local repo_url="" token="" labels="forge-lite" name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo=*)   repo_url="${1#*=}" ;;
            --token=*)  token="${1#*=}" ;;
            --labels=*) labels="${1#*=}" ;;
            --name=*)   name="${1#*=}" ;;
            -h|--help)  usage_setup ;;
            *)          die "Unknown option: $1" ;;
        esac
        shift
    done

    [[ -n "$repo_url" ]] || die "Required: --repo=URL"
    [[ -n "$token" ]]    || die "Required: --token=TOKEN"

    # Normalize SSH URLs to HTTPS for GitHub config.sh
    local github_url
    github_url="$(normalize_repo_url "$repo_url")"

    # Derive runner name from repo if not explicit
    if [[ -z "$name" ]]; then
        name="$(derive_runner_name "$repo_url")"
    fi
    validate_runner_name "$name"

    local runner_dir
    runner_dir="$(get_runner_dir "$name")"
    local github_runner_name
    github_runner_name="$(hostname)-${name}"

    log_info "=== Setting up GitHub Actions Runner: ${name} ==="

    # Migrate legacy layout if needed
    migrate_legacy_runner

    # 1. Create runner user
    ensure_user "$RUNNER_USER" "/bin/bash" "$RUNNER_HOME"

    # 2. Configure sudoers
    ensure_sudoers

    # 3. Download and extract runner
    if [[ ! -f "${runner_dir}/config.sh" ]]; then
        local version
        version="$(get_latest_runner_version)"
        local tarball="actions-runner-${RUNNER_ARCH}-${version}.tar.gz"
        local download_url="https://github.com/actions/runner/releases/download/v${version}/${tarball}"

        log_info "Downloading runner v${version} ..."
        mkdir -p "$runner_dir"
        chown "${RUNNER_USER}:${RUNNER_USER}" "$runner_dir"

        local tmp_tar
        tmp_tar="$(mktemp)"
        trap "rm -f '${tmp_tar}'" EXIT

        curl -fsSL -o "$tmp_tar" "$download_url"
        tar -xzf "$tmp_tar" -C "$runner_dir"
        chown -R "${RUNNER_USER}:${RUNNER_USER}" "$runner_dir"
        rm -f "$tmp_tar"
        trap - EXIT

        log_ok "Runner v${version} downloaded"
    else
        log_info "Runner already downloaded"
    fi

    # 4. Configure runner (as runner user)
    if [[ ! -f "${runner_dir}/.runner" ]]; then
        log_info "Registering runner with GitHub ..."
        sudo -u "$RUNNER_USER" -- "${runner_dir}/config.sh" \
            --url "$github_url" \
            --token "$token" \
            --labels "$labels" \
            --name "$github_runner_name" \
            --work "${runner_dir}/_work" \
            --unattended \
            --replace
        log_ok "Runner registered"
    else
        log_info "Runner already registered"
    fi

    # 5. Install and start systemd service (using bundled svc.sh)
    local service_name=""
    service_name="$(find_runner_service "$runner_dir" 2>/dev/null)" || true

    if [[ -z "$service_name" ]] || ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_info "Installing runner as systemd service ..."
        cd "$runner_dir"
        ./svc.sh install "$RUNNER_USER"
        ./svc.sh start
        cd - > /dev/null
        log_ok "Runner service started"
    else
        log_info "Runner service already running"
    fi

    # 6. Save runner metadata for status/list commands
    cat > "${runner_dir}/.forge-lite-runner.conf" <<EOF
NAME=${name}
REPO=${github_url}
LABELS=${labels}
GITHUB_RUNNER_NAME=${github_runner_name}
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    chown "${RUNNER_USER}:${RUNNER_USER}" "${runner_dir}/.forge-lite-runner.conf"

    log_ok "GitHub Actions Runner '${name}' setup complete"
    log_info "  User:   ${RUNNER_USER}"
    log_info "  Dir:    ${runner_dir}"
    log_info "  Name:   ${github_runner_name}"
    log_info "  Repo:   ${github_url}"
    log_info "  Labels: ${labels}"
}

# ---------------------------------------------------------------------------
# remove_github_runner — Deregister and remove a specific runner
# ---------------------------------------------------------------------------
remove_github_runner() {
    local token="" name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token=*) token="${1#*=}" ;;
            --name=*)  name="${1#*=}" ;;
            -h|--help) usage_remove ;;
            *)         die "Unknown option: $1" ;;
        esac
        shift
    done

    [[ -n "$name" ]]  || die "Required: --name=NAME"
    [[ -n "$token" ]] || die "Required: --token=TOKEN (generate a removal token from GitHub)"

    # Migrate legacy layout if needed
    migrate_legacy_runner

    validate_runner_name "$name"

    local runner_dir
    runner_dir="$(get_runner_dir "$name")"

    [[ -d "$runner_dir" ]] || die "Runner '${name}' not found at ${runner_dir}"

    log_info "=== Removing GitHub Actions Runner: ${name} ==="

    # 1. Stop and uninstall systemd service
    if [[ -f "${runner_dir}/svc.sh" ]]; then
        cd "$runner_dir"
        ./svc.sh stop 2>/dev/null || true
        ./svc.sh uninstall 2>/dev/null || true
        cd - > /dev/null
        log_ok "Runner service removed"
    fi

    # 2. Deregister from GitHub
    if [[ -f "${runner_dir}/config.sh" ]]; then
        sudo -u "$RUNNER_USER" -- "${runner_dir}/config.sh" remove --token "$token" || true
        log_ok "Runner deregistered from GitHub"
    fi

    # 3. Clean up files
    rm -rf "$runner_dir"
    log_ok "Runner directory removed: ${runner_dir}"

    # 4. Remove sudoers only when no runners remain
    local remaining=0
    if [[ -d "$RUNNER_BASE_DIR" ]]; then
        remaining=$(find "$RUNNER_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    fi

    if [[ "$remaining" -eq 0 ]]; then
        rm -f /etc/sudoers.d/github-runner
        log_ok "Sudoers entry removed (last runner)"
    else
        log_info "Sudoers kept (${remaining} runner(s) remaining)"
    fi

    log_ok "GitHub Actions Runner '${name}' fully removed"
}

# ---------------------------------------------------------------------------
# status_github_runner — Show detailed status of all runners
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

    # Check sudoers
    if [[ -f /etc/sudoers.d/github-runner ]]; then
        log_ok "Sudoers: configured"
    else
        log_warn "Sudoers: not configured"
    fi

    # Migrate legacy layout if needed
    migrate_legacy_runner

    # Check runners directory
    if [[ ! -d "$RUNNER_BASE_DIR" ]] || [[ -z "$(ls -A "$RUNNER_BASE_DIR" 2>/dev/null)" ]]; then
        log_warn "No runners found in ${RUNNER_BASE_DIR}"
        return 0
    fi

    # Iterate over each runner
    local runner_dir
    for runner_dir in "${RUNNER_BASE_DIR}"/*/; do
        [[ -d "$runner_dir" ]] || continue
        local name
        name="$(basename "$runner_dir")"

        log_info "--- Runner: ${name} ---"
        log_info "  Dir: ${runner_dir}"

        # Show metadata if available
        if [[ -f "${runner_dir}/.forge-lite-runner.conf" ]]; then
            local repo="" runner_labels="" github_name=""
            repo=$(grep "^REPO=" "${runner_dir}/.forge-lite-runner.conf" 2>/dev/null | cut -d= -f2-) || true
            runner_labels=$(grep "^LABELS=" "${runner_dir}/.forge-lite-runner.conf" 2>/dev/null | cut -d= -f2-) || true
            github_name=$(grep "^GITHUB_RUNNER_NAME=" "${runner_dir}/.forge-lite-runner.conf" 2>/dev/null | cut -d= -f2-) || true
            [[ -n "$repo" ]] && log_info "  Repo: ${repo}"
            [[ -n "$runner_labels" ]] && log_info "  Labels: ${runner_labels}"
            [[ -n "$github_name" ]] && log_info "  GitHub name: ${github_name}"
        fi

        # Check registration
        if [[ -f "${runner_dir}/.runner" ]]; then
            log_ok "  Registration: configured"
        else
            log_warn "  Registration: not configured"
        fi

        # Check systemd service
        local service_name=""
        service_name="$(find_runner_service "$runner_dir" 2>/dev/null)" || true

        if [[ -n "$service_name" ]]; then
            if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                log_ok "  Service: ${service_name} (running)"
            else
                log_warn "  Service: ${service_name} (stopped)"
            fi
        else
            log_warn "  Service: not installed"
        fi
    done
}

# ---------------------------------------------------------------------------
# list_github_runners — Quick tabular list of all runners
# ---------------------------------------------------------------------------
list_github_runners() {
    # Migrate legacy layout if needed
    migrate_legacy_runner

    if [[ ! -d "$RUNNER_BASE_DIR" ]] || [[ -z "$(ls -A "$RUNNER_BASE_DIR" 2>/dev/null)" ]]; then
        log_info "No runners configured."
        return 0
    fi

    printf "%-20s %-40s %-20s %-10s\n" "NAME" "REPO" "LABELS" "STATUS"
    printf "%-20s %-40s %-20s %-10s\n" "----" "----" "------" "------"

    local runner_dir
    for runner_dir in "${RUNNER_BASE_DIR}"/*/; do
        [[ -d "$runner_dir" ]] || continue
        local name repo runner_labels status
        name="$(basename "$runner_dir")"
        repo="-"
        runner_labels="-"
        status="unknown"

        if [[ -f "${runner_dir}/.forge-lite-runner.conf" ]]; then
            repo=$(grep "^REPO=" "${runner_dir}/.forge-lite-runner.conf" 2>/dev/null | cut -d= -f2-) || true
            runner_labels=$(grep "^LABELS=" "${runner_dir}/.forge-lite-runner.conf" 2>/dev/null | cut -d= -f2-) || true
            [[ -z "$repo" ]] && repo="-"
            [[ -z "$runner_labels" ]] && runner_labels="-"
        fi

        local service_name=""
        service_name="$(find_runner_service "$runner_dir" 2>/dev/null)" || true

        if [[ -n "$service_name" ]]; then
            if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                status="running"
            else
                status="stopped"
            fi
        elif [[ -f "${runner_dir}/.runner" ]]; then
            status="registered"
        else
            status="unconfigured"
        fi

        printf "%-20s %-40s %-20s %-10s\n" "$name" "$repo" "$runner_labels" "$status"
    done
}
