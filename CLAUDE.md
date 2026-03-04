# forge-lite — Architecture & Engineering Standards

> Bash-based server provisioning and zero-downtime deployment system for Laravel.
> Target: Ubuntu 24.04. Alternative to Laravel Forge.

---

## 1. Architectural Principles

### 1.1 Three Pillars

| Pillar | Directory | Scope |
|---|---|---|
| Server Provisioning | `server/` | One-time machine setup — OS, packages, services |
| Site Management | `sites/` | Per-domain CRUD — vhosts, FPM pools, databases, workers |
| CI/CD | `deploy/` + `templates/workflows/` | Zero-downtime releases via atomic symlink swap |

### 1.2 Non-Negotiable Design Rules

1. **Idempotency** — Every script, every function, every operation MUST be safe to re-run. Guard before mutate. Never assume first-run.
2. **Fail fast** — `set -euo pipefail` in every script, no exceptions. Undefined variables are bugs, not features.
3. **Separation of concerns** — Libraries (`lib/`) provide primitives. Modules (`server/modules/`) provide provisioning. CLI (`cli/`) provides UX. Never mix layers.
4. **No external dependencies** — Pure bash + coreutils + standard packages. No Python helpers, no Ruby gems, no custom binaries. The template engine uses `sed`, not `envsubst`.
5. **Single user model** — All sites run as `deployer`. No per-site users. FPM pools run as `deployer`, sockets owned by `www-data`.
6. **Credentials are sacred** — `/root/.forge-lite-credentials` (chmod 600). Never overwrite existing keys. Append-only pattern.
7. **Atomic deployments** — `ln -sfn` for symlink swap. The `-n` flag is critical — without it, symlinks nest instead of replacing.

---

## 2. Directory Structure

```
forge-lite/
├── lib/                              # Shared libraries (sourced, never executed directly)
│   ├── common.sh                     #   Logging, colors, idempotent helpers, env guards
│   ├── credentials.sh                #   Password generation & credential store
│   ├── templates.sh                  #   {{VAR}} template rendering engine
│   └── validation.sh                 #   Domain, PHP version, identifier validation
│
├── server/
│   ├── provision.sh                  # Main orchestrator (sources modules, runs in order)
│   ├── modules/                      # Each file defines one provision_<name>() function
│   │   ├── system.sh                 #   Base packages, deployer user, timezone, locale
│   │   ├── swap.sh                   #   Swap file, sysctl, OOM priorities
│   │   ├── security.sh               #   SSH hardening, UFW, Fail2Ban, unattended-upgrades
│   │   ├── nginx.sh                  #   NGINX, DH params, base config, catch-all
│   │   ├── php.sh                    #   PHP 8.1–8.4 parallel, FPM, extensions
│   │   ├── composer.sh               #   Global Composer, auto-update cron
│   │   ├── mariadb.sh                #   MariaDB, secure install, InnoDB tuning
│   │   ├── redis.sh                  #   Redis, password, AOF, maxmemory
│   │   ├── node.sh                   #   Node.js via NodeSource
│   │   ├── supervisor.sh             #   Supervisor daemon
│   │   └── certbot.sh                #   Certbot, nginx plugin, renewal timer
│   └── config/templates/             # Config templates with {{VAR}} placeholders
│       ├── nginx/                    #   nginx.conf, vhost.conf, vhost-ssl.conf, catch-all.conf
│       ├── php/                      #   php.ini, php-fpm-pool.conf
│       ├── supervisor/               #   laravel-worker.conf, horizon.conf, ssr.conf
│       ├── mariadb/                  #   50-server.cnf
│       ├── redis/                    #   redis.conf
│       ├── cron/                     #   laravel-scheduler
│       └── logrotate/                #   forge-lite
│
├── sites/
│   ├── add-site.sh                   # Full site provisioning (FPM, vhost, DB, workers, env)
│   └── remove-site.sh                # Clean teardown with --keep-db/--keep-files safety nets
│
├── deploy/
│   ├── deploy.sh                     # Zero-downtime deployment (artifact or git clone)
│   └── rollback.sh                   # Instant rollback to previous release
│
├── cli/                              # User-facing CLI tools (installed to /usr/local/bin/)
│   ├── forge-lite                    #   Main entry point — dispatches to subcommands
│   ├── forge-lite-db                 #   Database CRUD, backup, restore
│   ├── forge-lite-env                #   .env variable management
│   ├── forge-lite-ssl                #   SSL issuance, renewal, status
│   ├── php-switch                    #   PHP version switcher
│   └── completions/
│       └── forge-lite.bash           #   Bash completion
│
├── cloud-init/
│   └── cloud-config.yml              # Fully automated cloud provisioning
│
└── templates/workflows/
    ├── deploy.yml                    # Reusable workflow (workflow_call)
    ├── deploy-production.yml         # Trigger: push to main
    └── deploy-staging.yml            # Trigger: push to develop
```

---

## 3. Code Standards

### 3.1 Script Header — Every File

```bash
#!/usr/bin/env bash
set -euo pipefail
```

No exceptions. No `set -e` alone. No `#!/bin/bash`. The `env` lookup ensures portability, the triple flags ensure correctness.

### 3.2 Project Root Resolution

Every script that sources libraries MUST auto-resolve the project root:

```bash
if [[ -z "${FORGE_LITE_DIR:-}" ]]; then
    FORGE_LITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export FORGE_LITE_DIR
```

Adjust `/../..` depth based on the file's location relative to root. Never hardcode `/opt/forge-lite`.

### 3.3 Logging — Structured, to stderr

All user-facing output goes through `lib/common.sh` logging functions. Direct `echo` is forbidden in scripts that modify the system.

| Function | Use case | Color |
|---|---|---|
| `log_info "message"` | Progress, status updates | Blue `[INFO]` |
| `log_ok "message"` | Successful completion | Green `[OK]` |
| `log_warn "message"` | Non-fatal issues, skipped steps | Yellow `[WARN]` |
| `log_error "message"` | Errors (before recovery or exit) | Red `[ERROR]` |
| `die "message"` | Fatal error — logs + `exit 1` | Red `[ERROR]` |

Colors auto-disable when stdout is not a TTY (piped or redirected). All logging goes to stderr so stdout remains clean for machine-parseable output.

### 3.4 Function Naming Conventions

| Pattern | Layer | Example |
|---|---|---|
| `provision_<name>()` | Server modules | `provision_php`, `provision_nginx` |
| `cmd_<command>()` | CLI subcommands | `cmd_site_add`, `cmd_deploy` |
| `ensure_<thing>()` | Idempotent helpers | `ensure_packages`, `ensure_service`, `ensure_user` |
| `validate_<thing>()` | Input validation | `validate_domain`, `validate_php_version` |
| `render_<thing>()` | Template rendering | `render_template` |
| `generate_<thing>()` | Value creation | `generate_password` |
| `store_<thing>()` | Persistence | `store_credential` |
| `get_<thing>()` | Retrieval | `get_credential` |

### 3.5 Variable Naming

```bash
# Constants / Globals — UPPER_SNAKE_CASE, prefixed where ambiguous
FORGE_LITE_DIR="/opt/forge-lite"
FORGE_LITE_PHP_DEFAULT="8.3"

# Site-scoped — UPPER_SNAKE_CASE, domain-derived
DOMAIN="example.com"
SITE_ID="example_com"                    # sanitize_for_identifier output
SITE_DIR="/home/deployer/sites/${DOMAIN}"
FPM_SOCKET="/var/run/php/php${PHP_VERSION}-${DOMAIN}-fpm.sock"

# Locals inside functions — lower_snake_case, declared with local
local release_dir pool_name php_version
```

### 3.6 Quoting Rules

```bash
# ALWAYS double-quote variable expansions
echo "${DOMAIN}"                         # Correct
echo $DOMAIN                             # WRONG — word splitting, globbing

# ALWAYS double-quote command substitutions
local version
version="$(php -v | head -1)"            # Correct
version=$(php -v | head -1)              # WRONG — unquoted

# Arrays — proper iteration
local -a packages=("nginx" "curl" "git")
for pkg in "${packages[@]}"; do          # Correct — preserves elements
    ensure_packages "$pkg"
done
```

### 3.7 Conditional & Guard Patterns

```bash
# Prefer [[ ]] over [ ] — no word splitting, supports regex, &&/||
[[ -f "$file" ]] || die "Not found: $file"
[[ -n "${VAR:-}" ]] || die "VAR is required"

# Idempotent guards — check before mutate
if ! id "$username" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin "$username"
fi

if ! dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
    apt-get install -y "$pkg"
fi

if ! systemctl is-active --quiet "$service"; then
    systemctl start "$service"
fi

if ! grep -qF "$marker" "$file" 2>/dev/null; then
    echo "$line" >> "$file"
fi
```

### 3.8 Error Handling Beyond `set -euo pipefail`

```bash
# Intentional failure tolerance — explicit || true
command_that_may_fail 2>/dev/null || true

# Cleanup traps for temporary resources
local tmp_file
tmp_file="$(mktemp)"
trap "rm -f '$tmp_file'" EXIT
```

Never use `set +e` to disable error handling. If a command is allowed to fail, use `|| true` or `if ! command; then ...` explicitly.

### 3.9 Argument Parsing Pattern for CLI

```bash
cmd_example() {
    local domain="" php_version="8.3" flag_ssl=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain=*) domain="${1#*=}" ;;
            --php=*)    php_version="${1#*=}" ;;
            --ssl)      flag_ssl=true ;;
            -h|--help)  usage; return 0 ;;
            *)          die "Unknown option: $1" ;;
        esac
        shift
    done

    [[ -n "$domain" ]] || die "Required: --domain"
    validate_domain "$domain"
    validate_php_version "$php_version"
}
```

Use `--long=value` style consistently. No short flags except `-h`. No `getopt`/`getopts` — they add complexity without value for this project.

---

## 4. Idempotency — The Cardinal Rule

Every function must answer: "What happens if this runs twice?" The answer must be: "Nothing changes."

### The `ensure_*` Pattern

The `lib/common.sh` helpers enforce this pattern:

| Helper | Guard Check | Mutation |
|---|---|---|
| `ensure_packages pkg1 pkg2` | `dpkg -l \| grep '^ii'` | `apt-get install -y` |
| `ensure_service svc [action]` | `systemctl is-active/is-enabled` | `systemctl enable/start` |
| `ensure_user name [shell] [home]` | `id name` | `useradd` |
| `ensure_line_in_file file line [marker]` | `grep -qF` | `echo >> file` |

### Credential Safety

```bash
store_credential() {
    local key="$1" value="$2"
    local cred_file="/root/.forge-lite-credentials"
    # NEVER overwrite — only append new keys
    if grep -q "^${key}=" "$cred_file" 2>/dev/null; then
        return 0  # Already stored, skip silently
    fi
    echo "${key}=${value}" >> "$cred_file"
    chmod 600 "$cred_file"
}
```

---

## 5. Template Engine

Templates live in `server/config/templates/<category>/` and use `{{VAR}}` placeholders rendered by `lib/templates.sh`.

### Rendering

```bash
render_template "nginx/vhost.conf" "/etc/nginx/sites-available/${DOMAIN}" \
    DOMAIN="$DOMAIN" \
    FPM_SOCKET="$FPM_SOCKET"
```

The engine uses `sed` with `|` as delimiter and escapes `&`, `/`, `\` in values. No `envsubst`, no `eval`, no subshell string expansion — this prevents injection.

### Template Conventions

- Placeholder format: `{{UPPER_SNAKE_CASE}}` — matches the variable name exactly
- One template per concern — don't overload templates with conditionals
- Keep two variants where needed: `vhost.conf` (HTTP) and `vhost-ssl.conf` (HTTPS) instead of one template with if/else
- Templates are never executable — they are data, not code

---

## 6. Module Pattern

### Structure

Each provisioning module in `server/modules/` follows this exact pattern:

```bash
#!/usr/bin/env bash
# server/modules/example.sh — Provision <description>
set -euo pipefail

provision_example() {
    log_info "=== Provisioning: Example ==="

    # 1. Guard — skip if already done (idempotent)
    # 2. Install packages
    # 3. Render config templates
    # 4. Enable/start services
    # 5. Verify

    log_ok "Example provisioning complete"
}
```

### Rules

- **One exported function per module** — `provision_<filename_without_extension>()`
- **Sourced, not executed** — The orchestrator (`server/provision.sh`) sources all modules, then calls them in order
- **Ordered execution** — Module array defines dependency order. No dynamic dependency resolution.

```bash
# server/provision.sh
MODULES=(system swap security nginx php composer mariadb redis node supervisor certbot)

for mod in "${MODULES[@]}"; do
    source "${FORGE_LITE_DIR}/server/modules/${mod}.sh"
done

for mod in "${MODULES[@]}"; do
    "provision_${mod}"
done
```

- **Self-contained** — A module may call `lib/` functions but never calls another module directly
- **Testable in isolation** — Source `lib/*.sh`, then source and call a single module

---

## 7. Deployment Model

### Release Directory Layout

```
/home/deployer/sites/example.com/
├── current -> releases/20260301_143022/   # Atomic symlink
├── releases/
│   ├── 20260301_143022/                   # Active release
│   ├── 20260228_120000/                   # Previous (rollback target)
│   └── ...                                # Kept: 5 most recent
└── shared/
    ├── .env                               # Persistent environment
    └── storage/                           # Persistent Laravel storage
        ├── app/public/
        ├── framework/{cache/data,sessions,testing,views}
        └── logs/
```

### Deployment Sequence (deploy.sh)

1. Create timestamped release dir
2. Extract artifact or `git clone --depth 1`
3. Symlink shared resources (`.env`, `storage/`)
4. `composer install --no-dev` (if needed)
5. `npm ci && npm run build` (if `package.json` exists)
6. `artisan down --retry=60` (maintenance mode)
7. `artisan migrate --force` (unless `--skip-migrate`)
8. Cache optimization (`config:cache`, `route:cache`, `view:cache`, `event:cache`)
9. **Atomic symlink swap** — `ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"`
10. Reload FPM + supervisor
11. `artisan up`
12. Cleanup old releases (keep N)

### Rollback (rollback.sh)

Reads `current` symlink target, finds previous release directory, repeats steps 6–11 pointing to the older release. No rebuild needed.

---

## 8. Site Configuration

Each site has a flat config at `/etc/forge-lite/<domain>.conf`:

```bash
# Sourceable by bash — no spaces around =, no quoting needed for simple values
DOMAIN=example.com
SITE_DIR=/home/deployer/sites/example.com
PHP_VERSION=8.3
FPM_SOCKET=/var/run/php/php8.3-example.com-fpm.sock
DB_NAME=example_com
DB_USER=example_com
QUEUE_WORKERS=2
ENABLE_HORIZON=false
ENABLE_SSR=false
ENABLE_SCHEDULER=true
SSL=false
DEPLOY_REPO=git@github.com:org/app.git
DEPLOY_BRANCH=main
```

### Convention

- One file per domain, filename = `<domain>.conf`
- KEY=VALUE format, `source`-able by bash
- No quotes unless the value contains spaces (avoid values with spaces)
- Updated in-place with `sed` for individual keys, never regenerated wholesale

---

## 9. Security Baseline

These are enforced during provisioning and MUST NOT be weakened:

- **SSH**: Key-only auth, `PasswordAuthentication no`, `MaxAuthTries 3`, root login preserved for administration, deployer gets root's authorized_keys
- **Firewall**: UFW enabled, only 22/80/443 open
- **Fail2Ban**: sshd + nginx-http-auth jails active
- **Updates**: `unattended-upgrades` for security patches
- **File permissions**: Credentials at 600, deployer home at 711, shared storage at 775
- **Database**: Per-site users with database-scoped privileges only. Root password in credentials file.
- **Redis**: Password-protected, bound to 127.0.0.1

---

## 10. File System Locations (Post-Provisioning)

```
/usr/local/bin/forge-lite*                # CLI tools
/etc/bash_completion.d/forge-lite         # Shell completion
/root/.forge-lite-credentials             # Master credentials (600)
/root/.forge-lite-provisioned             # Provisioning marker (timestamp)
/etc/forge-lite/                          # Site configs directory
/etc/forge-lite/<domain>.conf             # Per-site config
/home/deployer/sites/<domain>/            # Site root
/home/deployer/sites/<domain>/current     # Symlink to active release
/home/deployer/sites/<domain>/shared/     # Persistent data (.env, storage/)
/home/deployer/sites/<domain>/releases/   # Timestamped release directories
```

---

## 11. CI/CD Workflows

### Reusable Workflow Pattern (`deploy.yml`)

Uses `workflow_call` for both staging and production. Inputs: `environment`, `domain`, `branch`. Secrets: `SSH_PRIVATE_KEY`, `SSH_HOST`, `SSH_USER`.

**Pipeline**: Checkout → PHP/Composer → Node/npm → Build → Create artifact (tar.gz, excludes .git/node_modules/tests) → SCP to server → SSH exec `deploy.sh --artifact=...` → Cleanup.

### Trigger Workflows

- `deploy-production.yml`: Push to `main` → calls `deploy.yml` with production params
- `deploy-staging.yml`: Push to `develop` → calls `deploy.yml` with staging params

---

## 12. Development Workflow

### Adding a Provisioning Module

1. Create `server/modules/<name>.sh` with `provision_<name>()`
2. Add `<name>` to the `MODULES` array in `server/provision.sh` at the correct position (respect dependency order)
3. Place any config templates in `server/config/templates/<name>/`
4. Test in isolation: `source lib/*.sh && source server/modules/<name>.sh && provision_<name>`

### Adding a CLI Subcommand

1. Add `cmd_<name>()` function in `cli/forge-lite` (or create a new `cli/forge-lite-<name>` for complex tools)
2. Add the dispatch case in the main CLI's `case` block
3. Update `cli/completions/forge-lite.bash` with the new subcommand
4. Add install line in `server/provision.sh` or `cli/forge-lite`'s `cmd_update()`

### Adding a Template

1. Place in `server/config/templates/<category>/<name>`
2. Use `{{UPPER_SNAKE_CASE}}` placeholders exclusively
3. Render with `render_template "<category>/<name>" "<output_path>" KEY=VALUE ...`

### Validation Checklist

```bash
# Syntax check — catches unclosed quotes, missing fi/done, etc.
bash -n <file>

# Lint — catches quoting bugs, useless cats, SC warnings
shellcheck <file>

# Dry-read — verify sourcing doesn't execute
bash -c 'source lib/common.sh && source server/modules/<name>.sh && type provision_<name>'
```

---

## 13. Anti-Patterns — Do NOT

| Don't | Do Instead |
|---|---|
| `echo $VAR` | `echo "${VAR}"` — always quote |
| `[ -f $file ]` | `[[ -f "$file" ]]` — double brackets, quoted |
| `set +e` to suppress errors | `command \|\| true` for intentional failures |
| `eval "$user_input"` | `sed` substitution via template engine |
| `envsubst` for templates | `render_template` — controlled `sed` replacement |
| Hardcode `/opt/forge-lite` | Use `FORGE_LITE_DIR` auto-resolution |
| `echo` for user-facing output | `log_info`, `log_ok`, `log_warn`, `log_error` |
| Per-site Linux users | Single `deployer` user for all sites |
| Inline config generation | Template file + `render_template` |
| `curl \| bash` for installs | Package manager (`apt`) or verified installer scripts |
| Positional args for complex CLIs | `--flag=value` named argument parsing |
| `#!/bin/bash` | `#!/usr/bin/env bash` — portable shebang |
| Nested `if` chains | Guard clauses with early `return`/`die` |
| Global mutable state | `local` variables inside functions |
| Silent failures (`2>/dev/null`) without `\|\| true` | Explicit error handling or documented suppression |
