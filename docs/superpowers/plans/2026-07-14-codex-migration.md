# Codex Project Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all Claude-specific project configuration with native, behavior-preserving Codex guidance, agents, skills, hooks, MCP configuration, and references.

**Architecture:** Keep durable project standards in `AGENTS.md`, reusable specialist workflows in `.agents/skills`, and delegated reviewer identities in `.codex/agents`. Use deterministic repo-local hook scripts for mechanical enforcement and a trusted project config for Context7.

**Tech Stack:** Markdown, TOML, JSON, Bash, jq, Codex project configuration, Agent Skills standard

## Global Constraints

- Preserve every project-specific rule and every verified memory fact from the Claude setup.
- Do not commit the machine-specific command and SSH allowlist from `.claude/settings.local.json`.
- Do not modify production provisioning behavior.
- Keep `AGENTS.md` below Codex's default 32 KiB project-instruction limit.
- Use only native Codex project locations documented in the 2026-07-14 Codex manual.

---

### Task 1: Establish skill behavior baselines

**Files:**
- Read: `.claude/agents/backward-compat-guardian.md`
- Read: `.claude/agents/idempotency-auditor.md`
- Read: `.claude/agent-memory/**/*.md`

**Interfaces:**
- Consumes: Existing Claude reviewer instructions and stored project findings.
- Produces: Baseline review outputs used to check that migrated skills add the intended specialized behavior.

- [x] **Step 1: Run a backward-compatibility review scenario without the migrated skill**

Use a fresh agent with only a hypothetical forge-lite path/config migration and request a deployment-safety review. Record whether it identifies version-skipping, cleanup, rollback, and legacy include-file hazards.

- [x] **Step 2: Run an idempotency review scenario without the migrated skill**

Use a fresh agent with only a hypothetical password regeneration and config append change. Record whether it traces the second-run state, credential preservation, append duplication, and service churn.

- [x] **Step 3: Preserve the observed gaps as forward-test assertions**

The migrated skills must return structured findings, concrete remediation, and the project-specific knowledge absent from each baseline.

### Task 2: Migrate repository guidance

**Files:**
- Create: `AGENTS.md`
- Delete: `CLAUDE.md`
- Modify: `server/modules/security.sh`
- Modify: `docs/superpowers/specs/2026-04-26-forge-lite-db-cli-design.md`
- Modify: `docs/superpowers/plans/2026-04-26-forge-lite-db-cli.md`

**Interfaces:**
- Consumes: All 518 lines of existing root guidance.
- Produces: Codex's automatically discovered repository instruction file and valid internal references.

- [x] **Step 1: Write a failing discovery assertion**

Run:

```bash
test -f AGENTS.md && test ! -e CLAUDE.md
```

Expected: FAIL because only `CLAUDE.md` exists.

- [x] **Step 2: Create `AGENTS.md` and remove `CLAUDE.md`**

Preserve the full source body, change its title to `# forge-lite — Codex Project Guidance`, replace self-references with `AGENTS.md`, and append:

```markdown
## 14. Specialist Reviews

- For deployed-component compatibility, use `$backward-compat-guardian` and delegate an independent review to the `backward-compat-guardian` custom agent when subagents are available.
- For state-changing operations, use `$idempotency-auditor` and delegate an independent review to the `idempotency-auditor` custom agent when subagents are available.
- Treat both reviews as required when a change has both cross-version and same-version re-run risks.
```

- [x] **Step 3: Update every live `CLAUDE.md` reference**

Replace only filename references in the three known files; preserve historical engineering meaning.

- [x] **Step 4: Verify guidance discovery shape**

Run:

```bash
test -f AGENTS.md
test ! -e CLAUDE.md
test "$(wc -c < AGENTS.md)" -lt 32768
legacy_scan_status=0
rg -n \
    -g '!docs/superpowers/specs/2026-07-14-codex-migration-design.md' \
    -g '!docs/superpowers/plans/2026-07-14-codex-migration.md' \
    'CLAUDE\.md|\.claude/' AGENTS.md server docs \
    || legacy_scan_status=$?
test "${legacy_scan_status}" -eq 1
```

Expected: the discovery and size checks exit 0, `rg` records status 1 for no live matches, and the final status assertion exits 0. An `rg` status of 0 (a match) or greater than 1 (an error) fails validation.

### Task 3: Migrate the backward compatibility specialist

**Files:**
- Create: `.agents/skills/backward-compat-guardian/SKILL.md`
- Create: `.agents/skills/backward-compat-guardian/agents/openai.yaml`
- Create: `.agents/skills/backward-compat-guardian/references/vhost-includes-and-rerender.md`
- Create: `.codex/agents/backward-compat-guardian.toml`

**Interfaces:**
- Consumes: Cross-version reviewer prompt and its NGINX migration memory.
- Produces: Explicit/implicit skill name `backward-compat-guardian` and custom agent name `backward-compat-guardian`.

- [x] **Step 1: Write a failing structure assertion**

```bash
test -f .agents/skills/backward-compat-guardian/SKILL.md
test -f .codex/agents/backward-compat-guardian.toml
```

Expected: FAIL because neither Codex artifact exists.

- [x] **Step 2: Create the skill and knowledge reference**

Use valid Agent Skills frontmatter. Preserve the Claude review dimensions, output contract, forge-lite checks, and behavioral rules. Replace Claude tool/memory wording with imperative Codex wording and direct the reviewer to load the NGINX reference whenever vhost templates or re-rendering are in scope.

- [x] **Step 3: Create UI metadata**

Set `display_name` to `Backward Compatibility Guardian`, describe cross-version forge-lite review in under 64 characters, and provide a default review prompt containing `$backward-compat-guardian`.

- [x] **Step 4: Create the read-only custom agent**

Define `name`, `description`, `sandbox_mode = "read-only"`, and `developer_instructions` that require the matching skill and return findings without modifying files.

- [x] **Step 5: Validate and forward-test**

Run the official `quick_validate.py` against the skill, parse the TOML, then repeat Task 1's compatibility scenario with a fresh agent using the skill. Expected: structured risk levels, upgrade-path reasoning, and concrete cleanup/rollback safeguards.

### Task 4: Migrate the idempotency specialist

**Files:**
- Create: `.agents/skills/idempotency-auditor/SKILL.md`
- Create: `.agents/skills/idempotency-auditor/agents/openai.yaml`
- Create: `.agents/skills/idempotency-auditor/references/config-upsert-patterns.md`
- Create: `.agents/skills/idempotency-auditor/references/confirmed-idempotent.md`
- Create: `.agents/skills/idempotency-auditor/references/vhost-rerender-hazard.md`
- Create: `.codex/agents/idempotency-auditor.toml`

**Interfaces:**
- Consumes: Same-version reviewer prompt and three verified memory topics.
- Produces: Explicit/implicit skill name `idempotency-auditor` and custom agent name `idempotency-auditor`.

- [x] **Step 1: Write a failing structure assertion**

```bash
test -f .agents/skills/idempotency-auditor/SKILL.md
test -f .codex/agents/idempotency-auditor.toml
```

Expected: FAIL because neither Codex artifact exists.

- [x] **Step 2: Create the skill and references**

Preserve mutation-to-guard analysis, generate-once rules, append/symlink/service/teardown checks, output contract, and known-safe patterns. Route arbitrary config values to `config-upsert-patterns.md`, existing safe constructs to `confirmed-idempotent.md`, and vhost re-renders to `vhost-rerender-hazard.md`.

- [x] **Step 3: Create UI metadata and the read-only custom agent**

Use `Idempotency Auditor` as the display name and require the matching skill from the agent's `developer_instructions`.

- [x] **Step 4: Validate and forward-test**

Run the official validator, parse the TOML, and repeat Task 1's same-version scenario with a fresh agent using the skill. Expected: a mutation-to-guard table, second-run consequences, and no false positive for documented safe patterns.

### Task 5: Migrate lifecycle hooks and Context7

**Files:**
- Create: `.codex/hooks.json`
- Create: `.codex/hooks/pre-edit-credential-policy.sh`
- Create: `.codex/hooks/post-edit-shell-lint.sh`
- Create: `.codex/config.toml`

**Interfaces:**
- Consumes: Codex hook JSON on stdin with `.cwd` and `.tool_input.command`.
- Produces: A `PreToolUse` deny decision for protected paths and post-edit lint enforcement for changed shell files.

- [x] **Step 1: Write failing synthetic hook checks**

Confirm both scripts are absent. Define payload fixtures containing `*** Add File: test.key`, `*** Update File: cli/forge-lite`, and `*** Update File: /tmp/broken.sh`.

- [x] **Step 2: Implement patch-path extraction and credential denial**

The pre-hook must inspect `Add`, `Update`, `Delete`, and `Move to` patch headers. Match `*.credentials`, `*.pem`, `*.key`, and `.forge-lite-credentials`; emit Codex's `hookSpecificOutput.permissionDecision = "deny"` shape.

- [x] **Step 3: Implement shell linting**

The post-hook must lint every existing added/updated `*.sh` path with `bash -n`, then `shellcheck -x` when installed. On failure, emit a model-visible message and exit nonzero.

- [x] **Step 4: Register hooks and Context7**

Register `Edit|Write` for both hook events in `.codex/hooks.json`. Configure:

```toml
[mcp_servers.deployment-context7]
url = "https://mcp.context7.com/mcp"
```

- [x] **Step 5: Verify scripts and payload behavior**

Run `bash -n`, `shellcheck -x` when installed, JSON/TOML parsers, and the three synthetic payloads. Expected: protected path denied, valid shell accepted, broken shell rejected.

### Task 6: Remove Claude artifacts and verify completeness

**Files:**
- Delete: `.claude/settings.json`
- Delete: `.claude/settings.local.json`
- Delete: `.claude/agents/*.md`
- Delete: `.claude/agent-memory/**/*.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: Fully migrated Codex artifacts from Tasks 2–5.
- Produces: A repository and local workspace with no active Claude-specific configuration.

- [x] **Step 1: Update ignore policy**

Remove the `.claude/` ignore entry. Keep `.codex/` and `.agents/` tracked because their project configuration is intentional.

- [x] **Step 2: Delete the migrated Claude tree**

Delete all files listed by `rg --files -uu .claude`, then remove empty directories.

- [x] **Step 3: Run the full migration audit**

```bash
! test -e .claude
! test -e CLAUDE.md
! rg -n -i 'claude|anthropic|\.claude' . --hidden -g '!.git/**' -g '!docs/superpowers/specs/2026-07-14-codex-migration-design.md' -g '!docs/superpowers/plans/2026-07-14-codex-migration.md'
git diff --check
```

Expected: no active Claude marker and no whitespace errors. The two migration documents may mention Claude historically.

- [x] **Step 4: Run all native validation**

Validate both skills, both agent TOML files, `hooks.json`, `config.toml`, both hook scripts, guidance size, and synthetic hook behavior. Review `git diff --stat` and `git status --short` for scope.

- [x] **Step 5: Commit the migration**

```bash
git add AGENTS.md .agents .codex .gitignore server docs CLAUDE.md
git commit -m "chore: migrate project guidance from Claude to Codex"
```

## Completion note

Completed on 2026-07-15. The native Codex migration, contributor onboarding,
legacy local-settings protection, and repository contract validations are in
place.
