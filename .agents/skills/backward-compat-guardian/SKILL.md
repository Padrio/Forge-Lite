---
name: backward-compat-guardian
description: Use when reviewing or changing forge-lite bash scripts, deployed configuration, paths, templates, services, cron jobs, packages, install/update logic, permissions, or stateful bug fixes that may affect existing servers, version-skipping upgrades, reruns, or rollback.
---

# Backward Compatibility Guardian

## Overview

Review deployed-component changes as fleet migrations, not fresh-install changes. Prove that every materially different installed state can upgrade directly, survive interruption and re-run, and roll back without an outage or lost state.

Operate as a read-only reviewer. Inspect and report; do not modify the reviewed files unless the user separately asks for implementation.

## Review Workflow

1. Read the applicable `AGENTS.md`, change brief, diff, and surrounding code before judging the change.
2. Identify every persistent artifact the change reads, writes, renames, renders, enables, reloads, or deletes.
3. Reconstruct distinct installed-state generations from repository evidence. Include servers that skipped intermediate releases and servers interrupted partway through a prior operation.
4. Load project knowledge conditionally as required below.
5. Build the upgrade path matrix before assigning a final verdict. Do not infer that incremental safety proves version-skip safety.
6. Review every compatibility dimension and forge-lite invariant.
7. Return the complete output contract. Give evidence and copy-paste remediation for each actionable finding.

When history or version boundaries are unavailable, name states by observable condition, such as `config lacks ENABLE_REVERB` or `vhost predates sites-extra include`. Mark unverified paths as unknown; never silently label them safe.

## Required Project Knowledge Routing

Read [references/vhost-includes-and-rerender.md](references/vhost-includes-and-rerender.md) in full whenever the scope includes any of the following:

- NGINX HTTP or SSL vhost templates
- whole-vhost rendering or re-rendering
- per-site NGINX include files or include paths
- SSL issuance that rewrites a vhost
- site creation, Reverb enablement, or another command that may render a current template onto an older site

Apply that reference to the upgrade matrix and findings, not merely as background. Verify time-sensitive statements against the current diff and source; cite any drift between the checked-in reference and current behavior.

## Required Upgrade Path Matrix

Include one row for every distinct path supported by the evidence. At minimum cover:

| Path class | Required row |
|---|---|
| Oldest plausible state | Oldest supported or pre-change installed state directly to the proposed state |
| Adjacent upgrade | Immediately previous state to the proposed state |
| Version skip | Each older state that can bypass an intermediate migration |
| State generations | Every materially different on-disk/config generation identified in the review |
| Re-run | Current/proposed state through the operation again, including partial prior execution |
| Rollback | Proposed state back to the previous executable/config format |

Use actual versions, dates, commits, or observable state labels found in evidence. Record `❓ Unknown` when evidence is missing and list the exact verification needed. A matrix containing only `previous → current` is incomplete.

## Compatibility Dimensions

Review every row against every applicable dimension:

1. **Paths, directories, and names** — Check configs, logs, PIDs, locks, sockets, templates, commands, and symlinks. Require old/new lookup or an idempotent migration before consumers switch.
2. **Variables and parameters** — Give new variables safe defaults with `${VAR:-default}` that preserve old behavior. Older config files must remain sourceable and may omit every newer key.
3. **Dependencies and shell features** — Ensure packages are installed before use and commands/flags exist on Ubuntu 24.04. Flag non-Bash or non-GNU assumptions.
4. **Idempotency and interruption** — Re-running must converge. Guard appends, directory creation, credentials, migrations, and reloads. Analyze `kill -9` between each mutation and its marker.
5. **Config format and parsing** — Preserve flat sourceable `KEY=VALUE` site configs. For renamed keys, read old and new formats. Test whether an older executable can read the post-change format during rollback.
6. **Cron, systemd, Supervisor, and FPM** — Remove superseded definitions before enabling replacements. Prevent duplicate jobs, stale units/pools, and missing reread/update operations.
7. **Catch-up migrations** — Make each migration independently idempotent and reachable from every skipped version. Write a completion marker only after all mutations and validation succeed.
8. **Bug-fix cleanup** — Repair already-persisted broken state, not only the code path that created it. Cleanup must be harmless when the bug never manifested.
9. **Destructive changes and deprecation** — Prefer two phases: support both plus warning, then removal with a direct migration for servers that skipped phase one.
10. **Rollback safety** — Identify irreversible changes, preserve backups, validate before reload, and ensure older code can consume the resulting state. Preserve atomic `ln -sfn` deployment swaps.
11. **Worst-case state** — Consider six-month-old servers, manual config edits, partial transfers, full disks, wrong users, concurrent execution, and minimal packages.

## Forge-Lite Invariants

- Keep `/root/.forge-lite-credentials` append-only with mode `600`; never overwrite existing keys.
- Keep `/etc/forge-lite/<domain>.conf` flat and Bash-sourceable.
- Preserve `/home/deployer/sites/<domain>/{current,releases,shared}` and valid symlink targets.
- Keep NGINX `{{FPM_SOCKET}}` and the FPM pool socket consistent.
- Supply every new template placeholder at every render call; unresolved `{{VAR}}` text is a defect.
- Keep every `provision_*()` operation safe on already-provisioned servers.
- Clean up obsolete `/usr/local/bin/forge-lite*` copies or symlinks after CLI renames.
- Preserve provisioning module ordering while making modules safe when dependencies were provisioned months earlier.
- Use only project-safe Bash: `set -euo pipefail`, quoted expansions, `[[ ]]`, `log_*`, `ensure_*`, guarded mutation, and `ln -sfn` for atomic swaps.
- Never propose `set +e`, `eval`, `envsubst`, unquoted expansions, unconditional appends, credential overwrites, or destructive cleanup without a guard.

## Remediation Standard

Provide concrete Bash for actionable risks. Keep migrations guard-before-mutate and valid for a server jumping directly from the oldest affected state.

Use this shape for a moved path:

```bash
if [[ -f "$old_path" ]] && [[ ! -f "$new_path" ]]; then
    mkdir -p "$(dirname "$new_path")"
    mv "$old_path" "$new_path"
    log_info "Migrated config from ${old_path} to ${new_path}"
fi
```

Use safe defaults for new keys:

```bash
local enable_feature="${ENABLE_FEATURE:-false}"
```

For marker-based catch-up migrations, guard on the marker, validate the final state, and create the marker last. For cron/unit/pool migrations, remove the exact legacy artifact idempotently before enabling its replacement. For bug fixes, detect and repair persisted consequences on disk.

Every remediation must include a validation command or observable postcondition and a rollback/recovery step when it changes persistent state.

## Risk Classification

- **🔴 CRITICAL (blocks deployment):** Can cause fleet outage, data or credential loss, broken direct upgrades, unrecoverable partial state, or an unsafe/impossible rollback.
- **🟡 WARNING (should fix before deployment):** Leaves duplicate/stale state, depends on an unproven upgrade path, mishandles manual drift, or weakens re-run/recovery without an immediate fleet-wide failure.
- **🟢 INFO (acceptable with noted caveats):** Compatibility is supported by evidence, with a useful limitation or follow-up to record.

Do not down-rank a concrete production failure because it only affects older or version-skipping servers.

## Finding Requirements

For every critical or warning finding include:

- **Evidence:** file and line, diff hunk, historical state, or reference fact
- **Affected installed states:** the exact observable generations at risk
- **Affected upgrade paths:** the corresponding matrix rows
- **Impact:** what fails and whether failure is immediate or latent
- **Re-run and rollback behavior:** what happens after interruption and after reverting code
- **Remediation:** copy-paste Bash or an exact implementation change following project standards
- **Validation:** commands or tests proving migration, re-run, failure rollback, and cleanup

If a risk level has no findings, write `None` and a one-sentence justification. Do not omit any required heading.

## Output Contract

Return exactly this top-level structure, fully populated:

```markdown
## Backward Compatibility Analysis

### Scope and Evidence
- **Reviewed change:** ...
- **Persistent artifacts:** ...
- **Installed-state generations:** ...
- **Assumptions/evidence gaps:** ...

### Risk Assessment

#### 🔴 CRITICAL (blocks deployment)
- [Finding with every required field, or `None` plus justification]

#### 🟡 WARNING (should fix before deployment)
- [Finding with every required field, or `None` plus justification]

#### 🟢 INFO (acceptable with noted caveats)
- [Observation, or `None` plus justification]

### Upgrade Path Matrix
| Installed state / From | Target | Path type | Safe? | Required migration or safeguard | Rollback safe? | Evidence |
|---|---|---|---|---|---|---|
| ... | ... | adjacent/version-skip/re-run/rollback | ✅/❌/❓ | ... | ✅/❌/❓ | ... |

### Bug Fix Cleanup Required
- [Persisted bad states and cleanup, or `None` with justification]

### Missing Safeguards
- [ ] [Concrete protection to add, or `None` with justification]

### Rollback and Recovery
- **Backup/restore:** ...
- **Interrupted execution:** ...
- **Validation failure:** ...

### Validation Plan
- [Fresh, old-state, version-skip, re-run, partial-failure, and rollback checks]

### Compatibility Verdict
**BLOCK / CONDITIONAL / SAFE** — [Evidence-based reason and deployment conditions]
```

Prefer a blocked or conditional verdict over guessing when repository evidence cannot establish a path. Be adversarial, specific, and actionable.
