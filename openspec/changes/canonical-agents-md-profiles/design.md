# Design

## Context

See `proposal.md` for motivation. Today, `ctx` supports three Copilot integration modes (`synthetic-home`, `global-user`, `ephemeral-clean`). Under Mode A (`synthetic-home`), `ctx` reconciles shared files and symlinks skills from `.github/skills/` into a synthetic `COPILOT_HOME`. Under Modes B and C, `ctx` exports `COPILOT_SKILLS_DIRS` pointing at `.github/skills` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` pointing at profile roots.

The canonical profile contract (introduced for cross-tool alignment with `ai-task-scaffold`) specifies:
1. Root `AGENTS.md` selects canonical mode.
2. Canonical skills live under `.agents/skills/<name>` and must contain `SKILL.md`. Co-located `.github/skills` is ignored.
3. Copilot CLI loads instructions from `COPILOT_HOME/instructions/**/*.instructions.md` with frontmatter `applyTo: "**"`.

Because Modes B and C do not construct a synthetic `COPILOT_HOME`, canonical instructions cannot be projected there. Furthermore, `COPILOT_SKILLS_DIRS` discovery currently only points to `.github/skills`. Therefore, selecting a canonical profile under Mode B or C is functionally unsupported and must be rejected fail-closed before any mutation.

Cross-cutting constraints:
- Parity between `ctx.sh` (bash/zsh) and `ctx.ps1` (PowerShell 5.1+ and pwsh).
- Zero C-style `for ((i=0; ...))` loops in `ctx.sh`: zsh arrays are 1-indexed by default, so indexed loops break unless `KSH_ARRAYS` is set. Use array streaming / list iteration patterns established by PR #47.
- Offline tests only; never touch real user credentials or real `~/.copilot`.

## Goals / Non-Goals

**Goals:**
- Detect canonical profiles by checking for root `AGENTS.md`.
- Under Mode A, project canonical instructions into `COPILOT_HOME/instructions/ctx-profiles/<order>-<label>.instructions.md` with `applyTo: "**"` frontmatter.
- Under Mode A, discover canonical skills from `.agents/skills/<name>` (requiring `SKILL.md`).
- Exclude canonical profile roots from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`.
- Hard-fail activations combining canonical profiles with Mode B or C before any state change.
- In `ctx check`, validate instruction projections under Mode A and emit `CHECK SKIP` under Modes B and C.
- Maintain full parity across Bash, zsh, and PowerShell.

**Non-Goals:**
- Extending Copilot CLI's Mode B/C environment discovery to canonical `.agents/skills` (Copilot CLI does not document env-based `.agents/skills` discovery).
- Expanding relative `@file` imports in canonical `AGENTS.md` (instructions are copied as self-contained files).
- Changing the `.ctx` file line grammar (no new directive needed; standard `<label>:<path>` entries resolve canonical directories naturally).

## Decisions

### Decision 1: Mode B/C preflight hard-fail on canonical profile selection

**Decision:** If `AI_CTX_PROFILES_COPILOT_MODE` is `global-user` or `ephemeral-clean`, and any resolved directory in the activation contains a root `AGENTS.md`, `ctx` immediately errors before modifying environment variables, writing workspace files, or creating ephemeral directories.

**Rationale:** Mode B does not manage `COPILOT_HOME`, and Mode C creates an empty ephemeral home without reconciling instructions. If canonical profiles were accepted under B or C, their instructions would be omitted from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` and never projected to `COPILOT_HOME`, resulting in a silent no-op. Failing fast follows the established fail-closed pattern in `ctx` (e.g. comma-in-skills-path rejection).

**Alternatives considered:**
- *Documented limitation (silent skip)*: Rejected because the user selected a profile expecting its instructions to apply; silent omission leads to subtle agent drift.
- *Fall back to adding canonical roots to `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`*: Rejected because `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` expects Copilot-style instructions or directories, not raw root `AGENTS.md` files without the synthetic projection structure.

### Decision 2: Reuse PR #47 warn-and-skip skill collision policy

**Decision:** Skill collisions across profiles (legacy or canonical) will reuse PR #47's merged behavior. In `ctx.sh`, reuse `_ctx_skill_canonical_name` for the existing canonical key and feed canonical skill directories into the existing Mode A collision reconciliation; in PowerShell, extend its matching reconciliation path. Warn and skip every colliding group during Mode A activation, and report `CHECK FAIL skill:<name>: name collision` in `ctx check`. Do not create a second preflight duplicate-name checker.

**Rationale:** The raw patch in issue #48 attempted a preflight abort on any duplicate skill name. However, PR #47 deliberately established the warn-and-skip policy for Mode A to prevent a single third-party profile collision from completely breaking activation. Reusing PR #47 keeps the codebase consistent, avoids maintaining two parallel collision checkers, and respects the normative spec clause.

### Decision 3: Managed instruction projection manifest and naming

**Decision:** Canonical instruction files are named `<04d-order>-<sanitized-label>.instructions.md` inside `COPILOT_HOME/instructions/ctx-profiles/`. A `.ctx-managed` text file tracks active projection filenames. On reactivation, any file recorded in `.ctx-managed` that is not in the current desired set is deleted. If no canonical profiles remain, the directory and empty parent instructions directories are cleaned up.

**Rationale:** The 4-digit order prefix ensures stable lexical ordering in Copilot CLI. The `.ctx-managed` manifest distinguishes ctx-generated projections from any user-placed files.

### Decision 4: `ctx check` reporting semantics

**Decision:**
- Under Mode A: For each canonical profile in the active context, `ctx check` verifies that `<order>-<label>.instructions.md` exists with exact header and content matches (`CHECK PASS instruction:<file>` or `CHECK FAIL`). Stale entries in `.ctx-managed` trigger `CHECK FAIL instruction:<file>: stale projection`.
- Under Modes B and C: `instruction:<file>` checks report `CHECK SKIP`, exactly as shared links and skill symlinks do.

**Rationale:** In Modes B and C, `COPILOT_HOME` is either untouched (B) or unreconciled (C), so instructions cannot and should not be present in `COPILOT_HOME`. Reporting `CHECK SKIP` adheres to the principle that unmanaged subsystem state audits must skip, not fail.

### Decision 5: Zsh compatibility for loop iteration

**Decision:** Avoid all C-style `for ((i = 0; ...))` loops in `ctx.sh`. Use list iteration (`for item in "${list[@]}"`) or `while [ "$#" -gt 0 ]` with counters.

**Rationale:** In zsh, arrays are 1-indexed by default, making 0-indexed C loops error-prone or incompatible without special option flags. PR #47 explicitly removed all C-style loops from `ctx.sh` for this reason.

## Risks / Trade-offs

- [Risk] User attempts to use canonical profiles in Mode B or Mode C → Mitigation: Clear error message explaining that canonical profiles require `synthetic-home` (Mode A) because they rely on instruction projection.
- [Risk] Canonical `AGENTS.md` containing relative file paths or `@imports` → Mitigation: Document in README that projected instructions are copied as-is with `applyTo: "**"` frontmatter; instructions should be self-contained.
- [Risk] Skill collision between a legacy `.github/skills/<name>` and canonical `.agents/skills/<name>` → Mitigation: Both feed into the unified collision detection mechanism from PR #47 and are skipped if names collide.
