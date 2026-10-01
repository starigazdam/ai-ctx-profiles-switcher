# Spec Delta

## MODIFIED Requirements

### Requirement: .ctx file format and parsing

The system SHALL parse a `.ctx` file as lines of the form `<name>:<path>`. Blank lines and lines starting with `#` SHALL be ignored. The name and path on each side of the first `:` SHALL be trimmed of surrounding whitespace. A line may instead be a bare `noautoload` directive (case-insensitive) or a reserved `home:` directive. Each entry's target must be an existing directory, and the whole file must be validated before any state changes. The mode selector SHALL introduce no new `.ctx` line type: a line such as `mode:` or `copilot-mode:` SHALL be parsed as an ordinary `<name>:<path>` entry, not as a mode selector. The reserved `home:` directive SHALL be valid only under Mode A: when `AI_CTX_PROFILES_COPILOT_MODE` selects Mode B or Mode C and the `.ctx` file contains a `home:` line, the file SHALL be rejected before any state change, with the same invalid-file, previous-context-untouched semantics as other `.ctx` validation errors, and the `home:` line SHALL never be silently ignored or silently reinterpreted for Modes B and C. Parsing, `noautoload`, and hook triggering SHALL otherwise be unchanged by the mode selector.

#### Scenario: Comments and blank lines are ignored

- **WHEN** a `.ctx` file contains `#`-prefixed comment lines and blank lines alongside `<name>:<path>` entries
- **THEN** the comment and blank lines are ignored and only the entries are parsed

#### Scenario: Relative paths resolve against the .ctx file's own directory

- **WHEN** a `.ctx` entry has a relative path and a user loads the file
- **THEN** the path resolves against the directory containing the `.ctx` file, not the current working directory

#### Scenario: @profile resolves the name under the profiles root

- **WHEN** a `.ctx` entry uses the value `@profile`
- **THEN** the entry name is resolved under the profiles root with the same identifier rules and traversal/symlink-escape protection as manual profile activation

#### Scenario: Duplicate entry labels are rejected case-insensitively

- **WHEN** two entries in a `.ctx` file share the same label differing only in case, and the label is not `home`
- **THEN** the file is rejected with a non-zero exit before any state changes

#### Scenario: Duplicate canonical targets are rejected

- **WHEN** two entries with different labels in a `.ctx` file resolve to the same real directory after path resolution
- **THEN** the file is rejected with a non-zero exit before any state changes

#### Scenario: home: is a reserved directive

- **WHEN** a `.ctx` file contains a `home:` line
- **THEN** it sets the custom `COPILOT_HOME`-equivalent location rather than acting as a regular entry, and a second `home:` line is rejected with a non-zero exit

#### Scenario: mode: and copilot-mode: lines are ordinary entries, not selectors

- **WHEN** a `.ctx` file contains a line beginning with `mode:` or `copilot-mode:` under any mode selector
- **THEN** the line is parsed as an ordinary `<name>:<path>` entry, so it is rejected exactly like any other entry whose target is missing or invalid, and is never treated as a mode selector

#### Scenario: home: with Mode B or Mode C selected is rejected before any state change

- **WHEN** `AI_CTX_PROFILES_COPILOT_MODE` selects Mode B or Mode C and the `.ctx` file being loaded contains a `home:` line
- **THEN** the file is rejected before any state change with the same invalid-file, previous-context-untouched semantics as other `.ctx` validation errors, and the `home:` line is never silently ignored or reinterpreted

#### Scenario: The mode selector adds no new .ctx line type and leaves hooking unchanged

- **WHEN** a `.ctx` file is loaded or auto-loaded under any mode
- **THEN** the parser accepts exactly the existing line grammar (no mode directive), and `noautoload` handling and hook triggering are unchanged by the mode selector

### Requirement: ctx check

The system SHALL audit the current activation against the nearest `.ctx` file with `ctx check`, strictly read-only (never repairing, writing, deleting, or unsetting anything). It SHALL report per-item `CHECK PASS`, `CHECK FAIL`, or `CHECK SKIP` lines for the environment variables, each shared Copilot symlink, each skill, and an adjacent workspace file, exiting 0 only when every applicable check passes. A missing `.ctx` file SHALL be a successful no-op rather than a failure. When a `.ctx` file is found, the check SHALL also report the active mode and SHALL flag a mismatch between the selector that would be used now and the mode actually active. Mode A SHALL keep every existing check unchanged. Mode B's check SHALL compare the current `COPILOT_HOME` only against the exact value recorded at that activation, including when it was and still is unset, and SHALL never inspect the contents of the global `~/.copilot`. Mode C's check SHALL require the recorded ephemeral path to still exist as a real (non-symlink) directory, SHALL NOT require it to be empty, and SHALL NOT inspect or repair its contents. In Modes B and C, the Mode-A-only shared-link and skill-symlink checks SHALL be reported as `CHECK SKIP`, not `CHECK FAIL`. A `COPILOT_HOME` or `COPILOT_SKILLS_DIRS` present in the environment with no matching local activation record SHALL be reported as unknown rather than attributed to a mode by guessing from its path or deleted.

#### Scenario: ctx check reports PASS for a matching activation

- **WHEN** the nearest `.ctx` file is correctly activated and a user runs `ctx check`
- **THEN** the check reports `CHECK PASS` for each applicable item and exits 0

#### Scenario: ctx check reports FAIL for drift without repairing it

- **WHEN** the current environment variables, Copilot symlinks, skills, or adjacent workspace file differ from what the nearest `.ctx` file expects, and a user runs `ctx check`
- **THEN** the check reports `CHECK FAIL` for each drifted item, exits non-zero, and does not repair, write, delete, or unset anything

#### Scenario: ctx check reports SKIP for a probe it cannot run read-only

- **WHEN** a check would require invoking the external Copilot CLI, or a workspace audit cannot run because no Python interpreter is available
- **THEN** the check reports `CHECK SKIP` for that item and does not invoke the probe

#### Scenario: ctx check with no .ctx file is a successful no-op

- **WHEN** no `.ctx` file exists in the current directory tree and a user runs `ctx check`
- **THEN** the check reports that there is nothing to check and exits 0 without changing any state

#### Scenario: ctx check reports the active mode and flags a selector mismatch

- **WHEN** a `.ctx` file is found and a user runs `ctx check`
- **THEN** the check reports the active mode and flags a mismatch between the selector that would be used now and the mode actually active

#### Scenario: Mode B check compares COPILOT_HOME only against the recorded value

- **WHEN** a user runs `ctx check` with an active Mode B activation
- **THEN** the current `COPILOT_HOME` is compared only against the exact value recorded at that activation, including when it was and still is unset, and the contents of the global `~/.copilot` are never inspected

#### Scenario: Mode C check requires the recorded ephemeral path to still exist

- **WHEN** a user runs `ctx check` with an active Mode C activation
- **THEN** the check requires the recorded ephemeral path to still exist as a real (non-symlink) directory, does not require it to be empty, and does not inspect or repair its contents

#### Scenario: Modes B and C report CHECK SKIP for Mode-A-only checks

- **WHEN** a user runs `ctx check` with an active Mode B or Mode C activation
- **THEN** the Mode-A-only shared-link and skill-symlink checks report `CHECK SKIP` rather than `CHECK FAIL`

#### Scenario: Foreign environment state is reported unknown by ctx check

- **WHEN** a `COPILOT_HOME` or `COPILOT_SKILLS_DIRS` exists in the environment with no matching local activation record and a user runs `ctx check`
- **THEN** the check reports the state as unknown rather than attributing it to a mode by guessing from its path or deleting it