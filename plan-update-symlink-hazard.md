## Plan updated: symlink-write hazard is now a first-class design element

Following the empirical test above (confirmed: Copilot CLI's write-tmp+rename on `settings.json` replaces the `COPILOT_HOME` symlink with a plain file, orphaning the real `~/.copilot/settings.json`), `plan-issue-1.md` has been revised:

**New section 3.4a** — documents the confirmed repro, root cause (POSIX `rename(2)` onto a symlink replaces the link, doesn't write through), and the design fix: a **self-healing reconciliation step**, run on every `ctx <profile>`/`.ctx` activation (not just first creation), that:
1. Checks if each symlinked-back path is still a symlink
2. If not (CLI replaced it via rename), copies its current content back into the real `~/.copilot/<file>` first — so the latest write isn't lost
3. Deletes the plain file and recreates the symlink

Applied generically to **every** file/dir in the symlink-back list (not just `settings.json`) since we can't rely on which files a given CLI version chooses to rewrite. Also documents a known residual limitation: two concurrent contexts writing the same underlying file in the same window can still race (last reconciliation wins, not merged) — called out as a documented limitation rather than silently left as a gap.

**Test matrix (section 5.2)** gains 3 new cases (12–14): reconciliation correctly detects+restores a symlink the CLI replaced, this is verified across all symlinked files (not just `settings.json`), and reconciliation is a no-op when nothing changed (no unnecessary churn).

**Checklist / Q1**: Q1 in section 9 is now marked RESOLVED (was previously an open, unverified risk) — implementing the reconciliation logic is folded into checklist step 3 as a required part of `_ctx_setup_copilot_home`, not deferred or optional.

Full diff is in `plan-issue-1.md` on disk (sections 3.4a, 5.2 items 12–14, checklist steps 3/7/11, and the Q1 rewrite in section 9). Ready to proceed with implementation per the checklist whenever you give the go-ahead.
