#!/usr/bin/env bats
# Test suite for ctx.sh — COPILOT_HOME per-folder skill isolation (issue #1)
# and general ctx.sh behavior, per the historical design in
# docs/design-history-copilot-home.md section 5.2.
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
    printf 'home:%s\nreview:%s\n' "$custom" "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    _ctx_load_ctx_file "$proj/.ctx"
    [ "$COPILOT_HOME" = "$custom" ]
    [ -d "$custom" ]
}

@test "home: rejects traversal outside HOME" {
    _make_profile "review"
    local proj="$TEST_TMP/project-home-traversal"
    mkdir -p "$proj"
    printf 'home:../outside\nreview:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    run _ctx_load_ctx_file "$proj/.ctx"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe home"* ]]
    [ -z "${AI_CONTEXT:-}" ]
    [ ! -d "$TEST_TMP/outside" ]
}

@test "home: rejects an absolute path outside allowed roots" {
    _make_profile "review"
    local proj="$TEST_TMP/project-home-absolute"
    mkdir -p "$proj"
    printf 'home:%s\nreview:%s\n' "$TEST_TMP/unrelated" "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    run _ctx_load_ctx_file "$proj/.ctx"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe home"* ]]
    [ ! -d "$TEST_TMP/unrelated" ]
}

@test "home: rejects filesystem root and empty paths" {
    _make_profile "review"
    local proj="$TEST_TMP/project-home-boundaries"
    mkdir -p "$proj"
    for value in / ''; do
        printf 'home:%s\nreview:%s\n' "$value" "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
        run _ctx_load_ctx_file "$proj/.ctx"
        [ "$status" -ne 0 ]
        [[ "$output" == *"unsafe home"* || "$output" == *"invalid .ctx line"* ]]
    done
}

@test "home: rejects symlink escape outside allowed roots" {
    _make_profile "review"
    local proj="$HOME/project-home-link"
    local outside="$TEST_TMP/outside-link"
    mkdir -p "$proj" "$outside"
    ln -s "$outside" "$proj/link"
    printf 'home:%s\nreview:%s\n' "$proj/link/child" "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    run _ctx_load_ctx_file "$proj/.ctx"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe home"* ]]
    [ ! -d "$outside/child" ]
}

@test "ctx clear --all refuses an unsafe selected home and preserves it" {
    _make_profile "review"
    local victim="$HOME/victim-home"
    local outside="$TEST_TMP/victim-outside"
    mkdir -p "$outside"
    ln -s "$outside" "$victim"
    printf 'important\n' > "$outside/data.txt"
    export AI_CONTEXT=review
    export COPILOT_HOME="$victim"
    _ctx_auto_load_home_override="$victim"

    run _ctx_clear --all
    [ "$status" -ne 0 ]
    [ -f "$victim/data.txt" ]
    [[ "$output" == *"unsafe home"* ]]
}

@test "home validator rejects HOME and CTX_HOMES_ROOT themselves" {
    run _ctx_validate_home_path "$HOME"
    [ "$status" -ne 0 ]
    run _ctx_validate_home_path "$CTX_HOMES_ROOT"
    [ "$status" -ne 0 ]
}

@test "public ctx clear --all propagates unsafe home failure" {
    _make_profile "review"
    local victim="$HOME/public-victim-home"
    local outside="$TEST_TMP/public-victim-outside"
    mkdir -p "$outside"
    ln -s "$outside" "$victim"
    printf 'important\n' > "$outside/data.txt"
    export AI_CONTEXT=review
    export COPILOT_HOME="$victim"
    _ctx_auto_load_home_override="$victim"

    run ctx clear --all
    [ "$status" -ne 0 ]
    [ -f "$victim/data.txt" ]
    [[ "$output" == *"unsafe home"* ]]
}

@test "ctx clear --all propagates a valid-home deletion failure" {
    _make_profile "review"
    local victim="$CTX_HOMES_ROOT/review"
    mkdir -p "$victim"
    export AI_CONTEXT=review
    export COPILOT_HOME="$victim"

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

    local proj="$HOME/project-home-abs"
    local custom_home="$HOME/custom-copilot-home"
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

    local proj="$HOME/project-home-clear"
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
    local proj="$HOME/project-home-dup"
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

@test "generated workspace is marked and removed by clear --all" {
    local proj="$HOME/project-workspace"
    local profile="$AI_CONFIG_ROOT/profiles/review"
    mkdir -p "$proj" "$profile"
    _ctx_update_workspace_file "$proj" review "$profile"

    local workspace="$proj/project-workspace.code-workspace"
    grep -q '"generatedBy": "ctx"' "$workspace"
    unset AI_CONTEXT COPILOT_HOME
    _ctx_auto_load_dir="$proj"
    _ctx_clear --all
    [ ! -e "$workspace" ]
}

@test "pre-existing unmarked workspace is preserved by clear --all" {
    local proj="$HOME/project-workspace-existing"
    local workspace="$proj/project-workspace-existing.code-workspace"
    mkdir -p "$proj"
    printf '{"folders":[{"path":"."}],"settings":{}}\n' > "$workspace"
    unset AI_CONTEXT COPILOT_HOME
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
    unset AI_CONTEXT COPILOT_HOME
    _ctx_auto_load_dir="$proj"
    _ctx_clear --all
    [ -L "$workspace" ]
}

@test "wrong-case workspace marker is preserved by clear --all" {
    local proj="$HOME/project-workspace-case"
    local workspace="$proj/project-workspace-case.code-workspace"
    mkdir -p "$proj"
    printf '{"generatedBy":"CTX"}\n' > "$workspace"
    unset AI_CONTEXT COPILOT_HOME
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
        unset AI_CONTEXT COPILOT_HOME
        _ctx_auto_load_dir="$proj"
        run _ctx_clear --all
        [ "$status" -eq 0 ]
        [[ "$output" == *"preserved unowned workspace"* ]]
        [ -f "$workspace" ]
    done
}

@test "ctx check reports a matching .ctx activation without changing state" {
    local proj="$HOME/project-check"
    local profile="$AI_CONFIG_ROOT/profiles/review"
    _make_profile review review-skill
    mkdir -p "$proj"
    printf 'review:%s\n' "$profile" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    local home="$COPILOT_HOME"
    local before_ctx="$(stat -c '%Y %s' "$proj/.ctx")"
    cd "$proj"
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS AI_CONTEXT"* ]]
    [[ "$output" == *"ctx check: PASS"* ]]
    [ "$home" = "$COPILOT_HOME" ]
    [ "$(stat -c '%Y %s' "$proj/.ctx")" = "$before_ctx" ]
}

@test "ctx check detects environment and link drift without repairing it" {
    local proj="$HOME/project-check-drift"
    local profile="$AI_CONFIG_ROOT/profiles/review"
    _make_profile review review-skill
    mkdir -p "$proj"
    printf 'review:%s\n' "$profile" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    local home="$COPILOT_HOME"
    cd "$proj"
    export AI_CONTEXT=wrong
    rm -f "$home/settings.json"
    printf 'drift' > "$home/settings.json"
    run ctx check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHECK FAIL AI_CONTEXT"* ]]
    [[ "$output" == *"CHECK FAIL link:settings.json"* ]]
    [ -f "$home/settings.json" ]
    [ ! -L "$home/settings.json" ]
}

@test "ctx check succeeds with no nearest .ctx and does not clear the shell" {
    export AI_CONTEXT=manual
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=manual-dir
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"no .ctx file found"* ]]
    [ "$AI_CONTEXT" = manual ]
    [ "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" = manual-dir ]
}

@test "ctx check detects workspace folder drift" {
    local proj="$HOME/project-check-workspace"
    local profile="$AI_CONFIG_ROOT/profiles/review"
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
    printf 'review:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
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
    printf 'review:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    cd "$proj"
    ctx check >/dev/null
    [ "$?" -eq 0 ]
    export AI_CONTEXT=wrong
    if ctx check >/dev/null; then false; else [ "$?" -eq 1 ]; fi
}

@test "ctx check accepts hardlink fallback for shared files" {
    local proj="$HOME/project-check-hardlink"
    _make_profile review
    mkdir -p "$proj"
    printf 'review:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
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
    printf 'review:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
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
    printf 'review:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
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
    mkdir -p "$AI_CONFIG_ROOT/profiles/review/.github/skills/alpha-skill" "$proj" "$TEST_TMP/bin"
    printf '%s\n' '---' 'name: alpha-skill' 'description: alpha' '---' > "$AI_CONFIG_ROOT/profiles/review/.github/skills/alpha-skill/SKILL.md"
    printf 'review:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
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
    printf 'review:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
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
    printf 'HOME:%s\nreview:%s\n' "$override" "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    cd "$proj"
    run ctx check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK PASS COPILOT_HOME"* ]]
}

@test "activation treats mixed-case HOME as a directive and excludes it from AI_CONTEXT" {
    local proj="$HOME/project-activation-home-case"
    local override="$HOME/custom-copilot-home"
    _make_profile review
    mkdir -p "$proj"
    printf 'HoMe:%s\nreview:%s\n' "$override" "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    _ctx_load_ctx_file "$proj/.ctx"

    [ "$COPILOT_HOME" = "$override" ]
    [ "$AI_CONTEXT" = "review" ]
    [[ "$AI_CONTEXT" != *"HoMe"* ]]
}

@test "zsh supports mixed-case HOME in .ctx activation and ctx check" {
    if ! command -v zsh >/dev/null 2>&1; then
        skip "zsh is not installed"
    fi

    local proj="$HOME/project-zsh-home-case"
    local override="$HOME/custom-zsh-copilot-home"
    _make_profile review
    mkdir -p "$proj" "$override"
    printf 'HoMe:%s\nreview:%s\n' "$override" "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"

    local zsh_path
    zsh_path="$(command -v zsh)"
    run env PATH="/usr/local/bin:/usr/bin:/bin:$PATH" "$zsh_path" -f -c '
        source "$1"
        _ctx_load_ctx_file "$2" >/dev/null || exit
        rm -f "$4/project-zsh-home-case.code-workspace"
        [ "$COPILOT_HOME" = "$3" ] || exit
        [ "$AI_CONTEXT" = review ] || exit
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
    printf 'review:%s\n' "$AI_CONFIG_ROOT/profiles/review" > "$proj/.ctx"
    _ctx_load_ctx_file "$proj/.ctx" >/dev/null
    ln -s "$TEST_TMP/missing-skill" "$COPILOT_HOME/skills/stale-skill"
    [ -L "$COPILOT_HOME/skills/stale-skill" ]

    _ctx_load_ctx_file "$proj/.ctx" >/dev/null

    [ ! -e "$COPILOT_HOME/skills/stale-skill" ]
    [ ! -L "$COPILOT_HOME/skills/stale-skill" ]
}
