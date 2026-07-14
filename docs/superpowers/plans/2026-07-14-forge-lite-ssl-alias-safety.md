# forge-lite SSL and Alias Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make forge-lite resolve CNAME-backed DNS and configured aliases correctly while keeping certificate lineage, SAN coverage, site config, and the live NGINX vhost consistent.

**Architecture:** `lib/sites.sh` owns reusable primary-site resolution. `forge-lite-ssl` resolves the desired site/name set, filters final DNS addresses, operates on the primary Certbot lineage, verifies SAN coverage, and activates the SSL vhost transactionally. `forge-lite site alias` stores the desired alias temporarily and delegates SSL expansion before the alias can enter a live SSL vhost, rolling back the config on failure.

**Tech Stack:** Bash 3.2-compatible shell code, standard Unix tools, mocked `dig`/`certbot`/`openssl`/`nginx`/`systemctl`, NGINX templates, Certbot

## Global Constraints

- Make no production-server changes and request no real Let's Encrypt certificates.
- Keep the installed CLI fallback working when project libraries are unavailable relative to the executable.
- Preserve all existing functions and unrelated working-tree changes.
- Use the primary domain as the Certbot certificate name and NGINX certificate lineage.
- Reload NGINX only after successful certificate-name and configuration validation.
- Run Bash syntax checks, ShellCheck when available, all new/relevant tests, and `git diff --check`.
- Commit and push the completed changes directly on `main`, as explicitly requested.

---

### Task 1: Sourceable CLIs and reusable site resolution

**Files:**
- Modify: `lib/sites.sh`
- Modify: `cli/forge-lite-ssl`
- Modify: `cli/forge-lite`
- Create: `tests/test_ssl_alias.sh`

**Interfaces:**
- Produces: `resolve_site REQUESTED_DOMAIN`, which prints `PRIMARY_DOMAIN<TAB>CONFIG_PATH` and fails for zero or multiple matches.
- Produces: source-safe CLI files whose root checks and dispatch execute only when the file is run directly.
- Consumes: `SITE_CONFIG_DIR`, `die`, and `validate_domain` from the caller environment.

- [ ] **Step 1: Write failing site-resolution and source-safety tests**

Create a dependency-free Bash harness with temporary directories and assertions.
Cover a direct config, an exact unique alias, an unknown domain, a duplicate
alias, and sourcing both CLI files as a non-root test process.

```bash
test_direct_site_resolution() {
    write_site example.com "www.example.com"
    local resolved
    resolved="$(resolve_site example.com)"
    assert_equals "example.com${TAB}${SITE_CONFIG_DIR}/example.com.conf" "$resolved"
}

test_unique_alias_resolution() {
    write_site example.com "www.example.com"
    local resolved
    resolved="$(resolve_site www.example.com)"
    assert_equals "example.com${TAB}${SITE_CONFIG_DIR}/example.com.conf" "$resolved"
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `bash tests/test_ssl_alias.sh site_resolution source_safety`

Expected: failures because `resolve_site` does not exist and both CLIs execute
their root guard/dispatch while being sourced.

- [ ] **Step 3: Implement exact site resolution and direct-execution guards**

Add a safe config-value reader and resolver to `lib/sites.sh`:

```bash
resolve_site() {
    local requested_domain="${1:-}" direct_conf primary aliases conf alias
    local -a matches=()
    validate_domain "$requested_domain"
    direct_conf="${SITE_CONFIG_DIR}/${requested_domain}.conf"
    if [[ -f "$direct_conf" ]]; then
        primary="$(_site_config_value "$direct_conf" DOMAIN)"
        printf '%s\t%s' "${primary:-$requested_domain}" "$direct_conf"
        return 0
    fi
    # Compare every comma-separated alias exactly; fail on 0 or >1 matches.
}
```

Move each CLI's root check and final case dispatch into `main()` and invoke it
only under `[[ "${BASH_SOURCE[0]}" == "$0" ]]`. Source `validation.sh` and
`sites.sh` when available, with equivalent validation/resolution fallbacks for
standalone installed use.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `bash tests/test_ssl_alias.sh site_resolution source_safety`

Expected: all direct, unique-alias, unknown, duplicate, and source-safety cases pass.

### Task 2: Final-address DNS preflight

**Files:**
- Modify: `cli/forge-lite-ssl`
- Modify: `tests/test_ssl_alias.sh`

**Interfaces:**
- Produces: `_resolve_dns_addresses DOMAIN TYPE`, newline-separated final IPs only.
- Produces: `_check_dns_records DOMAIN SERVER_IPV4 SERVER_IPV6`, warning/info output with all final addresses.
- Consumes: `dig`, `log_warn`, and `log_info`.

- [ ] **Step 1: Add failing DNS behavior tests**

Add a PATH fake for `dig` and fixtures for direct IPv4, CNAME plus IPv4, CNAME
plus IPv6, multiple A/AAAA records with one match, all-address mismatch, and a
CNAME without a final address.

```bash
test_cname_ipv4_is_not_a_mismatch() {
    dns_fixture www.example.com A $'example.com.\n5.75.157.10'
    local output
    output="$(_check_dns_records www.example.com 5.75.157.10 "" 2>&1)"
    assert_not_contains "$output" "[WARN]"
}

test_multiple_addresses_accept_any_match() {
    dns_fixture example.com A $'192.0.2.1\n5.75.157.10'
    dns_fixture example.com AAAA $'2001:db8::1\n2a01:4f8:1c1c:29b8::1'
    local output
    output="$(_check_dns_records example.com 5.75.157.10 2a01:4f8:1c1c:29b8::1 2>&1)"
    assert_not_contains "$output" "[WARN]"
}
```

- [ ] **Step 2: Run DNS tests and verify RED**

Run: `bash tests/test_ssl_alias.sh dns`

Expected: failures because the DNS helper functions do not exist.

- [ ] **Step 3: Implement filtering, any-match comparison, and diagnostics**

Filter A output with IPv4 syntax and AAAA output with IPv6 syntax. Retain every
final address, compare each against the server address, format mismatches as a
comma-separated list, and treat a CNAME-only result as missing address data.

- [ ] **Step 4: Run DNS tests and verify GREEN**

Run: `bash tests/test_ssl_alias.sh dns`

Expected: all six DNS scenarios pass without treating a CNAME target as an IP.

### Task 3: Primary certificate lineage, SAN verification, and vhost transaction

**Files:**
- Modify: `cli/forge-lite-ssl`
- Modify: `tests/test_ssl_alias.sh`

**Interfaces:**
- Produces: `_verify_certificate_names CERT_FILE DOMAIN...` using `openssl x509 -checkhost`.
- Produces: `_activate_ssl_vhost PRIMARY CONFIG_PATH`, which restores the old vhost on NGINX validation/reload failure.
- Consumes: `LE_LIVE_DIR`, `NGINX_SITES_AVAILABLE`, `FORGE_LITE_TEMPLATES`, and resolved site config values.

- [ ] **Step 1: Add failing SSL issue tests**

Mock Certbot, OpenSSL, NGINX, and systemctl. Assert that an alias invocation
logs primary-site resolution, calls Certbot with `--cert-name example.com` and
all `-d` names, reads `LE_LIVE_DIR/example.com/fullchain.pem`, renders the
primary lineage, reports `ready` rather than `issued`, and performs no NGINX
reload when any expected hostname fails certificate validation.

```bash
test_issue_uses_primary_lineage_and_all_names() {
    run_issue www.example.com
    assert_file_contains "$CERTBOT_LOG" "--cert-name example.com"
    assert_file_contains "$CERTBOT_LOG" "-d example.com"
    assert_file_contains "$CERTBOT_LOG" "-d www.example.com"
    assert_file_contains "$NGINX_VHOST" "/etc/letsencrypt/live/example.com/fullchain.pem"
}

test_missing_san_prevents_nginx_reload() {
    OPENSSL_MISSING_HOST=www.example.com run_issue_expect_failure example.com
    assert_file_empty "$SYSTEMCTL_LOG"
}
```

- [ ] **Step 2: Run SSL tests and verify RED**

Run: `bash tests/test_ssl_alias.sh ssl_issue`

Expected: failures from the missing `--cert-name`, alias resolution, SAN checks,
transactional activation, and accurate status message.

- [ ] **Step 3: Implement the desired-state SSL flow**

Resolve the requested domain before DNS or Certbot, read and validate all
configured aliases, and build unique certificate arguments:

```bash
certbot certonly --nginx \
    --cert-name "$primary_domain" \
    "${certbot_domains[@]}" \
    --non-interactive --agree-tos --expand \
    --register-unsafely-without-email
```

Verify the primary full chain against every requested name. Render a temporary
SSL vhost, preserve the old target, install and test the candidate, restore on
failure, reload only on success, then persist `SSL=true` and report
`SSL certificate ready for <primary>`.

- [ ] **Step 4: Run SSL tests and verify GREEN**

Run: `bash tests/test_ssl_alias.sh ssl_issue`

Expected: primary lineage, complete SAN set, no false issuance claim, and safe
reload ordering all pass.

### Task 4: Transactional SSL alias changes

**Files:**
- Modify: `cli/forge-lite`
- Modify: `tests/test_ssl_alias.sh`

**Interfaces:**
- Consumes: `resolve_site`, `validate_domain`, `forge-lite-ssl issue PRIMARY`, and current `SSL`/`ALIASES` config values.
- Produces: alias commands that accept primary or known alias input and never activate an uncovered SSL name.

- [ ] **Step 1: Add failing alias transaction tests**

Mock `forge-lite-ssl` so it inspects the vhost at call time. For SSL sites,
assert the alias is already in desired config but not yet in `server_name` when
SSL expansion starts. On mocked SSL failure, assert that `ALIASES` and the vhost
are restored and no success is logged. Also cover successful known-alias input.

- [ ] **Step 2: Run alias tests and verify RED**

Run: `bash tests/test_ssl_alias.sh alias_transaction`

Expected: current code exposes the new alias in the SSL vhost before any
certificate expansion and does not roll back failures.

- [ ] **Step 3: Implement SSL delegation and rollback**

Resolve the command domain to the primary site, validate alias arguments, save
the old alias value, and write desired state. If `SSL=true`, call
`forge-lite-ssl issue "$primary_domain"` before directly editing any vhost. On
failure, restore the old alias value and abort. For HTTP sites, back up the
vhost around `server_name` editing and restore it if `nginx -t` or reload fails.

- [ ] **Step 4: Run alias tests and verify GREEN**

Run: `bash tests/test_ssl_alias.sh alias_transaction`

Expected: no uncovered SSL alias becomes live, rollback is complete, and known
aliases resolve to the primary site.

### Task 5: Documentation and full verification

**Files:**
- Modify: `README.md`
- Verify: every changed shell script and test

**Interfaces:**
- Produces: documented safe alias/SSL workflow and evidence that all requested checks pass.

- [ ] **Step 1: Update README workflow and alias-resolution behavior**

Document:

```bash
forge-lite site alias example.com --add=www.example.com
forge-lite ssl issue example.com
```

Explain that SSL-enabled sites expand and validate the certificate before the
alias enters the live vhost, and that `forge-lite ssl issue www.example.com`
automatically manages the primary `example.com` site when the alias is known.

- [ ] **Step 2: Run all behavioral tests**

Run: `bash tests/test_ssl_alias.sh`

Expected: all named cases pass; all external system commands are fakes.

- [ ] **Step 3: Run syntax, lint, and diff checks**

Run:

```bash
bash -n cli/forge-lite cli/forge-lite-ssl lib/sites.sh tests/test_ssl_alias.sh
shellcheck cli/forge-lite cli/forge-lite-ssl lib/sites.sh tests/test_ssl_alias.sh
git diff --check
```

Expected: no syntax, ShellCheck, or whitespace errors. If ShellCheck is not
installed, record that fact and continue with the other required checks.

- [ ] **Step 4: Review the scoped diff and repository status**

Run: `git diff -- cli/forge-lite cli/forge-lite-ssl lib/sites.sh README.md tests/test_ssl_alias.sh docs/superpowers/specs/2026-07-14-forge-lite-ssl-alias-safety-design.md docs/superpowers/plans/2026-07-14-forge-lite-ssl-alias-safety.md`

Expected: only task-scoped changes; unrelated concurrent edits remain unstaged.

- [ ] **Step 5: Commit and push main**

```bash
git add cli/forge-lite cli/forge-lite-ssl lib/sites.sh README.md tests/test_ssl_alias.sh docs/superpowers/specs/2026-07-14-forge-lite-ssl-alias-safety-design.md docs/superpowers/plans/2026-07-14-forge-lite-ssl-alias-safety.md
git commit -m "Fix SSL certificate handling for site aliases"
git push origin main
```

Expected: the task commit and the already-local main commits are present on `origin/main`.
