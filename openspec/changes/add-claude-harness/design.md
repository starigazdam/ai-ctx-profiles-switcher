# Design

## Context

Issue #22 Step 3 lists seven contract items. This design gives a choice for each item. One choice (D8, snapshot retention) differs from the #22 text and needs an owner decision. Evidence classes follow `docs/native-skill-isolation-poc.md`: `verified` means a command ran on a named client version; `documented` means vendor text only.

Evidence that the design uses:

- `--add-dir <dir>` adds `<dir>/.claude/skills` (verified, 2.1.292 offline and 2.1.250 signed in, #83 P3.1 and P3.1s).
- A profile with only `.agents/skills` adds no skill through `--add-dir` (verified, 2.1.292, #22 comment 6127372437).
- `CLAUDE.md` in an added directory loads only with `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` (documented).
- `--settings` accepts a file path or a JSON string (documented).
- `autoMemoryEnabled: false` disables auto-memory (documented).

Task 0 verifies the first two documented items before implementation starts. The memory item stays documented. Task 0 cannot show that Claude reads the key or that no memory write occurs. The guidance output states this limit.

## Decisions

### D1. Grammar

- `harness:<value>` is a reserved directive, like `home:`. The key is case-insensitive. Whitespace around key and value is trimmed.
- The value must be exactly `claude` or `copilot`. Any other value, an empty value, or a second `harness:` line (any key case) rejects the file.
- No directive means `copilot`. `harness:copilot` is the same as no directive.
- A file with `harness:` and no profile entry is rejected. The handling of other directive-only files does not change.
- A line with the label `harness` is not an ordinary entry any more. This is the only change for current users: an old file with an entry labelled `harness` now gets an error.
- `home:` with `harness:claude` rejects the file. `home:` is Copilot-only.

### D2. Profile rules

- Every selected profile must be canonical (root `AGENTS.md`). A legacy profile rejects the file and the error names it.
- `@profile`, direct paths, trusted-root containment and duplicate checks stay as they are.

### D3. Snapshot

- Location: a new unique directory from the Mode C primitive (`mktemp -d` on POSIX; `GetTempPath()` plus a random suffix in PowerShell). Name prefix `ctx-claude.`. Mode 0700 on POSIX. On Windows, the directory keeps the ACL that it gets from the user temp directory. A collision or a link rejects the activation.
- `CLAUDE.md`: each profile in `.ctx` order adds the line `<!-- ctx profile <n> <label> -->`, a newline and its exact `AGENTS.md` bytes. A newline follows when the source does not end with one. No BOM is added. A source BOM is removed only at the start of each source, so the output has no BOM in the middle.
- `@path` imports in `AGENTS.md` are not resolved. The bytes are copied as they are. A relative import then resolves from the snapshot, not from the profile. The README states this limit.
- `.claude/skills/<name>/`: a copy of each `<profile>/.agents/skills/<name>/` that has a regular `SKILL.md`. Regular files and directories only. A symlink, a junction or another special file anywhere in a selected skill rejects the activation.
- Two selected skills with the same name, or with names that differ only in case, reject the activation. Copilot Mode A uses warn-and-skip; Claude does not, because a skipped skill is not visible to the user at session start.
- Limits: at most 2000 files and 32 MiB in one snapshot. Over the limit, the activation fails and the error gives the count.
- `ctx-settings.json`: exactly `{"autoMemoryEnabled": false}` and a newline.

### D4. Activation order and record

A Claude activation runs these steps in this order:

1. Parse and check the `.ctx` file (D1, D2).
2. Check the client (D7).
3. Build the snapshot (D3).
4. When a Copilot activation record exists, reset it with the same routine that `ctx clear` uses today. This step does not change: it can read and change the Mode A home and call the engine, as `ctx clear` does today.
5. Publish the Claude record.

- A failure in steps 1 to 3 removes the snapshot that this call created, without following links. The previous activation and record stay unchanged.
- A failure in step 4 also removes the new snapshot and does not publish the record. The state is then what a failed `ctx clear` leaves today. The error says that the previous activation was partly reset.
- The record is shell-session state only. It holds the harness, the `.ctx` path and the sha256 of its bytes. It also holds the ordered labels, the resolved paths and the snapshot path. No file registry.
- Only step 4 can touch Copilot state. The Claude steps do not create, read or change a Copilot home.
- `ctx current` and `ctx clear` read the Claude record in the shell before they delegate to the engine. With a Claude record, they do not call the engine. The engine (`src/Ctx/**`) does not change.
- `AI_CTX_PROFILES` is exported as today (the `+`-joined labels), for prompts only. The record is the source of truth, not that variable.

### D5. Switch and clear

- A Copilot activation after Claude removes the Claude record.
- `ctx clear` and `ctx clear --all` remove the Claude record and print the retained snapshot path.
- A published snapshot is never deleted by `ctx` (D8).
- Values of Copilot variables that the user set are not touched. Step 4 unsets only values that a previous `ctx` activation set, as `ctx clear` does today.

### D6. Guidance output

On success, `ctx` prints these lines (Bash/zsh form):

```text
ctx: harness claude (Claude Code <version>)
ctx: selected 1 <label> <path>
ctx: selected 2 <label> <path>
ctx: skill <name> from <label>
ctx: snapshot <snapshot>
ctx: ambient: Claude also loads user, ancestor, repository, managed and built-in sources. ctx does not filter them.
ctx: ambient: these sources depend on the directory where you start claude.
ctx: effective context: unknown. ctx lists only the selected inputs.
ctx: memory: ctx-settings.json sets autoMemoryEnabled false. This effect is documented, not verified.
ctx: start a NEW Claude session in your work directory (an open session does not change):
CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir '<snapshot>' --settings '<snapshot>/ctx-settings.json'
```

- The command has no `cd`. The user starts it in the directory where the work is. The snapshot reaches the session through `--add-dir` from any directory.
- Bash/zsh quoting: single quotes, with `'` written as `'\''`. The leading assignment applies only to that one command.
- PowerShell prints one line: `$ctxClaudeMdPrev = $env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD; $env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = '1'; try { claude --add-dir '<snapshot>' --settings '<snapshot>\ctx-settings.json' } finally { $env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = $ctxClaudeMdPrev }`. A `'` is written as `''`. The `finally` block restores the earlier value. When the variable was not set, the assignment of `$null` removes it again.
- The settings file avoids JSON quoting through a native command line in Windows PowerShell 5.1.
- `ctx` itself does not set `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` in the shell.

Errors use one prefix and a fixed reason token:

```text
ctx: error: harness claude: <reason> [<detail>]
```

Reasons: `client-missing`, `client-failed`, `client-unsupported`, `legacy-profile <label>`, `skill-collision <name>`, `skill-link <path>`, `limit-files <count>`, `limit-bytes <count>`, `snapshot-failed <detail>`, `reset-failed <detail>`.

### D7. Client check

- `claude` must be on `PATH`. Otherwise: `client-missing`.
- `claude --version` must exit 0 within 10 seconds. Otherwise: `client-failed`.
- `claude --help` must exit 0 within 10 seconds, and its output must contain `--add-dir` and `--settings`. Otherwise: `client-unsupported`.
- These calls do not start a session and do not call a model. `ctx` prints the version. It does not compare it with a minimum version. The evidence table lists the versions that task 0 verified.

### D8. Snapshot retention (owner decision)

- `ctx` never deletes a published snapshot. A running session can still use it. `ctx` cannot know when that session ends.
- This follows the Mode C home rule. #22 item 5 asks for "bounded retention and explicit owned cleanup conditions". This design gives no automatic bound. The user removes old `ctx-claude.*` directories, and `ctx clear` prints the path.
- Owner decision: accept unbounded retention, or name a bound. A bound could be "`ctx clear --all` deletes snapshots that this shell created, except the active one". That bound still cannot see a running session in another shell.

### D9. Stale state and same-directory changes

- Auto-load keeps its current rule: it acts on a directory change only. An edit in the same directory does not rebuild the snapshot and does not print new guidance.
- `ctx check` finds stale state (D10). The user then runs `ctx load` again. That builds a new snapshot and replaces the record.

### D10. `ctx check`

With a Claude record, `ctx check` is read-only. It compares:

- the nearest `.ctx` path and the sha256 of its bytes with the record. A different path or different bytes give `CHECK FAIL harness:claude stale <.ctx path>`. This covers a changed selection, a changed label or a changed root.
- the expected `CLAUDE.md` bytes and skill tree, from the recorded paths, with the snapshot. Each difference gives `CHECK FAIL harness:claude stale <path>`.
- `ctx-settings.json` with its fixed bytes. A difference gives `CHECK FAIL harness:claude stale ctx-settings.json`.

A missing snapshot gives `CHECK FAIL harness:claude missing`. When all comparisons match: `CHECK PASS harness:claude`. Copilot checks print `CHECK SKIP` with a Claude record.

## Risks and limits

- Ambient sources can add or shadow skills with the same name. `ctx` discloses this. It does not detect it.
- A profile of another task can still load through an ambient path, for example an ancestor `.claude/skills`. #22 calls that a task-separation blocker. Task 0.4 tests realistic paths. If it finds a leak, the work stops for an owner decision.
- Task 0 is narrower than all #22 packet A obligations. It covers the native recipe of this contract. The owner decides whether it replaces packet A Steps 2a and 2b.
- `autoMemoryEnabled: false` stays documented only.
- Snapshots stay on disk until the user removes them (D8).
- No native Claude run on Windows. The implementation adds Pester cases. They run on the hosted Windows runner when CI runs.
