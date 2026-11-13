# Proposal

## Why

Issue #22 asks `ctx` to support Claude Code. `.ctx` stays the selection surface. A Claude user must get the selected canonical instructions and skills in a fresh native Claude session. `ctx` must not start Claude.

The maintainer set the boundary on 2026-10-13 (#22):

- Ambient native sources are allowed: user settings, ancestor, repository, worktree, managed and built-in sources. `ctx` reports them. It does not filter them and does not call them selected.
- Production guidance keeps the normal `HOME`, `CLAUDE_CONFIG_DIR`, subscription login and setting sources. No `--bare`, no API key, no project-only source filter, no fake home.
- A profile of another task must never reach a session as a ctx-selected input.

Issue #83 closed the open evidence for this boundary on Claude Code 2.1.250, signed in:

- `--add-dir <dir>` loads `<dir>/.claude/skills` into the session.
- An external profile that has only `.agents/skills` adds no skill (#22 comment 6127372437). Thus `ctx` must copy the selected skills into a native `.claude/skills` layout.
- A signed-in session works with each tested flag set.

## What Changes

- **New `.ctx` directive `harness:`.** Values: `claude` or `copilot`. No directive keeps the current Copilot behavior.
- **Claude activation.** `harness:claude` builds one new private snapshot directory for each successful activation. The snapshot holds `CLAUDE.md` (the selected `AGENTS.md` bytes in `.ctx` order), `.claude/skills/` (copies of the selected `.agents/skills`), and `ctx-settings.json` (`{"autoMemoryEnabled": false}`).
- **Launch guidance, not a launcher.** On success, `ctx` prints the selected inputs, an ambient-source notice, and one shell-native command that starts a fresh Claude session with `--add-dir <snapshot>`.
- **Lifecycle.** `ctx current`, `ctx check`, `ctx clear` and `ctx clear --all` know the Claude record. `ctx` never deletes a snapshot. A running session can still use it.
- **Fail closed.** Every validation and snapshot error occurs before the new activation is published. The previous activation stays.

## Capabilities

### New Capabilities

- `claude-harness`: Claude activation, snapshot, launch guidance, check, current and clear.

### Modified Capabilities

- `dotctx-loading`: the `.ctx` grammar adds the reserved `harness:` directive.

## Non-goals

- `ctx` does not start, wrap or shadow `claude`. No `ctx-claude` command.
- No project-only setting source. #83 shows that `--setting-sources project` keeps the login. The maintainer policy keeps the normal sources, so this change does not use it.
- No `skillOverrides` or other filter for ambient skills. No plugins, hooks, MCP servers, agents or commands in the snapshot.
- No change to Copilot behavior, Modes A, B or C, or the .NET engine (`src/Ctx/**`, #67).
- Manual activation (`ctx <profile>...`) does not select Claude. Only `.ctx` can.
- No hard sandbox. Discovery settings are not a security boundary.

## Impact

- This proposal PR changes only `openspec/changes/add-claude-harness/**`.
- Later implementation scope: `ctx.sh`, `ctx.ps1`, `tests/ctx.bats`, `tests/ctx.Tests.ps1`, `README.md`, `docs/claude-code-compatibility.md`.
- Merging this proposal approves the contract. It does not approve the native evidence run in task 0 or the implementation. Each needs its own go.
