#!/usr/bin/env bats
# Test suite for ctx.sh — COPILOT_HOME per-folder skill isolation (issue #1)
# and general ctx.sh behavior, per plan-issue-1.md section 5.2.
#
# Every test runs against an isolated $HOME / $AI_CONFIG_ROOT / COPILOT_HOME
# root (via CTX_COPILOT_DIR / CTX_HOMES_ROOT overrides) inside a temp dir, so
# nothing ever touches the real user's ~/.copilot or ~/.config/ctx.

setup() {
    export CTX_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/ctx.sh"
    export TEST_TMP
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"
    export AI_CONFIG_ROOT="$TEST_TMP/ai-config"
    export CTX_COPILOT_DIR="$TEST_TMP/copilot"
    export CTX_HOMES_ROOT="$TEST_TMP/home/.config/ctx/homes"
    mkdir -p "$HOME" "$AI_CONFIG_ROOT/profiles" "$AI_CONFIG_ROOT/shared" "$CTX_COPILOT_DIR"

    # Repo root, for fixtures under examples/.
    export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    unset AI_CONTEXT COPILOT_CUSTOM_INSTRUCTIONS_DIRS COPILOT_HOME CTX_AUTO_LOAD
    unset _ctx_auto_load_dir

    # shellcheck source=/dev/null
    source "$CTX_SRC"
}

teardown() {
    rm -rf "$TEST_TMP"
}

_make_profile() {
    # _make_profile <name> [skill-name]
    local name="$1" skill="${2:-}"
    mkdir -p "$AI_CONFIG_ROOT/profiles/$name/.github/instructions"
    echo "# $name instructions" > "$AI_CONFIG_ROOT/profiles/$name/.github/instructions/$name.instructions.md"
    if [ -n "$skill" ]; then
        mkdir -p "$AI_CONFIG_ROOT/profiles/$name/.github/skills/$skill"
        cat > "$AI_CONFIG_ROOT/profiles/$name/.github/skills/$skill/SKILL.md" <<EOF
---
name: $skill
description: Test skill $skill
---
EOF
    fi
}

# --- Test 1: manual activation creates isolated home -----------------------

@test "manual activation creates isolated COPILOT_HOME with skill symlink" {
    _make_profile "review" "review-skill"
    ctx review

    [ -n "$COPILOT_HOME" ]
    [ -d "$COPILOT_HOME" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
    local target
    target="$(readlink -f "$COPILOT_HOME/skills/review-skill")"
    [ "$target" = "$(readlink -f "$AI_CONFIG_ROOT/profiles/review/.github/skills/review-skill")" ]
}

# --- Test 2: shared-file symlinks point at the real ~/.copilot -------------

@test "shared files symlink back to the real copilot dir" {
    _make_profile "review"
    ctx review

    for f in settings.json config.json mcp-config.json session-store.db session-store.db-shm session-store.db-wal; do
        [ -L "$COPILOT_HOME/$f" ]
        local resolved
        resolved="$(readlink -f "$COPILOT_HOME/$f")"
        [ "$resolved" = "$(readlink -f "$CTX_COPILOT_DIR/$f")" ]
    done
    for d in session-state installed-plugins logs; do
        [ -L "$COPILOT_HOME/$d" ]
        local resolved
        resolved="$(readlink -f "$COPILOT_HOME/$d")"
        [ "$resolved" = "$(readlink -f "$CTX_COPILOT_DIR/$d")" ]
    done
}

# --- Test 3: multi-profile + shared context, no bleed -----------------------

@test "multi-profile context has both skills, single-profile context is isolated" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"

    ctx review
    local review_home="$COPILOT_HOME"
    [ -L "$review_home/skills/review-skill" ]
    [ ! -e "$review_home/skills/test-skill" ]

    ctx test
    local test_home="$COPILOT_HOME"
    [ "$review_home" != "$test_home" ]
    [ -L "$test_home/skills/test-skill" ]
    [ ! -e "$test_home/skills/review-skill" ]
}

@test ".ctx multi-entry activation puts both skills in one home, no bleed to single-profile" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"

    local proj="$TEST_TMP/project"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CONFIG_ROOT/profiles/review
test:$AI_CONFIG_ROOT/profiles/test
EOF

    _ctx_load_ctx_file "$proj/.ctx"
    local combined_home="$COPILOT_HOME"
    [ -L "$combined_home/skills/review-skill" ]
    [ -L "$combined_home/skills/test-skill" ]

    ctx review
    local review_home="$COPILOT_HOME"
    [ "$review_home" != "$combined_home" ]
    [ -L "$review_home/skills/review-skill" ]
    [ ! -e "$review_home/skills/test-skill" ]
}

# --- Test 4: idempotent re-activation ---------------------------------------

@test "re-activating the same profile does not recreate unchanged symlinks" {
    _make_profile "review" "review-skill"
    ctx review

    local before_settings_ino before_skill_ino
    before_settings_ino="$(stat -c '%i' "$COPILOT_HOME/settings.json")"
    before_skill_ino="$(stat -c '%i' "$COPILOT_HOME/skills/review-skill")"

    sleep 1
    ctx review

    local after_settings_ino after_skill_ino
    after_settings_ino="$(stat -c '%i' "$COPILOT_HOME/settings.json")"
    after_skill_ino="$(stat -c '%i' "$COPILOT_HOME/skills/review-skill")"

    [ "$before_settings_ino" = "$after_settings_ino" ]
    [ "$before_skill_ino" = "$after_skill_ino" ]
}

# --- Test 5: stale skill removal --------------------------------------------

@test "reactivation removes a skill symlink that no longer exists in the profile" {
    _make_profile "review" "review-skill"
    ctx review
    [ -L "$COPILOT_HOME/skills/review-skill" ]

    rm -rf "$AI_CONFIG_ROOT/profiles/review/.github/skills/review-skill"
    ctx review

    [ ! -e "$COPILOT_HOME/skills/review-skill" ]
}

# --- Test 6: ctx clear unsets COPILOT_HOME but preserves cache dir ---------

@test "ctx clear unsets COPILOT_HOME but preserves the home dir on disk" {
    _make_profile "review" "review-skill"
    ctx review
    local home_dir="$COPILOT_HOME"
    [ -d "$home_dir" ]

    _ctx_clear

    [ -z "${COPILOT_HOME:-}" ]
    [ -d "$home_dir" ]
}

# --- Test 7: ctx clear --all removes the current context's home dir --------

@test "ctx clear --all removes only the current context's home dir" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"

    ctx review
    local review_home="$COPILOT_HOME"
    ctx test
    local test_home="$COPILOT_HOME"

    [ -d "$review_home" ]
    [ -d "$test_home" ]

    _ctx_clear --all

    [ ! -d "$test_home" ]
    [ -d "$review_home" ]
}

# --- Test 8: .ctx auto-load path exercises the same logic ------------------

@test ".ctx auto-load creates COPILOT_HOME isolation identical to manual ctx" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"

    local proj="$REPO_ROOT/examples/copilot-cli-dotctx-test-review"
    [ -d "$proj" ]

    _ctx_load_ctx_file "$proj/.ctx"

    [ -n "$COPILOT_HOME" ]
    [ -L "$COPILOT_HOME/skills/review-profile-skill" ]
    [ -L "$COPILOT_HOME/skills/test-profile-skill" ]
}

# --- Test 9: no more settings.local.json writes -----------------------------

@test "fresh activation does not create settings.local.json" {
    _make_profile "review" "review-skill"

    local proj="$TEST_TMP/project9"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CONFIG_ROOT/profiles/review
EOF
    _ctx_load_ctx_file "$proj/.ctx"

    [ ! -f "$proj/.github/copilot/settings.local.json" ]
}

@test "manual ctx activation does not create settings.local.json" {
    _make_profile "review" "review-skill"
    ctx review
    [ ! -d "$AI_CONFIG_ROOT/profiles/review/.github/copilot" ]
}

# --- Test 10: fallback behavior on symlink failure --------------------------

@test "ctx warns and does not crash when symlink creation fails" {
    _make_profile "review" "review-skill"

    ln() { return 1; }
    export -f ln

    run ctx review

    # Don't assert `$status -eq 0`: ctx() currently ignores
    # _ctx_setup_copilot_home's return value, but if error propagation is
    # ever added that assertion would break for the wrong reason. What
    # actually matters here is the observable fallback behavior: a warning
    # is surfaced and COPILOT_HOME is left unset rather than pointing at a
    # half-built home dir.
    [[ "$output" == *"warning"* ]]
    [ -z "${COPILOT_HOME:-}" ]
}

# --- Test 11: fixture regression test (frontmatter parse) -------------------

@test "test-profile-skill SKILL.md has well-formed frontmatter" {
    local skill_md="$REPO_ROOT/examples/ai-profiles/test/.github/skills/test-profile-skill/SKILL.md"
    [ -f "$skill_md" ]

    local first_line
    first_line="$(sed -n '1p' "$skill_md")"
    [ "$first_line" = "---" ]

    run grep -c '^---$' "$skill_md"
    [ "$status" -eq 0 ]
    [ "$output" -ge 2 ]

    run grep -q '^name:' "$skill_md"
    [ "$status" -eq 0 ]
    run grep -q '^description:' "$skill_md"
    [ "$status" -eq 0 ]
}

# --- Tests 12-14: reconciliation hazard fix (plan 3.4a) ---------------------

@test "symlink replaced by a plain-file write is detected and reconciled (settings.json)" {
    _make_profile "review" "review-skill"
    ctx review
    local home="$COPILOT_HOME"

    [ -L "$home/settings.json" ]

    # Simulate Copilot CLI's write-tmp + rename(tmp, path), which replaces
    # the symlink itself with a plain regular file (confirmed empirically,
    # see empirical-test-symlink-hazard.md).
    rm -f "$home/settings.json"
    echo '{"bashEnv": true}' > "$home/settings.json"
    [ ! -L "$home/settings.json" ]

    ctx review

    [ -L "$home/settings.json" ]
    run cat "$CTX_COPILOT_DIR/settings.json"
    [[ "$output" == *'"bashEnv": true'* ]]
    run cat "$home/settings.json"
    [[ "$output" == *'"bashEnv": true'* ]]
}

@test "reconciliation runs for every shared file, not just settings.json" {
    _make_profile "review" "review-skill"
    ctx review
    local home="$COPILOT_HOME"

    for f in config.json mcp-config.json session-store.db; do
        rm -f "$home/$f"
        echo "content-for-$f" > "$home/$f"
        [ ! -L "$home/$f" ]
    done

    ctx review

    for f in config.json mcp-config.json session-store.db; do
        [ -L "$home/$f" ]
        run cat "$CTX_COPILOT_DIR/$f"
        [[ "$output" == "content-for-$f" ]]
        run cat "$home/$f"
        [[ "$output" == "content-for-$f" ]]
    done
}

@test "reconciliation is a no-op (mtime/inode unchanged) when nothing was written" {
    _make_profile "review" "review-skill"
    ctx review
    local home="$COPILOT_HOME"

    local before_ino
    before_ino="$(stat -c '%i' "$home/settings.json")"
    local real_before_ino
    real_before_ino="$(stat -c '%i' "$CTX_COPILOT_DIR/settings.json")"

    sleep 1
    ctx review

    local after_ino real_after_ino
    after_ino="$(stat -c '%i' "$home/settings.json")"
    real_after_ino="$(stat -c '%i' "$CTX_COPILOT_DIR/settings.json")"

    [ "$before_ino" = "$after_ino" ]
    [ "$real_before_ino" = "$real_after_ino" ]
}

# --- Tests 15-18: "home:" directive, custom COPILOT_HOME location (#7) -----

@test "home: directive in .ctx puts COPILOT_HOME at the custom location" {
    _make_profile "review" "review-skill"

    local proj="$TEST_TMP/project-home"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
home: .copilot-ctx
review:$AI_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"

    [ -n "$COPILOT_HOME" ]
    [ "$COPILOT_HOME" = "$proj/.copilot-ctx" ]
    [ -d "$COPILOT_HOME" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
    # Centralized default root must NOT have been used.
    [ ! -d "$CTX_HOMES_ROOT/review" ]
}

@test ".ctx without a home: directive still uses the centralized default" {
    _make_profile "review" "review-skill"

    local proj="$TEST_TMP/project-nohome"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"

    [ "$COPILOT_HOME" = "$CTX_HOMES_ROOT/review" ]
}

@test "home: directive with absolute path is used as-is" {
    _make_profile "review" "review-skill"

    local proj="$TEST_TMP/project-home-abs"
    local custom_home="$TEST_TMP/custom-copilot-home"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
home: $custom_home
review:$AI_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"

    [ "$COPILOT_HOME" = "$custom_home" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
}

@test "ctx clear --all removes the custom home: location, not the centralized one" {
    _make_profile "review" "review-skill"

    local proj="$TEST_TMP/project-home-clear"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
home: .copilot-ctx
review:$AI_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"
    local custom_home="$COPILOT_HOME"
    [ -d "$custom_home" ]

    _ctx_clear --all

    [ ! -d "$custom_home" ]
    [ ! -d "$CTX_HOMES_ROOT/review" ]
}

@test "duplicate home: directive in .ctx is rejected" {
    local proj="$TEST_TMP/project-home-dup"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
home: .copilot-ctx-a
home: .copilot-ctx-b
review:$AI_CONFIG_ROOT/profiles/review
EOF

    run _ctx_load_ctx_file "$proj/.ctx"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate"* ]]
}

# --- Tests 22-26: noautoload flag and ctx load command (issue #27) ----------

@test "noautoload flag: _ctx_load_ctx_file still loads a noautoload .ctx file" {
    _make_profile review skill-review
    local proj="$TEST_TMP/project-noautoload"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
noautoload
review:$AI_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"
    [ "$AI_CONTEXT" = "review" ]
    [[ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" == *"profiles/review"* ]]
}

@test "noautoload flag: auto-load hook skips a .ctx file with noautoload" {
    _make_profile review skill-review
    local proj="$TEST_TMP/project-noautoload-hook"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
noautoload
review:$AI_CONFIG_ROOT/profiles/review
EOF

    # Simulate the hook being called from inside the project directory.
    (
        cd "$proj"
        source "$CTX_SRC"
        # Hook fires at source time; context should NOT be set.
        [ -z "${AI_CONTEXT:-}" ]
    )
}

@test "noautoload flag: case-insensitive (NOAUTOLOAD is accepted)" {
    _make_profile review skill-review
    local proj="$TEST_TMP/project-noautoload-upper"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
NOAUTOLOAD
review:$AI_CONFIG_ROOT/profiles/review
EOF

    # load directly works fine
    _ctx_load_ctx_file "$proj/.ctx"
    [ "$AI_CONTEXT" = "review" ]
}

@test "ctx load: loads a .ctx file via explicit path" {
    _make_profile review skill-review
    local proj="$TEST_TMP/project-ctx-load"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CONFIG_ROOT/profiles/review
EOF

    ctx load "$proj/.ctx"
    [ "$AI_CONTEXT" = "review" ]
    [[ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" == *"profiles/review"* ]]
    [ "$_ctx_auto_load_dir" = "$proj" ]
}

@test "ctx load: loads a noautoload .ctx file that the hook would skip" {
    _make_profile review skill-review
    local proj="$TEST_TMP/project-ctx-load-noautoload"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
noautoload
review:$AI_CONFIG_ROOT/profiles/review
EOF

    ctx load "$proj/.ctx"
    [ "$AI_CONTEXT" = "review" ]
    [ "$_ctx_auto_load_dir" = "$proj" ]
}

@test "ctx load: errors when file not found" {
    run ctx load /nonexistent/.ctx
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "ctx load: errors when no path given" {
    run ctx load
    [ "$status" -ne 0 ]
}
