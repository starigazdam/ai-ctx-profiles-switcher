# Native skill isolation PoC (issue #83)

Issue: [#83](https://github.com/starigazdam/ai-ctx-profiles-switcher/issues/83)
Run date: 2026-11-13. Host: Linux. The exact-head evidence comment prints the
tool versions.

This PoC does not change `ctx.sh`, `ctx.ps1`, `install.sh` or `install.ps1`.
No Windows probe ran, so this document makes no Windows or PowerShell claim.

## How to run

```sh
dotnet build src/Ctx/Ctx.csproj --configuration Release   # CI step; without it P4 is skipped
d=$(mktemp -d) && TMPDIR=$d \
  experiments/native-isolation/ro-run.sh experiments/native-isolation/run-probes.sh
ls -A "$d"                                                # empty = nothing left behind
```

Only this form is shown to run offline. A bare `run-probes.sh` call does not
remove the network.

The probes do not log in and do not call a model. They write only into one
`mktemp -d` directory and remove it at exit (`KEEP=1` keeps it). The script
exits 0 when every expectation that ran holds, and 1 on a mismatch. The
`RESULT` line names each skipped group.

- `ro-run.sh` is the write confinement. By default it runs its inner part
  through `unshare -rnm`, which removes the network. The test-only variable
  `RO_RUN_UNSHARE` accepts only `-rnm`, `-rm` or `-rn`.
  Both mount namespace ids must be readable and non-empty. The inner part first fails when
  its mount namespace is the outer one, or when an interface other than `lo`
  exists. It then remounts every mount read-only. Only `$TMPDIR`, `/proc`, `/sys`, `/dev/pts`,
  `/dev/mqueue` and device nodes stay writable. It fails when another
  writable mount stays, and it prints the list of writable mounts.
- `CTX_ENGINE_DLL` defaults to the CI build output
  `src/Ctx/bin/Release/net10.0/Ctx.dll`. `ctx clear` needs it. When it is
  missing, P4 prints `SKIP`. The script does not build it, because a
  `dotnet build` writes into the checkout and into SDK lock directories.
- `COPILOT_CMD` selects Copilot CLI. On this host, the default `copilot` npm
  loader ran 1.0.88 under the fake `HOME`. To pin 1.0.111, use an absolute
  path: `COPILOT_CMD="node $HOME/.cache/copilot/pkg/linux-x64/1.0.111/index.js"`.
- `CLAUDE_CMD` selects Claude Code. When it is not found, P3 prints `SKIP`.
- `claude-signed-in.sh` is a separate probe for a signed-in session. It calls
  the model and uses the real login of the caller, so it is not offline. Run it
  only as a sandbox account, with `CLAUDE_SIGNED_IN_PROBE=1`. See "Signed-in
  run" below.

Each Copilot line prints the built-in count, the fixture count `n`, the
fixture names and `name:source` pairs (`:off` marks a disabled skill). Each
exclusion claim, and each no-effect claim of an exclusion setting, prints
`[before n=X -> after n=Y]`. Each before value is a checked baseline. P3.6
prints the totals instead. Counts include only
fixture skills (paths in the temp directory). Host skills above the temp
directory are out of scope.

## Runs at the PoC head

The PR comment for the reviewed head holds the raw output of these runs:

1. Clean clone, no engine build, default commands, under `ro-run.sh`:
   `RESULT: PASS (skipped: P4)`, exit 0. The writable `$TMPDIR` was empty after the run.
2. After the CI build step, under `ro-run.sh`, with `COPILOT_CMD` pinned to
   1.0.111: `RESULT: PASS`, exit 0. The writable `$TMPDIR` was empty after the run.
3. The same under `ro-run.sh` with the default `copilot` (1.0.88): `RESULT: PASS`, exit 0.
4. Mutant: the line `KEY=ignoredSkillsLocations` changed to a wrong key. The
   checks that expect an effect failed: P1.1, P1.3, P1.8, P1.9 and P4.1 to
   P4.3 after injection. Exit 1. The log shows only `FAIL` and `RESULT` lines.
   No `FAIL` line names the no-effect checks (P1.5, P1.10, P1.11).

## Results

Evidence class `verified` means a command in this table ran on this host and
gave the stated result. `documented` means vendor text only.

| ID | Client | Version | Claim | Evidence | Command |
|---|---|---|---|---|---|
| P1.0-P1.2 | Copilot CLI | 1.0.111, 1.0.88 | `ignoredSkillsLocations` in `$COPILOT_HOME/settings.json` removes the three listed fixture roots (n=3 to n=0). The built-in count does not change. Without the key, the 3 skills come back. | verified | `run-probes.sh` P1.0-P1.2 |
| P1.3-P1.4 | Copilot CLI | 1.0.111, 1.0.88 | The ignore list applies only to the home that holds it. A context home with the list shows n=0. The default home after that still shows n=3. | verified | `run-probes.sh` P1.3-P1.4 |
| P1.5a | Copilot CLI | 1.0.111, 1.0.88 | When the working directory is a git repository root, the skill root of an ancestor above it is not listed (n=3 to n=2). | verified | `run-probes.sh` P1.5a |
| P1.5 | Copilot CLI | 1.0.111, 1.0.88 | In a git repository with `trustedFolders` set in `config.json`, `ignoredSkillsLocations` in `.github/copilot/settings.json` has no effect (n=2 stays n=2). Control: `disabledSkills` in the same file turns `g-agents` off, so Copilot read the file. The probe does not show the trust state itself. | verified | `run-probes.sh` P1.5 |
| P1.6 | Copilot CLI | 1.0.111, 1.0.88 | `COPILOT_SKILLS_DIRS` adds a root with `source: custom`. It removes no other root. | verified | `run-probes.sh` P1.6 |
| P1.7 | Copilot CLI | 1.0.111, 1.0.88 | With a custom `COPILOT_HOME`, the fixture skills in `~/.copilot/skills` and `~/.agents/skills` are not listed. The fixture ancestor skill stays (`source: inherited`). | verified | `run-probes.sh` P1.7 |
| P1.8-P1.9 | Copilot CLI | 1.0.111, 1.0.88 | An ignore entry is a path prefix. A parent directory hides every skill root below it. That includes a `COPILOT_SKILLS_DIRS` root. | verified | `run-probes.sh` P1.8-P1.9 |
| P1.10 | Copilot CLI | 1.0.111, 1.0.88 | A glob entry (`<dir>/*/skills`) has no effect. | verified | `run-probes.sh` P1.10 |
| P1.11 | Copilot CLI | 1.0.111, 1.0.88 | A string prefix that is not a parent directory (`<tmp>/an` for `<tmp>/anc`) has no effect. In this probe, prefixes match whole path components. | verified | `run-probes.sh` P1.11 |
| P1.d | Copilot CLI | 1.0.111 help | The key name in the help text is the flat `ignoredSkillsLocations`. Issue #83 reports that the web docs show `skills.ignoredLocations`. This PoC did not check the web page. | documented | `copilot help config` |
| P2.0 | Copilot CLI | 1.0.111, 1.0.88 | `copilot --add-dir <profile> skill list --json` exits 0 and does not list the profile skills. | verified | `run-probes.sh` P2.0 |
| P2.1 | Copilot CLI | 1.0.111 | In an interactive session, `--add-dir <profile>` loads the profile's `.github/skills`, `.agents/skills` and `.claude/skills`. `/skills` shows all three as `Repository`. At start, the capture shows a "Confirm folder trust" prompt. No login and no model call. | verified | "P2 session" below |
| P3.0 | Claude Code | 2.1.292 | Not signed in, the stream-json `init` event lists the skills. The result is then "Not logged in", so no model call happens. Each P3 check requires that result. | verified | `run-probes.sh` P3.0 |
| P3.1 | Claude Code | 2.1.292 | `--add-dir <profile>` adds `<profile>/.claude/skills` to the `init` list. | verified | `run-probes.sh` P3.1 |
| P3.2 | Claude Code | 2.1.292 | `--setting-sources project` removes `~/.claude/skills` (n=3 to n=2). Ancestor `.claude/skills` and `--add-dir` skills stay. | verified | `run-probes.sh` P3.2 |
| P3.3-P3.4 | Claude Code | 2.1.292 | `skillOverrides: {"<name>": "off"}` in `--settings` JSON removes that skill from the `init` list. This also works with `--setting-sources project`. | verified | `run-probes.sh` P3.3-P3.4 |
| P3.5 | Claude Code | 2.1.292 | With `name-only`, the skill stays in the `init` list. | verified | `run-probes.sh` P3.5 |
| P3.6 | Claude Code | 2.1.292 | With `disableBundledSkills: true`, the total drops (35 to 21 on this host). The fixture skills stay. | verified | `run-probes.sh` P3.6 |
| P3.7-P3.8 | Claude Code | 2.1.292 | `--plugin-dir` adds a plugin skill as `prof:pl-skill`. `skillOverrides` does not remove it, by bare name or by `plugin:skill` name. | verified | `run-probes.sh` P3.7-P3.8 |
| P3.9 | Claude Code | 2.1.250, signed in | A session with `--setting-sources project` returned a successful answer (exit 0, `subtype: success`, `is_error: false`, a non-empty answer). | verified | `claude-signed-in.sh` P3.2s, P3.4s |
| P3.0s-P3.5s, P3.7s-P3.8s | Claude Code | 2.1.250, signed in | These checks repeat P3.0-P3.5, P3.7 and P3.8 in a signed-in session. Each check found the same fixture skill names in the `init` list. Each check also required a successful answer. P3.6 was not repeated. | verified | `claude-signed-in.sh` |
| P3.10 | Claude Code | 2.1.323 docs, as issue #83 reports them | `CLAUDE.md` from `--add-dir` needs `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`. `claudeMdExcludes` takes globs of `CLAUDE.md` paths. Bundled skills are the skills that `disableBundledSkills` removes. | documented | none |
| P3.11 | Claude Code | 2.1.323 docs, as issue #83 reports them | `--bare` removes subscription OAuth, so it is not usable for `ctx`. | documented | none |
| P4.1-P4.3 | Copilot CLI + `ctx.sh` | 1.0.111, 1.0.88; develop `2645f99` | Real `ctx.sh` in Mode C (`ephemeral-clean`): `ctx alpha`, `ctx beta`, `ctx alpha`. Each activation gives a new home in the temp directory. The home has no `settings.json`, and the ancestor skill is visible (n=2). The PoC then writes an ignore list for the ancestor root (n=2 to n=1). Only the profile skill stays. | verified | `run-probes.sh` P4.1-P4.3 |
| P4.4-P4.6 | Copilot CLI + `ctx.sh` | 1.0.111, 1.0.88; develop `2645f99` | `ctx clear` unsets `COPILOT_HOME` and `COPILOT_SKILLS_DIRS`. The default home then shows the 3 fixture skills again. The default `settings.json` is absent after P4. | verified | `run-probes.sh` P4.4-P4.6 |

Limits of the evidence:

- The P4 ignore-list write is a manual PoC step. `ctx.sh` does not do it today.
- The P3.0-P3.8 rows cover the `init` list of a session that is not signed in.
  The signed-in rows repeat eight of them on one host, one client version
  (2.1.250) and one account. They compare only the fixture skill names, not the
  full skill list. They do not test a skill invocation.
- The fixture counts cover only the fixture. They do not give a full
  inventory of an arbitrary host.

### P2 session

Fixture: a profile with one skill in each of `.github/skills`, `.agents/skills`
and `.claude/skills`, and a fake `HOME` with no login.

```sh
X=$(mktemp -d); P=$X/prof/A
for s in .github .agents .claude; do
  n=a-${s#.}; mkdir -p "$P/$s/skills/$n" "$X/home" "$X/ws"
  printf -- '---\nname: %s\ndescription: canary %s\n---\nbody\n' "$n" "$n" >"$P/$s/skills/$n/SKILL.md"
done
tmux new-session -d -s p2 -c "$X/ws" -x 160 -y 50 "unshare -rn env -i PATH=$PATH \
  TERM=xterm-256color HOME=$X/home TMPDIR=$X COPILOT_AUTO_UPDATE=false \
  node $HOME/.cache/copilot/pkg/linux-x64/1.0.111/index.js --add-dir $P"
sleep 8; tmux send-keys -t p2 Enter   # answer "Confirm folder trust" with 1. Yes
sleep 4; tmux send-keys -t p2 /skills; sleep 2; tmux send-keys -t p2 Enter
sleep 4; tmux send-keys -t p2 /; sleep 1; tmux send-keys -t p2 a-   # filter the list
sleep 2; tmux capture-pane -p -t p2
```

Captured result: `✓ a-agents Repository`, `✓ a-claude Repository`,
`✓ a-github Repository`. The capture does not show the full prompt history. The PR comment for the reviewed head holds the
capture. The P2 session check is not in `run-probes.sh`, because a TUI capture
is not deterministic.

## Design decision

**Decision: option 2 in Mode C, plus a per-activation ignore list. Mode A and
Mode B stay unchanged.** The decision combines option 2 with the ignore file
of option 1, because option 2 alone gives no exclusion.

Option 2 says "stop the projection, inject `COPILOT_SKILLS_DIRS`". Mode C
already does both: it does not project skills, and it exports
`COPILOT_SKILLS_DIRS` (`ctx.sh` `_ctx_compute_skills_dirs_csv`, line 1292). `COPILOT_SKILLS_DIRS` only adds roots (P1.6). Thus the
proposed change adds one step: on each Mode C activation, `ctx` writes a
private `settings.json` with `ignoredSkillsLocations` into the new ephemeral
home. P4 tests this step as a manual injection with the real `ctx.sh`.

Reasons:

1. Copilot reads the ignore list from `$COPILOT_HOME/settings.json` (P1.1 to
   P1.4). The same key in a repository file has no effect (P1.5), with
   `trustedFolders` set.
   Thus exclusion needs a per-context `settings.json`.
2. Mode C creates a new, empty home for each activation. A file written there
   did not reach the next activation or the default home (P4.1 to P4.6).
3. Under a custom home, the personal fixture roots are absent (P1.7). At a git
   repository root, ancestors above it are absent (P1.5a). Thus the list must
   cover the ancestor roots that Copilot still lists. Outside a repository,
   the probe ancestor stayed listed (P1.7). Inside a repository, the roots
   between the working directory and the repository root are project roots.
   This PoC did not test that case. The follow-up must decide if `ctx` hides
   project roots.

Mode scope:

- **Mode C** supports exclusion with this decision.
- **Mode A** keeps the `skills/` projection and gets no exclusion. Its
  `settings.json` stays a symlink to the shared `~/.copilot/settings.json`.
  An ignore list there would go into the shared file. That is a stop gate of
  #83. It would also change every Mode A context and normal use.
- **Mode B** gets no exclusion. It does not set `COPILOT_HOME` (`ctx.sh`
  line 622), so an ignore list would also go into the shared user settings.

`settings.json` symlink consequence: no change. Mode A keeps the shared
symlink. Mode C has no symlink, and its `settings.json` is a private file.

Out of scope: P2.1 shows a fourth attach path. `copilot --add-dir <profile>`
loads all three profile skill roots in a session. The issue allows only its
three listed options, so the follow-up must assess `--add-dir` separately.

Rejected options:

- Option 1 (projection plus a per-context ignore file in Mode A) needs Mode A to
  replace the `settings.json` symlink with a real file. That file would no
  longer follow the user's settings. The symlink exists to keep them shared.
  This is a choice about the Mode A contract, not a limit of Copilot CLI.
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
- The help text and the web docs use different names for the key (P1.d).
  The follow-up must probe the key on each supported version.
- Mode C rejects canonical profiles (`ctx.sh` line 588), and its
  `COPILOT_SKILLS_DIRS` includes only `.github/skills` (`ctx.sh` line 1292). Canonical `.agents/skills` support in Mode C is a
  separate change.
- A Mode C home starts empty, so it has no signed-in account and no session
  history. This PoC does not test sign-in in Mode C.
- `openspec/specs/copilot-integration-modes/spec.md` still says that the CLI
  has no negative skill-root filter. The Mode C change must amend it.
- For Claude Code, `--setting-sources project`, `--add-dir` and
  `skillOverrides` change the `init` skill list as P3.1 to P3.4 show.
  Ancestor `.claude/skills` still load under `project`, and `skillOverrides`
  does not cover plugin skills. The signed-in run verifies the auth claim
  (P3.9) on 2.1.250 (see "Signed-in run"). The #22 contract still governs Claude support in `ctx`.

## Signed-in run

The run used a dedicated sandbox account with its own Claude login and Claude
Code 2.1.250. Before and after the checks, `claude auth status` reported
`loggedIn: true`, `authMethod: claude.ai` and `subscriptionType: pro`.

```sh
CLAUDE_SIGNED_IN_PROBE=1 experiments/native-isolation/claude-signed-in.sh
```

Result: 8 `PASS` lines, `RESULT: PASS`, exit 0. The script printed that
`~/.claude/skills` did not exist before the run. A check after the run found it
absent. The auth status after the checks was equal to the status before them.
Without `CLAUDE_SIGNED_IN_PROBE=1`, the script prints `BLOCKED` and exits 2.
An offline self-check used a fake client. Each check failed for an error
result, an empty answer, no answer field, and a non-zero exit. The self-check also showed that a dangling `g-global` symlink stops the
script with exit 2. The PR holds the raw output.

## Review

The review verdicts for the exact PoC head are PR comments.
