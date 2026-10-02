# Spec Delta

## MODIFIED Requirements

### Requirement: Mode A synthetic-home behavior

The system SHALL implement Mode A (`synthetic-home`) as today's synthetic-home behavior with the canonical-profile projection addition specified by the `profile-activation` capability. An explicit `synthetic-home` value SHALL be byte-identical to the selector being unset. All current `COPILOT_HOME` symlink reconciliation, skill population, and cleanup rules SHALL remain as documented, except for canonical instruction and skill sourcing specified by `profile-activation`. The rename-through-symlink hazard and concurrent last-writer-wins race SHALL remain documented, not fixed, and not hidden. The existing Mode A skill-collision behavior SHALL NOT be changed by this feature; canonical skills SHALL use the same collision behavior specified by `profile-activation`. Mode A SHALL NOT be altered to resolve unrelated issues such as the skill-name-collision bug.

#### Scenario: Explicit synthetic-home is byte-identical to unset

- **WHEN** a user activates a context with `AI_CTX_PROFILES_COPILOT_MODE` explicitly set to `synthetic-home`
- **THEN** the result is byte-identical to activating the same context with the variable unset, including canonical-profile handling

#### Scenario: Mode A keeps the documented home rules

- **WHEN** a context is active under Mode A
- **THEN** the synthetic `COPILOT_HOME` uses the documented symlink, skill-directory, and cleanup rules; canonical instructions and skills follow the canonical-profile contract; and the rename-through-symlink hazard and concurrent race remain documented rather than fixed

#### Scenario: Mode A default-visible addition is mode reporting only

- **WHEN** a context containing only legacy profiles is active under Mode A and a user runs `ctx current` or `ctx check`
- **THEN** the only new default-visible output is the report of the active mode, with every existing check and output unchanged

### Requirement: Mode B/C environment wiring

The system SHALL wire Copilot environment variables as follows. `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` SHALL be replaced, not appended, on activation and unset on `ctx clear`. Under Mode A it SHALL contain only the resolved legacy-profile directories, in invocation order and comma-joined; canonical-profile directories SHALL be omitted, and an all-canonical selection SHALL set it to the empty string (not unset it). Under Modes B and C, canonical-profile activation SHALL be rejected before state changes as specified by `Canonical profile selection requires Mode A`; therefore every successful B/C activation contains only legacy profiles, whose resolved directories SHALL retain today's semantics. `COPILOT_SKILLS_DIRS` SHALL be set only in Modes B and C to the existing `<resolved-root>/.github/skills` directories for active entries — only those that actually exist — in the same stable order, comma-joined; if none exist, it SHALL be left unset rather than exported as an empty string. It SHALL be fully replaced on each new B/C activation, never appended across activations, SHALL be unset on `ctx clear`, and SHALL be unset on a successful switch into Mode A; a Mode-A-only session SHALL never touch a `COPILOT_SKILLS_DIRS` that the user set themselves, only unset one that a prior B/C activation in this session set. Before export, `ctx` SHALL reject, as an activation error with no side effects, any resolved directory path containing a literal comma used for `COPILOT_SKILLS_DIRS`, because no escaping mechanism exists; this additive check SHALL not change Mode A's existing parsing. "Additive" means additive to Copilot's own built-in discovery locations, not appending new entries to the previous activation's value.

#### Scenario: COPILOT_CUSTOM_INSTRUCTIONS_DIRS keeps today's semantics in all modes

- **WHEN** a user activates only legacy profiles under Mode A, Mode B, or Mode C
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lists all resolved profile directories in invocation order, comma-joined, replaced on each activation, and unset on `ctx clear`

#### Scenario: Mode A omits canonical roots but keeps legacy directory order

- **WHEN** a user activates canonical and legacy profiles together under Mode A
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lists only the resolved legacy-profile directories in their original invocation order

#### Scenario: Mode A all-canonical selection exports an empty value

- **WHEN** a user activates one or more canonical profiles and no legacy profiles under Mode A
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` is set to the empty string

#### Scenario: COPILOT_SKILLS_DIRS lists existing skills directories in stable order

- **WHEN** a user activates a context under Mode B or Mode C and the active entries have existing `.github/skills` directories
- **THEN** `COPILOT_SKILLS_DIRS` lists only those existing directories, in the same stable order, comma-joined

#### Scenario: No skills directories leaves COPILOT_SKILLS_DIRS unset

- **WHEN** a user activates a context under Mode B or Mode C and no active entry has an existing `.github/skills` directory
- **THEN** `COPILOT_SKILLS_DIRS` is left unset rather than exported as an empty string

#### Scenario: COPILOT_SKILLS_DIRS is replaced each activation, never appended

- **WHEN** a user activates a second Mode B or Mode C context in the same session
- **THEN** `COPILOT_SKILLS_DIRS` is fully replaced with the new activation's directories and never carries over entries from the previous activation

#### Scenario: Switching into Mode A unsets only a session-set COPILOT_SKILLS_DIRS

- **WHEN** a user switches from a Mode B or Mode C activation into Mode A
- **THEN** a `COPILOT_SKILLS_DIRS` set by the prior B/C activation in this session is unset, while a `COPILOT_SKILLS_DIRS` the user set themselves in a Mode-A-only session is never touched

#### Scenario: A comma in a resolved directory path is rejected before export

- **WHEN** a resolved directory path used for `COPILOT_SKILLS_DIRS` in Mode B or Mode C contains a literal comma
- **THEN** activation errors before any export with no side effects, because no escaping mechanism exists

## ADDED Requirements

### Requirement: Canonical profile selection requires Mode A

An activation containing any resolved profile directory with a root-level `AGENTS.md` SHALL proceed only when the selected mode is `synthetic-home`. In `global-user` or `ephemeral-clean` mode, activation SHALL fail with a clear error identifying the canonical profile or profiles and stating that canonical profiles require `synthetic-home`. This validation SHALL occur before any environment export, workspace-file write, or Copilot-home setup or creation. This requirement applies to manual profile activation, explicit `.ctx` loading, and `.ctx` auto-loading.

#### Scenario: Mode A accepts canonical profiles

- **WHEN** a user activates one or more profiles containing root-level `AGENTS.md` files under `synthetic-home`
- **THEN** activation proceeds using the canonical-profile behavior specified by the `profile-activation` capability

#### Scenario: Mode B rejects canonical profiles before mutation

- **WHEN** a user activates a selection containing a canonical profile under `global-user`
- **THEN** activation fails with a clear Mode A requirement message before environment variables, workspace files, or Copilot-home state are changed

#### Scenario: Mode C rejects canonical profiles before home creation

- **WHEN** a user activates a selection containing a canonical profile under `ephemeral-clean`
- **THEN** activation fails with a clear Mode A requirement message before environment variables, workspace files, or an ephemeral Copilot home are created

#### Scenario: Legacy profiles remain available in every mode

- **WHEN** a user activates only profiles without a root-level `AGENTS.md` under any supported mode
- **THEN** the existing behavior for that mode proceeds unchanged
