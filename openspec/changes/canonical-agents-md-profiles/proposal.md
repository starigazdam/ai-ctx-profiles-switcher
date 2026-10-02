# Proposal

## Why

Issue #48 introduces canonical `AGENTS.md` profile projection as an additional profile format alongside the legacy `.github/skills` + `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` format. The companion system (`ai-task-scaffold`) shares this canonical root contract. While the supplied patch proposed projection for Mode A, it predates the 3-mode dispatch (Modes A, B, C from #36/#45/#46) and skill collision reconciliation (from #40/#47). Under Modes B and C, a canonical profile currently results in a silent no-op (instructions and `.agents/skills` are invisible and omitted, leaving `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` empty). This proposal specifies canonical profile projection, explicitly hard-fails canonical profile selection under Modes B and C before state mutation, reuses the merged warn-and-skip skill collision policy, and mode-gates `ctx check` instruction line validation.

## What Changes

- **Canonical profile detection**: For each resolved profile directory in an activation, the presence of a root-level `AGENTS.md` selects canonical mode for that directory. A directory without root `AGENTS.md` remains in legacy mode. Canonical and legacy profiles combine freely in an ordered activation under Mode A.
- **Mode A canonical projection**: For canonical profiles under Mode A, `ctx` copies root `AGENTS.md` into `COPILOT_HOME/instructions/ctx-profiles/<order>-<label>.instructions.md` with an `applyTo: "**"` frontmatter header, using stable order-prefixed filenames and tracking active projections in a `.ctx-managed` manifest. Canonical roots are excluded from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` (their instructions load from the synthetic home).
- **Canonical skill discovery**: Canonical profiles discover skills only from `.agents/skills/<name>` directories containing `SKILL.md`. Co-located `.github/skills` is ignored for canonical roots. Legacy profiles continue discovering skills from `.github/skills/<name>`.
- **Skill collision policy**: Reuses the PR #47 merged collision policy: cross-profile skill collisions warn and skip the colliding skill group during Mode A symlink reconciliation, and report `CHECK FAIL` in `ctx check`.
- **Mode B/C hard-fail preflight**: When `AI_CTX_PROFILES_COPILOT_MODE` selects `global-user` (Mode B) or `ephemeral-clean` (Mode C) and any selected profile or `.ctx` entry is a canonical profile (contains root `AGENTS.md`), activation SHALL hard-fail before any export, workspace file mutation, or home creation with a clear error message naming the canonical profile(s) and stating that canonical profiles require Mode A (`synthetic-home`).
- **`ctx check` mode awareness**: In Modes B and C, `instruction:<file>` checks SHALL be reported as `CHECK SKIP`, mirroring the existing `CHECK SKIP` handling for shared links and skill symlinks. In Mode A, `instruction:<file>` checks report `CHECK PASS` for valid projections, `CHECK FAIL` for missing, mismatched, or stale projections.
- **Lifecycle & cleanup**: Stale managed instruction projections are pruned on reactivation when selection changes. `ctx clear` preserves the home cache; `ctx clear --all` removes it.

## Capabilities

### Modified Capabilities

- `copilot-integration-modes`: Adds the fail-closed Mode B/C canonical-selection rule and updates the Mode A requirement to explicitly preserve PR #47's existing collision policy while allowing canonical projection.
- `profile-activation`: Adds the canonical-profile detection, Mode A instruction and skill projection, and existing warn-and-skip collision behavior.
- `dotctx-loading`: Adds canonical `.ctx` activation behavior and the mode-aware instruction audit contract, including `CHECK SKIP` under Modes B and C.

## Impact

- Affected files: `ctx.sh`, `ctx.ps1`, `openspec/specs/copilot-integration-modes/spec.md`, `openspec/specs/profile-activation/spec.md`, `openspec/specs/dotctx-loading/spec.md`, `README.md`, `tests/ctx.bats`, `tests/ctx.Tests.ps1`.
- Bash/zsh (`ctx.sh`) and PowerShell (`ctx.ps1`) parity strictly maintained.
- Non-indexed loop patterns used in `ctx.sh` to ensure zsh compatibility (no `for ((i=...))` regressions).
- No new external dependencies or daemons.
