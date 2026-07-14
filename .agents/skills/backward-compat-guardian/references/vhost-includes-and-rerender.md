# NGINX vhost include generations and re-render safety

Use this reference when reviewing NGINX vhost templates, whole-vhost rendering,
SSL issuance, site creation, Reverb enablement, or per-site include files. Verify
historical claims against current source when the review depends on them.

## Single-file includes

The HTTP and SSL vhost templates reference two single files, not globs. A
missing target makes `nginx -t` fail.

- `/etc/forge-lite/auth/{{DOMAIN}}.conf` was added by commit `0297588` on
  2026-04-14.
- `/etc/nginx/sites-extra/{{DOMAIN}}.conf` was added by commit `a912d34` on
  2026-04-27.

## Installed-state generations

| Site creation generation | Auth include file | Sites-extra include file |
|---|---:|---:|
| Before 2026-04-14 | Missing | Missing |
| 2026-04-14 through 2026-04-26 | Present | Missing |
| 2026-04-27 or later | Present | Present |

At the time this knowledge was captured, `sites/add-site.sh` created both
per-site files for new sites, `forge-lite auth enable` could create the auth
file, and `forge-lite reverb enable` had created the sites-extra file
retroactively since 2026-06-30. Do not assume those are the only current
writers without checking the reviewed source.

## Whole-vhost re-render hazard

Forge-lite owns and re-renders the vhost from its current template. Certbot is
invoked with `certbot certonly --nginx`, so Certbot does not persist certificate
directives into the vhost. The primary compatibility risks are:

1. an older on-disk vhost rendered before one or both include lines existed;
2. manual operator edits lost by whole-file replacement; and
3. a current template rendered onto an older site whose include target is
   absent.

For a pre-2026-04-27 site, a whole-vhost render can add a reference to a missing
`sites-extra/<domain>.conf`. `nginx -t` then fails. If the renderer already
persisted the vhost and lacks restoration logic, running NGINX keeps its old
in-memory configuration but a later restart or reboot can fail. That latent
failure can take every hosted site down.

## Safe re-render sequence

Before replacing the live vhost:

1. Create both include directories.
2. Ensure both per-site include targets exist without truncating existing
   content.
3. Preserve the live vhost, including mode and ownership, in a recoverable
   backup.
4. Render the candidate configuration.
5. Run `nginx -t`.
6. On validation failure, restore the exact backup and abort.
7. Reload NGINX only after validation succeeds.

Re-run the sequence against sites from all three generations. Also inject a
validation failure and prove the original vhost is restored.

The historical implementation in `reverb enable` followed the pre-create,
backup, validate, and restore approach as of 2026-06-30. The source note also
identified SSL issuance as a sibling whole-vhost renderer that lacked
sites-extra creation and backup/rollback at that time. Treat this as a review
lead, not a timeless claim: verify the current implementation before reporting
it as an active defect.

## Reverb `/app` location matching

`location /app` is an NGINX prefix match. It captures extensionless paths that
start with `/app`, including `/appointments`, `/apps`, and `/applications`.
Regex locations for PHP or static file extensions can still win, but ordinary
application routes may be proxied to port 8080 and return 502 when no Reverb
daemon is listening.

The block is rendered
UNCONDITIONALLY into every SSL vhost (independent of ENABLE_REVERB), so any SSL
site re-rendered via `ssl issue`/`reverb enable`, or created new with `--ssl`,
inherits it. Treat this as a historical installed-state fact, not only a
current-source concern.

Inspect legacy on-disk SSL vhosts even if current source is fixed. The block may
already have persisted through any of these paths:

- SSL issuance via `forge-lite ssl issue`
- Reverb enablement via `forge-lite reverb enable`
- new site creation with `--ssl`

Prefer a Reverb-only per-site include and scope the proxy location to `/app/`
when that matches the protocol requirements. Review whether the block is
rendered conditionally; a block embedded unconditionally in every SSL vhost
affects sites that never enabled Reverb.
