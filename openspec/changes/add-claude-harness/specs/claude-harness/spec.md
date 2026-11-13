# Spec Delta

## ADDED Requirements

### Requirement: harness directive

The system SHALL accept a reserved `.ctx` directive `harness:<value>`. The key SHALL be matched case-insensitively, and whitespace around the key and the value SHALL be trimmed. The value SHALL be exactly `claude` or `copilot`. A file without the directive SHALL select `copilot`, and `harness:copilot` SHALL behave exactly like a file without the directive. The system SHALL reject the whole file before any state change when the value is empty or unknown, when the file has more than one `harness:` line in any key case, when `harness:claude` appears with a `home:` line, or when a file with `harness:` has no profile entry. Manual activation (`ctx <profile>...`) SHALL NOT select Claude.

#### Scenario: Missing directive keeps Copilot

- **WHEN** a `.ctx` file has no `harness:` line
- **THEN** activation behaves exactly as before this change

#### Scenario: Unknown or duplicate value is rejected

- **WHEN** a `.ctx` file contains `harness:Claude`, `harness:`, `harness:codex`, or two `harness:` lines
- **THEN** the file is rejected with a non-zero exit and the previous activation stays unchanged

#### Scenario: home: is refused for Claude

- **WHEN** a `.ctx` file contains `harness:claude` and a `home:` line
- **THEN** the file is rejected before any state change

### Requirement: Claude selection is canonical only

With `harness:claude`, every selected profile SHALL be canonical (a root-level `AGENTS.md`). A legacy profile SHALL reject the file before any state change, and the error SHALL name the profile. Entry resolution, trusted-root containment, and duplicate checks SHALL be the same as for Copilot.

#### Scenario: Legacy profile is rejected for Claude

- **WHEN** a `.ctx` file with `harness:claude` selects a profile without a root `AGENTS.md`
- **THEN** the file is rejected, the error names that profile, and the previous activation stays unchanged

### Requirement: Claude client check

Before it publishes a Claude activation, the system SHALL require `claude` on `PATH` and a `claude --version` call that exits 0 within 10 seconds. Otherwise the activation SHALL fail before publication. The system SHALL print the version and SHALL NOT compare it with a minimum version. The check SHALL NOT start a session or call a model.

#### Scenario: Missing client fails before publication

- **WHEN** a `.ctx` file with `harness:claude` is loaded and `claude` is not on `PATH`
- **THEN** the activation fails, no snapshot stays, and the previous activation stays unchanged

### Requirement: Claude selection snapshot

Each successful Claude activation SHALL create a new unique private snapshot directory with the Mode C temp-directory primitive and the name prefix `ctx-claude.`. A colliding path or a link SHALL reject the activation. The snapshot SHALL contain only:

- `CLAUDE.md`: for each selected profile in `.ctx` order, the line `<!-- ctx profile <n> <label> -->`, a newline, the `AGENTS.md` bytes with a leading UTF-8 BOM removed, and a newline when those bytes do not end with one. `@path` imports SHALL NOT be resolved.
- `.claude/skills/<name>/`: a copy of each `<profile>/.agents/skills/<name>/` directory that contains a regular `SKILL.md`, with all supporting files.
- `ctx-settings.json`: exactly `{"autoMemoryEnabled": false}` and a newline.

A symlink, junction, or special file in a selected skill, two selected skills whose names differ only in case, more than 2000 files, or more than 32 MiB SHALL fail the activation before publication. On such a failure, the system SHALL remove only the snapshot directory that this call created, without following links. The system SHALL NOT copy hooks, settings, MCP servers, agents, commands, plugins, or credentials into the snapshot, and SHALL NOT write to any source profile.

#### Scenario: CLAUDE.md holds the selected bytes in order

- **WHEN** a `.ctx` file selects canonical profiles `a` then `b` with `harness:claude`
- **THEN** `CLAUDE.md` holds the marker line and bytes of `a`, then those of `b`, byte-exact except for a removed leading BOM and an added final newline

#### Scenario: Skills are copied with their assets

- **WHEN** a selected profile has `.agents/skills/s/SKILL.md` and `.agents/skills/s/ref/data.txt`
- **THEN** the snapshot has `.claude/skills/s/SKILL.md` and `.claude/skills/s/ref/data.txt` with the same bytes

#### Scenario: Case collision is rejected

- **WHEN** two selected profiles have skills `Lint` and `lint`
- **THEN** the activation fails before publication and no snapshot stays

#### Scenario: Each activation gets its own snapshot

- **WHEN** a user loads task A, then task B, then task A again
- **THEN** three distinct snapshots exist, and no content of B appears in either A snapshot

### Requirement: Claude launch guidance

On success, the system SHALL print the client version, each selected profile with its order, label, and resolved path, the snapshot path, a notice that Claude also loads user, ancestor, repository, managed, and built-in sources that `ctx` does not filter, a notice that only a new session uses the selection, and exactly one start command. The Bash/zsh command SHALL be `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir '<snapshot>' --settings '<snapshot>/ctx-settings.json'`, with each `'` in a path written as `'\''`. The PowerShell command SHALL set `$env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` to `'1'`, run `claude --add-dir '<snapshot>' --settings '<snapshot>\ctx-settings.json'`, and then remove the variable, with each `'` written as `''`. The system SHALL NOT start Claude, SHALL NOT export `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` in the shell, and SHALL NOT change `HOME`, `USERPROFILE`, `CLAUDE_CONFIG_DIR`, or any Claude setting file.

#### Scenario: The command is quoted for the shell

- **WHEN** the snapshot path contains a space, a `'`, and non-ASCII text
- **THEN** the printed command, pasted into the same shell, passes the exact path to `claude`

#### Scenario: Ambient sources are disclosed, not filtered

- **WHEN** a Claude activation succeeds
- **THEN** the output states that ambient sources still load, and the command has no `--setting-sources` argument

### Requirement: Claude activation record, switch, and clear

The system SHALL keep the Claude record (harness, ordered labels, resolved paths, snapshot path) in the shell session only. It SHALL publish the record only after the snapshot and the client check succeed, and it SHALL first reset the previous activation as `ctx clear` does today. It SHALL unset only Copilot variables that a previous `ctx` activation set. A Claude activation SHALL NOT create, change, or read a Copilot home. `ctx current` and `ctx clear` SHALL handle a Claude record in the shell without calling the .NET engine. `ctx current` SHALL print the harness and the snapshot path. `ctx clear` and `ctx clear --all` SHALL drop the record and print the retained snapshot path, and SHALL NEVER delete a snapshot. A later Copilot activation SHALL drop the Claude record. A failed activation SHALL keep the previous activation and record unchanged.

#### Scenario: Clear keeps the snapshot

- **WHEN** a user runs `ctx clear --all` with a Claude record
- **THEN** the record is dropped, the snapshot path is printed, and the snapshot stays on disk

#### Scenario: User Copilot variables survive a switch to Claude

- **WHEN** a user set `COPILOT_SKILLS_DIRS` before `ctx` ran, and then loads a `.ctx` file with `harness:claude`
- **THEN** the user value is unchanged

### Requirement: Claude check

With a Claude record, `ctx check` SHALL be read-only. It SHALL recompute the expected `CLAUDE.md` bytes and skill tree from the recorded paths and compare them with the snapshot. It SHALL print `CHECK PASS harness:claude` when all bytes match, `CHECK FAIL harness:claude stale <path>` for each difference, and `CHECK FAIL harness:claude missing` when the snapshot is gone. Copilot checks SHALL print `CHECK SKIP`. Auto-load SHALL keep acting on a directory change only; an edit in the same directory SHALL NOT rebuild the snapshot.

#### Scenario: Edited source is reported as stale

- **WHEN** a selected `AGENTS.md` changes after activation and the user runs `ctx check`
- **THEN** the check prints `CHECK FAIL harness:claude stale` with that path, exits non-zero, and changes no file
