# Copilot Integration Modes Specification

## Purpose

Lets a profile activation choose how `ctx` wires resolved directories into GitHub Copilot CLI — synthetic-home (today), global-user, or ephemeral-clean — through a single environment variable selector.

## Requirements

### Requirement: Mode selector

The system SHALL select the Copilot integration mode for an activation from the single environment variable `AI_CTX_PROFILES_COPILOT_MODE`, accepting exactly the case-sensitive strings `synthetic-home`, `global-user`, and `ephemeral-clean`. An unset or empty variable SHALL mean `synthetic-home` and SHALL behave byte-identically to the current single-mode behavior. Any other non-empty value (wrong case, surrounding whitespace, or an unknown word) SHALL be rejected as an activation error raised before any export, workspace write, or home setup, and the error SHALL name the allowed values. The variable SHALL be read once per actual activation — a manual `ctx <profile>...`, an explicit `ctx load <path>`, or an actual `.ctx` auto-load firing — and SHALL NOT be read or written by `ctx clear`, `ctx current`, or `ctx check` as a write target, and activation SHALL never overwrite or unset the variable itself. The mode SHALL come from this environment variable only: no CLI flag, no `.ctx` mode directive, no per-profile metadata, and no precedence chain. One mode SHALL apply to the whole activation, so all profiles named in one `ctx a b c` invocation or one `.ctx` file share one mode.

#### Scenario: Unset or empty selector means synthetic-home

- **WHEN** `AI_CTX_PROFILES_COPILOT_MODE` is unset or empty and a user activates a context
- **THEN** the activation behaves byte-identically to today's single synthetic-home behavior

#### Scenario: A valid selector is accepted exactly and case-sensitively

- **WHEN** a user sets `AI_CTX_PROFILES_COPILOT_MODE` to exactly `synthetic-home`, `global-user`, or `ephemeral-clean` and activates a context
- **THEN** the activation proceeds with that mode and the value is accepted without error

#### Scenario: An invalid selector is rejected before any state change

- **WHEN** a user sets `AI_CTX_PROFILES_COPILOT_MODE` to any other non-empty value, including a wrong case, surrounding whitespace, or an unknown word, and runs an activation
- **THEN** activation errors before any export, workspace write, or home setup, and the error message names the three allowed values

#### Scenario: One mode applies to the entire activation

- **WHEN** a user activates several profiles in one `ctx a b c` invocation or loads a `.ctx` file with multiple entries under a single selector value
- **THEN** every profile or entry in that activation uses the same mode

#### Scenario: The selector is environment-variable only

- **WHEN** a user looks for the mode selector in a CLI flag, a `.ctx` mode directive, or per-profile metadata
- **THEN** no such selector exists; the mode is determined solely by `AI_CTX_PROFILES_COPILOT_MODE`

#### Scenario: The selector is never written by ctx

- **WHEN** a user runs `ctx clear`, `ctx current`, or `ctx check`
- **THEN** the commands never set, unset, or overwrite `AI_CTX_PROFILES_COPILOT_MODE`, and activation does not modify the variable either

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

### Requirement: Copilot skill-discovery scope

Mode A SHALL project each context's `skills/` tree from the resolved entries' contracted skill source (`.github/skills` for legacy profiles, `.agents/skills` for canonical profiles, following `profile-activation`) into the synthetic home, exactly as documented, but this projection SHALL NOT be described or treated as complete or isolated skill discovery. Copilot CLI SHALL remain free to load skills from its other documented roots — personal `~/.copilot/skills` and `~/.agents/skills` (Copilot CLI does not treat `~/.claude/skills` as an official personal root), project `.github/skills`, `.agents/skills`, and `.claude/skills`, plus inherited and plugin/custom sources. Those documented roots may be additive and are not all always present or always loaded under a custom `COPILOT_HOME`; the only verified independence is that one ancestor `.agents/skills` source still loads when `COPILOT_HOME` points outside that ancestor tree, and `ctx` SHALL NOT remove, hide, or disable any of them. `ctx` SHALL provide no built-in or durable per-context skill exclusion in any mode: in Mode A a `copilot skill disable` writes through the shared `settings.json` symlink to the real `~/.copilot/settings.json` and so affects every Mode A context; in Mode B its effect follows whatever `COPILOT_HOME` value is already set — the normal user home, a stale Mode-A synthetic pointer, or another custom value — and may affect any sessions sharing that home; and in Mode C a user could manually disable a skill name inside a fresh activation's home but SHALL have to repeat it on every activation because `ctx` SHALL NOT automate or persist an exclusion policy. `ctx` activation SHALL NOT alter global skill enablement, though a user manually running the CLI's supported skill-name disable command can; the CLI SHALL provide no negative skill-root filter, and `ctx` SHALL provide no managed durable exclusion.

#### Scenario: Mode A skill projection is additive, not exclusive

- **WHEN** a context is active under Mode A and Copilot CLI resolves skills
- **THEN** the synthetic home's `skills/` tree is included alongside Copilot's documented personal, project, inherited, and plugin/custom skill roots, `ctx` claims neither complete nor isolated discovery, and not every documented root is guaranteed to be present or loaded under a custom `COPILOT_HOME`

#### Scenario: No built-in or durable per-context skill exclusion is provided under any mode

- **WHEN** a user wants a context to exclude an inherited or other non-projected skill
- **THEN** `ctx` provides no built-in or durable per-context exclusion in any mode: a `copilot skill disable` is global in Mode A via the shared `settings.json` symlink, its effect in Mode B follows the existing `COPILOT_HOME` value and may affect any sessions sharing it, a Mode C manual disable inside a fresh activation's home must be repeated on every activation because `ctx` neither automates nor persists an exclusion policy, and `ctx` activation does not alter global skill enablement

### Requirement: Mode B global-user COPILOT_HOME handling

The system SHALL implement Mode B (`global-user`) by never writing `COPILOT_HOME`: at activation `ctx` SHALL not set, unset, create, or delete `COPILOT_HOME`, leaving whatever value it has — set by the user, left over from a prior Mode A or Mode C activation, or unset — exactly as-is. Mode B MAY read `COPILOT_HOME` for status reporting and for the preserved-value warning below; reading SHALL never change it. Switching directly from Mode A or Mode C into Mode B SHALL NOT restore or clear an old pointer; a user who wants Copilot's real default SHALL clear or unset `COPILOT_HOME` themselves first, and `ctx` SHALL not claim that Mode B restores anything.

#### Scenario: Mode B leaves a set COPILOT_HOME exactly as-is

- **WHEN** a user activates a context under Mode B and `COPILOT_HOME` holds a custom value
- **THEN** the value is left exactly as-is: `ctx` does not set, unset, create, or delete it, and reading it for status/warning never modifies it

#### Scenario: Mode B leaves COPILOT_HOME unset when it is unset

- **WHEN** a user activates a context under Mode B and `COPILOT_HOME` is unset
- **THEN** `COPILOT_HOME` remains unset after activation

#### Scenario: Mode B warns that a present COPILOT_HOME is preserved

- **WHEN** a user successfully activates a context under Mode B and `COPILOT_HOME` is present in the environment (including empty)
- **THEN** `ctx` emits to stderr the exact template `ctx: warning: global-user mode preserves the existing COPILOT_HOME: "<path>". This may point to a synthetic home from a previous ctx activation.` with the exact value, never modifies it, and emits nothing when the variable is absent, in Modes A/C, on a failed activation, or from read-only commands

#### Scenario: Switching from A or C into Mode B does not restore or clear an old pointer

- **WHEN** a user switches directly from a Mode A or Mode C activation into Mode B
- **THEN** any previous `COPILOT_HOME` is neither restored nor cleared, and `ctx` does not claim Mode B restores Copilot's real default

### Requirement: Mode B/C environment wiring

The system SHALL wire Copilot environment variables as follows. `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` SHALL be replaced, not appended, on activation and unset on `ctx clear`. Under Mode A it SHALL contain only the resolved legacy-profile directories, in invocation order and comma-joined; canonical-profile directories SHALL be omitted, and an all-canonical selection SHALL set it to the empty string (not unset it), subject to the `profile-activation` runtime guard on Unix pwsh running .NET 8 and earlier. Under Modes B and C, canonical-profile activation SHALL be rejected before state changes as specified by `Canonical profile selection requires Mode A`; therefore every successful B/C activation contains only legacy profiles, whose resolved directories SHALL retain today's semantics. `COPILOT_SKILLS_DIRS` SHALL be set only in Modes B and C to the existing `<resolved-root>/.github/skills` directories for active entries — only those that actually exist — in the same stable order, comma-joined; if none exist, it SHALL be left unset rather than exported as an empty string. It SHALL be fully replaced on each new B/C activation, never appended across activations, SHALL be unset on `ctx clear`, and SHALL be unset on a successful switch into Mode A; a Mode-A-only session SHALL never touch a `COPILOT_SKILLS_DIRS` that the user set themselves, only unset one that a prior B/C activation in this session set. Before export, `ctx` SHALL reject, as an activation error with no side effects, any resolved directory path containing a literal comma used for `COPILOT_SKILLS_DIRS`, because no escaping mechanism exists; this additive check SHALL not change Mode A's existing parsing. "Additive" means additive to Copilot's own built-in discovery locations, not appending new entries to the previous activation's value.

#### Scenario: COPILOT_CUSTOM_INSTRUCTIONS_DIRS keeps today's semantics in all modes

- **WHEN** a user activates only legacy profiles under Mode A, Mode B, or Mode C
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lists all resolved profile directories in invocation order, comma-joined, replaced on each activation, and unset on `ctx clear`

#### Scenario: Mode A omits canonical roots but keeps legacy directory order

- **WHEN** a user activates canonical and legacy profiles together under Mode A
- **THEN** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lists only the resolved legacy-profile directories in their original invocation order

#### Scenario: Mode A all-canonical selection exports an empty value

- **WHEN** a user activates one or more canonical profiles and no legacy profiles under Mode A on a supported runtime (Bash/zsh, native-Windows pwsh (the runtime exercised by PR CI; exact PowerShell/.NET version is not logged, so no version-wide PowerShell 7+ claim), or Unix pwsh running .NET 9+)
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

### Requirement: Mode C ephemeral-clean home creation

The system SHALL implement Mode C (`ephemeral-clean`) by creating a fresh, unique, temporary home directory on every activation, including when re-running the same profiles or `.ctx` file, and SHALL never reuse or look it up by name. Creation SHALL use the platform's standard secure/private temp-directory primitive — a `mktemp -d` equivalent on POSIX, `[System.IO.Path]::GetTempPath()` plus a GUID/random suffix in PowerShell, with no new dependency — and SHALL reject a colliding path or an existing symlink/junction. `COPILOT_HOME` SHALL be exported only after the directory is successfully created. The system SHALL create no symlinks, junctions, hardlinks, or copies into or out of the real `~/.copilot`, SHALL perform no reconciliation of its contents, and SHALL never read what Copilot later writes there. A validation or creation failure — invalid mode string, unsafe path, or directory-creation failure — SHALL leave the previously active context and all files untouched, using the same fail-before-any-state-change contract as existing validation errors; this SHALL not be framed as a full filesystem transaction and SHALL not be retrofitted onto Mode A's existing, already-documented setup-failure behavior. Mode C is storage separation only, not a skills/instructions sandbox and not a process/credential sandbox: `COPILOT_SKILLS_DIRS` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` remain additive to Copilot's normal discovery, and ambient OS-level credential stores and environment variables are unaffected — the only isolation claimed is that `COPILOT_HOME` points at an empty unique directory.

#### Scenario: A fresh unique temp home is created on every activation

- **WHEN** a user activates a context under Mode C, including re-running the same profiles or `.ctx` file more than once
- **THEN** a new unique temporary directory is created for every activation and is never reused or looked up by name

#### Scenario: COPILOT_HOME is exported only after successful creation

- **WHEN** a user activates a context under Mode C and the temporary directory is created successfully
- **THEN** `COPILOT_HOME` is exported to point at that directory, and only after creation succeeds

#### Scenario: A colliding or symlink path is rejected

- **WHEN** the generated Mode C temporary path already exists or is a symlink/junction
- **THEN** activation errors and does not use the colliding path

#### Scenario: Mode C never links into or reconciles the real .copilot

- **WHEN** a context is active under Mode C
- **THEN** no symlinks, junctions, hardlinks, or copies are created into or out of the real `~/.copilot`, no reconciliation of its contents is performed, and `ctx` never reads what Copilot later writes to the ephemeral home

#### Scenario: A Mode C failure leaves the previous context untouched

- **WHEN** a Mode C activation fails on an invalid mode string, an unsafe path, or a directory-creation failure
- **THEN** the previously active context and all files remain untouched, matching the fail-before-any-state-change contract of existing validation errors

#### Scenario: Mode C is storage separation only

- **WHEN** a context is active under Mode C
- **THEN** `COPILOT_SKILLS_DIRS` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` remain additive to Copilot's normal discovery, ambient OS-level credential stores and environment variables are unaffected, and the only isolation is that `COPILOT_HOME` points at an empty unique directory

### Requirement: Mode C cleanup never deletes the ephemeral directory

The system SHALL never delete the Mode C ephemeral directory. `ctx clear` and `ctx clear --all` under Mode C SHALL unset `COPILOT_HOME` for the session but SHALL never delete the directory or its contents — not on clear, not on switching to a different mode or profile, and not on shell exit. There SHALL be no automatic sweeper, trap, or background cleanup. When leaving or replacing an active Mode C context, the system SHALL report the retained path on stdout and state plainly that cleanup and moving data out of it is the user's or workflow's own responsibility, warning that it may contain auth/session data and consumes disk until removed manually. `ctx clear --all`'s existing common-artifact cleanup — the workspace file and the legacy settings file — SHALL still run; only Mode A's existing, already-guarded home deletion remains home-deleting. There SHALL be no configurable cleanup policy.

#### Scenario: ctx clear under Mode C never deletes the ephemeral directory

- **WHEN** a user runs `ctx clear` with an active Mode C context
- **THEN** `COPILOT_HOME` is unset for the session and the ephemeral directory and its contents remain on disk

#### Scenario: ctx clear --all under Mode C still never deletes the ephemeral directory

- **WHEN** a user runs `ctx clear --all` with an active Mode C context
- **THEN** the common workspace-file and legacy settings-file cleanup still runs, and the ephemeral directory and its contents are never deleted

#### Scenario: Leaving a Mode C context reports the retained path and responsibility

- **WHEN** a user leaves or replaces an active Mode C context
- **THEN** the retained ephemeral path is reported on stdout, and the message states plainly that cleanup and moving data out of it is the user's or workflow's own responsibility, warning that it may contain auth/session data and consumes disk until removed manually

#### Scenario: No automatic cleanup runs for Mode C homes

- **WHEN** a Mode C ephemeral directory is no longer referenced by an active context
- **THEN** no automatic sweeper, trap, or background cleanup deletes it, including on shell exit

### Requirement: Mode reporting

The system SHALL record, session-locally and without any new on-disk registry, which mode actually activated and, for Modes B and C, the home value the activation is responsible for checking. `ctx current` SHALL print the active mode — the mode of the matching activation, not merely the requested selector, so a stale or mismatched `AI_CTX_PROFILES_COPILOT_MODE` sitting in the environment without a matching activation is not reported as active — and, in Modes B and C, the active `COPILOT_SKILLS_DIRS`. The active-mode labels SHALL be exactly consistent across `ctx current` and `ctx check` status: `A — synthetic-home`, `B — global-user`, `C — ephemeral-clean`; the selector values themselves SHALL remain unchanged. A `COPILOT_HOME` or `COPILOT_SKILLS_DIRS` that exists in the environment with no matching local activation record cannot be attributed to a mode; the system SHALL report such state as unknown rather than guessing from its path or deleting it. The read-only audit behavior of `ctx check` under each mode is specified by the `.ctx loading` capability.

#### Scenario: A successful activation records its mode session-locally

- **WHEN** a user activates a context under any mode
- **THEN** the activation records the mode that actually activated, and the record lives only in the session with no new on-disk registry

#### Scenario: ctx current prints the active mode, not a stale selector

- **WHEN** a context is active and a user runs `ctx current`
- **THEN** the active mode is printed, and a stale or mismatched `AI_CTX_PROFILES_COPILOT_MODE` sitting in the environment without a matching activation is not reported as active

#### Scenario: ctx current prints the active COPILOT_SKILLS_DIRS in Modes B and C

- **WHEN** a context is active under Mode B or Mode C and a user runs `ctx current`
- **THEN** the active `COPILOT_SKILLS_DIRS` is printed alongside the mode

#### Scenario: Foreign environment state is reported as unknown

- **WHEN** a `COPILOT_HOME` or `COPILOT_SKILLS_DIRS` exists in the environment with no matching local activation record
- **THEN** the system reports it as unknown rather than attributing it to a mode by guessing from its path or deleting it

### Requirement: ctx skills read-only skill-discovery inventory

The system SHALL provide `ctx skills` as a filesystem/configuration-based, strictly read-only inventory of the skill directories Copilot might discover, explicitly headed as **potential Copilot skill discovery** and explicitly not claiming skills are loaded or invoked. It SHALL report candidate skill directories with all of their origins and a single classification chosen by precedence `ctx-profile > expected-home > external` (all origins retained). Origins SHALL be a deterministic, deduplicated, comma-joined list of distinct source labels kept separate from the single classification: `ctx-profile`, `expected-home`, `copilot-skill-dirs`, `settings-skill-dirs`, `personal-copilot`, `personal-agents`, `repo-github-skills`, `repo-agents-skills`, `repo-claude-skills`, and `plugin-skills`; a path found via several sources (including several `external`-class sources) SHALL report all of its origins, not one generic label. It SHALL normalize and deduplicate paths using platform-appropriate rules, SHALL show configured-but-missing or inaccessible paths cleanly without failing, and SHALL NOT emit unrelated settings or secrets. It SHALL inventory the observable/applicable sources: active context/profile `.github/skills` dirs; the expected `<COPILOT_HOME>/skills`; personal `~/.copilot/skills` and `~/.agents/skills`; repository `.github/skills`, `.agents/skills`, and `.claude/skills` in the current directory and applicable ancestors; `COPILOT_SKILLS_DIRS`; configured `skillDirectories` in relevant Copilot settings; and detectable additional-directory/installed-plugin skill paths (an installed-plugins root itself SHALL NOT be reported as a skill directory; only observable `skills`/`.github/skills` subdirectories under plugins may be, and the boundary SHALL be disclosed). If the active context provenance does not match its session record, `ctx skills` SHALL say attribution is unknown and SHALL NOT guess ctx-owned paths. It SHALL clearly disclose categories a filesystem/config diagnostic cannot observe (notably another Copilot process's command-line arguments), SHALL NOT invoke the Copilot CLI, and SHALL NOT modify settings, files, or the environment. `ctx check` SHALL remain strictly read-only and continue to skip the external Copilot probe.

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
