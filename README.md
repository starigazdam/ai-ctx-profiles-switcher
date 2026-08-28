# ctx — Portable Context Switcher for GitHub Copilot CLI

`ctx` composes AI agent configuration directories (profiles + shared contexts)
stored in a directory tree such as:

```
~/work/ai-config/
├── profiles/
│   ├── review/
│   ├── architecture/
│   ├── incident/
│   └── coding/
└── shared/
    ├── dotnet/
    ├── azure/
    ├── terraform/
    └── security/
```

into the `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` environment variable for the
current shell session, and exposes the active selection as `AI_CONTEXT`
(e.g. `review+dotnet+security`).

Available for **bash**, **zsh**, and **PowerShell** (Windows PowerShell 5.1+
and PowerShell 7+ / pwsh).

## Requirements

`ctx` is built specifically for and heavily oriented around
[**GitHub Copilot CLI**](https://docs.github.com/copilot/how-tos/copilot-cli):
custom-instructions loading (`COPILOT_CUSTOM_INSTRUCTIONS_DIRS`) and
per-folder skill discovery (`COPILOT_HOME`, see [Skill discovery](#skill-discovery)
below) both depend on behavior specific to that CLI, not on GitHub Copilot
in general (e.g. the VS Code extension) or other AI coding agents.

- **GitHub Copilot CLI** must be installed and authenticated —
  `npm install -g @github/copilot`, then `copilot login`. See the
  [official docs](https://docs.github.com/copilot/how-tos/copilot-cli) for
  details.
- All `COPILOT_HOME`-dependent behavior in this README (isolation,
  reconciliation, the empirically-found symlink hazard, etc.) was
  developed against and tested with **GitHub Copilot CLI 1.0.80**. Other
  versions likely work — the `COPILOT_HOME`/`COPILOT_CUSTOM_INSTRUCTIONS_DIRS`
  environment variables are documented, stable CLI behavior — but the
  specific hazards and workarounds described here (see
  [Skill discovery](#skill-discovery)) were only verified empirically
  against that version. If you hit different behavior on another version,
  please open an issue with your `copilot --version` output.

## Files

| File           | Purpose                                             |
|----------------|------------------------------------------------------|
| `ctx.sh`       | bash/zsh function, completions, `.ctx` auto-loading   |
| `ctx.ps1`      | PowerShell function, completions, `.ctx` auto-loading |
| `install.sh`   | Installs `ctx.sh` and wires up `.zshrc` / `.bashrc`   |
| `install.ps1`  | Installs `ctx.ps1` and wires up `$PROFILE`            |

## Installation

### zsh / bash

```sh
cd ctx
./install.sh
```

This copies `ctx.sh` to `~/.config/ctx/ctx.sh` and appends a sourcing line to
`~/.zshrc` and/or `~/.bashrc` (only if not already present — safe to re-run).

Restart your shell, or run:

```sh
source ~/.config/ctx/ctx.sh
```

### PowerShell

```powershell
cd ctx
.\install.ps1
```

This copies `ctx.ps1` to `~/.config/ctx/ctx.ps1` and appends a dot-source
line to your `$PROFILE` (only if not already present — safe to re-run).

Restart PowerShell, or run:

```powershell
. "$HOME\.config\ctx\ctx.ps1"
```

### Custom AI config root

By default `ctx` looks for `profiles/` and `shared/` under `$HOME/work/ai-config`
(`$HOME\work\ai-config` on Windows). Override with:

```sh
export AI_CONFIG_ROOT="/path/to/ai-config"       # bash/zsh
```
```powershell
$env:AI_CONFIG_ROOT = "C:\path\to\ai-config"      # PowerShell
```

## Usage

```sh
ctx review                     # activate the "review" profile
ctx coding azure                # "coding" profile + "azure" shared context
ctx review dotnet security      # profile + multiple shared contexts
ctx current                     # show the active profile/shared/env vars
ctx clear                       # unset AI_CONTEXT / COPILOT_CUSTOM_INSTRUCTIONS_DIRS
ctx clear --all                 # remove the current context home and generated artifacts
ctx --help                      # usage help
```

Example output after `ctx review dotnet security`:

```
[AI Context]

Profile : review
Shared  : dotnet, security

AI_CONTEXT=review+dotnet+security

COPILOT_HOME=/home/user/.config/ctx/homes/review+dotnet+security

COPILOT_CUSTOM_INSTRUCTIONS_DIRS=
/home/user/work/ai-config/profiles/review
/home/user/work/ai-config/shared/dotnet
/home/user/work/ai-config/shared/security
```

Unknown profiles/shared contexts produce a clear error listing what is
available:

```
$ ctx bogus
ctx: error: unknown profile "bogus" (looked in /home/user/work/ai-config/profiles)
ctx: available profiles:
  - architecture
  - coding
  - incident
  - review
```

## Tab completion

Completion is registered automatically when `ctx.sh` / `ctx.ps1` is sourced:

- First argument completes: `current`, `clear`, and profile directory names
- Subsequent arguments complete: shared directory names

```sh
ctx <TAB>            # current  clear  review  architecture  incident  coding
ctx review <TAB>      # dotnet  azure  terraform  security
```

## Auto-loading with `.ctx` files

Drop a `.ctx` file in any project directory. Each non-empty, non-comment line
maps an arbitrary context name to a custom-instructions directory:

```
<context-name>:<path-to-folder>
```

Example:

```
review:/home/user/work/ai-config/profiles/review
dotnet:/home/user/work/ai-config/shared/dotnet
security:./local-instructions
```

- Relative paths resolve against the directory containing the `.ctx` file
  (not your current working directory).
- Unlike `ctx <profile> [shared...]`, these names are **not** looked up
  under `AI_CONFIG_ROOT/profiles|shared` — the path on each line is used
  directly, so you can point at any folder (including project-local
  instructions that live outside your `ai-config` repo).
- Every path is validated to exist; an invalid `.ctx` file leaves the
  previously active context untouched and prints a clear error.
- An optional `home:<path>` line is a reserved directive, not a
  profile/shared-context entry: it overrides where this `.ctx` file's
  synthetic `COPILOT_HOME` is created (see [How it
  works](#how-it-works) below) instead of the centralized default. See
  [Choosing a custom COPILOT_HOME location](#choosing-a-custom-copilot_home-location).

When your shell prompt renders after a `cd` / `Set-Location` into that
directory (or any descendant of it), `AI_CONTEXT` (the names joined by `+`)
and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` (the paths joined by `,`) are set,
overwriting any previous value. Leaving the directory tree (into a location
with no `.ctx` file anywhere in its ancestry) automatically clears the
context.

### Skill discovery

Setting `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` makes Copilot CLI load custom
instructions from your `.ctx` entries, but it does **not** make it discover
[agent skills](https://docs.github.com/en/copilot/concepts/agents/about-agent-skills)
stored in those directories on its own. `ctx` solves this with genuine
per-folder, session-isolated skill discovery via the `COPILOT_HOME`
environment variable, which Copilot CLI respects as a full replacement for
`~/.copilot`.

#### How it works

Every time a context is activated (`ctx <profile> [shared...]` or `.ctx`
auto-load), `ctx` computes and reconciles a per-context home directory at
`~/.config/ctx/homes/<context-name>/` (e.g. `~/.config/ctx/homes/review+dotnet/`)
and exports `COPILOT_HOME` to point at it:

```
~/.config/ctx/homes/<context-name>/
  settings.json           -> symlink to ~/.copilot/settings.json
  config.json              -> symlink to ~/.copilot/config.json
  mcp-config.json           -> symlink to ~/.copilot/mcp-config.json
  session-store.db*         -> symlink to ~/.copilot/session-store.db*
  session-state/            -> symlink to ~/.copilot/session-state/
  installed-plugins/        -> symlink to ~/.copilot/installed-plugins/
  logs/                     -> symlink to ~/.copilot/logs/
  skills/
    <skill-name>/            -> symlink to the real skill dir (from resolved .ctx/profile entries)
```

- **Shared files/dirs** (`settings.json`, `config.json`, `mcp-config.json`,
  `session-store.db*`, `session-state/`, `installed-plugins/`, `logs/`) are
  symlinked back to the real `~/.copilot`, so authentication, model
  settings, MCP servers, and session history all keep working identically
  to today, shared across every context.
- **`skills/`** is context-local and populated only with symlinks to each
  resolved directory's `.github/skills/*` subfolders — every context sees
  exactly its own skills and nothing else. No bleed between projects.
- Reactivating a context (re-`cd`-ing into a `.ctx` dir, or re-running
  `ctx <profile>`) is idempotent: unchanged symlinks are left alone, stale
  skill symlinks (from a profile's skill set that has since changed) are
  removed, and incorrect/missing symlinks are (re)created.
- `ctx clear` unsets `COPILOT_HOME` for the session but leaves the home
  directory on disk as a reusable cache. `ctx clear --all` additionally
  removes the *current* context's home directory (not other cached
  contexts' homes).

#### Choosing a custom `COPILOT_HOME` location

By default every context's synthetic `COPILOT_HOME` lives centrally under
`~/.config/ctx/homes/<context-name>/` (or `$CTX_HOMES_ROOT` if set). If
you'd rather keep it colocated with a specific project — easier to spot,
inspect, or `.gitignore` — add a `home:<path>` line to that project's
`.ctx` file:

```
home: .copilot-ctx
review:/home/user/work/ai-config/profiles/review
```

- `home:` is a reserved directive name — you cannot also define a
  profile/shared-context entry called `home`.
- Only one `home:` line is allowed per `.ctx` file; a duplicate is an
  error, same as any other invalid `.ctx` line.
- The path resolves the same way as any other `.ctx` entry: relative to
  the directory containing the `.ctx` file unless it's absolute. It does
  **not** need to already exist — `ctx` creates it on demand, exactly like
  the centralized default.
- Add the custom directory to that project's `.gitignore` (e.g.
  `.copilot-ctx/`) so the synthetic home never gets committed.
- This only applies to `.ctx`-file activation. Manually invoking
  `ctx <profile> [shared...]` (no `.ctx` file involved) always uses the
  centralized default — there's no `.ctx` file to read a `home:` directive
  from.
- `ctx clear --all` looks up whichever location was actually used (custom
  or centralized) for the context it's clearing, so cleanup works
  correctly either way.

#### Operational notes

`ctx` reconciles the context home on every activation and repairs managed
links that were replaced by the CLI. This protects shared configuration from
the CLI's file-replacement behavior. The context home is a cache and is not
deleted by ordinary `ctx clear`; `ctx clear --all` removes the current cache
and generated project artifacts.

Avoid running concurrent Copilot CLI sessions under different active contexts
when both may write the same shared configuration: the last reconciliation
wins. See the [design history](docs/design-history-copilot-home.md) and
[empirical hazard report](docs/empirical-symlink-hazard.md) for implementation
rationale and historical investigation.

Older versions of `ctx` could create `.github/copilot/settings.local.json`.
Current versions no longer write it; remove an old leftover manually if it is
not needed.

### VS Code workspace

Whenever a `.ctx` file is loaded, `ctx` also creates (or updates) a
multi-root VS Code workspace file named `<folder-name>.code-workspace` next
to it — e.g. a `.ctx` file in `my-service/` produces
`my-service/my-service.code-workspace` — so the project and all of its
`.ctx` dependencies can be opened and browsed together in one VS Code
window:

- This folder is added as a workspace folder named `root: <folder-name>`.
- Each `.ctx` entry is added as a workspace folder named
  `ctx: <context-name>`, pointing at the resolved directory from that line.

Given the earlier example `.ctx` file in a project named `my-service`, the
generated `my-service.code-workspace` would contain:

```json
{
  "folders": [
    { "path": ".", "name": "root: my-service" },
    { "path": "/home/user/work/ai-config/profiles/review", "name": "ctx: review" },
    { "path": "/home/user/work/ai-config/shared/dotnet", "name": "ctx: dotnet" },
    { "path": "./local-instructions", "name": "ctx: security" }
  ],
  "settings": {}
}
```

- Any other folders already present in the workspace file (added by you, or
  by VS Code) are preserved as-is.
- Only folders previously generated by `ctx` (named `root: ...` or
  `ctx: ...`) are replaced on each load, so the file always reflects the
  current `.ctx` contents without losing manual additions.
- Other top-level keys already in the file (`settings`, `extensions`, ...)
  are preserved; requires `python3` (or `python`) to be on `PATH`.
- Nothing is removed from the workspace file when the context is cleared —
  like `settings.local.json`, it's project-local and will already be up to
  date the next time you return. Run `ctx clear --all` to delete it instead.

Disable auto-loading for the session with:

```sh
export CTX_AUTO_LOAD=0          # bash/zsh
```
```powershell
$env:CTX_AUTO_LOAD = "0"        # PowerShell
```

## Showing the active context in your prompt (Oh My Posh)

If you use [Oh My Posh](https://ohmyposh.dev/), add a conditional `text`
segment to your theme so the active `AI_CONTEXT` shows up in the prompt
(hidden automatically when unset):

```json
{
  "type": "text",
  "style": "powerline",
  "powerline_symbol": "\ue0b0",
  "foreground": "#ffffff",
  "background": "#5f005f",
  "template": "{{ if .Env.AI_CONTEXT }}{{ $parts := splitList \"+\" .Env.AI_CONTEXT }} \uf544 {{ first $parts }}{{ if gt (len $parts) 1 }} (+{{ sub (len $parts) 1 }}){{ end }} {{ end }}"
}
```

Place it after your other segments in the relevant `blocks[].segments` array.
When `AI_CONTEXT` is set (e.g. `review+dotnet+security`), the prompt shows
only the first context name plus a `(+2)` suffix for the rest (e.g.
`review (+2)`) — the full detail is available via `ctx current`. When
`AI_CONTEXT` is unset, the segment disappears entirely.

## Notes

- `ctx.sh` targets bash and zsh; it uses POSIX-compatible constructs (`[ ]`,
  `local`, `printf`) and passes `shellcheck` with default rules (two
  intentional `shellcheck disable` comments are documented inline for
  word-splitting that is required by design).
- `ctx.ps1` passes `PSScriptAnalyzer` with default rules, aside from
  `PSAvoidUsingWriteHost`, which is intentional: `ctx` is an interactive
  status-display command, not a value-returning function meant for pipeline
  composition.
- Both implementations validate that the AI config root, profile directory,
  and every shared directory exist before exporting anything, and leave any
  previously active context untouched if validation fails.
- `COPILOT_HOME` is managed automatically by `ctx` whenever a context is
  active (see [Skill discovery](#skill-discovery)); it is exported/unset
  alongside `AI_CONTEXT` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, and shown
  in `ctx current` output.

## Testing

Both implementations have an automated test suite that runs entirely
against isolated temp directories — nothing in the suites touches your real
`~/.copilot` or `~/.config/ctx`.

### bash/zsh (`ctx.sh`) — bats

```sh
npm install --no-save bats
./node_modules/.bin/bats tests/ctx.bats
```

### PowerShell (`ctx.ps1`) — Pester

Requires PowerShell 7+ (`pwsh`) and [Pester](https://pester.dev/) 5+:

```powershell
Install-Module Pester -Force -Scope CurrentUser -SkipPublisherCheck -MinimumVersion 5.0
Invoke-Pester tests/ctx.Tests.ps1
```

### CI

`.github/workflows/test.yml` runs both suites on every push/PR that touches
`ctx.sh`, `ctx.ps1`, or `tests/**`, on `ubuntu-latest` only (`pwsh` ships
preinstalled on that image, so it exercises real `ctx.ps1` logic — just
without the Windows-only symlink → junction → hardlink fallback ladder,
which stays manual-verification-only since `ubuntu-latest` doesn't hit
Windows-style symlink permission errors).
