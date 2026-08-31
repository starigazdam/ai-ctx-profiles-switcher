# Claude Code compatibility investigation

Issue: [#15](https://github.com/starigazdam/ai-ctx-profiles-switcher/issues/15)  
Retrieved: 2026-08-31  
Scope: Claude Code CLI only; not Claude Desktop, the Anthropic API, or IDE-specific product behavior.

## Recommendation

Choose **option 2: add a provider-neutral context model with adapters**, but do not implement it in this issue. Claude Code has a viable, documented integration surface, yet it is structurally different from Copilot CLI:

- project instructions and skills naturally map to checked-in `.claude/` files;
- user/global state is rooted at `~/.claude` (or `CLAUDE_CONFIG_DIR`), not `COPILOT_HOME`;
- hooks/settings are configuration, not merely instruction directories;
- Claude's global state includes credentials, sessions, plugins, and auto-memory, so copying or symlinking it would create security and concurrency hazards.

The first implementation should use a **project-local adapter**: materialize only owned instruction/skill artifacts and set `CLAUDE_CONFIG_DIR` only when an explicit isolated-state mode is requested. Do not symlink unknown Claude-managed files.

## Official mechanism matrix

| Mechanism | Bash | zsh | PowerShell 5.1 | PowerShell 7+ | Suitable ctx mapping |
|---|---:|---:|---:|---:|---|
| `CLAUDE.md`, `.claude/rules/` | Yes | Yes | Yes | Yes | profile-owned instructions |
| `.claude/skills/<name>/SKILL.md` | Yes | Yes | Yes | Yes | profile-owned skills |
| `.claude/settings.json` and `.local.json` | Yes | Yes | Yes | Yes | project activation policy; must be owned explicitly |
| `~/.claude/settings.json` | Yes | Yes | Yes | Yes | user defaults; do not rewrite during activation |
| `CLAUDE_CONFIG_DIR` | Yes | Yes | Yes | Yes | optional isolated Claude state boundary |
| hooks | Yes | Yes | Yes | Yes | lifecycle/check hooks, not a direct replacement for shell activation |
| plugins/MCP | Yes | Yes | Yes | Yes | future adapter input; no automatic copying |
| `--add-dir` | Yes | Yes | Yes | Yes | possible additional read-only instruction source; verify version semantics |

The platform cells mean the mechanism is documented as a CLI/configuration feature and can be selected from that shell. They do not assert identical quoting, filesystem permissions, junction behavior, or installation support across every Claude Code release.

## Version compatibility status

| Claude Code version | Evidence available in this investigation | Support decision |
|---|---|---|
| 2.1.234 (installed locally) | `claude --version` returned `2.1.234 (Claude Code)`; the offline PoC passed with a fake client, not the real client | Candidate baseline only; real feature smoke tests still required |
| Older versions | No version-pinned matrix was found in the retrieved official pages for every mechanism above | Not claimed supported |
| Newer versions | Documentation is current as retrieved on 2026-08-31, but behavior can change | Detect capabilities and test the exact release |

No PowerShell executable is installed in this Linux environment, so PowerShell 5.1/7+ behavior and Windows link/permission semantics remain unverified. The first implementation PR must add a Windows CI job or an explicitly documented manual matrix before claiming parity.

Sources: [Claude directory](https://code.claude.com/docs/en/claude-directory), [settings](https://code.claude.com/docs/en/settings), [skills](https://code.claude.com/docs/en/skills), [hooks](https://code.claude.com/docs/en/hooks), [memory](https://code.claude.com/docs/en/memory).

## Mapping to ctx concepts

| Current ctx concept | Claude Code equivalent | Assessment |
|---|---|---|
| profile instructions | profile-owned `CLAUDE.md`, `.claude/rules/`, or an adapter-generated project file | Direct enough, but generated files need ownership markers and cleanup rules. |
| additional profile instruction directories | symlinked profile-owned `.claude/rules/` or `--add-dir` | `.claude/rules/` symlinks are documented; `--add-dir` memory loading has additional opt-in semantics. |
| skills | `.claude/skills/<name>/SKILL.md` | Direct layout match in concept; Claude skill frontmatter and invocation semantics differ from Copilot. |
| context/session state | `CLAUDE_CONFIG_DIR`, `~/.claude/projects/`, sessions, plugins, and `~/.claude.json` | Not equivalent to instruction content; isolate only as a deliberate state policy. |
| `.ctx` auto-loading | shell hook that exports env vars before launching Claude Code, or a project-local generated adapter | Claude hooks are Claude lifecycle hooks, not a portable shell `chpwd` mechanism. Keep `.ctx` loading in ctx. |

## Proposed lifecycle and ownership

1. Parse and validate `.ctx` completely before changing the environment; preserve the existing failure-atomic contract.
2. Resolve profile paths and reject paths outside the permitted profile roots unless explicitly allowed.
3. For the default mode, expose profile instructions and skills through an owned project adapter (prefer symlinked `.claude/rules/` and `.claude/skills/` where the platform supports them). Mark every generated entry.
4. For isolated state, create a per-context `CLAUDE_CONFIG_DIR` under a user-owned cache root. Never place secrets in a repository. Treat `~/.claude.json`, credentials, transcripts, plugins, and auto-memory as private state.
5. On clear, remove only entries carrying ctx ownership metadata. `clear --all` may remove empty, fully-owned cache directories after path and symlink checks.
6. On any failure, remove only newly created temporary artifacts and leave the previous activation intact.

Do not use per-file symlinks for Claude-managed JSON/database/session files until a version-pinned experiment proves both read and write semantics. The official documentation describes locations and reload behavior, but does **not** establish atomic-write behavior for every managed file. This is an explicit evidence gap, not evidence of safety.

## Security and concurrency

- `CLAUDE_CONFIG_DIR` can redirect settings, session history, and plugins; redirecting it can accidentally duplicate or expose credentials if permissions are wrong. Create it with restrictive permissions and never copy authentication material by default.
- Generated project files are executable/configuration inputs. Do not accept arbitrary hook commands or MCP endpoints from untrusted `.ctx` entries without an explicit policy.
- Canonicalize paths before containment checks; reject traversal, unexpected symlink/junction targets, and deletion of a path that changed identity between validation and cleanup.
- Two shells activating different contexts must not share a writable state directory. Otherwise settings, sessions, plugins, and auto-memory can leak or race. Default recommendation is read-only profile instructions plus separate state, or no state isolation.
- Claude Code watches/reloads settings changes according to its documentation. This increases the risk of mutating settings used by another session while a session is running; activation should not rewrite the user settings file.

## Version detection and CI

Use `claude --version` when available and record the version in diagnostics. Feature-gate behavior by detected capability rather than assuming a latest release. CI must not authenticate: use a fake executable or a temporary sandbox to test path resolution, generated layout, cleanup ownership, and environment exports. A real Claude Code smoke test is optional and should run only when the binary is preinstalled; it must use a temporary `CLAUDE_CONFIG_DIR` and no real credentials.

The issue is an investigation, so this document does not prescribe a minimum supported version yet. The first implementation issue should choose a baseline after testing the exact features it uses (especially `CLAUDE_CONFIG_DIR`, project skills, hooks, and `--add-dir`).

## Migration and compatibility

Existing Copilot behavior remains unchanged. A future provider-neutral model should retain the current profile and `.ctx` syntax, then add provider-specific projections. Existing profiles can be projected to Claude by convention, but Copilot instruction files and Claude `CLAUDE.md`/skill frontmatter should not be silently treated as byte-for-byte interchangeable. Existing Claude user configuration must remain untouched; migration should be opt-in and reversible.

## Safe proof-of-concept results

The offline PoC in [`experiments/claude-code-compat/README.md`](../experiments/claude-code-compat/README.md) tests only temporary paths and a fake `claude` executable. It verifies that environment selection and project-local `.claude` artifacts are possible without login. It intentionally does not claim that Claude-managed files are safe to symlink; that requires a version-pinned write experiment.

## Follow-up issues if support is approved

1. Define provider-neutral profile projection and ownership metadata while preserving current syntax.
2. Add Claude adapter for project `CLAUDE.md`, rules, and skills with bash/zsh/PowerShell parity.
3. Add opt-in isolated `CLAUDE_CONFIG_DIR` lifecycle with restrictive permissions and no credential copying.
4. Add path, symlink/junction, TOCTOU, cleanup, and failure-atomicity tests.
5. Add version/capability detection and offline CI fixtures.
6. Run authenticated, version-pinned experiments for settings/session/plugin writes; decide whether any state can be linked or must be copied.
7. Document concurrency policy and migration/rollback behavior.

## Non-goals

- Claude Desktop, direct Anthropic API clients, IDE extensions as separate products, or arbitrary MCP hosts.
- Rebranding the current CLI before provider-neutral semantics are approved.
- Automatic migration or copying of credentials, transcripts, plugins, or auto-memory.
- Claiming support for undocumented Claude Code internals or all historical versions.
