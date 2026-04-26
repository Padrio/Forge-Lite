# forge-lite Database CLI — Domain-aware Dump/Import + DB Sync

**Date:** 2026-04-26
**Status:** Draft
**Scope:** `cli/forge-lite-db`, `lib/credentials.sh`, `lib/sites.sh` (new), `cli/completions/forge-lite.bash`

---

## Problem

`forge-lite-db` exposes raw database operations (`create`, `drop`, `list`, `backup`, `restore`) keyed on database names. Operators have to look up the database name in `/etc/forge-lite/<domain>.conf`, the root password in `/root/.forge-lite-credentials`, and pipe them together themselves. There is no domain-aware path for the most common operations:

- Dump a site's database without typing names or passwords.
- Import a SQL/SQL.gz dump into a site's database with a clean reset.
- Copy one site's database into another site's database on the **same server** (typical for Prod → Staging refresh).
- Open a `mysql` client connected to a site's database.
- Inspect a site's database (size, table count, charset).

Three additional friction points exist in the current code:

1. `cli/forge-lite-db` reads `MARIADB_ROOT_PASSWORD` at script-init via `get_credential`. If the credential file is missing, even `--help` dies. Credential resolution must be lazy and tolerate a missing store by prompting interactively.
2. The credential file (`/root/.forge-lite-credentials`) may be missing on hand-managed servers or have wrong permissions. The CLI currently has no recovery path.
3. Site-config resolution (`/etc/forge-lite/<domain>.conf` → keys) is duplicated inline across `cli/forge-lite-env`, `cli/forge-lite-ssl`, `cli/forge-lite-auth`. A shared helper avoids reinventing it for the new subcommands.

## Decision

Extend `cli/forge-lite-db` with five new domain-aware subcommands (`dump`, `import`, `sync`, `shell`, `info`), introduce a shared `lib/sites.sh` helper for site-config resolution, and add `resolve_mariadb_root_password()` to `lib/credentials.sh` for interactive fallback. Existing subcommands keep their signatures and behaviour; their credential loading becomes lazy as a side benefit. No tests are written in this scope (none exist project-wide; a coordinated test strategy is deferred).

---

## Design

### 1. `lib/credentials.sh` — `resolve_mariadb_root_password()`

New function, exported on stdout. Logging on stderr.

```
resolve_mariadb_root_password()
  Returns: MariaDB root password on stdout.
  Side effects: may prompt the user, may write to CREDENTIALS_FILE.

  1. If CREDENTIALS_FILE exists:
       - chmod 600 CREDENTIALS_FILE              (idempotent perms fix)
       - try get_credential MARIADB_ROOT_PASSWORD
       - on success: validate via mysql_safe "$pw" -e 'SELECT 1' >/dev/null
         - on success: echo "$pw"; return 0
         - on failure: log_warn "stored password rejected"; fall through to prompt
  2. log_warn "MariaDB root password not available — prompting"
     read -rsp "MariaDB root password: " pw; echo >&2
  3. Validate via mysql_safe "$pw" -e 'SELECT 1' >/dev/null || die "MariaDB authentication failed"
  4. If we reached the prompt path:
       read -rp "Save to ${CREDENTIALS_FILE}? [y/N] " ans
       [[ "$ans" =~ ^[Yy]$ ]] && store_credential MARIADB_ROOT_PASSWORD "$pw"
  5. echo "$pw"
```

Documented header comment matches the style of `get_credential` / `store_credential`.

### 2. `lib/sites.sh` (new file) — `resolve_site_db()`

A new shared library for site-config resolution. Holds one function for now; designed to grow as sibling CLIs (`forge-lite-env`, `forge-lite-ssl`, `forge-lite-auth`) migrate off their inlined duplicates in a future cleanup. **Not** part of this scope.

```bash
#!/usr/bin/env bash
# forge-lite/lib/sites.sh — Site-config resolution helpers
set -euo pipefail

SITE_CONFIG_DIR="${SITE_CONFIG_DIR:-/etc/forge-lite}"

# resolve_site_db <domain>
#   Validates domain, resolves site config, returns DB_NAME on stdout.
#   Dies with a helpful message if the site or DB_NAME key is missing.
resolve_site_db() {
    local domain="$1"
    [[ -n "$domain" ]] || die "Domain required."
    validate_domain "$domain"

    local conf="${SITE_CONFIG_DIR}/${domain}.conf"
    if [[ ! -f "$conf" ]]; then
        local available
        available=$(ls "${SITE_CONFIG_DIR}"/*.conf 2>/dev/null \
            | xargs -n1 basename 2>/dev/null \
            | sed 's/\.conf$//' | paste -sd, -)
        die "Site '${domain}' not found. Available: ${available:-<none>}"
    fi

    local db_name
    db_name=$(
        # subshell isolates the source
        # shellcheck disable=SC1090
        source "$conf"
        printf '%s' "${DB_NAME:-}"
    )
    [[ -n "$db_name" ]] || die "Site config '${conf}' lacks DB_NAME — old or manually edited."
    echo "$db_name"
}
```

`SITE_CONFIG_DIR` is overridable for hypothetical future testing; defaults to `/etc/forge-lite`.

### 3. `cli/forge-lite-db` — Rewrite Highlights

#### Lazy credential loading

Remove the script-init `ROOT_PASS=$(get_credential ...)` line. Each `cmd_*` that needs it calls:

```bash
local root_pass
root_pass=$(resolve_mariadb_root_password)
```

at its top. Existing `create|drop|list|backup|restore` get the same treatment for consistency. UX impact: identical for users with a valid credential file; resilient (interactive prompt) for users without; `--help` works without any credentials file.

#### Source resolution

Source `lib/sites.sh` and `lib/validation.sh` alongside `lib/common.sh` and `lib/credentials.sh` when the lib directory is detected. Keep the existing minimal-fallback block for installed-CLI mode, augmented with inline copies of `resolve_mariadb_root_password` and `resolve_site_db` so the CLI works even without `lib/` on disk (mirrors the current pattern used for `mysql_safe`/`mysqldump_safe`).

#### Argument parsing

All new subcommands use `--flag=value` style per CLAUDE.md §3.9:

```bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output=*)     output="${1#*=}" ;;
        --no-gzip)      gzip_enabled=false ;;
        --yes)          assume_yes=true ;;
        --no-drop)      drop_enabled=false ;;
        --keep-dump=*)  keep_dump_path="${1#*=}" ;;
        -h|--help)      sub_usage; return 0 ;;
        --*)            die "Unknown option: $1" ;;
        *)              positional+=("$1") ;;
    esac
    shift
done
```

#### Confirmation helper

A single helper used by `import`, `sync`, and `drop` for consistency:

```bash
_confirm_destructive() {
    local prompt="$1" assume_yes="$2"
    [[ "$assume_yes" == "true" ]] && return 0
    read -rp "$prompt" ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }
}
```

#### DB size helper

```bash
_db_size_mb() {
    local root_pass="$1" db_name="$2"
    mysql_safe "$root_pass" -N -B -e \
        "SELECT IFNULL(ROUND(SUM(data_length+index_length)/1024/1024,1),0)
         FROM information_schema.tables WHERE table_schema='${db_name}';"
}
```

Returns a number with one decimal (MB). `0` if DB has no tables or doesn't exist.

#### DB exists helper

```bash
_db_exists() {
    local root_pass="$1" db_name="$2"
    mysql_safe "$root_pass" -N -B -e \
        "SELECT 1 FROM information_schema.schemata WHERE schema_name='${db_name}';" \
        | grep -q '^1$'
}
```

#### Re-grant helper

After `DROP DATABASE` + `CREATE DATABASE` we **must re-grant the site user** on the recreated database, otherwise the live site loses access. The site user's password lives in `DB_${SITE_ID}_PASSWORD` in the credentials file (set by `add-site.sh`).

```bash
_regrant_site_user() {
    local root_pass="$1" db_name="$2" site_id="$3"
    local site_pw
    site_pw=$(get_credential "DB_${site_id}_PASSWORD") || \
        die "Site password DB_${site_id}_PASSWORD not in credentials. Site DB user grants will be missing — refusing to leave broken state."
    mysql_safe "$root_pass" <<MYSQL
CREATE USER IF NOT EXISTS '${site_id}'@'localhost' IDENTIFIED BY '${site_pw}';
ALTER USER '${site_id}'@'localhost' IDENTIFIED BY '${site_pw}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${site_id}'@'localhost';
FLUSH PRIVILEGES;
MYSQL
}
```

`site_id` is derived via `sanitize_for_identifier "$domain"` (matches `add-site.sh` convention: `DB_NAME == DB_USER == SITE_ID`).

### 4. New Subcommand Specifications

#### `dump <domain> [--output=PATH] [--no-gzip]`

```
1. db_name=$(resolve_site_db "$domain")
2. site_id=$(sanitize_for_identifier "$domain")
3. root_pass=$(resolve_mariadb_root_password)
4. _db_exists "$root_pass" "$db_name" || die "DB '${db_name}' missing in MariaDB"
5. backup_dir=/home/deployer/backups
   mkdir -p "$backup_dir"; chown deployer:deployer "$backup_dir"
6. timestamp=$(date +%Y%m%d_%H%M%S)
7. ext=".sql"; [[ $gzip_enabled == true ]] && ext=".sql.gz"
8. output=${output:-${backup_dir}/${site_id}_${timestamp}${ext}}
9. log_info "Dumping ${db_name} → ${output} (this may take a while)..."
10. if gzip_enabled:
       mysqldump_safe "$root_pass" --single-transaction --quick --lock-tables=false "$db_name" \
         | gzip > "$output"
    else:
       mysqldump_safe "$root_pass" --single-transaction --quick --lock-tables=false "$db_name" \
         > "$output"
11. chown deployer:deployer "$output"
12. log_ok "Dump complete (size: $(du -h "$output" | cut -f1))"
13. echo "$output"     # stdout: machine-readable path
```

`set -o pipefail` (active globally) catches mysqldump failures even through the `gzip` pipe.

#### `import <domain> <file> [--yes] [--no-drop]`

```
1. [[ -n "$file" ]] || die "Usage: forge-lite db import <domain> <file>"
2. [[ -r "$file" ]] || die "File not readable: ${file}"
3. db_name=$(resolve_site_db "$domain")
4. site_id=$(sanitize_for_identifier "$domain")
5. root_pass=$(resolve_mariadb_root_password)
6. is_gzip=false
   if [[ "$file" == *.gz ]]; then
       gunzip -t "$file" 2>/dev/null || die "Corrupt gzip: ${file}"
       is_gzip=true
   fi
7. current_size=$(_db_size_mb "$root_pass" "$db_name")
8. file_size=$(du -h "$file" | cut -f1)
9. drop_msg="DROP and recreate"
   [[ "$drop_enabled" == false ]] && drop_msg="MERGE into (existing tables kept)"
10. _confirm_destructive \
       "WARNING: This will ${drop_msg} database '${db_name}' (current size: ${current_size} MB).
    Source file '${file}' (${file_size}) will be imported.
    Continue? [y/N] " "$assume_yes"
11. if drop_enabled:
       mysql_safe "$root_pass" -e "DROP DATABASE IF EXISTS \`${db_name}\`;"
       mysql_safe "$root_pass" -e "CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
       _regrant_site_user "$root_pass" "$db_name" "$site_id"
12. log_info "Importing ${file} → ${db_name} (this may take a while)..."
13. if is_gzip:
       gunzip -c "$file" | mysql_safe "$root_pass" "$db_name"
    else:
       mysql_safe "$root_pass" "$db_name" < "$file"
14. log_ok "Import complete"
```

#### `sync <source-domain> <target-domain> [--yes] [--no-drop] [--keep-dump=PATH]`

```
1. [[ "$source" != "$target" ]] || die "Source and target must differ."
2. src_db=$(resolve_site_db "$source")
   tgt_db=$(resolve_site_db "$target")
   tgt_id=$(sanitize_for_identifier "$target")
3. root_pass=$(resolve_mariadb_root_password)
4. _db_exists "$root_pass" "$src_db" || die "Source DB '${src_db}' missing"
5. _db_exists "$root_pass" "$tgt_db" || die "Target DB '${tgt_db}' missing — run add-site first"
6. src_size=$(_db_size_mb "$root_pass" "$src_db")
   tgt_size=$(_db_size_mb "$root_pass" "$tgt_db")
7. drop_msg="DROP and recreate"
   [[ "$drop_enabled" == false ]] && drop_msg="MERGE into (existing tables kept)"
8. _confirm_destructive \
       "WARNING: This will ${drop_msg} database '${tgt_db}' (current size: ${tgt_size} MB).
    Source '${source}' DB '${src_db}' (${src_size} MB) will be copied.
    Continue? [y/N] " "$assume_yes"
9. if drop_enabled:
       mysql_safe "$root_pass" -e "DROP DATABASE IF EXISTS \`${tgt_db}\`;"
       mysql_safe "$root_pass" -e "CREATE DATABASE \`${tgt_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
       _regrant_site_user "$root_pass" "$tgt_db" "$tgt_id"
10. if [[ -n "$keep_dump_path" ]]; then
        # Two-phase: dump-to-disk, then import-from-disk
        log_info "Dumping ${src_db} → ${keep_dump_path}..."
        mysqldump_safe "$root_pass" --single-transaction --quick --lock-tables=false "$src_db" \
          | gzip > "$keep_dump_path"
        chown deployer:deployer "$keep_dump_path"
        log_info "Importing ${keep_dump_path} → ${tgt_db}..."
        gunzip -c "$keep_dump_path" | mysql_safe "$root_pass" "$tgt_db"
    else:
        # Streaming pipe: no disk roundtrip
        log_info "Streaming ${src_db} → ${tgt_db} (this may take a while)..."
        mysqldump_safe "$root_pass" --single-transaction --quick --lock-tables=false "$src_db" \
          | mysql_safe "$root_pass" "$tgt_db"
    fi
11. log_ok "Sync complete: ${source} → ${target}"
```

`set -o pipefail` propagates errors from either side of the pipe. The DROP+CREATE happens **before** the pipe — if the pipe fails partway, the target is empty (consistent state), not half-imported.

#### `shell <domain>`

```
1. db_name=$(resolve_site_db "$domain")
2. root_pass=$(resolve_mariadb_root_password)
3. _db_exists "$root_pass" "$db_name" || die "DB '${db_name}' missing in MariaDB"
4. exec mysql_safe "$root_pass" --database "$db_name"
```

`exec` replaces the shell so the user gets a clean exit code from `mysql`. `mysql_safe` already uses `--defaults-extra-file` so the password is never in `ps`.

#### `info <domain>`

Read-only. Output to stdout (no log_* prefixes — machine-friendly).

```
1. db_name=$(resolve_site_db "$domain")
2. root_pass=$(resolve_mariadb_root_password)
3. _db_exists "$root_pass" "$db_name" || die "DB '${db_name}' missing in MariaDB"
4. Single batched query:
       SELECT
         '${db_name}' AS db,
         (SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name='${db_name}'),
         (SELECT default_collation_name FROM information_schema.schemata WHERE schema_name='${db_name}'),
         (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db_name}'),
         (SELECT IFNULL(ROUND(SUM(data_length+index_length)/1024/1024,1),0) FROM information_schema.tables WHERE table_schema='${db_name}');
5. Print:
       Database: example_com
       Charset:  utf8mb4
       Collation: utf8mb4_unicode_ci
       Tables:   42
       Size:     142.3 MB
```

### 5. `cli/completions/forge-lite.bash`

Replace the existing `db)` block:

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

`compopt -o default` falls back to the shell's filename completion for `import` / `restore` file arguments.

### 6. `usage()` in `forge-lite-db`

Replace with:

```
Usage: forge-lite-db <command> [args]

Commands:
    create <name>                        Create database + user with auto-generated password
    drop <name> [--yes]                  Drop database and user
    list                                 List all databases
    backup <name> [path]                 Dump database to file (raw, name-based)
    restore <name> <file>                Restore database from SQL dump (raw, name-based)

  Domain-aware:
    dump <domain> [--output=PATH] [--no-gzip]
                                         Dump a site's database (default: gzipped)
    import <domain> <file> [--yes] [--no-drop]
                                         Import SQL/SQL.gz into a site's database
    sync <source-domain> <target-domain> [--yes] [--no-drop] [--keep-dump=PATH]
                                         Copy one site's database to another (same server)
    shell <domain>                       Open mysql client connected to a site's database
    info <domain>                        Show DB name, size, table count, charset, collation
```

---

## Edge Cases (Coverage Map)

| Case | Handler |
|---|---|
| Site config exists, DB missing in MariaDB | `_db_exists` check → `die` |
| Backup file unreadable / missing | `[[ -r "$file" ]]` early check |
| Corrupt gzip file | `gunzip -t` upfront → `die` |
| `source == target` for sync | Explicit equality check → `die` |
| Site config exists, `DB_NAME` key missing | `resolve_site_db` → `die` |
| Credentials file wrong permissions | `chmod 600` (silent, idempotent) |
| Backup directory missing | `mkdir -p` + `chown deployer:deployer` |
| User not root | Existing `[[ $EUID -eq 0 ]] || die` |
| Empty domain string | `validate_domain` |
| Pipe failure during sync (streaming) | `set -o pipefail` + DROP+CREATE before pipe → target left empty (clean re-run possible) |
| Site DB password missing for re-grant | `_regrant_site_user` `die`s before mutating — refuses to leave grants broken |
| Stored MariaDB password no longer valid | `resolve_mariadb_root_password` retries via prompt |

---

## Backwards Compatibility

- `create`, `drop`, `list`, `backup`, `restore` keep their current synopses, output formats, and exit codes.
- Their **only** behavioural change: credential resolution becomes lazy, so `forge-lite-db --help` no longer requires `/root/.forge-lite-credentials`. Users with a valid credentials file see no UX difference.
- `cmd_drop`'s positional `--yes` argument (a non-idiomatic wart vs. CLAUDE.md §3.9) is preserved unchanged. Cleanup deferred to a separate change.
- `/etc/forge-lite/<domain>.conf` format is unchanged. No new keys required.
- The credentials file format is unchanged. `MARIADB_ROOT_PASSWORD` is the existing key.
- `cli/forge-lite` already dispatches `db` via `exec forge-lite-db "$@"` (verified). No change.
- `cmd_update()` already installs `forge-lite-db` and the bash completion. No change.
- `lib/sites.sh` is a new file; it won't disturb existing sources because nothing else sources it yet.

---

## Verification

In place of automated tests (none exist project-wide; deferred for project-wide planning):

1. **Syntax**: `bash -n cli/forge-lite-db lib/credentials.sh lib/sites.sh cli/completions/forge-lite.bash`
2. **Lint**: `shellcheck -x cli/forge-lite-db lib/credentials.sh lib/sites.sh` (CI runs this on every PR — see `.github/workflows/lint.yml`)
3. **Help smoke**: `forge-lite db --help`, then each new subcommand `--help` (`dump`, `import`, `sync`, `shell`, `info`)
4. **Argument parsing smoke**: bogus flag for each subcommand → expect "Unknown option: ..."
5. **Negative paths**:
   - `forge-lite db dump nonexistent.com` → "Site 'nonexistent.com' not found. Available: ..."
   - `forge-lite db sync prod.com prod.com` → "Source and target must differ."
   - `forge-lite db import prod.com /no/such/file` → "File not readable: ..."
   - `forge-lite db import prod.com /tmp/corrupt.sql.gz` (truncated) → "Corrupt gzip: ..."
6. **Optional VM round-trip** (recommended before real-world use, not blocking for merge):
   - Provision a fresh server, add two sites, populate one with sample data, then `dump`, `import`, `sync`, `shell` (interactive sanity check), `info` — verify the target site stays functional (login, queries) afterwards.
7. **Password not in `ps`**: while a `dump` of a large DB runs, `ps auxf | grep -E 'mysql|mysqldump'` must not show the password. Existing `mysql_safe`/`mysqldump_safe` already enforces this via `--defaults-extra-file`.

---

## Out of Scope

Per the original brief:
- Cross-server DB sync (over SSH to another host)
- Incremental / differential backups
- Cron jobs for scheduled syncs
- DB user management beyond `create`/`drop` (grant editing, password rotation)
- Schema-only or data-only dumps
- Migration between MariaDB and MySQL/Postgres
- Anonymisation of PII during sync

Plus, deferred from this scope:
- Migrating `forge-lite-env`, `forge-lite-ssl`, `forge-lite-auth` to use `lib/sites.sh` (those CLIs each have their own inlined `resolve_*` helper today; the migration is a mechanical refactor across three files but not required for this feature).
- Cleaning up `cmd_drop`'s positional `--yes` argument to the idiomatic `--flag` form.
- Project-wide test infrastructure.

---

## Files Touched

**Modified:**
- `cli/forge-lite-db` — lazy credential loading, source new libs, add 5 subcommands + helpers + `usage()`
- `lib/credentials.sh` — add `resolve_mariadb_root_password()`
- `cli/completions/forge-lite.bash` — extend the `db)` block

**Created:**
- `lib/sites.sh` — new shared library, holds `resolve_site_db()`

**Verified unchanged:**
- `cli/forge-lite` (dispatcher already correct)
- `cli/forge-lite cmd_update()` (tools list already includes `forge-lite-db`)

**Untouched:**
- `sites/add-site.sh`, `server/modules/mariadb.sh` (per brief)
