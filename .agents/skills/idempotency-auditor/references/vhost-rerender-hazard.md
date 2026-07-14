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

## Required durable render transaction

For a command that re-renders `vhost-ssl.conf` or `vhost.conf` on an existing site, use stable per-target paths for an exclusive lock, a durable transaction marker, and a last-known-good backup. Hold the lock across recovery and the complete transaction. Never delete or replace the backup while the marker exists.

Define one recovery routine and use it both at process startup and after validation or reload failure:

1. Process an existing transaction marker before creating or replacing any backup. If no marker exists, recovery is complete.
2. Require the last-known-good backup named by the marker. If it is missing, abort without touching the live target or marker.
3. Copy the backup to a sibling recovery file, preserve its mode and ownership, make it durable, and atomically `mv -f` it over the live target. Make the restored live target and its containing directory durable before validation. Keep the backup itself intact so another interrupted recovery can retry.
4. Run `nginx -t`, capture the current NGINX worker generation, then reload NGINX and perform the bounded adoption check below so the running configuration demonstrably matches the restored disk state. If validation, reload, or adoption confirmation fails, leave the marker and backup intact and abort.
5. Remove the marker and make the marker directory durable only after restore durability, validation, reload, and adoption confirmation all succeed.

After startup recovery succeeds, perform a new transaction in this order:

1. Create both include directories with `mkdir -p`.
2. Create each missing per-site include target without truncating existing content, then set required permissions.
3. Run `nginx -t` against the current live configuration. Do not bless an already-invalid target as last-known-good.
4. Render a complete sibling candidate. If it is byte-identical to the live target, remove the candidate and stop without creating a marker, replacing the backup, or reloading.
5. Copy the validated live target to a sibling backup candidate, preserve mode and ownership, make it durable, then atomically replace the stable last-known-good backup. Make the containing directory durable before continuing.
6. Write the transaction marker through a sibling temporary file. Record the target and backup paths, make the file durable, atomically rename it to the stable marker path, and make the containing directory durable. The marker must be durable before the live target changes.
7. Atomically `mv -f` the rendered candidate over the live vhost path that NGINX includes, then make the target and containing directory durable.
8. Run `nginx -t` against the installed candidate. On failure, invoke the same recovery routine.
9. Capture the current NGINX worker generation, reload NGINX, and perform the bounded adoption check below. On reload failure, rejection, or adoption timeout, invoke the same recovery routine.
10. Removing the durable marker is the transaction commit point. Remove it only after validation and confirmed reload adoption succeed, then make the marker directory durable. Retain the backup as last-known-good until a later validated transaction replaces it.

A successful reload command or signal alone is not confirmation. Before each reload, record the NGINX master PID and its worker-process PID set. After the reload, use a bounded wait for a new NGINX worker generation: require the same master to remain active and observe at least one live worker child that was not in the pre-reload set. Treat service failure, an explicit reload rejection, or timeout without a new worker as failure. Keep the marker throughout this check so recovery remains mandatory until the running generation is known to match the durable target.

This ordering makes every interruption state deterministic: no marker means the old target is still live or the new transaction committed; a marker means recovery must restore the preserved backup before any new work. A crash after reload but before marker removal deliberately rolls back on retry, keeping disk and running state aligned.

Re-run the path with both include files present, each file missing in turn, and injected `nginx -t`, reload rejection, and adoption-timeout failures. Also interrupt immediately after the live-path install and before `nginx -t`, then rerun: prove recovery processes the marker before touching the backup, the backup checksum remains unchanged during recovery, the old target and target directory are made durable, the old target validates, NGINX confirms a new worker generation for that restored target, and only then is the marker removed. Repeat interruption after marker creation and after reload but before marker removal. Prove existing include content is never truncated. Consult [confirmed-idempotent.md](confirmed-idempotent.md) for why `render_template` itself is otherwise safe.
