# Design

## Context

Issue #22 Step 3 lists seven contract items. This design gives one choice for each. Evidence classes follow `docs/native-skill-isolation-poc.md`: `verified` means a command ran on a named client version; `documented` means vendor text only.

Evidence that the design uses:

- `--add-dir <dir>` adds `<dir>/.claude/skills` (verified, 2.1.292 offline and 2.1.250 signed in, #83 P3.1 and P3.1s).
- A profile with only `.agents/skills` adds no skill through `--add-dir` (verified, 2.1.292, #22 comment 6127372437).
- `CLAUDE.md` in an added directory loads only with `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` (documented).
- `--settings` accepts a file path or a JSON string (documented). `autoMemoryEnabled: false` turns off auto-memory (documented).

Task 0 must verify the three documented items before implementation starts.

## Decisions

### D1. Grammar

- `harness:<value>` is a reserved directive, like `home:`. The key is case-insensitive. Whitespace around key and value is trimmed.
- The value must be exactly `claude` or `copilot`. Any other value, an empty value, or a second `harness:` line (any key case) rejects the file.
- No directive means `copilot`. `harness:copilot` is the same as no directive.
- A file with `harness:` and no profile entry is rejected. The handling of other directive-only files does not change.
- An entry with the label `harness` is no longer an ordinary entry. Old files that use that label get a reserved-directive error.
- `home:` with `harness:claude` rejects the file. `home:` is Copilot-only.

### D2. Profile rules

- Every selected profile must be canonical (root `AGENTS.md`). A legacy profile rejects the file and the error names it.
- `@profile`, direct paths, trusted-root containment and duplicate checks stay as they are.

### D3. Snapshot

- Location: a new unique directory from the Mode C primitive (`mktemp -d` on POSIX; `GetTempPath()` plus a random suffix in PowerShell). Name prefix `ctx-claude.`. Mode 0700 on POSIX. A collision or a link rejects the activation.
- `CLAUDE.md`: each profile in `.ctx` order adds the line `<!-- ctx profile <n> <label> -->`, a newline and its exact `AGENTS.md` bytes. A newline follows when the source does not end with one. No BOM is added. A source BOM is removed only at the start of each source, so the output has no BOM in the middle.
- `@path` imports in `AGENTS.md` are not resolved. The bytes are copied as they are. A relative import then resolves from the snapshot, not from the profile. The README states this limit.
- `.claude/skills/<name>/`: a copy of each `<profile>/.agents/skills/<name>/` that has a regular `SKILL.md`. Regular files and directories only. A symlink, a junction or another special file anywhere in a selected skill rejects the activation.
- Two selected skills whose names differ only in case reject the activation. Copilot Mode A uses warn-and-skip; Claude does not, because a skipped skill is not visible to the user at session start.
- Limits: at most 2000 files and 32 MiB in one snapshot. Over the limit, the activation fails and the error gives the count.
- `ctx-settings.json`: exactly `{"autoMemoryEnabled": false}` and a newline.
- On a failure during the build, `ctx` removes only the directory that this call created. It does not follow links.

### D4. Selection record

- The record is shell-session state only: harness, ordered labels, resolved paths, snapshot path. No file registry.
- The .NET engine is not changed. `ctx current` and `ctx clear` read the Claude record in the shell before they delegate to the engine. When a Claude record is active, the Copilot engine path is not called.
- `AI_CTX_PROFILES` is exported as today (the `+`-joined labels), for prompts only. The record is the source of truth, not that variable.

### D5. Switch and clear

- A Claude activation that succeeds first resets the previous activation exactly like `ctx clear` does today, then publishes the Claude record. Copilot variables that a previous `ctx` activation set are unset. Values that the user set are not touched.
- A Claude activation does not create, change or read a Copilot home.
- Copilot activation after Claude drops the Claude record.
- `ctx clear` and `ctx clear --all` drop the Claude record and print the retained snapshot path. They never delete the snapshot.

### D6. Guidance output

On success, `ctx` prints these lines (Bash/zsh form):

```text
ctx: harness claude (Claude Code <version>)
ctx: selected 1 <label> <path>
ctx: selected 2 <label> <path>
ctx: snapshot <snapshot>
ctx: ambient: Claude also loads user, ancestor, repository, managed and built-in sources. ctx does not filter them.
ctx: start a NEW Claude session (an open session does not change):
CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir '<snapshot>' --settings '<snapshot>/ctx-settings.json'
```

- Bash/zsh quoting: single quotes, with `'` written as `'\''`.
- PowerShell prints: `$env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = '1'; claude --add-dir '<snapshot>' --settings '<snapshot>\ctx-settings.json'; Remove-Item Env:CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`. A `'` is written as `''`. The settings file avoids JSON quoting through a native command line in Windows PowerShell 5.1.
- `ctx` does not set `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` in the shell. The variable stays local to the printed command.

### D7. Client check

- `claude` must be on `PATH`, and `claude --version` must exit 0 within 10 seconds. Otherwise the activation fails before publication.
- `ctx` prints the version. It does not compare it with a minimum. The evidence table lists the verified versions.

### D8. Same-directory changes

- Auto-load keeps its current rule: it acts on a directory change only. An edit of `.ctx` or of a profile in the same directory does not rebuild the snapshot.
- `ctx check` reports a stale snapshot (D9). The user runs `ctx load` again.

### D9. `ctx check`

- With a Claude record, `ctx check` is read-only. It recomputes the expected `CLAUDE.md` bytes and skill tree from the recorded paths and compares them with the snapshot.
- `CHECK PASS harness:claude` when all bytes match. `CHECK FAIL harness:claude stale <path>` for each difference, `CHECK FAIL harness:claude missing` when the snapshot is gone.
- Copilot checks print `CHECK SKIP` with a Claude record.

## Risks and limits

- Ambient sources can add or shadow skills with the same name. `ctx` discloses this. It does not detect it.
- A profile of another task can still load through an ambient path, for example an ancestor `.claude/skills`. #22 calls that a task-separation blocker. This change cannot prevent it. The README tells the user to keep task profiles out of ancestor paths.
- `autoMemoryEnabled: false` is documented only. Task 0 checks that `--settings <file>` is accepted. It cannot prove that no memory write happens.
- Snapshots stay on disk until the user removes them, like Mode C homes.
- Windows behavior is tested only by the Pester suite on the hosted runner. No native Claude run on Windows.
