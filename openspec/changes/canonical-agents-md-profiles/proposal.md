# Proposal

## Why

Issue #48 adds canonical `AGENTS.md` profile directories as an alternative to legacy profiles that use `.github/skills` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. Its supplied patch predates the three-mode dispatch and PR #47's collision reconciliation, and the current OpenSpec clauses do not define how canonical roots affect custom-instruction directories or `ctx check`. Modes B and C cannot perform the proposed synthetic-home instruction projection and only wire `.github/skills`; accepting canonical profiles there would leave canonical instructions and skills unsupported. This proposal defines the Mode A behavior and rejects canonical selections in Modes B/C before state mutation.

## What Changes

- **Canonical profile detection**: A resolved directory with a root-level `AGENTS.md` is canonical; one without it stays legacy. Canonical and legacy profiles can be mixed in order under Mode A.
- **Mode A instruction projection**: Copy source bytes after the fixed UTF-8/LF header into `COPILOT_HOME/instructions/ctx-profiles/<order>-<label>.instructions.md`. Order is one-based, at least four-digit zero-padded; the label is the profile identifier or `.ctx` entry label, passed through the existing cross-shell sanitizer. Canonical roots are excluded from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`; mixed selections keep legacy roots in order, and all-canonical selections set the variable to the empty string.
- **Canonical skills**: Discover only `.agents/skills/<name>` directories containing a regular `SKILL.md`; ignore co-located `.github/skills`. Legacy profiles continue using `.github/skills`.
- **Collision behavior**: Feed both canonical and legacy skill candidates through PR #47's existing case-insensitive warn-and-skip collision handling. Do not add a duplicate-name preflight or change that policy.
- **Mode B/C guard**: Any canonical selection under `global-user` or `ephemeral-clean` fails before environment exports, workspace writes, or Copilot-home setup/creation, with an error naming the profile(s) and requiring `synthetic-home`.
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
- Bash/zsh and PowerShell parity is required. No new dependency or service.
