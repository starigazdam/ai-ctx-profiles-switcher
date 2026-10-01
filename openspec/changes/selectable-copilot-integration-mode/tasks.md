# Tasks

## 1. Mode Selection and Validation

- [x] 1.1 Implement mode selection/validation in `ctx.sh`: read `AI_CTX_PROFILES_COPILOT_MODE` once per actual activation (manual `ctx <profile>...`, `ctx load`, and actual `.ctx` auto-load), accept exactly `synthetic-home`/`global-user`/`ephemeral-clean` case-sensitively, treat unset/empty as `synthetic-home` (byte-identical to today), and raise an error naming the allowed values for any other non-empty value before any export, workspace write, or home setup; never overwrite or unset the variable. Verify: `bats tests/ctx.bats` passes and a manual invalid-value run exits non-zero before any state change.
- [x] 1.2 Mirror 1.1 in `ctx.ps1` and verify parity. Verify: `Invoke-Pester tests/ctx.Tests.ps1` passes and a manual invalid-value run under `pwsh` exits non-zero before any state change.
- [x] 1.3 Add bats case: `home:` line + non-A mode conflict — the file is rejected before any state change and the previous context is untouched. Verify: `bats tests/ctx.bats`.
- [x] 1.4 Add bats case: validation-failure non-mutation — an invalid mode string leaves the previous context and all files untouched. Verify: `bats tests/ctx.bats`. (NOTE: tasks.md's text also says "...or comma path" — that sub-case is COPILOT_SKILLS_DIRS comma-rejection, which does not exist yet and belongs to task 3.6. Do NOT implement comma-rejection now. Cover only the invalid-mode-string sub-case here.)
- [x] 1.5 Mirror 1.3 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.
- [x] 1.6 Mirror 1.4 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.

## 2. Mode A Diagnostic Addition

- [x] 2.1 Keep Mode A byte-identical (explicit `synthetic-home` ≡ unset) and add the active-mode report to `ctx current`/`ctx check` in `ctx.sh`. Verify: existing `tests/ctx.bats` cases pass unchanged and a manual `ctx current` shows the mode.
- [x] 2.2 Mirror 2.1 in `ctx.ps1` (`Show-CtxCurrent`/`Test-CtxActivation`). Verify: existing `tests/ctx.Tests.ps1` cases pass unchanged and a manual `ctx current` under `pwsh` shows the mode.
- [x] 2.3 Add bats case: Mode A default-equivalence — unset vs explicit `synthetic-home` is byte-identical. Verify: `bats tests/ctx.bats`.
- [x] 2.4 Mirror 2.3 in Pester (`tests/ctx.Tests.ps1`). Verify: `Invoke-Pester tests/ctx.Tests.ps1`.

## 3. Mode B Environment/Home Semantics

- [x] 3.1 Implement Mode B activation in `ctx.sh`: never read/set/unset/create/delete `COPILOT_HOME`; leave any value (user-set, leftover from A/C, or unset) exactly as-is; do not restore or clear an old pointer on an A/C→B switch. Verify: `bats tests/ctx.bats` passes and a manual check that a pre-set `COPILOT_HOME` is untouched after `ctx <profile>`.
- [x] 3.2 Implement `COPILOT_SKILLS_DIRS` wiring in `ctx.sh` for Modes B/C: existing `<resolved-root>/.github/skills` dirs of the active entries, stable order, comma-joined, unset when none exist, fully replaced each activation, unset on `ctx clear` and on a successful switch into Mode A, and rejection of a resolved path containing a literal comma before export with no side effects. Verify: `bats tests/ctx.bats` passes with the new Mode B cases.
- [x] 3.3 Mirror 3.1 and 3.2 in `ctx.ps1`. Verify: `Invoke-Pester tests/ctx.Tests.ps1` passes with the new Mode B cases.
- [x] 3.4 Add bats case: Mode B with `COPILOT_HOME` unset, custom, and leftover-from-A-or-C — left exactly as-is across activation and clear. Verify: `bats tests/ctx.bats`.
- [x] 3.5 Add bats case: Mode B with no skill dirs present — `COPILOT_SKILLS_DIRS` left unset, not empty. Verify: `bats tests/ctx.bats`.
- [x] 3.6 Add bats case: directory-order stability and comma-rejection in `COPILOT_SKILLS_DIRS` (existing dirs listed in stable order; a resolved path with a literal comma rejected before export). Verify: `bats tests/ctx.bats`.
- [x] 3.7 Add bats case: B/C→A transition correctly unsets a session-set `COPILOT_SKILLS_DIRS` while never touching a user-set value. Verify: `bats tests/ctx.bats`.
- [x] 3.8 Mirror 3.4 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.
- [x] 3.9 Mirror 3.5 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.
- [x] 3.10 Mirror 3.6 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.
- [x] 3.11 Mirror 3.7 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.

## 4. Mode C Lifecycle

- [x] 4.1 Implement Mode C ephemeral-home creation in `ctx.sh` via `mktemp -d`: a fresh unique temp home on every activation (never reused or looked up by name), reject colliding paths and existing symlinks/junctions, export `COPILOT_HOME` only after successful creation, create no symlinks/copies into or out of real `~/.copilot`, no reconciliation, and leave the previous context and all files untouched on failure. Verify: `bats tests/ctx.bats` passes and a manual re-activation yields a different path.
- [x] 4.2 Implement Mode C cleanup semantics in `ctx.sh`: `ctx clear`/`ctx clear --all` unset `COPILOT_HOME` but never delete the ephemeral directory or its contents; report the retained path and the user's cleanup responsibility when leaving/replacing; no sweeper, trap, or background cleanup. Verify: `bats tests/ctx.bats` passes and a manual `ctx clear` leaves the directory on disk.
- [x] 4.3 Mirror 4.1 and 4.2 in `ctx.ps1` using `[System.IO.Path]::GetTempPath()` plus a GUID/random suffix, with no new dependency. Verify: `Invoke-Pester tests/ctx.Tests.ps1` passes with the new Mode C cases.
- [x] 4.4 Add bats case: Mode C uniqueness across repeated activations and retained-content-on-clear — each activation gets a different path and the directory survives `ctx clear`/`clear --all`. Verify: `bats tests/ctx.bats`.
- [x] 4.5 Mirror 4.4 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.

## 5. Mode-Aware clear/current/check

- [x] 5.1 Update `_ctx_clear`/`_ctx_current`/`_ctx_check` in `ctx.sh` for per-mode behavior: `clear`/`clear --all` never touch `COPILOT_HOME` under Mode B and never delete the ephemeral home under Mode C while still running common workspace/settings cleanup, and unset a session-set `COPILOT_SKILLS_DIRS`; `current` prints the active mode and, in B/C, the active `COPILOT_SKILLS_DIRS`; `check` reports the active mode, flags selector/active-mode mismatch, compares Mode B `COPILOT_HOME` only against the recorded value (including still-unset), requires the Mode C recorded ephemeral path to still exist as a real non-symlink directory, reports `CHECK SKIP` for the Mode-A-only shared-link and skill-symlink checks in B/C, and reports foreign env state as unknown. Verify: `bats tests/ctx.bats` passes with the new clear/current/check cases.
- [x] 5.2 Mirror 5.1 in `ctx.ps1` (`Clear-CtxContext`/`Show-CtxCurrent`/`Test-CtxActivation`). Verify: `Invoke-Pester tests/ctx.Tests.ps1` passes with the new clear/current/check cases.
- [x] 5.3 Add bats case: `ctx clear`/`ctx clear --all` per mode — Mode B leaves `COPILOT_HOME` untouched, Mode C unsets but never deletes, and common workspace/settings cleanup still runs. Verify: `bats tests/ctx.bats`.
- [x] 5.4 Add bats case: selector-changed-but-active-mode-unchanged reporting — `ctx current` reports the actually-active mode, not the stale selector, and `ctx check` flags the mismatch. Verify: `bats tests/ctx.bats`.
- [x] 5.5 Add bats case: `ctx check` per mode including the no-`.ctx` successful no-op, Mode B recorded-`COPILOT_HOME` comparison, Mode C recorded-path-exists check, `CHECK SKIP` for Mode-A-only checks in B/C, and foreign env state reported unknown. Verify: `bats tests/ctx.bats`.
- [x] 5.6 Mirror 5.3 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.
- [x] 5.7 Mirror 5.4 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.
- [x] 5.8 Mirror 5.5 in Pester. Verify: `Invoke-Pester tests/ctx.Tests.ps1`.

## 6. README Updates

- [x] 6.1 Document the three modes, the `AI_CTX_PROFILES_COPILOT_MODE` selector, Mode B's never-touches-`COPILOT_HOME` guidance (the user must clear/unset an old pointer themselves for Copilot's real default), Mode C's retained-ephemeral-dir cleanup responsibility (auth/session data, disk consumption, no auto-sweep), and `COPILOT_SKILLS_DIRS` semantics under "Skill discovery"/"Operational notes". Verify: manual read-through of the updated README sections.
- [x] 6.2 Update "Choosing a custom COPILOT_HOME location" to state that `home:` is Mode-A-only and rejected under Modes B/C, and update the testing/CI notes to reflect the two suites and the `windows-latest` Pester job without describing CI as Ubuntu-only. Verify: manual read-through of the updated sections.

## 7. CI and Review Gates

- [ ] 7.1 Confirm green CI on both suites at the implementation PR — bats on `tests/ctx.bats` and Pester on `tests/ctx.Tests.ps1` including the real `windows-latest` Pester job. Verify: GitHub Actions checks pass on that PR.
- [ ] 7.2 Obtain independent cross-provider review at the final implementation PR's exact head SHA. Verify: review approval recorded against that exact head.
- [ ] 7.3 Obtain explicit human merge approval for the implementation PR. Verify: maintainer approval/merge record.
- [ ] 7.4 State plainly in the implementation PR description that none of the gates in 7.1–7.3 are satisfied by this planning PR, which adds no CI workflow and triggers none. Verify: manual review of the PR description text.