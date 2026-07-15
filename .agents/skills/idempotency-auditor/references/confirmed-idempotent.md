# Confirmed idempotent constructs

Read this reference before flagging any construct listed below. Confirm that current source still matches the documented shape, then cite it as INFO rather than manufacturing a finding.

## `render_template`

`render_template` in `lib/templates.sh` writes atomically using a sibling
`mktemp "${output}.XXXXXX"`. It explicitly checks template reads,
substitutions, temporary writes, and permission changes; applies mode `644` to
the complete candidate; and only then activates it with `mv -f`. Identical
inputs produce byte-identical content. Do not flag the render itself merely
because it overwrites its destination.

It warns but does not fail on unreplaced `{{KEY}}` placeholders. Verify that every call supplies all placeholders used by its template. At the time this fact was verified, `vhost-ssl.conf` used exactly `DOMAIN`, `SERVER_NAMES`, and `FPM_SOCKET`.

If killed between `mktemp` and `mv`, it can leave a harmless
`${output}.XXXXXX` sibling. That file does not match Supervisor's `*.conf`
glob and is not selected by NGINX `sites-enabled` symlinks. The live file is
never activated with `mktemp`'s `0600` mode. Distinguish this minor residue
from a partial live-file write.

## Supervisor apply sequence

`supervisorctl reread` followed by `supervisorctl update` is the established repeatable apply sequence. `reread` detects changes and `update` applies only detected changes; both are no-ops when the rendered config is unchanged. It is used by `add-site.sh` and `forge-lite-reverb`. Do not flag this pair as an unconditional restart.

## `add-site.sh` entry guard

`add-site.sh` is intentionally not rerunnable for an existing domain. Near the top it calls `die` when the site's config file already exists. Its internal mutations are bounded by that entry guard. The standalone auth, SSL, Reverb, and other commands that operate on existing sites are the rerunnable surfaces and must each be audited independently.

## Flag-set-last ordering

Enable-type commands set `ENABLE_X=true` only after `nginx -t` and reload succeed. This was verified in both `forge-lite-auth` and `forge-lite-reverb`. A failed validation can leave the flag `false` while a Supervisor daemon is already installed or running, but a later successful rerun self-heals the state. Record this as INFO, not a bug, when current control flow still matches.

## Guarded database block

The `mysql_safe` block in `add-site.sh` uses `CREATE DATABASE IF NOT EXISTS` and `CREATE USER IF NOT EXISTS`. It also runs `ALTER USER ... IDENTIFIED BY`, but only inside `add-site.sh`, whose existing-site entry guard prevents a normal second invocation. Do not report it as a live rerun hazard there. Report the pattern if it leaks into a rerunnable repair path such as `_regrant_site_user`, because a regrant must not reset the password.
