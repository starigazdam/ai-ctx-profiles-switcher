#!/usr/bin/env bats
# Test suite for ctx.sh — COPILOT_HOME per-folder skill isolation (issue #1)
# and general ctx.sh behavior, per the historical design in
# docs/design-history-copilot-home.md section 5.2.
#
# Every test runs against an isolated $HOME / $AI_CTX_PROFILES_CONFIG_ROOT / COPILOT_HOME
# root (via CTX_COPILOT_DIR / AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT overrides) inside a temp dir, so
# nothing ever touches the real user's ~/.copilot or ~/.config/ctx.

setup() {
    export CTX_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/ctx.sh"
    export TEST_TMP
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"
    export AI_CTX_PROFILES_CONFIG_ROOT="$TEST_TMP/ai-config"
    export CTX_COPILOT_DIR="$TEST_TMP/copilot"
    export AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT="$TEST_TMP/home/.config/ctx/homes"
    mkdir -p "$HOME" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles" "$CTX_COPILOT_DIR"

    # Repo root, for fixtures under examples/.
    export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    unset AI_CTX_PROFILES AI_CONTEXT AI_CONFIG_ROOT CTX_HOMES_ROOT COPILOT_CUSTOM_INSTRUCTIONS_DIRS COPILOT_HOME COPILOT_SKILLS_DIRS CTX_AUTO_LOAD
    unset AI_CTX_PROFILES_COPILOT_MODE
    unset _ctx_auto_load_dir
    unset _ctx_skills_dirs_owned
    unset _ctx_skills_dirs_was_set
    unset _ctx_skills_dirs_value

    # shellcheck source=/dev/null
    source "$CTX_SRC"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "breaking contract activates multiple unified profiles and ignores legacy root" {
    _make_profile review review-skill
    _make_profile security security-skill
    export AI_CONFIG_ROOT="$TEST_TMP/legacy"

    ctx review security

    [ "$AI_CTX_PROFILES" = "review+security" ]
    [ -z "${AI_CONTEXT:-}" ]
    [[ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" == *"$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"* ]]
    [[ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" == *"$AI_CTX_PROFILES_CONFIG_ROOT/profiles/security"* ]]
}

@test "manual duplicate profiles are rejected before changing state" {
    _make_profile review
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs

    local status=0
    ctx review Review >"$TEST_TMP/dup.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/dup.out")" == *"duplicate profile"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
}

@test ".ctx profile references, direct paths, and duplicate targets are validated" {
    _make_profile review review-skill
    _make_profile security security-skill
    local direct="$TEST_TMP/direct"
    mkdir -p "$direct"
    local proj="$TEST_TMP/project"
    mkdir -p "$proj"
    printf 'review:@profile\nsecurity:@profile\nlocal:%s\n' "$direct" > "$proj/.ctx"

    _ctx_load_ctx_file "$proj/.ctx"

    [ "$AI_CTX_PROFILES" = "review+security+local" ]
    [[ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" == *"$direct"* ]]
}

@test ".ctx duplicate labels and canonical targets fail atomically" {
    _make_profile review
    local proj="$TEST_TMP/project"
    mkdir -p "$proj"
    printf 'review:@profile\nReview:@profile\n' > "$proj/.ctx"
    export AI_CTX_PROFILES=previous

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/dup-ctx.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/dup-ctx.out")" == *"duplicate .ctx entry label"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
}

_make_profile() {
    # _make_profile <name> [skill-name]
    local name="$1" skill="${2:-}"
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/$name/.github/instructions"
    echo "# $name instructions" > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/$name/.github/instructions/$name.instructions.md"
    if [ -n "$skill" ]; then
        mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/$name/.github/skills/$skill"
        cat > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/$name/.github/skills/$skill/SKILL.md" <<EOF
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
    [ "$target" = "$(readlink -f "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills/review-skill")" ]
}

@test "zsh supports manual activation with profiles" {
    if ! command -v zsh >/dev/null 2>&1; then
        skip "zsh is not installed"
    fi

    _make_profile review "review-skill"
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/azure/.github/skills/azure-skill"
    printf '%s\n' '# azure skill' > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/azure/.github/skills/azure-skill/SKILL.md"

    local zsh_path
    zsh_path="$(command -v zsh)"
    run env PATH="/usr/local/bin:/usr/bin:/bin:$PATH" "$zsh_path" -f -c '
        source "$1"
        ctx review azure >/dev/null || exit
        [ "$AI_CTX_PROFILES" = review+azure ] || exit
        [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$2/profiles/review,$2/profiles/azure" ] || exit
        [ -L "$COPILOT_HOME/skills/review-skill" ] || exit
        [ -L "$COPILOT_HOME/skills/azure-skill" ] || exit
    ' -- "$CTX_SRC" "$AI_CTX_PROFILES_CONFIG_ROOT"

    [ "$status" -eq 0 ]
}

@test "BSD stat fallback does not pass GNU-only option separator" {
    local target="$TEST_TMP/stat-target"
    printf 'target\n' > "$target"

    stat() {
        if [ "$1" = "-c" ]; then
            return 1
        fi
        [ "$1" = "-f" ] && [ "$2" = "%d:%i" ] || return 2
        [ "$3" != "--" ] || return 3
        printf '42:99\n'
    }

    run _ctx_file_identity "$target"
    [ "$status" -eq 0 ]
    [ "$output" = "42:99" ]
}

# --- Test 2: shared-file symlinks point at the real copilot dir -------------

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

# --- Test 3: multi-profile + profile, no bleed -----------------------

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
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
test:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/test
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

    rm -rf "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills/review-skill"
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
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF
    _ctx_load_ctx_file "$proj/.ctx"

    [ ! -f "$proj/.github/copilot/settings.local.json" ]
}

@test "manual ctx activation does not create settings.local.json" {
    _make_profile "review" "review-skill"
    ctx review
    [ ! -d "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/copilot" ]
}

# --- Test 10: fallback behavior on symlink failure --------------------------

@test "ctx warns and does not crash when symlink creation fails" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"
    ctx review >/dev/null 2>&1

    local prev_profiles="$AI_CTX_PROFILES"
    local prev_dirs="$COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    local prev_home="$COPILOT_HOME"
    local prev_mode="$_ctx_active_mode"
    local prev_context="$_ctx_active_context"
    local prev_custom_dirs="$_ctx_active_custom_dirs"
    local prev_home_was_set="$_ctx_active_home_was_set"
    local prev_home_value="$_ctx_active_home_value"

    ln() { return 1; }
    export -f ln

    local status=0
    ctx test >"$TEST_TMP/link-fail-manual.out" 2>&1 || status=$?

    # A warning is surfaced, and the failure is atomic: the existing
    # activation's context, custom-instructions dirs, COPILOT_HOME, and
    # session record are all left byte-identical rather than pointing at a
    # half-built home dir.
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/link-fail-manual.out")" == *"warning"* ]]
    [ "$AI_CTX_PROFILES" = "$prev_profiles" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$prev_dirs" ]
    [ "$COPILOT_HOME" = "$prev_home" ]
    [ "$_ctx_active_mode" = "$prev_mode" ]
    [ "$_ctx_active_context" = "$prev_context" ]
    [ "$_ctx_active_custom_dirs" = "$prev_custom_dirs" ]
    [ "$_ctx_active_home_was_set" = "$prev_home_was_set" ]
    [ "$_ctx_active_home_value" = "$prev_home_value" ]
}

@test ".ctx auto-load leaves state and workspace untouched when symlink creation fails" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"

    local proj="$TEST_TMP/project-link-fail"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null 2>&1

    local workspace_file="$proj/project-link-fail.code-workspace"
    [ -f "$workspace_file" ]
    cp "$workspace_file" "$TEST_TMP/workspace-link-fail.before"

    local prev_profiles="$AI_CTX_PROFILES"
    local prev_dirs="$COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    local prev_home="$COPILOT_HOME"
    local prev_mode="$_ctx_active_mode"
    local prev_context="$_ctx_active_context"
    local prev_custom_dirs="$_ctx_active_custom_dirs"
    local prev_home_was_set="$_ctx_active_home_was_set"
    local prev_home_value="$_ctx_active_home_value"

    printf 'test:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/test" > "$proj/.ctx"
    ln() { return 1; }
    export -f ln

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/link-fail-autoload.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/link-fail-autoload.out")" == *"warning"* ]]
    [ "$AI_CTX_PROFILES" = "$prev_profiles" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$prev_dirs" ]
    [ "$COPILOT_HOME" = "$prev_home" ]
    [ "$_ctx_active_mode" = "$prev_mode" ]
    [ "$_ctx_active_context" = "$prev_context" ]
    [ "$_ctx_active_custom_dirs" = "$prev_custom_dirs" ]
    [ "$_ctx_active_home_was_set" = "$prev_home_was_set" ]
    [ "$_ctx_active_home_value" = "$prev_home_value" ]
    cmp -s "$workspace_file" "$TEST_TMP/workspace-link-fail.before"
}

@test "manual ctx activation leaves state untouched when COPILOT_HOME creation fails" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"
    ctx review >/dev/null 2>&1

    local prev_profiles="$AI_CTX_PROFILES"
    local prev_dirs="$COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    local prev_home="$COPILOT_HOME"
    local prev_mode="$_ctx_active_mode"
    local prev_context="$_ctx_active_context"
    local prev_custom_dirs="$_ctx_active_custom_dirs"
    local prev_home_was_set="$_ctx_active_home_was_set"
    local prev_home_value="$_ctx_active_home_value"

    mkdir() { return 1; }
    export -f mkdir

    local status=0
    ctx test >"$TEST_TMP/mkdir-fail-manual.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/mkdir-fail-manual.out")" == *"warning"* ]]
    [ "$AI_CTX_PROFILES" = "$prev_profiles" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$prev_dirs" ]
    [ "$COPILOT_HOME" = "$prev_home" ]
    [ "$_ctx_active_mode" = "$prev_mode" ]
    [ "$_ctx_active_context" = "$prev_context" ]
    [ "$_ctx_active_custom_dirs" = "$prev_custom_dirs" ]
    [ "$_ctx_active_home_was_set" = "$prev_home_was_set" ]
    [ "$_ctx_active_home_value" = "$prev_home_value" ]
}

@test ".ctx auto-load leaves state and workspace untouched when COPILOT_HOME creation fails" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"

    local proj="$TEST_TMP/project-mkdir-fail"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null 2>&1

    local workspace_file="$proj/project-mkdir-fail.code-workspace"
    [ -f "$workspace_file" ]
    cp "$workspace_file" "$TEST_TMP/workspace-mkdir-fail.before"

    local prev_profiles="$AI_CTX_PROFILES"
    local prev_dirs="$COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    local prev_home="$COPILOT_HOME"
    local prev_mode="$_ctx_active_mode"
    local prev_context="$_ctx_active_context"
    local prev_custom_dirs="$_ctx_active_custom_dirs"
    local prev_home_was_set="$_ctx_active_home_was_set"
    local prev_home_value="$_ctx_active_home_value"

    printf 'test:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/test" > "$proj/.ctx"
    mkdir() { return 1; }
    export -f mkdir

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/mkdir-fail-autoload.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/mkdir-fail-autoload.out")" == *"warning"* ]]
    [ "$AI_CTX_PROFILES" = "$prev_profiles" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$prev_dirs" ]
    [ "$COPILOT_HOME" = "$prev_home" ]
    [ "$_ctx_active_mode" = "$prev_mode" ]
    [ "$_ctx_active_context" = "$prev_context" ]
    [ "$_ctx_active_custom_dirs" = "$prev_custom_dirs" ]
    [ "$_ctx_active_home_was_set" = "$prev_home_was_set" ]
    [ "$_ctx_active_home_value" = "$prev_home_value" ]
    cmp -s "$workspace_file" "$TEST_TMP/workspace-mkdir-fail.before"
}

@test ".ctx auto-load hook returns non-zero and leaves state/workspace intact when symlink creation fails" {
    _make_profile "review" "review-skill"
    _make_profile "test" "test-skill"

    local proj_a="$TEST_TMP/project-hook-link-fail-a"
    mkdir -p "$proj_a"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj_a/.ctx"
    cd "$proj_a"
    _ctx_auto_load_hook

    local workspace_a="$proj_a/project-hook-link-fail-a.code-workspace"
    [ -f "$workspace_a" ]
    cp "$workspace_a" "$TEST_TMP/workspace-hook-link-fail.before"

    local prev_profiles="$AI_CTX_PROFILES"
    local prev_dirs="$COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    local prev_home="$COPILOT_HOME"
    local prev_mode="$_ctx_active_mode"
    local prev_context="$_ctx_active_context"
    local prev_custom_dirs="$_ctx_active_custom_dirs"
    local prev_home_was_set="$_ctx_active_home_was_set"
    local prev_home_value="$_ctx_active_home_value"

    local proj_b="$TEST_TMP/project-hook-link-fail-b"
    mkdir -p "$proj_b"
    printf 'test:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/test" > "$proj_b/.ctx"
    cd "$proj_b"
    ln() { return 1; }
    export -f ln

    local status=0
    _ctx_auto_load_hook >"$TEST_TMP/hook-link-fail.out" 2>&1 || status=$?

    # The hook propagates the failed load as a non-zero status, and the
    # failure is atomic: the prior activation's context, custom-instructions
    # dirs, COPILOT_HOME, session record, and workspace are all left
    # byte-identical, and the failing directory's workspace is never written.
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/hook-link-fail.out")" == *"warning"* ]]
    [ "$AI_CTX_PROFILES" = "$prev_profiles" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$prev_dirs" ]
    [ "$COPILOT_HOME" = "$prev_home" ]
    [ "$_ctx_active_mode" = "$prev_mode" ]
    [ "$_ctx_active_context" = "$prev_context" ]
    [ "$_ctx_active_custom_dirs" = "$prev_custom_dirs" ]
    [ "$_ctx_active_home_was_set" = "$prev_home_was_set" ]
    [ "$_ctx_active_home_value" = "$prev_home_value" ]
    cmp -s "$workspace_a" "$TEST_TMP/workspace-hook-link-fail.before"
    [ ! -e "$proj_b/project-hook-link-fail-b.code-workspace" ]
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
    # see docs/empirical-symlink-hazard.md).
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

# --- Tests 20-26: safe custom home validation (issue #12) -------------------

@test "home: accepts a canonical nested path under HOME" {
    _make_profile "review" "review-skill"
    local proj="$HOME/project-home-valid"
    local custom="$HOME/.config/ctx/homes/project-valid/nested"
    mkdir -p "$proj"
    printf 'home:%s\nreview:%s\n' "$custom" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    _ctx_load_ctx_file "$proj/.ctx"
    [ "$COPILOT_HOME" = "$custom" ]
    [ -d "$custom" ]
}

@test "home: rejects traversal outside HOME" {
    _make_profile "review"
    local proj="$TEST_TMP/project-home-traversal"
    mkdir -p "$proj"
    printf 'home:../outside\nreview:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/home-traverse.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/home-traverse.out")" == *"unsafe home"* ]]
    [ -z "${AI_CTX_PROFILES:-}" ]
    [ ! -d "$TEST_TMP/outside" ]
}

@test "home: rejects an absolute path outside allowed roots" {
    _make_profile "review"
    local proj="$TEST_TMP/project-home-absolute"
    mkdir -p "$proj"
    printf 'home:%s\nreview:%s\n' "$TEST_TMP/unrelated" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/home-absolute.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/home-absolute.out")" == *"unsafe home"* ]]
    [ ! -d "$TEST_TMP/unrelated" ]
}

@test "home: rejects filesystem root and empty paths" {
    _make_profile "review"
    local proj="$TEST_TMP/project-home-boundaries"
    mkdir -p "$proj"
    for value in / ''; do
        printf 'home:%s\nreview:%s\n' "$value" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
        local status=0
        _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/home-boundaries.out" 2>&1 || status=$?
        [ "$status" -ne 0 ]
        [[ "$(<"$TEST_TMP/home-boundaries.out")" == *"unsafe home"* || "$(<"$TEST_TMP/home-boundaries.out")" == *"invalid .ctx line"* ]]
    done
}

@test "home: rejects symlink escape outside allowed roots" {
    _make_profile "review"
    local proj="$HOME/project-home-link"
    local outside="$TEST_TMP/outside-link"
    mkdir -p "$proj" "$outside"
    ln -s "$outside" "$proj/link"
    printf 'home:%s\nreview:%s\n' "$proj/link/child" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/home-link.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/home-link.out")" == *"unsafe home"* ]]
    [ ! -d "$outside/child" ]
}

@test "ctx clear --all refuses an unsafe selected home and preserves it" {
    _make_profile "review"
    local victim="$HOME/victim-home"
    local outside="$TEST_TMP/victim-outside"
    mkdir -p "$outside"
    ln -s "$outside" "$victim"
    printf 'important\n' > "$outside/data.txt"
    # Establish a real Mode A activation record, then point COPILOT_HOME and
    # the home override at the unsafe link so clear --all still refuses.
    ctx review >/dev/null
    export COPILOT_HOME="$victim"
    _ctx_auto_load_home_override="$victim"

    run _ctx_clear --all
    [ "$status" -ne 0 ]
    [ -f "$victim/data.txt" ]
    [[ "$output" == *"unsafe home"* ]]
}

@test "home validator rejects HOME and AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT themselves" {
    run _ctx_validate_home_path "$HOME"
    [ "$status" -ne 0 ]
    run _ctx_validate_home_path "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT"
    [ "$status" -ne 0 ]
}

@test "home: directive conflicts with a non-synthetic-home mode and leaves state untouched" {
    _make_profile review
    local proj="$TEST_TMP/project-home-mode-conflict"
    local custom="$HOME/.config/ctx/homes/mode-conflict"
    mkdir -p "$proj"
    printf 'home:%s\nreview:%s\n' "$custom" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
    export COPILOT_HOME=previous-home

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/home-conflict.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/home-conflict.out")" == *"ctx: error:"* ]]
    [[ "$(<"$TEST_TMP/home-conflict.out")" == *"home"* ]]
    [[ "$(<"$TEST_TMP/home-conflict.out")" == *"global-user"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]
    [ ! -d "$custom" ]
}

@test "an invalid copilot mode is rejected before any state change" {
    _make_profile review
    local proj="$TEST_TMP/project-invalid-mode"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    export AI_CTX_PROFILES_COPILOT_MODE=bogus
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
    export COPILOT_HOME=previous-home

    local status=0
    ctx review >"$TEST_TMP/invalid-mode.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/invalid-mode.out")" == *"ctx: error:"* ]]
    [[ "$(<"$TEST_TMP/invalid-mode.out")" == *"synthetic-home"* ]]
    [[ "$(<"$TEST_TMP/invalid-mode.out")" == *"global-user"* ]]
    [[ "$(<"$TEST_TMP/invalid-mode.out")" == *"ephemeral-clean"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]

    status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/invalid-mode-load.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]
    [ ! -e "$proj/project-invalid-mode.code-workspace" ]
}

@test "public ctx clear --all propagates unsafe home failure" {
    _make_profile "review"
    local victim="$HOME/public-victim-home"
    local outside="$TEST_TMP/public-victim-outside"
    mkdir -p "$outside"
    ln -s "$outside" "$victim"
    printf 'important\n' > "$outside/data.txt"
    # Establish a real Mode A activation record, then point COPILOT_HOME and
    # the home override at the unsafe link so clear --all still refuses.
    ctx review >/dev/null
    export COPILOT_HOME="$victim"
    _ctx_auto_load_home_override="$victim"

    run ctx clear --all
    [ "$status" -ne 0 ]
    [ -f "$victim/data.txt" ]
    [[ "$output" == *"unsafe home"* ]]
}

@test "ctx clear --all propagates a valid-home deletion failure" {
    _make_profile "review"
    # Establish a real Mode A activation record; the synthetic home is the
    # deletion target.
    ctx review >/dev/null
    local victim="$COPILOT_HOME"
    [ -d "$victim" ]

    rm() { return 42; }
    run ctx clear --all
    unset -f rm

    [ "$status" -eq 42 ]
    [[ "$output" != *"ctx: removed $victim"* ]]
}

# --- Tests 15-18: "home:" directive, custom COPILOT_HOME location (#7) -----

@test "home: directive in .ctx puts COPILOT_HOME at the custom location" {
    _make_profile "review" "review-skill"

    local proj="$HOME/project-home"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
home: .copilot-ctx
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"

    [ -n "$COPILOT_HOME" ]
    [ "$COPILOT_HOME" = "$proj/.copilot-ctx" ]
    [ -d "$COPILOT_HOME" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
    # Centralized default root must NOT have been used.
    [ ! -d "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review" ]
}

@test ".ctx without a home: directive still uses the centralized default" {
    _make_profile "review" "review-skill"

    local proj="$TEST_TMP/project-nohome"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"

    [ "$COPILOT_HOME" = "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review" ]
}

@test "home: directive with absolute path is used as-is" {
    _make_profile "review" "review-skill"

    local proj="$HOME/project-home-abs"
    local custom_home="$HOME/custom-copilot-home"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
home: $custom_home
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"

    [ "$COPILOT_HOME" = "$custom_home" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
}

@test "ctx clear --all removes the custom home: location, not the centralized one" {
    _make_profile "review" "review-skill"

    local proj="$HOME/project-home-clear"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
home: .copilot-ctx
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"
    local custom_home="$COPILOT_HOME"
    [ -d "$custom_home" ]

    _ctx_clear --all

    [ ! -d "$custom_home" ]
    [ ! -d "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review" ]
}

@test "duplicate home: directive in .ctx is rejected" {
    local proj="$HOME/project-home-dup"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
home: .copilot-ctx-a
home: .copilot-ctx-b
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    run _ctx_load_ctx_file "$proj/.ctx"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate"* ]]
}

@test "generated workspace is marked and removed by clear --all" {
    local proj="$HOME/project-workspace"
    local profile="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    mkdir -p "$proj" "$profile"
    _ctx_update_workspace_file "$proj" review "$profile"

    local workspace="$proj/project-workspace.code-workspace"
    grep -q '"generatedBy": "ctx"' "$workspace"
    unset AI_CTX_PROFILES COPILOT_HOME
    _ctx_auto_load_dir="$proj"
    _ctx_clear --all
    [ ! -e "$workspace" ]
}

@test "pre-existing unmarked workspace is preserved by clear --all" {
    local proj="$HOME/project-workspace-existing"
    local workspace="$proj/project-workspace-existing.code-workspace"
    mkdir -p "$proj"
    printf '{"folders":[{"path":"."}],"settings":{}}\n' > "$workspace"
    unset AI_CTX_PROFILES COPILOT_HOME
    _ctx_auto_load_dir="$proj"
    _ctx_clear --all
    [ -f "$workspace" ]
    grep -q '"folders"' "$workspace"
}

@test "symlink to a marked workspace is preserved by clear --all" {
    local proj="$HOME/project-workspace-symlink"
    local target="$TEST_TMP/marked.code-workspace"
    local workspace="$proj/project-workspace-symlink.code-workspace"
    mkdir -p "$proj"
    printf '{"generatedBy":"ctx"}\n' > "$target"
    ln -s "$target" "$workspace"
    unset AI_CTX_PROFILES COPILOT_HOME
    _ctx_auto_load_dir="$proj"
    _ctx_clear --all
    [ -L "$workspace" ]
}

@test "wrong-case workspace marker is preserved by clear --all" {
    local proj="$HOME/project-workspace-case"
    local workspace="$proj/project-workspace-case.code-workspace"
    mkdir -p "$proj"
    printf '{"generatedBy":"CTX"}\n' > "$workspace"
    unset AI_CTX_PROFILES COPILOT_HOME
    _ctx_auto_load_dir="$proj"
    _ctx_clear --all
    [ -f "$workspace" ]
}

@test "help documents conditional workspace cleanup" {
    run ctx --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"generatedBy"* ]]
    [[ "$output" == *"unmarked"*"invalid"*"linked"*"preserved"* ]]
}

@test "invalid workspace markers are preserved with warnings" {
    local marker
    for marker in malformed false 123 null; do
        local proj="$HOME/project-workspace-marker-$marker"
        local workspace="$proj/project-workspace-marker-$marker.code-workspace"
        mkdir -p "$proj"
        case "$marker" in
            malformed) printf '{not-json}\n' > "$workspace" ;;
            false) printf '{"generatedBy":false}\n' > "$workspace" ;;
            123) printf '{"generatedBy":123}\n' > "$workspace" ;;
            null) printf '{"generatedBy":null}\n' > "$workspace" ;;
        esac
        unset AI_CTX_PROFILES COPILOT_HOME
        _ctx_auto_load_dir="$proj"
        run _ctx_clear --all
        [ "$status" -eq 0 ]
        [[ "$output" == *"preserved unowned workspace"* ]]
        [ -f "$workspace" ]
    done
}

@test "ctx check reports a matching .ctx activation without changing state" {
    local proj="$HOME/project-check"
    local profile="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    _make_profile review review-skill
    mkdir -p "$proj"
    printf 'review:%s\n' "$profile" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    local home="$COPILOT_HOME"
    local before_ctx="$(stat -c '%Y %s' "$proj/.ctx")"
    cd "$proj"
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS AI_CTX_PROFILES"* ]]
    [[ "$output" == *"ctx check: PASS"* ]]
    [ "$home" = "$COPILOT_HOME" ]
    [ "$(stat -c '%Y %s' "$proj/.ctx")" = "$before_ctx" ]
}

@test "ctx check detects environment and link drift without repairing it" {
    local proj="$HOME/project-check-drift"
    local profile="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    _make_profile review review-skill
    mkdir -p "$proj"
    printf 'review:%s\n' "$profile" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    local home="$COPILOT_HOME"
    cd "$proj"
    export AI_CTX_PROFILES=wrong
    rm -f "$home/settings.json"
    printf 'drift' > "$home/settings.json"
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL AI_CTX_PROFILES"* ]]
    [[ "$output" == *"CHECK FAIL link:settings.json"* ]]
    [ -f "$home/settings.json" ]
    [ ! -L "$home/settings.json" ]
}

@test "ctx check succeeds with no nearest .ctx and does not clear the shell" {
    export AI_CTX_PROFILES=manual
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=manual-dir
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"no .ctx file found"* ]]
    [ "$AI_CTX_PROFILES" = manual ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = manual-dir ]
}

@test "ctx check detects workspace folder drift" {
    local proj="$HOME/project-check-workspace"
    local profile="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    _make_profile review
    mkdir -p "$proj"
    printf 'review:%s\n' "$profile" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    printf '{"generatedBy":"ctx","folders":[]}' > "$proj/project-check-workspace.code-workspace"
    cd "$proj"
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL workspace"* ]]
}

@test "ctx check uses a fake copilot skill list without auth or network" {
    local proj="$HOME/project-check-copilot"
    _make_profile review review-skill
    mkdir -p "$proj" "$TEST_TMP/bin"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    cd "$proj"
    cat > "$TEST_TMP/bin/copilot" <<'EOF'
#!/usr/bin/env bash
printf 'called' > "$TEST_TMP/copilot-called"
[ "$1" = skill ] && [ "$2" = list ] && [ "$3" = --json ] || exit 9
printf '{"skills":[{"name":"review-skill"}]}\n'
EOF
    chmod +x "$TEST_TMP/bin/copilot"
    PATH="$TEST_TMP/bin:$PATH" run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK SKIP skills: copilot probe disabled in read-only check"* ]]
    [ ! -e "$TEST_TMP/copilot-called" ]
}


@test "direct ctx check preserves diagnostics and returns a scalar status" {
    local proj="$HOME/project-check-direct"
    _make_profile review review-skill
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    cd "$proj"
    ctx check >/dev/null
    [ "$?" -eq 0 ]
    export AI_CTX_PROFILES=wrong
    if ctx check >/dev/null; then false; else [ "$?" -eq 1 ]; fi
}

@test "ctx check accepts hardlink fallback for shared files" {
    local proj="$HOME/project-check-hardlink"
    _make_profile review
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    rm -f "$COPILOT_HOME/settings.json"
    : > "$CTX_COPILOT_DIR/settings.json"
    ln "$CTX_COPILOT_DIR/settings.json" "$COPILOT_HOME/settings.json"
    cd "$proj"
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"ctx check: PASS"* ]]
}

@test "ctx check skips malformed optional copilot JSON" {
    local proj="$HOME/project-check-copilot-malformed"
    _make_profile review review-skill
    mkdir -p "$proj" "$TEST_TMP/bin"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    rm -f "$proj/project-check-copilot-malformed.code-workspace"
    cd "$proj"
    cat > "$TEST_TMP/bin/copilot" <<'EOF'
#!/usr/bin/env bash
printf '{not-json}\n'
EOF
    chmod +x "$TEST_TMP/bin/copilot"
    PATH="$TEST_TMP/bin:$PATH" run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK SKIP skills: copilot probe disabled in read-only check"* ]]
}

@test "ctx check uses python fallback for optional copilot JSON" {
    local proj="$HOME/project-check-copilot-python"
    _make_profile review review-skill
    mkdir -p "$proj" "$TEST_TMP/bin"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    rm -f "$proj/project-check-copilot-python.code-workspace"
    cd "$proj"
    cat > "$TEST_TMP/bin/copilot" <<'EOF'
#!/usr/bin/env bash
printf '{"skills":[{"name":"review-skill"}]}\n'
EOF
    cat > "$TEST_TMP/bin/python" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'review-skill\n'
EOF
    chmod +x "$TEST_TMP/bin/copilot" "$TEST_TMP/bin/python"
    PATH="$TEST_TMP/bin:/usr/bin" run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK SKIP skills: copilot probe disabled in read-only check"* ]]
}

@test "ctx check reports optional copilot skills in deterministic order" {
    local proj="$HOME/project-check-copilot-order"
    _make_profile review zeta-skill
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills/alpha-skill" "$proj" "$TEST_TMP/bin"
    printf '%s\n' '---' 'name: alpha-skill' 'description: alpha' '---' > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills/alpha-skill/SKILL.md"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    rm -f "$proj/project-check-copilot-order.code-workspace"
    cat > "$TEST_TMP/bin/copilot" <<'EOF'
#!/usr/bin/env bash
printf '[{"name":"zeta-skill"},{"name":"alpha-skill"}]\n'
EOF
    chmod +x "$TEST_TMP/bin/copilot"
    cd "$proj"
    PATH="$TEST_TMP/bin:$PATH" run ctx check
    [ "$status" -eq 0 ]
    local first="$output"
    PATH="$TEST_TMP/bin:$PATH" run ctx check
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
    [[ "$output" == *"CHECK SKIP skills: copilot probe disabled in read-only check"* ]]
}

@test "ctx check skips workspace audit when no python interpreter exists" {
    local proj="$HOME/project-check-workspace-no-python"
    _make_profile review
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    printf '{"generatedBy":"ctx","folders":[]}' > "$proj/project-check-workspace-no-python.code-workspace"
    cd "$proj"
    command() {
        if [ "$1" = -v ] && { [ "$2" = python3 ] || [ "$2" = python ]; }; then return 1; fi
        builtin command "$@"
    }
    export -f command
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK SKIP workspace: no python interpreter available"* ]]
}

@test "ctx check treats mixed-case HOME like the activation parser" {
    local proj="$HOME/project-check-home-case"
    local override="$HOME/custom-copilot-home"
    _make_profile review
    mkdir -p "$proj" "$override"
    printf 'HOME:%s\nreview:%s\n' "$override" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    cd "$proj"
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS COPILOT_HOME"* ]]
}

@test "activation treats mixed-case HOME as a directive and excludes it from AI_CTX_PROFILES" {
    local proj="$HOME/project-activation-home-case"
    local override="$HOME/custom-copilot-home"
    _make_profile review
    mkdir -p "$proj"
    printf 'HoMe:%s\nreview:%s\n' "$override" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    _ctx_load_ctx_file "$proj/.ctx"

    [ "$COPILOT_HOME" = "$override" ]
    [ "$AI_CTX_PROFILES" = "review" ]
    [[ "$AI_CTX_PROFILES" != *"HoMe"* ]]
}

@test "zsh supports mixed-case HOME in .ctx activation and ctx check" {
    if ! command -v zsh >/dev/null 2>&1; then
        skip "zsh is not installed"
    fi

    local proj="$HOME/project-zsh-home-case"
    local override="$HOME/custom-zsh-copilot-home"
    _make_profile review
    mkdir -p "$proj" "$override"
    printf 'HoMe:%s\nreview:%s\n' "$override" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    local zsh_path
    zsh_path="$(command -v zsh)"
    run env PATH="/usr/local/bin:/usr/bin:/bin:$PATH" "$zsh_path" -f -c '
        source "$1"
        _ctx_load_ctx_file "$2" >/dev/null || exit
        rm -f "$4/project-zsh-home-case.code-workspace"
        [ "$COPILOT_HOME" = "$3" ] || exit
        [ "$AI_CTX_PROFILES" = review ] || exit
        cd "$4" || exit
        ctx check
    ' -- "$CTX_SRC" "$proj/.ctx" "$override" "$proj"

    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS COPILOT_HOME"* ]]
    [[ "$output" == *"ctx check: PASS"* ]]
}

@test "reactivation removes a dangling stale skill symlink" {
    local proj="$HOME/project-dangling-skill"
    _make_profile review
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    ln -s "$TEST_TMP/missing-skill" "$COPILOT_HOME/skills/stale-skill"
    [ -L "$COPILOT_HOME/skills/stale-skill" ]

    _ctx_load_ctx_file "$proj/.ctx" >/dev/null

    [ ! -e "$COPILOT_HOME/skills/stale-skill" ]
    [ ! -L "$COPILOT_HOME/skills/stale-skill" ]
}


# --- Issue #4 parser parity and profile-boundary regressions ----------------

@test "ctx check shares .ctx parsing for profiles, direct paths, and home directives without writes" {
    _make_profile review review-skill
    local direct="$TEST_TMP/direct-check"
    local proj="$HOME/project-check-parser-parity"
    local override="$HOME/check-parser-home"
    mkdir -p "$direct" "$proj" "$override"
    printf 'HoMe:%s\nreview:@profile\nlocal:%s\n' "$override" "$direct" > "$proj/.ctx"

    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    local before_ctx="$AI_CTX_PROFILES" before_dirs="$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" before_home="$COPILOT_HOME"
    local before_file="$(stat -c '%Y %s' "$proj/.ctx")"
    cd "$proj"
    run ctx check

    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS AI_CTX_PROFILES"* ]]
    [ "$AI_CTX_PROFILES" = "$before_ctx" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$before_dirs" ]
    [ "$COPILOT_HOME" = "$before_home" ]
    [ "$(stat -c '%Y %s' "$proj/.ctx")" = "$before_file" ]
}

@test "Mode A default-equivalence: unset and explicit synthetic-home are byte-identical for current and check" {
    _make_profile review review-skill
    local proj="$HOME/project-mode-default-equivalence"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    unset AI_CTX_PROFILES_COPILOT_MODE
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    run ctx current
    [ "$status" -eq 0 ]
    local current_unset="$output"
    [[ "$current_unset" == *"Mode: synthetic-home"* ]]

    _ctx_clear >/dev/null
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    run ctx current
    [ "$status" -eq 0 ]
    local current_explicit="$output"
    [[ "$current_explicit" == *"Mode: synthetic-home"* ]]
    [ "$current_explicit" = "$current_unset" ]

    unset AI_CTX_PROFILES_COPILOT_MODE
    cd "$proj"
    run ctx check
    [ "$status" -eq 0 ]
    local check_unset="$output"
    [[ "$check_unset" == *"CHECK PASS COPILOT_MODE"* ]]

    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    run ctx check
    [ "$status" -eq 0 ]
    local check_explicit="$output"
    [[ "$check_explicit" == *"CHECK PASS COPILOT_MODE"* ]]
    [ "$check_explicit" = "$check_unset" ]
}

@test "ctx check rejects activation-invalid labels, targets, and home directives read-only" {
    _make_profile review
    local proj="$HOME/project-check-parser-invalid"
    local duplicate="$TEST_TMP/duplicate-target"
    mkdir -p "$proj" "$duplicate"
    printf 'review:%s\nReview:%s\nhome:%s\nHOME:%s\n' "$duplicate" "$duplicate" "$HOME/check-a" "$HOME/check-b" > "$proj/.ctx"
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
    local before_file="$(stat -c '%Y %s' "$proj/.ctx")"
    cd "$proj"
    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate .ctx entry label"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$(stat -c '%Y %s' "$proj/.ctx")" = "$before_file" ]
}

@test "manual and @profile traversal cannot escape profiles before state changes" {
    _make_profile review
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/escaped"
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs

    local status=0
    ctx ../escaped >"$TEST_TMP/trav-manual.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/trav-manual.out")" == *"invalid profile identifier"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]

    local proj="$HOME/project-profile-traversal"
    mkdir -p "$proj"
    printf '../escaped:@profile\nreview:@profile\n' > "$proj/.ctx"
    status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/trav-ctx.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/trav-ctx.out")" == *"invalid profile identifier"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
}


@test "ctx check rejects canonical duplicate targets read-only" {
    local proj="$HOME/project-check-canonical-target"
    local target="$TEST_TMP/canonical-target"
    mkdir -p "$proj" "$target"
    printf 'one:%s\ntwo:%s/.\n' "$target" "$target" > "$proj/.ctx"
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
    cd "$proj"
    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"same directory"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
}


# --- noautoload flag and ctx load command (issue #27) ----------------------

@test "noautoload flag: _ctx_load_ctx_file still loads a noautoload .ctx file" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-noautoload"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
noautoload
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"
    [ "$AI_CTX_PROFILES" = "review" ]
    [[ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" == *"profiles/review"* ]]
}

@test "noautoload flag: auto-load hook skips a .ctx file with noautoload" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-noautoload-hook"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
noautoload
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    cd "$proj"
    _ctx_auto_load_hook
    [ -z "${AI_CTX_PROFILES:-}" ]
    [ -z "$_ctx_auto_load_dir" ]
}

@test "noautoload flag: case-insensitive (NOAUTOLOAD is accepted)" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-noautoload-upper"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
NOAUTOLOAD
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    _ctx_load_ctx_file "$proj/.ctx"
    [ "$AI_CTX_PROFILES" = "review" ]

    cd "$proj"
    unset AI_CTX_PROFILES COPILOT_CUSTOM_INSTRUCTIONS_DIRS COPILOT_HOME
    _ctx_auto_load_dir=""
    _ctx_auto_load_hook
    [ -z "${AI_CTX_PROFILES:-}" ]
}

@test "noautoload flag: hook clears context when flag added after auto-load" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-noautoload-added-later"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    cd "$proj"
    _ctx_auto_load_hook
    [ "$AI_CTX_PROFILES" = "review" ]
    [ "$_ctx_auto_load_dir" = "$proj" ]

    cat > "$proj/.ctx" <<EOF
noautoload
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF
    _ctx_auto_load_hook
    [ -z "${AI_CTX_PROFILES:-}" ]
    [ -z "$_ctx_auto_load_dir" ]
}

@test "ctx load: loads a .ctx file via explicit path" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-ctx-load"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    ctx load "$proj/.ctx"
    [ "$AI_CTX_PROFILES" = "review" ]
    [[ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" == *"profiles/review"* ]]
    [ "$_ctx_auto_load_dir" = "$proj" ]
}

@test "ctx load: loads a noautoload .ctx file that the hook would skip" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-ctx-load-noautoload"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
noautoload
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    ctx load "$proj/.ctx"
    [ "$AI_CTX_PROFILES" = "review" ]
    [ "$_ctx_auto_load_dir" = "$proj" ]
}

@test "ctx load: relative path resolves against PWD" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-ctx-load-relative"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    cd "$proj"
    ctx load .ctx
    [ "$AI_CTX_PROFILES" = "review" ]
    [ "$_ctx_auto_load_dir" = "$proj" ]
}

@test "ctx load: sets state so ctx clear --all cleans up artifacts" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-ctx-load-clear-all"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF

    ctx load "$proj/.ctx"
    local home_dir="$COPILOT_HOME"
    [ -d "$home_dir" ]

    ctx clear --all
    [ ! -d "$home_dir" ]
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

@test "ctx load: bypasses noautoload but still validates the .ctx file" {
    local proj="$TEST_TMP/project-ctx-load-invalid"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
noautoload
badline-no-colon
EOF

    run ctx load "$proj/.ctx"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid .ctx line"* ]]
}

# --- Group 3: Mode B (global-user) environment/home semantics --------------

@test "Mode B: COPILOT_HOME is left exactly as-is across activation and clear" {
    _make_profile review review-skill
    _make_profile test test-skill
    export AI_CTX_PROFILES_COPILOT_MODE=global-user

    # (a) unset before activation -> still unset after
    unset COPILOT_HOME
    ctx review
    [ -z "${COPILOT_HOME:-}" ]
    _ctx_clear
    [ -z "${COPILOT_HOME:-}" ]

    # (b) custom user value byte-identical after activation
    export COPILOT_HOME="$TEST_TMP/custom-home"
    ctx review
    [ "$COPILOT_HOME" = "$TEST_TMP/custom-home" ]
    _ctx_clear
    [ "$COPILOT_HOME" = "$TEST_TMP/custom-home" ]

    # (c) leftover synthetic home from a prior Mode A activation is untouched
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx review
    local leftover="$COPILOT_HOME"
    [ -n "$leftover" ]
    [ -d "$leftover" ]
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    ctx test
    [ "$COPILOT_HOME" = "$leftover" ]

    # clear --all under Mode B: exits 0, COPILOT_HOME unchanged, workspace
    # artifact still cleaned up
    local proj="$TEST_TMP/project-b-clear-all"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx"
    local before_home="$COPILOT_HOME"
    local workspace="$proj/project-b-clear-all.code-workspace"
    [ -f "$workspace" ]
    _ctx_clear --all
    [ "$?" -eq 0 ]
    [ "$COPILOT_HOME" = "$before_home" ]
    [ ! -e "$workspace" ]
}

@test "Mode B: COPILOT_SKILLS_DIRS is unset (not empty) when no skills dirs exist" {
    _make_profile review
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    ctx review
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]

    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    _ctx_clear
    ctx review
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]
}

@test "Mode B: COPILOT_SKILLS_DIRS keeps stable order and rejects comma paths" {
    _make_profile alpha alpha-skill
    _make_profile beta beta-skill
    export AI_CTX_PROFILES_COPILOT_MODE=global-user

    # (a) existing skills dirs listed in the same stable order as the entries
    ctx alpha beta
    [ "$COPILOT_SKILLS_DIRS" = "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/alpha/.github/skills,$AI_CTX_PROFILES_CONFIG_ROOT/profiles/beta/.github/skills" ]

    # fully replaced (not appended) on the next activation
    ctx beta
    [ "$COPILOT_SKILLS_DIRS" = "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/beta/.github/skills" ]

    # (b) a resolved path with a literal comma is rejected before any state change
    local comma_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/a,b"
    mkdir -p "$comma_dir/.github/skills"
    export AI_CTX_PROFILES=previous
    export COPILOT_HOME=previous-home
    export COPILOT_SKILLS_DIRS=previous-skills

    local status=0
    ctx a,b >"$TEST_TMP/comma.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/comma.out")" == *"comma"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_HOME" = previous-home ]
    [ "$COPILOT_SKILLS_DIRS" = previous-skills ]
}

@test "Mode B/C -> Mode A unsets a session-set COPILOT_SKILLS_DIRS but never a user value" {
    _make_profile review review-skill
    _make_profile test test-skill
    export AI_CTX_PROFILES_COPILOT_MODE=global-user

    # B activation sets COPILOT_SKILLS_DIRS (ctx-owned this session)
    ctx review
    [ -n "$COPILOT_SKILLS_DIRS" ]

    # switch into Mode A -> unset
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx test
    [ -z "${COPILOT_SKILLS_DIRS:-}" ]
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]

    # fresh session state: a user-set value is never touched by Mode A
    _ctx_skills_dirs_owned=0
    export COPILOT_SKILLS_DIRS=my-own-value
    ctx review
    [ "$COPILOT_SKILLS_DIRS" = my-own-value ]
}

# --- Group 4: Mode C (ephemeral-clean) lifecycle ----------------------------

@test "Mode C: every activation gets a fresh unique ephemeral home; clear never deletes" {
    _make_profile review review-skill
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean

    # (a) reactivating the same profile (no clear between) yields a different
    # path, and BOTH ephemeral dirs stay on disk - Mode C never deletes
    ctx review
    local home1="$COPILOT_HOME"
    ctx review
    local home2="$COPILOT_HOME"
    [ -n "$home1" ]
    [ -n "$home2" ]
    [ "$home1" != "$home2" ]
    [ -d "$home1" ]
    [ -d "$home2" ]

    # (b) plain ctx clear unsets COPILOT_HOME but leaves home2 + marker on disk
    touch "$home2/marker"
    ctx clear >"$TEST_TMP/c-clear.out" 2>&1
    [ -z "${COPILOT_HOME:-}" ]
    [ -f "$home2/marker" ]
    [ -d "$home2" ]

    # (c) ctx clear --all reports the retained path, still never deletes, and
    # the common workspace/settings cleanup still runs
    local proj="$TEST_TMP/project-c-clear-all"
    mkdir -p "$proj"
    cat > "$proj/.ctx" <<EOF
review:$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review
EOF
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx"
    local home3="$COPILOT_HOME"
    touch "$home3/marker"
    local workspace="$proj/project-c-clear-all.code-workspace"
    [ -f "$workspace" ]
    ctx clear --all >"$TEST_TMP/c-clear-all.out" 2>&1
    local clear_all_status=$?
    local clear_all_out
    clear_all_out="$(<"$TEST_TMP/c-clear-all.out")"
    [ "$clear_all_status" -eq 0 ]
    [ -z "${COPILOT_HOME:-}" ]
    [ -f "$home3/marker" ]
    [ -d "$home3" ]
    [[ "$clear_all_out" == *"retained"* ]]
    [[ "$clear_all_out" == *"not deleted"* ]]
    [[ "$clear_all_out" == *"$home3"* ]]
    [[ "$clear_all_out" == *"consumes disk"* ]]
    [[ "$clear_all_out" == *"manually removed"* ]]
    [[ "$clear_all_out" == *"responsibility"* ]]
    [ ! -e "$workspace" ]
}

# --- Group 5: mode-aware clear/current/check --------------------------------

@test "Group5 5.3: clear per mode - B leaves COPILOT_HOME, C unsets/retains, A deletes, common cleanup runs" {
    _make_profile review review-skill
    _make_profile test test-skill

    # Mode A: existing delete behavior remains (--all removes the synthetic home)
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx review >/dev/null
    local a_home="$COPILOT_HOME"
    [ -d "$a_home" ]
    ctx clear --all >/dev/null
    [ ! -d "$a_home" ]
    [ -z "${COPILOT_HOME:-}" ]

    # Mode B: plain clear and clear --all leave a pre-set COPILOT_HOME
    # byte-identical and run the common workspace cleanup
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    export COPILOT_HOME="$TEST_TMP/b-custom-home"
    local proj_b="$TEST_TMP/project-b-clear"
    mkdir -p "$proj_b"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj_b/.ctx"
    cd "$proj_b"
    ctx load "$proj_b/.ctx" >/dev/null
    [ "$COPILOT_HOME" = "$TEST_TMP/b-custom-home" ]
    ctx clear
    [ "$COPILOT_HOME" = "$TEST_TMP/b-custom-home" ]
    ctx load "$proj_b/.ctx" >/dev/null
    local ws_b="$proj_b/project-b-clear.code-workspace"
    [ -f "$ws_b" ]
    ctx clear --all
    [ "$?" -eq 0 ]
    [ "$COPILOT_HOME" = "$TEST_TMP/b-custom-home" ]
    [ ! -e "$ws_b" ]
    unset COPILOT_HOME

    # Mode C: plain clear and clear --all unset COPILOT_HOME, retain path +
    # marker, print the retained notice (incl. on plain clear), and clean the
    # common workspace artifact
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    local proj_c="$TEST_TMP/project-c-clear"
    mkdir -p "$proj_c"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj_c/.ctx"
    cd "$proj_c"
    ctx load "$proj_c/.ctx" >/dev/null
    local c_home="$COPILOT_HOME"
    touch "$c_home/marker"
    ctx clear >"$TEST_TMP/c-clear-53.out" 2>&1
    [ -z "${COPILOT_HOME:-}" ]
    [ -f "$c_home/marker" ]
    [ -d "$c_home" ]
    [[ "$(<"$TEST_TMP/c-clear-53.out")" == *"retained"* ]]
    [[ "$(<"$TEST_TMP/c-clear-53.out")" == *"not deleted"* ]]
    [[ "$(<"$TEST_TMP/c-clear-53.out")" == *"$c_home"* ]]
    [[ "$(<"$TEST_TMP/c-clear-53.out")" == *"consumes disk"* ]]
    [[ "$(<"$TEST_TMP/c-clear-53.out")" == *"manually removed"* ]]
    [[ "$(<"$TEST_TMP/c-clear-53.out")" == *"responsibility"* ]]

    ctx load "$proj_c/.ctx" >/dev/null
    local c_home2="$COPILOT_HOME"
    touch "$c_home2/marker"
    local ws_c="$proj_c/project-c-clear.code-workspace"
    [ -f "$ws_c" ]
    ctx clear --all >"$TEST_TMP/c-clear-all-53.out" 2>&1
    [ "$?" -eq 0 ]
    [ -z "${COPILOT_HOME:-}" ]
    [ -f "$c_home2/marker" ]
    [ -d "$c_home2" ]
    [ ! -e "$ws_c" ]
    [[ "$(<"$TEST_TMP/c-clear-all-53.out")" == *"retained"* ]]
    [[ "$(<"$TEST_TMP/c-clear-all-53.out")" == *"consumes disk"* ]]
    [[ "$(<"$TEST_TMP/c-clear-all-53.out")" == *"manually removed"* ]]
    [[ "$(<"$TEST_TMP/c-clear-all-53.out")" == *"responsibility"* ]]
}

@test "Group5 5.4: current/check/clear use the recorded active mode, not a stale selector" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-stale-selector"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    cd "$proj"

    # Mode C activation, then change the selector to Mode B
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    ctx load "$proj/.ctx" >/dev/null
    local c_home="$COPILOT_HOME"
    [ -n "$c_home" ]
    export AI_CTX_PROFILES_COPILOT_MODE=global-user

    run ctx current
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: ephemeral-clean"* ]]
    [[ "$output" != *"Mode: global-user"* ]]

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_MODE"* ]]
    [[ "$output" == *"does not match recorded active mode ephemeral-clean"* ]]

    # clear uses the recorded Mode C: unsets COPILOT_HOME, retains the path
    ctx clear >"$TEST_TMP/clear-54.out" 2>&1
    [ -z "${COPILOT_HOME:-}" ]
    [ -d "$c_home" ]
    [[ "$(<"$TEST_TMP/clear-54.out")" == *"$c_home"* ]]
    [[ "$(<"$TEST_TMP/clear-54.out")" == *"consumes disk"* ]]
    [[ "$(<"$TEST_TMP/clear-54.out")" == *"manually removed"* ]]
    [[ "$(<"$TEST_TMP/clear-54.out")" == *"responsibility"* ]]

    # Mode B activation, then change the selector to Mode C
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    export COPILOT_HOME="$TEST_TMP/b-stale-home"
    ctx load "$proj/.ctx" >/dev/null
    [ "$COPILOT_HOME" = "$TEST_TMP/b-stale-home" ]
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean

    run ctx current
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: global-user"* ]]
    [[ "$output" != *"Mode: ephemeral-clean"* ]]

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_MODE"* ]]

    # clear uses the recorded Mode B: COPILOT_HOME is left exactly as-is
    ctx clear >/dev/null
    [ "$COPILOT_HOME" = "$TEST_TMP/b-stale-home" ]
}

@test "Group5 5.5: check per mode - B recorded-home, C path-exists, SKIPs, unknown foreign state" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-check-modes"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    # (a) no .ctx remains a successful no-op
    local noctx="$TEST_TMP/noctx"
    mkdir -p "$noctx"
    ( cd "$noctx" && run ctx check; [ "$status" -eq 0 ]; [[ "$output" == *"no .ctx file found"* ]] )

    cd "$proj"
    export AI_CTX_PROFILES_COPILOT_MODE=global-user

    # (b) Mode B originally-unset: PASS; drift -> FAIL; link/skill checks SKIP
    unset COPILOT_HOME
    ctx load "$proj/.ctx" >/dev/null
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS COPILOT_HOME"* ]]
    [[ "$output" == *"CHECK SKIP link:settings.json"* ]]
    [[ "$output" == *"CHECK SKIP skill:review-skill"* ]]

    export COPILOT_HOME="$TEST_TMP/drift-home"
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_HOME"* ]]
    unset COPILOT_HOME

    # (c) Mode B originally-set: PASS when exact, FAIL on change
    export COPILOT_HOME="$TEST_TMP/b-home"
    ctx load "$proj/.ctx" >/dev/null
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS COPILOT_HOME"* ]]
    export COPILOT_HOME="$TEST_TMP/b-home-changed"
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_HOME"* ]]
    unset COPILOT_HOME

    # (d) Mode C: real dir PASS; removed FAIL; symlink FAIL; never inspects contents
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    ctx load "$proj/.ctx" >/dev/null
    local c_home="$COPILOT_HOME"
    touch "$c_home/content-file"
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS COPILOT_HOME"* ]]
    [[ "$output" == *"CHECK SKIP link:settings.json"* ]]
    [[ "$output" == *"CHECK SKIP skill:review-skill"* ]]
    [ -f "$c_home/content-file" ]

    rm -rf "$c_home"
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_HOME"* ]]

    ctx load "$proj/.ctx" >/dev/null
    local c_home2="$COPILOT_HOME"
    rm -rf "$c_home2"
    mkdir -p "$TEST_TMP/c-target"
    ln -s "$TEST_TMP/c-target" "$c_home2"
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_HOME"* ]]

    # (e) foreign env state with no matching activation record -> CHECK UNKNOWN,
    # never deleted, unknown alone does not become a false FAIL
    mkdir -p "$TEST_TMP/foreign-home" "$TEST_TMP/foreign-skills"
    ctx load "$proj/.ctx" >/dev/null
    _ctx_reset_active_record
    export COPILOT_HOME="$TEST_TMP/foreign-home"
    export COPILOT_SKILLS_DIRS="$TEST_TMP/foreign-skills"
    run ctx current
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: <unknown>"* ]]
    [[ "$output" == *"COPILOT_HOME=$TEST_TMP/foreign-home (unknown)"* ]]
    [ -d "$TEST_TMP/foreign-home" ]
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK UNKNOWN COPILOT_MODE"* ]]
    [[ "$output" == *"CHECK UNKNOWN COPILOT_HOME"* ]]
    [[ "$output" == *"CHECK UNKNOWN COPILOT_SKILLS_DIRS"* ]]
    [ -d "$TEST_TMP/foreign-home" ]
    [ -d "$TEST_TMP/foreign-skills" ]
}

@test "Group5 5.6: Mode C replacement reports retained path only on success; old path remains" {
    _make_profile review review-skill
    _make_profile test test-skill
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean

    # C -> C (same profile reactivated): notice for the old path, old dir kept
    ctx review >/dev/null
    local old_home="$COPILOT_HOME"
    touch "$old_home/marker"
    ctx review >"$TEST_TMP/repl-cc.out" 2>&1
    [[ "$(<"$TEST_TMP/repl-cc.out")" == *"retained"* ]]
    [[ "$(<"$TEST_TMP/repl-cc.out")" == *"$old_home"* ]]
    [[ "$(<"$TEST_TMP/repl-cc.out")" == *"consumes disk"* ]]
    [[ "$(<"$TEST_TMP/repl-cc.out")" == *"manually removed"* ]]
    [[ "$(<"$TEST_TMP/repl-cc.out")" == *"responsibility"* ]]
    [ -f "$old_home/marker" ]
    [ -d "$old_home" ]
    local new_home="$COPILOT_HOME"
    [ "$old_home" != "$new_home" ]

    # C -> B (switch selector): notice for the old path, COPILOT_HOME kept as-is
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    ctx test >"$TEST_TMP/repl-cb.out" 2>&1
    [[ "$(<"$TEST_TMP/repl-cb.out")" == *"retained"* ]]
    [[ "$(<"$TEST_TMP/repl-cb.out")" == *"$new_home"* ]]
    [[ "$(<"$TEST_TMP/repl-cb.out")" == *"consumes disk"* ]]
    [[ "$(<"$TEST_TMP/repl-cb.out")" == *"manually removed"* ]]
    [[ "$(<"$TEST_TMP/repl-cb.out")" == *"responsibility"* ]]
    [ "$COPILOT_HOME" = "$new_home" ]
    [ -d "$new_home" ]

    # Failed replacement (temp-home creation fails): no notice, previous state
    # and session record are untouched
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    mktemp() { return 1; }
    export -f mktemp
    local status=0
    ctx test >"$TEST_TMP/repl-fail.out" 2>&1 || status=$?
    unset -f mktemp
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/repl-fail.out")" != *"retained"* ]]
    [ "$AI_CTX_PROFILES" = test ]
    [ "$COPILOT_HOME" = "$new_home" ]
    [ "$_ctx_active_mode" = "global-user" ]
    [ "$_ctx_active_context" = test ]
}

@test "Group5 5.7: Mode C temp-home failure leaves env, session record, and workspace files untouched" {
    _make_profile review review-skill
    _make_profile test test-skill
    local proj="$TEST_TMP/project-c-preflight"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean

    # manual entry path: prior activation, then force temp-home failure
    ctx review >/dev/null
    local old_profiles="$AI_CTX_PROFILES"
    local old_dirs="$COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    local old_home="$COPILOT_HOME"
    mktemp() { return 1; }
    export -f mktemp
    local status=0
    ctx test >"$TEST_TMP/c-fail-manual.out" 2>&1 || status=$?
    unset -f mktemp
    [ "$status" -ne 0 ]
    [ "$AI_CTX_PROFILES" = "$old_profiles" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$old_dirs" ]
    [ "$COPILOT_HOME" = "$old_home" ]
    [ "$_ctx_active_mode" = "ephemeral-clean" ]
    [ "$_ctx_active_home_value" = "$old_home" ]

    # load entry path: force temp-home failure; env, record, and the adjacent
    # workspace file all remain unchanged
    cd "$proj"
    ctx load "$proj/.ctx" >/dev/null
    local l_profiles="$AI_CTX_PROFILES"
    local l_dirs="$COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    local l_home="$COPILOT_HOME"
    local ws="$proj/project-c-preflight.code-workspace"
    [ -f "$ws" ]
    local ws_before
    ws_before="$(stat -c '%Y %s' "$ws")"
    mktemp() { return 1; }
    export -f mktemp
    status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/c-fail-load.out" 2>&1 || status=$?
    unset -f mktemp
    [ "$status" -ne 0 ]
    [ "$AI_CTX_PROFILES" = "$l_profiles" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$l_dirs" ]
    [ "$COPILOT_HOME" = "$l_home" ]
    [ "$_ctx_active_mode" = "ephemeral-clean" ]
    [ "$_ctx_active_home_value" = "$l_home" ]
    [ "$(stat -c '%Y %s' "$ws")" = "$ws_before" ]
}

@test "Group5 5.8: clear --all with no activation record treats home as unknown and never deletes" {
    _make_profile review
    local proj="$TEST_TMP/project-clear-unknown"
    mkdir -p "$proj"
    # Foreign context whose COPILOT_HOME happens to equal the otherwise-computed
    # synthetic-home path, but with NO ctx activation record: clear must not
    # guess Mode A or delete it.
    local foreign_home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    mkdir -p "$foreign_home"
    touch "$foreign_home/marker"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    local workspace="$proj/project-clear-unknown.code-workspace"
    printf '{"generatedBy":"ctx"}\n' > "$workspace"
    export AI_CTX_PROFILES=review
    export COPILOT_HOME="$foreign_home"
    _ctx_auto_load_dir="$proj"

    run ctx clear --all

    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown"* ]]
    [[ "$output" == *"no matching activation record"* ]]
    [[ "$output" != *"synthetic-home"* ]]
    [ -d "$foreign_home" ]
    [ -f "$foreign_home/marker" ]
    [ ! -e "$workspace" ]
}

@test "Group5 5.9: Mode C owns COPILOT_SKILLS_DIRS across clear and Mode A switch" {
    _make_profile review review-skill
    _make_profile test
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean

    # C activation with actual skills: the var is set and ctx-owned
    ctx review
    [ -n "$COPILOT_SKILLS_DIRS" ]
    [ "$_ctx_skills_dirs_owned" -eq 1 ]

    # ctx clear unsets the owned var and resets the flag
    ctx clear
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]
    [ "$_ctx_skills_dirs_owned" -eq 0 ]

    # re-activate C, then switch into Mode A: the owned var is unset
    ctx review
    [ -n "$COPILOT_SKILLS_DIRS" ]
    [ "$_ctx_skills_dirs_owned" -eq 1 ]
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx test
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]
    [ "$_ctx_skills_dirs_owned" -eq 0 ]

    # B/C ownership is flag-true even when no skills dirs exist (var unset)
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    _ctx_clear
    ctx test
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]
    [ "$_ctx_skills_dirs_owned" -eq 1 ]

    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    _ctx_clear
    ctx test
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]
    [ "$_ctx_skills_dirs_owned" -eq 1 ]
}

# --- Group 5 remediation (PR #45 review): findings 1, 3, 4, 5 -----------------

@test "Group5 6.1: Mode C changed/unset/foreign COPILOT_HOME is not misattributed" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-c-home-drift"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    cd "$proj"
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    ctx load "$proj/.ctx" >/dev/null
    local rec_home="$COPILOT_HOME"
    touch "$rec_home/marker"
    [ -n "$rec_home" ]

    # (a) changed value: current reports unknown, check FAILs, clear preserves
    # the user's value while still reporting the recorded path as retained
    export COPILOT_HOME="$TEST_TMP/user-replacement"
    run ctx current
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: <unknown>"* ]]
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_HOME"* ]]
    ctx clear >"$TEST_TMP/clear-drift.out" 2>&1
    [ "$COPILOT_HOME" = "$TEST_TMP/user-replacement" ]
    [[ "$(<"$TEST_TMP/clear-drift.out")" == *"retained"* ]]
    [[ "$(<"$TEST_TMP/clear-drift.out")" == *"changed"* ]]
    [ -d "$rec_home" ]
    [ -f "$rec_home/marker" ]

    # (b) unset value: check FAILs, clear leaves it unset but reports retained
    ctx load "$proj/.ctx" >/dev/null
    local rec_home2="$COPILOT_HOME"
    unset COPILOT_HOME
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_HOME"* ]]
    ctx clear >"$TEST_TMP/clear-unset.out" 2>&1
    [ -z "${COPILOT_HOME:-}" ]
    [[ "$(<"$TEST_TMP/clear-unset.out")" == *"retained"* ]]
    [ -d "$rec_home2" ]

    # (c) foreign replacement: check FAILs, clear preserves the foreign dir,
    # and neither the recorded path nor the foreign path is deleted
    ctx load "$proj/.ctx" >/dev/null
    local rec_home3="$COPILOT_HOME"
    mkdir -p "$TEST_TMP/foreign-replacement"
    export COPILOT_HOME="$TEST_TMP/foreign-replacement"
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_HOME"* ]]
    ctx clear >"$TEST_TMP/clear-foreign.out" 2>&1
    [ "$COPILOT_HOME" = "$TEST_TMP/foreign-replacement" ]
    [[ "$(<"$TEST_TMP/clear-foreign.out")" == *"retained"* ]]
    [ -d "$TEST_TMP/foreign-replacement" ]
    [ -d "$rec_home3" ]
}

@test "Group5 6.3: Mode A comma-containing skills paths still activate" {
    local comma_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/a,b"
    mkdir -p "$comma_dir/.github/skills" "$comma_dir/.github/instructions"
    echo "# a,b" > "$comma_dir/.github/instructions/a,b.instructions.md"

    # selector unset (Mode A default): comma path activates, skills var unset
    unset AI_CTX_PROFILES_COPILOT_MODE
    ctx a,b
    [ "$AI_CTX_PROFILES" = "a,b" ]
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]

    # explicit synthetic-home: same
    _ctx_clear
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx a,b
    [ "$AI_CTX_PROFILES" = "a,b" ]
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]

    # .ctx direct-path entry whose resolved path contains a literal comma
    # (non-comma label): Mode A must load it and leave COPILOT_SKILLS_DIRS
    # untouched/unset under both unset selector and explicit synthetic-home.
    local dotctx_dir="$TEST_TMP/comma,dir"
    mkdir -p "$dotctx_dir/.github/skills"
    local proj="$TEST_TMP/project-comma-ctx"
    mkdir -p "$proj"
    printf 'review:%s\n' "$dotctx_dir" > "$proj/.ctx"

    _ctx_clear
    unset AI_CTX_PROFILES_COPILOT_MODE
    _ctx_load_ctx_file "$proj/.ctx"
    [ "$AI_CTX_PROFILES" = "review" ]
    [ "$COPILOT_HOME" = "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review" ]
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]

    _ctx_clear
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx load "$proj/.ctx"
    [ "$AI_CTX_PROFILES" = "review" ]
    [ "$COPILOT_HOME" = "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review" ]
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]
}

@test "Group5 6.4: B/C skills ownership preserves a later user value on clear and Mode A switch" {
    _make_profile review review-skill
    _make_profile test

    # (a) ctx set the var (B); user replaces it; clear preserves the user value
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    ctx review
    [ -n "$COPILOT_SKILLS_DIRS" ]
    export COPILOT_SKILLS_DIRS=user-own-value
    ctx clear
    [ "$COPILOT_SKILLS_DIRS" = user-own-value ]

    # (b) ctx left it unset (C, no skills); user later sets a value; clear preserves it
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    ctx test
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]
    export COPILOT_SKILLS_DIRS=user-own-value
    ctx clear
    [ "$COPILOT_SKILLS_DIRS" = user-own-value ]

    # (c) ctx set the var (C); Mode A switch unsets it since still matching
    _ctx_clear
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    ctx review
    [ -n "$COPILOT_SKILLS_DIRS" ]
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx test
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]

    # (d) ctx set the var (C); user replaces it; Mode A switch preserves it
    _ctx_clear
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    ctx review
    export COPILOT_SKILLS_DIRS=user-own-value
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx test
    [ "$COPILOT_SKILLS_DIRS" = user-own-value ]
}

@test "Group5 6.5: check audits COPILOT_SKILLS_DIRS in Mode B/C" {
    _make_profile review review-skill
    _make_profile test
    local proj="$TEST_TMP/project-check-skills"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    cd "$proj"
    export AI_CTX_PROFILES_COPILOT_MODE=global-user

    # (a) expected value -> PASS
    ctx load "$proj/.ctx" >/dev/null
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS COPILOT_SKILLS_DIRS"* ]]

    # (b) missing value -> FAIL
    unset COPILOT_SKILLS_DIRS
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_SKILLS_DIRS"* ]]

    # (c) wrong value -> FAIL
    export COPILOT_SKILLS_DIRS=wrong-value
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_SKILLS_DIRS"* ]]
    unset COPILOT_SKILLS_DIRS

    # (d) unexpected value when no skills dirs exist (Mode C) -> FAIL
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    printf 'test:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/test" > "$proj/.ctx"
    ctx load "$proj/.ctx" >/dev/null
    [ -z "${COPILOT_SKILLS_DIRS+x}" ]
    export COPILOT_SKILLS_DIRS=unexpected-value
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_SKILLS_DIRS"* ]]
}

# --- Issue #40: Mode A skill-name collision reconciliation ------------------
# Skill names are compared case-insensitively (COPILOT_HOME targets are
# case-insensitive on Windows), so two source dirs contributing "foo" and
# "Foo" collide; the whole colliding group is skipped and the collision is
# diagnosed on activation and reported as CHECK FAIL by ctx check.

@test "Issue40: exact-name skill collision is diagnosed, skipped, and check fails" {
    local proj="$TEST_TMP/project-issue40-exact"
    local review_dir security_dir
    _make_profile review shared-skill
    _make_profile review review-skill
    _make_profile security shared-skill
    _make_profile security security-skill
    review_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    security_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/security"
    mkdir -p "$proj"
    printf 'review:%s\nsecurity:%s\n' "$review_dir" "$security_dir" > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/issue40-exact.out" 2>&1
    local act_out
    act_out="$(<"$TEST_TMP/issue40-exact.out")"
    [[ "$act_out" == *"collision"* ]]
    [[ "$act_out" == *"shared-skill"* ]]
    [[ "$act_out" == *"$review_dir"* ]]
    [[ "$act_out" == *"$security_dir"* ]]
    [ ! -e "$COPILOT_HOME/skills/shared-skill" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
    [ -L "$COPILOT_HOME/skills/security-skill" ]

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL skill:shared-skill"* ]]
    [[ "$output" == *"$review_dir"* ]]
    [[ "$output" == *"$security_dir"* ]]
}

@test "Issue40: case-only skill collision is diagnosed, skipped, and check fails" {
    local proj="$TEST_TMP/project-issue40-case"
    local review_dir security_dir
    _make_profile review shared-skill
    _make_profile review review-skill
    _make_profile security Shared-Skill
    _make_profile security security-skill
    review_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    security_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/security"
    mkdir -p "$proj"
    printf 'review:%s\nsecurity:%s\n' "$review_dir" "$security_dir" > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/issue40-case.out" 2>&1
    local act_out
    act_out="$(<"$TEST_TMP/issue40-case.out")"
    [[ "$act_out" == *"collision"* ]]
    [[ "$act_out" == *"shared-skill"* ]]
    [[ "$act_out" == *"$review_dir"* ]]
    [[ "$act_out" == *"$security_dir"* ]]
    [ ! -e "$COPILOT_HOME/skills/shared-skill" ]
    [ ! -e "$COPILOT_HOME/skills/Shared-Skill" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
    [ -L "$COPILOT_HOME/skills/security-skill" ]

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL skill:shared-skill"* ]]
    [[ "$output" == *"$review_dir"* ]]
    [[ "$output" == *"$security_dir"* ]]
}

@test "Issue40: non-ASCII case-fold collision (ZÄHLER vs zähler) is diagnosed and skipped" {
    local proj="$TEST_TMP/project-issue40-unicode"
    local review_dir security_dir
    _make_profile review ZÄHLER
    _make_profile review review-skill
    _make_profile security zähler
    _make_profile security security-skill
    review_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    security_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/security"
    mkdir -p "$proj"
    printf 'review:%s\nsecurity:%s\n' "$review_dir" "$security_dir" > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/issue40-unicode.out" 2>&1
    local act_out
    act_out="$(<"$TEST_TMP/issue40-unicode.out")"
    [[ "$act_out" == *"collision"* ]]
    [[ "$act_out" == *"zähler"* ]]
    [[ "$act_out" == *"$review_dir"* ]]
    [[ "$act_out" == *"$security_dir"* ]]
    [ ! -e "$COPILOT_HOME/skills/ZÄHLER" ]
    [ ! -e "$COPILOT_HOME/skills/zähler" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
    [ -L "$COPILOT_HOME/skills/security-skill" ]

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL skill:zähler"* ]]
    [[ "$output" == *"collision"* ]]
    [[ "$output" == *"$review_dir"* ]]
    [[ "$output" == *"$security_dir"* ]]
}

@test "Issue40: stale case-only sibling is detected by check and removed on reactivation" {
    # Only meaningful on a case-sensitive filesystem, where two spellings of
    # the same canonical name can coexist.
    printf 'probe\n' > "$TEST_TMP/caseprobe"
    if [ -e "$TEST_TMP/CASEPROBE" ]; then
        skip "filesystem is case-insensitive"
    fi

    local proj="$TEST_TMP/project-issue40-stale-case"
    local review_dir
    _make_profile review foo-skill
    _make_profile review review-skill
    review_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    mkdir -p "$proj"
    printf 'review:%s\n' "$review_dir" > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    [ -L "$COPILOT_HOME/skills/foo-skill" ]

    # Simulate a stale same-case sibling left behind by an earlier partial
    # state on a case-sensitive filesystem.
    ln -s "$review_dir/.github/skills/foo-skill" "$COPILOT_HOME/skills/Foo-Skill"
    [ -L "$COPILOT_HOME/skills/Foo-Skill" ]

    # Read-only check must detect the duplicate canonical name and fail.
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL skill:foo-skill"* ]]
    [[ "$output" == *"duplicate"* ]]

    # Reactivation reconciles to exactly one on-disk spelling.
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    [ -L "$COPILOT_HOME/skills/foo-skill" ]
    [ ! -e "$COPILOT_HOME/skills/Foo-Skill" ]

    run ctx check
    [ "$status" -eq 0 ]
}

@test "Issue40: Greek final-sigma invariant lowercase collision (ΟΣ vs οσ) is diagnosed and skipped" {
    local proj="$TEST_TMP/project-issue40-greek"
    local review_dir security_dir
    _make_profile review ΟΣ
    _make_profile review review-skill
    _make_profile security οσ
    _make_profile security security-skill
    review_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    security_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/security"
    mkdir -p "$proj"
    printf 'review:%s\nsecurity:%s\n' "$review_dir" "$security_dir" > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/issue40-greek.out" 2>&1
    local act_out
    act_out="$(<"$TEST_TMP/issue40-greek.out")"
    [[ "$act_out" == *"collision"* ]]
    [[ "$act_out" == *"οσ"* ]]
    [[ "$act_out" == *"$review_dir"* ]]
    [[ "$act_out" == *"$security_dir"* ]]
    [ ! -e "$COPILOT_HOME/skills/ΟΣ" ]
    [ ! -e "$COPILOT_HOME/skills/οσ" ]
    [ -L "$COPILOT_HOME/skills/review-skill" ]
    [ -L "$COPILOT_HOME/skills/security-skill" ]

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL skill:οσ"* ]]
    [[ "$output" == *"collision"* ]]
    [[ "$output" == *"$review_dir"* ]]
    [[ "$output" == *"$security_dir"* ]]
}

@test "Issue40: Turkish dotted İ and i are distinct under invariant lowercase (no collision)" {
    # Only meaningful on a case-sensitive filesystem, where two spellings of
    # the same canonical name can coexist; on case-insensitive filesystems
    # the on-disk links themselves would alias.
    printf 'probe\n' > "$TEST_TMP/caseprobe"
    if [ -e "$TEST_TMP/CASEPROBE" ]; then
        skip "filesystem is case-insensitive"
    fi

    local proj="$TEST_TMP/project-issue40-turkish"
    local review_dir security_dir
    _make_profile review İstanbul
    _make_profile review review-skill
    _make_profile security istanbul
    _make_profile security security-skill
    review_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    security_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/security"
    mkdir -p "$proj"
    printf 'review:%s\nsecurity:%s\n' "$review_dir" "$security_dir" > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/issue40-turkish.out" 2>&1
    local act_out
    act_out="$(<"$TEST_TMP/issue40-turkish.out")"
    [[ "$act_out" != *"collision"* ]]
    [ -L "$COPILOT_HOME/skills/İstanbul" ]
    [ -L "$COPILOT_HOME/skills/istanbul" ]

    run ctx check
    [ "$status" -eq 0 ]
}

@test "Issue40: desired spelling is recreated when only a differently-cased link exists" {
    local proj="$TEST_TMP/project-issue40-spelling"
    local review_dir
    _make_profile review foo-skill
    _make_profile review review-skill
    review_dir="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    mkdir -p "$proj"
    printf 'review:%s\n' "$review_dir" > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    local foo_link="$COPILOT_HOME/skills/foo-skill"
    local foo_link_old="$COPILOT_HOME/skills/Foo-Skill"
    [ -L "$foo_link" ]

    # Seed a correctly-targeted link under the OLD casing, removing the
    # desired-casing entry so activation must recreate the desired spelling.
    rm -f "$foo_link"
    ln -s "$review_dir/.github/skills/foo-skill" "$foo_link_old"
    [ -L "$foo_link_old" ]

    # Activation leaves the exact desired on-disk spelling behind as a correct
    # link (regression: a differently-cased entry could previously satisfy the
    # exact-case check through aliasing and suppress recreation).
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    [ -L "$foo_link" ]
    [ "$(readlink "$foo_link")" = "$review_dir/.github/skills/foo-skill" ]

    run ctx check
    [ "$status" -eq 0 ]
}
