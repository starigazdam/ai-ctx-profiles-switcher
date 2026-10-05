# Profile Activation Specification

## Purpose

`ctx <profile> [profile...]` activates one or more named profiles into the current shell session by setting `AI_CTX_PROFILES` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. `ctx clear` / `ctx clear --all` tear that activation down (and optionally remove the generated artifacts), and `ctx current` reports what is active. Profile names resolve beneath `$AI_CTX_PROFILES_CONFIG_ROOT/profiles`; an explicitly configured `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` may add one more trusted physical root. Names never resolve against arbitrary paths.

## Requirements

### Requirement: Manual profile activation

The system SHALL activate one or more profiles given as `ctx <profile> [profile...]` by resolving each name under the profiles root (`$AI_CTX_PROFILES_CONFIG_ROOT/profiles/<name>`). When `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` is set, it SHALL be an absolute, existing directory other than a filesystem root; it adds a second trusted root and is searched only when no matching candidate exists in the primary root. Each identifier's physical target SHALL be an immediate child of one of the physically resolved trusted roots. The system SHALL set `AI_CTX_PROFILES` to profile names joined with `+` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` to resolved profile directories joined with `,`. Resolution SHALL reject identifiers that escape all trusted roots, such as `.`, `..`, or paths containing separators.

#### Scenario: Activate a single profile

- **WHEN** a user runs `ctx review` and a `review` directory exists under the profiles root
- **THEN** `AI_CTX_PROFILES` is set to `review` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` contains the resolved `review` directory

#### Scenario: Activate multiple profiles

- **WHEN** a user runs `ctx coding azure` and both `coding` and `azure` directories exist under the profiles root
- **THEN** `AI_CTX_PROFILES` is set to `coding+azure` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lists both resolved directories in invocation order, joined with `,`

#### Scenario: Profile under an opted-in external root is activated

- **WHEN** `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` names an existing absolute directory and a requested profile exists only as an immediate child of that physical root
- **THEN** the profile is activated using its physical directory, while the configured profiles root remains available and takes precedence for same-name profiles

#### Scenario: Invalid external root is rejected before state changes

- **WHEN** `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` is relative, missing, not a directory, or resolves to the filesystem root
- **THEN** activation errors before changing the active context

#### Scenario: Profile symlink outside all trusted roots is rejected

- **WHEN** a profile entry beneath either configured root physically resolves outside every trusted root
- **THEN** activation errors before changing the active context

#### Scenario: Unknown profile is rejected

- **WHEN** a user runs `ctx nonexistent` and no `nonexistent` directory exists under either the configured or opted-in external profiles root
- **THEN** activation errors with a non-zero exit and a message that names the unknown profile, and does not set `AI_CTX_PROFILES` or `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`

#### Scenario: Traversal identifier is rejected

- **WHEN** a user runs `ctx ../escape` (or any identifier containing a path separator, `.`, or `..`)
- **THEN** activation errors with a non-zero exit and does not resolve a directory outside any trusted profiles root

#### Scenario: Case-insensitive duplicate profiles are rejected before any state change

- **WHEN** a user runs `ctx review Review` and a context is already active
- **THEN** activation errors with a non-zero exit and a message naming the duplicate, and leaves the previously active `AI_CTX_PROFILES` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` untouched

### Requirement: Clear the active context

The system SHALL clear the active context with `ctx clear`, which unsets `AI_CTX_PROFILES`, `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, and `COPILOT_HOME` while leaving the synthetic home directory on disk. With `ctx clear --all` the system SHALL additionally remove the currently-selected synthetic home directory and ctx-owned generated artifacts, subject to safety validation. The clear behavior SHALL be mode-aware: `ctx clear` and `ctx clear --all` SHALL also unset `COPILOT_SKILLS_DIRS` when it was set by a prior Mode B or Mode C activation in this session; under Mode B they SHALL never touch `COPILOT_HOME`; and under Mode C they SHALL unset `COPILOT_HOME` without ever deleting the ephemeral directory or its contents. `ctx clear --all`'s common workspace-file and legacy settings-file cleanup SHALL still run in every mode.

#### Scenario: ctx clear unsets the environment variables

- **WHEN** a context is active and a user runs `ctx clear`
- **THEN** `AI_CTX_PROFILES`, `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, and `COPILOT_HOME` are unset and the synthetic home directory remains on disk

#### Scenario: ctx clear --all removes the synthetic home directory

- **WHEN** a context was activated and a user runs `ctx clear --all`
- **THEN** the currently-selected synthetic home directory is removed from disk

#### Scenario: ctx clear --all refuses to remove an unsafe or unselected home

- **WHEN** a user runs `ctx clear --all` and the computed home directory is not the actual currently-selected `COPILOT_HOME`, or fails the home-path safety validation
- **THEN** the system errors and refuses to remove the directory, leaving it on disk

#### Scenario: ctx clear --all removes a ctx-generated workspace file

- **WHEN** `ctx clear --all` runs and the adjacent `<folder-name>.code-workspace` file carries the exact `generatedBy: "ctx"` marker
- **THEN** the workspace file is removed from disk

#### Scenario: ctx clear --all preserves linked and unowned workspace files

- **WHEN** `ctx clear --all` runs and the adjacent workspace file is a symlink, or does not carry the `generatedBy: "ctx"` marker
- **THEN** the workspace file is preserved on disk and a warning is reported

#### Scenario: ctx clear --all removes legacy settings.local.json

- **WHEN** `ctx clear --all` runs and a `.github/copilot/settings.local.json` file exists next to the nearest `.ctx` file
- **THEN** the legacy settings file is removed

#### Scenario: ctx clear unsets a session-set COPILOT_SKILLS_DIRS

- **WHEN** `ctx clear` runs while `COPILOT_SKILLS_DIRS` was set by a prior Mode B or Mode C activation in this session
- **THEN** `COPILOT_SKILLS_DIRS` is unset along with the other context variables

#### Scenario: ctx clear under Mode B never touches COPILOT_HOME

- **WHEN** a user runs `ctx clear` with an active Mode B context and `COPILOT_HOME` holds any value, including a custom one or one left over from a prior activation
- **THEN** `AI_CTX_PROFILES`, `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, and `COPILOT_SKILLS_DIRS` are unset while `COPILOT_HOME` is left exactly as-is

#### Scenario: ctx clear --all under Mode B runs common cleanup and never touches COPILOT_HOME

- **WHEN** a user runs `ctx clear --all` with an active Mode B context
- **THEN** the common workspace-file and legacy settings-file cleanup still runs, and `COPILOT_HOME` is never read, set, unset, created, or deleted

#### Scenario: ctx clear under Mode C leaves the ephemeral directory on disk

- **WHEN** a user runs `ctx clear` with an active Mode C context
- **THEN** `COPILOT_HOME` and `COPILOT_SKILLS_DIRS` are unset for the session and the ephemeral directory and its contents remain on disk

#### Scenario: ctx clear --all under Mode C never deletes the ephemeral directory

- **WHEN** a user runs `ctx clear --all` with an active Mode C context
- **THEN** the common workspace-file and legacy settings-file cleanup still runs, and the ephemeral directory and its contents are never deleted

### Requirement: Show the current context

The system SHALL report the active context with `ctx current`, printing the active profile(s) and the current environment variables when a context is active, or a no-active-context message when nothing is active. `ctx current` SHALL also print the active Copilot integration mode — the mode of the matching activation, not merely the requested selector — and, in Modes B and C, the active `COPILOT_SKILLS_DIRS`.

#### Scenario: Active context is printed

- **WHEN** a context is active and a user runs `ctx current`
- **THEN** the active profile(s), `AI_CTX_PROFILES`, `COPILOT_HOME`, and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` are printed

#### Scenario: No active context message

- **WHEN** no context is active and a user runs `ctx current`
- **THEN** a message stating that no active AI context exists is printed and the command exits successfully

#### Scenario: Active context prints the active mode

- **WHEN** a context is active and a user runs `ctx current`
- **THEN** the active Copilot integration mode is printed, and a stale or mismatched `AI_CTX_PROFILES_COPILOT_MODE` sitting in the environment without a matching activation is not reported as the active mode

#### Scenario: Mode B or Mode C active context prints the active COPILOT_SKILLS_DIRS

- **WHEN** a context is active under Mode B or Mode C and a user runs `ctx current`
- **THEN** the active `COPILOT_SKILLS_DIRS` is printed alongside the other context variables and the active mode