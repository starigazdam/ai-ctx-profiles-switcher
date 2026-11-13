#!/usr/bin/env bash
# Offline probe set for issue #83: native Copilot CLI skill isolation.
#
# Every write goes into one mktemp directory (fake HOME, fixture COPILOT_HOME,
# profiles, ctx config). No login, no model call, no network need.
# Exit 0 = every expectation held; exit 1 = at least one mismatch.
#
#   COPILOT_CMD   command that starts Copilot CLI (default: copilot)
#                 e.g. COPILOT_CMD="node ~/.cache/copilot/pkg/linux-x64/1.0.111/index.js"
#   KEEP=1        keep the temp directory for inspection
#
# Counts include only fixture skills (paths under the temp dir) and built-in
# skills. A host ancestor .agents/skills above the temp dir is out of scope.
set -euo pipefail

COPILOT_CMD="${COPILOT_CMD:-copilot}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
[ "${KEEP:-0}" = 1 ] && echo "temp: $T" || trap 'rm -rf "$T"' EXIT

H="$T/home"            # fake HOME; default COPILOT_HOME is $H/.copilot
WS="$T/anc/ws"         # workspace below an ancestor with .agents/skills
PROF="$T/ai-config/profiles"
fail=0

mkskill() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: canary %s\n---\nbody\n' "$2" "$2" >"$1/$2/SKILL.md"; }
mkskill "$H/.copilot/skills" g-copilot       # personal-copilot root
mkskill "$H/.agents/skills" g-agents         # personal-agents root
mkskill "$T/anc/.agents/skills" anc-canary   # ancestor (inherited) root, issue #49
mkdir -p "$WS"
for p in alpha beta; do mkskill "$PROF/$p/.github/skills" "$p-skill"; : >"$PROF/$p/copilot-instructions.md"; done

# Run `copilot skill list --json` in $WS with a clean env plus extra VAR=VAL args.
# Prints "builtin=<n> fixture=<sorted,names>".
list() {
    (cd "$WS" && env -i PATH="$PATH" HOME="$H" TMPDIR="$T" CLAUDE_CODE_TMPDIR="$T" COPILOT_AUTO_UPDATE=false "$@" \
        $COPILOT_CMD skill list --json) | python3 -c '
import json, sys
t = sys.argv[1]
d = json.load(sys.stdin)
b = sum(1 for s in d if s["source"] == "builtin")
f = sorted(s["name"] for s in d if s["path"].startswith(t) and s["source"] != "builtin")
print("builtin=%d fixture=%s" % (b, ",".join(f) or "-"))' "$T"
}

# check <label> <expected fixture csv> <actual list output> [<builtin baseline>]
check() {
    local got_f="${3#*fixture=}" got_b="${3%% *}"
    if [ "$got_f" = "$2" ] && { [ -z "${4:-}" ] || [ "$got_b" = "builtin=$4" ]; }; then
        printf 'PASS %-34s %s\n' "$1" "$3"
    else
        printf 'FAIL %-34s %s (want fixture=%s%s)\n' "$1" "$3" "$2" "${4:+ builtin=$4}"; fail=1
    fi
}

ignore_json() { python3 -c 'import json,sys; print(json.dumps({"ignoredSkillsLocations": sys.argv[1:]}))' "$@"; }
GLOBALS=("$H/.copilot/skills" "$H/.agents/skills" "$T/anc/.agents/skills")

echo "client: $(cd "$WS" && env -i PATH="$PATH" HOME="$H" TMPDIR="$T" CLAUDE_CODE_TMPDIR="$T" COPILOT_AUTO_UPDATE=false $COPILOT_CMD --version | head -1)"

# --- P1: ignoredSkillsLocations is a user-scope negative skill-root filter ---
base="$(list)"; B="${base%% *}"; B="${B#builtin=}"
check "P1.0 baseline default home" "anc-canary,g-agents,g-copilot" "$base"
[ "$B" -ge 1 ] || { echo "FAIL P1.0 no built-in skill"; fail=1; }

ignore_json "${GLOBALS[@]}" >"$H/.copilot/settings.json"
check "P1.1 user settings ignores 3 roots" "-" "$(list)" "$B"
rm "$H/.copilot/settings.json"
check "P1.2 settings removed -> restored" "anc-canary,g-agents,g-copilot" "$(list)" "$B"

# Per-home scope: an ignore list in a context home does not reach the default home.
mkdir -p "$T/ctxhome"; ignore_json "${GLOBALS[@]:1}" >"$T/ctxhome/settings.json"
check "P1.3 context home ignore list" "-" "$(list COPILOT_HOME="$T/ctxhome")" "$B"
check "P1.4 default home after (no leak)" "anc-canary,g-agents,g-copilot" "$(list)" "$B"

# Repository scope: the same key in .github/copilot/settings.json.
mkdir -p "$WS/.github/copilot"; ignore_json "${GLOBALS[@]}" >"$WS/.github/copilot/settings.json"
check "P1.5 repo settings ignore (no effect)" "anc-canary,g-agents,g-copilot" "$(list)" "$B"
rm -r "$WS/.github"

# --- P1.6: COPILOT_SKILLS_DIRS is additive -------------------------------
check "P1.6 COPILOT_SKILLS_DIRS adds alpha" "alpha-skill,anc-canary,g-agents,g-copilot" \
    "$(list COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")" "$B"

# --- P1.7-P1.9: custom-home scope and prefix semantics ---------------------
mkdir -p "$T/emptyhome"; echo '{}' >"$T/emptyhome/settings.json"
check "P1.7 custom home: no personal roots" "anc-canary" "$(list COPILOT_HOME="$T/emptyhome")" "$B"
ignore_json "$T/anc" >"$T/emptyhome/settings.json"
check "P1.8 parent dir prefix hides anc" "alpha-skill" \
    "$(list COPILOT_HOME="$T/emptyhome" COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")" "$B"
ignore_json "$T" >"$T/emptyhome/settings.json"
check "P1.9 prefix also hides SKILLS_DIRS" "-" \
    "$(list COPILOT_HOME="$T/emptyhome" COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")" "$B"

# --- P2 (list level only): `skill list` ignores --add-dir ----------------
out="$(cd "$WS" && env -i PATH="$PATH" HOME="$H" TMPDIR="$T" CLAUDE_CODE_TMPDIR="$T" COPILOT_AUTO_UPDATE=false \
    $COPILOT_CMD --add-dir "$PROF/alpha" skill list --json 2>/dev/null || true)"
if printf '%s' "$out" | grep -q '"alpha-skill"'; then
    echo "INFO P2.0 skill list --add-dir lists alpha-skill (changed since 1.0.111)"
else
    echo "INFO P2.0 skill list --add-dir does not list alpha-skill (session check: see docs/native-skill-isolation-poc.md)"
fi

# --- P4: A -> B -> A with real ctx.sh Mode C, plus a per-activation ignore list ---
# The ignore-list write below is the PoC step that ctx does NOT do today.
# `ctx clear` needs the .NET 10 engine: use CTX_ENGINE_DLL, or build it into $T.
if [ -z "${CTX_ENGINE_DLL:-}" ]; then
    env HOME="$T/dn" XDG_CACHE_HOME="$T/dn/cache" TMPDIR="$T" DOTNET_CLI_HOME="$T/dn" NUGET_PACKAGES="$T/dn/nuget" \
        DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_EnableDiagnostics=0 MSBUILDDISABLENODEREUSE=1 \
        DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1 \
        dotnet build "$REPO/src/Ctx" -c Release --disable-build-servers -p:UseSharedCompilation=false \
        --artifacts-path "$T/dn/artifacts" -o "$T/engine" >"$T/engine.log" 2>&1 \
        || { echo "FAIL P4 engine build (see KEEP=1 $T/engine.log)"; exit 1; }
    export CTX_ENGINE_DLL="$T/engine/Ctx.dll"
fi
p4() {
    (
        set +eu  # ctx.sh is an interactive-shell library; it is not nounset-safe
        export HOME="$H" TMPDIR="$T" AI_CTX_PROFILES_CONFIG_ROOT="$T/ai-config" DOTNET_EnableDiagnostics=0 \
               AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean CTX_AUTO_LOAD=0
        unset COPILOT_HOME COPILOT_SKILLS_DIRS AI_CTX_PROFILES
        # shellcheck source=/dev/null
        source "$REPO/ctx.sh"
        cd "$WS"
        step() {  # step <label> <profile|clear> <expected>
            if [ "$2" = clear ]; then ctx clear >"$T/ctx.out" 2>&1 || { echo "FAIL $1: $(tail -1 "$T/ctx.out")"; exit 1; }; else
                ctx "$2" >"$T/ctx.out" 2>&1 || { echo "FAIL $1: $(tail -1 "$T/ctx.out")"; exit 1; }
                ignore_json "$H/.agents/skills" "$T/anc/.agents/skills" >"$COPILOT_HOME/settings.json"
            fi
            local args=() v
            for v in COPILOT_HOME COPILOT_SKILLS_DIRS; do [ -n "${!v:-}" ] && args+=("$v=${!v}"); done
            check "$1" "$3" "$(list "${args[@]}")" "$B"
        }
        step "P4.1 ctx alpha" alpha alpha-skill
        step "P4.2 ctx beta" beta beta-skill
        step "P4.3 ctx alpha again" alpha alpha-skill
        step "P4.4 ctx clear -> normal" clear "anc-canary,g-agents,g-copilot"
        [ -z "${COPILOT_HOME:-}${COPILOT_SKILLS_DIRS:-}" ] || { echo "FAIL P4.5 env left after clear"; exit 1; }
        echo "PASS P4.5 clear unsets COPILOT_HOME and COPILOT_SKILLS_DIRS"
        exit "$fail"
    ) || fail=1
}
p4
[ ! -e "$H/.copilot/settings.json" ] && echo "PASS P4.6 default settings.json never written" \
    || { echo "FAIL P4.6 default settings.json written"; fail=1; }

# --- P3: Claude Code skill visibility, read from the stream-json init event ---
# Not signed in is fine: the init event lists skills before the "Not logged in"
# result, so no model call happens. Auth with --setting-sources is NOT tested here.
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
if command -v "${CLAUDE_CMD%% *}" >/dev/null 2>&1; then
    mkskill "$H/.claude/skills" g-claude
    mkskill "$T/anc/.claude/skills" anc-claude
    mkskill "$PROF/alpha/.claude/skills" alpha-claude
    cl() {
        (cd "$WS" && echo x | env -i PATH="$PATH" HOME="$H" TMPDIR="$T" CLAUDE_CODE_TMPDIR="$T" DISABLE_TELEMETRY=1 \
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 $CLAUDE_CMD -p --output-format stream-json --verbose "$@" 2>/dev/null || true) |
        python3 -c '
import json, sys
for line in sys.stdin:
    d = json.loads(line)
    if d.get("subtype") == "init":
        f = sorted(s for s in d["skills"] if s in ("g-claude", "anc-claude", "alpha-claude"))
        print("client=%s fixture=%s" % (d.get("claude_code_version"), ",".join(f) or "-"))
        break
else:
    print("client=? fixture=NO-INIT")'
    }
    echo "client: Claude Code $(cl | sed 's/ .*//; s/client=//')"
    check "P3.0 baseline" "anc-claude,g-claude" "$(cl)"
    check "P3.1 --add-dir profile" "alpha-claude,anc-claude,g-claude" "$(cl --add-dir "$PROF/alpha")"
    check "P3.2 --setting-sources project" "alpha-claude,anc-claude" \
        "$(cl --setting-sources project --add-dir "$PROF/alpha")"
    check "P3.3 skillOverrides off (user)" "anc-claude" "$(cl --settings '{"skillOverrides":{"g-claude":"off"}}')"
    check "P3.4 project + overrides off (anc)" "alpha-claude" \
        "$(cl --setting-sources project --settings '{"skillOverrides":{"anc-claude":"off"}}' --add-dir "$PROF/alpha")"
    check "P3.5 skillOverrides name-only" "anc-claude,g-claude" "$(cl --settings '{"skillOverrides":{"g-claude":"name-only"}}')"
else
    echo "SKIP P3 claude not found (set CLAUDE_CMD)"
fi

[ "$fail" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$fail"
