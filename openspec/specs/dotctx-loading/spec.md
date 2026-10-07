# .ctx Loading Specification

## Purpose

`.ctx` files associate a project directory with a set of context entries. They are loaded automatically when the shell changes into the directory tree, and can be loaded explicitly with `ctx load <path>`. `ctx check` audits the current activation against the nearest `.ctx` file without modifying anything.

## Requirements

### Requirement: .ctx file format and parsing

The system SHALL parse a `.ctx` file as lines of the form `<name>:<path>`. Blank lines and lines starting with `#` SHALL be ignored. The name and path on each side of the first `:` SHALL be trimmed of surrounding whitespace. A line may instead be a bare `noautoload` directive (case-insensitive) or a reserved `home:` directive. Each entry's target must be an existing directory, and the whole file must be validated before any state changes. The mode selector SHALL introduce no new `.ctx` line type: a line such as `mode:` or `copilot-mode:` SHALL be parsed as an ordinary `<name>:<path>` entry, not as a mode selector. The reserved `home:` directive SHALL be valid only under Mode A: when `AI_CTX_PROFILES_COPILOT_MODE` selects Mode B or Mode C and the `.ctx` file contains a `home:` line, the file SHALL be rejected before any state change, with the same invalid-file, previous-context-untouched semantics as other `.ctx` validation errors, and the `home:` line SHALL never be silently ignored or silently reinterpreted for Modes B and C. Parsing, `noautoload`, and hook triggering SHALL otherwise be unchanged by the mode selector.

#### Scenario: Comments and blank lines are ignored

- **WHEN** a `.ctx` file contains `#`-prefixed comment lines and blank lines alongside `<name>:<path>` entries
- **THEN** the comment and blank lines are ignored and only the entries are parsed

#### Scenario: Relative paths resolve against the .ctx file's own directory

- **WHEN** a `.ctx` entry has a relative path and a user loads the file
- **THEN** the path resolves against the directory containing the `.ctx` file, not the current working directory

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
- **THEN** the parser accepts exactly the existing line grammar (no mode directive), and `noautoload` handling and hook triggering are unchanged by the mode selector

### Requirement: Folder-local profiles roots directives

The PowerShell implementation (`ctx.ps1`) SHALL support two reserved `.ctx` directives that scope the profile roots for a single file: `config-root:` and `external-profiles-root:`. This capability is PowerShell-only; the Bash/zsh implementation (`ctx.sh`) SHALL NOT be required to implement it, and a `.ctx` file containing these directives is not portable to Bash. `config-root:<path>` SHALL override `AI_CTX_PROFILES_CONFIG_ROOT` for that parse and SHALL name a directory containing a `profiles` subdirectory. `external-profiles-root:<path>` SHALL override `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` for that parse and SHALL trust canonical profiles physically beneath it. Both directives SHALL be recognized in any line position, SHALL be collected and validated before any entry is resolved, and SHALL take precedence over the matching environment variables, so an invalid environment value cannot break a `.ctx` that supplies valid local roots. Paths SHALL be either relative to the directory containing the `.ctx` file or absolute and fully qualified; a Windows drive-relative (`C:foo`) or root-relative (`\foo`) value SHALL be rejected before normalization, while fully qualified drive (`C:\...`) and UNC (`\\server\share\...`) values SHALL be accepted. Each root SHALL exist, SHALL not be a filesystem root, and SHALL be physically resolved under the same containment rules as the environment roots, so junctions, symlinks, and sibling path-prefix escapes are rejected. The directives SHALL be metadata only: they SHALL NOT appear as context entries in `AI_CTX_PROFILES`, `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, the adjacent workspace file, or the skill inventory. Applying the directives SHALL NOT mutate, set, or clear either root environment variable and SHALL NOT require an approval prompt; the override is scoped to the single parse and SHALL NOT leak to manual activation or a later context. An invalid, missing, duplicate, or partially qualified root directive SHALL reject the whole `.ctx` file before any state change, with the same previous-context-untouched semantics as other `.ctx` validation errors. The directory-change auto-load hook SHALL treat a `.ctx` file's local root directives as trusted exactly as explicit `ctx load` does.

#### Scenario: PowerShell loads a .ctx with folder-local roots

- **WHEN** a `.ctx` file declares valid `config-root:` and `external-profiles-root:` directives and a user loads it with PowerShell
- **THEN** the entries resolve beneath those local roots, the directives are treated as metadata rather than entries, neither root environment variable is changed, and no approval prompt is required

#### Scenario: Local roots override invalid environment roots

- **WHEN** `AI_CTX_PROFILES_CONFIG_ROOT` and `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` hold invalid values and a `.ctx` file supplies valid `config-root:` and `external-profiles-root:` directives
- **THEN** the file loads, `ctx check` passes, and both environment variables remain unchanged

#### Scenario: Partially qualified Windows roots are rejected early

- **WHEN** a `.ctx` file declares `config-root:C:relative` or `external-profiles-root:\root-relative` on Windows
- **THEN** parsing fails with a precise "fully qualified" validation error before normalization, even when the target paths do not exist, and the previous context remains unchanged

#### Scenario: Invalid local roots reject the file before any state change

- **WHEN** a `.ctx` file declares a missing, duplicate, filesystem-root, or otherwise invalid `config-root:` or `external-profiles-root:` directive
- **THEN** the file is rejected before any state change and the previous context remains unchanged

#### Scenario: Bash is not portable with folder-local roots

- **WHEN** a `.ctx` file contains `config-root:` or `external-profiles-root:` and is loaded with Bash/zsh
- **THEN** Bash parses the lines as ordinary `<name>:<path>` entries (it does not implement the directives) and typically rejects the file, so the file is not portable to Bash

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

### Requirement: Canonical profiles in .ctx activations

A `.ctx` entry whose resolved directory contains a root-level `AGENTS.md` SHALL be treated as a canonical profile in Mode A, with instructions and skills handled according to the `profile-activation` capability. Canonical entries MAY be combined with legacy entries in the order listed. A `.ctx` entry that resolves to a canonical profile SHALL physically resolve beneath the configured primary profiles root (`$AI_CTX_PROFILES_CONFIG_ROOT/profiles`) or, when `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` is configured and valid, beneath that trusted external profiles root; otherwise activation SHALL fail before reading or projecting that profile, and non-canonical direct targets SHALL remain unaffected. Before an activation loaded from a `.ctx` file changes environment variables, writes the adjacent workspace file, or sets up or creates a Copilot home, it SHALL validate the selected mode against every resolved entry. If any entry is canonical and the selected mode is `global-user` or `ephemeral-clean`, the activation SHALL fail with a clear error identifying the canonical entry or entries and requiring `synthetic-home`. This applies to both `ctx load <path>` and the directory-change auto-load hook. On Unix pwsh/.NET 8 and earlier, an all-canonical Mode A `.ctx` activation SHALL additionally fail before any environment export, workspace write, or Copilot-home setup/creation, with an error stating that all-canonical Mode A requires pwsh/.NET 9+ on Unix; the `profile-activation` runtime guard applies to both `ctx load <path>` and the auto-load hook. On failure of the Mode B/C rejection, a trusted-root containment parse failure, or the Unix pwsh all-canonical runtime guard, the previously active context and files SHALL remain unchanged; this guarantee does not extend to a later Mode A projection or Copilot-home setup failure, whose failure atomicity remains unresolved (issue #63). Each actual auto-load trigger SHALL perform this validation; a repeated directory-change trigger SHALL report the error again and SHALL NOT suppress it or alter the prior context. Existing `.ctx` grammar, `home:`, `noautoload`, and hook triggering behavior SHALL otherwise remain unchanged.

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

#### Scenario: Direct canonical .ctx target outside all trusted roots is rejected

- **WHEN** a `.ctx` file lists a direct path that resolves to a canonical profile outside both the configured primary profiles root and any explicitly configured valid external profiles root
- **THEN** activation fails before reading or projecting that profile, and the previously active context remains unchanged

#### Scenario: Direct canonical .ctx target under the opted-in external profiles root is accepted

- **WHEN** `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` names a valid external directory and a `.ctx` file lists a direct path that resolves to a canonical profile beneath that trusted root
- **THEN** activation accepts the canonical target and projects it according to the `profile-activation` capability, and non-canonical direct targets remain unaffected
