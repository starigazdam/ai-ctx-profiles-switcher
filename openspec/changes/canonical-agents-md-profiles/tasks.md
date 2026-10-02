# Tasks

## 1. Mode A Canonical Projection

- [ ] 1.1 Regenerate the Mode A projection changes against current `develop`; detect canonical roots by root `AGENTS.md`, project ordered instructions, and route canonical skills from `.agents/skills` only when `SKILL.md` exists. Feed canonical and legacy skill candidates into PR #47's existing case-insensitive collision handling; do not add a parallel duplicate-name preflight or change warn-and-skip semantics. Verify Bash and PowerShell syntax checks pass.
- [ ] 1.2 Add matching Bats and Pester tests for Mode A canonical-only and mixed canonical/legacy selections, ordered instruction filenames/content, canonical `.agents/skills` filtering, ignored co-located `.github/skills`, unchanged legacy behavior, and collision warn-and-skip. Verify `bats tests/ctx.bats` and `Invoke-Pester tests/ctx.Tests.ps1` pass.
- [ ] 1.3 Add managed-projection lifecycle coverage in Bats and Pester: reactivation removes stale manifest-owned projections while preserving unmanaged files; `ctx clear` preserves the cached home and `ctx clear --all` follows existing selected-home safety rules. Verify both focused suites pass.
- [ ] 1.4 Add a zsh-specific test exercising Mode A canonical projection, including loop-sensitive mixed-profile iteration and collision handling, under zsh's default array indexing. Verify the test passes under zsh and is skipped with an explicit reason when zsh is unavailable.

## 2. Mode B/C Fail-Closed Compatibility

- [ ] 2.1 Add a shared preflight guard for canonical profile selection in Modes B and C across manual activation, explicit `ctx load`, and `.ctx` auto-load. It must run before exports, workspace writes, synthetic-home setup, or ephemeral-home creation. Regenerate affected hunks against current `develop`; do not `git apply` the raw issue patch. Verify Bash and PowerShell parsing checks pass.
- [ ] 2.2 Add Mode A/B/C canonical-profile matrix tests in Bats and Pester for manual selection, explicit `ctx load`, and actual `.ctx` auto-load; Mode A succeeds, Modes B/C fail with a clear message naming the unsupported mode and preserve existing environment values, workspace files, and Copilot-home state. Verify both focused suites pass.
- [ ] 2.3 Add a zsh-specific Mode B/C rejection test confirming preflight failure leaves prior state untouched. Verify under zsh and skip with an explicit reason when unavailable.

## 3. Read-Only Check and Documentation

- [ ] 3.1 Extend `ctx check` in Bash and PowerShell: Mode A reports PASS/FAIL for expected and stale instruction projections; Modes B/C report `CHECK SKIP instruction:<file>` for canonical entries; all paths remain read-only. Add equivalent Bats/Pester tests proving both output and non-mutation. Verify both focused suites pass.
- [ ] 3.2 Update README with canonical profile detection, projection and skill-source rules, the Mode B/C hard-fail, collision behavior, and self-contained instruction-file limitation. Verify the documented paths and mode matrix agree with the spec and tests.

## 4. Integration Verification

- [ ] 4.1 Run the complete Bats suite (including zsh coverage) and Pester suite; verify both pass with no changes to real user Copilot state.
- [ ] 4.2 Review the final diff against `develop`, confirm `ctx.sh` contains no C-style `for ((...))` loops, run `git diff --check`, and verify each acceptance criterion in the three delta specs has a matching test or explicit verification.
