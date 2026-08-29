## 🔴 Empirical test: the `COPILOT_HOME` symlink-write hazard is real

I ran the verification I proposed in my earlier critique, against the real (authenticated) Copilot CLI 1.0.80. **Confirmed: the plan's "symlink individual shared config files back to `~/.copilot`" design is broken as written.**

### Setup

```bash
mkdir -p /tmp/synthome/skills
ln -sf ~/.copilot/settings.json        /tmp/synthome/settings.json
ln -sf ~/.copilot/config.json          /tmp/synthome/config.json
ln -sf ~/.copilot/session-store.db     /tmp/synthome/session-store.db
ln -sf ~/.copilot/session-state        /tmp/synthome/session-state
ln -sf ~/.copilot/installed-plugins    /tmp/synthome/installed-plugins
ln -sf ~/.copilot/logs                 /tmp/synthome/logs
```

Real `~/.copilot/settings.json` before: `{}`

### Step 1 — skills materialize correctly ✅

```bash
COPILOT_HOME=/tmp/synthome copilot skill add /tmp/testskill/SKILL.md
```
→ `Created /tmp/synthome/skills/empiric-test-skill` — this part of the design works exactly as intended, isolated skills directory is fine.

### Step 2 — trigger a settings write ❌

```bash
COPILOT_HOME=/tmp/synthome copilot --bash-env=on -p "say hi" --allow-all-tools
```

`--bash-env=on` is documented to persist to config. Result:

```
--- before ---
lrwxrwxrwx 1 hermes hermes 35 /tmp/synthome/settings.json -> /home/hermes/.copilot/settings.json

--- after ---
-rw------- 1 hermes hermes 22 /tmp/synthome/settings.json      <- symlink REPLACED by a regular file
content via symlink path:  {"bashEnv": true}
content of the REAL file (~/.copilot/settings.json):  {}       <- unchanged, now silently stale
```

**This is exactly the atomic-rename hazard from Q1 of the plan.** Copilot CLI writes `settings.json` via write-tmp + rename, which on a symlink target replaces the symlink itself with an independent regular file. The real `~/.copilot/settings.json` is now permanently orphaned from that point forward — every future context activation would see the stale real file, while this one context's file silently diverged.

### Control: directories and other files were NOT affected

- `config.json`, `session-store.db`, `session-state/`, `installed-plugins/`, `logs/` all remained intact symlinks after the same run (checked via `ls -la`).
- So the hazard is specific to files the CLI actively **rewrites** via atomic replace — currently just `settings.json` in this test. `config.json` wasn't touched in this run so it's not proven safe, only "not observed unsafe here."

### Conclusion / required design change

Plain per-file symlinks-back are **not safe** for any file Copilot CLI writes to (confirmed: `settings.json`). The plan (section 3.3/3.4) needs one of:

1. **Reconciliation-on-every-activation**: detect `settings.json` is now a regular file (not a symlink) → copy its content back into the real `~/.copilot/settings.json`, then replace it with a fresh symlink again. Must run this check at the *start* of every `ctx <profile>` invocation, not just once.
2. **Don't symlink `settings.json`/`config.json` at all** — instead have `ctx` copy the real files in at context-activation time and copy them back out at deactivation (`ctx clear`), losing true concurrency but avoiding orphaning.
3. **Skip isolation for `settings.json`** — always point it at the real file via a mechanism the CLI can't replace-out-from-under (not obviously possible with symlinks; would need e.g. a bind mount, which requires root/CAP_SYS_ADMIN — probably not viable for a userland tool).

Recommend **option 1** (self-healing reconciliation), added explicitly to section 3.4 of the plan, with a new automated test case: write through the synthetic settings.json, reactivate the context, assert the real `~/.copilot/settings.json` picked up the change and the symlink was restored.

This should block writing `_ctx_setup_copilot_home` until the reconciliation logic for at-risk files (`settings.json` confirmed, `config.json`/anything else the CLI writes should be assumed at-risk too until proven otherwise) is part of the design, not deferred to a "risk to monitor."
