# IPv6 Dual-Stack Support for forge-lite

**Date:** 2026-04-02
**Status:** Draft
**Scope:** Server provisioning, site management, deployment, CLI tools

---

## Problem

forge-lite provisions servers and manages Laravel sites on Ubuntu 24.04. While NGINX and Redis already support IPv6, several components are IPv4-only:

- MariaDB binds exclusively to `127.0.0.1`
- Sysctl tuning covers only `net.ipv4.tcp_*` parameters
- SSL DNS checks query only A records, not AAAA
- The deployment health check targets `http://127.0.0.1`
- CLI status output shows no IPv6 information
- No explicit guarantee that IPv6 remains enabled at the kernel level

Cloud providers (Hetzner, DigitalOcean, AWS) assign IPv6 addresses by default. Without Dual-Stack support, forge-lite ignores half the network stack.

## Decision

**Dual-Stack (IPv4 + IPv6 parallel).** All services accept both protocols. No breaking changes for existing IPv4-only servers. Servers without IPv6 ignore IPv6-specific configuration silently.

---

## Current State Audit

### Already Dual-Stack (no changes needed)

| Component | Evidence |
|---|---|
| NGINX vhosts | `listen 80;` + `listen [::]:80;` in all templates |
| NGINX SSL vhosts | `listen 443 ssl http2;` + `listen [::]:443 ssl http2;` |
| NGINX catch-all | `listen 80 default_server;` + `listen [::]:80 default_server;` |
| Redis | `bind 127.0.0.1 ::1` in `redis.conf` |
| PHP-FPM | Unix sockets (not network-bound) |
| SSH | Listens on `0.0.0.0` and `::` by default |
| UFW firewall | `ufw allow <port>/tcp` creates IPv4 + IPv6 rules automatically |
| Fail2Ban | Port-based jails, protocol-agnostic |
| NGINX rate limiting | `$binary_remote_addr` works with both IPv4 and IPv6 |

### Needs Changes

| Component | File | Issue |
|---|---|---|
| MariaDB bind | `server/config/templates/mariadb/50-server.cnf:5` | `bind-address = 127.0.0.1` (IPv4 only) |
| Sysctl tuning | `server/modules/swap.sh:35-37` | Only `net.ipv4.tcp_*` parameters |
| SSL DNS check | `cli/forge-lite-ssl:47-48` | Only queries A records, not AAAA |
| Health check | `deploy/deploy.sh:268-269` | `curl http://127.0.0.1` |
| UFW IPv6 flag | `server/modules/security.sh` | No explicit `IPV6=yes` verification |
| Status output | `cli/forge-lite` | No IPv6 information displayed |
| IP helper functions | `lib/common.sh` | No IPv4/IPv6 detection helpers |

---

## Design

### 1. MariaDB Dual-Stack Loopback

**File:** `server/config/templates/mariadb/50-server.cnf`

Change:
```
bind-address = 127.0.0.1
```
To:
```
bind-address = 127.0.0.1,::1
```

MariaDB 10.6+ (Ubuntu 24.04 ships 10.11+) supports comma-separated bind addresses. This allows connections from both `127.0.0.1` and `::1` while keeping the database off the network.

The `.env` values `DB_HOST=127.0.0.1` and `REDIS_HOST=127.0.0.1` remain unchanged. They connect via TCP to IPv4 loopback, which works on all servers. Switching to `localhost` would introduce DNS resolution overhead and potential ambiguity (some systems resolve `localhost` to `::1` first).

Database users created with `@'localhost'` already cover connections via Unix socket and TCP from both `127.0.0.1` and `::1` in MariaDB. No SQL changes needed.

### 2. Sysctl IPv6 Hardening

**File:** `server/modules/swap.sh` (extend in-place — this module already owns sysctl tuning)

Add IPv6-specific kernel parameters alongside existing IPv4 tuning:

```bash
# Ensure IPv6 is enabled (defensive — Ubuntu default, but cloud images may differ)
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0

# Accept Router Advertisements even when forwarding is enabled
# Value 2 = accept RA regardless of forwarding state (important for cloud VMs)
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2

# Privacy extensions — use temporary addresses for outgoing connections
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
```

Note: The existing `net.ipv4.tcp_tw_reuse` and `net.ipv4.tcp_max_syn_backlog` parameters already apply to IPv6 TCP connections in Linux kernels 4.9+. The `net.ipv4.tcp_*` namespace is a historical misnomer — these parameters control both IPv4 and IPv6 TCP. No duplication needed, but a comment should clarify this.

### 3. IPv6 Detection Helpers

**File:** `lib/common.sh`

New functions for IPv6 awareness:

```bash
# get_server_ipv4 — returns the public IPv4 address or empty string
get_server_ipv4() {
    curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true
}

# get_server_ipv6 — returns the public IPv6 address or empty string
get_server_ipv6() {
    curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || true
}

# has_ipv6 — returns 0 if server has a public IPv6 address
has_ipv6() {
    local ipv6
    ipv6=$(get_server_ipv6)
    [[ -n "$ipv6" ]]
}
```

These use `curl -4` / `curl -6` to force protocol selection against an external service. This detects actual public reachability, not just interface configuration. The `ifconfig.me` service supports both protocols.

Fallback: If `curl` fails (no internet during provisioning), fall back to `ip -6 addr show scope global` for local detection.

### 4. SSL DNS Check — AAAA Records

**File:** `cli/forge-lite-ssl` — `cmd_issue()`

Current check only verifies the A record. Extend to also check the AAAA record when the server has IPv6:

```bash
local server_ipv4 server_ipv6 domain_ipv4 domain_ipv6
server_ipv4=$(get_server_ipv4)
server_ipv6=$(get_server_ipv6)
domain_ipv4=$(dig +short "$domain" A 2>/dev/null | head -1) || domain_ipv4=""
domain_ipv6=$(dig +short "$domain" AAAA 2>/dev/null | head -1) || domain_ipv6=""

# Check A record
if [[ -n "$server_ipv4" && -n "$domain_ipv4" && "$server_ipv4" != "$domain_ipv4" ]]; then
    log_warn "A record for '${domain}' points to ${domain_ipv4}, but this server is ${server_ipv4}"
elif [[ -z "$domain_ipv4" ]]; then
    log_warn "No A record found for '${domain}'."
    [[ -n "$server_ipv4" ]] && log_warn "Point your A record to ${server_ipv4}"
fi

# Check AAAA record (only if server has IPv6)
if [[ -n "$server_ipv6" ]]; then
    if [[ -n "$domain_ipv6" && "$server_ipv6" != "$domain_ipv6" ]]; then
        log_warn "AAAA record for '${domain}' points to ${domain_ipv6}, but this server is ${server_ipv6}"
    elif [[ -z "$domain_ipv6" ]]; then
        log_info "No AAAA record for '${domain}'. IPv6 visitors won't reach this site."
        log_info "Add an AAAA record pointing to ${server_ipv6} for full Dual-Stack."
    fi
fi
```

Certbot uses HTTP-01 challenges and does not care about AAAA records specifically — it validates via whatever path works. But AAAA warnings help the admin ensure full IPv6 reachability.

### 5. Deployment Health Check

**File:** `deploy/deploy.sh`

Current:
```bash
curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: ${DOMAIN}" --max-time 10 "http://127.0.0.1"
```

Change to check both stacks when IPv6 is available:
```bash
# Primary health check via IPv4 loopback
http_code=$(curl -4 -s -o /dev/null -w '%{http_code}' \
    -H "Host: ${DOMAIN}" --max-time 10 "http://127.0.0.1") || true

if [[ "${http_code:-0}" -ge 200 && "${http_code:-0}" -lt 400 ]]; then
    log_ok "Health check passed (HTTP ${http_code})"
else
    log_warn "Health check returned HTTP ${http_code:-timeout} -- verify manually"
fi

# Secondary IPv6 health check (non-blocking)
if has_ipv6; then
    http_code_v6=$(curl -6 -s -o /dev/null -w '%{http_code}' \
        -H "Host: ${DOMAIN}" --max-time 5 "http://[::1]") || true
    if [[ "${http_code_v6:-0}" -ge 200 && "${http_code_v6:-0}" -lt 400 ]]; then
        log_ok "IPv6 health check passed (HTTP ${http_code_v6})"
    else
        log_warn "IPv6 health check returned HTTP ${http_code_v6:-timeout}"
    fi
fi
```

The IPv6 check is secondary and non-blocking. A failed IPv6 check does not affect deployment success.

### 6. UFW IPv6 Verification

**File:** `server/modules/security.sh`

Add an idempotent guard to ensure UFW processes IPv6 rules:

```bash
# Ensure UFW processes IPv6 rules
if grep -q "^IPV6=no" /etc/default/ufw 2>/dev/null; then
    sed -i "s|^IPV6=no|IPV6=yes|" /etc/default/ufw
    log_info "Enabled IPv6 in UFW"
fi
```

This is defensive. Ubuntu 24.04 defaults to `IPV6=yes`, but some cloud images or hardening scripts disable it. The guard runs during provisioning and ensures IPv6 firewall rules are processed.

### 7. Status Output — IPv6 Transparency

**File:** `cli/forge-lite` — `cmd_status()`

Add a "Network" section to the status output:

```
--- Network ---
  IPv4:        203.0.113.42
  IPv6:        2a01:4f8:c2c:1234::1
  Dual-Stack:  yes
```

Implementation: Use `get_server_ipv4()` and `get_server_ipv6()` from `lib/common.sh`.

**File:** `cli/forge-lite` — `cmd_site_list()`

No changes to `site list` table columns. DNS record checking (A/AAAA) would require network calls per site, adding latency to a read-only command. Instead, `forge-lite ssl issue` already performs DNS checks where it matters.

### 8. Cloud-Init

**File:** `cloud-init/cloud-config.yml`

No changes needed. Cloud-init's network configuration is handled by the cloud provider's metadata service, which controls IPv6 assignment. forge-lite's sysctl hardening (Section 2) ensures the kernel accepts the assigned IPv6 address.

---

## Files Changed

| File | Change | Lines |
|---|---|---|
| `lib/common.sh` | Add `get_server_ipv4()`, `get_server_ipv6()`, `has_ipv6()` | ~20 new |
| `server/config/templates/mariadb/50-server.cnf` | `bind-address = 127.0.0.1,::1` | 1 changed |
| `server/modules/swap.sh` | Add IPv6 sysctl parameters + comment on net.ipv4 scope | ~15 new |
| `server/modules/security.sh` | Add `IPV6=yes` UFW guard | ~5 new |
| `cli/forge-lite-ssl` | Extend DNS check for AAAA records, use new helpers | ~20 changed |
| `deploy/deploy.sh` | Add optional IPv6 health check | ~10 new |
| `cli/forge-lite` | Add Network section to `cmd_status()` | ~15 new |

**Total: ~85 new/changed lines across 7 files. No new files created.**

---

## Backward Compatibility

All changes are additive:

- **Existing IPv4-only servers:** Continue working identically. MariaDB adds `::1` but `127.0.0.1` still works. Sysctl changes don't affect IPv4 behavior. IPv6 health checks only run if `has_ipv6()` is true.
- **Servers without IPv6:** `get_server_ipv6()` returns empty, `has_ipv6()` returns false, all IPv6-conditional code paths are skipped.
- **Re-provisioning:** All changes are idempotent. Running `provision.sh` on an existing server applies the new sysctl values and MariaDB config without disruption.
- **Site configs:** No schema changes to `/etc/forge-lite/<domain>.conf`. No `.env` format changes.

---

## What Is NOT In Scope

- **IPv6-only mode** (no IPv4): Would require `.env` changes (`DB_HOST=::1`), different health check logic, and testing matrix. Deferred.
- **AAAA record management:** forge-lite does not manage DNS records. It warns about missing records but does not create them.
- **IPv6 firewall rules beyond UFW:** UFW handles the dual-stack rules automatically. No ip6tables management needed.
- **Per-site IPv6 configuration:** All sites share the server's network stack. No per-site IPv6 toggles.

---

## Verification

1. **Syntax:** `bash -n` and `shellcheck` on all modified files
2. **Sysctl:** After provisioning, verify: `sysctl net.ipv6.conf.all.disable_ipv6` returns `0`
3. **MariaDB:** `mysql -h ::1 -u root -p -e "SELECT 1"` succeeds
4. **UFW:** `grep "^IPV6=" /etc/default/ufw` returns `IPV6=yes`; `ufw status` shows v6 rules
5. **Health check:** Deploy a site, verify both IPv4 and IPv6 health checks pass
6. **SSL DNS check:** `forge-lite ssl issue test.com` shows both A and AAAA record status
7. **Status:** `forge-lite status` shows Network section with IPv4 and IPv6 addresses
8. **No-IPv6 server:** On a server without IPv6, verify all IPv6 code paths are silently skipped
