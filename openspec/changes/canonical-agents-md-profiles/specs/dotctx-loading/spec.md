# Spec Delta

## ADDED Requirements

### Requirement: Canonical profiles in .ctx activations

A `.ctx` entry whose resolved directory contains a root-level `AGENTS.md` SHALL be treated as a canonical profile in Mode A, with instructions and skills handled according to the `profile-activation` capability. Canonical entries MAY be combined with legacy entries in the order listed. Before an activation loaded from a `.ctx` file changes environment variables, writes the adjacent workspace file, or sets up or creates a Copilot home, it SHALL validate the selected mode against every resolved entry. If any entry is canonical and the selected mode is `global-user` or `ephemeral-clean`, the activation SHALL fail with a clear error identifying the canonical entry or entries and requiring `synthetic-home`. This applies to both `ctx load <path>` and the directory-change auto-load hook. Existing `.ctx` grammar, `home:`, `noautoload`, and hook triggering behavior SHALL otherwise remain unchanged.

#### Scenario: Canonical and legacy entries load together in Mode A

- **WHEN** a `.ctx` file lists canonical and legacy profile directories and Mode A is selected
- **THEN** all entries activate in listed order, with canonical and legacy behavior applied to their respective directories

#### Scenario: Canonical entry rejects explicit Mode B load without mutation

- **WHEN** a `.ctx` file contains a canonical entry and a user runs `ctx load <path>` under `global-user`
- **THEN** loading fails with an explanatory error before environment variables, the adjacent workspace file, or Copilot-home state are changed

#### Scenario: Canonical entry rejects Mode C auto-load before home creation

- **WHEN** the directory-change auto-load hook finds a `.ctx` file with a canonical entry while `ephemeral-clean` is selected
- **THEN** auto-loading fails with an explanatory error before environment variables, the adjacent workspace file, or an ephemeral Copilot home are created

#### Scenario: Legacy-only .ctx files keep existing behavior

- **WHEN** a `.ctx` file contains only entries without root-level `AGENTS.md` under any supported mode
- **THEN** the existing parsing, mode behavior, `home:`, `noautoload`, and hook behavior remain unchanged

### Requirement: ctx check audits canonical instruction projections by mode

`ctx check` SHALL remain strictly read-only when auditing canonical instructions from the nearest `.ctx` file. For each canonical entry, Mode A SHALL report `CHECK PASS instruction:<file>` only when the managed projection exists as a regular non-symlink file and its contents exactly match the expected frontmatter and source `AGENTS.md`; otherwise it SHALL report `CHECK FAIL instruction:<file>`. It SHALL also report `CHECK FAIL instruction:<file>: stale projection` for stale projection filenames recorded in the ctx-managed manifest. In Modes B and C, every applicable `instruction:<file>` check SHALL be reported as `CHECK SKIP`, not `CHECK FAIL`, because those modes do not project canonical instructions. This mode-specific rule SHALL hold even though canonical-profile activation itself is rejected in Modes B and C, and SHALL not alter the existing Mode A-only shared-link or skill-symlink checks.

#### Scenario: Mode A instruction projection passes when exact

- **WHEN** a canonical `.ctx` entry's managed instruction file exists and exactly matches its expected header and source contents
- **THEN** `ctx check` reports `CHECK PASS instruction:<file>`

#### Scenario: Mode A instruction projection fails when missing or mismatched

- **WHEN** a canonical `.ctx` entry's instruction projection is missing, is a symlink, or differs from the expected header or source contents
- **THEN** `ctx check` reports `CHECK FAIL instruction:<file>` and does not repair or modify it

#### Scenario: Mode A stale manifest projection fails

- **WHEN** the ctx-managed manifest lists an instruction projection that is not expected by the current `.ctx` entries
- **THEN** `ctx check` reports `CHECK FAIL instruction:<file>: stale projection` without removing the file

#### Scenario: Modes B and C skip canonical instruction checks

- **WHEN** a `.ctx` file contains canonical entries and `ctx check` runs while the selected mode is `global-user` or `ephemeral-clean`
- **THEN** each corresponding instruction check reports `CHECK SKIP instruction:<file>` rather than `CHECK FAIL`, and no state is changed
