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
