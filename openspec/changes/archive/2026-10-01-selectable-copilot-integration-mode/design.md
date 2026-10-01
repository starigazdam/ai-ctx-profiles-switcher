# Design

## Context

See proposal.md — Why for motivation. Today `ctx` has a single Copilot integration path: every activation (manual `ctx <profile>...`, `ctx load`, or `.ctx` auto-load) builds a per-context synthetic home under `~/.config/ctx/homes/<context>/` (or `$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT`), symlinks the shared `~/.copilot` files/dirs back into it, populates `skills/` with symlinks to each resolved entry's `.github/skills`, and exports `COPILOT_HOME`. Two implementations must stay in parity: `ctx.sh` (bash/zsh, POSIX constructs, shellcheck-clean) and `ctx.ps1` (PowerShell, PSScriptAnalyzer-clean). The `.ctx` grammar is lines of `<name>:<path>`, a bare `noautoload` (case-insensitive), and a reserved `home:<path>` directive; the mode feature must not collide with that grammar.

Cross-cutting constraints:

- Bash/zsh (`ctx.sh`) and PowerShell (`ctx.ps1`) parity is required for all three modes. Future tests use offline/temp fixtures only and never a developer's real `~/.copilot` (matching the existing bats/Pester suites).
- No general Copilot instruction-source precedence is claimed or implied. Copilot merges `AGENTS.md`/`CLAUDE.md`/`.github/copilot-instructions.md`/`COPILOT_CUSTOM_INSTRUCTIONS_DIRS` and more, dedupes identical content, and defines no cross-source order; `ctx` only controls the order it lists directories within its own two env vars. `COPILOT_SKILLS_DIRS` is additive to Copilot's existing skill roots (`.github/skills`, `~/.copilot/skills` i.e. under whatever `COPILOT_HOME` is, `~/.agents/skills`, project `.agents/skills`, `.claude/skills`) in every mode — Modes B/C do not isolate skills; only Mode A does, via its own symlinked `skills/`. Citations: docs.github.com copilot-cli-reference/cli-command-reference (env var table), docs.github.com customize-copilot/add-custom-instructions (merge / no precedence), docs.github.com customize-copilot/add-skills (skill roots).
- This PR adds no CI workflow and triggers none: the docs/openspec paths this change touches are not in `test.yml`'s path filters. Nothing in this PR should be described as implying green CI.

## Goals / Non-Goals

**Goals:**
- Add one env var selector (`AI_CTX_PROFILES_COPILOT_MODE`) that resolves to three Copilot integration modes, with unset/empty meaning today's behavior byte-for-byte.
- Keep Mode A behavior exactly as documented while making `ctx current`/`ctx check` report the active mode.
- Give Modes B and C well-defined home and environment-wiring semantics with identical behavior in both shells.
- Keep the design additive and opt-in so existing users and CI see no change unless they opt in.

**Non-Goals:**
- Not resolving issue #40 (skill-name-collision bug), #34 (Rust v2), #22 (Claude Code adapter), #31 (external bindings), #32 (auto-load announcements), or #30 (workspace opt-in).
- No daemon/database/registry/new service, no `--add-dir` usage, no mutating repo-local `.github/copilot/...` config, and no auto-migrating or deleting an existing synthetic home.
- No configurable cleanup policy and no automatic cleanup of Mode C ephemeral homes.
- Mode C is not a skills/instructions sandbox and not a process/credential sandbox — only `COPILOT_HOME` pointing at an empty unique directory.
- Preserving the exclusions #38 carved out of the baseline specs: no identical-output unknown-profile listing promise across shells, no same-directory `noautoload` same-prompt reactivity promise, no generic whitespace-normalization parity claim between bash/PowerShell, and no description of CI as Ubuntu-only (the real workflow also runs a `windows-latest` Pester job).

## Decisions

### Decision 1: One selector, one env var (`AI_CTX_PROFILES_COPILOT_MODE`)

**Decision:** A single case-sensitive env var with exactly `synthetic-home` | `global-user` | `ephemeral-clean`; unset/empty = `synthetic-home` (byte-for-byte today); any other non-empty value errors before any export/workspace write/home setup, naming the allowed values. Read once per actual activation; never read/written as a write target by `clear`/`current`/`check`; activation never overwrites or unsets it. No CLI flag, no `.ctx` directive, no per-profile metadata, no precedence chain. One mode per activation.

**Rationale:** An env var is the only channel both shells and the auto-load hook already share, requires no completion changes, and cannot collide with the `.ctx` entry-label grammar. Validating before any state change reuses the existing "fail before mutation" contract. Unset-means-default preserves today's behavior byte-for-byte for every existing user. The name itself follows the existing `AI_CTX_PROFILES_` prefix and ALL-CAPS noun-phrase suffix convention already set by `AI_CTX_PROFILES_CONFIG_ROOT` and `AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT`, so no separate naming alternatives were considered.

**Alternative considered:** A `.ctx mode:` directive was rejected because `mode:`/`copilot-mode:` would collide with the existing `<name>:<path>` entry grammar — the parser would have to special-case a new reserved label, and the feature would then only work for `.ctx`-file activations, not manual `ctx <profile>...`. A CLI flag was rejected because it would need per-call plumbing through the auto-load hook in both shells and break parity of completion. Per-profile metadata was rejected because it cannot express "one mode for the whole activation."

### Decision 2: `.ctx` parsing/`noautoload`/hook unchanged; `home:` is Mode-A-only

**Decision:** The mode selector adds no new `.ctx` line type, does not change when the auto-load hook fires, and does not change workspace-file creation/ownership/cleanup. `home:` is valid only under Mode A: under Modes B/C a `.ctx` file with a `home:` line is rejected before any state change with the same invalid-file, previous-context-untouched semantics as other `.ctx` validation errors.

**Rationale:** The mode feature should not grow the `.ctx` grammar; keeping `home:` Mode-A-only avoids ambiguity about which directory (synthetic vs ephemeral) a `home:` directive would mean in B/C, and rejects loudly rather than silently ignoring a directive the user wrote on purpose.

**Alternative considered:** Silently ignoring `home:` under B/C was rejected: it hides user intent and creates a silent difference between modes. Silently reinterpreting `home:` as a hint for the ephemeral root was rejected: it would mix namespaces and invent a precedence chain.

### Decision 3: Mode A is today, unchanged

**Decision:** Explicit `synthetic-home` is byte-identical to unset. All current symlink reconciliation, skill-directory population, and cleanup rules stay exactly as documented in README "Skill discovery"/"Operational notes". The rename-through-symlink hazard and concurrent last-writer-wins race stay documented, not fixed, not hidden. The only default-visible addition is that `ctx current`/`ctx check` also report the active mode. Issue #40 is not resolved here.

**Rationale:** The feature is opt-in; changing default behavior would violate the brief's additive constraint and force every existing user through a behavior migration. Documenting (not fixing) the known hazards keeps parity with the current spec and the #38 exclusions.

**Alternative considered:** Fixing the rename-through-symlink hazard or the concurrent race as part of this change was rejected as out of scope and already-excluded by #38; it would change Mode A behavior this feature must not touch.

### Decision 4: Mode B never touches `COPILOT_HOME`

**Decision:** At activation Mode B does not read, set, unset, create, or delete `COPILOT_HOME` — whatever value it has (user-set, leftover from A/C, or unset) is left exactly as-is. Switching directly from A/C into B does not restore or clear an old pointer; the user who wants Copilot's real default clears/unset it themselves. `ctx clear`/`clear --all` under Mode B likewise never touch it; `--all`'s common workspace/settings cleanup still runs.

**Rationale:** "Never touch" is the simplest contract to specify and test, and it is the only contract that cannot surprise a user who deliberately set `COPILOT_HOME` for a global Copilot session. Restoring/clearing on switch would require `ctx` to know the user's intent, which it cannot.

**Alternative considered:** "Restore" or "clear the old pointer" on entering Mode B was rejected: `ctx` cannot distinguish a leftover A/C pointer from a deliberately-set global value, and any automatic action would violate the never-touch guarantee and the brief's explicit instruction that `ctx` must not claim Mode B restores anything.

### Decision 5: Mode B/C env wiring for `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` and the new `COPILOT_SKILLS_DIRS`

**Decision:** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` keeps today's exact semantics in all three modes (resolved entry/profile dirs, invocation/file order, comma-joined, replaced — not appended — on each activation, unset on clear). `COPILOT_SKILLS_DIRS` is new, used only in Modes B/C: the existing `<resolved-root>/.github/skills` directories of the active entries (only existing ones), stable order, comma-joined; unset when none exist; fully replaced on each new B/C activation; unset on `ctx clear` and on a successful switch into Mode A; a Mode-A-only session never touches a user-set value — only unsets one a prior B/C activation in this session set. Before export, a resolved path containing a literal comma is rejected as an activation error with no side effects (no escaping mechanism exists); this is additive to Copilot's built-in discovery, not appending to the previous activation's value.

**Rationale:** Modes B/C have no synthetic `skills/` tree to symlink into, so the only way to point Copilot at the entries' skills is the directory list. Replacing each activation and unsetting on clear/A-switch prevents cross-activation leakage and matches the existing `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` lifecycle, so the two vars behave consistently. The comma rejection avoids an unescapable ambiguity in a comma-joined var.

**Alternative considered:** Appending new entries across activations was rejected: it leaks state between contexts and contradicts the replaced-each-activation contract of the sibling var. Exporting an empty string when no skills exist was rejected: an unset var is the correct "nothing to add" signal and avoids a later active-but-empty misread. Ignoring comma paths was rejected: it would silently drop an entry the user listed.

### Decision 6: Mode C creates a fresh unique temp home on every activation

**Decision:** Every Mode C activation creates a new unique temp home via the platform's secure temp primitive (`mktemp -d` on POSIX; `[System.IO.Path]::GetTempPath()` + GUID/random suffix in PowerShell, no new dependency); never reused, never looked up by name; reject a colliding path or existing symlink/junction; export `COPILOT_HOME` only after creation succeeds. No symlinks/junctions/hardlinks/copies into or out of real `~/.copilot`, no reconciliation, no auth/session inspection. Any validation/creation failure leaves the previous context and all files untouched (same fail-before-state-change contract as existing validation; not a full filesystem transaction, not retrofitted onto Mode A's existing setup-failure behavior).

**Rationale:** A unique name per activation guarantees isolation between repeated activations without needing to manage a name registry, and the platform temp primitive gives secure/private semantics for free. Failing before export and before any state change reuses the contract users already rely on for `.ctx` validation errors.

**Alternative considered:** A reusable, named ephemeral home (e.g. keyed by context name under the temp dir) was rejected: reuse would defeat "clean" semantics and reintroduce exactly the cross-context contamination the mode exists to avoid. Symlinking or copying the real `~/.copilot` into the ephemeral home was rejected: it is precisely the Mode A behavior this mode opts out of, and reconciliation would reintroduce the hazards Mode C avoids.

### Decision 7: Mode C cleanup never deletes the ephemeral directory

**Decision:** `ctx clear`/`ctx clear --all` under Mode C unset `COPILOT_HOME` but never delete the directory or its contents — not on clear, not on switching modes/profiles, not on shell exit. No sweeper, trap, or background cleanup. Leaving/replacing an active Mode C context reports the retained path on stdout and states plainly that cleanup and moving data out is the user's/workflow's responsibility, warning that it may contain auth/session data and consumes disk until removed manually. `--all`'s common-artifact cleanup still runs; only Mode A's existing home deletion stays home-deleting. No configurable cleanup policy.

**Rationale:** Deleting a directory Copilot may be writing to (auth/session state) is unsafe and unpredictable; `ctx` must not destroy data it never read. Leaving cleanup to the user/workflow is explicit and honest, and reporting the retained path makes it actionable. This matches the brief's requirement to warn about auth/session data and disk consumption.

**Alternative considered:** An automatic sweeper/trap or cleanup-on-shell-exit was rejected: shell-exit hooks are unreliable across bash/zsh/PowerShell, and background deletion of a possibly-in-use Copilot home would be destructive. A configurable cleanup policy was rejected by the brief as out of scope.

### Decision 8: Reporting and read-only checks

**Decision:** Each successful activation records session-locally (no new on-disk registry) which mode actually activated and, for B/C, the home value it is responsible for checking. `ctx current` prints the active mode (not the requested selector — a stale/mismatched env value without a matching activation is not "active") plus, in B/C, the active `COPILOT_SKILLS_DIRS`. `ctx check` stays a successful no-op with no `.ctx` file, reports the active mode and flags selector/active-mode mismatch when a file is found, keeps every Mode A check unchanged, compares `COPILOT_HOME` in Mode B only against the recorded value (including still-unset), requires in Mode C that the recorded ephemeral path still exist as a real non-symlink directory (no empty requirement, no content inspection/repair), reports `CHECK SKIP` (not FAIL) for the Mode-A-only shared-link and skill-symlink checks in B/C, and reports foreign `COPILOT_HOME`/`COPILOT_SKILLS_DIRS` without a local activation record as unknown rather than guessing or deleting. No existing Mode-A check for inherited/foreign state is redesigned.

**Rationale:** Session-local state avoids a new on-disk registry while still letting `current`/`check` distinguish "requested" from "actually active" — the key ambiguity the brief calls out. The per-mode CHECK semantics keep the read-only audit truthful: what a mode does not manage must be SKIP, not FAIL, and what cannot be attributed must be reported unknown, never guessed.

**Alternative considered:** An on-disk registry of active mode/home was rejected by the brief ("no new on-disk registry") and would add cleanup/migration surface. Guessing the mode from a foreign path was rejected: it would fabricate provenance and could lead to destructive actions on state `ctx` never created.

## Risks / Trade-offs

- [Risk] Mode C ephemeral directories accumulate on disk and are never auto-cleaned → Mitigation: documented manual cleanup with no automatic sweep, the retained path is reported on stdout when leaving a Mode C context, and the message warns that the directory may contain auth/session data and consumes disk until removed manually.
- [Risk] Mode B leaving an unrelated existing `COPILOT_HOME` is confusable with "no mode selected" → Mitigation: `ctx current` must show the active mode explicitly, and `ctx check` flags a selector/active-mode mismatch so "no mode" and "Mode B with a leftover `COPILOT_HOME`" are distinguishable.
- [Risk] A stale/mismatched `AI_CTX_PROFILES_COPILOT_MODE` sitting in the environment could be misread as the active mode → Mitigation: `ctx current` reports the actually-active mode from the session-local activation record, never the raw selector.
- [Risk] `COPILOT_SKILLS_DIRS` leaking between activations → Mitigation: always fully replaced on each B/C activation, unset on `ctx clear` and on a successful switch into Mode A, and never appended.
- [Risk] An unescapable comma in a resolved directory path would corrupt the comma-joined `COPILOT_SKILLS_DIRS` → Mitigation: rejected as an activation error before export, with no side effects, in Modes B/C only; Mode A parsing is untouched.