#!/usr/bin/env bats
# Tests-first suite for the future .NET 10 CLI's read-only `current` command:
#
#   dotnet run --project src/Ctx/Ctx.csproj -- current [--recorded-mode <mode>]
#
# These pin observable behavior to the current shell implementation:
# ctx.sh::_ctx_current / _ctx_print_status and ctx.ps1::Show-CtxCurrent /
# Write-CtxStatus. The recorded integration mode is explicit command input and
# is never inferred from the AI_CTX_PROFILES_COPILOT_MODE selector.
#
# Every invocation runs in a fully isolated process environment so no real
# Copilot state, HOME, or credentials are ever read or written.

setup() {
    export CTX_DOTNET_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export CTX_DOTNET_PROJECT="$CTX_DOTNET_REPO_ROOT/src/Ctx/Ctx.csproj"
    export CTX_DOTNET_TMP="$(mktemp -d)"
    export CTX_DOTNET_HOME="$CTX_DOTNET_TMP/home"
    mkdir -p "$CTX_DOTNET_HOME"
}

teardown() {
    rm -rf "$CTX_DOTNET_TMP"
}

# Runs `current` with no recorded mode. Arguments are extra KEY=VALUE
# environment assignments for the child process; everything else, including
# any ambient AI_CTX_*/COPILOT_* variables, is absent. Sets $status/$output.
run_ctx_dotnet_current() {
    run env -i \
        PATH="$PATH" \
        HOME="$CTX_DOTNET_HOME" \
        DOTNET_CLI_HOME="$CTX_DOTNET_HOME" \
        DOTNET_CLI_TELEMETRY_OPTOUT=1 \
        DOTNET_NOLOGO=1 \
        DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
        ${@+"$@"} \
        dotnet run --project "$CTX_DOTNET_PROJECT" -- current
}

# Same as run_ctx_dotnet_current, but passes an explicit --recorded-mode value.
run_ctx_dotnet_current_with_mode() {
    local mode="$1"
    shift
    run env -i \
        PATH="$PATH" \
        HOME="$CTX_DOTNET_HOME" \
        DOTNET_CLI_HOME="$CTX_DOTNET_HOME" \
        DOTNET_CLI_TELEMETRY_OPTOUT=1 \
        DOTNET_NOLOGO=1 \
        DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
        ${@+"$@"} \
        dotnet run --project "$CTX_DOTNET_PROJECT" -- current --recorded-mode "$mode"
}

@test "current: no active context prints the exact two lines and exits 0" {
    run_ctx_dotnet_current

    [ "$status" -eq 0 ]
    [ "$output" = $'No active AI context.\nRun "ctx <profile> [profile...]" to activate one.' ]
    [[ "$output" != *"[AI Context]"* ]]
}

@test "current: an empty AI_CTX_PROFILES behaves like no active context" {
    run_ctx_dotnet_current AI_CTX_PROFILES=

    [ "$status" -eq 0 ]
    [ "$output" = $'No active AI context.\nRun "ctx <profile> [profile...]" to activate one.' ]
    [[ "$output" != *"[AI Context]"* ]]
}

@test "current: absent recorded mode reports <unknown> even when the selector is set" {
    run_ctx_dotnet_current AI_CTX_PROFILES=review AI_CTX_PROFILES_COPILOT_MODE=global-user

    [ "$status" -eq 0 ]
    [[ "$output" == *"[AI Context]"* ]]
    [[ "$output" == *"Profile : review"* ]]
    [[ "$output" == *"Profiles: <none>"* ]]
    [[ "$output" == *"AI_CTX_PROFILES=review"* ]]
    [[ "$output" == *"Mode: <unknown>"* ]]
    [[ "$output" != *"Mode: A —"* ]]
    [[ "$output" != *"Mode: B — global-user"* ]]
    [[ "$output" != *"Mode: C —"* ]]
}

@test "current: recorded synthetic-home reports mode A, ignores the selector, and omits COPILOT_SKILLS_DIRS" {
    run_ctx_dotnet_current_with_mode synthetic-home \
        AI_CTX_PROFILES=review \
        AI_CTX_PROFILES_COPILOT_MODE=global-user \
        COPILOT_HOME=/fabricated/home \
        COPILOT_SKILLS_DIRS=/fabricated/skills

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: A — synthetic-home"* ]]
    [[ "$output" == *"COPILOT_HOME=/fabricated/home"* ]]
    [[ "$output" != *"COPILOT_SKILLS_DIRS="* ]]
}

@test "current: recorded global-user reports mode B with COPILOT_SKILLS_DIRS and COPILOT_HOME" {
    run_ctx_dotnet_current_with_mode global-user \
        AI_CTX_PROFILES=review \
        COPILOT_HOME=/fabricated/home \
        COPILOT_SKILLS_DIRS=/fabricated/skills

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: B — global-user"* ]]
    [[ "$output" == *"COPILOT_SKILLS_DIRS=/fabricated/skills"* ]]
    [[ "$output" == *"COPILOT_HOME=/fabricated/home"* ]]
}

@test "current: recorded ephemeral-clean reports mode C" {
    run_ctx_dotnet_current_with_mode ephemeral-clean \
        AI_CTX_PROFILES=review \
        COPILOT_HOME=/fabricated/home

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: C — ephemeral-clean"* ]]
    [[ "$output" == *"COPILOT_HOME=/fabricated/home"* ]]
}

@test "current: absent recorded mode labels foreign COPILOT_HOME and COPILOT_SKILLS_DIRS unknown" {
    run_ctx_dotnet_current \
        AI_CTX_PROFILES=review \
        COPILOT_HOME=/foreign/home \
        COPILOT_SKILLS_DIRS=/foreign/skills

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: <unknown>"* ]]
    [[ "$output" == *"COPILOT_SKILLS_DIRS=/foreign/skills (unknown)"* ]]
    [[ "$output" == *"COPILOT_HOME=/foreign/home (unknown)"* ]]
}

@test "current: absent recorded mode with no COPILOT_HOME reports <unset>" {
    run_ctx_dotnet_current AI_CTX_PROFILES=review

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: <unknown>"* ]]
    [[ "$output" == *"COPILOT_HOME=<unset>"* ]]
}

@test "current: shows the first profile and the remaining profiles in order" {
    run_ctx_dotnet_current_with_mode global-user AI_CTX_PROFILES=review+azure+security

    [ "$status" -eq 0 ]
    [[ "$output" == *"Profile : review"* ]]
    [[ "$output" == *"Profiles: azure, security"* ]]
    [[ "$output" == *"AI_CTX_PROFILES=review+azure+security"* ]]
}

@test "current: distinguishes unset from present-empty COPILOT_CUSTOM_INSTRUCTIONS_DIRS" {
    run_ctx_dotnet_current_with_mode global-user AI_CTX_PROFILES=review
    [ "$status" -eq 0 ]
    [[ "$output" == *"COPILOT_CUSTOM_INSTRUCTIONS_DIRS="*"<unset>"* ]]
    [[ "$output" != *"<present-empty>"* ]]

    run_ctx_dotnet_current_with_mode global-user \
        AI_CTX_PROFILES=review \
        COPILOT_HOME=/fabricated/home \
        COPILOT_SKILLS_DIRS=/fabricated/skills \
        COPILOT_CUSTOM_INSTRUCTIONS_DIRS=
    [ "$status" -eq 0 ]
    [[ "$output" == *"COPILOT_CUSTOM_INSTRUCTIONS_DIRS="*"<present-empty>"* ]]
    [[ "$output" != *"<unset>"* ]]
}

@test "current: recorded global-user falls back to <unset> for absent COPILOT_HOME and COPILOT_SKILLS_DIRS" {
    run_ctx_dotnet_current_with_mode global-user AI_CTX_PROFILES=review

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: B — global-user"* ]]
    [[ "$output" == *"COPILOT_SKILLS_DIRS=<unset>"* ]]
    [[ "$output" == *"COPILOT_HOME=<unset>"* ]]
}

@test "current: splits non-empty COPILOT_CUSTOM_INSTRUCTIONS_DIRS on commas in order" {
    run_ctx_dotnet_current_with_mode global-user \
        AI_CTX_PROFILES=review \
        COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/alpha,/beta,/gamma

    [ "$status" -eq 0 ]
    [[ "$output" == *$'COPILOT_CUSTOM_INSTRUCTIONS_DIRS=\n/alpha\n/beta\n/gamma'* ]]
}

@test "current: does not print canonical projection listings" {
    run_ctx_dotnet_current_with_mode synthetic-home AI_CTX_PROFILES=review

    [ "$status" -eq 0 ]
    [[ "$output" != *"instructions.md"* ]]
}

# ---------------------------------------------------------------------------
# Issue #67 packet 2: shell<->engine protocol codec (probe + adapters), RED.
#
# The internal probe command
#     dotnet "$CTX_ENGINE_DLL" protocol probe --protocol-dir <dir>
# is a zero-side-effect round-trip proof of the line-oriented request/response
# codec. The shell adapter helpers are deliberately unreachable from every
# public command in this packet, so the tests call them directly. Case 9-11 pin
# the bash adapter (_ctx_apply_protocol_response) and case 12-13 pin the
# PowerShell adapter (Apply-CtxProtocolResponse). Cases 4-8 must additionally
# prove the *new* command is the thing rejecting the request - a missing
# command must not make the rejection assertion pass accidentally.
# ---------------------------------------------------------------------------

# Runs the internal probe command. Prefers the prebuilt engine named by
# CTX_ENGINE_DLL (the same variable `ctx current` delegates to); falls back to
# `dotnet run` for a local, unbuilt checkout. Sets $status/$output.
run_ctx_protocol_probe() {
    local protocol_dir="$1"
    if [ -n "${CTX_ENGINE_DLL:-}" ] && [ -f "${CTX_ENGINE_DLL:-}" ]; then
        run dotnet "$CTX_ENGINE_DLL" protocol probe --protocol-dir "$protocol_dir"
    else
        run dotnet run --project "$CTX_DOTNET_PROJECT" -- protocol probe --protocol-dir "$protocol_dir"
    fi
}

# Creates a fresh mode-0700 protocol dir under the test temp and echoes it.
new_protocol_dir() {
    local dir="$CTX_DOTNET_TMP/protocol-$1"
    mkdir -p "$dir"
    chmod 0700 "$dir"
    printf '%s' "$dir"
}

# Sources ctx.sh in an isolated non-interactive shell with a known
# pre-existing environment, then calls the bash adapter's apply function for
# the given response file. Prints the resulting environment for inspection and
# exits with the adapter's return code (70 = validation failure, per contract).
run_shell_apply_protocol_response() {
    local response_file="$1"
    local ctx_src="$CTX_DOTNET_REPO_ROOT/ctx.sh"
    run env HOME="$CTX_DOTNET_HOME" bash --noprofile --norc -c '
        source "$1"
        export AI_CTX_PROFILES=keep
        export COPILOT_HOME=/keep-home
        export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/keep-dirs
        export EVIL_VAR=keep-evil
        _ctx_apply_protocol_response "$2"
        rc=$?
        printf "RC=%s\n" "$rc"
        printf "AI_CTX_PROFILES=%s\n" "${AI_CTX_PROFILES-<unset>}"
        printf "COPILOT_HOME=%s\n" "${COPILOT_HOME-<unset>}"
        printf "COPILOT_CUSTOM_INSTRUCTIONS_DIRS=%s\n" "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS-<unset>}"
        printf "EVIL_VAR=%s\n" "${EVIL_VAR-<unset>}"
        exit "$rc"
    ' -- "$ctx_src" "$response_file"
}

@test "protocol probe: round-trips all 10 allowlisted fields with exact escaping" {
    local dir request expected
    dir="$(new_protocol_dir case1)"
    request="$dir/request"
    expected="$dir/expected-response"

    # Values deliberately include embedded spaces, Unicode, commas and both
    # shapes of backslash escape: literal backslash-n/r ("\\n"/"\\r" in bytes)
    # and a real LF/CR encoded as "\n"/"\r".
    {
        printf '%s\n' 'CTX-REQ 1'
        printf '%s\n' 'active.mode global-user'
        printf '%s\n' 'active.context café 日本, one'
        printf '%s\n' 'active.custom_dirs /alpha,/beta'
        printf '%s\n' 'active.home_was_set 1'
        printf '%s\n' 'active.home_value /tmp/a b/c'
        printf '%s\n' 'skills.owned /s1,/s2'
        printf '%s\n' 'skills.was_set true'
        printf '%s\n' 'skills.value a\\nb\\rc'
        printf '%s\n' 'autoload.dir dir with space'
        printf '%s\n' 'autoload.home_override lf\ncr\r'
        printf '%s\n' 'END'
    } > "$request"
    chmod 0600 "$request"

    {
        printf '%s\n' 'CTX-RES 1'
        printf '%s\n' 'REC probe.active.mode global-user'
        printf '%s\n' 'REC probe.active.context café 日本, one'
        printf '%s\n' 'REC probe.active.custom_dirs /alpha,/beta'
        printf '%s\n' 'REC probe.active.home_was_set 1'
        printf '%s\n' 'REC probe.active.home_value /tmp/a b/c'
        printf '%s\n' 'REC probe.skills.owned /s1,/s2'
        printf '%s\n' 'REC probe.skills.was_set true'
        printf '%s\n' 'REC probe.skills.value a\\nb\\rc'
        printf '%s\n' 'REC probe.autoload.dir dir with space'
        printf '%s\n' 'REC probe.autoload.home_override lf\ncr\r'
        printf '%s\n' 'EXIT 0'
        printf '%s\n' 'END'
    } > "$expected"

    run_ctx_protocol_probe "$dir"

    [ "$status" -eq 0 ]
    [ -f "$dir/response" ]
    run diff -u "$expected" "$dir/response"
    [ "$status" -eq 0 ]
}

@test "protocol probe: an absent field has no echo line" {
    local dir request
    dir="$(new_protocol_dir case2)"
    request="$dir/request"

    # active.home_was_set is deliberately absent from the request.
    {
        printf '%s\n' 'CTX-REQ 1'
        printf '%s\n' 'active.mode global-user'
        printf '%s\n' 'active.context review'
        printf '%s\n' 'active.custom_dirs /alpha'
        printf '%s\n' 'active.home_value /tmp/a'
        printf '%s\n' 'skills.owned /s1'
        printf '%s\n' 'skills.was_set true'
        printf '%s\n' 'skills.value v'
        printf '%s\n' 'autoload.dir d'
        printf '%s\n' 'autoload.home_override h'
        printf '%s\n' 'END'
    } > "$request"

    run_ctx_protocol_probe "$dir"

    [ "$status" -eq 0 ]
    [ -f "$dir/response" ]
    grep -q '^REC probe\.active\.mode global-user' "$dir/response"
    ! grep -q '^REC probe\.active\.home_was_set' "$dir/response"
}

@test "protocol probe: present-empty field is distinguishable from absent" {
    local dir request
    dir="$(new_protocol_dir case3)"
    request="$dir/request"

    # active.custom_dirs is present with an empty value (note the trailing
    # space); active.home_was_set is absent entirely.
    {
        printf '%s\n' 'CTX-REQ 1'
        printf '%s\n' 'active.custom_dirs '
        printf '%s\n' 'END'
    } > "$request"

    run_ctx_protocol_probe "$dir"

    [ "$status" -eq 0 ]
    [ -f "$dir/response" ]
    grep -qxF 'REC probe.active.custom_dirs ' "$dir/response"
    ! grep -q '^REC probe\.active\.home_was_set' "$dir/response"
}

@test "protocol probe: missing END is rejected and no response is written" {
    local dir request
    dir="$(new_protocol_dir case4)"
    request="$dir/request"
    printf '%s\n' 'CTX-REQ 1' 'active.mode A' > "$request"

    run_ctx_protocol_probe "$dir"

    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown command"* ]]
    [[ "$output" != *"usage: ctx current"* ]]
    [ ! -e "$dir/response" ]
}

@test "protocol probe: trailing garbage after END is rejected" {
    local dir request
    dir="$(new_protocol_dir case5)"
    request="$dir/request"
    printf '%s\n' 'CTX-REQ 1' 'active.mode A' 'END' 'garbage' > "$request"

    run_ctx_protocol_probe "$dir"

    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown command"* ]]
    [[ "$output" != *"usage: ctx current"* ]]
    [ ! -e "$dir/response" ]
}

@test "protocol probe: unknown request field name is rejected" {
    local dir request
    dir="$(new_protocol_dir case6)"
    request="$dir/request"
    printf '%s\n' 'CTX-REQ 1' 'bogus.field x' 'END' > "$request"

    run_ctx_protocol_probe "$dir"

    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown command"* ]]
    [[ "$output" != *"usage: ctx current"* ]]
    [ ! -e "$dir/response" ]
}

@test "protocol probe: invalid backslash escape is rejected" {
    local dir request
    dir="$(new_protocol_dir case7)"
    request="$dir/request"
    printf '%s\n' 'CTX-REQ 1' 'active.context \x' 'END' > "$request"

    run_ctx_protocol_probe "$dir"

    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown command"* ]]
    [[ "$output" != *"usage: ctx current"* ]]
    [ ! -e "$dir/response" ]
}

@test "protocol probe: a raw NUL byte anywhere is rejected" {
    local dir request
    dir="$(new_protocol_dir case8)"
    request="$dir/request"
    printf 'CTX-REQ 1\nactive.mode A\000bad\nEND\n' > "$request"

    run_ctx_protocol_probe "$dir"

    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown command"* ]]
    [[ "$output" != *"usage: ctx current"* ]]
    [ ! -e "$dir/response" ]
}

@test "protocol adapter: truncated response applies nothing" {
    local response="$CTX_DOTNET_TMP/truncated-response"
    # Missing END (and EXIT): a crash mid-write must apply nothing.
    printf '%s\n' 'CTX-RES 1' 'SET AI_CTX_PROFILES hijacked' > "$response"

    run_shell_apply_protocol_response "$response"

    [ "$status" -eq 70 ]
    [[ "$output" == *"AI_CTX_PROFILES=keep"* ]]
    [[ "$output" == *"COPILOT_HOME=/keep-home"* ]]
    [[ "$output" == *"COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/keep-dirs"* ]]
    [[ "$output" != *"hijacked"* ]]
}

@test "protocol adapter: unknown ENVNAME is rejected before any export" {
    local response="$CTX_DOTNET_TMP/unknown-envname-response"
    printf '%s\n' 'CTX-RES 1' 'SET EVIL_VAR hijacked' 'EXIT 0' 'END' > "$response"

    run_shell_apply_protocol_response "$response"

    [ "$status" -eq 70 ]
    [[ "$output" == *"EVIL_VAR=keep-evil"* ]]
    [[ "$output" == *"AI_CTX_PROFILES=keep"* ]]
    [[ "$output" != *"hijacked"* ]]
}

@test "protocol adapter: SETEMPTY on a non-allowlisted name is rejected" {
    local response="$CTX_DOTNET_TMP/bad-setempty-response"
    printf '%s\n' 'CTX-RES 1' 'SETEMPTY AI_CTX_PROFILES' 'EXIT 0' 'END' > "$response"

    run_shell_apply_protocol_response "$response"

    [ "$status" -eq 70 ]
    [[ "$output" == *"AI_CTX_PROFILES=keep"* ]]
}

# ---------------------------------------------------------------------------
# Issue #67 packet 3: `protocol clear` decision table + adapter finish.
#
# The engine's `protocol clear` subcommand is the non---all ctx clear mutation
# boundary. Each case writes a request and asserts the response file
# byte-for-byte, so the decision table is pinned independently of the shell.
# ---------------------------------------------------------------------------

# Runs the internal clear command (prebuilt engine preferred; dotnet run fallback).
run_ctx_protocol_clear() {
    local protocol_dir="$1"
    if [ -n "${CTX_ENGINE_DLL:-}" ] && [ -f "${CTX_ENGINE_DLL:-}" ]; then
        run dotnet "$CTX_ENGINE_DLL" protocol clear --protocol-dir "$protocol_dir"
    else
        run dotnet run --project "$CTX_DOTNET_PROJECT" -- protocol clear --protocol-dir "$protocol_dir"
    fi
}

# write_clear_request <dir> <full-line>...
write_clear_request() {
    local dir="$1"
    shift
    {
        printf '%s\n' 'CTX-REQ 1'
        local line
        for line in "$@"; do
            printf '%s\n' "$line"
        done
        printf '%s\n' 'END'
    } > "$dir/request"
    chmod 0600 "$dir/request"
}

# write_expected_response <dir> <full-line>...
write_expected_response() {
    local dir="$1"
    shift
    {
        printf '%s\n' 'CTX-RES 1'
        local line
        for line in "$@"; do
            printf '%s\n' "$line"
        done
        printf '%s\n' 'EXIT 0'
        printf '%s\n' 'END'
    } > "$dir/expected"
}

assert_clear_response() {
    local dir="$1"
    run diff -u "$dir/expected" "$dir/response"
    [ "$status" -eq 0 ]
}

@test "protocol clear: synthetic-home unsets COPILOT_HOME unconditionally" {
    local dir
    dir="$(new_protocol_dir clear-synthetic)"
    write_clear_request "$dir" \
        'active.mode synthetic-home' \
        'live.home_was_set 1' \
        'live.home_value /tmp/x'
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS' \
        'UNSET COPILOT_HOME'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: ephemeral-clean matching home unsets and retains the recorded path" {
    local dir
    dir="$(new_protocol_dir clear-eph-match)"
    write_clear_request "$dir" \
        'active.mode ephemeral-clean' \
        'active.home_value /tmp/eph' \
        'live.home_was_set 1' \
        'live.home_value /tmp/eph'
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS' \
        'UNSET COPILOT_HOME' \
        'REC outcome.retained_ephemeral_home /tmp/eph'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: ephemeral-clean changed home is preserved, retained and warned" {
    local dir
    dir="$(new_protocol_dir clear-eph-changed)"
    write_clear_request "$dir" \
        'active.mode ephemeral-clean' \
        'active.home_value /tmp/eph' \
        'live.home_was_set 1' \
        'live.home_value /tmp/user-home'
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS' \
        'REC outcome.retained_ephemeral_home /tmp/eph' \
        'REC outcome.warn_home_changed /tmp/user-home'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: ephemeral-clean with no recorded home emits no home records" {
    local dir
    dir="$(new_protocol_dir clear-eph-nohome)"
    write_clear_request "$dir" \
        'active.mode ephemeral-clean' \
        'active.home_value ' \
        'live.home_was_set 0' \
        'live.home_value '
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: global-user never touches COPILOT_HOME" {
    local dir
    dir="$(new_protocol_dir clear-global)"
    write_clear_request "$dir" \
        'active.mode global-user' \
        'live.home_was_set 1' \
        'live.home_value /tmp/user-home'
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: no matching record warns an unowned present COPILOT_HOME" {
    local dir
    dir="$(new_protocol_dir clear-unowned)"
    write_clear_request "$dir" \
        'live.home_was_set 1' \
        'live.home_value /tmp/foreign'
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS' \
        'REC outcome.warn_unowned_home /tmp/foreign'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: no matching record with no COPILOT_HOME emits no warnings" {
    local dir
    dir="$(new_protocol_dir clear-unowned-absent)"
    write_clear_request "$dir" \
        'live.home_was_set 0' \
        'live.home_value '
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: owned matching skills are unset" {
    local dir
    dir="$(new_protocol_dir clear-skills-match)"
    write_clear_request "$dir" \
        'active.mode global-user' \
        'skills.owned 1' \
        'skills.was_set 1' \
        'skills.value /skills' \
        'live.skills_was_set 1' \
        'live.skills_value /skills'
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS' \
        'UNSET COPILOT_SKILLS_DIRS'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: owned mismatched skills are preserved" {
    local dir
    dir="$(new_protocol_dir clear-skills-mismatch)"
    write_clear_request "$dir" \
        'active.mode global-user' \
        'skills.owned 1' \
        'skills.was_set 1' \
        'skills.value /skills' \
        'live.skills_was_set 1' \
        'live.skills_value /user-skills'
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: unowned skills are preserved" {
    local dir
    dir="$(new_protocol_dir clear-skills-unowned)"
    write_clear_request "$dir" \
        'active.mode global-user' \
        'skills.owned 0' \
        'skills.was_set 0' \
        'skills.value ' \
        'live.skills_was_set 1' \
        'live.skills_value /foreign-skills'
    write_expected_response "$dir" \
        'UNSET AI_CTX_PROFILES' \
        'UNSET COPILOT_CUSTOM_INSTRUCTIONS_DIRS'

    run_ctx_protocol_clear "$dir"

    [ "$status" -eq 0 ]
    assert_clear_response "$dir"
}

@test "protocol clear: an unknown request field is rejected and no response is written" {
    local dir
    dir="$(new_protocol_dir clear-bogus)"
    write_clear_request "$dir" 'bogus.field x'

    run_ctx_protocol_clear "$dir"

    [ "$status" -ne 0 ]
    [ ! -e "$dir/response" ]
}

# Prints the adapter's return code plus the surfaced outcome.* variables.
run_shell_adapter_outcomes() {
    local response_file="$1"
    local ctx_src="$CTX_DOTNET_REPO_ROOT/ctx.sh"
    run env HOME="$CTX_DOTNET_HOME" bash --noprofile --norc -c '
        source "$1"
        _ctx_apply_protocol_response "$2"
        rc=$?
        printf "RC=%s\n" "$rc"
        printf "UNOWNED_SEEN=%s\n" "${_ctx_protocol_outcome_warn_unowned_home_seen:-<unset>}"
        printf "UNOWNED=[%s]\n" "${_ctx_protocol_outcome_warn_unowned_home-<unset>}"
        printf "CHANGED_SEEN=%s\n" "${_ctx_protocol_outcome_warn_home_changed_seen:-<unset>}"
        printf "CHANGED=[%s]\n" "${_ctx_protocol_outcome_warn_home_changed-<unset>}"
        printf "RETAINED_SEEN=%s\n" "${_ctx_protocol_outcome_retained_ephemeral_home_seen:-<unset>}"
        printf "RETAINED=[%s]\n" "${_ctx_protocol_outcome_retained_ephemeral_home-<unset>}"
        printf "AI_CTX_PROFILES=%s\n" "${AI_CTX_PROFILES-<unset>}"
        exit 0
    ' -- "$ctx_src" "$response_file"
}

@test "protocol adapter: surfaces outcome.* values including present-empty" {
    local response="$CTX_DOTNET_TMP/outcome-response"
    {
        printf '%s\n' 'CTX-RES 1'
        printf '%s\n' 'UNSET COPILOT_HOME'
        printf '%s\n' 'REC outcome.warn_unowned_home '
        printf '%s\n' 'REC outcome.warn_home_changed /tmp/other'
        printf '%s\n' 'REC outcome.retained_ephemeral_home /tmp/eph'
        printf '%s\n' 'EXIT 0'
        printf '%s\n' 'END'
    } > "$response"

    run_shell_adapter_outcomes "$response"

    [ "$status" -eq 0 ]
    [[ "$output" == *"UNOWNED_SEEN=1"* ]]
    [[ "$output" == *"UNOWNED=[]"* ]]
    [[ "$output" == *"CHANGED_SEEN=1"* ]]
    [[ "$output" == *"CHANGED=[/tmp/other]"* ]]
    [[ "$output" == *"RETAINED_SEEN=1"* ]]
    [[ "$output" == *"RETAINED=[/tmp/eph]"* ]]
}

@test "protocol adapter: propagates a non-zero EXIT value as its return code" {
    local response="$CTX_DOTNET_TMP/exit-restores-response"
    {
        printf '%s\n' 'CTX-RES 1'
        printf '%s\n' 'SET AI_CTX_PROFILES changed'
        printf '%s\n' 'EXIT 7'
        printf '%s\n' 'END'
    } > "$response"

    run_shell_adapter_outcomes "$response"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=7"* ]]
    [[ "$output" == *"AI_CTX_PROFILES=changed"* ]]
    [[ "$output" == *"UNOWNED_SEEN=0"* ]]
}

@test "protocol adapter: applies a valid response under zsh (zsh-gated)" {
    if ! command -v zsh >/dev/null 2>&1; then
        skip "zsh is not installed"
    fi

    local dir response zsh_path
    dir="$(new_protocol_dir zsh)"
    response="$dir/response"
    {
        printf '%s\n' 'CTX-RES 1'
        printf '%s\n' 'SET AI_CTX_PROFILES review'
        printf '%s\n' 'SET COPILOT_HOME /zhome'
        printf '%s\n' 'EXIT 0'
        printf '%s\n' 'END'
    } > "$response"

    local ctx_src="$CTX_DOTNET_REPO_ROOT/ctx.sh"
    zsh_path="$(command -v zsh)"
    run env HOME="$CTX_DOTNET_HOME" "$zsh_path" -f -c '
        source "$1"
        _ctx_apply_protocol_response "$2"
        rc=$?
        printf "RC=%s\n" "$rc"
        printf "AI_CTX_PROFILES=%s\n" "${AI_CTX_PROFILES-<unset>}"
        printf "COPILOT_HOME=%s\n" "${COPILOT_HOME-<unset>}"
        exit "$rc"
    ' -- "$ctx_src" "$response"

    [ "$status" -eq 0 ]
    [[ "$output" == *"AI_CTX_PROFILES=review"* ]]
    [[ "$output" == *"COPILOT_HOME=/zhome"* ]]
}

@test "ctx clear: missing engine fails closed without mutating the environment" {
    local ctx_src="$CTX_DOTNET_REPO_ROOT/ctx.sh"
    run env HOME="$CTX_DOTNET_HOME" CTX_ENGINE_DLL="$CTX_DOTNET_TMP/missing-engine/ctx.dll" \
        bash --noprofile --norc -c '
        source "$1"
        export AI_CTX_PROFILES=review
        export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/dirs
        export COPILOT_HOME=/tmp/ctx-synthetic
        _ctx_set_active_record synthetic-home
        ctx clear 2>&1
        rc=$?
        printf "RC=%s\n" "$rc"
        printf "AI_CTX_PROFILES=%s\n" "${AI_CTX_PROFILES-<unset>}"
        printf "COPILOT_CUSTOM_INSTRUCTIONS_DIRS=%s\n" "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS-<unset>}"
        printf "COPILOT_HOME=%s\n" "${COPILOT_HOME-<unset>}"
        exit 0
    ' -- "$ctx_src"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]]
    [[ "$output" == *"engine DLL not found"* ]]
    [[ "$output" == *"AI_CTX_PROFILES=review"* ]]
    [[ "$output" == *"COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/dirs"* ]]
    [[ "$output" == *"COPILOT_HOME=/tmp/ctx-synthetic"* ]]
    [[ "$output" != *"AI context cleared."* ]]
}

@test "ctx clear: an unset engine fails closed without mutating the environment" {
    local ctx_src="$CTX_DOTNET_REPO_ROOT/ctx.sh"
    run env HOME="$CTX_DOTNET_HOME" CTX_ENGINE_DLL= \
        bash --noprofile --norc -c '
        source "$1"
        export AI_CTX_PROFILES=review
        export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/dirs
        export COPILOT_HOME=/tmp/ctx-synthetic
        _ctx_set_active_record synthetic-home
        ctx clear 2>&1
        rc=$?
        printf "RC=%s\n" "$rc"
        printf "AI_CTX_PROFILES=%s\n" "${AI_CTX_PROFILES-<unset>}"
        printf "COPILOT_HOME=%s\n" "${COPILOT_HOME-<unset>}"
        exit 0
    ' -- "$ctx_src"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=1"* ]]
    [[ "$output" == *"engine DLL not found: <unset>"* ]]
    [[ "$output" == *"AI_CTX_PROFILES=review"* ]]
    [[ "$output" == *"COPILOT_HOME=/tmp/ctx-synthetic"* ]]
}

@test "ctx clear: real engine round-trip clears a synthetic-home activation" {
    local ctx_src="$CTX_DOTNET_REPO_ROOT/ctx.sh"
    if [ -z "${CTX_ENGINE_DLL:-}" ] || [ ! -f "${CTX_ENGINE_DLL:-}" ]; then
        skip "CTX_ENGINE_DLL is not set to a prebuilt engine"
    fi
    run env HOME="$CTX_DOTNET_HOME" CTX_ENGINE_DLL="${CTX_ENGINE_DLL}" \
        bash --noprofile --norc -c '
        source "$1"
        export AI_CTX_PROFILES=review
        export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/dirs
        export COPILOT_HOME=/tmp/ctx-synthetic
        _ctx_set_active_record synthetic-home
        ctx clear 2>&1
        rc=$?
        printf "RC=%s\n" "$rc"
        printf "AI_CTX_PROFILES=%s\n" "${AI_CTX_PROFILES-<unset>}"
        printf "COPILOT_HOME=%s\n" "${COPILOT_HOME-<unset>}"
        exit 0
    ' -- "$ctx_src"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=0"* ]]
    [[ "$output" == *"AI context cleared."* ]]
    [[ "$output" == *"AI_CTX_PROFILES=<unset>"* ]]
    [[ "$output" == *"COPILOT_HOME=<unset>"* ]]
}
