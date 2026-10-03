# Tasks

## 1. Mode A Canonical Projection

- [ ] 1.1 Regenerate the Mode A implementation against current `develop`; detect root `AGENTS.md`, derive stable sanitized projection filenames, copy the fixed header plus source bytes, omit canonical roots from `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, and export empty string for an all-canonical selection. Feed canonical and legacy skills through PR #47's existing collision reconciliation; add no duplicate-name preflight. Verify Bash/PowerShell parsing and syntax checks pass. Do not apply the raw issue patch.
- [ ] 1.2 Add matching Bats/Pester cases for canonical-only and mixed selections, legacy-only parity, custom-directory ordering and empty-string semantics, filename sanitization/order (including whitespace, separators, and non-ASCII labels), exact bytes for LF/CRLF/BOM/no-final-newline/source frontmatter, canonical `SKILL.md` filtering, ignored co-located `.github/skills`, and collision warn-and-skip. Verify both focused suites pass and compare expected projection bytes for both shells.
- [ ] 1.3 Add Bats/Pester lifecycle and safety cases: stale managed files are removed, unmanaged files preserved, an unmanifested desired filename is not overwritten, malformed or linked manifests fail without projection changes, `instructions/` symlink/junction is not traversed, `ctx clear` preserves the cached projection, and `ctx clear --all` follows selected-home safety rules. Verify both focused suites pass and assert no file is written outside the synthetic home.
- [ ] 1.4 Add a zsh-specific Mode A test for mixed-profile projection and collision handling under default array indexing. Verify it passes under zsh and is skipped with an explicit reason when zsh is unavailable.

## 2. Mode B/C Fail-Closed Compatibility

- [ ] 2.1 Add a shared preflight for canonical selection in Modes B/C across manual activation, explicit `ctx load`, and `.ctx` auto-load. It must run before exports, workspace writes, synthetic-home setup, or ephemeral-home creation, and preserve the previous context on failure. Verify Bash/PowerShell syntax checks pass; regenerate against current `develop` and do not apply the raw issue patch.
- [ ] 2.2 Add Bats/Pester canonical-profile mode-matrix coverage for Modes A/B/C across manual selection, explicit load, and actual auto-load. Mode A succeeds; B/C fail with a clear profile/mode message and leave environment values, workspace files, and Copilot-home state unchanged. Trigger auto-load failure twice and verify both errors appear with state still unchanged. Verify both focused suites pass.
- [ ] 2.3 Add a zsh-specific Mode B/C rejection test proving preflight failure leaves prior state untouched. Verify under zsh and skip with an explicit reason when unavailable.

## 3. Read-Only Check and Documentation

- [ ] 3.1 Extend `ctx check` in Bash/PowerShell to check Mode A instruction bytes, safe projection directories/manifests, canonical skill links, and collisions; emit `CHECK SKIP instruction:<file>` for recorded B/C or unattributable state; use the recorded mode despite selector mismatch. Verify both focused suites pass with output and non-mutation assertions.
- [ ] 3.2 Add Bats/Pester cases for canonical skill-link PASS/FAIL, ignored `SKILL.md`-less directories, B/C instruction SKIP, Mode A selector mismatch while still checking projections, no-record SKIP, all-canonical custom-directory presence/empty-value audit, unchanged `ctx current` projection listing behavior, and read-only failure on unsafe paths/manifests. Verify both focused suites pass.
- [ ] 3.3 Update README with canonical root detection, exact filename/content behavior, source and skill routing, ignored co-located `.github/skills`, Mode B/C rejection, collision behavior, and self-contained instruction guidance. Verify the documented mode matrix and paths agree with the specs and tests.

## 4. Integration Verification

- [ ] 4.1 Run the complete Bats suite (including zsh coverage) and Pester suite; verify both pass using only temporary homes and no real Copilot state.
- [ ] 4.2 Review the final diff against `develop`, confirm `ctx.sh` has no C-style `for ((...))` loops, run `git diff --check`, and map every delta-spec criterion to a test or explicit verification.
