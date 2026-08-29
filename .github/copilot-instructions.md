# Copilot Instructions — ai-ctx-profiles-switcher

## What this repo is

A **dual-implementation shell tool** (`ctx`) that composes AI agent
configuration directories into the `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`
environment variable for a GitHub Copilot CLI session:

- `ctx.sh` — bash/zsh implementation
- `ctx.ps1` — PowerShell (5.1 and 7+) implementation

Both files are **standalone dot-sourced scripts** — no build step, no
package manager, no test runner. All logic lives in those two files.
`install.sh` / `install.ps1` are thin installers that copy the scripts to
`~/.config/ctx/` and patch the user's shell profile.

## Key architecture

### Two activation modes

1. **Manual** — `ctx <profile> [shared...]`  
   Looks up directories under `$AI_CONFIG_ROOT/profiles/<profile>` and
   `$AI_CONFIG_ROOT/shared/<name>`, validates they exist, then sets
   `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` (comma-separated) and `AI_CONTEXT`
   (plus-separated names).

2. **Auto-load** — `.ctx` file in any project directory  
   Format: one `<context-name>:<path-to-folder>` line per entry.  
   Relative paths resolve against the **directory containing the `.ctx`
   file**, not `$PWD`. Paths are used directly — they are **not** looked
   up under `AI_CONFIG_ROOT`.  
   Triggered on every prompt render (bash/zsh `chpwd`-style hook; PowerShell
   wraps `prompt`). Activates when entering the tree, clears when leaving.

### Side effects of `.ctx` loading

Both implementations do the same things when a `.ctx` file is loaded:

1. **`COPILOT_HOME` skill isolation** — computes/reconciles a per-context
   home dir under `~/.config/ctx/homes/<context-name>/`, symlinking shared
   Copilot CLI files/dirs (`settings.json`, `config.json`, `mcp-config.json`,
   `session-store.db*`, `session-state/`, `installed-plugins/`, `logs/`)
   back to the real `~/.copilot`, and populating `skills/` with symlinks to
   each resolved dir's `.github/skills/*` subfolders. `COPILOT_HOME` is
   exported to point at it. See `_ctx_setup_copilot_home` (ctx.sh) /
   `Set-CtxCopilotHome` (ctx.ps1). Runs a self-healing reconciliation step
   on every activation (see the "3.4a hazard" note below) — this replaced
   the old, confirmed-broken `skillDirectories`-in-`settings.local.json`
   approach (issue #1). `_ctx_update_skill_directories` /
   `Update-CtxSkillDirectories` are no longer called from the load path;
   the functions are kept only for the legacy-cleanup path in
   `ctx clear --all` for one release.

2. **VS Code workspace** — creates/updates `<folder-name>.code-workspace`
   next to the `.ctx` file with `root: <folder-name>` and `ctx: <name>`
   folders. User-added folders (names not starting with `root: ` or
   `ctx: `) are preserved. `ctx.sh` requires `python3`.

Generated workspace files are intentionally **not cleaned on `ctx clear`**
— only `ctx clear --all` removes them (and the current context's
`COPILOT_HOME` home dir).

### ⚠️ `rename()`-through-symlink hazard (plan section 3.4a)

Copilot CLI writes files like `settings.json` via write-tmp + `rename()`,
which **replaces a symlink at that path with a plain file** rather than
writing through it (confirmed empirically against Copilot CLI 1.0.80 — see
`docs/empirical-symlink-hazard.md`). The reconciliation step in
`_ctx_setup_copilot_home` / `Set-CtxCopilotHome` runs on every activation
and self-heals this: if a shared file/dir is no longer a symlink, its
content is copied onto the real `~/.copilot/<file>` first, then the plain
file is deleted and the symlink recreated. **Do not remove this check when
touching the reconciliation loop** — a version without it silently loses
writes. Known residual limitation: concurrent contexts in two shells can
still race (last reconciliation wins, not a merge) — documented in the
README, not solved.

### Environment variables

| Variable | Set by | Purpose |
|---|---|---|
| `AI_CONTEXT` | `ctx` | Human-readable label, `profile+shared1+shared2` |
| `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` | `ctx` | Comma-separated paths passed to Copilot CLI |
| `COPILOT_HOME` | `ctx` | Per-context Copilot CLI home dir for skill isolation (unset when no context is active) |
| `AI_CONFIG_ROOT` | User | Root of the profiles/shared tree (default: `$HOME/work/ai-config`) |
| `CTX_AUTO_LOAD` | User | Set to `0` to disable `.ctx` auto-loading |
| `CTX_HOMES_ROOT` | User (mainly tests) | Overrides `~/.config/ctx/homes` for `COPILOT_HOME` dirs |
| `CTX_COPILOT_DIR` | User (mainly tests) | Overrides `~/.copilot` as the shared-file symlink target |

## Conventions

### Parity between `ctx.sh` and `ctx.ps1`

Every feature must exist in **both** implementations with identical
behavior. When changing one, always change the other. Key differences are
intentional and unavoidable:

- `ctx.sh` uses `python3` (or `python`) for JSON manipulation;
  `ctx.ps1` uses native PowerShell cmdlets.
- `ctx.sh` exports env vars with `export`; `ctx.ps1` sets `$env:`.
- `ctx.sh` uses `_ctx_*` internal function names; `ctx.ps1` uses
  `Verb-CtxNoun` (approved PowerShell verbs).
- The auto-load hook in `ctx.sh` uses `chpwd` (zsh) / `PROMPT_COMMAND`
  (bash); in `ctx.ps1` it wraps the existing `prompt` function.

### Error handling

- On invalid input (unknown profile, missing directory, bad `.ctx` line),
  print a clear error to stderr and **leave the previously active context
  untouched** — never export a partial state.
- When an unknown profile/shared is requested, list what is available.

### Line endings

Enforced by `.gitattributes`:
- `*.sh` → LF
- `*.ps1` → CRLF

### `.gitignore` / generated files

Add to `.gitignore` in any project that uses `.ctx`:
```
# legacy — ctx no longer writes this file (COPILOT_HOME isolation, issue #1);
# kept as a guard for repos on an older ctx version
.github/copilot/settings.local.json
*.code-workspace
.vscode/
```
`COPILOT_HOME` per-context cache dirs live under `~/.config/ctx/homes/`
(outside any project repo) by default, so no additional `.gitignore` entry
is needed for them unless `CTX_HOMES_ROOT` is pointed inside a repo.

## `examples/` layout

```
examples/
  ai-profiles/
    review/          # sample profile: instructions + skill
    test/            # sample profile: instructions + skill
  copilot-cli-dotctx-review/    # demo project with a single-entry .ctx
  copilot-cli-dotctx-test-review/  # demo project with a two-entry .ctx
```

Each profile directory follows the Copilot CLI custom-instructions layout:
```
<profile>/
  .github/
    instructions/   # *.instructions.md files
    skills/
      <skill-name>/
        SKILL.md    # skill manifest
```
