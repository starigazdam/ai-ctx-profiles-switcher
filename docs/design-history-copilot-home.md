# Plan: Issue #1 — Per-folder skill isolation via `COPILOT_HOME`

Repo: `starigazdam/ai-ctx-profiles-switcher`
Issue: https://github.com/starigazdam/ai-ctx-profiles-switcher/issues/1
Status: Historical design record — implemented by PR #3 and extended by PR #8.
The checklist and test matrix below describe the design as it was proposed;
the current implementation and user-facing behavior are documented in the
repository README.

## 1. Goal

Replace the current `settings.local.json` / `skillDirectories` approach
(confirmed broken — silently ignored by Copilot CLI, see README "What
does NOT work" + issue #1 body) with genuine per-folder, session-isolated
skill discovery, using `COPILOT_HOME` as proposed in the issue, refined by
the "already ephemeral" comment (no active cleanup needed on `ctx clear`;
per-context home dirs persist on disk as a reusable cache).

## 2. Scope

- `ctx.sh` (bash/zsh) — primary implementation, full feature
- `ctx.ps1` (PowerShell) — mirrored implementation (repo convention:
  every feature must exist in both, per `.github/copilot-instructions.md`)
- `examples/ai-profiles/test/.github/skills/test-profile-skill/SKILL.md`
  — fix malformed frontmatter (tracked separately as issue #2, folded into
  this change since the new automated tests depend on this fixture
  actually loading)
- New automated test suite (bats for `ctx.sh`, Pester for `ctx.ps1`)
- README updates: replace "What does NOT work" section framing, document
  new behavior, remove "planned" language for the `COPILOT_HOME` approach
- `.gitignore` guidance update (new generated path)

Out of scope: MCP servers, session-history sharing edge cases beyond
what's needed for basic auth/model settings to keep working, Windows
symlink privilege issues beyond a documented fallback.

## 3. Design

### 3.1 Directory layout

```
~/.config/ctx/homes/<context-name>/
  settings.json        -> symlink to ~/.copilot/settings.json
  config.json           -> symlink to ~/.copilot/config.json
  mcp-config.json        -> symlink to ~/.copilot/mcp-config.json (if exists)
  session-store.db*      -> symlink to ~/.copilot/session-store.db*
  session-state/         -> symlink to ~/.copilot/session-state/
  installed-plugins/     -> symlink to ~/.copilot/installed-plugins/
  logs/                  -> symlink to ~/.copilot/logs/
  skills/
    <skill-name>/         -> symlink to the real skill dir (from .ctx entries)
```

`<context-name>` = the same string `ctx` already computes for `AI_CTX_PROFILES`
(e.g. `review+test`), sanitized for filesystem use (replace `/` and other
unsafe characters — `+` is already safe).

### 3.2 What gets symlinked back vs. left context-local

Symlinked back to `~/.copilot` (shared, so auth/model/session history
keep working identically to today):
`settings.json`, `config.json`, `mcp-config.json`, `session-store.db`,
`session-store.db-shm`, `session-store.db-wal`, `session-state/`,
`installed-plugins/`, `logs/`.

Context-local (NOT shared): `skills/` — populated only with symlinks to
`.github/skills/*` subfolders found under each resolved `.ctx`/profile
directory for *this* context.

This deliberately avoids ever writing to `~/.copilot/settings.json`
(Option 2 in the current README) or polluting `~/.copilot/skills`
(Option 1) — each context sees exactly its own skills and nothing else.

### 3.3 Trigger points

- `ctx <profile> [shared...]` (manual activation) and `.ctx` auto-load
  (`_ctx_load_ctx_file`) both call a new function,
  `_ctx_setup_copilot_home <context-name> <resolved-dir>...`, which:
  1. Computes `home_dir=~/.config/ctx/homes/<sanitized-context-name>`
  2. Creates it (and `skills/`) if missing
  3. Ensures the shared-file symlinks exist (idempotent — skip if already
     correct symlink; recreate if missing/stale/pointing elsewhere)
  4. For each resolved dir with a `.github/skills` subfolder, symlinks
     each skill subdirectory into `home_dir/skills/<skill-name>`
     (idempotent; removes stale skill symlinks from a previous run that
     no longer correspond to a current entry — see 3.5)
  5. `export COPILOT_HOME="$home_dir"`
- `ctx clear` — unsets `COPILOT_HOME` (in addition to existing
  `AI_CTX_PROFILES`/`COPILOT_CUSTOM_INSTRUCTIONS_DIRS` unset). Per the
  "already ephemeral" comment, the on-disk home dir is left in place as a
  reusable cache — no deletion.
- `ctx clear --all` — additionally removes the current context's
  `~/.config/ctx/homes/<context-name>/` directory (in addition to today's
  `settings.local.json` / `*.code-workspace` cleanup). Only the *current*
  context's home dir is removed, not all cached homes.
- Since `skillDirectories`-in-`settings.local.json` no longer serves any
  purpose (confirmed inert), **stop writing it**: remove
  `_ctx_update_skill_directories` call from `_ctx_load_ctx_file` /
  the manual `ctx` path. Keep the function's removal path in `ctx clear
  --all` for one release (delete pre-existing files left over from older
  ctx versions) with a comment, then drop entirely in a follow-up.
- VS Code `.code-workspace` generation (`_ctx_update_workspace_file`) is
  unrelated to Copilot CLI skill discovery and stays as-is.

### 3.4 Idempotency / staleness handling

Because home dirs persist as a cache, re-activating the same context
(e.g. re-`cd`-ing into a `.ctx` dir, or re-running `ctx review`) must:
- Not recreate symlinks that are already correct (avoid unnecessary
  filesystem churn / mtime changes)
- Detect and fix symlinks that point to the wrong target (e.g. shared
  files if `~/.copilot` was reset, or a skill dir that moved)
- Remove skill symlinks under `skills/` that no longer correspond to any
  currently-resolved `.github/skills/*` entry for this context (prevents
  stale skills lingering after a profile's skill set changes)

Implementation: a small reconciliation loop — read desired
(name -> target) pairs, diff against existing symlinks in the directory,
remove extras, (re)create missing/incorrect ones.

### 3.4a 🔴 Confirmed hazard: atomic-rename-through-symlink orphans shared files

**Empirically verified against real, authenticated Copilot CLI 1.0.80**
(see issue comment with full transcript). Symlinking individual *files*
(as opposed to directories) back to `~/.copilot` is unsafe for any file
Copilot CLI writes to during a session.

**Repro**: symlinked `settings.json` from a synthetic `COPILOT_HOME` to
the real `~/.copilot/settings.json`, then ran
`COPILOT_HOME=/tmp/synthome copilot --bash-env=on -p "say hi" --allow-all-tools`
(a flag documented to persist a setting). Result:

- `/tmp/synthome/settings.json` was **no longer a symlink** afterward —
  it had become an independent regular file containing `{"bashEnv": true}`.
- The real `~/.copilot/settings.json` was **untouched**, still `{}`.

**Root cause**: Copilot CLI writes `settings.json` via the standard
write-tmp-then-`rename()` pattern. `rename(tmp, path)` onto a path that is
a symlink **replaces the symlink itself** with the new regular file — it
does not dereference and write through to the symlink's target. This is
standard POSIX `rename(2)` behavior, not a Copilot CLI bug, but it means
"symlink individual files back to `~/.copilot`" silently breaks the
moment any such file is written.

**Control (same run)**: `config.json`, `session-store.db`,
`session-state/`, `installed-plugins/`, `logs/` all remained intact
symlinks after the same invocation. This only rules out breakage
*during this specific run* — `config.json` in particular wasn't written
to in this test, so it is not proven safe, only "not observed unsafe
here." **Every file in the symlink-back list (3.2) must be treated as
at-risk until proven otherwise**, since we don't control or want to
depend on Copilot CLI's internal write strategy per file, and it can
change across CLI versions.

**Design fix — self-healing reconciliation on every activation.**
Extend the reconciliation loop from 3.4 to run this check, per file,
*before* comparing/creating symlinks, on every `ctx <profile>` /
`.ctx` auto-load invocation (not just once at first creation):

1. `test -L "$home_dir/<file>"` — is it still a symlink?
2. If **not** a symlink (i.e. the CLI replaced it via rename), it now
   holds this context's real, current data. Before touching anything:
   copy its content over the real `~/.copilot/<file>` (`cp -f`), so the
   most recent write wins and isn't silently lost.
3. Delete the plain file and recreate the symlink pointing at
   `~/.copilot/<file>`.
4. If it **is** already a correct symlink, no-op (matches existing 3.4
   idempotency behavior).

This must run for every file in the symlinked-file list — `settings.json`
(confirmed at-risk), `config.json`, `mcp-config.json`,
`session-store.db`/`-shm`/`-wal`. Directories (`session-state/`,
`installed-plugins/`, `logs/`) get the same treatment defensively even
though not observed broken, since a directory symlink can in principle
be replaced the same way (e.g. `rmdir` + `mkdir` by the CLI) — the
reconciliation function should be written generically over a list of
paths, not special-cased per file, so directories are covered for free
and any future file Copilot CLI starts writing is automatically safe
once added to the list.

**Known residual risk**: reconciliation is still only *eventually*
consistent — if the user runs two contexts concurrently in two shells,
each with its own `COPILOT_HOME`, and both happen to write
`settings.json` in the same window before either reconciles, one
context's write can still be lost (last reconciliation wins, not a
merge). This is a narrower, harder-to-hit race than the original
always-silently-orphaned bug, and out of scope to fully solve here —
call it out explicitly in the README as a known limitation of concurrent
context use, rather than silently leaving it undocumented.

### 3.5 Windows / `ctx.ps1` symlink considerations

`New-Item -ItemType SymbolicLink` requires either Developer Mode enabled
or admin privileges on Windows. Plan:
- Try symlinks first (`New-Item -ItemType SymbolicLink`)
- On failure (permission error), fall back to **junctions** for
  directories (`New-Item -ItemType Junction`, no special privilege
  required) — works for `skills/<name>` and the `session-state`/
  `installed-plugins`/`logs` directories
- For individual files (`settings.json`, `config.json`, etc.), junctions
  aren't valid; fall back to **hardlinks** (`New-Item -ItemType
  HardLink`) — same volume required, which holds for `~/.copilot` and
  `~/.config/ctx` both under `$HOME` in the default install
- If all else fails, print a clear warning and skip `COPILOT_HOME`
  isolation for that session (leave `COPILOT_HOME` unset, fall back to
  today's behavior) rather than hard-failing `ctx`

### 3.6 `_ctx_print_status` / `ctx current` output

Add a line showing whether `COPILOT_HOME` isolation is active and its
path, e.g.:
```
COPILOT_HOME=/home/user/.config/ctx/homes/review+test
```
(this already exists as a status line today — currently always
`<unset>`; after this change it will show the real path when a context
is active)

## 4. Fix: `test-profile-skill` malformed frontmatter (issue #2)

`examples/ai-profiles/test/.github/skills/test-profile-skill/SKILL.md`
currently has:
```
\---

name: test-profile-skill
description: Test skill in test profile to see if it will load

\---
```
Fix to:
```
---
name: test-profile-skill
description: Test skill in test profile to see if it will load
---
```
This fixture must load cleanly for the new automated tests (section 5) to
verify multi-skill, multi-profile isolation (`test` + `review` both
active, both skills visible, no cross-context bleed).

## 5. Automated tests

### 5.1 Framework

- **bash/zsh (`ctx.sh`)**: [bats-core](https://github.com/bats-core/bats-core),
  installed via `npm install --no-save bats` in CI / locally (no sudo
  required — confirmed working in this environment). Test files under
  `tests/ctx.bats`.
- **PowerShell (`ctx.ps1`)**: [Pester](https://pester.dev/) (bundled with
  PowerShell 7+; installable via `Install-Module Pester -Scope
  CurrentUser` without admin on Windows PowerShell 5.1). Test file
  `tests/ctx.Tests.ps1`.
- Both suites are self-contained — no live Copilot CLI network calls; we
  assert on the filesystem side effects (symlinks/junctions created,
  correct targets, correct cleanup) since that's what's actually under
  `ctx`'s control and what caused the original bug (asserting against a
  real `copilot skill list` would require the CLI installed + authed in
  CI, which is unnecessary — the contract we own is "did we create the
  right symlinks in the right place").
- An **optional** smoke-test script (`tests/smoke-copilot-cli.sh`, not
  run in CI) is included for manual verification against a real,
  authenticated Copilot CLI install — mirrors what was done manually in
  this chat (`copilot skill list` before/after activating a context).

### 5.2 Test matrix (bats, mirrored in Pester)

Setup: each test runs in an isolated `$HOME`/`$AI_CONFIG_ROOT`/
`~/.config/ctx` via a temp dir (bats `setup()`/`teardown()`), so tests
never touch the real user's `~/.copilot` or `~/.config/ctx`.

1. **Manual activation creates isolated home**
   `ctx <profile>` with a profile containing `.github/skills/foo` →
   assert `~/.config/ctx/homes/<profile>/skills/foo` is a symlink to the
   correct target, and `COPILOT_HOME` env var is exported to the home dir.

2. **Shared-file symlinks point at the real `~/.copilot`**
   Assert `settings.json`, `config.json`, `session-state/`, etc. under
   the home dir resolve (via `readlink -f` / `Resolve-Path`) to files
   under a fake `~/.copilot`, proving global auth/config is preserved.

3. **Multi-profile + shared context, no bleed**
   `ctx review test` (or `.ctx` with two entries, using the now-fixed
   `test-profile-skill` fixture) → assert **both** skill symlinks exist
   in the same home dir, and a **separate** context (`ctx review` alone)
   has its own home dir containing only `review`'s skill — proving
   isolation.

4. **Idempotent re-activation**
   Run `ctx <profile>` twice → assert symlink mtimes/inodes unchanged
   (no unnecessary recreation) on the second run.

5. **Stale skill removal**
   Activate a context, remove a skill dir from the source profile (or
   switch the `.ctx` file to reference fewer entries), reactivate →
   assert the now-orphaned symlink under `skills/` is removed.

6. **`ctx clear` unsets `COPILOT_HOME` but preserves the cache dir**
   Assert `COPILOT_HOME` is unset in the shell env after `ctx clear`, but
   `~/.config/ctx/homes/<context-name>/` still exists on disk.

7. **`ctx clear --all` removes the current context's home dir**
   Assert the specific `homes/<context-name>` directory is deleted, but
   (if present) other unrelated cached context homes are left untouched.

8. **`.ctx` auto-load path exercises the same logic as manual `ctx`**
   Using `examples/copilot-cli-dotctx-test-review/.ctx` (existing
   fixture) — `cd` into the dir (simulated by directly invoking
   `_ctx_auto_load_hook` after `cd`, matching how `chpwd`/
   `PROMPT_COMMAND` would fire) → assert same isolation guarantees as
   test 3.

9. **No more `settings.local.json` writes**
   Assert `.github/copilot/settings.local.json` is *not* created/modified
   by a fresh `ctx`/`.ctx` activation (regression guard — this file was
   the broken mechanism being replaced).

10. **Fallback behavior on symlink failure** (simulated via a mocked
    failing `ln` in bats — this is the only rung of the section 3.5
    ladder exercised in CI, since `ubuntu-latest` doesn't hit Windows
    permission errors; the junction/hardlink fallback paths in `ctx.ps1`
    are manual-verification-only per section 5.3)
    Force symlink creation to fail → assert `ctx` prints a clear warning
    and does not crash; either falls back gracefully or leaves
    `COPILOT_HOME` unset for that session per section 3.5.

11. **Fixture regression test**
    `copilot skill add`-equivalent check (frontmatter parse) — a
    lightweight test that parses
    `test-profile-skill/SKILL.md`'s frontmatter with a simple YAML-ish
    check (`^---$` delimiters, `name:`/`description:` present) to catch
    any future regression of the issue #2 bug without requiring the
    actual Copilot CLI binary in CI.

12. **Symlink-replaced-by-write is detected and reconciled (regression
    guard for the confirmed hazard in 3.4a)**
    Simulate the CLI's rename-through-symlink behavior directly (no real
    Copilot CLI needed in CI): `rm` the `settings.json` symlink under a
    test home dir and write a plain file with new content in its place
    (mirrors what `rename(tmp, path)` does), matching the real repro.
    Reactivate the context (`ctx <profile>` again) → assert:
    - the new content was copied into the *real* (fake, per-test)
      `~/.copilot/settings.json`
    - `home_dir/settings.json` is a symlink again, pointing at the real
      file
    - reading through the restored symlink returns the reconciled content

13. **Reconciliation runs for every file in the symlink-back list, not
    just `settings.json`**
    Parametrize test 12 (bats `@test` per file, or a loop) over
    `config.json`, `mcp-config.json`, `session-store.db` — same
    assertions. Ensures the fix isn't special-cased to the one file we
    happened to catch empirically and will also catch it if a future
    Copilot CLI version starts writing e.g. `config.json` directly.

14. **Reconciliation is a no-op when nothing changed**
    Run reconciliation twice with no intervening write → assert no
    unnecessary `cp`/recreate happens the second time (combine with test
    4's idempotency assertions — same mtime/inode check applies to the
    reconciliation step itself, not just initial symlink creation).

### 5.3 CI wiring

Single `ubuntu-latest`-only workflow (no Windows runner — keeps CI fast
and simple; `pwsh` (PowerShell 7+, cross-platform) ships preinstalled on
`ubuntu-latest` images, so it exercises the real `ctx.ps1` logic, just
without the Windows-only symlink/junction/hardlink fallback ladder from
section 3.5, which stays manual-verification-only, documented as such in
the PR/README).

Add `.github/workflows/test.yml`:
- One job on `ubuntu-latest` with two steps:
  1. `npm install --no-save bats` → `bats tests/ctx.bats`
  2. `Install-Module Pester -Force -Scope CurrentUser` (via
     `shell: pwsh`) → `Invoke-Pester tests/ctx.Tests.ps1 -CI`
- Triggered on push + PR to any branch touching `ctx.sh`, `ctx.ps1`, or
  `tests/**`

Note: GitHub Actions minutes are free/unlimited for `ubuntu-latest` (and
any runner) on public repos, so cost was not a driver here — this is
purely a "keep CI simple, one OS" simplification requested by the repo
owner.

## 6. README updates

- Rewrite "Skill discovery" section: remove "What does NOT work" as the
  primary framing (keep it, but as a historical "why not the simple
  approaches" subsection), promote `COPILOT_HOME` isolation as the
  **actual, implemented** behavior (not "planned")
- Update the environment variable table to note `COPILOT_HOME` is now
  managed automatically by `ctx` when a context is active
- Add a "Testing" section: how to run `bats`/`Pester` locally
- Update `.gitignore` guidance: `.github/copilot/settings.local.json` is
  no longer generated by `ctx` — note this is now optional guidance /
  mark as legacy for pre-upgrade repos
- Cross-link issue #2 fix in a short changelog-style note (optional)

## 7. Migration / backward compatibility notes

- Users who already have a `.github/copilot/settings.local.json`
  generated by an older `ctx` version: harmless leftover, not actively
  read by Copilot CLI (confirmed), can be deleted manually or via one
  `ctx clear --all` run under the old code path before upgrading — call
  this out in README/CHANGELOG.
- No breaking change to `AI_CTX_PROFILES` / `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`
  behavior — those keep working exactly as today (custom instructions
  loading was never broken, only skills).

## 8. Implementation checklist (order of work)

1. Fix `test-profile-skill/SKILL.md` frontmatter (issue #2)
2. Add bats + Pester test scaffolding (`tests/`, empty/skeleton specs)
3. Implement `_ctx_setup_copilot_home` + reconciliation logic in `ctx.sh`,
   including the symlink-replaced-by-write self-healing check from 3.4a
   (this is now part of the core function, not a follow-up — a version
   without it is confirmed to silently lose/orphan settings)
4. Wire into manual `ctx` path and `_ctx_load_ctx_file` (auto-load path)
5. Wire `COPILOT_HOME` unset into `_ctx_clear`; home-dir removal into
   `ctx clear --all`
6. Remove `_ctx_update_skill_directories` call sites (keep function only
   for the one-release cleanup-of-legacy-file path in `ctx clear --all`)
7. Write full bats suite (section 5.2, including tests 12–14 for the
   3.4a hazard), get it green against `ctx.sh`
8. Mirror everything into `ctx.ps1` (`Set-CtxCopilotHome` or similar,
   following existing `Verb-CtxNoun` naming convention) with the
   symlink/junction/hardlink fallback ladder
9. Write full Pester suite, get it green against `ctx.ps1`
10. Add `.github/workflows/test.yml`
11. Update README + `.github/copilot-instructions.md` (include the
    concurrent-context known-limitation note from 3.4a)
12. Manual smoke test against real Copilot CLI (the `tests/smoke-copilot-cli.sh`
    script) — repeat the verification done manually in this session, now
    scripted, confirming `copilot skill list` actually shows
    context-scoped skills with real isolation
13. Open PR referencing issue #1 (and #2), request review

## 9. Risks / open questions for confirmation

- **Q1 — RESOLVED (empirically tested, see 3.4a)**: Symlinking
  individual files (e.g. `settings.json`) back to `~/.copilot` **is**
  broken as originally proposed — confirmed via a real, authenticated
  Copilot CLI 1.0.80 run: the CLI's write-tmp+rename replaces the
  symlink with a plain file, orphaning the real `~/.copilot/settings.json`
  from that point on. Directories (`session-state/`, `installed-plugins/`,
  `logs/`) were not observed to break in the same test, but are treated
  as at-risk defensively (see 3.4a) since the reconciliation fix is
  applied generically rather than trusting per-file/per-type assumptions.
  Fix: self-healing reconciliation on every activation, detailed in
  3.4a, now part of the core design and checklist step 3 — no longer an
  open risk, but a required implementation component with its own test
  coverage (tests 12–14).
- **Q2**: Sanitizing `<context-name>` for use as a directory name — plan
  assumes `+` is safe and no other separators appear (profile names come
  from directory basenames, which are already filesystem-safe by
  definition). Should be fine, but flagging the assumption.
- **Q3**: Should stale **whole context home dirs** (not just stale skill
  symlinks within one) ever be garbage collected automatically (e.g. not
  accessed in N days), or is manual `ctx clear --all` / a future `ctx gc`
  command sufficient? Proposing: out of scope for this issue, leave as a
  manual operation for now.

## 10. Deliverable summary for issue comment

Once this plan is confirmed, it will be posted as a comment on issue #1,
then implementation proceeds per the checklist in section 8, with the PR
opened at the end referencing both issue #1 and #2.
