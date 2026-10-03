# ctx — Portable Context Switcher for GitHub Copilot CLI

`ctx` composes AI agent configuration directories (profiles)
stored in a directory tree such as:

```
~/work/ai-config/
└── profiles/
    ├── review/
    ├── architecture/
    ├── incident/
    ├── coding/
    ├── dotnet/
    ├── azure/
    ├── terraform/
    └── security/
```

into the `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` environment variable for the
current shell session, and exposes the active selection as `AI_CTX_PROFILES`
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


## Breaking migration guide

Issue #4 intentionally removes the legacy context and shared-directory model.
Runtime migration is not performed; update your shell configuration and files
manually before sourcing the new implementation.

1. Move every reusable directory from `shared/` into `profiles/`. If a name
   exists in both old directories, stop and resolve the conflict manually;
   `ctx` never chooses a winner.
2. Replace environment variables in shell startup and prompt integrations:

   ```sh
   export AI_CTX_PROFILES_CONFIG_ROOT="$HOME/work/ai-config"
   export AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT="$HOME/.config/ctx/homes"
   ```

3. Replace `AI_CONTEXT` references with `AI_CTX_PROFILES`.
4. Change invocations such as `ctx review security` so every argument is a
   directory under `profiles/`; `.ctx` files may use `label:@profile` or a
   direct path. Existing `home:` directives remain supported.

The legacy variables and `shared/` directories are deliberately not read,
aliased, or synchronized by the runtime.

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

By default `ctx` looks for profiles under `$HOME/work/ai-config`
(`$HOME\work\ai-config` on Windows). Override with:

```sh
export AI_CTX_PROFILES_CONFIG_ROOT="/path/to/ai-config"       # bash/zsh
```
```powershell
$env:AI_CTX_PROFILES_CONFIG_ROOT = "C:\path\to\ai-config"      # PowerShell
```

## Usage

```sh
ctx review                     # activate the "review" profile
ctx coding azure                # "coding" profile + "azure" profile
ctx review dotnet security      # profile + multiple profiles
ctx current                   # show the active profile/profiles/env vars
ctx check                     # read-only audit against the nearest .ctx file
ctx skills                    # read-only potential-Copilot-skill discovery inventory
ctx clear                     # unset AI_CTX_PROFILES / COPILOT_CUSTOM_INSTRUCTIONS_DIRS / COPILOT_HOME
ctx clear --all                 # remove the current context home and generated artifacts
ctx load /path/to/.ctx          # explicitly load any .ctx file (bypasses noautoload)
ctx --help                      # usage help
```

Example output after `ctx review dotnet security`:

```
[AI Context]

Profile : review
Profiles: dotnet, security

AI_CTX_PROFILES=review+dotnet+security
Mode: A — synthetic-home

COPILOT_HOME=/home/user/.config/ctx/homes/review+dotnet+security

COPILOT_CUSTOM_INSTRUCTIONS_DIRS=
/home/user/work/ai-config/profiles/review
/home/user/work/ai-config/profiles/dotnet
/home/user/work/ai-config/profiles/security
```

Unknown profiles produce a clear error listing what is
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

### Checking activation drift

`ctx check` reads the nearest `.ctx` file and reports deterministic `CHECK PASS`,
`CHECK FAIL`, and `CHECK SKIP` lines for the shell environment, expected
`COPILOT_HOME` links and skills, Copilot's optional JSON skill listing, and an
adjacent workspace file. It exits 0 only when all applicable checks pass (a
missing `.ctx` is a successful no-op) and non-zero when drift is found. The
command is strictly read-only: it never repairs, writes, deletes, or unsets.
Environment checks describe only the shell in which `ctx check` runs; invoking
it from another shell cannot validate that shell's activation state.

## Tab completion

Completion is registered automatically when `ctx.sh` / `ctx.ps1` is sourced:

- First argument completes: `current`, `clear`, and profile directory names
- Subsequent arguments complete: profile directory names

```sh
ctx <TAB>            # current  clear  review  architecture  incident  coding
ctx review <TAB>      # profile directory names
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
dotnet:/home/user/work/ai-config/profiles/dotnet
security:./local-instructions
```

- Relative paths resolve against the directory containing the `.ctx` file
  (not your current working directory).
- Unlike `ctx <profile> [profile...]`, these names are **not** looked up
  under `AI_CTX_PROFILES_CONFIG_ROOT/profiles` — the path on each line is used
  directly, so you can point at any folder (including project-local
  instructions that live outside your `ai-config` repo).
- Every path is validated to exist; an invalid `.ctx` file leaves the
  previously active context untouched and prints a clear error.
- An optional `home:<path>` line is a reserved directive, not a
  profile entry: it overrides where this `.ctx` file's
  synthetic `COPILOT_HOME` is created (see [How it
  works](#how-it-works) below) instead of the centralized default. See
  [Choosing a custom COPILOT_HOME location](#choosing-a-custom-copilot_home-location).

When your shell prompt renders after a `cd` / `Set-Location` into that
directory (or any descendant of it), `AI_CTX_PROFILES` (the names joined by `+`)
and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` (the paths joined by `,`) are set,
overwriting any previous value. Leaving the directory tree (into a location
with no `.ctx` file anywhere in its ancestry) automatically clears the
context.

### Skill discovery

Setting `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` makes Copilot CLI load custom
instructions from your `.ctx` entries, but it does **not** make it discover
[agent skills](https://docs.github.com/en/copilot/concepts/agents/about-agent-skills)
stored in those directories on its own. Mode A projects the selected profiles'
`.github/skills` directories into the synthetic `<COPILOT_HOME>/skills` tree so
those skills are what Copilot CLI — which respects `COPILOT_HOME` as a full
replacement for `~/.copilot` — sees under this context. That projection is not
a complete skill-discovery or security sandbox: other built-in or configured
discovery locations (personal `~/.agents/skills`, repository `.github/skills` /
`.claude/skills`, `COPILOT_SKILLS_DIRS`, or configured `skillDirectories`) may
still be discovered by Copilot and are not blocked. Modes B/C instead export
`COPILOT_SKILLS_DIRS` (see [Integration modes](#integration-modes)).

#### Inspecting potential skill discovery with `ctx skills`

`ctx skills` is a strictly read-only, filesystem/configuration-based inventory
of the skill directories Copilot *might* discover in the current shell and
project. It never claims a skill is loaded or invoked — discovering a
directory is not the same as Copilot loading it — and it never modifies
settings, files, or the environment, and it never invokes the Copilot CLI
(no probe is performed). Each candidate is reported with its normalized path,
a single classification, and all of its origins:

- **`ctx-profile`** — `.github/skills` of the active context/profile entries
  (attributable only while the session activation record matches; otherwise
  attribution is reported as unknown and ctx-owned paths are not guessed).
- **`expected-home`** — the expected `<COPILOT_HOME>/skills` directory when
  `COPILOT_HOME` is set.
- **`external`** — everything else: personal `~/.copilot/skills` and
  `~/.agents/skills`, repository `.github/skills` / `.agents/skills` /
  `.claude/skills` in the current directory and ancestors, `COPILOT_SKILLS_DIRS`
  entries, configured `skillDirectories` in relevant Copilot settings files,
  and detectable `skills` / `.github/skills` directories under installed
  Copilot plugins.

A path found through several sources is reported once, classified by
precedence `ctx-profile > expected-home > external`, while all origins are
listed. Configured-but-missing or inaccessible paths are reported cleanly
without failing. The inventory explicitly discloses what a filesystem/config
diagnostic cannot observe (notably another Copilot process's command-line
arguments and plugin-internal skill locations beyond detectable
`skills`/`.github/skills` subdirectories).

### Integration modes

`ctx` supports three Copilot integration modes, selected by the exact,
case-sensitive `AI_CTX_PROFILES_COPILOT_MODE` environment variable. There is
no CLI flag and no `.ctx` mode line. The selector is read once per actual
activation (manual `ctx <profile>...`, `ctx load`, or a real `.ctx`
auto-load); an invalid non-empty value errors out before any state change.
Unset or empty means Mode A — today's behavior. The selector values are
unchanged; `ctx current` and `ctx check` report the active mode using the
consistent letter/name labels `A — synthetic-home`, `B — global-user`, and
`C — ephemeral-clean`:

| Selector | Mode | `COPILOT_HOME` |
|----------|------|----------------|
| unset / empty | **A — synthetic-home** | synthetic per-context home at `~/.config/ctx/homes/<context>/` |
| `synthetic-home` | **A — synthetic-home** | same as unset |
| `global-user` | **B — global-user** | never touched; left exactly as-is |
| `ephemeral-clean` | **C — ephemeral-clean** | fresh, unique, empty temp dir per activation |

```sh
export AI_CTX_PROFILES_COPILOT_MODE=global-user        # Mode B
export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean    # Mode C
unset AI_CTX_PROFILES_COPILOT_MODE                     # back to Mode A
```
```powershell
$env:AI_CTX_PROFILES_COPILOT_MODE = "global-user"        # Mode B
$env:AI_CTX_PROFILES_COPILOT_MODE = "ephemeral-clean"    # Mode C
Remove-Item Env:AI_CTX_PROFILES_COPILOT_MODE             # back to Mode A
```

Existing behavior with the selector unset stays Mode A; setting the selector
to `global-user` or `ephemeral-clean` chooses Mode B or C instead. The
selector stays in the shell for this and later activations:

```sh
# Before: no selector; unchanged synthetic-home default
unset AI_CTX_PROFILES_COPILOT_MODE
ctx review

# After: opt into global-user for this and later activations
export AI_CTX_PROFILES_COPILOT_MODE=global-user
ctx review
```

`COPILOT_CUSTOM_INSTRUCTIONS_DIRS` keeps its existing resolved-directory
order/replacement semantics in every mode. Copilot defines no general
precedence order among merged instruction sources; `ctx` does not claim to
guarantee one.

#### Mode A — synthetic-home (default)

The existing default: `ctx` builds a synthetic per-context `COPILOT_HOME` at
`~/.config/ctx/homes/<context>/`, symlinks the shared files/directories back
to the real Copilot home so auth, settings, MCP servers, and session history
keep working identically across contexts, and populates the per-context
`skills/` tree from each resolved entry's `.github/skills`. Known risks remain;
this feature does not fix them:

- Copilot's atomic temp-file+rename writes can replace a symlinked file
  (empirically confirmed for `settings.json`), so that context can diverge
  from the real shared file until the next activation's reconciliation
  repairs it. See `docs/empirical-symlink-hazard.md`.
- Concurrent contexts are last-reconciliation-wins.
- **Local TOCTOU gap:** Mode A path checks, including rechecks before creating
  the synthetic home and before `ctx clear --all` recursively deletes it, are
  preflight validation only—not race protection. A different local user who
  can modify an ancestor directory could replace a path component with a
  symlink/junction after validation and redirect the later creation or
  deletion. This is a conditional local risk, not a remote attack; same-user
  and administrator attackers are out of scope. Until this gap is resolved,
  avoid Mode A when its home path (including a `.ctx` `home:` override) is
  beneath an ancestor writable by an untrusted user. Modes B/C avoid this
  specific Mode A create/delete path but are not equivalent replacements: B
  leaves `COPILOT_HOME` untouched; C uses a unique temporary home and retains
  it after clear, and is not a security sandbox.

#### Mode B — global-user

`ctx` never sets, unsets, deletes, or builds a synthetic `COPILOT_HOME`; any
current value is left exactly as-is. If you want Copilot's real default, you
must clear/unset an old pointer yourself:

```sh
unset COPILOT_HOME            # bash/zsh
```
```powershell
Remove-Item Env:COPILOT_HOME  # PowerShell
```

After each successful Mode B activation (manual `ctx <profile>...`, explicit
`ctx load`, or a real `.ctx` auto-load), if `COPILOT_HOME` is present in the
environment (including when it is empty), `ctx` prints a warning on stderr
naming the preserved value — the value itself is never changed:

```
ctx: warning: global-user mode preserves the existing COPILOT_HOME: "/path/to/home". This may point to a synthetic home from a previous ctx activation.
```

The warning is informational only: Mode B reads `COPILOT_HOME` to report and
warn about it, but never modifies it. No warning is emitted when the variable
is absent, in Modes A/C, on a failed activation, or from read-only commands
such as `ctx current` / `ctx check`.

Mode B sets/replaces `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` and
`COPILOT_SKILLS_DIRS` from the active resolved directories.
`COPILOT_SKILLS_DIRS` lists existing `<entry>/.github/skills` paths only,
comma-joined in stable order; it is unset when none exist, and it is additive
to Copilot's built-in skill locations, not an isolation mechanism.

#### Mode C — ephemeral-clean

Each activation creates a new, empty, unique temp `COPILOT_HOME`; no
symlinks/copies to or from real `~/.copilot`, no reconciliation. Copilot may
write auth/session/cache data there. `ctx clear` and `ctx clear --all` unset
the env pointer but never delete the directory or its contents; `ctx` prints
the retained path and tells users/workflows to move any needed data out and
remove it manually. It consumes disk until removed — there is no
auto-sweeper. Mode C is storage separation only, not a security or
credential sandbox; `COPILOT_SKILLS_DIRS` is additive, not isolation.

Important limitations of Modes B/C:

- Mode B never restores or clears an old `COPILOT_HOME`; switching between
  modes does not move or clean the pointer.
- Mode C's temp directory accumulates until you remove it manually.
- Neither mode reconciles shared Copilot config, so Mode A's symlink
  self-repair does not apply.

#### How it works

This describes Mode A (synthetic-home), the default. Every time a context is
activated (`ctx <profile> [profile...]` or `.ctx`
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
  resolved directory's `.github/skills/*` subfolders, so this context projects
  exactly the selected profiles' skills. This controls the synthetic
  `COPILOT_HOME` view only — it does not hide or block other built-in or
  configured skill locations Copilot may discover, and it is not a security
  sandbox.
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
`~/.config/ctx/homes/<context-name>/` (or `$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT` if set). If
you'd rather keep it colocated with a specific project — easier to spot,
inspect, or `.gitignore` — add a `home:<path>` line to that project's
`.ctx` file:

```
home: .copilot-ctx
review:/home/user/work/ai-config/profiles/review
```

- `home:` is a reserved directive name — you cannot also define a
  profile entry called `home`.
- `home:` is **Mode A only**: under `global-user` or `ephemeral-clean` a
  `.ctx` file containing `home:` is rejected before any state change — it is
  never silently ignored or reinterpreted. In Mode A the rules below apply.
- Only one `home:` line is allowed per `.ctx` file; a duplicate is an
  error, same as any other invalid `.ctx` line.
- The path resolves the same way as any other `.ctx` entry: relative to
  the directory containing the `.ctx` file unless it's absolute. It does
  **not** need to already exist — `ctx` creates it on demand, exactly like
  the centralized default.
- To constrain deletion targets, the resolved `home:` path must be a non-root
  descendant of the user's home directory or `$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT`. Paths that
  are empty, escape with `..`, point outside those roots, or contain an
  existing symlink/junction component are rejected during preflight
  validation. See [Operational notes](#operational-notes) for its TOCTOU
  limitation. This intentionally means a project tree outside those roots
  cannot be selected as a custom home; keep the project under `$HOME` if
  colocating is desired.
- `ctx clear --all` deletes only the exact `COPILOT_HOME` selected for the
  active context, after repeating the same validation. It refuses empty,
  root, unselected, or symlink/junction targets. These checks are preflight,
  not race protection; see [Operational notes](#operational-notes).
- Add the custom directory to that project's `.gitignore` (e.g.
  `.copilot-ctx/`) so the synthetic home never gets committed.
- This only applies to `.ctx`-file activation. Manually invoking
  `ctx <profile> [profile...]` (no `.ctx` file involved) always uses the
  centralized default — there's no `.ctx` file to read a `home:` directive
  from.
- `ctx clear --all` looks up whichever location was actually used (custom
  or centralized) for the context it's clearing, so cleanup works
  correctly either way.

#### Operational notes

The reconciliation and hazards below apply to Mode A (synthetic-home) only:
Modes B/C never build a synthetic `COPILOT_HOME`, so there is no shared-link
tree to repair (see [Integration modes](#integration-modes)).

`ctx` reconciles the context home on every Mode A activation and repairs
managed links that were replaced by the CLI, protecting shared configuration
from the CLI's file-replacement behavior. The two reconciliation hazards
below, as well as the local TOCTOU gap described in the Mode A summary above,
are **not** fixed by the integration-modes feature:

- Copilot's atomic temp-file+rename writes can replace a symlinked file
  (empirically confirmed for `settings.json`); that context can diverge from
  the real shared file until the next activation's reconciliation repairs it.
- Concurrent Copilot CLI sessions under different active contexts are
  last-reconciliation-wins when both write the same shared configuration.

The context home is a cache and is not deleted by ordinary `ctx clear`;
`ctx clear --all` removes the current cache and generated project artifacts.
See the [design history](docs/design-history-copilot-home.md) and
[empirical hazard report](docs/empirical-symlink-hazard.md) for implementation
rationale and historical investigation.

In Modes B/C, `COPILOT_SKILLS_DIRS` lists only the existing
`<entry>/.github/skills` directories of the active resolved entries,
comma-joined in stable order, and is unset when none exist; it is additive to
Copilot's built-in skill locations, not an isolation mechanism. `ctx` only
unsets a `COPILOT_SKILLS_DIRS` value it set earlier in the session — a
user-set value is never cleared.

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
  "generatedBy": "ctx",
  "folders": [
    { "path": ".", "name": "root: my-service" },
    { "path": "/home/user/work/ai-config/profiles/review", "name": "ctx: review" },
    { "path": "/home/user/work/ai-config/profiles/dotnet", "name": "ctx: dotnet" },
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
- A workspace file created by `ctx` carries the machine-readable
  `generatedBy: "ctx"` ownership marker. Existing workspace files are never
  marked retroactively.
- Nothing is removed from the workspace file when the context is cleared —
  like `settings.local.json`, it's project-local and will already be up to
  date the next time you return. `ctx clear --all` removes the workspace only
  when that ownership marker is present; unmarked or invalid files are
  preserved with a warning.

Disable auto-loading for the session with:

```sh
export CTX_AUTO_LOAD=0          # bash/zsh
```
```powershell
$env:CTX_AUTO_LOAD = "0"        # PowerShell
```

### Opting a single `.ctx` file out of auto-loading

Add a bare `noautoload` line (case-insensitive) anywhere in the file:

```
noautoload
review:/home/user/work/ai-config/profiles/review
dotnet:/home/user/work/ai-config/profiles/dotnet
```

The directory-change hook silently skips this file — useful for shared
repos where each engineer uses a different context, or when you want to
gate activation on an explicit command. The file is otherwise fully valid
and can be loaded on demand with:

```sh
ctx load /path/to/project/.ctx   # bash/zsh — absolute or relative path
```
```powershell
ctx load C:\path\to\project\.ctx  # PowerShell
```

`ctx load` bypasses `noautoload` entirely: the flag only suppresses the
automatic hook. After a manual load, `ctx clear --all` works as normal. If
`noautoload` is added to a `.ctx` file *after* it was already auto-loaded,
the hook clears the context and forgets the directory the next time your
prompt renders in that tree.

## Showing the active context in your prompt (Oh My Posh)

If you use [Oh My Posh](https://ohmyposh.dev/), add a conditional `text`
segment to your theme so the active `AI_CTX_PROFILES` shows up in the prompt
(hidden automatically when unset):

```json
{
  "type": "text",
  "style": "powerline",
  "powerline_symbol": "\ue0b0",
  "foreground": "#ffffff",
  "background": "#5f005f",
  "template": "{{ if .Env.AI_CTX_PROFILES }}{{ $parts := splitList \"+\" .Env.AI_CTX_PROFILES }} \uf544 {{ first $parts }}{{ if gt (len $parts) 1 }} (+{{ sub (len $parts) 1 }}){{ end }} {{ end }}"
}
```

Place it after your other segments in the relevant `blocks[].segments` array.
When `AI_CTX_PROFILES` is set (e.g. `review+dotnet+security`), the prompt shows
only the first context name plus a `(+2)` suffix for the rest (e.g.
`review (+2)`) — the full detail is available via `ctx current`. When
`AI_CTX_PROFILES` is unset, the segment disappears entirely.

## Notes

- `ctx.sh` targets bash and zsh; it uses POSIX-compatible constructs (`[ ]`,
  `local`, `printf`) and passes `shellcheck` with default rules (two
  intentional `shellcheck disable` comments are documented inline for
  word-splitting that is required by design).
- `ctx.ps1` passes `PSScriptAnalyzer` with default rules, aside from
  `PSAvoidUsingWriteHost`, which is intentional: `ctx` is an interactive
  status-display command, not a value-returning function meant for pipeline
  composition.
- Both implementations validate that the AI config root and every profile
  directory exist before exporting anything, and leave any
  previously active context untouched if validation fails. A `COPILOT_HOME`
  setup failure during Mode A (synthetic-home) activation — home creation or
  shared-link reconciliation — leaves the activation environment and
  session-record state and (for `.ctx` auto-load) the `.code-workspace` file
  unchanged, and the failure status is returned through the currently
  documented Bash/PowerShell paths: a non-zero exit status from `ctx.sh` on
  any failed activation (manual `ctx <profile>...`, explicit `ctx load`, or
  `.ctx` auto-load), and a Boolean from `ctx.ps1` — `$false` on a failed
  Mode A manual activation, failed explicit `ctx load`, or failed `.ctx`
  auto-load; `$true` only on a successful Mode A manual activation and a
  successful Mode A explicit `ctx load`. Successful Modes B/C manual
  activation and `ctx load` keep their old behavior of emitting no Boolean
  pipeline value, and the `ctx.ps1` startup/prompt hooks suppress the
  auto-load's return value so no stray `True`/`False` text appears at the
  shell prompt. This atomicity covers the activation environment and session
  record, not the bytes of shared `~/.copilot` files: `_ctx_reconcile_symlink`
  / `Resolve-CtxLink` may intentionally transfer an already-written regular
  file/directory from the synthetic home into the shared target before a
  later reconciliation step fails. Making shared-target data atomic across a
  failed activation is tracked in
  [issue #51](https://github.com/starigazdam/ai-ctx-profiles-switcher/issues/51).
- `COPILOT_HOME` is managed automatically by `ctx` whenever a context is
  active (see [Skill discovery](#skill-discovery)); it is exported/unset
  alongside `AI_CTX_PROFILES` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, and shown
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

`.github/workflows/test.yml` runs on every push/PR that touches `ctx.sh`,
`ctx.ps1`, or `tests/**`, as two jobs: both suites on `ubuntu-latest`
(`pwsh` ships preinstalled on that image, so it exercises real `ctx.ps1`
logic there too), plus the Pester suite again on native `windows-latest`.
Whether the Windows-hosted runner's account privileges actually force the
Windows-only symlink → junction → hardlink fallback ladder down to the
junction/hardlink rungs, or symlinks just succeed there too, isn't
verified — treat that ladder's lower rungs as still manual-verification-only
until someone checks.

## Change workflow (OpenSpec)

This repo uses [OpenSpec](https://openspec.dev) as an optional, repo-local workflow for specifying and validating non-trivial changes before implementation. It is developer tooling only — not a runtime dependency of `ctx`.

Specs and change proposals live under `openspec/`. GitHub Copilot CLI users get the workflow via skills installed under `.github/skills/openspec-*/` (invoke with `/openspec-propose`, `/openspec-apply-change`, etc.); IDE extensions (VS Code, JetBrains) use the command prompts under `.github/prompts/opsx-*.prompt.md` instead.

To propose a change: run the `openspec-propose` skill (or `/openspec-propose` in Copilot CLI) with your idea. To apply an in-progress change: `openspec-apply-change`. To validate the repo's specs and changes: `openspec validate --all`.

- [Setup guide](https://openspec.dev/docs/setup)
- [Supported tools](https://openspec.dev/docs/supported-tools)
- [CLI reference](https://openspec.dev/docs/cli)
