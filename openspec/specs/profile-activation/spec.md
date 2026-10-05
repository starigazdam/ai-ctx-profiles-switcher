# Profile Activation Specification

## Purpose

`ctx <profile> [profile...]` activates one or more named profiles into the current shell session by setting `AI_CTX_PROFILES` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. `ctx clear` / `ctx clear --all` tear that activation down (and optionally remove the generated artifacts), and `ctx current` reports what is active. Profile names resolve beneath `$AI_CTX_PROFILES_CONFIG_ROOT/profiles`; an explicitly configured `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` may add one more trusted physical root. Names never resolve against arbitrary paths.

## Requirements

### Requirement: Manual profile activation

The system SHALL activate one or more profiles given as `ctx <profile> [profile...]` by resolving each name under the profiles root (`$AI_CTX_PROFILES_CONFIG_ROOT/profiles/<name>`). When `AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT` is set, it SHALL be an absolute, existing directory other than a filesystem root; it adds a second trusted root and is searched only when no matching candidate exists in the primary root. Each identifier's physical target SHALL be an immediate child of one of the physically resolved trusted roots. The system SHALL set `AI_CTX_PROFILES` to the profile names joined with `+`. In Mode A, `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` SHALL contain the resolved directories of selected profiles without a root-level `AGENTS.md`, in invocation order and comma-joined; canonical profile directories SHALL be omitted, and if every selected profile is canonical the variable SHALL be set to the empty string, subject to the runtime guard in `Unix pwsh all-canonical Mode A guard`. Under Modes B and C, canonical selections SHALL be rejected before state changes as specified by `copilot-integration-modes`; successful B/C selections contain only legacy profiles and SHALL list every resolved directory. Resolution SHALL reject identifiers that escape all trusted roots, such as `.`, `..`, or paths containing separators.

#### Scenario: Activate a single profile

- **WHEN** a user runs `ctx review` and a `review` directory without a root-level `AGENTS.md` exists under the profiles root
- **THEN** `AI_CTX_PROFILES` is set to `review` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` contains the resolved `review` directory

#### Scenario: Activate multiple profiles

- **WHEN** a user runs `ctx coding azure` and both directories exist under the profiles root without root-level `AGENTS.md` files
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

#### Scenario: Mode A omits canonical roots from custom instruction directories

- **WHEN** a user activates a canonical profile and one or more legacy profiles under Mode A
- **THEN** `AI_CTX_PROFILES` retains all selected profile names, while `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` contains only the resolved legacy-profile directories in invocation order

#### Scenario: All-canonical Mode A selection sets custom directories empty

- **WHEN** a user activates only canonical profiles under Mode A on a supported runtime (Bash/zsh, Windows pwsh (PowerShell 7+), or Unix pwsh running .NET 9+)
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` is set to the empty string; on Unix pwsh running .NET 8 and earlier the selection instead fails as specified by the `Unix pwsh all-canonical Mode A guard` requirement

#### Scenario: Windows PowerShell 5.1 all-canonical present-empty is unverified

- **WHEN** an all-canonical Mode A selection would run under Windows PowerShell 5.1
- **THEN** present-empty success is not claimed; the behavior remains unverified and is tracked by issue #63

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

### Requirement: Canonical profile instructions and skills

During Mode A activation, each resolved profile directory with a root-level `AGENTS.md` SHALL be treated as a canonical profile. The one-based selection order SHALL be rendered as at least four zero-padded decimal digits. The filename label SHALL be the manual profile identifier or the `.ctx` entry label, passed through the existing cross-shell context-name sanitizer: ASCII letters, digits, `+`, `.`, `_`, and `-` are retained and each other character is replaced with `_`. The resulting file SHALL be named `<order>-<sanitized-label>.instructions.md` under `COPILOT_HOME/instructions/ctx-profiles/`.

The projected file SHALL begin with the exact UTF-8/LF byte sequence `---\napplyTo: "**"\n---\n\n`, followed by the source `AGENTS.md` bytes unchanged. Source line endings and any source BOM SHALL be preserved; an existing YAML-like header in `AGENTS.md` is copied as body content and is not parsed or merged. The source file SHALL NOT be modified. Canonical profile roots SHALL be excluded from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`; an all-canonical Mode A selection SHALL set that variable to an empty string, subject to the runtime guard in `Unix pwsh all-canonical Mode A guard`. Directories without a root-level `AGENTS.md` SHALL retain legacy behavior.

Canonical profiles SHALL discover skills only from `.agents/skills/<name>` directories containing a regular `SKILL.md` file; a co-located `.github/skills` tree SHALL be ignored. Legacy profiles SHALL continue to discover skills from `.github/skills`. Canonical and legacy profiles MAY be mixed in one ordered Mode A activation. All discovered skills SHALL use the existing case-insensitive collision behavior: warn and skip every member of a colliding group during activation and report that collision as `CHECK FAIL` during `ctx check`; this feature SHALL reuse the existing behavior, not add another collision preflight.

Before projecting, both `COPILOT_HOME/instructions/` and `COPILOT_HOME/instructions/ctx-profiles/` SHALL be real directories, not symlinks, junctions, or other reparse points. If either component exists as a link or non-directory, activation SHALL fail before writing or removing projections and SHALL NOT read or mutate anything through that component or outside the selected synthetic home.

A `.ctx-managed` manifest SHALL contain one projection basename per line. Each basename SHALL use the generated filename grammar: at least four ASCII decimal digits, a hyphen, a label containing only ASCII letters, digits, `+`, `.`, `_`, or `-`, and the literal suffix `.instructions.md`. A missing manifest SHALL be treated as empty. Any nonconforming line SHALL make an existing manifest malformed; activation SHALL fail before modifying projections, and no invalid line SHALL be used as a path or as grounds to delete files. If an existing manifest is a link, unreadable, or otherwise cannot be safely read, activation SHALL fail without modifying projection files. If a desired projection path already exists but is not listed in the valid manifest, activation SHALL fail without replacing or removing that unmanaged file. On successful reactivation, only prior manifest-listed projections absent from the desired set SHALL be removed; unmanaged files SHALL be preserved. If no canonical profiles remain, managed projections and the manifest SHALL be removed, and empty projection directories MAY be removed only when they are real directories and contain no unmanaged files. `ctx clear` SHALL preserve the cached home; `ctx clear --all` SHALL remove only the selected synthetic home under existing safety rules.

#### Scenario: Root AGENTS.md selects canonical profile mode

- **WHEN** a selected profile has a root-level `AGENTS.md`, is activated in Mode A, and the selection passes the `Unix pwsh all-canonical Mode A guard`
- **THEN** its source bytes are projected with the specified header and filename, and its root is omitted from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`; a canonical-only selection on Unix pwsh running .NET 8 and earlier instead fails before mutation

#### Scenario: Projection label uses the safe context-name form

- **WHEN** a manual profile identifier or `.ctx` entry label contains characters outside the allowed filename set
- **THEN** each such character is replaced with `_` in the projection filename, while the source label and `AI_CTX_PROFILES` remain unchanged

#### Scenario: Projection bytes and line endings are stable across shells

- **WHEN** Bash/zsh, Windows pwsh (PowerShell 7+), or Unix pwsh projects an `AGENTS.md` containing CRLF, no trailing newline, a BOM, or a leading YAML-like header
- **THEN** the output bytes equal the fixed LF header followed by the source bytes unchanged

#### Scenario: Canonical profiles discover only valid canonical skills

- **WHEN** a canonical profile contains `.agents/skills/<name>/SKILL.md`, a `.agents/skills/<other>` directory without `SKILL.md`, and/or `.github/skills/<legacy>`
- **THEN** only `.agents/skills` directories with a regular `SKILL.md` are exposed as skills, and the co-located `.github/skills` tree is ignored

#### Scenario: Legacy profile behavior is unchanged

- **WHEN** a selected profile has no root-level `AGENTS.md`
- **THEN** its root remains in `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` and its skills are discovered from `.github/skills` as before

#### Scenario: Canonical and legacy profiles can be mixed in order

- **WHEN** a user activates canonical and legacy profiles together in Mode A
- **THEN** each profile uses its own instruction and skill source, while the activation preserves the requested profile order; this includes mixed selections on Unix pwsh running .NET 8 and earlier, where the required custom-directories value is non-empty

#### Scenario: Projection directory links fail without external writes

- **WHEN** `instructions/` or `instructions/ctx-profiles/` is a symlink, junction, or non-directory
- **THEN** activation fails before projection writes or removals and does not write outside the selected synthetic home

#### Scenario: Unmanifested desired projection is preserved

- **WHEN** a desired projection path already contains a file that is not listed in the valid manifest
- **THEN** activation fails without replacing or removing the file, and `ctx check` reports `CHECK FAIL instruction:<file>` without modifying it

#### Scenario: Stale managed instruction projections are removed

- **WHEN** a later successful Mode A activation no longer selects a canonical profile whose projection is listed in the ctx-managed manifest
- **THEN** that stale managed projection is removed without following links, and unmanaged files in the instruction directory are preserved

#### Scenario: Unsafe manifest prevents projection reconciliation

- **WHEN** an existing `.ctx-managed` manifest is a link or cannot be safely read
- **THEN** activation fails without modifying managed projections, and no manifest entry is used to access a path outside the projection directory

#### Scenario: Clear preserves projections and clear-all removes the selected home

- **WHEN** a user runs `ctx clear` or `ctx clear --all` after a Mode A canonical-profile activation
- **THEN** `ctx clear` leaves the cached home and its projection on disk, while `ctx clear --all` removes only the selected synthetic home under the existing safety rules

#### Scenario: Canonical skill collisions reuse the existing policy

- **WHEN** a canonical profile and another selected profile provide skills whose names collide case-insensitively
- **THEN** activation emits the existing collision warning and skips every skill in the colliding group, and `ctx check` reports the collision as `CHECK FAIL`

#### Scenario: ctx current keeps its existing output for canonical profiles

- **WHEN** a canonical-profile context is active and a user runs `ctx current`
- **THEN** `ctx current` reports the context, environment variables, and active mode as specified by the existing requirement and does not add projection-file listings

### Requirement: Unix pwsh all-canonical Mode A guard

On Unix (Linux/macOS) PowerShell, all-canonical Mode A — a selection in which every selected profile is canonical and the required `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` value is empty — SHALL be supported only on pwsh running on .NET 9+. On Unix pwsh running .NET 8 and earlier, a canonical-only Mode A selection SHALL fail before any environment export, workspace-file write, Copilot-home setup or creation, or projection mutation, preserving the previously active context, with an error stating that all-canonical Mode A requires pwsh/.NET 9+ on Unix. This guard SHALL apply to manual profile activation, explicit `.ctx` loading, and `.ctx` auto-loading. Mixed canonical+legacy selections, whose `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` value is non-empty, SHALL retain their established behavior on Unix pwsh/.NET 8 and earlier, as SHALL legacy-only selections in all modes. This guard SHALL NOT alter the Modes B/C rejection of any canonical selection and SHALL NOT be weakened on Unix pwsh/.NET 8 and earlier.

#### Scenario: Unix pwsh/.NET 8 and earlier reject all-canonical Mode A before mutation

- **WHEN** a user activates only canonical profiles under Mode A on Unix pwsh running .NET 8 or earlier
- **THEN** activation fails with an error stating that all-canonical Mode A requires pwsh/.NET 9+ on Unix, before environment variables, workspace files, Copilot-home state, or projections are changed, and the previous context remains active

#### Scenario: Mixed and legacy selections keep established behavior on Unix pwsh/.NET 8 and earlier

- **WHEN** a user activates a mixed canonical+legacy or a legacy-only selection under Mode A on Unix pwsh running .NET 8 or earlier
- **THEN** activation proceeds with the established behavior, because the required custom-directories value is non-empty
