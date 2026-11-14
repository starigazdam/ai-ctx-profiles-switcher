# Tasks

## 0. Evidence gate (needs a separate run approval)

Done on 2026-11-13: owner go in #22, `RESULT: PASS` on Claude Code 2.1.250. Evidence: `docs/native-skill-isolation-poc.md`, section "Claude harness task 0".

- [x] 0.0 Write the probe like `experiments/native-isolation/claude-signed-in.sh`. It is opt-in and runs as a sandbox account. Exit codes: 0 for PASS, 1 for FAIL, 2 for BLOCKED. Each client call has a 60-second limit. Cleanup deletes only owned paths. Run an offline self-check with a fake client first.
- [x] 0.1 On one named client version, signed in: build a fabricated snapshot by hand (D3). Start `claude -p` with `--add-dir <snapshot>`, `--settings <snapshot>/ctx-settings.json` and `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`. The stream-json `init` event must list the snapshot skills.
- [x] 0.2 The response must contain a unique marker from the snapshot `CLAUDE.md`. Repeat without the variable and record whether the response contains the marker.
- [x] 0.3 Record that the client accepts `--settings <file>` (exit 0, a successful result). Do not claim that it reads `autoMemoryEnabled` or that no memory write occurs.
- [x] 0.4 Put a task-B canonical profile next to the task-A workspace. Put an earlier task-B snapshot in the temp directory. Start the task-A recipe in the task-A workspace. No task-B skill and no task-B marker may appear. If one appears, print `BLOCKED other-task`, stop, and ask the owner.
- [x] 0.5 Record the results in `docs/native-skill-isolation-poc.md`. If 0.1, 0.2, 0.3 or 0.4 does not pass, stop. Do not start task 1.

## 1. Grammar

- [ ] 1.1 `ctx.sh` and `ctx.ps1`: parse `harness:` per D1 in the shared `.ctx` parser, before any state change.
- [ ] 1.2 Bats and Pester cases: valid values, the default, key case and value case. Also: each `harness-*` reason text from D6, and `legacy-profile` for a legacy profile with Claude.

## 2. Snapshot and activation

- [ ] 2.1 Implement the D4 steps in order: parse, client check (D7), snapshot (D3), Copilot reset, publication.
- [ ] 2.2 Bats and Pester: byte-exact `CLAUDE.md` for LF, CRLF, BOM, no final newline and two profiles in order. Skill copy with a supporting asset.
- [ ] 2.3 Bats and Pester failure cases: equal and case-variant skill names, a symlink, both limits and each D7 reason. Each case also checks removal of the new snapshot. Each failure in steps 1 to 3 keeps the previous activation.
- [ ] 2.4 Bats and Pester: a reset failure in step 4 removes the new snapshot, publishes no record and prints `reset-failed`.
- [ ] 2.5 Bats and Pester: A then B then A gives three distinct snapshots; B content never appears in an A snapshot.

## 3. Output, check, current, clear

- [ ] 3.1 Guidance and error lines per D6. Quoting tests for a space, a `'` and non-ASCII text in the snapshot path. A PowerShell test that the printed line restores an earlier value and removes an unset one.
- [ ] 3.2 `ctx check` per D10. Cases: a changed `.ctx`, `AGENTS.md`, skill file or settings file, and a missing snapshot.
- [ ] 3.3 `ctx current` shows the harness and the snapshot. `ctx clear` and `ctx clear --all` follow D5. The engine is not called with a Claude record.
- [ ] 3.4 Switch tests: Copilot to Claude, Claude to Copilot, user-set Copilot variables kept.

## 4. Docs and sync

- [ ] 4.1 README: `harness:claude`, the printed command, ambient sources, the `@path` limit, the memory limit and snapshot retention.
- [ ] 4.2 Run the full Bats and Pester suites, `bash -n ctx.sh`, the PowerShell parse check and `openspec validate --all --strict`.
- [ ] 4.3 After the implementation merges, sync the specs and archive this change.
