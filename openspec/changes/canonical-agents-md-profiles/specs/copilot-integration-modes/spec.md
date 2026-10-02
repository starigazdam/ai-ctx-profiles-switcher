# Spec Delta

## MODIFIED Requirements

### Requirement: Mode A synthetic-home behavior

The system SHALL implement Mode A (`synthetic-home`) as today's synthetic-home behavior, with the canonical-profile projection behavior specified by the `profile-activation` capability as the only additional Mode A behavior in this change. An explicit `synthetic-home` value SHALL be byte-identical to the selector being unset. All current `COPILOT_HOME` symlink reconciliation, `skills/` population, and cleanup rules SHALL remain as documented, except that canonical profiles project `AGENTS.md` instructions and discover canonical skills as specified. The rename-through-symlink hazard and concurrent last-writer-wins race SHALL remain documented, not fixed, and not hidden. The existing Mode A skill-collision policy SHALL remain unchanged: warn and skip every skill in a colliding group during activation and report the collision as `CHECK FAIL`; canonical-profile skills SHALL pass through the same policy, not a new collision policy. Mode A SHALL NOT be changed to resolve unrelated issues.

#### Scenario: Explicit synthetic-home is byte-identical to unset

- **WHEN** a user activates a context with `AI_CTX_PROFILES_COPILOT_MODE` explicitly set to `synthetic-home`
- **THEN** the result is byte-identical to activating the same context with the variable unset, including canonical-profile handling

#### Scenario: Mode A keeps the documented home rules

- **WHEN** a context is active under Mode A
- **THEN** the synthetic `COPILOT_HOME` uses the documented symlink, skill-directory, and cleanup rules; canonical instructions and skills follow the canonical-profile contract; and the rename-through-symlink hazard, concurrent race, and existing warn-and-skip collision policy remain as documented

#### Scenario: Mode A default-visible addition is mode reporting only

- **WHEN** a context containing only legacy profiles is active under Mode A and a user runs `ctx current` or `ctx check`
- **THEN** the only new default-visible output is the report of the active mode, with every existing check and output unchanged

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
