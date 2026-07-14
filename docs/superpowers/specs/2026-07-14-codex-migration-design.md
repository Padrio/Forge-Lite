# Codex Migration Design

## Goal

Replace every Claude-specific project artifact with the closest native Codex mechanism while preserving project instructions, specialist review behavior, accumulated project knowledge, lifecycle enforcement, and Context7 access.

## Chosen Approach

Use project-local Codex primitives rather than a rename-only compatibility layer or a distributable plugin:

- `CLAUDE.md` becomes the repository-root `AGENTS.md`.
- Claude subagents become project-scoped custom agents in `.codex/agents/`.
- Their reusable review workflows become repo skills in `.agents/skills/`.
- Their persistent project memories become skill references loaded by those workflows.
- Claude hooks become trusted-project Codex hooks backed by deterministic Bash scripts.
- The Context7 Claude plugin becomes a project-scoped MCP server configuration.
- Claude-only references in code and documentation become `AGENTS.md` references.
- `.claude/` and `CLAUDE.md` are removed after their information is represented natively.

The machine-specific allowlist from `.claude/settings.local.json` is intentionally not promoted to shared project policy. This avoids committing broad shell and SSH approvals.

## Components

### Repository guidance

`AGENTS.md` retains all architecture and engineering standards from `CLAUDE.md`. A short specialist-review section tells Codex when to use the two review skills and their corresponding custom agents. Its total size must remain below Codex's default 32 KiB project-instruction limit.

### Specialist agents and skills

Each Claude agent maps to two cooperating Codex artifacts:

- A read-only `.codex/agents/<name>.toml` profile provides the specialist identity and delegation target.
- A `.agents/skills/<name>/SKILL.md` contains the reusable review procedure, output contract, and routing to project knowledge.

The custom agent loads and follows its matching skill before reviewing. This keeps the workflow usable both by a delegated subagent and by the main Codex agent. Existing memory notes move unchanged in meaning into `references/` under the matching skill and are linked from `SKILL.md`.

### Hooks

`.codex/hooks.json` uses `Edit|Write` matchers, which Codex maps to `apply_patch` edits. Hook scripts read Codex's `tool_input.command` patch payload.

- The pre-edit hook extracts every affected path and denies edits to credential/key files.
- The post-edit hook extracts added or updated shell files, runs `bash -n`, then runs `shellcheck -x` when available.

Scripts resolve paths from the hook payload's `cwd`, accept multi-file patches, handle deleted files safely, and emit Codex-compatible hook results.

### Context7

`.codex/config.toml` enables the official Context7 MCP endpoint at project scope without embedding credentials. The trusted-project requirement is documented in the handoff.

## Validation

- Baseline and forward scenarios verify that each migrated skill finds the intended compatibility or idempotency risks.
- Skill folders pass the official `quick_validate.py` validator.
- TOML and JSON parse successfully.
- Hook scripts pass `bash -n` and `shellcheck` when installed.
- Synthetic hook payloads verify allow, deny, and shell-lint behavior.
- `AGENTS.md` remains below 32 KiB and no live project file refers to Claude-specific paths or instructions.
- Git diff review confirms the old artifacts are fully replaced without unrelated changes.

## Scope Boundaries

No production provisioning behavior changes. No broad local command allowlist is committed. No user-level Codex settings outside this repository are modified.
