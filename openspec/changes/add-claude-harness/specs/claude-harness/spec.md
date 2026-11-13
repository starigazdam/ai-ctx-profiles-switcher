# Spec Delta

## ADDED Requirements

### Requirement: harness directive

The system SHALL accept a reserved `.ctx` directive `harness:<value>`. The key SHALL be matched case-insensitively, and whitespace around the key and the value SHALL be trimmed. The value SHALL be exactly `claude` or `copilot`. A file without the directive SHALL select `copilot`, and `harness:copilot` SHALL behave exactly like a file without the directive. The system SHALL reject the whole file before any state change in each of these cases:

- The value is empty or unknown.
- The file has more than one `harness:` line in any key case.
- `harness:claude` appears with a `home:` line.
- The file has `harness:` and no profile entry.

Manual activation (`ctx <profile>...`) SHALL NOT select Claude.

#### Scenario: Missing directive keeps Copilot

- **WHEN** a `.ctx` file has no `harness:` line and no entry labelled `harness`
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
- **THEN** the file is rejected with `ctx: error: harness claude: legacy-profile <label>`, and the previous activation stays unchanged

### Requirement: Claude client check

Before it builds a snapshot, the system SHALL run these checks. Each call SHALL have a 10-second limit and SHALL NOT start a session or call a model.

- `claude` is on `PATH`. Otherwise the reason is `client-missing`.
- `claude --version` exits 0. Otherwise the reason is `client-failed`.
- `claude --help` exits 0, and its output contains `--add-dir` and `--settings`. Otherwise the reason is `client-unsupported`.

The system SHALL print the version and SHALL NOT compare it with a minimum version.

#### Scenario: Missing client fails before any change

- **WHEN** a `.ctx` file with `harness:claude` is loaded and `claude` is not on `PATH`
- **THEN** the activation fails with `client-missing`, no snapshot stays, and the previous activation stays unchanged

### Requirement: Claude selection snapshot

Each Claude activation SHALL create a new unique private snapshot directory with the Mode C temp-directory primitive and the name prefix `ctx-claude.`. A colliding path or a link SHALL reject the activation. The snapshot SHALL contain only:

- `CLAUDE.md`: each selected profile in `.ctx` order adds the line `<!-- ctx profile <n> <label> -->`, a newline and its `AGENTS.md` bytes. A leading UTF-8 BOM SHALL be removed. A newline SHALL follow when the bytes do not end with one. `@path` imports SHALL NOT be resolved.
- `.claude/skills/<name>/`: a copy of each `<profile>/.agents/skills/<name>/` directory that contains a regular `SKILL.md`, with all supporting files.
- `ctx-settings.json`: exactly `{"autoMemoryEnabled": false}` and a newline.

The activation SHALL fail before any state change in each of these cases:

- A symlink, junction or special file is in a selected skill.
- Two selected skills have the same name, or names that differ only in case.
- The snapshot has more than 2000 files or more than 32 MiB.

On a failure before publication, the system SHALL remove the snapshot directory that this call created, without following links. The system SHALL NOT copy hooks, settings, MCP servers, agents, commands, plugins, or credentials into the snapshot. It SHALL NOT write to any source profile.

#### Scenario: CLAUDE.md holds the selected bytes in order

- **WHEN** a `.ctx` file selects canonical profiles `a` then `b` with `harness:claude`
- **THEN** `CLAUDE.md` holds the marker line and bytes of `a`, then those of `b`. Only a leading BOM is removed and only a missing final newline is added

#### Scenario: Skills are copied with their assets

- **WHEN** a selected profile has `.agents/skills/s/SKILL.md` and `.agents/skills/s/ref/data.txt`
- **THEN** the snapshot has `.claude/skills/s/SKILL.md` and `.claude/skills/s/ref/data.txt` with the same bytes

#### Scenario: Name collision is rejected

- **WHEN** two selected profiles have skills `lint` and `lint`, or `Lint` and `lint`
- **THEN** the activation fails with `skill-collision`, and no snapshot stays

#### Scenario: Each activation gets its own snapshot

- **WHEN** a user loads task A, then task B, then task A again
- **THEN** three distinct snapshots exist, and no content of B appears in either A snapshot

### Requirement: Claude activation order

The system SHALL run a Claude activation in this order:

1. Parse and check the `.ctx` file.
2. Check the client.
3. Build the snapshot.
4. Reset an existing Copilot activation.
5. Publish the Claude record.

The Copilot reset SHALL use the same routine as `ctx clear` and SHALL NOT change that routine. Only that reset step SHALL read or change Copilot state. A failure before the reset SHALL keep the previous activation and record unchanged. A failure in the reset SHALL remove the new snapshot, SHALL NOT publish the Claude record, and SHALL print `reset-failed`.

#### Scenario: User Copilot variables survive a switch to Claude

- **WHEN** a user set `COPILOT_SKILLS_DIRS` before `ctx` ran, and then loads a `.ctx` file with `harness:claude`
- **THEN** the user value is unchanged

#### Scenario: A reset failure publishes nothing

- **WHEN** the Copilot reset fails during a Claude activation
- **THEN** the error contains `reset-failed`, the new snapshot is removed, and no Claude record exists

### Requirement: Claude launch guidance

On success, the system SHALL print these lines:

- the client version;
- each selected profile with its order, label and resolved path;
- each copied skill with its source label;
- the snapshot path;
- a notice that Claude also loads user, ancestor, repository, managed and built-in sources, which `ctx` does not filter;
- a notice that these sources depend on the start directory;
- a notice that the effective context is unknown;
- a notice that the memory setting is documented, not verified;
- a notice that only a new session uses the selection;
- exactly one start command.

The Bash/zsh command SHALL be `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir '<snapshot>' --settings '<snapshot>/ctx-settings.json'`. Each `'` in a path SHALL be written as `'\''`.

The PowerShell command SHALL save the earlier value of `$env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`, set it to `'1'`, and run `claude --add-dir '<snapshot>' --settings '<snapshot>\ctx-settings.json'` in a `try` block. A `finally` block SHALL restore the earlier value, or remove the variable when it was not set. Each `'` in a path SHALL be written as `''`.

The system SHALL NOT start Claude, SHALL NOT export `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` in the shell, and SHALL NOT change `HOME`, `USERPROFILE`, `CLAUDE_CONFIG_DIR`, or any Claude setting file. Each error SHALL start with `ctx: error: harness claude: ` and a reason token from the design.

#### Scenario: The command is quoted for the shell

- **WHEN** the snapshot path contains a space, a `'`, and non-ASCII text
- **THEN** the printed command, pasted into the same shell, passes the exact path to `claude`

#### Scenario: PowerShell restores the variable

- **WHEN** `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` has the value `0` and the user runs the printed PowerShell command
- **THEN** the variable has the value `0` again after `claude` exits, also when `claude` fails

#### Scenario: Ambient sources are disclosed, not filtered

- **WHEN** a Claude activation succeeds
- **THEN** the output states that ambient sources still load and that the effective context is unknown, and the command has no `--setting-sources` argument

### Requirement: Claude record, current, and clear

The system SHALL keep the Claude record in the shell session only. The record SHALL hold the harness, the `.ctx` path and the sha256 of its bytes, the ordered labels and resolved paths, and the snapshot path. `ctx current` and `ctx clear` SHALL handle a Claude record in the shell without calling the .NET engine. `ctx current` SHALL print the harness and the snapshot path. `ctx clear` and `ctx clear --all` SHALL remove the record and print the retained snapshot path. The system SHALL NOT delete a published snapshot. A later Copilot activation SHALL remove the Claude record.

#### Scenario: Clear keeps the snapshot

- **WHEN** a user runs `ctx clear --all` with a Claude record
- **THEN** the record is removed, the snapshot path is printed, and the snapshot stays on disk

### Requirement: Claude check

With a Claude record, `ctx check` SHALL be read-only. It SHALL compare the nearest `.ctx` path and the sha256 of its bytes with the record. It SHALL recompute the expected `CLAUDE.md` bytes and skill tree from the recorded paths and compare them with the snapshot. It SHALL compare `ctx-settings.json` with its fixed bytes. Each difference SHALL print `CHECK FAIL harness:claude stale <path>`. A missing snapshot SHALL print `CHECK FAIL harness:claude missing`. When all comparisons match, it SHALL print `CHECK PASS harness:claude`. Copilot checks SHALL print `CHECK SKIP`. Auto-load SHALL keep acting on a directory change only. An edit in the same directory SHALL NOT rebuild the snapshot.

#### Scenario: Edited source is reported as stale

- **WHEN** a selected `AGENTS.md` changes after activation and the user runs `ctx check`
- **THEN** the check prints `CHECK FAIL harness:claude stale` with that path, exits non-zero, and changes no file

#### Scenario: Edited selection is reported as stale

- **WHEN** the user edits the `.ctx` file in the same directory to select another profile, and runs `ctx check`
- **THEN** the check prints `CHECK FAIL harness:claude stale` with the `.ctx` path and exits non-zero
