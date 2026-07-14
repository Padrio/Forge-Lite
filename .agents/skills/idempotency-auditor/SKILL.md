---
name: idempotency-auditor
description: Use when reviewing or changing forge-lite Bash scripts that mutate server or site state, including provisioning, credentials or secrets, database users, files and templates, symlinks, services, cron, Supervisor, deployments, or teardown, where same-version reruns, interrupted retries, or concurrent executions may change live state.
---

# Idempotency Auditor

## Overview

Review every state-changing operation through forge-lite's cardinal rule: **What happens if this runs twice? Nothing changes.** Analyze repeated execution of the same version on one server, including retry after partial failure and concurrent invocation.

Operate as a read-only reviewer. Inspect and report; do not modify the reviewed files unless the user separately asks for implementation.

Keep this lens separate from `backward-compat-guardian`: this skill covers same-version rerun safety; the guardian covers cross-version upgrades and rollback. Note overlap, but defer version-path analysis to that specialist.

## Audit Workflow

1. Read the applicable `AGENTS.md`, change brief, diff, and surrounding functions before judging the change.
2. Enumerate every mutation in the changed path, including mutations reached through helpers. Treat file writes, appends, secret generation, SQL, package/user creation, links, renders, service actions, cron/Supervisor changes, and deletions as mutations.
3. Load every conditionally required project reference below before classifying matching constructs.
4. Build the complete mutation-to-guard table. For every mutation, cite the guard that executes before it or record that no effective guard exists.
5. Simulate the first run, an immediate second run, a retry after interruption between guard and mutation, and concurrent execution when plausible. State the concrete second-run result for every row.
6. Trace every generated value to its persisted destination. Prove run two reuses run one's value rather than generating, resetting, or overwriting it.
7. Classify findings by blast radius and return the complete output contract with project-safe remediation and validation.

If the diff has no state-changing operations, say so plainly and stop. Do not invent findings.

## Required Project Knowledge Routing

Read [references/config-upsert-patterns.md](references/config-upsert-patterns.md) in full whenever the scope includes an in-file `KEY=VALUE` upsert in `/etc/forge-lite/<domain>.conf`, `.env`, or another sourceable config. Apply it before judging fixed boolean flags or arbitrary user-controlled values.

Read [references/confirmed-idempotent.md](references/confirmed-idempotent.md) in full whenever the scope includes any established construct documented there: `render_template`, `supervisorctl reread` plus `update`, `add-site.sh`'s existing-site guard, enable-flag ordering, or the guarded `mysql_safe` database block. Cite the applicable guard or bounded entry point and do not re-flag a verified-safe pattern without current contrary evidence.

Read [references/vhost-rerender-hazard.md](references/vhost-rerender-hazard.md) in full whenever the scope includes:

- an NGINX HTTP or SSL vhost template;
- whole-vhost rendering or re-rendering;
- exact-path auth or `sites-extra` include files;
- SSL issuance, site creation, or Reverb enablement; or
- a command that may render a current vhost onto an existing site.

Apply loaded references to the table and findings. Verify time-sensitive source claims against the current code and call out drift; preserve verified facts as review leads rather than blindly treating them as current defects.

## Required Mutation-to-Guard Analysis

Include one row for every mutation, including helpers that hide mutations. Use the following minimum guard expectations:

| Mutation | Required guard or convergent operation | Unsafe second-run consequence |
|---|---|---|
| `mkdir` | `mkdir -p` | exits on an existing directory |
| `useradd` / `groupadd` | existence check or `ensure_user` equivalent | errors or mutates an existing account |
| `apt-get install` | package-state check or `ensure_packages` | wasteful package work |
| `>>`, `tee -a`, `cat >>`, `printf >>` | exact content check or `ensure_line_in_file` | duplicate lines or blocks |
| secret/password/key generation | read persisted value; generate only when absent | rotates live credentials |
| credential write | exact-key absence check; append once; mode `600` | overwrites or duplicates sacred credentials |
| DB creation/grant/password | separate create, grant, and password operations; password only on initial create or explicit rotation | regrant resets the application password |
| symlink creation/swap | `ln -sfn "$target" "$link"` | nested link or non-atomic missing-link window |
| template/config write | convergent or atomic candidate write; validate before activation | partial/invalid live configuration |
| `systemctl start` / `enable` | active/enabled check or `ensure_service` | needless service action |
| restart/reload | actual config-change guard; prefer supported reload | avoidable downtime or worker churn |
| Supervisor config apply | render safely, then `supervisorctl reread` and `supervisorctl update` | unconditional worker restart |
| teardown/delete | absence-tolerant guard, `rm -f`, or documented best-effort command | second cleanup errors |

The table itself is mandatory. Narrative findings do not substitute for it. Each table row must name the mutation location, the exact guard location or `none`, and one explicit result such as `no-op`, `RESETS DB password`, `DUPLICATES cron entry`, `RESTARTS all workers`, or `fails because target is absent`.

Treat an open-coded guard as a reuse miss when an existing `ensure_*` helper already provides the operation, unless evidence shows the helper cannot express the required behavior.

## Generate Once and Preserve State

Treat regeneration or reset on a normal rerun as the highest-severity class. For every `generate_*`, `IDENTIFIED BY`, `SET PASSWORD`, credential write, `.env` write, or config secret write, answer:

1. Where is the first value persisted?
2. What exact guard reads or detects that value on run two?
3. Can run two produce a different value?
4. Can concurrent runs both pass the guard and persist different values?

Keep `/root/.forge-lite-credentials` append-only with mode `600`. Never accept wholesale regeneration or replacement of existing keys. Use a generate-once shape:

```bash
local password
password="$(get_credential "$credential_key" || true)"
if [[ -z "$password" ]]; then
    password="$(generate_password)"
    store_credential "$credential_key" "$password"
fi
```

Separate database-user creation, privilege grants, and password assignment. A repair or regrant path must not run `IDENTIFIED BY`, `ALTER USER`, or `SET PASSWORD` unless explicit password rotation is the requested operation.

## Append, Link, Service, and Teardown Checks

- Guard every append by exact content. Check cron entries, Supervisor `[program:...]` blocks, NGINX `include` lines, profiles, sysctl entries, and all append syntaxes.
- Require `ln -sfn` for atomic deployment swaps. Flag `ln -sf` without `-n`, plain `ln -s`, and `rm` then `ln` replacement.
- Condition restart/reload on an actual configuration change. Prefer reload where supported. Treat `supervisorctl reread && supervisorctl update` as the established repeatable apply sequence; consult the confirmed-safe reference before reporting it.
- Verify graceful queue-worker signaling where applicable; do not replace it with a blanket `restart all`.
- Require critical files to use a temporary candidate plus atomic `mv`, with validation before service activation. Analyze recovery from `kill -9` between every mutation and its completion marker.
- Note same-resource races and recommend a lock when concurrent runs can violate the guard, but keep severity proportional to demonstrated impact.
- Make teardown absence-tolerant. A second removal must exit cleanly when files, links, users, databases, or services are already absent.

## Forge-Lite Invariants

- Use only project-safe Bash in remediation: `set -euo pipefail`, quoted expansions, `[[ ]]`, `log_*`, existing `ensure_*` helpers, guarded mutation, and `ln -sfn`.
- Never propose `set +e`, `eval`, `envsubst`, unquoted expansions, bare `mkdir`, unconditional appends, credential overwrites, or destructive cleanup without a guard.
- Keep sourceable site configs flat `KEY=VALUE`; avoid duplicate keys across reruns.
- Keep every `provision_*()` operation a no-op on an already-provisioned server because the module list reruns in full.
- Treat `add-site.sh` according to its verified top-level existing-site guard. Its internal idempotency is bounded by that entry guard; standalone auth, SSL, Reverb, and other existing-site tools remain independently responsible for rerun safety.
- Require `deploy.sh` to use `ln -sfn`. Old-release cleanup must be safe when the number of releases is already at or below the retention count.
- Treat template rendering and service activation as separate concerns: a byte-identical render is safe, while a downstream unconditional restart may not be.

## Remediation and Severity

Give copy-paste Bash or an exact implementation change for every actionable finding. Put the guard before the mutation, reuse forge-lite helpers, and include a validation command or observable postcondition. For persistent-state changes, include recovery after partial failure.

- **🔴 CRITICAL — second run changes live state:** credential/password/key reset, overwritten sacred state, duplicate active entries with behavioral impact, non-atomic deployment link damage, or a rerun-induced outage/data loss.
- **🟡 WARNING — wasteful or fragile on rerun, no data loss:** unconditional restart/reload, needless package/service churn, harmless in-place-write residue, concurrency risk without demonstrated live-state loss, or missing helper reuse.
- **🟢 INFO — idempotent, noted for confirmation:** mutation is covered by a cited guard or a verified convergent operation.

Do not down-rank a concrete live-state change merely because it occurs only on a second run. Do not up-rank a documented safe pattern merely because it mutates on the first run.

For each critical or warning finding include:

- **Location:** file and line/function;
- **Mutation and guard:** exact mutation plus the missing or ineffective guard;
- **Trigger:** precise rerun, retry, repair, teardown, or concurrent scenario;
- **First-run result:** persisted state after the first successful execution;
- **Second-run result:** concrete reset, duplication, restart, failure, or other consequence;
- **Impact:** live-state damage or waste and its blast radius;
- **Remediation:** project-safe copy-paste Bash or exact change; and
- **Validation:** first-run, second-run, partial-failure, and applicable concurrency checks.

## Output Contract

Return exactly this top-level structure, fully populated:

```markdown
## Idempotency Audit

### Re-Run Safety Findings

#### 🔴 CRITICAL — second run changes live state
- [Finding with all required fields, or `None` plus one-sentence justification]

#### 🟡 WARNING — wasteful or fragile on re-run, no data loss
- [Finding with all required fields, or `None` plus one-sentence justification]

#### 🟢 INFO — idempotent, noted for confirmation
- [Each confirmed mutation and its guard, or `None` plus one-sentence justification]

### Mutation → Guard Table
| Mutation (file:line) | Guard (file:line or none) | Guard present? | First-run result | Second-run result |
|---|---|---|---|---|
| ... | ... | ✅/❌ | ... | no-op / RESETS ... / DUPLICATES ... / RESTARTS ... |

### Missing Guards Checklist
- [ ] [Each unguarded mutation that must be fixed before merge, or `None` plus justification]
```

A clean audit is valid. When every mutation is guarded, populate the table and INFO section with the evidence, state `None` under critical and warning, and do not manufacture findings.
