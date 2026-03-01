# forge-lite — Developer Guide

## Project Overview

forge-lite is a modular, bash-based server provisioning and deployment system for Laravel projects. It targets Ubuntu 24.04 and serves as a lightweight alternative to Laravel Forge.

## Architecture

### Three Pillars
1. **Server Provisioning** (`server/`) — One-time server setup
2. **Site Management** (`sites/`) — Per-site CRUD operations
3. **CI/CD** (`deploy/` + `.github/workflows/`) — Zero-downtime deployments

### Key Patterns

- **Module pattern**: Each `server/modules/*.sh` defines a `provision_<name>()` function. Sourced but not executed until the orchestrator calls it.
- **Template engine**: `{{VAR}}` placeholders replaced via `sed` in `lib/templates.sh`. No envsubst.
- **Single deployer user**: All sites under `/home/deployer/sites/`. FPM pools run as `deployer`.
- **Symlink swap**: `ln -sfn` for atomic zero-downtime deployments. The `-n` flag is critical.
- **Flat site configs**: `/etc/forge-lite/<domain>.conf` — `KEY=VALUE`, sourceable by bash.
- **Credentials**: `/root/.forge-lite-credentials` (chmod 600), never overwritten.

## Directory Structure

```
lib/              Shared libraries (sourced by all scripts)
server/
  provision.sh    Main orchestrator
  modules/        Individual provisioning modules
  config/templates/  Config file templates with {{VAR}} placeholders
cli/              CLI tools (installed to /usr/local/bin/)
sites/            Site management (add/remove)
deploy/           Deployment + rollback
.github/workflows/  CI/CD pipelines
```

## Conventions

- All scripts use `set -euo pipefail`
- Logging goes to stderr via `log_info`, `log_ok`, `log_warn`, `log_error`
- Every operation is idempotent — safe to re-run
- Guard checks before mutations: `dpkg -l`, `id`, `-f`, `systemctl is-active`
- Scripts that modify the system require root (`require_root`)

## Testing

- `bash -n <file>` for syntax checking
- `shellcheck <file>` for linting
- All provisioning modules can be tested in isolation by sourcing lib/*.sh first

## Common Tasks

- **Add a provisioning module**: Create `server/modules/<name>.sh` with `provision_<name>()`, add to the `MODULES` array in `server/provision.sh`
- **Add a template**: Place in `server/config/templates/<category>/`, use `{{VAR}}` placeholders, render with `render_template`
- **Add a CLI tool**: Create in `cli/`, add `install` line to `server/provision.sh`
