# Tasks

## 0. Evidence gate (needs a run go)

- [ ] 0.1 On one named client version, signed in, as a sandbox account: build a fabricated snapshot by hand (D3). Start `claude -p` with `--add-dir <snapshot>`, `--settings <snapshot>/ctx-settings.json` and `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`. Verify from the stream-json `init` event that the snapshot skills are listed. Verify that the snapshot `CLAUDE.md` loads: the model must repeat a unique marker from it. Repeat without the variable and record whether `CLAUDE.md` loads.
- [ ] 0.2 Record the result in `docs/native-skill-isolation-poc.md`. If 0.1 fails, stop and report the blocker. Do not start task 1.

## 1. Grammar

- [ ] 1.1 `ctx.sh` and `ctx.ps1`: parse `harness:` per D1 in the shared `.ctx` parser, before any state change.
- [ ] 1.2 Bats and Pester cases: valid values, the default, key case and value case. Also: empty, unknown and duplicate values, `home:` with Claude, a legacy profile with Claude, and an old `harness` entry label.

## 2. Snapshot and activation

- [ ] 2.1 Build the snapshot per D3. Check the client per D7. Publish the record per D4 and D5 only after both succeed.
- [ ] 2.2 Bats and Pester: byte-exact `CLAUDE.md` for LF, CRLF, BOM, no final newline and two profiles in order. Skill copy with a supporting asset.
- [ ] 2.2a Bats and Pester failure cases: case collision, symlink, limits, missing client, and removal of a partial snapshot. Each failure keeps the previous activation.
- [ ] 2.3 Bats and Pester: A then B then A gives three distinct snapshots; B content never appears in an A snapshot.

## 3. Output, check, current, clear

- [ ] 3.1 Guidance per D6, with quoting tests for a space, a `'` and non-ASCII text in the snapshot path.
- [ ] 3.2 `ctx check` per D9, `ctx current` shows the harness and snapshot, `ctx clear` and `ctx clear --all` per D5. The engine is not called with a Claude record.
- [ ] 3.3 Switch tests: Copilot to Claude, Claude to Copilot, user-set Copilot variables kept.

## 4. Docs and sync

- [ ] 4.1 README: `harness:claude`, the printed command, ambient sources, the `@path` limit, snapshot retention.
- [ ] 4.2 Run the full Bats and Pester suites, `bash -n ctx.sh`, the PowerShell parse check and `openspec validate --all --strict`.
- [ ] 4.3 After merge of the implementation, sync the specs and archive this change.
