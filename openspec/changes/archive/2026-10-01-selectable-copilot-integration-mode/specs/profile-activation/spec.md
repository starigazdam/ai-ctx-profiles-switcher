# Spec Delta

## MODIFIED Requirements

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