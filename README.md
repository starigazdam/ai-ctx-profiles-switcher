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
ctx clear --all                 # also delete generated *.code-workspace
ctx --help                      # usage help
```

Example output after `ctx review dotnet security`:

```
[AI Context]

Profile : review
Shared  : dotnet, security

AI_CONTEXT=review+dotnet+security

COPILOT_HOME=<unset>

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
stored in those directories.

#### What does NOT work

> **There is no per-folder skill discovery mechanism in Copilot CLI.**

All of the following approaches were investigated and do not work for Copilot
CLI skill discovery from `.ctx` context directories:

- **`skillDirectories` in `settings.local.json`** — silently ignored.
  `skillDirectories` is a user-level-only setting. The
  `.github/copilot/settings.local.json` file uses the restricted repo-scope
  schema, which does not include `skillDirectories`. Values written there are
  discarded. The only location where it is honoured is `~/.copilot/settings.json`.

- **`enabledPlugins` in `settings.local.json`** — does not override the
  user-level `~/.copilot/settings.json`. A plugin disabled globally cannot be
  re-enabled per-folder via `settings.local.json`.

- **VS Code workspace file** — the `.code-workspace` file `ctx` generates adds
  context directories as VS Code workspace roots. This causes the **VS Code
  Copilot UI** to discover skills from those folders, but it has no effect on
  **Copilot CLI**. Starting Copilot CLI from VS Code's integrated terminal does
  not inherit workspace-root skill discovery.

#### Working alternatives for Copilot CLI

**Option 1 — Personal skills (symlinks, always-on):**

Symlink each skill directory into `~/.copilot/skills/`. Personal skills are
always loaded in every CLI session regardless of project.

```sh
# bash/zsh
for d in /path/to/context/.github/skills/*/; do
  ln -s "$d" ~/.copilot/skills/"$(basename "$d")"
done
```

```powershell
# PowerShell
Get-ChildItem /path/to/context/.github/skills -Directory | ForEach-Object {
    New-Item -ItemType SymbolicLink -Path "$HOME\.copilot\skills\$($_.Name)" -Target $_.FullName
}
```

**Option 2 — Global `skillDirectories` in `~/.copilot/settings.json`:**

Add the skills folder path to `skillDirectories` in your user settings. This
is global (not per-folder) but requires no symlinks:

```json
{
  "skillDirectories": [
    "/path/to/context/.github/skills"
  ]
}
```

Use Option 1 or 2 depending on whether the skills apply to a single project or
all your work. Neither provides automatic per-folder switching — that is a
current limitation of Copilot CLI's skill discovery model.

> **Option 1 is only appropriate if the skills are genuinely global** (useful
> in every project). Using symlinks to expose project-specific skills as
> personal skills pollutes all other CLI sessions — if you work across multiple
> projects with distinct skill sets, they will all bleed into each other.
> There is currently no supported mechanism for per-folder, session-isolated
> skill discovery in Copilot CLI.

#### Planned: per-folder skill isolation via `COPILOT_HOME`

A future enhancement to `ctx` will use the `COPILOT_HOME` environment variable
— which Copilot CLI respects as a full replacement for `~/.copilot` — to
provide genuine per-folder, session-isolated skill discovery without any
bleed between projects.

The approach: on `.ctx` load, `ctx` sets `COPILOT_HOME` to a project-specific
directory (e.g. `~/.config/ctx/homes/<context-name>/`) that contains only
that project's skill symlinks. Global config (authentication, settings, MCP
servers, session history) is preserved by symlinking the shared files back to
`~/.copilot`. On `ctx clear`, `COPILOT_HOME` is unset and the CLI returns to
the global config with no project skills visible.

See [GitHub issue #1](https://github.com/starigazdam/ai-ctx-profiles-switcher/issues/1)
for the implementation plan.

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
