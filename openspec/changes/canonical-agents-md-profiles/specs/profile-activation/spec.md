# Spec Delta

## ADDED Requirements

### Requirement: Canonical profile instructions and skills

During Mode A activation, each resolved profile directory with a root-level `AGENTS.md` SHALL be treated as a canonical profile. `ctx` SHALL copy the file's contents without modifying the source into `COPILOT_HOME/instructions/ctx-profiles/<order>-<label>.instructions.md`, prefixed with frontmatter containing `applyTo: "**"`. The stable filename SHALL include the profile's one-based selection order and a filesystem-safe label. Canonical profile roots SHALL be excluded from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`; directories without a root-level `AGENTS.md` SHALL retain legacy behavior. Canonical profiles SHALL discover skills only from `.agents/skills/<name>` directories containing a `SKILL.md` file; any co-located `.github/skills` directory SHALL be ignored. Legacy profiles SHALL continue to discover skills from `.github/skills`. Canonical and legacy profiles MAY be mixed in one ordered Mode A activation. All discovered skills SHALL use the existing case-insensitive collision policy: warn and skip all members of a colliding group during activation, and report the collision as `CHECK FAIL` during `ctx check`.

#### Scenario: Root AGENTS.md selects canonical profile mode

- **WHEN** a selected profile has a root-level `AGENTS.md` and is activated in Mode A
- **THEN** its instructions are projected into the synthetic Copilot home and its root is omitted from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`

#### Scenario: Canonical profiles discover only valid canonical skills

- **WHEN** a canonical profile contains `.agents/skills/<name>/SKILL.md` and/or `.github/skills/<name>`
- **THEN** only directories under `.agents/skills` that contain `SKILL.md` are exposed as its skills, and `.github/skills` is ignored

#### Scenario: Legacy profile behavior is unchanged

- **WHEN** a selected profile has no root-level `AGENTS.md`
- **THEN** its root remains in `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` and its skills are discovered from `.github/skills` as before

#### Scenario: Canonical and legacy profiles can be mixed in order

- **WHEN** a user activates canonical and legacy profiles together in Mode A
- **THEN** each profile uses its own instruction and skill source, while the activation preserves the requested profile order

#### Scenario: Stale managed instruction projections are removed

- **WHEN** a later successful Mode A activation no longer selects a canonical profile whose projection is listed in the ctx-managed manifest
- **THEN** that stale managed projection is removed and unmanaged files in the instruction directory are preserved

#### Scenario: Clear preserves projections and clear-all removes the selected home

- **WHEN** a user runs `ctx clear` or `ctx clear --all` after a Mode A canonical-profile activation
- **THEN** `ctx clear` leaves the cached home and its projection on disk, while `ctx clear --all` removes only the selected synthetic home under the existing safety rules

#### Scenario: Canonical skill collisions reuse the existing policy

- **WHEN** a canonical profile and another selected profile provide skills whose names collide case-insensitively
- **THEN** activation emits the existing collision warning and skips every skill in the colliding group, and `ctx check` reports the collision as `CHECK FAIL`
