# Spec Delta

## MODIFIED Requirements

### Requirement: ctx check

The system SHALL audit the current activation against the nearest `.ctx` file with `ctx check`, strictly read-only (never repairing, writing, deleting, or unsetting anything). It SHALL report per-item `CHECK PASS`, `CHECK FAIL`, or `CHECK SKIP` lines for environment variables, each shared Copilot symlink, each applicable skill, each applicable canonical instruction projection, and an adjacent workspace file, exiting 0 only when every applicable check passes. `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` SHALL pass only when its presence and value exactly match the expected activation state; for an all-canonical Mode A selection, a present empty value passes and an unset variable fails. This present-empty contract SHALL NOT be weakened to accept absent-as-empty on Unix pwsh/.NET 8 and earlier. A missing `.ctx` file SHALL be a successful no-op rather than a failure. When a `.ctx` file is found, the check SHALL also report the mode from the matching session-local activation record and SHALL flag a mismatch between the current selector and that recorded mode. The recorded mode, not the current selector, SHALL determine whether Mode A projections are audited; a selector mismatch SHALL NOT suppress applicable Mode A instruction or skill checks. If no matching local activation record exists, Mode-A-only projection checks SHALL be `CHECK SKIP` rather than inferred from environment paths or the raw selector.

Existing Mode A checks for legacy profiles SHALL remain unchanged. For a matching Mode A record, canonical instruction checks SHALL use the exact filename and content contract in `profile-activation`: report `CHECK PASS instruction:<file>` only when the projection is a regular non-symlink file, is listed in a valid manifest, and matches the expected header and source bytes; otherwise report `CHECK FAIL instruction:<file>`. A desired projection path occupied by an unmanifested file SHALL be reported as `CHECK FAIL instruction:<file>` without reading through or changing it. A valid manifest entry no longer expected by the current `.ctx` entries SHALL report `CHECK FAIL instruction:<file>: stale projection`. For a matching Mode A record with expected canonical entries, a missing, linked, unreadable, or malformed manifest SHALL report `CHECK FAIL instruction:manifest`. In Modes B and C, every applicable canonical instruction check SHALL be reported as `CHECK SKIP instruction:<file>`; these modes do not create canonical projections. If no matching activation record exists, canonical instruction checks SHALL also be skipped because no managed home can be attributed. The check SHALL NOT follow a symlink, junction, or other reparse point in either `instructions/` or `instructions/ctx-profiles/`; an unsafe projection directory SHALL report `CHECK FAIL instruction:<file>` under a matching Mode A record without reading through it.

For a matching Mode A record, skill checks SHALL use the same source selection as activation: canonical profiles contribute only `.agents/skills/<name>` directories containing a regular `SKILL.md`, and legacy profiles contribute `.github/skills/<name>`. The check SHALL compare each expected synthetic-home skill link to its resolved source, SHALL not treat a canonical directory lacking `SKILL.md` as a skill, and SHALL report existing case-insensitive collisions as `CHECK FAIL`. In Modes B and C, the Mode-A-only shared-link and skill-symlink checks SHALL be reported as `CHECK SKIP`, not `CHECK FAIL`. Mode B's `COPILOT_HOME` check SHALL compare only the exact value recorded at that activation, including when it was and remains unset, and SHALL never inspect global `~/.copilot`. Mode C's check SHALL require the recorded ephemeral path to still exist as a real non-symlink directory, SHALL NOT require it to be empty, and SHALL NOT inspect or repair its contents. A `COPILOT_HOME` or `COPILOT_SKILLS_DIRS` present without a matching local activation record SHALL be reported as unknown rather than attributed to a mode by guessing from its path or deleted.

#### Scenario: ctx check reports PASS for a matching activation

- **WHEN** the nearest `.ctx` file is correctly activated and a user runs `ctx check`
- **THEN** the check reports `CHECK PASS` for each applicable item and exits 0

#### Scenario: ctx check reports FAIL for drift without repairing it

- **WHEN** the current environment variables, Copilot symlinks, skills, canonical instruction projections, or adjacent workspace file differ from what the nearest `.ctx` file expects, and a user runs `ctx check`
- **THEN** the check reports `CHECK FAIL` for each drifted applicable item, exits non-zero, and does not repair, write, delete, or unset anything

#### Scenario: All-canonical custom directories require a present empty value

- **WHEN** an all-canonical Mode A activation is checked
- **THEN** `CHECK PASS COPILOT_CUSTOM_INSTRUCTIONS_DIRS` is reported only when the variable is set to the empty string; an unset variable is reported as `CHECK FAIL`

#### Scenario: ctx check reports SKIP for a probe it cannot run read-only

- **WHEN** a check would require invoking the external Copilot CLI, or a workspace audit cannot run because no Python interpreter is available
- **THEN** the check reports `CHECK SKIP` for that item and does not invoke the probe

#### Scenario: ctx check with no .ctx file is a successful no-op

- **WHEN** no `.ctx` file exists in the current directory tree and a user runs `ctx check`
- **THEN** the check reports that there is nothing to check and exits 0 without changing any state

#### Scenario: ctx check reports the active mode and flags a selector mismatch

- **WHEN** a `.ctx` file is found and a user runs `ctx check`
- **THEN** the check reports the recorded active mode and flags a mismatch between the selector that would be used now and the mode actually active

#### Scenario: Mode B check compares COPILOT_HOME only against the recorded value

- **WHEN** a user runs `ctx check` with an active Mode B activation
- **THEN** the current `COPILOT_HOME` is compared only against the exact value recorded at that activation, including when it was and still is unset, and the contents of the global `~/.copilot` are never inspected

#### Scenario: Mode C check requires the recorded ephemeral path to still exist

- **WHEN** a user runs `ctx check` with an active Mode C activation
- **THEN** the check requires the recorded ephemeral path to still exist as a real (non-symlink) directory, does not require it to be empty, and does not inspect or repair its contents

#### Scenario: Modes B and C report CHECK SKIP for Mode-A-only checks

- **WHEN** a user runs `ctx check` with a matching Mode B or Mode C activation record
- **THEN** Mode-A-only shared-link, skill-symlink, and canonical instruction checks report `CHECK SKIP` rather than `CHECK FAIL`

#### Scenario: Recorded Mode A checks continue despite a selector mismatch

- **WHEN** a matching Mode A activation record exists for canonical `.ctx` entries but the current selector has changed to Mode B or Mode C
- **THEN** `ctx check` reports the selector mismatch and still audits Mode A instruction and skill projections according to the recorded Mode A activation

#### Scenario: No matching activation record does not guess projection mode

- **WHEN** a `.ctx` file contains canonical entries but no matching local activation record exists
- **THEN** instruction and Mode-A-only skill projection checks report `CHECK SKIP` rather than inferring a mode from the selector or filesystem

#### Scenario: Canonical skill checks use the canonical source

- **WHEN** a matching Mode A activation record includes a canonical profile with a valid `.agents/skills/<name>/SKILL.md`
- **THEN** `ctx check` reports PASS only when the corresponding synthetic-home skill link targets that canonical skill directory

#### Scenario: A canonical skill directory without SKILL.md is not checked as a skill

- **WHEN** a canonical profile contains `.agents/skills/<name>` without a regular `SKILL.md`
- **THEN** that directory is not included in expected skill checks and does not cause a missing-skill failure

#### Scenario: Unsafe projection directories fail read-only checks

- **WHEN** a matching Mode A activation record exists and either instruction projection directory is a link, junction, or non-directory
- **THEN** `ctx check` reports `CHECK FAIL instruction:<file>` without reading through, repairing, or changing the unsafe path

#### Scenario: Foreign environment state is reported unknown by ctx check

- **WHEN** a `COPILOT_HOME` or `COPILOT_SKILLS_DIRS` exists in the environment with no matching local activation record and a user runs `ctx check`
- **THEN** the check reports the state as unknown rather than attributing it to a mode by guessing from its path or deleting it

## ADDED Requirements

### Requirement: Canonical profiles in .ctx activations

A `.ctx` entry whose resolved directory contains a root-level `AGENTS.md` SHALL be treated as a canonical profile in Mode A, with instructions and skills handled according to the `profile-activation` capability. Canonical entries MAY be combined with legacy entries in the order listed. Before an activation loaded from a `.ctx` file changes environment variables, writes the adjacent workspace file, or sets up or creates a Copilot home, it SHALL validate the selected mode against every resolved entry. If any entry is canonical and the selected mode is `global-user` or `ephemeral-clean`, the activation SHALL fail with a clear error identifying the canonical entry or entries and requiring `synthetic-home`. This applies to both `ctx load <path>` and the directory-change auto-load hook. On Unix pwsh/.NET 8 and earlier, an all-canonical Mode A `.ctx` activation SHALL additionally fail before any environment export, workspace write, or Copilot-home setup/creation, with an error stating that all-canonical Mode A requires pwsh/.NET 9+ on Unix; the `profile-activation` runtime guard applies to both `ctx load <path>` and the auto-load hook. On failure, the previously active context and files SHALL remain unchanged. Each actual auto-load trigger SHALL perform this validation; a repeated directory-change trigger SHALL report the error again and SHALL NOT suppress it or alter the prior context. Existing `.ctx` grammar, `home:`, `noautoload`, and hook triggering behavior SHALL otherwise remain unchanged.

#### Scenario: Canonical and legacy entries load together in Mode A

- **WHEN** a `.ctx` file lists canonical and legacy profile directories and Mode A is selected
- **THEN** all entries activate in listed order, with canonical and legacy behavior applied to their respective directories

#### Scenario: Canonical entry rejects explicit Mode B load without mutation

- **WHEN** a `.ctx` file contains a canonical entry and a user runs `ctx load <path>` under `global-user`
- **THEN** loading fails with an explanatory error before environment variables, the adjacent workspace file, or Copilot-home state are changed, and the previous context remains active

#### Scenario: Canonical entry rejects Mode C auto-load before home creation

- **WHEN** the directory-change auto-load hook finds a `.ctx` file with a canonical entry while `ephemeral-clean` is selected
- **THEN** auto-loading fails with an explanatory error before environment variables, the adjacent workspace file, or an ephemeral Copilot home are created, and the previous context remains active

#### Scenario: Repeated canonical auto-load failures are not suppressed

- **WHEN** the auto-load hook is triggered again for the same canonical `.ctx` file while Mode B or C is selected
- **THEN** the preflight error is reported again and the previous context remains unchanged

#### Scenario: Unix pwsh/.NET 8 and earlier reject all-canonical Mode A load before mutation

- **WHEN** a `.ctx` file lists only canonical entries and a user runs `ctx load <path>` under Mode A on Unix pwsh running .NET 8 or earlier
- **THEN** loading fails with a clear pwsh/.NET 9+ requirement before environment variables, the adjacent workspace file, Copilot-home state, or projections are changed, and the previous context remains active

#### Scenario: Unix pwsh/.NET 8 and earlier reject all-canonical Mode A auto-load

- **WHEN** the directory-change auto-load hook finds a `.ctx` file with only canonical entries under Mode A on Unix pwsh running .NET 8 or earlier
- **THEN** auto-loading fails with a clear pwsh/.NET 9+ requirement before any mutation, and the previous context remains active

#### Scenario: Mixed canonical .ctx entries keep behavior on Unix pwsh/.NET 8 and earlier

- **WHEN** a `.ctx` file lists both canonical and legacy entries under Mode A on Unix pwsh running .NET 8 or earlier
- **THEN** activation proceeds with the established behavior because the required custom-directories value is non-empty

#### Scenario: Legacy-only .ctx files keep existing behavior

- **WHEN** a `.ctx` file contains only entries without root-level `AGENTS.md` under any supported mode
- **THEN** the existing parsing, mode behavior, `home:`, `noautoload`, and hook behavior remain unchanged
