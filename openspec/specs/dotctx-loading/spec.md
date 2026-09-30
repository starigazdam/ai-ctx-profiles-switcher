# .ctx Loading Specification

## Purpose

`.ctx` files associate a project directory with a set of context entries. They are loaded automatically when the shell changes into the directory tree, and can be loaded explicitly with `ctx load <path>`. `ctx check` audits the current activation against the nearest `.ctx` file without modifying anything.

## Requirements

### Requirement: .ctx file format and parsing

The system SHALL parse a `.ctx` file as lines of the form `<name>:<path>`. Blank lines and lines starting with `#` SHALL be ignored. The name and path on each side of the first `:` SHALL be trimmed of surrounding whitespace. A line may instead be a bare `noautoload` directive (case-insensitive) or a reserved `home:` directive. Each entry's target must be an existing directory, and the whole file must be validated before any state changes.

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

### Requirement: .ctx auto-loading on directory change

The system SHALL auto-load the nearest `.ctx` file (searching from the current directory upward) when the shell changes into a directory within its tree. A file containing a bare `noautoload` directive (case-insensitive) SHALL be skipped by the auto-load hook; the hook evaluates `noautoload` when triggered by a directory change.

#### Scenario: Directory change auto-loads the nearest .ctx file

- **WHEN** the shell changes directory into a directory that has a `.ctx` file or is under one
- **THEN** the nearest `.ctx` file is loaded, setting `AI_CTX_PROFILES` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` from its entries

#### Scenario: noautoload skips the auto-load hook

- **WHEN** a `.ctx` file contains a bare `noautoload` line (case-insensitive) and the auto-load hook is triggered by a directory change into its tree
- **THEN** the hook skips the file and does not load it automatically

### Requirement: Explicit ctx load

The system SHALL load a `.ctx` file explicitly with `ctx load <path>`. Explicit loading SHALL bypass the `noautoload` directive but still fully validate the file, and SHALL error without changing the current context when the file is missing or invalid.

#### Scenario: ctx load loads a .ctx file by explicit path

- **WHEN** a user runs `ctx load <path-to-.ctx-file>` and the file exists and is valid
- **THEN** the file is loaded and its entries become the active context

#### Scenario: ctx load bypasses noautoload but still validates

- **WHEN** a user runs `ctx load <path>` on a `.ctx` file that contains a `noautoload` directive
- **THEN** the file is still loaded explicitly, and file validation still applies so an invalid file is rejected

#### Scenario: ctx load rejects a missing or missing-argument file

- **WHEN** a user runs `ctx load` with no path, or with a path that does not exist
- **THEN** the command errors with a non-zero exit and does not change the current context

### Requirement: ctx check

The system SHALL audit the current activation against the nearest `.ctx` file with `ctx check`, strictly read-only (never repairing, writing, deleting, or unsetting anything). It SHALL report per-item `CHECK PASS`, `CHECK FAIL`, or `CHECK SKIP` lines for the environment variables, each shared Copilot symlink, each skill, and an adjacent workspace file, exiting 0 only when every applicable check passes. A missing `.ctx` file SHALL be a successful no-op rather than a failure.

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