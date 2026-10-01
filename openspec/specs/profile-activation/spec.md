# Profile Activation Specification

## Purpose

`ctx <profile> [profile...]` activates one or more named profiles into the current shell session by setting `AI_CTX_PROFILES` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. `ctx clear` / `ctx clear --all` tear that activation down (and optionally remove the generated artifacts), and `ctx current` reports what is active. All profile names resolve against the profiles root (`$AI_CTX_PROFILES_CONFIG_ROOT/profiles`), never against arbitrary paths.

## Requirements

### Requirement: Manual profile activation

The system SHALL activate one or more profiles given as `ctx <profile> [profile...]` by resolving each name under the profiles root (`$AI_CTX_PROFILES_CONFIG_ROOT/profiles/<name>`) and setting `AI_CTX_PROFILES` to the profile names joined with `+` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` to the resolved profile directories joined with `,`. Resolution SHALL reject identifiers that escape the profiles root, such as `.`, `..`, or paths containing separators.

#### Scenario: Activate a single profile

- **WHEN** a user runs `ctx review` and a `review` directory exists under the profiles root
- **THEN** `AI_CTX_PROFILES` is set to `review` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` contains the resolved `review` directory

#### Scenario: Activate multiple profiles

- **WHEN** a user runs `ctx coding azure` and both `coding` and `azure` directories exist under the profiles root
- **THEN** `AI_CTX_PROFILES` is set to `coding+azure` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lists both resolved directories in invocation order, joined with `,`

#### Scenario: Unknown profile is rejected

- **WHEN** a user runs `ctx nonexistent` and no `nonexistent` directory exists under the profiles root
- **THEN** activation errors with a non-zero exit and a message that names the unknown profile, and does not set `AI_CTX_PROFILES` or `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`

#### Scenario: Traversal identifier is rejected

- **WHEN** a user runs `ctx ../escape` (or any identifier containing a path separator, `.`, or `..`)
- **THEN** activation errors with a non-zero exit and does not resolve a directory outside the profiles root

#### Scenario: Case-insensitive duplicate profiles are rejected before any state change

- **WHEN** a user runs `ctx review Review` and a context is already active
- **THEN** activation errors with a non-zero exit and a message naming the duplicate, and leaves the previously active `AI_CTX_PROFILES` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` untouched

### Requirement: Clear the active context

The system SHALL clear the active context with `ctx clear`, which unsets `AI_CTX_PROFILES`, `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, and `COPILOT_HOME` while leaving the synthetic home directory on disk. With `ctx clear --all` the system SHALL additionally remove the currently-selected synthetic home directory and ctx-owned generated artifacts, subject to safety validation.

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

### Requirement: Show the current context

The system SHALL report the active context with `ctx current`, printing the active profile(s) and the current environment variables when a context is active, or a no-active-context message when nothing is active.

#### Scenario: Active context is printed

- **WHEN** a context is active and a user runs `ctx current`
- **THEN** the active profile(s), `AI_CTX_PROFILES`, `COPILOT_HOME`, and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` are printed

#### Scenario: No active context message

- **WHEN** no context is active and a user runs `ctx current`
- **THEN** a message stating that no active AI context exists is printed and the command exits successfully