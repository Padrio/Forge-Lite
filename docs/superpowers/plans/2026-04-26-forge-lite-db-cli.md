# forge-lite Database CLI — Domain-aware Dump/Import + DB Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `cli/forge-lite-db` with five domain-aware subcommands (`dump`, `import`, `sync`, `shell`, `info`), introduce a shared `lib/sites.sh` helper, and add `resolve_mariadb_root_password()` to `lib/credentials.sh` for interactive fallback. Existing subcommands keep their signatures and output, but credential loading becomes lazy.

**Architecture:** Pure bash, sourced libraries + executable CLI. The CLI works in two modes: when invoked from the repo (`lib/*.sh` available, fully sourced) or installed to `/usr/local/bin/` (no `lib/`, falls back to inlined copies of every helper it needs). New helpers must be added to **both** sourcing paths. Idempotent guards everywhere — see CLAUDE.md §4.

**Tech Stack:** Bash 5 + coreutils, `mysql` / `mysqldump` (with `--defaults-extra-file` so passwords never reach `ps aux`), `gzip`/`gunzip`, `shellcheck`, no external runtimes.

**Source spec:** `docs/superpowers/specs/2026-04-26-forge-lite-db-cli-design.md`

**Testing policy for this plan:** No unit tests are written. The project has no test infrastructure today; a project-wide test setup is being planned separately (per `feedback_no_adhoc_tests.md`). Verification is `bash -n` + `shellcheck` + interactive `--help` smoke + negative-path manual checks per CLAUDE.md §12.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lib/credentials.sh` | Modify | Add `resolve_mariadb_root_password()` (interactive fallback when stored password is missing/wrong); existing `generate_password`, `store_credential`, `get_credential` unchanged. |
| `lib/sites.sh` | **Create** | New shared library. Holds `resolve_site_db()` for site-config → `DB_NAME` resolution. Designed to grow as sibling CLIs migrate off their inlined duplicates (deferred — out of scope). |
| `cli/forge-lite-db` | Modify | Source new libs; remove script-init `ROOT_PASS=...` (lazy load); extend the installed-mode fallback block; add 5 helpers (`_db_exists`, `_db_size_mb`, `_confirm_destructive`, `_regrant_site_user`, plus inline `resolve_mariadb_root_password` / `resolve_site_db` for fallback mode); add 5 subcommands; rewrite `usage()` and dispatch. |
| `cli/completions/forge-lite.bash` | Modify | Replace the `db)` block to advertise the new subcommands and offer domain / file / flag completions. |

**Verified unchanged (call out in commit message; do NOT touch):**
- `cli/forge-lite` — already dispatches `db` via `exec forge-lite-db "$@"` (line 516); `cmd_update`'s tools array (line 416) already includes `forge-lite-db`. Both verified before plan write.
- `sites/add-site.sh` — emits `store_credential "DB_${SITE_ID}_PASSWORD" "$DB_PASS"` (line 206); `_regrant_site_user` reads with this exact key. No change needed.
- `lib/common.sh`, `lib/validation.sh` — provide `mysql_safe`, `mysqldump_safe`, `log_*`, `die`, `validate_domain`, `sanitize_for_identifier` already.

---

## Conventions & Gotchas

Read these once before starting Task 1; they prevent the most likely review comments.

- **Quoting**: Always `"${VAR}"`, never `$VAR`. Always `[[ ]]`, never `[ ]`. (CLAUDE.md §3.6, §3.7)
- **Logging**: Every user-facing line goes through `log_info` / `log_ok` / `log_warn` / `log_error` / `die` — never bare `echo`, except for stdout-as-data (e.g. `dump` echoing the output path, `info` printing the formatted block, `resolve_*` echoing their return value).
- **Stderr vs stdout**: `log_*` writes to stderr (set in `lib/common.sh:22-25`). Any function that "returns" a value via `echo` writes to stdout. Both paths must coexist cleanly inside command substitutions: `path=$(cmd_dump …)` should yield only the path.
- **Identifier safety**: Use `sanitize_for_identifier "$domain"` from `lib/validation.sh:35`. It produces `example_com` from `example.com`. The site DB name, DB user, and credential key suffix all share this identifier (set by `sites/add-site.sh:69,194-206`).
- **Credential key for site DB password**: `DB_${SITE_ID}_PASSWORD`. Confirmed at `sites/add-site.sh:206`.
- **`mysql_safe` / `mysqldump_safe`**: Both are in `lib/common.sh:135,149` — and there is also an inline copy inside `cli/forge-lite-db`'s installed-fallback block (lines 40-62). Any new helper that needs DB access must work in both modes.
- **Pipe failure handling**: `set -euo pipefail` is global. A `mysqldump_safe … | gzip > out` that fails on the dump side will still propagate. Tasks rely on this — do not weaken with `|| true`.
- **`exec` for `shell`**: Replaces the bash process so the user sees `mysql`'s exit code directly.
- **Dispatch case order**: existing `create|drop|list|backup|restore` come first, new `dump|import|sync|shell|info` after — matches the `usage()` ordering. Dispatch entries must be `*` -terminated (`drop) cmd_drop "${2:-}" "${3:-}" ;;`) — the existing pattern.
- **CI lint scope**: `.github/workflows/lint.yml:20-23` runs `find . -name '*.sh'` — so `lib/sites.sh` and `lib/credentials.sh` are auto-linted, but `cli/forge-lite-db` (no extension) and `cli/completions/forge-lite.bash` are **not**. Run `shellcheck -x` on those manually as part of verification (Task 9).
- **Idempotency**: Every helper must be safe to re-run. `mkdir -p`, `IF NOT EXISTS`, `DROP … IF EXISTS`, `chown … 2>/dev/null || true` for non-existent owners, etc.
- **No new files outside the four listed.** No README, no CHANGELOG entry. Nothing the user did not ask for.

---

## Task 1: Add `resolve_mariadb_root_password()` to `lib/credentials.sh`

**Files:**
- Modify: `lib/credentials.sh` (append the new function after `get_credential`)

- [ ] **Step 1: Append the function**

Open `lib/credentials.sh` and append below the existing `get_credential` function (after line 50):

```bash
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
```

Notes for the implementer:
- `mysql_safe` is provided by `lib/common.sh`. The credentials lib does not source common; it relies on the caller to have sourced both. This matches the existing pattern (the lib never calls `log_warn` today either; the new function does, so callers must source `common.sh` first — both call sites do).
- `printf '%s'` (no trailing newline) so `pw=$(resolve_mariadb_root_password)` doesn't pick up a stray `\n` in the variable.
- The `store_credential` function refuses to overwrite an existing key (`lib/credentials.sh:29-31`). If the stored value is wrong but already present, the user must edit the file by hand. That's intentional — silently overwriting credentials is a footgun; document this behaviour with the warn line.

- [ ] **Step 2: Syntax check**

```bash
bash -n lib/credentials.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Lint**

```bash
shellcheck -x lib/credentials.sh
```

Expected: no findings. (If shellcheck complains about `log_warn`/`log_ok`/`die`/`mysql_safe` being undefined, that's a stylistic warning we ignore — the lib is sourced into a context that has them. If a hard error appears, fix it.)

- [ ] **Step 4: Smoke source**

```bash
bash -c 'source lib/common.sh && source lib/credentials.sh && type resolve_mariadb_root_password'
```

Expected output: `resolve_mariadb_root_password is a function`

- [ ] **Step 5: Commit**

```bash
git add lib/credentials.sh
git commit -m "$(cat <<'EOF'
Add resolve_mariadb_root_password() helper

Lazy resolver: tries stored credential first, validates against MariaDB,
falls back to interactive prompt if missing or rejected. Offers to persist
a fresh value. Lets callers do credential resolution at call time rather
than at script init — so --help works without /root/.forge-lite-credentials.
EOF
)"
```

---

## Task 2: Create `lib/sites.sh` with `resolve_site_db()`

**Files:**
- Create: `lib/sites.sh`

- [ ] **Step 1: Write the new file**

Create `lib/sites.sh` with the full content below (no other content):

```bash
#!/usr/bin/env bash
# forge-lite/lib/sites.sh — Site-config resolution helpers
#
# Sourced by CLIs that need to map a domain → site config keys. Designed to
# grow as sibling CLIs (forge-lite-env, forge-lite-ssl, forge-lite-auth)
# migrate off their inlined duplicates. For now: one function.
set -euo pipefail

SITE_CONFIG_DIR="${SITE_CONFIG_DIR:-/etc/forge-lite}"

# ---------------------------------------------------------------------------
# resolve_site_db <domain>
#   Validates the domain, locates its site config, and prints DB_NAME on
#   stdout. Dies with a helpful message (including the list of available
#   sites) if the config or the DB_NAME key is missing.
# ---------------------------------------------------------------------------
resolve_site_db() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || die "Domain required."
    validate_domain "$domain"

    local conf="${SITE_CONFIG_DIR}/${domain}.conf"
    if [[ ! -f "$conf" ]]; then
        local available
        available=$(ls "${SITE_CONFIG_DIR}"/*.conf 2>/dev/null \
            | xargs -n1 basename 2>/dev/null \
            | sed 's/\.conf$//' \
            | paste -sd, -)
        die "Site '${domain}' not found. Available: ${available:-<none>}"
    fi

    local db_name
    db_name=$(
        # shellcheck disable=SC1090
        source "$conf"
        printf '%s' "${DB_NAME:-}"
    )
    [[ -n "$db_name" ]] || die "Site config '${conf}' lacks DB_NAME — old or manually edited."
    printf '%s' "$db_name"
}
```

Notes for the implementer:
- `SITE_CONFIG_DIR` is overridable for hypothetical future testing; defaults to `/etc/forge-lite`. Do not hardcode the path.
- The subshell `( source "$conf"; printf '%s' "${DB_NAME:-}" )` isolates the `source` so unrelated keys (`PHP_VERSION`, `SITE_DIR`, …) don't leak into the caller's scope.
- `printf '%s'` (no newline) so `db_name=$(resolve_site_db …)` is exact.
- Depends on `die` from `lib/common.sh` and `validate_domain` from `lib/validation.sh`. Callers must source both first (the CLI does).

- [ ] **Step 2: Syntax check**

```bash
bash -n lib/sites.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Lint**

```bash
shellcheck -x lib/sites.sh
```

Expected: no findings.

- [ ] **Step 4: Smoke source**

```bash
bash -c 'source lib/common.sh && source lib/validation.sh && source lib/sites.sh && type resolve_site_db'
```

Expected: `resolve_site_db is a function`

- [ ] **Step 5: Commit**

```bash
git add lib/sites.sh
git commit -m "$(cat <<'EOF'
Add lib/sites.sh with resolve_site_db helper

Shared site-config resolution. Maps domain -> DB_NAME by sourcing
/etc/forge-lite/<domain>.conf in a subshell. New shared library; sibling
CLIs (forge-lite-env, -ssl, -auth) keep their inlined copies for now,
migration deferred.
EOF
)"
```

---

## Task 3: Wire new libs into `cli/forge-lite-db` and remove eager credential load

The next several tasks all edit `cli/forge-lite-db`. We do them in small, individually-verifiable steps. After each step the file remains a runnable script.

**Files:**
- Modify: `cli/forge-lite-db:1-67` (header + sourcing block + script-init creds line)

- [ ] **Step 1: Replace the sourcing block**

Replace lines 7-63 (the entire `if [[ -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then … else … fi` block) with the version below. The diff: source two new libs (`validation.sh`, `sites.sh`) when present, and add inline fallback definitions of `resolve_mariadb_root_password` and `resolve_site_db` so the installed CLI keeps working.

```bash
# Source lib/common.sh, credentials.sh, validation.sh, sites.sh if available.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then
    export FORGE_LITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    source "${FORGE_LITE_DIR}/lib/common.sh"
    source "${FORGE_LITE_DIR}/lib/credentials.sh"
    source "${FORGE_LITE_DIR}/lib/validation.sh"
    source "${FORGE_LITE_DIR}/lib/sites.sh"
else
    # Minimal fallback for installed CLI (no lib/ on disk).
    log_info()  { echo "[INFO]  $*" >&2; }
    log_ok()    { echo "[OK]    $*" >&2; }
    log_warn()  { echo "[WARN]  $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    die() { log_error "$@"; exit 1; }

    SITE_CONFIG_DIR="${SITE_CONFIG_DIR:-/etc/forge-lite}"

    validate_domain() {
        local domain="$1"
        if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
            die "Invalid domain name: ${domain}"
        fi
    }

    sanitize_for_identifier() {
        local input="$1"
        echo "$input" | tr '.-' '_' | tr -cd 'a-zA-Z0-9_' | tr '[:upper:]' '[:lower:]'
    }

    get_credential() {
        local key="$1"
        [[ -f "$CREDENTIALS_FILE" ]] || return 1
        local line
        line=$(grep -F "${key}=" "$CREDENTIALS_FILE" 2>/dev/null | grep "^${key}=" | head -1) || return 1
        echo "${line#*=}"
    }

    store_credential() {
        local key="$1" value="$2"
        if [[ ! -f "$CREDENTIALS_FILE" ]]; then
            install -m 600 /dev/null "$CREDENTIALS_FILE"
        fi
        if grep -qF "${key}=" "$CREDENTIALS_FILE" 2>/dev/null && grep -q "^${key}=" "$CREDENTIALS_FILE" 2>/dev/null; then
            return 0
        fi
        echo "${key}=${value}" >> "$CREDENTIALS_FILE"
    }

    generate_password() {
        openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"
    }

    mysql_safe() {
        local root_pass="$1"; shift
        local cnf
        cnf="$(mktemp)"
        chmod 600 "$cnf"
        printf '[client]\nuser=root\npassword=%s\n' "$root_pass" > "$cnf"
        mysql --defaults-extra-file="$cnf" "$@"
        local rc=$?
        rm -f "$cnf"
        return $rc
    }

    mysqldump_safe() {
        local root_pass="$1"; shift
        local cnf
        cnf="$(mktemp)"
        chmod 600 "$cnf"
        printf '[client]\nuser=root\npassword=%s\n' "$root_pass" > "$cnf"
        mysqldump --defaults-extra-file="$cnf" "$@"
        local rc=$?
        rm -f "$cnf"
        return $rc
    }

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

    resolve_site_db() {
        local domain="${1:-}"
        [[ -n "$domain" ]] || die "Domain required."
        validate_domain "$domain"
        local conf="${SITE_CONFIG_DIR}/${domain}.conf"
        if [[ ! -f "$conf" ]]; then
            local available
            available=$(ls "${SITE_CONFIG_DIR}"/*.conf 2>/dev/null \
                | xargs -n1 basename 2>/dev/null \
                | sed 's/\.conf$//' \
                | paste -sd, -)
            die "Site '${domain}' not found. Available: ${available:-<none>}"
        fi
        local db_name
        db_name=$(
            # shellcheck disable=SC1090
            source "$conf"
            printf '%s' "${DB_NAME:-}"
        )
        [[ -n "$db_name" ]] || die "Site config '${conf}' lacks DB_NAME — old or manually edited."
        printf '%s' "$db_name"
    }
fi
```

The fallback definitions are intentional copies of the lib versions (the only "no external dependencies on disk" mode the installed CLI supports). Keep them in sync if you change the libs in this PR.

- [ ] **Step 2: Remove the eager credential load**

Delete the line that currently reads:

```bash
ROOT_PASS=$(get_credential "MARIADB_ROOT_PASSWORD")
```

(in the original file, line 67, immediately above `usage()`). The line goes; nothing replaces it. Each `cmd_*` will fetch the password lazily when it actually needs it — see Task 4.

- [ ] **Step 3: Syntax check**

```bash
bash -n cli/forge-lite-db
```

Expected: no output, exit 0.

- [ ] **Step 4: --help works without credentials**

```bash
sudo -u root env CREDENTIALS_FILE=/tmp/nonexistent-$$ ./cli/forge-lite-db --help 2>&1 | head -20
```

(Use a fake credentials path that does not exist, so we prove the script no longer dies at init.)

Expected: prints the (still-old) usage block and exits 0. No "Credential not found" error.

If you cannot run as root in this dev shell, settle for `bash -n` and trust that the only top-level statement that touched credentials was the one we just deleted.

- [ ] **Step 5: Commit**

```bash
git add cli/forge-lite-db
git commit -m "$(cat <<'EOF'
Make forge-lite-db credential load lazy

Source lib/{validation,sites}.sh alongside common+credentials when
available; mirror resolve_mariadb_root_password and resolve_site_db inline
in the installed-mode fallback block.

Drop the script-init ROOT_PASS=... line so --help no longer dies on a
missing /root/.forge-lite-credentials. Per-command credential fetch comes
in the next commit.
EOF
)"
```

---

## Task 4: Convert existing `cmd_create|drop|list|backup|restore` to lazy credential fetch

After Task 3, `ROOT_PASS` is gone — the existing commands still reference it and would break. Wire each one to call `resolve_mariadb_root_password` at the top of its body.

**Files:**
- Modify: `cli/forge-lite-db` — the five existing `cmd_*` functions

- [ ] **Step 1: Edit `cmd_create`**

In `cli/forge-lite-db`, find:

```bash
cmd_create() {
    local name="$1"
    [[ -n "$name" ]] || die "Database name required."
    local safe_name
    safe_name=$(echo "$name" | tr '.-' '_' | tr -cd 'a-zA-Z0-9_')

    local db_pass
    db_pass=$(generate_password 32)

    mysql_safe "$ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS \`${safe_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
```

Replace with:

```bash
cmd_create() {
    local name="$1"
    [[ -n "$name" ]] || die "Database name required."
    local safe_name
    safe_name=$(echo "$name" | tr '.-' '_' | tr -cd 'a-zA-Z0-9_')

    local root_pass db_pass
    root_pass=$(resolve_mariadb_root_password)
    db_pass=$(generate_password 32)

    mysql_safe "$root_pass" -e "CREATE DATABASE IF NOT EXISTS \`${safe_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
```

Also rename every other `$ROOT_PASS` inside `cmd_create` to `$root_pass` (there are three more `mysql_safe "$ROOT_PASS"` lines and a `store_credential` is **not** affected — it doesn't take the root password).

- [ ] **Step 2: Edit `cmd_drop`**

In `cmd_drop`, after the `if [[ "$confirm" != "--yes" ]]; then … fi` block but before the first `mysql_safe`, insert:

```bash
    local root_pass
    root_pass=$(resolve_mariadb_root_password)
```

Then rename every `$ROOT_PASS` inside `cmd_drop` to `$root_pass` (three occurrences in the three `mysql_safe` calls).

- [ ] **Step 3: Edit `cmd_list`**

Replace the body of `cmd_list`:

```bash
cmd_list() {
    local root_pass
    root_pass=$(resolve_mariadb_root_password)
    mysql_safe "$root_pass" -e "SHOW DATABASES;" | tail -n +2 | grep -vE '^(information_schema|performance_schema|mysql|sys)$'
}
```

- [ ] **Step 4: Edit `cmd_backup`**

In `cmd_backup`, after the `mkdir -p "$backup_dir"` line, insert:

```bash
    local root_pass
    root_pass=$(resolve_mariadb_root_password)
```

Rename `$ROOT_PASS` to `$root_pass` in the `mysqldump_safe` call.

- [ ] **Step 5: Edit `cmd_restore`**

In `cmd_restore`, after the `safe_name=…` line, insert:

```bash
    local root_pass
    root_pass=$(resolve_mariadb_root_password)
```

Rename both `$ROOT_PASS` references in the `if/else` to `$root_pass`.

- [ ] **Step 6: Verify no stray `ROOT_PASS` remains**

```bash
grep -n 'ROOT_PASS' cli/forge-lite-db
```

Expected: no output (the variable name `root_pass` is lower-case so the grep is exact-match safe).

- [ ] **Step 7: Syntax check**

```bash
bash -n cli/forge-lite-db
```

Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git add cli/forge-lite-db
git commit -m "$(cat <<'EOF'
Lazy-load MariaDB root password in existing subcommands

create/drop/list/backup/restore each call resolve_mariadb_root_password
at the top of their body. UX unchanged for users with a valid credentials
file; users without get an interactive prompt instead of a hard failure.
EOF
)"
```

---

## Task 5: Add reusable helpers (`_db_exists`, `_db_size_mb`, `_confirm_destructive`, `_regrant_site_user`)

These four helpers are consumed by the new subcommands. We add them as a block before the existing `cmd_*` functions so they can be referenced by both the legacy (none of them need it) and new commands. They share the `_` prefix to mark them as internal (not invoked from the dispatch case).

**Files:**
- Modify: `cli/forge-lite-db` — insert helpers between the `usage()` function and `cmd_create`

- [ ] **Step 1: Insert the helper block**

Locate the line `cmd_create() {` and insert the block below directly above it (one blank line between `}` of `usage()` and the helper block, one blank line after the helper block before `cmd_create`):

```bash
# ---------------------------------------------------------------------------
# Internal helpers — used by domain-aware subcommands.
# ---------------------------------------------------------------------------

# _db_exists <root_pass> <db_name>
#   Returns 0 if the schema exists, non-zero otherwise.
_db_exists() {
    local root_pass="$1" db_name="$2"
    mysql_safe "$root_pass" -N -B -e \
        "SELECT 1 FROM information_schema.schemata WHERE schema_name='${db_name}';" \
        2>/dev/null | grep -q '^1$'
}

# _db_size_mb <root_pass> <db_name>
#   Prints the size in MiB (one decimal). Prints "0.0" for empty / missing DBs.
_db_size_mb() {
    local root_pass="$1" db_name="$2"
    mysql_safe "$root_pass" -N -B -e \
        "SELECT IFNULL(ROUND(SUM(data_length+index_length)/1024/1024,1),0)
         FROM information_schema.tables WHERE table_schema='${db_name}';" \
        2>/dev/null
}

# _confirm_destructive <prompt> <assume_yes>
#   Prompts for confirmation unless assume_yes == "true". Aborts with exit 0.
_confirm_destructive() {
    local prompt="$1" assume_yes="$2" ans
    [[ "$assume_yes" == "true" ]] && return 0
    read -rp "$prompt" ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }
}

# _regrant_site_user <root_pass> <db_name> <site_id>
#   After a DROP+CREATE we must re-grant the site user, otherwise the live
#   site loses DB access. Site user password lives in DB_${SITE_ID}_PASSWORD
#   (set by add-site.sh). Dies BEFORE issuing any GRANT if the password is
#   missing — refuses to leave grants half-broken.
_regrant_site_user() {
    local root_pass="$1" db_name="$2" site_id="$3"
    local site_pw
    site_pw=$(get_credential "DB_${site_id}_PASSWORD") \
        || die "Site password DB_${site_id}_PASSWORD not in credentials. Refusing to recreate database without restoring grants."
    mysql_safe "$root_pass" <<MYSQL
CREATE USER IF NOT EXISTS '${site_id}'@'localhost' IDENTIFIED BY '${site_pw}';
ALTER USER '${site_id}'@'localhost' IDENTIFIED BY '${site_pw}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${site_id}'@'localhost';
FLUSH PRIVILEGES;
MYSQL
}
```

Notes for the implementer:
- `_db_size_mb` swallows stderr and returns "0.0" on empty result thanks to `IFNULL(..., 0)` — a missing schema returns the same as a schema with no tables. That's intentional: callers display "current size" before destructive ops, "0" tells the operator the target is empty.
- `_db_exists` parses the result with `grep -q '^1$'` to be tolerant of MariaDB's exit code (which is 0 for valid SQL even if no row matches).
- `_confirm_destructive` uses `exit 0` (not `return`) to short-circuit the whole CLI — matches the existing `cmd_drop` aborted-by-user convention.
- The `MYSQL` heredoc is unquoted on its open marker → `${site_id}` and `${site_pw}` are interpolated by bash before mysql sees them. Escape backticks (`` \` ``) so bash doesn't treat them as command substitution.
- All four helpers operate on whatever root_pass and site_id the caller has already resolved — they don't call `resolve_mariadb_root_password` themselves.

- [ ] **Step 2: Syntax check**

```bash
bash -n cli/forge-lite-db
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add cli/forge-lite-db
git commit -m "$(cat <<'EOF'
Add internal helpers for domain-aware DB subcommands

_db_exists, _db_size_mb, _confirm_destructive, _regrant_site_user — used
by the upcoming dump/import/sync/shell/info commands. _regrant_site_user
refuses to mutate if the site DB password is missing, so a botched
recreate cannot leave the site without grants.
EOF
)"
```

---

## Task 6: Add `cmd_dump`

**Files:**
- Modify: `cli/forge-lite-db` — append `cmd_dump` after `cmd_restore` (or after the last existing `cmd_*` body)

- [ ] **Step 1: Insert the function**

Append below `cmd_restore`:

```bash
cmd_dump() {
    local domain="" output="" gzip_enabled=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output=*)  output="${1#*=}" ;;
            --no-gzip)   gzip_enabled=false ;;
            -h|--help)
                cat <<'USAGE'
Usage: forge-lite-db dump <domain> [--output=PATH] [--no-gzip]
  Dumps a site's database to disk. Default path:
    /home/deployer/backups/<site_id>_<timestamp>.sql.gz
  --output=PATH   Override destination path
  --no-gzip       Write raw SQL (.sql) instead of gzipped (.sql.gz)
USAGE
                return 0
                ;;
            --*)         die "Unknown option: $1" ;;
            *)
                if [[ -z "$domain" ]]; then domain="$1"
                else die "Unexpected positional argument: $1"
                fi
                ;;
        esac
        shift
    done

    [[ -n "$domain" ]] || die "Usage: forge-lite-db dump <domain> [--output=PATH] [--no-gzip]"

    local db_name site_id root_pass
    db_name=$(resolve_site_db "$domain")
    site_id=$(sanitize_for_identifier "$domain")
    root_pass=$(resolve_mariadb_root_password)

    _db_exists "$root_pass" "$db_name" || die "DB '${db_name}' missing in MariaDB."

    local backup_dir="/home/deployer/backups"
    mkdir -p "$backup_dir"
    chown deployer:deployer "$backup_dir" 2>/dev/null || true

    local timestamp ext
    timestamp=$(date +%Y%m%d_%H%M%S)
    ext=".sql"
    [[ "$gzip_enabled" == true ]] && ext=".sql.gz"
    [[ -n "$output" ]] || output="${backup_dir}/${site_id}_${timestamp}${ext}"

    log_info "Dumping ${db_name} → ${output} (this may take a while)..."
    if [[ "$gzip_enabled" == true ]]; then
        mysqldump_safe "$root_pass" --single-transaction --quick --lock-tables=false "$db_name" \
            | gzip > "$output"
    else
        mysqldump_safe "$root_pass" --single-transaction --quick --lock-tables=false "$db_name" \
            > "$output"
    fi
    chown deployer:deployer "$output" 2>/dev/null || true

    local size
    size=$(du -h "$output" | cut -f1)
    log_ok "Dump complete (size: ${size})"
    echo "$output"
}
```

Notes:
- The `--help` block is local to the function — printing it via `cat` then `return 0` short-circuits the parser before any positional arg is required.
- `set -o pipefail` (script-global) catches `mysqldump` failures even through the gzip pipe.
- `chown` is `|| true` because the script may run on a system where `deployer` doesn't exist (extremely unlikely on a forge-lite host but cheap to be safe).
- The trailing `echo "$output"` is the **only** stdout output of the command, so callers can capture the path: `path=$(forge-lite-db dump example.com)`.

- [ ] **Step 2: Syntax check**

```bash
bash -n cli/forge-lite-db
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add cli/forge-lite-db
git commit -m "$(cat <<'EOF'
Add forge-lite-db dump subcommand

Domain-aware dump. Default destination /home/deployer/backups/, default
.sql.gz; --output= and --no-gzip override. Stdout is the resulting path
so callers can capture it. Dispatch wiring follows in a later commit.
EOF
)"
```

---

## Task 7: Add `cmd_import`

**Files:**
- Modify: `cli/forge-lite-db` — append `cmd_import` after `cmd_dump`

- [ ] **Step 1: Insert the function**

```bash
cmd_import() {
    local domain="" file="" assume_yes=false drop_enabled=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)       assume_yes=true ;;
            --no-drop)   drop_enabled=false ;;
            -h|--help)
                cat <<'USAGE'
Usage: forge-lite-db import <domain> <file> [--yes] [--no-drop]
  Imports a SQL or SQL.gz dump into a site's database. By default
  drops and recreates the database first (full reset). Use --no-drop
  to merge into the existing schema.
  --yes       Skip confirmation
  --no-drop   Keep existing schema, merge imported tables on top
USAGE
                return 0
                ;;
            --*)         die "Unknown option: $1" ;;
            *)
                if   [[ -z "$domain" ]]; then domain="$1"
                elif [[ -z "$file"   ]]; then file="$1"
                else die "Unexpected positional argument: $1"
                fi
                ;;
        esac
        shift
    done

    [[ -n "$domain" && -n "$file" ]] || die "Usage: forge-lite-db import <domain> <file> [--yes] [--no-drop]"
    [[ -r "$file" ]] || die "File not readable: ${file}"

    local db_name site_id root_pass
    db_name=$(resolve_site_db "$domain")
    site_id=$(sanitize_for_identifier "$domain")
    root_pass=$(resolve_mariadb_root_password)

    local is_gzip=false
    if [[ "$file" == *.gz ]]; then
        gunzip -t "$file" 2>/dev/null || die "Corrupt gzip: ${file}"
        is_gzip=true
    fi

    local current_size file_size drop_msg
    current_size=$(_db_size_mb "$root_pass" "$db_name")
    file_size=$(du -h "$file" | cut -f1)
    if [[ "$drop_enabled" == true ]]; then
        drop_msg="DROP and recreate"
    else
        drop_msg="MERGE into (existing tables kept)"
    fi

    _confirm_destructive \
        "WARNING: This will ${drop_msg} database '${db_name}' (current size: ${current_size} MB).
Source file '${file}' (${file_size}) will be imported.
Continue? [y/N] " "$assume_yes"

    if [[ "$drop_enabled" == true ]]; then
        mysql_safe "$root_pass" -e "DROP DATABASE IF EXISTS \`${db_name}\`;"
        mysql_safe "$root_pass" -e "CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        _regrant_site_user "$root_pass" "$db_name" "$site_id"
    fi

    log_info "Importing ${file} → ${db_name} (this may take a while)..."
    if [[ "$is_gzip" == true ]]; then
        gunzip -c "$file" | mysql_safe "$root_pass" "$db_name"
    else
        mysql_safe "$root_pass" "$db_name" < "$file"
    fi
    log_ok "Import complete"
}
```

Notes:
- Re-grant happens **after** `CREATE DATABASE` and **before** the import. If the import fails, the user has an empty DB with valid grants — they can re-run `import` and recover. If we re-granted *after* import, a half-imported DB would be live without working credentials.
- `_regrant_site_user` will `die` if `DB_${site_id}_PASSWORD` is missing — that's the preferred failure mode, vs silently leaving the live site without DB access.
- `--no-drop` skips both the drop and the re-grant; existing grants stay valid.

- [ ] **Step 2: Syntax check**

```bash
bash -n cli/forge-lite-db
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add cli/forge-lite-db
git commit -m "$(cat <<'EOF'
Add forge-lite-db import subcommand

Imports SQL or SQL.gz into a site's database, defaulting to drop+recreate
with re-granting the site user before the import begins. --no-drop merges
into existing schema. --yes skips the destructive-action confirmation.
Dispatch wiring follows in a later commit.
EOF
)"
```

---

## Task 8: Add `cmd_sync`

**Files:**
- Modify: `cli/forge-lite-db` — append `cmd_sync` after `cmd_import`

- [ ] **Step 1: Insert the function**

```bash
cmd_sync() {
    local source_domain="" target_domain="" assume_yes=false drop_enabled=true keep_dump=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)            assume_yes=true ;;
            --no-drop)        drop_enabled=false ;;
            --keep-dump=*)    keep_dump="${1#*=}" ;;
            -h|--help)
                cat <<'USAGE'
Usage: forge-lite-db sync <source-domain> <target-domain> [--yes] [--no-drop] [--keep-dump=PATH]
  Copies one site's database into another's on the same server.
  By default streams via pipe (no disk roundtrip); --keep-dump=PATH
  writes a gzipped dump first, then imports from it.
  --yes              Skip confirmation
  --no-drop          Merge into target instead of drop+recreate
  --keep-dump=PATH   Two-phase: dump source to PATH, then import from PATH
USAGE
                return 0
                ;;
            --*)              die "Unknown option: $1" ;;
            *)
                if   [[ -z "$source_domain" ]]; then source_domain="$1"
                elif [[ -z "$target_domain" ]]; then target_domain="$1"
                else die "Unexpected positional argument: $1"
                fi
                ;;
        esac
        shift
    done

    [[ -n "$source_domain" && -n "$target_domain" ]] || \
        die "Usage: forge-lite-db sync <source-domain> <target-domain> [--yes] [--no-drop] [--keep-dump=PATH]"
    [[ "$source_domain" != "$target_domain" ]] || die "Source and target must differ."

    local src_db tgt_db tgt_id root_pass
    src_db=$(resolve_site_db "$source_domain")
    tgt_db=$(resolve_site_db "$target_domain")
    tgt_id=$(sanitize_for_identifier "$target_domain")
    root_pass=$(resolve_mariadb_root_password)

    _db_exists "$root_pass" "$src_db" || die "Source DB '${src_db}' missing."
    _db_exists "$root_pass" "$tgt_db" || die "Target DB '${tgt_db}' missing — run 'forge-lite site add' first."

    local src_size tgt_size drop_msg
    src_size=$(_db_size_mb "$root_pass" "$src_db")
    tgt_size=$(_db_size_mb "$root_pass" "$tgt_db")
    if [[ "$drop_enabled" == true ]]; then
        drop_msg="DROP and recreate"
    else
        drop_msg="MERGE into (existing tables kept)"
    fi

    _confirm_destructive \
        "WARNING: This will ${drop_msg} database '${tgt_db}' (current size: ${tgt_size} MB).
Source '${source_domain}' DB '${src_db}' (${src_size} MB) will be copied.
Continue? [y/N] " "$assume_yes"

    if [[ "$drop_enabled" == true ]]; then
        mysql_safe "$root_pass" -e "DROP DATABASE IF EXISTS \`${tgt_db}\`;"
        mysql_safe "$root_pass" -e "CREATE DATABASE \`${tgt_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        _regrant_site_user "$root_pass" "$tgt_db" "$tgt_id"
    fi

    if [[ -n "$keep_dump" ]]; then
        log_info "Dumping ${src_db} → ${keep_dump}..."
        mysqldump_safe "$root_pass" --single-transaction --quick --lock-tables=false "$src_db" \
            | gzip > "$keep_dump"
        chown deployer:deployer "$keep_dump" 2>/dev/null || true
        log_info "Importing ${keep_dump} → ${tgt_db}..."
        gunzip -c "$keep_dump" | mysql_safe "$root_pass" "$tgt_db"
    else
        log_info "Streaming ${src_db} → ${tgt_db} (this may take a while)..."
        mysqldump_safe "$root_pass" --single-transaction --quick --lock-tables=false "$src_db" \
            | mysql_safe "$root_pass" "$tgt_db"
    fi

    log_ok "Sync complete: ${source_domain} → ${target_domain}"
}
```

Notes:
- The DROP+CREATE happens *before* the pipe. If the streaming pipe fails partway, the target DB is empty — a clean state from which the user can re-run `sync`.
- Streaming uses two `mysql_safe` invocations, each with its own ephemeral `--defaults-extra-file`. The two `mktemp` files do not collide (different temp paths). This is consistent with how `mysql_safe` was designed.
- `--keep-dump` keeps the dump after the run for archival/debugging — we do not auto-delete it. The path is up to the operator.

- [ ] **Step 2: Syntax check**

```bash
bash -n cli/forge-lite-db
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add cli/forge-lite-db
git commit -m "$(cat <<'EOF'
Add forge-lite-db sync subcommand

Copies one site's DB into another on the same host. Streaming pipe by
default; --keep-dump=PATH does a two-phase dump-to-disk-then-import for
archival. DROP+CREATE happens before the pipe so a mid-pipe failure
leaves the target empty (recoverable) rather than half-imported.
Dispatch wiring follows in a later commit.
EOF
)"
```

---

## Task 9: Add `cmd_shell` and `cmd_info`

**Files:**
- Modify: `cli/forge-lite-db` — append both functions after `cmd_sync`

- [ ] **Step 1: Insert `cmd_shell`**

```bash
cmd_shell() {
    local domain=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<'USAGE'
Usage: forge-lite-db shell <domain>
  Opens a mysql client connected to the site's database.
USAGE
                return 0
                ;;
            --*)
                die "Unknown option: $1" ;;
            *)
                if [[ -z "$domain" ]]; then domain="$1"
                else die "Unexpected positional argument: $1"
                fi
                ;;
        esac
        shift
    done

    [[ -n "$domain" ]] || die "Usage: forge-lite-db shell <domain>"

    local db_name root_pass
    db_name=$(resolve_site_db "$domain")
    root_pass=$(resolve_mariadb_root_password)

    _db_exists "$root_pass" "$db_name" || die "DB '${db_name}' missing in MariaDB."

    exec mysql_safe "$root_pass" --database "$db_name"
}
```

Notes: `exec` replaces the bash process. The user gets `mysql`'s exit code directly. `mysql_safe` is a function; `exec` works on functions only because we built it as a single command — but to be safe across both modes, we rely on `mysql_safe` being available in the current shell (it is, sourced from common.sh or defined inline). If `exec function-name` proves awkward in some shells, fall back to plain `mysql_safe "$root_pass" --database "$db_name"` — the script will still exit with mysql's status because there is no further code after this line. (Fallback note: keep `exec` unless verification fails.)

- [ ] **Step 2: Insert `cmd_info`**

```bash
cmd_info() {
    local domain=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<'USAGE'
Usage: forge-lite-db info <domain>
  Prints the site's database name, charset, collation, table count, and
  size on stdout (machine-friendly, no log_* prefixes).
USAGE
                return 0
                ;;
            --*)
                die "Unknown option: $1" ;;
            *)
                if [[ -z "$domain" ]]; then domain="$1"
                else die "Unexpected positional argument: $1"
                fi
                ;;
        esac
        shift
    done

    [[ -n "$domain" ]] || die "Usage: forge-lite-db info <domain>"

    local db_name root_pass
    db_name=$(resolve_site_db "$domain")
    root_pass=$(resolve_mariadb_root_password)

    _db_exists "$root_pass" "$db_name" || die "DB '${db_name}' missing in MariaDB."

    local result charset collation tables size_mb
    result=$(mysql_safe "$root_pass" -N -B -e "
        SELECT
            (SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name='${db_name}'),
            (SELECT default_collation_name FROM information_schema.schemata WHERE schema_name='${db_name}'),
            (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db_name}'),
            (SELECT IFNULL(ROUND(SUM(data_length+index_length)/1024/1024,1),0) FROM information_schema.tables WHERE table_schema='${db_name}');")
    IFS=$'\t' read -r charset collation tables size_mb <<<"$result"

    printf 'Database:  %s\n'   "$db_name"
    printf 'Charset:   %s\n'   "$charset"
    printf 'Collation: %s\n'   "$collation"
    printf 'Tables:    %s\n'   "$tables"
    printf 'Size:      %s MB\n' "$size_mb"
}
```

Notes:
- `mysql -N -B` outputs tab-separated, no headers, no border. `IFS=$'\t' read` parses it.
- Output goes to stdout (not via `log_*`) so it's machine-parseable.

- [ ] **Step 3: Syntax check**

```bash
bash -n cli/forge-lite-db
```

Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add cli/forge-lite-db
git commit -m "$(cat <<'EOF'
Add forge-lite-db shell and info subcommands

shell <domain> execs mysql connected to the site DB.
info <domain> prints name, charset, collation, table count, size on
stdout in a human-and-machine-friendly block. Dispatch wiring follows.
EOF
)"
```

---

## Task 10: Wire dispatch case + new `usage()`

**Files:**
- Modify: `cli/forge-lite-db` — `usage()` function and the bottom-of-file `case "$1"` block

- [ ] **Step 1: Replace `usage()`**

Find the existing `usage()` function and replace its `cat <<'USAGE' … USAGE` body so it reads:

```bash
usage() {
    cat <<'USAGE'
Usage: forge-lite-db <command> [args]

Commands (raw, name-based):
    create <name>                        Create database + user with auto-generated password
    drop <name> [--yes]                  Drop database and user
    list                                 List all databases
    backup <name> [path]                 Dump database to file
    restore <name> <file>                Restore database from SQL dump

Commands (domain-aware):
    dump <domain> [--output=PATH] [--no-gzip]
                                         Dump a site's database (default: gzipped)
    import <domain> <file> [--yes] [--no-drop]
                                         Import SQL/SQL.gz into a site's database
    sync <source-domain> <target-domain> [--yes] [--no-drop] [--keep-dump=PATH]
                                         Copy one site's database to another (same server)
    shell <domain>                       Open mysql client connected to a site's database
    info <domain>                        Show DB name, size, table count, charset, collation
USAGE
    exit 0
}
```

- [ ] **Step 2: Replace the dispatch `case`**

Find the `# Main dispatch` block at the end of the file and replace its `case "$1" in … esac` so it reads:

```bash
# Main dispatch
[[ $# -ge 1 ]] || usage

case "$1" in
    create)  shift; cmd_create  "${1:-}" ;;
    drop)    shift; cmd_drop    "${1:-}" "${2:-}" ;;
    list)    shift; cmd_list ;;
    backup)  shift; cmd_backup  "${1:-}" "${2:-}" ;;
    restore) shift; cmd_restore "${1:-}" "${2:-}" ;;
    dump)    shift; cmd_dump    "$@" ;;
    import)  shift; cmd_import  "$@" ;;
    sync)    shift; cmd_sync    "$@" ;;
    shell)   shift; cmd_shell   "$@" ;;
    info)    shift; cmd_info    "$@" ;;
    -h|--help) usage ;;
    *)       die "Unknown command: $1. Run with --help for usage." ;;
esac
```

Notes:
- Existing commands (`create|drop|list|backup|restore`) preserve their exact prior call shape: `cmd_X "${2:-}" …` becomes `shift; cmd_X "${1:-}" …` — same args, just reformatted for consistency. Behaviour identical (verified: `cmd_drop` still receives positional `--yes` via `${2:-}` which is now `${2:-}` of the post-shift `$@`).
- New commands (`dump|import|sync|shell|info`) use `"$@"` so the `--flag=value` parsing in each `cmd_*` sees the full remaining argv. This is the established `cli/forge-lite-auth` / `cli/forge-lite` pattern.

- [ ] **Step 3: Syntax check + smoke**

```bash
bash -n cli/forge-lite-db
./cli/forge-lite-db --help 2>&1 | head -20
```

Expected: `--help` prints the new usage block, no error. (If you don't have root locally, the script's `[[ $EUID -eq 0 ]]` guard will fire — that's fine, it proves the script parses and reaches the guard. As long as you see the guard's "must be run as root" message OR the usage block, the dispatch is sound.)

Actually, re-check `cli/forge-lite-db:65` — the `[[ $EUID -eq 0 ]] || die …` runs *before* dispatch. So `--help` on a non-root shell will fail at the EUID guard, not at dispatch. **Acceptance**: the script parses (`bash -n` is clean) AND, when run as root with `--help`, the new usage block prints.

If you can't get root in dev, run:

```bash
bash -n cli/forge-lite-db && grep -n 'dump\|import\|sync\|shell\|info' cli/forge-lite-db | head
```

Confirm the grep shows the new commands in `usage()` and in the `case`.

- [ ] **Step 4: Commit**

```bash
git add cli/forge-lite-db
git commit -m "$(cat <<'EOF'
Wire dispatch and usage for new domain-aware DB subcommands

usage() lists raw and domain-aware commands separately; case dispatch
shifts and forwards "$@" to the new cmd_* so their --flag parsing works.
Existing create/drop/list/backup/restore retain their exact call shapes
(no behavioural change).
EOF
)"
```

---

## Task 11: Update bash completion

**Files:**
- Modify: `cli/completions/forge-lite.bash:96-100` (the `db)` block)

- [ ] **Step 1: Replace the `db)` block**

Find:

```bash
        db)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "create drop list backup restore" -- "$cur"))
            fi
            ;;
```

Replace with:

```bash
        db)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "create drop list backup restore dump import sync shell info" -- "$cur"))
            elif [[ $cword -eq 3 ]]; then
                case "${words[2]}" in
                    dump|import|sync|shell|info|drop|backup|restore)
                        COMPREPLY=($(compgen -W "$(_forge_lite_domains)" -- "$cur"))
                        ;;
                esac
            elif [[ $cword -eq 4 ]]; then
                case "${words[2]}" in
                    sync)
                        COMPREPLY=($(compgen -W "$(_forge_lite_domains)" -- "$cur"))
                        ;;
                    import|restore)
                        compopt -o default
                        COMPREPLY=()
                        ;;
                    dump)
                        local flags="--output= --no-gzip"
                        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                        [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
                        ;;
                esac
            elif [[ $cword -ge 5 ]]; then
                case "${words[2]}" in
                    import)
                        local flags="--yes --no-drop"
                        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                        ;;
                    sync)
                        local flags="--yes --no-drop --keep-dump="
                        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
                        [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *= ]] && compopt -o nospace
                        ;;
                esac
            fi
            ;;
```

Notes:
- `compopt -o default` for `import|restore` cword==4 falls back to filename completion (so users can tab-complete dump files).
- `compopt -o nospace` after a `--flag=` keeps the cursor against the `=` so the user can type the value immediately. Pattern matches the existing `site)` block usage.
- The list of subcommands at `$cword -eq 2` matches the `usage()` text exactly. Keep them in sync if either is edited later.

- [ ] **Step 2: Syntax check**

```bash
bash -n cli/completions/forge-lite.bash
```

Expected: no output, exit 0.

- [ ] **Step 3: Smoke source**

```bash
bash -c 'source cli/completions/forge-lite.bash && declare -F _forge_lite_complete'
```

Expected: `_forge_lite_complete`

- [ ] **Step 4: Commit**

```bash
git add cli/completions/forge-lite.bash
git commit -m "$(cat <<'EOF'
Update bash completion for new db subcommands

Tab-completes dump/import/sync/shell/info, suggests known site domains
for the domain slot, falls back to filename completion for the file slot
of import/restore, and offers per-subcommand flag completion.
EOF
)"
```

---

## Task 12: Verification (gate before declaring done)

This is the verification-before-completion gate. None of the prior tasks should be considered "done" until every check below passes; if a check fails, fix and re-run before moving on.

- [ ] **Step 1: bash -n on every touched file**

```bash
bash -n lib/credentials.sh
bash -n lib/sites.sh
bash -n cli/forge-lite-db
bash -n cli/completions/forge-lite.bash
```

Expected: all four exit 0 with no output.

- [ ] **Step 2: shellcheck on every touched file**

```bash
shellcheck -x lib/credentials.sh
shellcheck -x lib/sites.sh
shellcheck -x cli/forge-lite-db
shellcheck -x cli/completions/forge-lite.bash
```

Expected: no findings on any file. If shellcheck warns about unsourced lib functions (`SC1091`, `SC2154`), they are stylistic — the file is sourced into a context that has them. Suppress with `# shellcheck disable=SCxxxx` only if the warning is incorrect; if it is correct, fix the underlying issue.

- [ ] **Step 3: --help smoke on every new subcommand**

This requires either a system with MariaDB / a credentials file, or just trusting `bash -n` for the subcommand `--help` paths since each `cmd_*` returns from `--help` *before* it calls `resolve_mariadb_root_password`. Verify by reading the code:

```bash
grep -nE '\-h\|--help\)|resolve_mariadb_root_password' cli/forge-lite-db
```

Confirm that for every `cmd_*` (dump, import, sync, shell, info), the `-h|--help)` case appears in argument parsing **before** any line that calls `resolve_mariadb_root_password`. If the order is wrong, the user gets a credential prompt before getting help — bad UX.

If you have a target host (or a `sudo`-able dev container), do the live check too:

```bash
sudo ./cli/forge-lite-db dump   --help
sudo ./cli/forge-lite-db import --help
sudo ./cli/forge-lite-db sync   --help
sudo ./cli/forge-lite-db shell  --help
sudo ./cli/forge-lite-db info   --help
sudo ./cli/forge-lite-db        --help
```

Each should print its usage block and exit 0. None should prompt for a password.

- [ ] **Step 4: Argument-parsing negative paths (each subcommand)**

Either reason about by reading the code, or — if you can run as root locally — run:

```bash
sudo ./cli/forge-lite-db dump   --bogus
sudo ./cli/forge-lite-db import --bogus
sudo ./cli/forge-lite-db sync   --bogus
sudo ./cli/forge-lite-db shell  --bogus
sudo ./cli/forge-lite-db info   --bogus
```

Expected: each dies with `Unknown option: --bogus`, exit 1.

- [ ] **Step 5: Cross-grep for `$ROOT_PASS`**

```bash
grep -n 'ROOT_PASS' cli/forge-lite-db lib/credentials.sh lib/sites.sh
```

Expected: no output. (Lower-case `root_pass` is the new convention.)

- [ ] **Step 6: Confirm no untouched files were modified**

```bash
git diff --stat main..HEAD -- cli/forge-lite sites/add-site.sh server/modules/mariadb.sh lib/common.sh lib/validation.sh lib/templates.sh
```

Expected: no output (no changes to those files).

```bash
git diff --stat main..HEAD
```

Expected: only the four files listed in "File Structure" above appear.

- [ ] **Step 7: Final acceptance criteria checklist**

Mark each as ✓ before declaring the feature complete:

- ✓ `lib/credentials.sh` exposes `resolve_mariadb_root_password` (function exists, sources cleanly).
- ✓ `lib/sites.sh` exists, `set -euo pipefail`, defines `resolve_site_db`, sources cleanly.
- ✓ `cli/forge-lite-db --help` no longer requires `/root/.forge-lite-credentials`.
- ✓ Existing `create/drop/list/backup/restore` invocation shapes unchanged from the user's perspective.
- ✓ `dump`, `import`, `sync`, `shell`, `info` are each parseable, advertise their own `--help`, reject unknown flags, and validate domain + file/source-target inputs before touching MariaDB.
- ✓ `_regrant_site_user` dies *before* mutating if the site DB password is missing.
- ✓ `sync` DROP+CREATE happens before the streaming pipe (target empty on pipe failure, not half-imported).
- ✓ Bash completion advertises all five new subcommands and offers domain / file / flag completions.
- ✓ All four touched files pass `bash -n` and `shellcheck -x` cleanly.
- ✓ No tests added (per agreed test policy).
- ✓ No files outside the four-file scope were modified.

If every box is checked, declare the feature complete and post the commit list to the user.

---

## Self-Review Note

Spec coverage cross-check (run after writing the plan):

| Spec section | Plan task |
|---|---|
| §1 `resolve_mariadb_root_password` | Task 1 |
| §2 `lib/sites.sh` / `resolve_site_db` | Task 2 |
| §3 lazy credential loading | Tasks 3, 4 |
| §3 source resolution (validation, sites) | Task 3 |
| §3 argument parsing pattern | Tasks 6–9 (each cmd_*) |
| §3 `_confirm_destructive` | Task 5 |
| §3 `_db_size_mb` / `_db_exists` | Task 5 |
| §3 `_regrant_site_user` | Task 5 |
| §4 `dump` | Task 6 |
| §4 `import` | Task 7 |
| §4 `sync` | Task 8 |
| §4 `shell` | Task 9 |
| §4 `info` | Task 9 |
| §5 bash completion | Task 11 |
| §6 `usage()` | Task 10 |
| §7 edge cases | covered across cmd_* impls; verification step 4 exercises them |
| Verification §1–7 (bash -n, shellcheck, smoke, negative paths) | Task 12 |
| Out-of-scope items | excluded from plan |

No placeholders. No "TBD". Every step shows the actual code or command. No spec requirement without a corresponding task.
