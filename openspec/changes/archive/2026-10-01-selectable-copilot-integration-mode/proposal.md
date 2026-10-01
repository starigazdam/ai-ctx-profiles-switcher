# Proposal

## Why

Issue #36 asks for three selectable GitHub Copilot CLI integration modes; today `ctx` only supports the single synthetic `COPILOT_HOME` approach. This change adds an opt-in, environment-variable-driven mode selector while keeping today's behavior as the default, and resolves #36's open design questions as explicit decisions.

## What Changes

- Adds `AI_CTX_PROFILES_COPILOT_MODE`, a single case-sensitive selector (`synthetic-home` | `global-user` | `ephemeral-clean`) read once per actual activation; unset/empty means `synthetic-home` (byte-identical to today), and any other non-empty value is an error raised before any export, workspace write, or home setup.
- **Mode A (`synthetic-home`)** stays today's behavior unchanged, including all symlink reconciliation, skill-directory population, and cleanup rules; the only default-visible addition is that `ctx current`/`ctx check` also report the active mode.
- **Mode B (`global-user`)** never touches `COPILOT_HOME` (read, set, unset, create, or delete); a user who wants Copilot's real default clears or unsets an old pointer themselves.
- **Mode C (`ephemeral-clean`)** creates a fresh unique temp `COPILOT_HOME` on every activation, never deletes it, and reports the retained path when leaving.
- Adds `COPILOT_SKILLS_DIRS` (new; Modes B/C only; existing `.github/skills` directories of the active entries; fully replaced each activation; unset when none exist, on `ctx clear`, and on a successful switch into Mode A) and keeps `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` semantics unchanged in all three modes.
- `home:` in a `.ctx` file becomes Mode-A-only: rejected before any state change under Modes B/C. `.ctx` parsing, `noautoload`, and hook triggering otherwise stay unchanged.
- `ctx current`/`ctx check` become mode-aware (report the active mode, flag selector/active-mode mismatch, per-mode CHECK semantics) without any new on-disk registry.
- No **BREAKING** changes: everything is additive and opt-in.

## Capabilities

### New Capabilities
- `copilot-integration-modes`: contract for the `AI_CTX_PROFILES_COPILOT_MODE` selector and the Mode A/B/C home-handling and environment-wiring behaviors.

### Modified Capabilities
- `profile-activation`: `ctx clear`/`ctx clear --all` become mode-aware (Mode B never touches `COPILOT_HOME`, Mode C unsets but never deletes the ephemeral home, session-set `COPILOT_SKILLS_DIRS` is unset), and `ctx current` reports the active mode and, in Modes B/C, the active `COPILOT_SKILLS_DIRS`.
- `dotctx-loading`: `.ctx` parsing gains the `home:`-is-Mode-A-only rule and the `mode:`-line non-special-casing, and `ctx check` becomes mode-aware (reports active mode, flags selector/active-mode mismatch, per-mode CHECK PASS/FAIL/SKIP semantics).

## Impact

Affected files (future implementation only — this PR is planning artifacts, not code): `ctx.sh`, `ctx.ps1`, `README.md`, `tests/ctx.bats`, `tests/ctx.Tests.ps1`.

Bash/zsh (`ctx.sh`) and PowerShell (`ctx.ps1`) parity is required for all three modes; future tests use offline/temp fixtures only and never a developer's real `~/.copilot`. No new dependencies, no daemon/database/registry/new service, no `--add-dir` usage, no mutation of repo-local `.github/copilot/...` config, and no auto-migrating or deleting an existing synthetic home. Out of scope and unaffected: issues #40, #34, #22, #31, #32, #30. This PR itself adds no CI workflow and triggers none. See design.md for the full cross-cutting statements and citations.