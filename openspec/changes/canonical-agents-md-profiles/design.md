# Design

## Context

See `proposal.md` for motivation. The current CLI has Mode A (`synthetic-home`), Mode B (`global-user`), and Mode C (`ephemeral-clean`). Mode A reconciles skills into a synthetic `COPILOT_HOME`; Modes B/C export `COPILOT_SKILLS_DIRS` from `.github/skills`. Both `ctx.sh` (bash/zsh) and `ctx.ps1` (Windows PowerShell 5.1+/pwsh) must remain behaviorally aligned.

The canonical contract classifies a profile by root `AGENTS.md`; its skills live under `.agents/skills/<name>/SKILL.md`. The provided raw patch was generated before the mode dispatch and PR #47 collision handling. The implementation must be re-derived against current `develop`, not applied verbatim.

## Goals / Non-Goals

**Goals:**
- Project canonical instructions and skills in Mode A and preserve mixed-profile order.
- Exclude canonical roots from Mode A `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`; keep present-empty semantics for all-canonical selections on supported runtimes (Windows PowerShell 5.1+/pwsh, or Unix pwsh/.NET 9+) and fail before mutation on Unix pwsh/.NET 8 and earlier.
- Reject canonical profiles in Modes B/C before any environment or workspace mutation.
- Preserve PR #47 collision behavior and zsh compatibility.
- Make `ctx check` read-only and base Mode A/B/C checks on the matching session-local activation record.

**Non-Goals:**
- Extending Mode B/C discovery to `.agents/skills` or claiming that Copilot's built-in discovery loads root `AGENTS.md` in these modes.
- Expanding relative `@file` imports or interpreting source frontmatter; source bytes are copied as body after the projection header.
- Changing `.ctx` grammar or adding profile mode metadata.

## Decisions

### Decision 1: Reject canonical profile selection in Modes B/C

**Decision:** Detect root `AGENTS.md` after resolving each manual profile or `.ctx` entry and validate the selected mode before exports, workspace-file updates, or home setup/creation. If Mode B or C is selected and any entry is canonical, report the affected label(s) and require `synthetic-home`.

**Rationale:** Mode B does not reconcile a synthetic instruction home, and its skill environment wiring targets `.github/skills`; Mode C creates an empty home without reconciliation. The canonical projection contract is therefore not provided by either mode. A fail-closed error is clearer than partial support or relying on undocumented Copilot discovery.

### Decision 2: Keep custom-instruction directory semantics explicit

**Decision:** Mode A includes only legacy roots in `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, preserving their selection order. If every selected profile is canonical, export an empty string on supported runtimes (Windows PowerShell 5.1+/pwsh, or Unix pwsh/.NET 9+); on Unix pwsh/.NET 8 and earlier the all-canonical selection fails before mutation as specified by Decision 8, because the present-empty value cannot be produced. Mode B/C selections are legacy-only because canonical selections are rejected; their existing directory and `.github/skills` wiring remains unchanged.

**Rationale:** This resolves the current manual-activation and integration-mode requirements without weakening them for existing legacy profiles. The empty-string case follows the supplied patch's behavior and is tested explicitly.

### Decision 3: Reuse PR #47 collision reconciliation

**Decision:** Extend source enumeration to feed canonical and legacy skill candidates into the existing Mode A reconciliation and use `_ctx_skill_canonical_name` for canonical comparison keys. Keep warn-and-skip for every colliding group and the existing `ctx check` collision failure. Do not introduce a separate duplicate-name preflight.

**Rationale:** PR #47 already established the policy and helper in the touched reconciliation path. Reuse avoids divergent behavior and honors the issue's requirement.

### Decision 4: Define portable projection names and bytes

**Decision:** The filename is `<order>-<label>.instructions.md`: one-based order padded to at least four decimal digits; the label source is the manual profile identifier or `.ctx` entry label and uses the existing sanitizer, retaining ASCII letters/digits/`+._-` and replacing every other character with `_`. The exact prefix is UTF-8/LF bytes `---\napplyTo: "**"\n---\n\n`, followed by the source `AGENTS.md` bytes unchanged. Preserve source CRLF/LF, optional BOM, and trailing-newline state; do not parse a source YAML-like header.

**Rationale:** A single shared rule lets both shells derive the same path and bytes. Reusing the sanitizer avoids a parallel name policy; order prefixes keep distinct selected entries' filenames unique.

### Decision 5: Constrain projection directories and manifest

**Decision:** Before projection writes or removals, require `instructions/` and `instructions/ctx-profiles/` to be real directories, not symlinks, junctions, or reparse points. Never read or delete through an unsafe component. `.ctx-managed` is a UTF-8 newline-delimited list of generated basenames: at least four ASCII decimal digits, a hyphen, a label containing only ASCII letters, digits, `+`, `.`, `_`, or `-`, and the literal suffix `.instructions.md`. A missing manifest is empty during activation; any nonconforming line, link, or unreadable manifest fails closed before projection changes. An existing desired target absent from the manifest is an unmanaged collision: fail rather than overwrite it. Only validated manifest entries may identify stale files; preserve unmanaged files. `ctx check` reports unsafe/malformed state without modifying it.

**Rationale:** `COPILOT_HOME` is user data. Treating parent paths and manifest contents as untrusted prevents writes or deletions through symlinks or path-like manifest entries.

### Decision 6: Attribute `ctx check` to the recorded activation

**Decision:** If a matching record says Mode A, check Mode A instructions and canonical skill links even if the selector now requests B/C; report the selector mismatch separately. If a matching record says B/C, emit `CHECK SKIP instruction:<file>`. If no matching record exists, skip Mode-A-only projections rather than inferring from the selector or paths. Canonical skills without `SKILL.md` are not expected skills.

**Rationale:** The current mode is the mode that actually activated, not the latest selector value. This prevents a stale selector from masking drift in a real Mode A context and avoids attributing foreign homes to `ctx`.

### Decision 7: Keep zsh-safe iteration

**Decision:** Do not introduce `for ((i=...))` loops in `ctx.sh`; use the non-indexed list/streaming patterns established by PR #47 and test under zsh defaults.

**Rationale:** zsh's default array indexing differs from Bash. Existing shared iteration patterns avoid reintroducing the exact class of regression PR #47 just removed.

### Decision 8: Guard all-canonical Mode A on Unix pwsh/.NET 9+

**Decision:** On Unix (Linux/macOS) PowerShell, all-canonical Mode A — the selection in which every selected profile is canonical and the required `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` value is empty — SHALL be supported only on pwsh running on .NET 9+ (pwsh 7.5+). On pwsh/.NET 8 and earlier, a canonical-only Mode A selection SHALL fail before any environment export, workspace-file write, Copilot-home setup or creation, or projection mutation, preserving the prior context, with an error stating that all-canonical Mode A requires pwsh/.NET 9+ on Unix. The guard SHALL apply to manual activation, explicit `ctx load`, and `.ctx` auto-load. Mixed canonical+legacy selections, whose custom-directories value is non-empty, and legacy-only selections retain their established behavior on Unix pwsh/.NET 8 and earlier; Modes B/C continue rejecting any canonical selection. `ctx check` SHALL keep the present-empty contract and SHALL NOT accept absent-as-empty. Windows PowerShell runs on the native Windows environment block and MAY use a native process-environment setter, so it retains full all-canonical behavior on PowerShell 5.1+ and pwsh.

**Rationale:** On Unix, pwsh/.NET 8 and earlier normalize a managed empty environment assignment to removal, and libc `setenv` is not visible to PowerShell's managed environment or to .NET-spawned child processes, so a present-empty value cannot be produced reliably. Microsoft documents this at https://learn.microsoft.com/en-us/dotnet/core/compatibility/core-libraries/9.0/empty-env-variable: before .NET 9, `Environment.SetEnvironmentVariable(name, string.Empty)` deletes the variable, and .NET 9 adds support for a present-empty value. Failing clearly before mutation is safer than silently exporting a dropped empty value. The limitation is confined to the all-canonical case; it is not solved by native `setenv` on Unix .NET 8 and earlier.

## Risks / Trade-offs

- [Risk] Canonical profiles in Mode B/C cannot be projected → Mitigation: fail before mutation with a clear Mode A requirement.
- [Risk] Instructions contain relative imports or source frontmatter → Mitigation: copy source bytes unchanged as body and document that canonical instructions must be self-contained.
- [Risk] Unsafe or corrupt projection metadata → Mitigation: reject symlinked parent directories and malformed/unreadable manifests; keep `ctx check` read-only.
- [Risk] Users may expect co-located `.github/skills` to be merged into canonical profiles → Mitigation: state clearly in README that canonical roots use `.agents/skills` only.
- [Risk] Unix pwsh/.NET 8 and earlier cannot express a present-empty environment value → Mitigation: fail all-canonical Mode A before any mutation with a clear pwsh/.NET 9+ requirement, limit the guard to the all-canonical case, preserve mixed/legacy behavior, keep the present-empty `ctx check` contract, and do not claim native `setenv` solves the limitation on Unix .NET 8 and earlier.
