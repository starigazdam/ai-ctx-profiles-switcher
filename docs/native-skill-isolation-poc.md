# Native skill isolation PoC (issue #83)

Issue: [#83](https://github.com/starigazdam/ai-ctx-profiles-switcher/issues/83)
Run date: 2026-11-13. Host: Linux 7.0.14, bash 5.2.37, Node 26.7.0, .NET SDK 10.0.400.

This PoC does not change `ctx.sh`, `ctx.ps1`, `install.sh` or `install.ps1`.
No Windows probe ran, so this document makes no Windows or PowerShell claim.

## How to run

```sh
experiments/native-isolation/run-probes.sh
```

The script runs offline. It does not log in and it does not call a model.
It writes only into one `mktemp -d` directory and removes it on exit
(`KEEP=1` keeps it). It exits 0 when every expectation holds and 1 on a
mismatch.

- `COPILOT_CMD` selects the Copilot CLI. The npm loader runs the version that is
  in the cache of the fake `HOME`. To pin 1.0.111, use
  `COPILOT_CMD="node ~/.cache/copilot/pkg/linux-x64/1.0.111/index.js"`.
- `CLAUDE_CMD` selects Claude Code. When it is not found, P3 prints `SKIP`.
- `ctx clear` needs the .NET 10 engine. Set `CTX_ENGINE_DLL`, or the script
  builds `src/Ctx` into the temp directory. That build touches two SDK lock
  directories outside the temp directory (`$DOTNET_ROOT/metadata` and
  `/tmp/.dotnet/shm`). No file stays there. With a prebuilt `CTX_ENGINE_DLL`,
  a `find -newer` check found no write outside the temp directory.

Counts use only fixture skills (paths in the temp directory) and built-in
skills. Host skills above the temp directory are out of scope.

Mutation check: the script was run one time with the key misspelled as
`ignoredSkillLocationsX`. P1.1, P1.3 and P4.1 to P4.3 failed, and the exit
code was 1. The correct key restored `RESULT: PASS`.

## Results

Evidence class `verified` means a command in this table ran on this host and
gave the stated result. `documented` means vendor text only.

| ID | Client | Version | Claim | Evidence | Command |
|---|---|---|---|---|---|
| P1.0-P1.2 | Copilot CLI | 1.0.111 | `ignoredSkillsLocations` in `$COPILOT_HOME/settings.json` removes the listed skill roots (3 fixture skills to 0). The built-in count stays 3. Removing the key restores the 3 skills. | verified | `run-probes.sh` P1.0-P1.2 |
| P1.3-P1.4 | Copilot CLI | 1.0.111 | The ignore list applies only to the home that holds it. A context home with the list shows 0 fixture skills. The default home after that still shows 3. | verified | `run-probes.sh` P1.3-P1.4 |
| P1.5 | Copilot CLI | 1.0.111 | The same key in a repository `.github/copilot/settings.json` has no effect (3 stay 3). The workspace was not a trusted folder. | verified | `run-probes.sh` P1.5 |
| P1.6 | Copilot CLI | 1.0.111 | `COPILOT_SKILLS_DIRS` adds a root (`source: custom`). It does not remove other roots. | verified | `run-probes.sh` P1.6 |
| P1.7 | Copilot CLI | 1.0.111 | With a custom `COPILOT_HOME`, the personal roots `~/.copilot/skills` and `~/.agents/skills` are not listed. Only the ancestor (`inherited`) root stays. | verified | `run-probes.sh` P1.7 |
| P1.8-P1.9 | Copilot CLI | 1.0.111 | An ignore entry is a path prefix: a parent directory hides every skill root below it, also a `COPILOT_SKILLS_DIRS` root. A glob (`<dir>/*/skills`) had no effect. | verified | `run-probes.sh` P1.8-P1.9; glob: manual run, see "P1 glob" below |
| P1.x | Copilot CLI | 1.0.88 | The same P1 and P4 results hold on 1.0.88 (built-in count 2). | verified | `COPILOT_CMD="node ~/.cache/copilot/pkg/linux-x64/1.0.88/index.js" CLAUDE_CMD=none run-probes.sh` |
| P1.d | Copilot CLI | 1.0.111 | `disabledSkills` is the repository-level option (names, `plugin:skill` form). | documented | `copilot help config` |
| P2.0 | Copilot CLI | 1.0.111 | `copilot --add-dir <profile> skill list --json` does not list the profile skills. | verified | `run-probes.sh` P2.0 |
| P2.1 | Copilot CLI | 1.0.111 | In an interactive session, `--add-dir <profile>` loads the profile's `.github/skills`, `.agents/skills` and `.claude/skills`. `/skills` shows all three as `Repository`. The only trust prompt is "Confirm folder trust" for the working directory. There is no prompt for the added directory. No login and no model call. | verified | see "P2 session" below |
| P3.0 | Claude Code | 2.1.292 | The stream-json `init` event lists skills before the "Not logged in" result. So skill visibility can be tested with no login and no model call. | verified | `run-probes.sh` P3.0 |
| P3.1 | Claude Code | 2.1.292 | `--add-dir <profile>` loads `<profile>/.claude/skills`. | verified | `run-probes.sh` P3.1 |
| P3.2 | Claude Code | 2.1.292 | `--setting-sources project` removes `~/.claude/skills`. It keeps `--add-dir` skills and ancestor `.claude/skills`. | verified | `run-probes.sh` P3.2 |
| P3.3-P3.4 | Claude Code | 2.1.292 | `skillOverrides: {"<name>": "off"}` in `--settings` JSON hides that skill. It works with `--setting-sources project` too. | verified | `run-probes.sh` P3.3-P3.4 |
| P3.5 | Claude Code | 2.1.292 | `name-only` keeps the skill name in the `init` list. | verified | `run-probes.sh` P3.5 |
| P3.6 | Claude Code | 2.1.292 | `disableBundledSkills: true` removes the bundled skills (35 to 21 in the run). | verified | `run-probes.sh` P3.6 |
| P3.7-P3.8 | Claude Code | 2.1.292 | `--plugin-dir` adds a plugin skill as `prof:pl-skill`. `skillOverrides` does not hide it, by bare or by `plugin:skill` name. | verified | `run-probes.sh` P3.7-P3.8 |
| P3.9 | Claude Code | 2.1.323 docs | Dropping the `user` source keeps subscription auth, because auth is not a setting source. | documented | not run: `claude auth status` reports `loggedIn: false` on this host |
| P3.10 | Claude Code | 2.1.323 docs | `CLAUDE.md` from `--add-dir` needs `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`. `claudeMdExcludes` takes globs of `CLAUDE.md` paths. | documented | none |
| P3.11 | Claude Code | 2.1.323 docs | `--bare` removes subscription OAuth, so it is not usable for `ctx`. | documented | none |
| P4.1-P4.3 | Copilot CLI + `ctx.sh` | 1.0.111, develop `2645f99` | Real `ctx.sh` in Mode C (`ephemeral-clean`): `ctx alpha`, `ctx beta`, `ctx alpha`. After each activation the PoC writes an ignore list into the new ephemeral home. Each step shows only that profile's skill. No skill and no ignore list leaks to the next step. | verified | `run-probes.sh` P4.1-P4.3 |
| P4.4-P4.6 | Copilot CLI + `ctx.sh` | 1.0.111, develop `2645f99` | `ctx clear` unsets `COPILOT_HOME` and `COPILOT_SKILLS_DIRS`. The default home then shows the 3 global fixture skills again. The default `settings.json` is never written. | verified | `run-probes.sh` P4.4-P4.6 |

The ignore-list write in P4 is a PoC step. `ctx.sh` does not do it today.

### P1 glob

```sh
echo '{"ignoredSkillsLocations":["<tmp>/anc/*/skills"]}' > <tmp>/ch/settings.json
cd <tmp>/anc/ws && env -i PATH="$PATH" HOME=<tmp>/h COPILOT_HOME=<tmp>/ch \
  node ~/.cache/copilot/pkg/linux-x64/1.0.111/index.js skill list --json
```

Result: the three ancestor skills (`.agents`, `.claude`, `.github`) stayed listed.

### P2 session

Fixture: a profile with one skill in each of `.github/skills`, `.agents/skills`
and `.claude/skills`, and a fake `HOME` with no login.

```sh
tmux new-session -d -s p2 -x 200 -y 60 "env -i PATH=$PATH TERM=xterm-256color \
  HOME=<tmp>/home COPILOT_AUTO_UPDATE=false \
  node ~/.cache/copilot/pkg/linux-x64/1.0.111/index.js --add-dir <tmp>/prof/A"
tmux send-keys -t p2 Enter          # answer "Confirm folder trust" with 1. Yes
tmux send-keys -t p2 /skills Enter
tmux send-keys -t p2 / a-           # filter the list
tmux capture-pane -p -t p2
```

Captured result: `✓ a-agents Repository`, `✓ a-claude Repository`,
`✓ a-github Repository`. The P2 session check is not in `run-probes.sh`,
because a TUI capture is not deterministic.

## Design decision

**Decision: option 2. Stop the projection and inject `COPILOT_SKILLS_DIRS`
per activation. Support exclusion in Mode C (`ephemeral-clean`) only.**

On each Mode C activation, `ctx` writes a private `settings.json` into the new
ephemeral home. The file holds `ignoredSkillsLocations`. Mode C already exports
`COPILOT_SKILLS_DIRS` and does not project skills. P4 proves this contract with
the real `ctx.sh`.

Reasons:

1. The ignore list is user scope only (P1.5). Copilot reads it only from
   `$COPILOT_HOME/settings.json` (P1.3, P1.4). So exclusion needs a
   per-context `settings.json`.
2. Mode C owns a new, empty home for each activation. A file written there
   cannot reach another context or the default home (P4.1 to P4.6).
3. Under a custom home, the personal roots are already absent (P1.7). The list
   must cover only the ancestor (`inherited`) roots of the workspace.

Mode scope:

- **Mode C** supports exclusion with this decision.
- **Mode A** keeps the `skills/` projection and gets no exclusion. Its
  `settings.json` stays a symlink to the shared `~/.copilot/settings.json`.
  An ignore list there would be written into the shared file. That is a stop
  gate of #83, and it would change every Mode A context and normal use.
- **Mode B** gets no exclusion. It uses the user's home, so an ignore list
  would also be written into the shared user settings.

`settings.json` symlink consequence: no change. Mode A keeps the shared
symlink. Mode C has no symlink, and its `settings.json` is a private file that
`ctx` creates.

Rejected options:

- Option 1 (projection plus a per-context ignore file in Mode A) needs Mode A to
  replace the `settings.json` symlink with a real file. That file would no
  longer follow the user's settings. The symlink exists to keep them shared.
- Option 3 (hybrid) keeps the Mode A synthetic home for state. That home still
  has the shared `settings.json` symlink, so it has the same exclusion gap as
  Mode A.

Limits and follow-up work (not in this issue):

- Prefix semantics (P1.8, P1.9): an entry must not be a parent of the
  workspace or of a profile directory. Otherwise it also hides project skills
  or `COPILOT_SKILLS_DIRS` roots. `ctx` must list exact skill roots
  (`<ancestor>/.agents/skills`, `.claude/skills`, `.github/skills`).
- The ancestor roots depend on the working directory. A list written at
  activation does not follow a later `cd` into a different tree.
- Mode C rejects canonical profiles, and its `COPILOT_SKILLS_DIRS` includes
  only `.github/skills`. Canonical `.agents/skills` support in Mode C is a
  separate change.
- A Mode C home starts empty, so it has no signed-in account and no session
  history. This PoC does not test sign-in in Mode C.
- For Claude Code, `--setting-sources project`, `--add-dir` and
  `skillOverrides` give a working skill filter (P3.1 to P3.4). Ancestor
  `.claude/skills` still load under `project`, and `skillOverrides` does not
  cover plugin skills. The auth claim (P3.9) is not verified. The #22 gate
  stays in place.

## Review

The Opus review verdict for the exact PoC head is in the PR and issue comments.
