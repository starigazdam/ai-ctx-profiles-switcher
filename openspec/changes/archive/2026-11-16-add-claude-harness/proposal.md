# Proposal

## Why

Issue #22 asks `ctx` to support Claude Code. `.ctx` stays the selection surface. A Claude user must get the selected canonical instructions and skills in a fresh native Claude session. `ctx` must not start Claude.

The maintainer set the boundary on 2026-10-13 (#22):

- Ambient native sources are allowed: user settings, ancestor, repository, worktree, managed and built-in sources. `ctx` reports them. It does not filter them and does not call them selected.
- Production guidance keeps the normal `HOME`, `CLAUDE_CONFIG_DIR`, subscription login and setting sources. No `--bare`, no API key, no project-only source filter, no fake home.
- A profile of another task must never reach a session as a ctx-selected input.

Evidence from #22 and #83:

- `--add-dir <dir>` loads `<dir>/.claude/skills` into the session (2.1.292 offline, 2.1.250 signed in).
- An external profile that has only `.agents/skills` adds no skill (#22 comment 6127372437). Thus `ctx` must copy the selected skills into a native `.claude/skills` layout.
- A signed-in 2.1.250 session returned a successful answer with each tested flag set.

## What Changes

- **New `.ctx` directive `harness:`.** Values: `claude` or `copilot`. No directive keeps the current Copilot behavior. An old entry labelled `harness` now gets an error.
- **Claude activation.** `harness:claude` builds one new private snapshot directory for each activation. The snapshot holds `CLAUDE.md` (the selected `AGENTS.md` bytes in `.ctx` order), `.claude/skills/` (copies of the selected `.agents/skills`), and `ctx-settings.json` (`{"autoMemoryEnabled": false}`).
- **Launch guidance, not a launcher.** On success, `ctx` prints the selected inputs and skills, notices about ambient sources and limits, and one shell-native command. The command starts a fresh Claude session with `--add-dir <snapshot>`.
- **Lifecycle.** `ctx current`, `ctx check`, `ctx clear` and `ctx clear --all` read the Claude record. `ctx check` finds a stale snapshot or selection. `ctx` never deletes a published snapshot.
- **Fail closed.** A parse, client or snapshot error occurs before any state change, and the previous activation stays. A failure in the Copilot reset step publishes nothing (design D4).

## Capabilities

### New Capabilities

- `claude-harness`: Claude activation, snapshot, launch guidance, check, current and clear.

### Modified Capabilities

- `dotctx-loading`: the `.ctx` grammar adds the reserved `harness:` directive.

## Non-goals

- `ctx` does not start, wrap or shadow `claude`. No `ctx-claude` command.
- No project-only setting source. #83 shows that a session with `--setting-sources project` still answers. The maintainer policy keeps the normal sources, so this change does not use it.
- No `skillOverrides` or other filter for ambient skills. No plugins, hooks, MCP servers, agents or commands in the snapshot.
- No change to Copilot behavior, Modes A, B or C, or the .NET engine (`src/Ctx/**`, #67).
- Manual activation (`ctx <profile>...`) does not select Claude. Only `.ctx` can.
- No hard sandbox. Discovery settings are not a security boundary.

## Owner decisions

- Snapshot retention (design D8): accept unbounded retention like Mode C, or name a bound.
- Task 0 scope: accept task 0 as the native evidence for this contract, or require the full #22 packet A (Steps 2a and 2b).

## Impact

- This proposal PR changes only `openspec/changes/add-claude-harness/**`.
- Later implementation scope: `ctx.sh`, `ctx.ps1`, `tests/ctx.bats`, `tests/ctx.Tests.ps1`, `README.md`, `docs/claude-code-compatibility.md`.
- Merging this proposal approves the contract. It does not approve the native evidence run in task 0 or the implementation. Each needs a separate approval.
