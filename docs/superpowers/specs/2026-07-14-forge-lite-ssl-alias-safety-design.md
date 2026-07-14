# forge-lite SSL and Alias Safety Design

**Date:** 2026-07-14
**Status:** Approved for implementation by the supplied handoff
**Scope:** DNS preflight, site resolution, certificate lineage, SSL vhost activation, and alias mutation

## Problem

`forge-lite ssl issue` currently treats the first line from `dig +short` as an
address. A CNAME response therefore produces false A/AAAA mismatch warnings.
The command also assumes that its argument is a primary site domain. When it is
called with a configured alias, Certbot may operate on an unrelated certificate
lineage while the primary NGINX vhost continues serving the old certificate.

Separately, `forge-lite site alias --add` immediately adds an alias to an
SSL-enabled vhost without first ensuring that the site's certificate covers the
new name. That creates a TLS hostname mismatch for the newly activated alias.

## Decision

Keep certificate and vhost ownership at the primary site. Resolve every SSL
issue argument to exactly one primary site config, request the complete desired
name set under the primary domain's Certbot lineage, verify every expected name
against the resulting certificate, and only then activate the rendered SSL
vhost and reload NGINX.

For an SSL-enabled site, alias addition is a transaction:

1. Save the new alias in the site config as desired state.
2. Run `forge-lite-ssl issue` for the primary domain.
3. Let the SSL command expand and validate the primary lineage, render the
   complete `server_name` set, validate NGINX, and reload it.
4. If the SSL command fails, restore the previous alias config. The old live
   vhost remains active and never advertises the uncovered alias.

This is preferred over adding a special temporary alias-list option to the SSL
CLI because the site config remains the single source of truth. It is preferred
over temporarily activating an HTTP alias because that creates an unnecessary
intermediate externally visible state.

## Components

### Reusable site resolution

`lib/sites.sh` gains a helper that returns a primary domain and config path for
a requested domain. It first checks the direct `<domain>.conf` path. If no
direct config exists, it scans site configs and compares individual comma-
separated `ALIASES` entries exactly. No match is an error, and more than one
match is reported as inconsistent configuration.

`cli/forge-lite-ssl` sources this helper when project libraries are available.
Its installed-CLI fallback retains an equivalent local implementation so the
standalone installed command does not depend on relative source files.

### DNS preflight

DNS lookup separates final address records from CNAME lines. A records are
accepted only when they have IPv4 address syntax; AAAA records are accepted only
when they have IPv6 address syntax. All returned final addresses are retained.
The server address matches when it equals any final address. Mismatch warnings
list all final addresses, and a CNAME without a final address is reported as a
missing A or AAAA result rather than as an address mismatch.

The check runs for the complete requested certificate name set because every
name must pass the Certbot HTTP challenge.

### Certificate lineage and verification

Certbot is invoked with `--cert-name <primary>`, `-d <primary>`, every configured
alias as an additional `-d`, and `--expand`. The selected certificate always
lives at `/etc/letsencrypt/live/<primary>/`.

After Certbot exits successfully, forge-lite checks that the primary lineage's
full chain exists and uses `openssl x509 -checkhost` for every expected name.
Missing SAN coverage aborts before vhost activation or NGINX reload. Completion
is reported as "SSL certificate ready", which is true both for a new certificate
and for an unchanged certificate that already satisfies the request.

### Transactional vhost activation

The SSL vhost is rendered for the primary domain and complete alias set. Before
replacement, the current vhost is copied to a temporary backup. If `nginx -t`
fails after installation, forge-lite restores the backup (or removes the new
file when no previous vhost existed) and aborts without reloading. Only a
successful config test permits `systemctl reload nginx` and `SSL=true` state.

For non-SSL alias changes, the same backup/test/restore discipline is used when
editing `server_name` in place.

## Error Handling

- Unknown or multiply assigned aliases fail before Certbot is executed.
- Certbot failure leaves the existing vhost and SSL flag unchanged.
- Missing certificate files or SAN names fail before vhost activation.
- NGINX validation failure restores the previous vhost and does not reload.
- SSL alias-add failure restores the previous `ALIASES` value and does not
  report success.
- Alias commands accept a known alias by resolving it to the primary site and
  explain that resolution to the operator.

## Test Strategy

A small Bash test harness sources the real CLI functions and uses temporary
site, certificate, and vhost directories. `dig`, `certbot`, `openssl`, `nginx`,
and `systemctl` are deterministic PATH fakes; no production paths or external
services are touched.

Regression coverage includes direct and CNAME DNS results, IPv4 and IPv6,
multiple final addresses, mismatches, CNAMEs without final addresses, direct
and alias site resolution, unknown and duplicate aliases, the complete Certbot
argument list, unchanged-certificate messaging, primary-lineage rendering,
certificate SAN rejection, reload ordering, and rollback-safe alias addition.

## Documentation

README examples show the safe two-command workflow:

```bash
forge-lite site alias example.com --add=www.example.com
forge-lite ssl issue example.com
```

It also states that `forge-lite ssl issue` accepts a known alias and manages the
certificate and vhost of its primary site.
