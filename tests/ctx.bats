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

    unset AI_CTX_PROFILES AI_CONTEXT AI_CONFIG_ROOT CTX_HOMES_ROOT COPILOT_CUSTOM_INSTRUCTIONS_DIRS COPILOT_HOME COPILOT_SKILLS_DIRS CTX_AUTO_LOAD AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT
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
    [[ "$current_unset" == *"Mode: A — synthetic-home"* ]]

    _ctx_clear >/dev/null
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    run ctx current
    [ "$status" -eq 0 ]
    local current_explicit="$output"
    [[ "$current_explicit" == *"Mode: A — synthetic-home"* ]]
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
    mkdir -p "$TEST_TMP/trusted-external-profiles"
    export AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT="$TEST_TMP/trusted-external-profiles"
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

@test "Mode B: preserved-COPILOT_HOME warning fires on success, never otherwise" {
    _make_profile review review-skill
    local warning="global-user mode preserves the existing COPILOT_HOME"
    export AI_CTX_PROFILES_COPILOT_MODE=global-user

    # (a) COPILOT_HOME unset -> no warning
    unset COPILOT_HOME
    ctx review >"$TEST_TMP/warn-unset.out" 2>"$TEST_TMP/warn-unset.err"
    [ -z "${COPILOT_HOME:-}" ]
    [[ "$(<"$TEST_TMP/warn-unset.err")" != *"$warning"* ]]

    # (b) COPILOT_HOME present -> exact template on stderr, value untouched
    export COPILOT_HOME="$TEST_TMP/custom-home"
    ctx review >"$TEST_TMP/warn-set.out" 2>"$TEST_TMP/warn-set.err"
    [ "$COPILOT_HOME" = "$TEST_TMP/custom-home" ]
    [ "$(<"$TEST_TMP/warn-set.err")" = 'ctx: warning: global-user mode preserves the existing COPILOT_HOME: "'"$TEST_TMP/custom-home"'". This may point to a synthetic home from a previous ctx activation.' ]

    # (c) COPILOT_HOME present but empty -> warning with empty quotes
    export COPILOT_HOME=""
    ctx review >"$TEST_TMP/warn-empty.out" 2>"$TEST_TMP/warn-empty.err"
    [ "${COPILOT_HOME+x}" = "x" ]
    [ "$(<"$TEST_TMP/warn-empty.err")" = 'ctx: warning: global-user mode preserves the existing COPILOT_HOME: "". This may point to a synthetic home from a previous ctx activation.' ]

    # (d) Modes A and C -> no warning
    export COPILOT_HOME="$TEST_TMP/still-set"
    export AI_CTX_PROFILES_COPILOT_MODE=synthetic-home
    ctx review >"$TEST_TMP/warn-a.out" 2>"$TEST_TMP/warn-a.err"
    [[ "$(<"$TEST_TMP/warn-a.err")" != *"$warning"* ]]
    export AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean
    ctx review >"$TEST_TMP/warn-c.out" 2>"$TEST_TMP/warn-c.err"
    [[ "$(<"$TEST_TMP/warn-c.err")" != *"$warning"* ]]

    # (e) failed activation -> no warning
    export AI_CTX_PROFILES_COPILOT_MODE=bogus
    local status=0
    ctx review >"$TEST_TMP/warn-fail.out" 2>"$TEST_TMP/warn-fail.err" || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/warn-fail.err")" != *"$warning"* ]]

    # (f) explicit ctx load under Mode B with COPILOT_HOME present -> warning
    local proj="$TEST_TMP/project-b-warn"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    export COPILOT_HOME="$TEST_TMP/load-home"
    ctx load "$proj/.ctx" >"$TEST_TMP/warn-load.out" 2>"$TEST_TMP/warn-load.err"
    [ "$COPILOT_HOME" = "$TEST_TMP/load-home" ]
    [[ "$(<"$TEST_TMP/warn-load.err")" == *"global-user mode preserves the existing COPILOT_HOME: \"$TEST_TMP/load-home\""* ]]

    # (g) read-only commands never warn: ctx current / ctx check emit no warning
    run ctx current
    [ "$status" -eq 0 ]
    [[ "$output" != *"$warning"* ]]
    cd "$proj"
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" != *"$warning"* ]]

    # (h) .ctx auto-load under Mode B with COPILOT_HOME present -> warning
    local proj_auto="$TEST_TMP/project-b-warn-auto"
    mkdir -p "$proj_auto"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj_auto/.ctx"
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    export COPILOT_HOME="$TEST_TMP/auto-home"
    _ctx_auto_load_dir=""
    cd "$proj_auto"
    _ctx_auto_load_hook >"$TEST_TMP/warn-auto.out" 2>"$TEST_TMP/warn-auto.err"
    [ "$COPILOT_HOME" = "$TEST_TMP/auto-home" ]
    [[ "$(<"$TEST_TMP/warn-auto.err")" == *"global-user mode preserves the existing COPILOT_HOME: \"$TEST_TMP/auto-home\""* ]]
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
    [[ "$output" == *"Mode: C — ephemeral-clean"* ]]
    [[ "$output" != *"Mode: B — global-user"* ]]

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_MODE"* ]]
    [[ "$output" == *"does not match recorded active mode C — ephemeral-clean"* ]]

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
    [[ "$output" == *"Mode: B — global-user"* ]]
    [[ "$output" != *"Mode: C — ephemeral-clean"* ]]

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

# --- Group 7: ctx skills (read-only potential-skill-discovery inventory) ---
# `ctx skills` inventories candidate skill directories from the filesystem and
# configuration. It never claims skills are loaded/invoked, never invokes the
# Copilot CLI, and never modifies settings, files, or the environment. Each
# candidate carries one classification (precedence: ctx-profile >
# expected-home > external) while all origins are retained.

@test "ctx skills: read-only inventory of candidate skill dirs with origins, dedup, and missing paths" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-skills-inventory"
    mkdir -p "$proj" "$proj/.github/copilot" "$proj/.agents/skills/custom" "$proj/.github/skills/repo-skill" "$proj/.claude/skills/claude-skill"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    cd "$proj"

    # Active Mode A context so ctx-owned provenance is attributable.
    ctx load "$proj/.ctx" >/dev/null
    local home_skills="$COPILOT_HOME/skills"
    [ -d "$home_skills" ]

    # Configured entries: COPILOT_SKILLS_DIRS (one existing, one missing) and
    # skillDirectories in a repo settings file (one existing skill dir, one
    # missing), plus an observable installed-plugin skills subdir. The
    # existing COPILOT_SKILLS_DIRS entry is a dot-segment alias of the active
    # profile skills dir so the row is deduplicated by normalization, not by
    # string equality.
    local profile_skills="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills"
    # COPILOT_SKILLS_DIRS lists a dot-segment alias of the active profile
    # skills dir, the repo .github/skills dir itself, and a missing dir, so
    # one row must retain multiple distinct source origins (including two
    # external-class origins).
    export COPILOT_SKILLS_DIRS="${profile_skills%/skills}/./skills,$proj/.github/skills,$TEST_TMP/missing-skills-dir"
    printf '{"skillDirectories":["%s/review-skill","%s/missing-from-settings"]}\n' "$profile_skills" "$TEST_TMP" > "$proj/.github/copilot/settings.json"
    mkdir -p "$CTX_COPILOT_DIR/installed-plugins/my-plugin/skills/pskill" "$CTX_COPILOT_DIR/installed-plugins/no-skill"

    local before_env
    before_env="$(printf '%s|%s|%s|%s' "$AI_CTX_PROFILES" "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" "$COPILOT_HOME" "${COPILOT_SKILLS_DIRS:-}")"

    run ctx skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ctx skills] potential Copilot skill discovery"* ]]
    [[ "$output" == *"ctx does not claim these skills are loaded or invoked"* ]]

    # ctx-profile candidate from the active profile appears once, retaining
    # the distinct external-class origin from COPILOT_SKILLS_DIRS (dedup via
    # normalization of the dot-segment alias), with ctx-profile winning as the
    # classification. Exactly one row is proven by counting the exact line,
    # not merely by matching a row.
    [[ "$output" == *"candidate: $profile_skills (classification: ctx-profile, origins: copilot-skill-dirs,ctx-profile)"* ]]
    local profile_skills_row="[ctx skills] candidate: $profile_skills (classification: ctx-profile, origins: copilot-skill-dirs,ctx-profile)"
    local profile_skills_count
    profile_skills_count="$(grep -cxF -- "$profile_skills_row" <<<"$output")"
    [ "$profile_skills_count" -eq 1 ]

    # expected-home candidate (the active Mode A COPILOT_HOME/skills).
    [[ "$output" == *"candidate: $home_skills (classification: expected-home, origins: expected-home)"* ]]

    # external candidates: repo .github/skills (found by repository discovery
    # AND COPILOT_SKILLS_DIRS -> two external-class origins), .agents/skills,
    # and .claude/skills, plugin skill dir, configured skillDirectories entry
    # that exists.
    [[ "$output" == *"candidate: $proj/.github/skills (classification: external, origins: copilot-skill-dirs,repo-github-skills)"* ]]
    [[ "$output" == *"candidate: $proj/.agents/skills (classification: external, origins: repo-agents-skills)"* ]]
    [[ "$output" == *"candidate: $proj/.claude/skills (classification: external, origins: repo-claude-skills)"* ]]
    [[ "$output" == *"candidate: $CTX_COPILOT_DIR/installed-plugins/my-plugin/skills (classification: external, origins: plugin-skills)"* ]]
    [[ "$output" == *"candidate: $profile_skills/review-skill (classification: external, origins: settings-skill-dirs)"* ]]

    # Configured-but-missing paths are reported, not failed, and the plugins
    # root itself is never a candidate.
    [[ "$output" == *"missing: $TEST_TMP/missing-skills-dir (classification: external, origins: copilot-skill-dirs)"* ]]
    [[ "$output" == *"missing: $TEST_TMP/missing-from-settings (classification: external, origins: settings-skill-dirs)"* ]]
    [[ "$output" != *"candidate: $CTX_COPILOT_DIR/installed-plugins ("* ]]
    [[ "$output" != *"candidate: $CTX_COPILOT_DIR/installed-plugins/no-skill ("* ]]

    # Boundary disclosures.
    [[ "$output" == *"not observable: command-line arguments of another Copilot process"* ]]
    [[ "$output" == *"not observable: skill locations inside installed Copilot plugins"* ]]
    [[ "$output" == *"no Copilot CLI probe performed"* ]]

    # Strictly read-only: environment and files are untouched.
    local after_env
    after_env="$(printf '%s|%s|%s|%s' "$AI_CTX_PROFILES" "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" "$COPILOT_HOME" "${COPILOT_SKILLS_DIRS:-}")"
    [ "$after_env" = "$before_env" ]
    [ -d "$home_skills" ]
    [ -d "$proj/.github/skills" ]
    [ -d "$proj/.agents/skills/custom" ]
    [ -d "$proj/.claude/skills" ]
    [ -f "$proj/.github/copilot/settings.json" ]
}

@test "ctx skills: unknown provenance does not guess ctx-owned paths" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-skills-unknown"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    cd "$proj"

    # A context that is set in the environment but has NO matching session
    # activation record: ctx-owned paths must not be guessed.
    export AI_CTX_PROFILES=review
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    _ctx_reset_active_record

    run ctx skills
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ctx skills] unknown: no matching ctx session activation record; ctx-owned paths are not guessed"* ]]
    [[ "$output" != *"candidate: $AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills"* ]]
    [[ "$output" != *"classification: ctx-profile"* ]]
}

@test "ctx skills: normalization works without GNU realpath (python fallback)" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-skills-norealpath"
    mkdir -p "$proj" "$proj/.agents/skills/custom"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    cd "$proj"
    ctx load "$proj/.ctx" >/dev/null

    # Shadow realpath so only the portable python fallback can normalize.
    realpath() { return 1; }
    export -f realpath
    run ctx skills
    unset -f realpath
    [ "$status" -eq 0 ]
    [[ "$output" == *"candidate: $proj/.agents/skills (classification: external, origins: repo-agents-skills)"* ]]
}

@test "ctx skills: python fallback preserves paths with leading/trailing spaces" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-skills-spaces"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    cd "$proj"

    # A configured directory whose name has leading and trailing spaces. With
    # realpath shadowed only the python fallback normalizes it, and the spaces
    # must survive transport to python (passed as argv, never stripped).
    local spaced="$TEST_TMP/ spaced-skill "
    mkdir -p "$spaced"
    export COPILOT_SKILLS_DIRS="$spaced"

    realpath() { return 1; }
    export -f realpath
    run ctx skills
    unset -f realpath
    [ "$status" -eq 0 ]
    [[ "$output" == *"candidate: $spaced (classification: external, origins: copilot-skill-dirs)"* ]]
}

@test "ctx skills: caller bookkeeping variables are preserved (no global clobber)" {
    _make_profile review review-skill
    local proj="$TEST_TMP/project-skills-preserve"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    cd "$proj"

    # Simulate a caller that already owns these names with plain scalar values
    # (ctx uses array/associative-array shapes internally). Neither re-sourcing
    # ctx.sh nor running the read-only diagnostic may overwrite them.
    _CTX_SKILLS_ORIGINS='caller-origins-sentinel'
    _CTX_SKILLS_PATHS='caller-paths-sentinel'
    _CTX_SKILLS_REPORT='caller-report-sentinel'
    export _CTX_SKILLS_ORIGINS _CTX_SKILLS_PATHS _CTX_SKILLS_REPORT

    # Re-sourcing must not clobber caller state (no top-level declarations).
    . "$CTX_SRC" >/dev/null 2>&1
    [ "$_CTX_SKILLS_ORIGINS" = 'caller-origins-sentinel' ]
    [ "$_CTX_SKILLS_PATHS" = 'caller-paths-sentinel' ]
    [ "$_CTX_SKILLS_REPORT" = 'caller-report-sentinel' ]

    # Running the read-only diagnostic must not clobber caller state either.
    local status=0
    ctx skills >"$TEST_TMP/skills-preserve.out" 2>&1 || status=$?
    [ "$status" -eq 0 ]
    [ "$_CTX_SKILLS_ORIGINS" = 'caller-origins-sentinel' ]
    [ "$_CTX_SKILLS_PATHS" = 'caller-paths-sentinel' ]
    [ "$_CTX_SKILLS_REPORT" = 'caller-report-sentinel' ]
    [[ "$(<"$TEST_TMP/skills-preserve.out")" == *"[ctx skills] potential Copilot skill discovery"* ]]
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

# --- Issue #48: canonical AGENTS.md profiles -------------------------------

_make_canonical_profile() {
    # _make_canonical_profile <name> [agents-content]
    local name="$1" content="${2:-# $1 canonical instructions}"
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/$name"
    printf '%s' "$content" > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/$name/AGENTS.md"
}

_make_canonical_skill() {
    # _make_canonical_skill <profile> <skill-name>
    local profile="$1" skill="$2"
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/$profile/.agents/skills/$skill"
    printf -- '---\nname: %s\ndescription: test\n---\n' "$skill" \
        > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/$profile/.agents/skills/$skill/SKILL.md"
}

@test "Issue48: canonical manual activation projects AGENTS.md bytes and sets custom dirs present-empty" {
    _make_canonical_profile review $'# hello\n'
    ctx review

    local proj="$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md"
    [ -f "$proj" ]
    [ ! -L "$proj" ]
    printf -- '---\napplyTo: "**"\n---\n\n# hello\n' > "$TEST_TMP/expected"
    cmp -s "$proj" "$TEST_TMP/expected"
    [ "$AI_CTX_PROFILES" = review ]
    [ -n "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS+x}" ]
    [ -z "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" ]
    [ -f "$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed" ]
    [ "$(cat "$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed")" = "0001-review.instructions.md" ]
}

@test "Issue48: canonical .ctx activation projects and ctx check passes" {
    _make_canonical_profile review $'# hello\n'
    local proj="$TEST_TMP/project-canonical-check"
    mkdir -p "$proj"
    printf 'review:@profile\n' > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >/dev/null

    [ -f "$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md" ]
    [ -n "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS+x}" ]
    [ -z "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" ]

    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS instruction:0001-review.instructions.md"* ]]
}

@test "Issue48: mixed selection keeps legacy dirs in order and projects canonical at selection order" {
    _make_profile review review-skill
    _make_canonical_profile arch $'# arch\n'
    _make_profile security security-skill

    ctx review arch security

    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review,$AI_CTX_PROFILES_CONFIG_ROOT/profiles/security" ]
    [ -f "$COPILOT_HOME/instructions/ctx-profiles/0002-arch.instructions.md" ]
    [ ! -e "$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md" ]
    [ ! -e "$COPILOT_HOME/instructions/ctx-profiles/0003-security.instructions.md" ]
}

@test "Issue48: projection filename sanitizes labels and stays filesystem-safe" {
    _make_canonical_profile "my profile" $'# spaced\n'
    ctx "my profile"

    [ -f "$COPILOT_HOME/instructions/ctx-profiles/0001-my_profile.instructions.md" ]
    local fname
    fname="$(basename "$COPILOT_HOME/instructions/ctx-profiles/"*.instructions.md)"
    case "$fname" in
        0001-my_profile.instructions.md) : ;;
        *) false ;;
    esac
}

@test "Issue48: non-ASCII label yields a safe filename matching the grammar" {
    _make_canonical_profile "café" $'# accented\n'
    ctx "café"

    local fname
    fname="$(basename "$COPILOT_HOME/instructions/ctx-profiles/"*.instructions.md)"
    [ "$fname" = "0001-caf_.instructions.md" ]
    printf '%s' "$fname" | LC_ALL=C grep -Eq '^[0-9]{4,}-[A-Za-z0-9+._-]+\.instructions\.md$'
}

@test "Issue48: CRLF, BOM, and missing final newline are preserved byte-for-byte" {
    _make_canonical_profile review $'# a\r\n# b'
    ctx review
    local proj="$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md"
    { printf -- '---\napplyTo: "**"\n---\n\n'; printf '# a\r\n# b'; } > "$TEST_TMP/expected-crlf"
    cmp -s "$proj" "$TEST_TMP/expected-crlf"

    ctx clear >/dev/null
    _make_canonical_profile bom $'\xef\xbb\xbf# bom\n'
    ctx bom
    local proj2="$COPILOT_HOME/instructions/ctx-profiles/0001-bom.instructions.md"
    { printf -- '---\napplyTo: "**"\n---\n\n'; printf '\xef\xbb\xbf# bom\n'; } > "$TEST_TMP/expected-bom"
    cmp -s "$proj2" "$TEST_TMP/expected-bom"
}

@test "Issue48: canonical profiles use .agents/skills and ignore co-located .github/skills" {
    _make_canonical_profile review $'# review\n'
    _make_canonical_skill review good-skill
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.agents/skills/no-skill"
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills/legacy-skill"
    printf -- '---\nname: legacy\n---\n' > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills/legacy-skill/SKILL.md"
    local proj="$TEST_TMP/project-canonical-skills"
    mkdir -p "$proj"
    printf 'review:@profile\n' > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >/dev/null

    [ -L "$COPILOT_HOME/skills/good-skill" ]
    [ ! -e "$COPILOT_HOME/skills/no-skill" ]
    [ ! -e "$COPILOT_HOME/skills/legacy-skill" ]

    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS skill:good-skill"* ]]
}

@test "Issue48: canonical/legacy skill collisions reuse warn-and-skip and check FAIL" {
    _make_canonical_profile review $'# review\n'
    _make_canonical_skill review dup-skill
    _make_profile security Dup-Skill
    local proj="$TEST_TMP/project-canonical-collision"
    mkdir -p "$proj"
    printf 'review:@profile\nsecurity:@profile\n' > "$proj/.ctx"
    cd "$proj"

    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/collide.out" 2>&1
    [[ "$(<"$TEST_TMP/collide.out")" == *"collision"* ]]
    [ ! -e "$COPILOT_HOME/skills/dup-skill" ]
    [ ! -e "$COPILOT_HOME/skills/Dup-Skill" ]

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL skill:dup-skill"* ]]
    [[ "$output" == *"collision"* ]]
}

@test "Issue48: Mode B and C reject canonical selections before any mutation" {
    _make_canonical_profile review $'# review\n'
    for mode in global-user ephemeral-clean; do
        export AI_CTX_PROFILES_COPILOT_MODE="$mode"
        export AI_CTX_PROFILES=previous
        export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
        export COPILOT_HOME=previous-home

        local status=0
        ctx review >"$TEST_TMP/mode-reject.out" 2>&1 || status=$?
        [ "$status" -ne 0 ]
        [[ "$(<"$TEST_TMP/mode-reject.out")" == *"canonical"* ]]
        [[ "$(<"$TEST_TMP/mode-reject.out")" == *"synthetic-home"* ]]
        [ "$AI_CTX_PROFILES" = previous ]
        [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
        [ "$COPILOT_HOME" = previous-home ]
        [ ! -d "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review" ]
    done
}

@test "Issue48: .ctx auto-load rejects canonical entries under Mode B before mutation" {
    _make_canonical_profile review $'# review\n'
    local proj="$TEST_TMP/project-canon-mode-b"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    export AI_CTX_PROFILES_COPILOT_MODE=global-user
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/canon-load-b.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/canon-load-b.out")" == *"canonical"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ ! -e "$proj/project-canon-mode-b.code-workspace" ]
}

@test "Issue48: actual .ctx auto-load rejects canonical entries under Modes B and C, repeatedly" {
    _make_canonical_profile review $'# review\n'
    local proj="$TEST_TMP/project-canon-autoload-bc"
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    local mode
    for mode in global-user ephemeral-clean; do
        export AI_CTX_PROFILES_COPILOT_MODE="$mode"
        export AI_CTX_PROFILES=previous
        export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
        export COPILOT_HOME=previous-home
        export COPILOT_SKILLS_DIRS=previous-skills
        _ctx_auto_load_dir=""
        _ctx_reset_active_record

        local prev_mode="$_ctx_active_mode"
        local prev_context="$_ctx_active_context"
        local prev_custom_dirs="$_ctx_active_custom_dirs"
        local prev_home_was_set="$_ctx_active_home_was_set"
        local prev_home_value="$_ctx_active_home_value"

        cd "$proj"

        local status=0
        _ctx_auto_load_hook >"$TEST_TMP/canon-autoload-$mode-1.out" 2>&1 || status=$?
        [ "$status" -ne 0 ]
        [[ "$(<"$TEST_TMP/canon-autoload-$mode-1.out")" == *"canonical"* ]]
        [[ "$(<"$TEST_TMP/canon-autoload-$mode-1.out")" == *"synthetic-home"* ]]
        [ "$AI_CTX_PROFILES" = previous ]
        [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
        [ "$COPILOT_HOME" = previous-home ]
        [ "$COPILOT_SKILLS_DIRS" = previous-skills ]
        [ "$_ctx_active_mode" = "$prev_mode" ]
        [ "$_ctx_active_context" = "$prev_context" ]
        [ "$_ctx_active_custom_dirs" = "$prev_custom_dirs" ]
        [ "$_ctx_active_home_was_set" = "$prev_home_was_set" ]
        [ "$_ctx_active_home_value" = "$prev_home_value" ]
        [ ! -e "$proj/project-canon-autoload-bc.code-workspace" ]

        status=0
        _ctx_auto_load_hook >"$TEST_TMP/canon-autoload-$mode-2.out" 2>&1 || status=$?
        [ "$status" -ne 0 ]
        [[ "$(<"$TEST_TMP/canon-autoload-$mode-2.out")" == *"canonical"* ]]
        [ "$AI_CTX_PROFILES" = previous ]
        [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
        [ "$COPILOT_HOME" = previous-home ]
        [ "$COPILOT_SKILLS_DIRS" = previous-skills ]
        [ "$_ctx_active_mode" = "$prev_mode" ]
        [ ! -e "$proj/project-canon-autoload-bc.code-workspace" ]
    done
}

@test "Issue48: unmanifested desired projection is not overwritten" {
    _make_canonical_profile review $'# review\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    mkdir -p "$home/instructions/ctx-profiles"
    printf 'user data\n' > "$home/instructions/ctx-profiles/0001-review.instructions.md"
    export AI_CTX_PROFILES=previous

    local status=0
    ctx review >"$TEST_TMP/unmanaged.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/unmanaged.out")" == *"unmanaged projection"* ]]
    [ "$(cat "$home/instructions/ctx-profiles/0001-review.instructions.md")" = "user data" ]
    [ "$AI_CTX_PROFILES" = previous ]
}

@test "Issue48: manifest-listed desired projection as symlink to outside sentinel fails closed" {
    _make_canonical_profile review $'# review\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    local outside="$TEST_TMP/outside-sentinel"
    printf 'outside data\n' > "$outside"
    mkdir -p "$home/instructions/ctx-profiles"
    ln -s "$outside" "$home/instructions/ctx-profiles/0001-review.instructions.md"
    printf '0001-review.instructions.md\n' > "$home/instructions/ctx-profiles/.ctx-managed"
    export AI_CTX_PROFILES=previous

    local status=0
    ctx review >"$TEST_TMP/linked-proj.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/linked-proj.out")" == *"unsafe managed projection target"* ]]
    [ "$(cat "$outside")" = "outside data" ]
    [ -L "$home/instructions/ctx-profiles/0001-review.instructions.md" ]
    [ -z "${COPILOT_HOME:-}" ]
    [ "$AI_CTX_PROFILES" = previous ]
}

@test "Issue48: directory at manifest-listed desired projection name fails closed" {
    _make_canonical_profile review $'# review\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    mkdir -p "$home/instructions/ctx-profiles/0001-review.instructions.md"
    printf '0001-review.instructions.md\n' > "$home/instructions/ctx-profiles/.ctx-managed"
    export AI_CTX_PROFILES=previous

    local status=0
    ctx review >"$TEST_TMP/dir-proj.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/dir-proj.out")" == *"unsafe managed projection target"* ]]
    [ -d "$home/instructions/ctx-profiles/0001-review.instructions.md" ]
    [ -z "${COPILOT_HOME:-}" ]
    [ "$AI_CTX_PROFILES" = previous ]
}

@test "Issue48: linked projection directory fails without writing outside the home" {
    _make_canonical_profile review $'# review\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    local outside="$TEST_TMP/outside-instructions"
    mkdir -p "$home" "$outside"
    ln -s "$outside" "$home/instructions"

    local status=0
    ctx review >"$TEST_TMP/linked.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/linked.out")" == *"unsafe projection directory"* ]]
    [ ! -e "$outside/ctx-profiles" ]
}

@test "Issue48: malformed manifest fails closed without changing projections" {
    _make_canonical_profile review $'# review\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    mkdir -p "$home/instructions/ctx-profiles"
    printf '../escape.instructions.md\n' > "$home/instructions/ctx-profiles/.ctx-managed"

    local status=0
    ctx review >"$TEST_TMP/malformed.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/malformed.out")" == *"malformed projection manifest"* ]]
    [ ! -e "$TEST_TMP/escape.instructions.md" ]
}

@test "Issue48: removing AGENTS.md from a canonical profile cleans its stale projection on reactivation" {
    _make_canonical_profile review $'# review\n'
    ctx review >/dev/null
    local home="$COPILOT_HOME"
    local proj="$home/instructions/ctx-profiles/0001-review.instructions.md"
    [ -f "$proj" ]

    # The profile becomes legacy while the same context (and home) stays
    # selected, so the now-unwanted managed projection must be cleaned.
    rm -f "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/AGENTS.md"
    ctx review >/dev/null
    [ ! -e "$proj" ]
    [ ! -e "$home/instructions/ctx-profiles/.ctx-managed" ]
}

@test "Issue48: ctx clear preserves the cached projection and clear --all removes the home" {
    _make_canonical_profile review $'# review\n'
    ctx review >/dev/null
    local home="$COPILOT_HOME"
    local proj="$home/instructions/ctx-profiles/0001-review.instructions.md"
    [ -f "$proj" ]

    ctx clear >/dev/null
    [ -f "$proj" ]

    ctx review >/dev/null
    ctx clear --all >/dev/null
    [ ! -d "$home" ]
}

@test "Issue48: check uses the recorded Mode A despite a selector mismatch" {
    _make_canonical_profile review $'# review\n'
    local proj="$TEST_TMP/project-canonical-mismatch"
    mkdir -p "$proj"
    printf 'review:@profile\n' > "$proj/.ctx"
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    export AI_CTX_PROFILES_COPILOT_MODE=global-user

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK PASS instruction:0001-review.instructions.md"* ]]
    [[ "$output" == *"does not match recorded active mode"* ]]
}

@test "Issue48: no activation record skips canonical instruction checks" {
    _make_canonical_profile review $'# review\n'
    local proj="$TEST_TMP/project-canonical-norecord"
    mkdir -p "$proj"
    printf 'review:@profile\n' > "$proj/.ctx"
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    _ctx_reset_active_record

    run ctx check
    [[ "$output" == *"CHECK SKIP instruction:0001-review.instructions.md"* ]]
}

@test "Issue48: all-canonical Mode A check requires present-empty custom dirs" {
    _make_canonical_profile review $'# review\n'
    local proj="$TEST_TMP/project-canonical-empty"
    mkdir -p "$proj"
    printf 'review:@profile\n' > "$proj/.ctx"
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null

    [ -n "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS+x}" ]
    [ -z "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" ]

    run ctx check
    [ "$status" -eq 0 ]

    unset COPILOT_CUSTOM_INSTRUCTIONS_DIRS
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL COPILOT_CUSTOM_INSTRUCTIONS_DIRS"* ]]
}

@test "Issue48: ctx current does not add projection listings" {
    _make_canonical_profile review $'# review\n'
    ctx review >/dev/null

    run ctx current
    [ "$status" -eq 0 ]
    [[ "$output" != *"instructions.md"* ]]
}

@test "Issue48: ctx current distinguishes present-empty from unset COPILOT_CUSTOM_INSTRUCTIONS_DIRS" {
    _make_canonical_profile review $'# review\n'
    ctx review >/dev/null

    run ctx current
    [ "$status" -eq 0 ]
    [[ "$output" == *"COPILOT_CUSTOM_INSTRUCTIONS_DIRS="*"<present-empty>"* ]]

    unset COPILOT_CUSTOM_INSTRUCTIONS_DIRS
    run ctx current
    [ "$status" -eq 0 ]
    [[ "$output" == *"COPILOT_CUSTOM_INSTRUCTIONS_DIRS="*"<unset>"* ]]
}

@test "Issue48: legacy-only activation preserves an empty user instructions directory" {
    _make_profile security security-skill
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/security"
    mkdir -p "$home/instructions"

    ctx security >/dev/null
    [ -d "$home/instructions" ]
}

@test "Issue48: legacy-only activation does not reject an unrelated linked instructions path without a manifest" {
    _make_profile security security-skill
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/security"
    local outside="$TEST_TMP/outside-instructions"
    mkdir -p "$home" "$outside"
    ln -s "$outside" "$home/instructions"

    ctx security >/dev/null
    [ -L "$home/instructions" ]
}

@test "Issue48: legacy-only activation with an existing ctx manifest removes only stale managed projections" {
    _make_canonical_profile review $'# review\n'
    ctx review >/dev/null
    local home="$COPILOT_HOME"
    local proj="$home/instructions/ctx-profiles/0001-review.instructions.md"
    [ -f "$proj" ]

    # A legacy-only .ctx selection that reuses the same home must drop the
    # now-stale managed projection and manifest while keeping the shared home.
    _make_profile security security-skill
    local pdir="$TEST_TMP/project-legacy-reuse"
    mkdir -p "$pdir"
    printf 'security:@profile\nhome:%s\n' "$home" > "$pdir/.ctx"
    cd "$pdir"
    _ctx_load_ctx_file "$pdir/.ctx" >/dev/null

    [ ! -e "$proj" ]
    [ ! -e "$home/instructions/ctx-profiles/.ctx-managed" ]
    [ -d "$home/skills" ]
}

@test "Issue48: ctx check skips projections when no canonical entries and no manifest exist" {
    _make_profile security security-skill
    local proj="$TEST_TMP/project-legacy-check"
    mkdir -p "$proj"
    printf 'security:@profile\n' > "$proj/.ctx"
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null

    run ctx check
    [ "$status" -eq 0 ]
}

@test "Issue48: ctx check fails on a malformed ctx-managed manifest with zero canonical entries" {
    _make_profile security security-skill
    local proj="$TEST_TMP/project-legacy-check-malformed"
    mkdir -p "$proj"
    printf 'security:@profile\n' > "$proj/.ctx"
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    mkdir -p "$COPILOT_HOME/instructions/ctx-profiles"
    printf 'bad name\n' > "$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed"

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL instruction:manifest"* ]]
}

@test "Issue48: ctx check fails on a stale ctx-managed manifest with zero canonical entries" {
    _make_profile security security-skill
    local proj="$TEST_TMP/project-legacy-check-stale"
    mkdir -p "$proj"
    printf 'security:@profile\n' > "$proj/.ctx"
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    mkdir -p "$COPILOT_HOME/instructions/ctx-profiles"
    printf '0001-review.instructions.md\n' > "$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed"

    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"stale projection"* ]]
}

@test "Issue48: projection transaction fails closed when a later source is missing" {
    _make_canonical_profile review $'# review\n'
    _make_canonical_profile arch $'# arch\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review+arch"
    local missing="$TEST_TMP/missing-source"
    mkdir -p "$missing"

    local status=0
    _ctx_project_instructions "$home" \
        1 review "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" \
        2 arch "$missing" >"$TEST_TMP/b1-fail.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/b1-fail.out")" == *"could not read projection source"* ]]
    [ ! -e "$home/instructions/ctx-profiles/0001-review.instructions.md" ]
    [ ! -e "$home/instructions/ctx-profiles/0002-arch.instructions.md" ]
    [ ! -e "$home/instructions/ctx-profiles/.ctx-managed" ]
    [ -z "$(find "$home/instructions/ctx-profiles" -mindepth 1 -maxdepth 1 -name '.ctx-txn.*' -print 2>/dev/null)" ]
}

@test "Issue48: projection transaction retry succeeds after the source is fixed" {
    _make_canonical_profile review $'# review\n'
    _make_canonical_profile arch $'# arch\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review+arch"
    local missing="$TEST_TMP/missing-source"
    mkdir -p "$missing"

    local status=0
    _ctx_project_instructions "$home" 1 review "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" 2 arch "$missing" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ]

    printf '# arch\n' > "$missing/AGENTS.md"
    _ctx_project_instructions "$home" 1 review "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" 2 arch "$missing"

    [ -f "$home/instructions/ctx-profiles/0001-review.instructions.md" ]
    [ -f "$home/instructions/ctx-profiles/0002-arch.instructions.md" ]
    [ "$(cat "$home/instructions/ctx-profiles/.ctx-managed")" = "0001-review.instructions.md
0002-arch.instructions.md" ]
    [ -z "$(find "$home/instructions/ctx-profiles" -mindepth 1 -maxdepth 1 -name '.ctx-txn.*' -print 2>/dev/null)" ]
}

@test "Issue48: an interrupted projection transaction is recoverable on retry" {
    _make_canonical_profile review $'# review\n'
    _make_canonical_profile arch $'# arch\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review+arch"
    mkdir -p "$home/instructions/ctx-profiles"

    # Simulate a crash after the union manifest was written and one target
    # replaced: the manifest still covers the old stale name plus both desired
    # names, and a leftover per-transaction staging directory remains.
    printf '0001-review.instructions.md\n0001-old.instructions.md\n0002-arch.instructions.md\n' > "$home/instructions/ctx-profiles/.ctx-managed"
    printf 'old review\n' > "$home/instructions/ctx-profiles/0001-review.instructions.md"
    printf 'old stale\n' > "$home/instructions/ctx-profiles/0001-old.instructions.md"
    printf 'old arch\n' > "$home/instructions/ctx-profiles/0002-arch.instructions.md"
    mkdir -p "$home/instructions/ctx-profiles/.ctx-txn.crashed"
    printf 'partial\n' > "$home/instructions/ctx-profiles/.ctx-txn.crashed/0001-review.instructions.md"

    ctx review arch >/dev/null
    cmp -s <(printf -- '---\napplyTo: "**"\n---\n\n# review\n') "$home/instructions/ctx-profiles/0001-review.instructions.md"
    cmp -s <(printf -- '---\napplyTo: "**"\n---\n\n# arch\n') "$home/instructions/ctx-profiles/0002-arch.instructions.md"
    [ ! -e "$home/instructions/ctx-profiles/0001-old.instructions.md" ]
    [ "$(cat "$home/instructions/ctx-profiles/.ctx-managed")" = "0001-review.instructions.md
0002-arch.instructions.md" ]
    # A crashed transaction directory is never swept; it is ignored safely.
    [ -d "$home/instructions/ctx-profiles/.ctx-txn.crashed" ]
}

@test "Issue48: an unrelated .ctx.tmp.keep file survives activation and retry" {
    _make_canonical_profile review $'# review\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    mkdir -p "$home/instructions/ctx-profiles"
    printf 'keep me\n' > "$home/instructions/ctx-profiles/.ctx.tmp.keep"

    ctx review >/dev/null
    [ "$(cat "$home/instructions/ctx-profiles/.ctx.tmp.keep")" = "keep me" ]

    printf '# review v2\n' > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/AGENTS.md"
    ctx review >/dev/null
    [ "$(cat "$home/instructions/ctx-profiles/.ctx.tmp.keep")" = "keep me" ]
    [ -z "$(find "$home/instructions/ctx-profiles" -mindepth 1 -maxdepth 1 -name '.ctx-txn.*' -print 2>/dev/null)" ]
}

@test "Issue48: stale prune failure retains the expanded manifest and never deletes directory contents" {
    _make_canonical_profile review $'# review\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    mkdir -p "$home/instructions/ctx-profiles/0001-old.instructions.md"
    printf 'precious\n' > "$home/instructions/ctx-profiles/0001-old.instructions.md/inner.txt"
    printf '0001-old.instructions.md\n0001-review.instructions.md\n' > "$home/instructions/ctx-profiles/.ctx-managed"
    printf 'old review\n' > "$home/instructions/ctx-profiles/0001-review.instructions.md"

    local status=0
    ctx review >"$TEST_TMP/prune-fail.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/prune-fail.out")" == *"refusing to remove non-regular stale projection"* ]]
    # The expanded union manifest is retained so a retry remains possible.
    [ "$(cat "$home/instructions/ctx-profiles/.ctx-managed")" = "0001-old.instructions.md
0001-review.instructions.md" ]
    # Directory contents were never recursively deleted.
    [ "$(cat "$home/instructions/ctx-profiles/0001-old.instructions.md/inner.txt")" = "precious" ]
    # No transaction staging directory is left behind.
    [ -z "$(find "$home/instructions/ctx-profiles" -mindepth 1 -maxdepth 1 -name '.ctx-txn.*' -print 2>/dev/null)" ]
}

@test "Issue48: case-only projection label transition under a shared home removes the stale old-case projection" {
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/Review"
    printf '# review\n' > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/Review/AGENTS.md"
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/case-home"
    local pdir="$TEST_TMP/project-case-home"
    mkdir -p "$pdir" "$home"

    printf 'Review:@profile\nhome:%s\n' "$home" > "$pdir/.ctx"
    cd "$pdir"
    _ctx_load_ctx_file "$pdir/.ctx" >/dev/null
    [ -f "$home/instructions/ctx-profiles/0001-Review.instructions.md" ]

    # On a case-sensitive filesystem the old-case projection is a distinct
    # stale file that must be removed, not orphaned, when the label case flips.
    mv "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/Review" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review"
    printf 'review:@profile\nhome:%s\n' "$home" > "$pdir/.ctx"
    _ctx_load_ctx_file "$pdir/.ctx" >/dev/null
    [ -f "$home/instructions/ctx-profiles/0001-review.instructions.md" ]
    [ ! -e "$home/instructions/ctx-profiles/0001-Review.instructions.md" ]
    [ "$(cat "$home/instructions/ctx-profiles/.ctx-managed")" = "0001-review.instructions.md" ]
}

@test "Issue48: ordinary managed projection files update on reactivation" {
    _make_canonical_profile review $'# review\n'
    ctx review >/dev/null
    local proj="$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md"

    printf '# review v2\n' > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/AGENTS.md"
    ctx review >/dev/null
    cmp -s <(printf -- '---\napplyTo: "**"\n---\n\n# review v2\n') "$proj"
    [ ! -L "$proj" ]
}

@test "Issue48: projection activation works with noclobber set" {
    set -o noclobber
    _make_canonical_profile review $'# review\n'
    ctx review >/dev/null
    local proj="$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md"
    [ -f "$proj" ]

    # Reactivation must also work: no transaction step clobbers an existing
    # file with `>` (temps are new files, targets/manifest are renamed).
    printf '# review v2\n' > "$TEST_TMP/agents-v2"
    mv -f "$TEST_TMP/agents-v2" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/AGENTS.md"
    ctx review >/dev/null
    cmp -s <(printf -- '---\napplyTo: "**"\n---\n\n# review v2\n') "$proj"
    set +o noclobber
}

@test "Issue48: sanitizer replaces each disallowed Unicode character once across locales" {
    local saved_lc_all="${LC_ALL-}" lc_all_set=0
    [ -n "${LC_ALL+x}" ] && lc_all_set=1
    restore_lc_all() {
        if [ "$lc_all_set" -eq 1 ]; then export LC_ALL="$saved_lc_all"; else unset LC_ALL; fi
    }
    trap restore_lc_all EXIT

    export LC_ALL=en_US.UTF-8
    [ "$(_ctx_sanitize_context_name 'café')" = 'caf_' ]
    [ "$(_ctx_sanitize_context_name 'caféñ')" = 'caf__' ]
    [ "$(_ctx_sanitize_context_name 'a𝄞b')" = 'a_b' ]
    export LC_ALL=C
    [ "$(_ctx_sanitize_context_name 'café')" = 'caf_' ]
    [ "$(_ctx_sanitize_context_name 'caféñ')" = 'caf__' ]
    [ "$(_ctx_sanitize_context_name 'a𝄞b')" = 'a_b' ]
    restore_lc_all
    trap - EXIT
}

@test "Issue48: non-ASCII manifest names are rejected under a UTF-8 locale" {
    local saved_lc_all="${LC_ALL-}" lc_all_set=0
    [ -n "${LC_ALL+x}" ] && lc_all_set=1
    restore_lc_all() {
        if [ "$lc_all_set" -eq 1 ]; then export LC_ALL="$saved_lc_all"; else unset LC_ALL; fi
    }
    trap restore_lc_all EXIT

    export LC_ALL=en_US.UTF-8
    # A collation range like [a-z] must not admit accented letters in the
    # manifest grammar; the ASCII-stable check runs under LC_ALL=C internally.
    _ctx_valid_projection_name '0001-café.instructions.md' && return 1
    _ctx_valid_projection_name '0001-ok.instructions.md' || return 1
    _ctx_valid_projection_name '1-short.instructions.md' && return 1
    _ctx_valid_projection_name '0001-bad/name.instructions.md' && return 1
    restore_lc_all
    trap - EXIT
}

@test "Issue48: direct .ctx canonical profile outside the configured profiles root fails atomically" {
    local outside="$TEST_TMP/outside-canonical"
    mkdir -p "$outside"
    printf '# outside canonical\n' > "$outside/AGENTS.md"
    local sentinel="$outside/AGENTS.md" before
    before="$(cksum "$sentinel")"

    local proj="$TEST_TMP/project-canon-outside"
    mkdir -p "$proj"
    printf 'outside:%s\n' "$outside" > "$proj/.ctx"
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
    export COPILOT_HOME=previous-home
    export COPILOT_SKILLS_DIRS=previous-skills
    _ctx_auto_load_dir=""
    _ctx_reset_active_record

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/canon-outside.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/canon-outside.out")" == *"outside the configured profiles root"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]
    [ "$COPILOT_SKILLS_DIRS" = previous-skills ]
    [ ! -e "$proj/project-canon-outside.code-workspace" ]
    [ ! -d "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/outside" ]
    [ "$(cksum "$sentinel")" = "$before" ]
}

@test "Issue48: in-root canonical profile symlink whose target escapes the profiles root fails atomically" {
    local outside="$TEST_TMP/outside-symlink-target"
    mkdir -p "$outside"
    printf '# outside symlink target\n' > "$outside/AGENTS.md"
    local sentinel="$outside/AGENTS.md" before
    before="$(cksum "$sentinel")"
    ln -s "$outside" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/evil"

    local proj="$TEST_TMP/project-canon-symlink-escape"
    mkdir -p "$proj"
    printf 'evil:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/evil" > "$proj/.ctx"
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
    export COPILOT_HOME=previous-home
    _ctx_auto_load_dir=""
    _ctx_reset_active_record

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/canon-symlink.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/canon-symlink.out")" == *"outside the configured profiles root"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]
    [ ! -e "$proj/project-canon-symlink-escape.code-workspace" ]
    [ ! -d "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/evil" ]
    [ "$(cksum "$sentinel")" = "$before" ]
}

@test "Issue48: direct .ctx canonical profile inside the configured root still activates and identifier activation remains compatible" {
    _make_canonical_profile review $'# review\n'
    _make_canonical_profile arch $'# arch\n'
    _make_canonical_profile ghost $'# ghost unselected\n'
    _make_canonical_skill review review-skill
    _make_canonical_skill arch arch-skill
    _make_canonical_skill ghost ghost-skill

    # Capture every source so activation can be proven read-only.
    local review_agents="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/AGENTS.md"
    local arch_agents="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/arch/AGENTS.md"
    local ghost_agents="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/ghost/AGENTS.md"
    local review_skill_md="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.agents/skills/review-skill/SKILL.md"
    local arch_skill_md="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/arch/.agents/skills/arch-skill/SKILL.md"
    local ghost_skill_md="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/ghost/.agents/skills/ghost-skill/SKILL.md"
    local review_agents_sum arch_agents_sum ghost_agents_sum
    local review_skill_sum arch_skill_sum ghost_skill_sum
    review_agents_sum="$(cksum "$review_agents")"
    arch_agents_sum="$(cksum "$arch_agents")"
    ghost_agents_sum="$(cksum "$ghost_agents")"
    review_skill_sum="$(cksum "$review_skill_md")"
    arch_skill_sum="$(cksum "$arch_skill_md")"
    ghost_skill_sum="$(cksum "$ghost_skill_md")"

    local proj="$TEST_TMP/project-canon-inroot"
    mkdir -p "$proj"
    printf 'review:%s\narch:@profile\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    ctx load "$proj/.ctx" >/dev/null

    # Mixed direct-path + identifier compatibility is preserved.
    [ "$AI_CTX_PROFILES" = "review+arch" ]

    # Projections are deterministic and keyed to selected entry order; only the
    # selected canonical entries appear, never the unselected ghost profile.
    local projections
    projections="$(cd "$COPILOT_HOME/instructions/ctx-profiles" && ls -1 *.instructions.md | sort)"
    [ "$projections" = "$(printf '0001-review.instructions.md\n0002-arch.instructions.md')" ]
    [ "$(cat "$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed")" = "$(printf '0001-review.instructions.md\n0002-arch.instructions.md')" ]
    [ ! -e "$COPILOT_HOME/instructions/ctx-profiles/0003-ghost.instructions.md" ]

    # Only the selected profiles' distinct skills are linked; ghost is absent.
    local links
    links="$(cd "$COPILOT_HOME/skills" && ls -1 | sort)"
    [ "$links" = "$(printf 'arch-skill\nreview-skill')" ]
    [ "$(readlink -f "$COPILOT_HOME/skills/review-skill")" = "$(readlink -f "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.agents/skills/review-skill")" ]
    [ "$(readlink -f "$COPILOT_HOME/skills/arch-skill")" = "$(readlink -f "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/arch/.agents/skills/arch-skill")" ]
    [ ! -e "$COPILOT_HOME/skills/ghost-skill" ]

    # Sources are byte-identical after activation.
    [ "$(cksum "$review_agents")" = "$review_agents_sum" ]
    [ "$(cksum "$arch_agents")" = "$arch_agents_sum" ]
    [ "$(cksum "$ghost_agents")" = "$ghost_agents_sum" ]
    [ "$(cksum "$review_skill_md")" = "$review_skill_sum" ]
    [ "$(cksum "$arch_skill_md")" = "$arch_skill_sum" ]
    [ "$(cksum "$ghost_skill_md")" = "$ghost_skill_sum" ]
}

@test "Issue48: intermediate in-root symlink followed by .. cannot escape the profiles root" {
    local outside_dir="$TEST_TMP/outside-escape/dir"
    local outside_profile="$TEST_TMP/outside-escape/outside-profile"
    mkdir -p "$outside_dir" "$outside_profile"
    printf '# outside\n' > "$outside_profile/AGENTS.md"
    ln -s "$outside_dir" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/escape-link"

    # Filesystem order resolves escape-link -> outside/dir, then .. -> the
    # outside parent; realpath -m follows that order, so this canonical
    # profile is outside the root and must be rejected.
    local crafted="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/escape-link/../outside-profile"
    ! _ctx_canonical_profile_within_root "$crafted"

    local proj="$TEST_TMP/project-canon-symlink-dotdot"
    mkdir -p "$proj"
    printf 'evil:%s\n' "$crafted" > "$proj/.ctx"
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
    export COPILOT_HOME=previous-home
    _ctx_auto_load_dir=""
    _ctx_reset_active_record

    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/canon-dotdot.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/canon-dotdot.out")" == *"outside the configured profiles root"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]
    [ ! -e "$proj/project-canon-symlink-dotdot.code-workspace" ]
}

@test "Issue48: zsh sanitizer emits ASCII names without escape text and survives reactivation + ctx check (zsh-gated)" {
    if ! command -v zsh >/dev/null 2>&1; then
        skip "zsh is not installed"
    fi
    _make_canonical_profile review $'# review\n'
    local pdir="$TEST_TMP/project-zsh"
    mkdir -p "$pdir"
    printf 'review:@profile\n' > "$pdir/.ctx"

    local zsh_path
    zsh_path="$(command -v zsh)"
    # Run entirely under zsh -f (no user startup files) so the sanitizer's
    # printf '%b' octal decoding is exercised in zsh (which leaves the bare
    # \NNN form literal). A broken sanitizer corrupts home/projection/manifest
    # names, either activation fails, and ctx check fails.
    run env PATH="/usr/local/bin:/usr/bin:/bin:$PATH" "$zsh_path" -f -c '
        source "$1"
        printf "a=%s\n" "$(_ctx_sanitize_context_name review)"
        printf "c=%s\n" "$(_ctx_sanitize_context_name café)"
        ctx review >/dev/null 2>&1
        printf "act1=%s\n" "$?"
        ctx review >/dev/null 2>&1
        printf "act2=%s\n" "$?"
        cd "$2"
        ctx check >/dev/null 2>&1
        printf "check=%s\n" "$?"
        printf "proj=%s\n" "$(basename "$COPILOT_HOME"/instructions/ctx-profiles/*.instructions.md)"
        printf "manifest=%s\n" "$(<"$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed")"
    ' -- "$CTX_SRC" "$pdir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"a=review"* ]]
    [[ "$output" == *"c=caf_"* ]]
    [[ "$output" == *"act1=0"* ]]
    [[ "$output" == *"act2=0"* ]]
    [[ "$output" == *"check=0"* ]]
    [[ "$output" == *"proj=0001-review.instructions.md"* ]]
    [[ "$output" == *"manifest=0001-review.instructions.md"* ]]
    [[ "$output" != *"\\"* ]]
}

@test "opt-in external profile root accepts canonical aliases and direct paths" {
    _make_profile team
    local external_root="$TEST_TMP/external-profiles"
    local external_profile="$external_root/task-scaffold"
    mkdir -p "$external_profile"
    printf '# task scaffold instructions\n' > "$external_profile/AGENTS.md"
    ln -s "$external_profile" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/task-scaffold"
    export AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT="$external_root"

    local proj="$TEST_TMP/project-external-profile"
    mkdir -p "$proj"
    printf 'team:@profile\ntask-scaffold:@profile\n' > "$proj/.ctx"
    local status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/external-alias.out" 2>&1 || status=$?
    [ "$status" -eq 0 ]
    [ "$AI_CTX_PROFILES" = "team+task-scaffold" ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/team" ]
    [ -f "$COPILOT_HOME/instructions/ctx-profiles/0002-task-scaffold.instructions.md" ]
    cd "$proj"
    status=0
    ctx check >"$TEST_TMP/external-check.out" 2>&1 || status=$?
    [ "$status" -eq 0 ]
    [[ "$(<"$TEST_TMP/external-check.out")" == *"ctx check: PASS"* ]]

    local direct_proj="$TEST_TMP/project-external-direct-path"
    mkdir -p "$direct_proj"
    printf 'team:%s\ntask-scaffold:%s\n' "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/team" "$external_profile" > "$direct_proj/.ctx"
    status=0
    _ctx_load_ctx_file "$direct_proj/.ctx" >"$TEST_TMP/external-direct.out" 2>&1 || status=$?
    [ "$status" -eq 0 ]
    [ "$AI_CTX_PROFILES" = "team+task-scaffold" ]
}

@test "external profile allowlist rejects untrusted links and invalid roots without mutation" {
    _make_profile review
    local trusted_root="$TEST_TMP/trusted-profiles"
    local untrusted_profile="$TEST_TMP/untrusted/task-scaffold"
    mkdir -p "$trusted_root" "$untrusted_profile"
    printf '# untrusted\n' > "$untrusted_profile/AGENTS.md"
    ln -s "$untrusted_profile" "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/evil"
    export AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT="$trusted_root"
    export AI_CTX_PROFILES=previous
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=previous-dirs
    export COPILOT_HOME=previous-home

    local status=0
    ctx evil >"$TEST_TMP/external-untrusted.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/external-untrusted.out")" == *"invalid profile identifier"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]

    local proj="$TEST_TMP/project-untrusted-direct-canonical"
    mkdir -p "$proj"
    printf 'evil:%s\n' "$untrusted_profile" > "$proj/.ctx"
    status=0
    _ctx_load_ctx_file "$proj/.ctx" >"$TEST_TMP/external-untrusted-direct.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/external-untrusted-direct.out")" == *"outside the configured profiles root"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]

    export AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT="$TEST_TMP/missing-profiles-root"
    status=0
    ctx review >"$TEST_TMP/external-missing-root.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/external-missing-root.out")" == *"external profiles root"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = previous-dirs ]
    [ "$COPILOT_HOME" = previous-home ]

    export AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT="relative/profiles"
    status=0
    ctx review >"$TEST_TMP/external-relative-root.out" 2>&1 || status=$?
    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/external-relative-root.out")" == *"must be an absolute path"* ]]
    [ "$AI_CTX_PROFILES" = previous ]
}

@test "Issue48: zsh projects mixed canonical/legacy instructions and applies collision skip (zsh-gated)" {
    if ! command -v zsh >/dev/null 2>&1; then
        skip "zsh is not installed"
    fi
    _make_profile review dup-skill
    mkdir -p "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills/keep-skill"
    printf -- '---\nname: keep-skill\ndescription: test\n---\n' \
        > "$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/.github/skills/keep-skill/SKILL.md"
    _make_canonical_profile canon $'# canon\n'
    _make_canonical_skill canon Dup-Skill
    local log="$TEST_TMP/zsh-mixed-collision.err"

    local zsh_path
    zsh_path="$(command -v zsh)"
    # Run entirely under zsh -f (no user startup files) to exercise the mixed
    # ordered projection and case-insensitive collision skip under zsh's
    # default array indexing. Values are bracketed so the outer assertions
    # compare them exactly rather than as path prefixes.
    run env PATH="/usr/local/bin:/usr/bin:/bin:$PATH" "$zsh_path" -f -c '
        source "$1"
        if ctx review canon 2>"$3"; then
            printf "ctx_status=0\n"
        else
            printf "ctx_status=%s\n" "$?"
        fi
        printf "profiles=[%s]\n" "$AI_CTX_PROFILES"
        printf "customdirs=[%s]\n" "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
        printf "proj2=[%s]\n" "$([[ -f "$COPILOT_HOME/instructions/ctx-profiles/0002-canon.instructions.md" ]] && echo present || echo absent)"
        printf "proj1=[%s]\n" "$([[ -e "$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md" ]] && echo present || echo absent)"
        printf "keep_skill=[%s]\n" "$([[ -L "$COPILOT_HOME/skills/keep-skill" ]] && echo linked || echo absent)"
        printf "legacy_skill=[%s]\n" "$([[ -e "$COPILOT_HOME/skills/dup-skill" ]] && echo present || echo absent)"
        printf "canon_skill=[%s]\n" "$([[ -e "$COPILOT_HOME/skills/Dup-Skill" ]] && echo present || echo absent)"
        printf "manifest=[%s]\n" "$(cat "$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed")"
    ' -- "$CTX_SRC" "$AI_CTX_PROFILES_CONFIG_ROOT" "$log"

    [ "$status" -eq 0 ]
    [[ "$output" == *"ctx_status=0"* ]]
    [[ "$output" == *"profiles=[review+canon]"* ]]
    printf '%s\n' "$output" | grep -qxF "customdirs=[$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review]"
    printf '%s\n' "$output" | grep -qxF "manifest=[0002-canon.instructions.md]"
    [[ "$output" == *"proj2=[present]"* ]]
    [[ "$output" == *"proj1=[absent]"* ]]
    [[ "$output" == *"keep_skill=[linked]"* ]]
    [[ "$output" == *"legacy_skill=[absent]"* ]]
    [[ "$output" == *"canon_skill=[absent]"* ]]
    [[ "$(<"$log")" == *"collision"* ]]
}

@test "Issue48: zsh Mode B/C canonical preflight rejection leaves state untouched (zsh-gated)" {
    if ! command -v zsh >/dev/null 2>&1; then
        skip "zsh is not installed"
    fi
    _make_profile base base-skill
    _make_canonical_profile review $'# review\n'
    local logdir="$TEST_TMP/zsh-reject"
    local privtmp="$TEST_TMP/zsh-priv-tmp"
    local projdir="$TEST_TMP/zsh-proj"
    mkdir -p "$logdir" "$privtmp" "$projdir"

    local zsh_path
    zsh_path="$(command -v zsh)"
    # Establish a valid prior Mode A activation, then prove both B and C reject
    # the canonical selection before any mutation: the prior environment and
    # the session-local activation record must survive, TMPDIR must stay empty
    # (Mode C created no temp home), and each error must name the profile and
    # require synthetic-home.
    run env PATH="/usr/local/bin:/usr/bin:/bin:$PATH" "$zsh_path" -f -c '
        source "$1"
        cd "$5"
        export TMPDIR="$4"
        if ! ctx base >/dev/null 2>&1; then
            printf "prior_activation=failed\n"
            exit 1
        fi
        printf "prior_context=[%s]\n" "$_ctx_active_context"
        printf "prior_mode=[%s]\n" "$_ctx_active_mode"
        prior_home="$_ctx_active_home_value"
        prior_custom="$_ctx_active_custom_dirs"
        prior_env_home="$COPILOT_HOME"
        prior_env_custom_state="$([ "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS+set}" = set ] && printf 'set:%s' "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" || printf 'unset')"
        prior_env_skills_state="$([ "${COPILOT_SKILLS_DIRS+set}" = set ] && printf 'set:%s' "$COPILOT_SKILLS_DIRS" || printf 'unset')"
        for mode in global-user ephemeral-clean; do
            export AI_CTX_PROFILES_COPILOT_MODE="$mode"
            if ctx review 2>"${3}/${mode}.err"; then
                printf "%s_status=unexpected-success\n" "$mode"
            else
                printf "%s_status=rejected\n" "$mode"
            fi
            printf "%s_record_context=[%s]\n" "$mode" "$_ctx_active_context"
            printf "%s_record_mode=[%s]\n" "$mode" "$_ctx_active_mode"
            printf "%s_record_survived=%s\n" "$mode" "$([ "$_ctx_active_context" = base ] && [ "$_ctx_active_mode" = synthetic-home ] && [ "$_ctx_active_home_value" = "$prior_home" ] && [ "$_ctx_active_custom_dirs" = "$prior_custom" ] && printf yes || printf no)"
            printf "%s_env_context=[%s]\n" "$mode" "$AI_CTX_PROFILES"
            printf "%s_env_home_unchanged=%s\n" "$mode" "$([ "$COPILOT_HOME" = "$prior_env_home" ] && printf yes || printf no)"
            curr_env_custom_state="$([ "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS+set}" = set ] && printf 'set:%s' "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" || printf 'unset')"
            curr_env_skills_state="$([ "${COPILOT_SKILLS_DIRS+set}" = set ] && printf 'set:%s' "$COPILOT_SKILLS_DIRS" || printf 'unset')"
            printf "%s_env_custom=[%s]\n" "$mode" "${curr_env_custom_state#set:}"
            printf "%s_env_custom_unchanged=%s\n" "$mode" "$([ "$curr_env_custom_state" = "$prior_env_custom_state" ] && printf yes || printf no)"
            printf "%s_env_skills=[%s]\n" "$mode" "${curr_env_skills_state#set:}"
            printf "%s_env_skills_unchanged=%s\n" "$mode" "$([ "$curr_env_skills_state" = "$prior_env_skills_state" ] && printf yes || printf no)"
            printf "%s_names_profile=%s\n" "$mode" "$(grep -c "review" "${3}/${mode}.err")"
            printf "%s_names_synthetic=%s\n" "$mode" "$(grep -c "synthetic-home" "${3}/${mode}.err")"
        done
        printf "tmpdir_empty=%s\n" "$([ -z "$(ls -A "$4")" ] && printf yes || printf no)"
    ' -- "$CTX_SRC" "$AI_CTX_PROFILES_CONFIG_ROOT" "$logdir" "$privtmp" "$projdir"

    [ "$status" -eq 0 ]
    [[ "$output" != *"prior_activation=failed"* ]]
    [[ "$output" == *"prior_context=[base]"* ]]
    [[ "$output" == *"prior_mode=[synthetic-home]"* ]]
    [[ "$output" == *"global-user_status=rejected"* ]]
    [[ "$output" == *"ephemeral-clean_status=rejected"* ]]
    [[ "$output" == *"global-user_record_survived=yes"* ]]
    [[ "$output" == *"ephemeral-clean_record_survived=yes"* ]]
    [[ "$output" == *"global-user_env_context=[base]"* ]]
    [[ "$output" == *"ephemeral-clean_env_context=[base]"* ]]
    [[ "$output" == *"global-user_env_home_unchanged=yes"* ]]
    [[ "$output" == *"ephemeral-clean_env_home_unchanged=yes"* ]]
    [[ "$output" == *"global-user_env_custom=[$AI_CTX_PROFILES_CONFIG_ROOT/profiles/base]"* ]]
    [[ "$output" == *"global-user_env_custom_unchanged=yes"* ]]
    [[ "$output" == *"global-user_env_skills=[unset]"* ]]
    [[ "$output" == *"global-user_env_skills_unchanged=yes"* ]]
    [[ "$output" == *"ephemeral-clean_env_custom=[$AI_CTX_PROFILES_CONFIG_ROOT/profiles/base]"* ]]
    [[ "$output" == *"ephemeral-clean_env_custom_unchanged=yes"* ]]
    [[ "$output" == *"ephemeral-clean_env_skills=[unset]"* ]]
    [[ "$output" == *"ephemeral-clean_env_skills_unchanged=yes"* ]]
    [[ "$output" == *"global-user_names_profile=1"* ]]
    [[ "$output" == *"global-user_names_synthetic=1"* ]]
    [[ "$output" == *"ephemeral-clean_names_profile=1"* ]]
    [[ "$output" == *"ephemeral-clean_names_synthetic=1"* ]]
    [[ "$output" == *"tmpdir_empty=yes"* ]]
    [ ! -d "$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review" ]
}

# --- Issue #48 evidence-map gap coverage -----------------------------------

_setup_check_home() {
    # $1: canonical profile label. Creates a project .ctx, activates it, and
    # leaves the shell cwd at the project with a matching Mode A record.
    local label="$1"
    _make_canonical_profile "$label" $'# '"$label"$'\n'
    local proj="$TEST_TMP/project-check-$label"
    mkdir -p "$proj"
    printf '%s:@profile\n' "$label" > "$proj/.ctx"
    cd "$proj"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
}

@test "Issue48: source YAML-like frontmatter is copied as body bytes after the fixed header" {
    _make_canonical_profile review $'---\nname: review\n---\n# body\n'
    local source="$AI_CTX_PROFILES_CONFIG_ROOT/profiles/review/AGENTS.md"
    local before
    before="$(cksum "$source")"

    ctx review >/dev/null
    local proj="$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md"
    { printf -- '---\napplyTo: "**"\n---\n\n'; printf -- '---\nname: review\n---\n# body\n'; } > "$TEST_TMP/expected-frontmatter"
    cmp -s "$proj" "$TEST_TMP/expected-frontmatter"
    [ "$(cksum "$source")" = "$before" ]
}

@test "Issue48: a linked ctx-managed manifest fails activation without touching the sentinel" {
    _make_canonical_profile review $'# review\n'
    local home="$AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT/review"
    local outside="$TEST_TMP/outside-manifest"
    printf '0001-review.instructions.md\n' > "$outside"
    local before
    before="$(cksum "$outside")"
    mkdir -p "$home/instructions/ctx-profiles"
    ln -s "$outside" "$home/instructions/ctx-profiles/.ctx-managed"
    export AI_CTX_PROFILES=previous

    local status=0
    ctx review >"$TEST_TMP/linked-manifest.out" 2>&1 || status=$?

    [ "$status" -ne 0 ]
    [[ "$(<"$TEST_TMP/linked-manifest.out")" == *"malformed projection manifest"* ]]
    [ "$(cksum "$outside")" = "$before" ]
    [ -L "$home/instructions/ctx-profiles/.ctx-managed" ]
    [ ! -e "$home/instructions/ctx-profiles/0001-review.instructions.md" ]
    [ "$AI_CTX_PROFILES" = previous ]
}

@test "Issue48: ctx check fails on altered canonical instruction bytes without changing them" {
    _setup_check_home review
    local target="$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md"
    printf 'tampered bytes\n' > "$target"
    local before
    before="$(cksum "$target")"

    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL instruction:0001-review.instructions.md"* ]]
    [ "$(cksum "$target")" = "$before" ]
}

@test "Issue48: ctx check fails on an unmanifested desired projection without changing the manifest" {
    _setup_check_home review
    local manifest="$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed"
    local projection="$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md"
    : > "$manifest"
    local before_manifest before_projection
    before_manifest="$(cksum "$manifest")"
    before_projection="$(cksum "$projection")"

    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL instruction:0001-review.instructions.md"* ]]
    [ "$(cksum "$manifest")" = "$before_manifest" ]
    [ "$(cksum "$projection")" = "$before_projection" ]
}

@test "Issue48: ctx check fails read-only on an unsafe instructions directory with canonical entries" {
    _setup_check_home review
    local home="$COPILOT_HOME"
    local outside="$TEST_TMP/outside-check-parent"
    mkdir -p "$outside"
    rm -rf "$home/instructions"
    ln -s "$outside" "$home/instructions"

    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL instruction:0001-review.instructions.md"* ]]
    [ ! -e "$outside/ctx-profiles" ]
    [ -z "$(ls -A "$outside")" ]
    [ -L "$home/instructions" ]
}

@test "Issue48: ctx check fails read-only on a linked ctx-profiles directory with canonical entries" {
    _setup_check_home review
    local home="$COPILOT_HOME"
    local outside="$TEST_TMP/outside-check-profiles"
    mkdir -p "$outside"
    rm -rf "$home/instructions/ctx-profiles"
    ln -s "$outside" "$home/instructions/ctx-profiles"

    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL instruction:0001-review.instructions.md"* ]]
    [ -z "$(ls -A "$outside")" ]
    [ -L "$home/instructions/ctx-profiles" ]
}

@test "Issue48: ctx check fails read-only on a missing ctx-managed manifest with canonical entries" {
    _setup_check_home review
    rm -f "$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed"

    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL instruction:manifest"* ]]
    [ ! -e "$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed" ]
}

@test "Issue48: ctx check fails read-only on a linked ctx-managed manifest without touching the sentinel" {
    _setup_check_home review
    local manifest="$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed"
    local outside="$TEST_TMP/outside-check-manifest"
    printf '0001-review.instructions.md\n' > "$outside"
    local before
    before="$(cksum "$outside")"
    rm -f "$manifest"
    ln -s "$outside" "$manifest"

    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL instruction:manifest"* ]]
    [ "$(cksum "$outside")" = "$before" ]
    [ -L "$manifest" ]
}

@test "Issue48: ctx check fails read-only on a malformed ctx-managed manifest with canonical entries" {
    _setup_check_home review
    local manifest="$COPILOT_HOME/instructions/ctx-profiles/.ctx-managed"
    local projection="$COPILOT_HOME/instructions/ctx-profiles/0001-review.instructions.md"
    printf 'bad name\n' > "$manifest"
    local before_manifest before_projection
    before_manifest="$(cksum "$manifest")"
    before_projection="$(cksum "$projection")"

    run ctx check

    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL instruction:manifest"* ]]
    [ "$(cksum "$manifest")" = "$before_manifest" ]
    [ "$(cksum "$projection")" = "$before_projection" ]
}

@test "Issue67: ctx current fails when the missing .NET engine DLL path does not exist" {
    # The shell adapter must delegate `current` to the .NET 10 engine named by
    # CTX_ENGINE_DLL. A missing DLL is a hard failure with no old-shell
    # fallback, even when no profile is active.
    local missing_dll="$TEST_TMP/missing-engine/no-such-ctx-engine.dll"
    [ ! -e "$missing_dll" ]

    local prior_set=0 prior_value=""
    if [ -n "${CTX_ENGINE_DLL+x}" ]; then
        prior_set=1
        prior_value="$CTX_ENGINE_DLL"
    fi
    export CTX_ENGINE_DLL="$missing_dll"

    local status=0
    ctx current >"$TEST_TMP/engine-missing.out" 2>&1 || status=$?

    if [ "$prior_set" -eq 1 ]; then
        export CTX_ENGINE_DLL="$prior_value"
    else
        unset CTX_ENGINE_DLL
    fi

    local out
    out="$(<"$TEST_TMP/engine-missing.out")"

    [ "$status" -ne 0 ]
    [[ "$out" != *"No active AI context."* ]]
    [[ "$out" == *"$missing_dll"* ]]
    [[ "${out,,}" == *"engine"* ]]
}
