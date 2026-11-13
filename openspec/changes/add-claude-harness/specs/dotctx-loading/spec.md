# Spec Delta

## MODIFIED Requirements

### Requirement: .ctx file format and parsing

The system SHALL parse a `.ctx` file as lines of the form `<name>:<path>`. Blank lines and lines starting with `#` SHALL be ignored. The name and path on each side of the first `:` SHALL be trimmed of surrounding whitespace. A line may instead be a bare `noautoload` directive (case-insensitive), a reserved `home:` directive, or a reserved `harness:` directive specified by the `claude-harness` capability. Each entry's target must be an existing directory, and the whole file must be validated before any state changes. The mode selector SHALL introduce no new `.ctx` line type: a line such as `mode:` or `copilot-mode:` SHALL be parsed as an ordinary `<name>:<path>` entry, not as a mode selector. The reserved `home:` directive SHALL be valid only under Mode A: when `AI_CTX_PROFILES_COPILOT_MODE` selects Mode B or Mode C and the `.ctx` file contains a `home:` line, the file SHALL be rejected before any state change, with the same invalid-file, previous-context-untouched semantics as other `.ctx` validation errors, and the `home:` line SHALL never be silently ignored or silently reinterpreted for Modes B and C. Parsing, `noautoload`, and hook triggering SHALL otherwise be unchanged by the mode selector. The `harness:` key SHALL be matched case-insensitively, and a `.ctx` entry whose label is `harness` in any case SHALL be rejected with a reserved-directive error rather than parsed as an ordinary entry.

#### Scenario: Comments and blank lines are ignored

- **WHEN** a `.ctx` file contains `#`-prefixed comment lines and blank lines alongside `<name>:<path>` entries
- **THEN** the comment and blank lines are ignored and only the entries are parsed

#### Scenario: Relative paths resolve against the .ctx file's own directory

- **WHEN** a `.ctx` entry has a relative path and a user loads the file
- **THEN** the path resolves against the directory containing the `.ctx` file, not the current working directory

#### Scenario: Relative paths resolve the same way however the .ctx path is spelled

- **WHEN** `ctx load` receives a `.ctx` path containing `.` or `..` segments (for example `./task/.ctx`) and the same file is later found by auto-load or `ctx check` from the task folder
- **THEN** every relative entry resolves to the same normalized absolute directory, without `.` or `..` segments, in the exported environment, the generated workspace file, and the check, and auto-load does not re-activate the folder that `ctx load` just activated

#### Scenario: @profile resolves the name under a trusted profiles root

- **WHEN** a `.ctx` entry uses the value `@profile`
- **THEN** the entry name is resolved under the configured profiles root, or the explicitly configured external profiles root, with the same identifier rules and physical traversal/symlink protection as manual profile activation

#### Scenario: Canonical direct path requires a trusted physical root

- **WHEN** a `.ctx` entry points directly to a canonical profile outside the configured profiles root
- **THEN** it is accepted only when `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` is configured and the physically resolved target is beneath that trusted root; an absolute path alone does not bypass containment, and legacy direct-path behavior remains unchanged

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
- **THEN** the parser accepts exactly the existing line grammar plus the `harness:` directive (no mode directive), and `noautoload` handling and hook triggering are unchanged by the mode selector

#### Scenario: harness: is a reserved directive

- **WHEN** a `.ctx` file contains a line whose key is `harness` in any letter case
- **THEN** the line is parsed as the `harness:` directive of the `claude-harness` capability and never as an ordinary `<name>:<path>` entry
