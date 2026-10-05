# Proposal

## Why

Issue #48 adds canonical `AGENTS.md` profile directories as an alternative to legacy profiles that use `.github/skills` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. Its supplied patch predates the three-mode dispatch and PR #47's collision reconciliation, and the current OpenSpec clauses do not define how canonical roots affect custom-instruction directories or `ctx check`. Modes B and C cannot perform the proposed synthetic-home instruction projection and only wire `.github/skills`; accepting canonical profiles there would leave canonical instructions and skills unsupported. This proposal defines the Mode A behavior and rejects canonical selections in Modes B/C before state mutation.

A Unix PowerShell runtime limitation constrains the all-canonical Mode A contract. Before .NET 9, `Environment.SetEnvironmentVariable(name, string.Empty)` deletes the variable rather than setting it empty, so pwsh running on .NET 8 and earlier cannot produce the required present-empty `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` value on Unix. All-canonical Mode A therefore requires Unix pwsh running on .NET 9+; older Unix pwsh/.NET versions must fail clearly before any mutation rather than silently drop the required empty value. The present-empty result was verified on the native-Windows pwsh runtime exercised by PR CI, whose exact PowerShell/.NET version is not logged, and no version-wide PowerShell 7+ claim is made. Windows PowerShell 5.1 all-canonical present-empty behavior is unverified and tracked by issue #63, and this proposal does not claim it. This proposal records that platform constraint.

## What Changes

- **Canonical profile detection**: A resolved directory with a root-level `AGENTS.md` is canonical; one without it stays legacy. Canonical and legacy profiles can be mixed in order under Mode A.
- **Mode A instruction projection**: Copy source bytes after the fixed UTF-8/LF header into `COPILOT_HOME/instructions/ctx-profiles/<order>-<label>.instructions.md`. Order is one-based, at least four-digit zero-padded; the label is the profile identifier or `.ctx` entry label, passed through the existing cross-shell sanitizer. Canonical roots are excluded from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`; mixed selections keep legacy roots in order, and all-canonical selections set the variable to the present-empty value on supported runtimes (Bash/zsh, native-Windows pwsh (the runtime exercised by PR CI; exact PowerShell/.NET version is not logged, so no version-wide PowerShell 7+ claim), or Unix pwsh running .NET 9+). On Unix pwsh running .NET 8 and earlier an all-canonical selection instead rejects before mutation under the Unix pwsh runtime guard below. Windows PowerShell 5.1 all-canonical present-empty behavior is unverified and tracked by issue #63.
- **Canonical skills**: Discover only `.agents/skills/<name>` directories containing a regular `SKILL.md`; ignore co-located `.github/skills`. Legacy profiles continue using `.github/skills`.
- **Collision behavior**: Feed both canonical and legacy skill candidates through PR #47's existing case-insensitive warn-and-skip collision handling. Do not add a duplicate-name preflight or change that policy.
- **Mode B/C guard**: Any canonical selection under `global-user` or `ephemeral-clean` fails before environment exports, workspace writes, or Copilot-home setup/creation, with an error naming the profile(s) and requiring `synthetic-home`.
- **Unix pwsh runtime guard**: On Unix (Linux/macOS) PowerShell, all-canonical Mode A requires pwsh running on .NET 9+. pwsh running on .NET 8 and earlier removes an empty value when it is assigned, so the required present-empty `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` value cannot be produced; a canonical-only Mode A selection under those versions fails before any environment export, workspace write, or Copilot-home setup/creation, with an error stating that all-canonical Mode A requires pwsh/.NET 9+ on Unix. Mixed canonical+legacy and legacy-only selections are unaffected, and `ctx check` keeps the present-empty contract.
- **Read-only checks**: Mode A checks canonical instruction bytes and canonical skill links. B/C report `CHECK SKIP instruction:<file>` for canonical entries. A matching activation record determines check mode; changing the selector reports a mismatch but does not suppress checks for the recorded mode. Without a matching activation record, Mode-A-only projection checks are skipped rather than inferred.
- **Filesystem safety**: Never traverse symlinks/junctions in the instruction projection parent directories or manifest. Preserve unmanaged files and fail closed on an unsafe/unreadable manifest.

## Capabilities

### Modified Capabilities

- `copilot-integration-modes`: Refines Mode A behavior and custom-instruction directory semantics, and adds the Mode B/C canonical-selection rejection.
- `profile-activation`: Refines manual activation directory wiring and adds canonical instruction/skill projection behavior.
- `dotctx-loading`: Adds canonical `.ctx` activation behavior and extends `ctx check` for canonical instructions, skills, recorded-mode attribution, and B/C `CHECK SKIP` output.

## Impact

- This proposal PR changes only `openspec/changes/canonical-agents-md-profiles/**`. It does not edit the main `openspec/specs/**`, implementation code, README, tests, or CI. The main specs are the targets for synchronization/archive after the implementation is approved and completed.
- Eventual implementation scope: `ctx.sh`, `ctx.ps1`, `README.md`, `tests/ctx.bats`, and `tests/ctx.Tests.ps1`.
- Bash/zsh and the native-Windows pwsh runtime exercised by current PR CI (exact PowerShell/.NET version is not logged, so no version-wide PowerShell 7+ claim) retain all-canonical Mode A behavior: `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` is present and empty. Windows PowerShell 5.1 all-canonical present-empty behavior is unverified and tracked by issue #63; no present-empty success is claimed there. On Unix PowerShell, all-canonical Mode A is supported only on pwsh running on .NET 9+; older Unix pwsh/.NET versions fail before mutation rather than weakening the present-empty contract. No new dependency or service.
