# Spec Delta

## MODIFIED Requirements

### Requirement: Mode A synthetic-home behavior

The system SHALL implement Mode A (`synthetic-home`) as today's synthetic-home behavior with the canonical-profile projection addition specified by the `profile-activation` capability. An explicit `synthetic-home` value SHALL be byte-identical to the selector being unset. All current `COPILOT_HOME` symlink reconciliation, skill population, and cleanup rules SHALL remain as documented, except for canonical instruction and skill sourcing specified by `profile-activation`. The rename-through-symlink hazard and concurrent last-writer-wins race SHALL remain documented, not fixed, and not hidden. The existing Mode A skill-collision behavior SHALL NOT be changed by this feature; canonical skills SHALL use the same collision behavior specified by `profile-activation`. Mode A SHALL NOT be altered to resolve unrelated issues such as the skill-name-collision bug. The Unix pwsh runtime guard in `profile-activation` SHALL apply: on Unix pwsh running .NET 8 and earlier an all-canonical Mode A selection SHALL fail before any mutation with a pwsh/.NET 9+ requirement rather than export a dropped empty value, and the present-empty contract SHALL NOT be weakened. Mode A's `skills/` population SHALL be understood as projecting only each selected profile's contracted skill source into the synthetic `COPILOT_HOME` view — `.github/skills` for legacy profiles and `.agents/skills` for canonical profiles, following `profile-activation`; it SHALL NOT be represented as a complete skill-discovery mechanism or a security sandbox, because other built-in or configured discovery locations (e.g. personal `~/.agents/skills`, repository `.github/skills`/`.claude/skills`, `COPILOT_SKILLS_DIRS`, or configured `skillDirectories`) MAY remain discoverable by Copilot and SHALL NOT be blocked by Mode A.

#### Scenario: Explicit synthetic-home is byte-identical to unset

- **WHEN** a user activates a context with `AI_CTX_PROFILES_COPILOT_MODE` explicitly set to `synthetic-home`
- **THEN** the result is byte-identical to activating the same context with the variable unset, including canonical-profile handling

#### Scenario: Mode A keeps the documented home rules

- **WHEN** a context is active under Mode A
- **THEN** the synthetic `COPILOT_HOME` uses the documented symlink, skill-directory, and cleanup rules; canonical instructions and skills follow the canonical-profile contract; and the rename-through-symlink hazard and concurrent race remain documented rather than fixed

#### Scenario: Mode A projects profile skills but is not a discovery or security sandbox

- **WHEN** a context is active under Mode A and other built-in or configured skill discovery locations exist
- **THEN** the synthetic `COPILOT_HOME` view contains only each selected profile's contracted skill source (`.github/skills` for legacy profiles and `.agents/skills` for canonical profiles, following `profile-activation`), those other locations may still be discovered by Copilot, and `ctx` SHALL NOT claim that Mode A blocks them

#### Scenario: Mode A default-visible addition is mode reporting only

- **WHEN** a context containing only legacy profiles is active under Mode A and a user runs `ctx current` or `ctx check`
- **THEN** the only new default-visible output is the report of the active mode, with every existing check and output unchanged

### Requirement: Mode B/C environment wiring

The system SHALL wire Copilot environment variables as follows. `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` SHALL be replaced, not appended, on activation and unset on `ctx clear`. Under Mode A it SHALL contain only the resolved legacy-profile directories, in invocation order and comma-joined; canonical-profile directories SHALL be omitted, and an all-canonical selection SHALL set it to the empty string (not unset it), subject to the `profile-activation` runtime guard on Unix pwsh running .NET 8 and earlier. Under Modes B and C, canonical-profile activation SHALL be rejected before state changes as specified by `Canonical profile selection requires Mode A`; therefore every successful B/C activation contains only legacy profiles, whose resolved directories SHALL retain today's semantics. `COPILOT_SKILLS_DIRS` SHALL be set only in Modes B and C to the existing `<resolved-root>/.github/skills` directories for active entries — only those that actually exist — in the same stable order, comma-joined; if none exist, it SHALL be left unset rather than exported as an empty string. It SHALL be fully replaced on each new B/C activation, never appended across activations, SHALL be unset on `ctx clear`, and SHALL be unset on a successful switch into Mode A; a Mode-A-only session SHALL never touch a `COPILOT_SKILLS_DIRS` that the user set themselves, only unset one that a prior B/C activation in this session set. Before export, `ctx` SHALL reject, as an activation error with no side effects, any resolved directory path containing a literal comma used for `COPILOT_SKILLS_DIRS`, because no escaping mechanism exists; this additive check SHALL not change Mode A's existing parsing. "Additive" means additive to Copilot's own built-in discovery locations, not appending new entries to the previous activation's value.

#### Scenario: COPILOT_CUSTOM_INSTRUCTIONS_DIRS keeps today's semantics in all modes

- **WHEN** a user activates only legacy profiles under Mode A, Mode B, or Mode C
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lists all resolved profile directories in invocation order, comma-joined, replaced on each activation, and unset on `ctx clear`

#### Scenario: Mode A omits canonical roots but keeps legacy directory order

- **WHEN** a user activates canonical and legacy profiles together under Mode A
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lists only the resolved legacy-profile directories in their original invocation order

#### Scenario: Mode A all-canonical selection exports an empty value

- **WHEN** a user activates one or more canonical profiles and no legacy profiles under Mode A on a supported runtime (Bash/zsh, Windows pwsh (PowerShell 7+), or Unix pwsh running .NET 9+)
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` is set to the empty string; on Unix pwsh running .NET 8 and earlier the selection instead fails before mutation as specified by `profile-activation`

#### Scenario: Windows PowerShell 5.1 all-canonical present-empty is unverified

- **WHEN** an all-canonical Mode A selection would run under Windows PowerShell 5.1
- **THEN** present-empty success is not claimed; the behavior remains unverified and is tracked by issue #63

#### Scenario: Unix pwsh/.NET 8 and earlier reject all-canonical Mode A before mutation

- **WHEN** a user activates only canonical profiles under Mode A on Unix pwsh running .NET 8 or earlier
- **THEN** activation fails before any environment export, workspace write, or Copilot-home setup/creation, stating that all-canonical Mode A requires pwsh/.NET 9+ on Unix, and the prior context remains unchanged

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

### Requirement: ctx skills read-only skill-discovery inventory

The system SHALL provide `ctx skills` as a filesystem/configuration-based, strictly read-only inventory of the skill directories Copilot might discover, explicitly headed as **potential Copilot skill discovery** and explicitly not claiming skills are loaded or invoked. It SHALL report candidate skill directories with all of their origins and a single classification chosen by precedence `ctx-profile > expected-home > external` (all origins retained). Origins SHALL be a deterministic, deduplicated, comma-joined list of distinct source labels kept separate from the single classification: `ctx-profile`, `expected-home`, `copilot-skill-dirs`, `settings-skill-dirs`, `personal-copilot`, `personal-agents`, `repo-github-skills`, `repo-agents-skills`, `repo-claude-skills`, and `plugin-skills`; a path found via several sources (including several `external`-class sources) SHALL report all of its origins, not one generic label. It SHALL normalize and deduplicate paths using platform-appropriate rules, SHALL show configured-but-missing or inaccessible paths cleanly without failing, and SHALL NOT emit unrelated settings or secrets. It SHALL inventory the observable/applicable sources: active context/profile skill dirs (`.github/skills` for legacy profiles, `.agents/skills` for canonical `AGENTS.md` profiles); the expected `<COPILOT_HOME>/skills`; personal `~/.copilot/skills` and `~/.agents/skills`; repository `.github/skills`, `.agents/skills`, and `.claude/skills` in the current directory and applicable ancestors; `COPILOT_SKILLS_DIRS`; configured `skillDirectories` in relevant Copilot settings; and detectable additional-directory/installed-plugin skill paths (an installed-plugins root itself SHALL NOT be reported as a skill directory; only observable `skills`/`.github/skills` subdirectories under plugins may be, and the boundary SHALL be disclosed). If the active context provenance does not match its session record, `ctx skills` SHALL say attribution is unknown and SHALL NOT guess ctx-owned paths. It SHALL clearly disclose categories a filesystem/config diagnostic cannot observe (notably another Copilot process's command-line arguments), SHALL NOT invoke the Copilot CLI, and SHALL NOT modify settings, files, or the environment. `ctx check` SHALL remain strictly read-only and continue to skip the external Copilot probe.

#### Scenario: ctx skills reports potential candidates with classification and origins

- **WHEN** a user runs `ctx skills` and candidate skill directories are discoverable from multiple sources
- **THEN** each normalized, deduplicated candidate is reported once with its classification by precedence and all of its origins

#### Scenario: ctx skills retains multiple external-class origins on one row

- **WHEN** a candidate path is discoverable from more than one external-class source (e.g. a repository `.github/skills` that is also listed in `COPILOT_SKILLS_DIRS`)
- **THEN** the single deduplicated row lists both source labels (e.g. `copilot-skill-dirs,repo-github-skills`) with classification `external`

#### Scenario: ctx skills shows configured-but-missing paths without failing

- **WHEN** a configured path (e.g. a `COPILOT_SKILLS_DIRS` entry or a settings `skillDirectories` entry) does not exist and a user runs `ctx skills`
- **THEN** the path is reported as missing/inaccessible and the command exits successfully

#### Scenario: ctx skills reports unknown provenance without guessing ctx-owned paths

- **WHEN** the active context provenance does not match its session record and a user runs `ctx skills`
- **THEN** the inventory states that attribution is unknown and does not guess ctx-owned paths

#### Scenario: ctx skills is read-only and discloses what it cannot observe

- **WHEN** a user runs `ctx skills`
- **THEN** no settings, files, or environment are modified, no Copilot CLI probe is performed, and categories that cannot be observed (notably another Copilot process's command-line arguments) are disclosed

## ADDED Requirements

### Requirement: Canonical profile selection requires Mode A

An activation containing any resolved profile directory with a root-level `AGENTS.md` SHALL proceed only when the selected mode is `synthetic-home`. In `global-user` or `ephemeral-clean` mode, activation SHALL fail with a clear error identifying the canonical profile or profiles and stating that canonical profiles require `synthetic-home`. This validation SHALL occur before any environment export, workspace-file write, or Copilot-home setup or creation. This requirement applies to manual profile activation, explicit `.ctx` loading, and `.ctx` auto-loading.

#### Scenario: Mode A accepts canonical profiles

- **WHEN** a user activates profiles containing root-level `AGENTS.md` files under `synthetic-home` and the selection passes the `profile-activation` Unix pwsh runtime guard
- **THEN** activation proceeds using the canonical-profile behavior specified by the `profile-activation` capability; a canonical-only selection on Unix pwsh running .NET 8 and earlier instead fails before mutation, while mixed canonical+legacy selections proceed on every runtime

#### Scenario: Mode B rejects canonical profiles before mutation

- **WHEN** a user activates a selection containing a canonical profile under `global-user`
- **THEN** activation fails with a clear Mode A requirement message before environment variables, workspace files, or Copilot-home state are changed

#### Scenario: Mode C rejects canonical profiles before home creation

- **WHEN** a user activates a selection containing a canonical profile under `ephemeral-clean`
- **THEN** activation fails with a clear Mode A requirement message before environment variables, workspace files, or an ephemeral Copilot home are created

#### Scenario: Legacy profiles remain available in every mode

- **WHEN** a user activates only profiles without a root-level `AGENTS.md` under any supported mode
- **THEN** the existing behavior for that mode proceeds unchanged
