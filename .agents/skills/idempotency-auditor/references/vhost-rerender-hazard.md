# Vhost re-render include hazard

Read this reference when an existing site's NGINX vhost may be rendered from a current template. Verify current implementations before reporting historical gaps as active defects.

## Verified historical render shape

At the time the source memory was captured, three code paths rendered `server/config/templates/nginx/vhost-ssl.conf` with the same three placeholders, `DOMAIN`, `SERVER_NAMES`, and `FPM_SOCKET`:

- `sites/add-site.sh` through `render_template`;
- `cli/forge-lite-ssl` `cmd_issue` through inline `sed`, then auth-include injection when missing; and
- `cli/forge-lite-reverb` `cmd_enable` through `render_template`.

Current HEAD on 2026-07-15 has drifted from that snapshot: `forge-lite-reverb cmd_enable` renders only its Supervisor program, writes the websocket block to the per-site `sites-extra` file, and injects the include into an existing vhost when absent. Preserve the historical fact as an installed-state and regression-review lead; do not report whole-vhost rendering by current Reverb code unless the reviewed source introduces it again.

The template contains two exact-path, non-glob includes:

- `include /etc/forge-lite/auth/{{DOMAIN}}.conf;`
- `include /etc/nginx/sites-extra/{{DOMAIN}}.conf;`

NGINX treats a missing exact-path include as a fatal `nginx -t` error.

## Same-version rerun hazard

`add-site.sh` creates both backing files with `mkdir -p`, `touch`, and `chmod`. Standalone re-render paths have not always ensured both files before rendering. A legacy or manually drifted site can therefore receive a new vhost that references a missing include. Validation then fails after the live vhost has already been overwritten, and later NGINX reloads or restarts continue to fail until the file is recreated or the vhost restored.

The render can be atomic and byte-correct while still producing an invalid configuration because correctness depends on external include targets. `forge-lite-reverb` was designed to retrofit sites created before the template change, which is precisely the population most likely to lack backing files. At the time this fact was captured, `forge-lite-ssl cmd_issue` ensured the auth file but not the `sites-extra` file. Treat that as a current-review lead, not a timeless defect.

## Required guard-before-render sequence

For a command that re-renders `vhost-ssl.conf` or `vhost.conf` on an existing site:

1. Create both include directories with `mkdir -p`.
2. Create each missing per-site include target without truncating existing content, then set required permissions.
3. Preserve the exact live vhost in a recoverable backup.
4. Render a temporary candidate completely, then atomically install it at the live vhost path that NGINX actually includes.
5. Run `nginx -t` against the installed candidate.
6. On failure, atomically restore the exact backup, rerun `nginx -t` to prove recovery, and abort.
7. Reload only after validation succeeds, and only when the active configuration changed.

Re-run the path with both files present, each file missing in turn, and injected `nginx -t` failure. Prove existing include content is never truncated and a failed validation restores the original vhost. Consult [confirmed-idempotent.md](confirmed-idempotent.md) for why `render_template` itself is otherwise safe.
