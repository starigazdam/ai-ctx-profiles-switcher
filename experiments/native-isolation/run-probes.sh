#!/usr/bin/env bash
# Offline probe set for issue #83: native skill isolation in Copilot CLI and Claude Code.
#
# The probes write only into one mktemp directory (fake HOME, fixture
# COPILOT_HOME, profiles, ctx config). They do not log in and do not call a model.
# To prove "no network" and temp-only writes, run it through ro-run.sh:
#   d=$(mktemp -d) && TMPDIR=$d experiments/native-isolation/ro-run.sh experiments/native-isolation/run-probes.sh
# Exit 0 = every expectation that ran held; 1 = at least one mismatch.
# The RESULT line names skipped probe groups (P3 without claude, P4 without the engine).
#
#   COPILOT_CMD     command that starts Copilot CLI (default: copilot). Use an
#                   absolute path; the variable is word-split, not tilde-expanded:
#                   COPILOT_CMD="node $HOME/.cache/copilot/pkg/linux-x64/1.0.111/index.js"
#   CLAUDE_CMD      Claude Code command (default: claude). Not found = P3 SKIP.
#   CTX_ENGINE_DLL  .NET 10 engine for `ctx clear` (default: the CI build output
#                   src/Ctx/bin/Release/net10.0/Ctx.dll). Not found = P4 SKIP.
#                   Build it with `dotnet build src/Ctx/Ctx.csproj --configuration Release`.
#   KEEP=1          keep the temp directory for inspection
#
# Counts include only fixture skills (paths in the temp dir) and built-in
# skills. Host skills above the temp dir are out of scope.
set -euo pipefail

COPILOT_CMD="${COPILOT_CMD:-copilot}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTX_ENGINE_DLL="${CTX_ENGINE_DLL:-$REPO/src/Ctx/bin/Release/net10.0/Ctx.dll}"
skipped=""
if [ -f "$CTX_ENGINE_DLL" ]; then CTX_ENGINE_DLL="$(cd "$(dirname "$CTX_ENGINE_DLL")" && pwd)/$(basename "$CTX_ENGINE_DLL")"; export CTX_ENGINE_DLL
else skipped="$skipped P4"; fi
T="$(mktemp -d)"
if [ "${KEEP:-0}" = 1 ]; then echo "temp: $T"; else trap 'rm -rf "$T"' EXIT; fi

H="$T/home"            # fake HOME; default COPILOT_HOME is $H/.copilot
WS="$T/anc/ws"         # workspace below an ancestor with skill roots
PROF="$T/ai-config/profiles"
fail=0

mkskill() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: canary %s\n---\nbody\n' "$2" "$2" >"$1/$2/SKILL.md"; }
mkskill "$H/.copilot/skills" g-copilot       # personal-copilot root
mkskill "$H/.agents/skills" g-agents         # personal-agents root
mkskill "$T/anc/.agents/skills" anc-canary   # ancestor (inherited) root, issue #49
mkdir -p "$WS"
for p in alpha beta; do mkskill "$PROF/$p/.github/skills" "$p-skill"; : >"$PROF/$p/copilot-instructions.md"; done

cenv() { env -i PATH="$PATH" HOME="$H" TMPDIR="$T" CLAUDE_CODE_TMPDIR="$T" COPILOT_AUTO_UPDATE=false "$@"; }

# list [VAR=VAL...] [-- copilot args before `skill list`]: run `copilot skill list --json` in $WS.
# Prints "builtin=<n> n=<fixture count> fixture=<names> src=<name:source[:off]>".
# A failed command or invalid JSON prints fixture=ERROR, so every check fails.
list() {
    local envs=() pre=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    [ "${1:-}" = -- ] && { shift; pre=("$@"); }
    local out
    # shellcheck disable=SC2086  # COPILOT_CMD is a word-split command by design
    out="$(cd "$WS" && cenv "${envs[@]}" $COPILOT_CMD "${pre[@]}" skill list --json 2>/dev/null)" \
        || { echo "builtin=? n=? fixture=ERROR(exit)"; return; }
    printf '%s' "$out" | python3 -c '
import json, sys
t = sys.argv[1] + "/"
try:
    d = json.load(sys.stdin)
except ValueError:
    print("builtin=? n=? fixture=ERROR(json)"); sys.exit()
b = sum(1 for s in d if s["source"] == "builtin")
f = sorted((s for s in d if s["path"].startswith(t) and s["source"] != "builtin"), key=lambda s: s["name"])
src = ",".join(s["name"] + ":" + s["source"] + ("" if s.get("enabled", True) else ":off") for s in f)
print("builtin=%d n=%d fixture=%s src=%s" % (b, len(f), ",".join(s["name"] for s in f) or "-", src or "-"))' "$T"
}

field() { local v=" $2"; v="${v#* "$1"=}"; printf '%s' "${v%% *}"; }

# check <label> <expected fixture csv> <actual> [<builtin baseline>] [<before output>]
check() {
    local got_f got_b; got_f="$(field fixture "$3")"; got_b="$(field builtin "$3")"
    local ba=""; [ -n "${5:-}" ] && ba="  [before n=$(field n "$5") -> after n=$(field n "$3")]"
    if [ "$got_f" = "$2" ] && { [ -z "${4:-}" ] || [ "$got_b" = "$4" ]; }; then
        printf 'PASS %-38s %s%s\n' "$1" "$3" "$ba"
    else
        printf 'FAIL %-38s %s (want fixture=%s%s)%s\n' "$1" "$3" "$2" "${4:+ builtin=$4}" "$ba"; fail=1
    fi
}
# has <label> <needle> <actual>: an extra assertion on the src field.
has() { case " $3 " in *"$2"*) printf 'PASS %-38s %s\n' "$1" "$2" ;; *) printf 'FAIL %-38s missing %s in: %s\n' "$1" "$2" "$3"; fail=1 ;; esac; }

KEY=ignoredSkillsLocations
# settings_json [--disable <name>] <path>...: a settings.json with the ignore list.
settings_json() { python3 -c '
import json, sys
a = sys.argv[2:]; d = {}
if a[:1] == ["--disable"]: d["disabledSkills"] = [a[1]]; a = a[2:]
d[sys.argv[1]] = a
print(json.dumps(d))' "$KEY" "$@"; }
ignore_json() { settings_json "$@"; }
GLOBALS=("$H/.copilot/skills" "$H/.agents/skills" "$T/anc/.agents/skills")
ALL3="anc-canary,g-agents,g-copilot"

# shellcheck disable=SC2086
echo "client: $(cd "$WS" && cenv $COPILOT_CMD --version | head -1)"

# --- P1: ignoredSkillsLocations is a negative skill-root filter -----------
base="$(list)"; B="$(field builtin "$base")"
check "P1.0 baseline default home" "$ALL3" "$base"
[ "$B" -ge 1 ] 2>/dev/null || { echo "FAIL P1.0 no built-in skill"; fail=1; }

ignore_json "${GLOBALS[@]}" >"$H/.copilot/settings.json"
check "P1.1 user settings ignores 3 roots" "-" "$(list)" "$B" "$base"
rm "$H/.copilot/settings.json"
check "P1.2 settings removed -> restored" "$ALL3" "$(list)" "$B"

# Per-home scope: an ignore list in a context home does not reach the default home.
mkdir -p "$T/ctxhome"; echo '{}' >"$T/ctxhome/settings.json"
ctxbase="$(list COPILOT_HOME="$T/ctxhome")"
check "P1.3 baseline: context home" "anc-canary" "$ctxbase" "$B"
ignore_json "${GLOBALS[@]:1}" >"$T/ctxhome/settings.json"
check "P1.3 context home ignore list" "-" "$(list COPILOT_HOME="$T/ctxhome")" "$B" "$ctxbase"
check "P1.4 default home after (no leak)" "$ALL3" "$(list)" "$B" "$base"

# Repository scope, in a git repository listed in trustedFolders. Positive control: disabledSkills
# in the same file turns g-agents off, so Copilot read the file.
git -C "$WS" init -q
gitbase="$(list)"
check "P1.5a git repo: no ancestor above root" "g-agents,g-copilot" "$gitbase" "$B" "$base"
mkdir -p "$WS/.github/copilot"
echo "{\"trustedFolders\":[\"$WS\"]}" >"$H/.copilot/config.json"
settings_json --disable g-agents "${GLOBALS[@]}" >"$WS/.github/copilot/settings.json"
out="$(list)"
check "P1.5 repo ignore list: no effect" "g-agents,g-copilot" "$out" "$B" "$gitbase"
has "P1.5 control: repo disabledSkills read" "g-agents:personal-agents:off" "$out"
rm -rf "$WS/.github" "$WS/.git" "$H/.copilot/config.json"

# --- P1.6: COPILOT_SKILLS_DIRS is additive -------------------------------
out="$(list COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")"
check "P1.6 COPILOT_SKILLS_DIRS adds alpha" "alpha-skill,$ALL3" "$out" "$B"
has "P1.6 source of alpha-skill" "alpha-skill:custom" "$out"

# --- P1.7-P1.10: custom-home scope and prefix semantics --------------------
mkdir -p "$T/emptyhome"; echo '{}' >"$T/emptyhome/settings.json"
out="$(list COPILOT_HOME="$T/emptyhome")"
check "P1.7 custom home: no personal roots" "anc-canary" "$out" "$B" "$base"
has "P1.7 source of anc-canary" "anc-canary:inherited" "$out"
eb="$(list COPILOT_HOME="$T/emptyhome" COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")"
check "P1.8 baseline: custom home + alpha" "alpha-skill,anc-canary" "$eb" "$B"
ignore_json "$T/anc" >"$T/emptyhome/settings.json"
check "P1.8 parent dir prefix hides anc" "alpha-skill" \
    "$(list COPILOT_HOME="$T/emptyhome" COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")" "$B" "$eb"
ignore_json "$T" >"$T/emptyhome/settings.json"
check "P1.9 prefix also hides SKILLS_DIRS" "-" \
    "$(list COPILOT_HOME="$T/emptyhome" COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")" "$B" "$eb"
ignore_json "$T/anc/*/skills" >"$T/emptyhome/settings.json"
check "P1.10 glob entry: no effect" "alpha-skill,anc-canary" \
    "$(list COPILOT_HOME="$T/emptyhome" COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")" "$B" "$eb"
ignore_json "$T/an" >"$T/emptyhome/settings.json"   # a string prefix of $T/anc, not a parent
check "P1.11 string prefix (not parent): no effect" "alpha-skill,anc-canary" \
    "$(list COPILOT_HOME="$T/emptyhome" COPILOT_SKILLS_DIRS="$PROF/alpha/.github/skills")" "$B" "$eb"

# --- P2.0: `skill list` does not apply --add-dir (session check: see the doc) ---
check "P2.0 skill list --add-dir: not listed" "$ALL3" "$(list -- --add-dir "$PROF/alpha")" "$B" "$base"

# --- P4: A -> B -> A with real ctx.sh Mode C, plus a per-activation ignore list ---
# The ignore-list write below is the PoC step that ctx does NOT do today.
p4() {
    (
        set +eu  # ctx.sh is an interactive-shell library; it is not nounset-safe
        export HOME="$H" TMPDIR="$T" AI_CTX_PROFILES_CONFIG_ROOT="$T/ai-config" DOTNET_EnableDiagnostics=0 \
               AI_CTX_PROFILES_COPILOT_MODE=ephemeral-clean CTX_AUTO_LOAD=0
        unset COPILOT_HOME COPILOT_SKILLS_DIRS AI_CTX_PROFILES
        # shellcheck source=/dev/null
        source "$REPO/ctx.sh"
        cd "$WS" || exit 1
        prev=""
        envargs() { args=(); local v; for v in COPILOT_HOME COPILOT_SKILLS_DIRS; do [ -n "${!v:-}" ] && args+=("$v=${!v}"); done; }
        step() {  # step <label> <profile> <expected before injection> <expected after>
            ctx "$2" >"$T/ctx.out" 2>&1 || { echo "FAIL $1: $(tail -1 "$T/ctx.out")"; fail=1; return; }
            case "$COPILOT_HOME" in "$T"/ctx-ephemeral.*) ;; *) echo "FAIL $1: COPILOT_HOME not a fresh home in \$T: $COPILOT_HOME"; fail=1; return ;; esac
            [ "$COPILOT_HOME" != "$prev" ] || { echo "FAIL $1: COPILOT_HOME reused"; fail=1; return; }
            prev="$COPILOT_HOME"
            # No state from an earlier step: the new home has no settings.json,
            # and the ancestor skill is still visible before the injection.
            if [ -e "$COPILOT_HOME/settings.json" ] || [ -L "$COPILOT_HOME/settings.json" ]; then
                echo "FAIL $1: settings.json already in new home"; fail=1; return
            fi
            envargs; local before; before="$(list "${args[@]}")"
            check "$1 before injection" "$3" "$before" "$B"
            ignore_json "$T/anc/.agents/skills" >"$COPILOT_HOME/settings.json"
            check "$1 after injection" "$4" "$(list "${args[@]}")" "$B" "$before"
        }
        step "P4.1 ctx alpha" alpha alpha-skill,anc-canary alpha-skill
        step "P4.2 ctx beta" beta anc-canary,beta-skill beta-skill
        step "P4.3 ctx alpha again" alpha alpha-skill,anc-canary alpha-skill
        ctx clear >"$T/ctx.out" 2>&1 || { echo "FAIL P4.4 ctx clear: $(tail -1 "$T/ctx.out")"; fail=1; }
        if [ -z "${COPILOT_HOME:-}${COPILOT_SKILLS_DIRS:-}" ]; then echo "PASS P4.4 clear unsets COPILOT_HOME and COPILOT_SKILLS_DIRS"
        else echo "FAIL P4.4 env left after clear"; fail=1; fi
        envargs; check "P4.5 after clear -> normal" "$ALL3" "$(list "${args[@]}")" "$B"
        exit "$fail"
    ) || fail=1
}
if [ -n "$CTX_ENGINE_DLL" ] && [ -f "$CTX_ENGINE_DLL" ]; then
    p4
    if [ ! -e "$H/.copilot/settings.json" ] && [ ! -L "$H/.copilot/settings.json" ]; then echo "PASS P4.6 default settings.json absent after P4"
    else echo "FAIL P4.6 default settings.json present after P4"; fail=1; fi
else
    echo "SKIP P4 CTX_ENGINE_DLL not found: $CTX_ENGINE_DLL"
fi

# --- P3: Claude Code skill visibility, read from the stream-json init event ---
# Not signed in: the init event lists skills, then the result is "Not logged in".
# The check requires that result, so a run that reached a model fails.
if command -v "${CLAUDE_CMD%% *}" >/dev/null 2>&1; then
    mkskill "$H/.claude/skills" g-claude
    mkskill "$T/anc/.claude/skills" anc-claude
    mkskill "$PROF/alpha/.claude/skills" alpha-claude
    mkskill "$T/plug/skills" pl-skill
    mkdir -p "$T/plug/.claude-plugin"; echo '{"name":"prof","version":"0.0.1"}' >"$T/plug/.claude-plugin/plugin.json"
    cl() {
        # shellcheck disable=SC2086
        (cd "$WS" && echo x | cenv DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
            $CLAUDE_CMD -p --output-format stream-json --verbose "$@" 2>/dev/null || true) |
        python3 -c '
import json, sys
init = res = None
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("subtype") == "init":
        init = d
    if d.get("type") == "result":
        res = str(d.get("result", ""))
if init is None or res is None or "Not logged in" not in res:
    print("client=? total=? n=? fixture=ERROR(no-init-or-not-logged-out)"); sys.exit()
f = sorted(s for s in init["skills"] if s in ("g-claude", "anc-claude", "alpha-claude", "prof:pl-skill"))
print("client=%s total=%d n=%d fixture=%s" % (init.get("claude_code_version"), len(init["skills"]), len(f), ",".join(f) or "-"))'
    }
    cb="$(cl)"
    echo "client: Claude Code $(field client "$cb")"
    check "P3.0 baseline (not logged in)" "anc-claude,g-claude" "$cb"
    check "P3.1 --add-dir profile" "alpha-claude,anc-claude,g-claude" "$(cl --add-dir "$PROF/alpha")"
    pb="$(cl --add-dir "$PROF/alpha")"
    check "P3.2 baseline: --add-dir" "alpha-claude,anc-claude,g-claude" "$pb"
    check "P3.2 --setting-sources project" "alpha-claude,anc-claude" \
        "$(cl --setting-sources project --add-dir "$PROF/alpha")" "" "$pb"
    check "P3.3 skillOverrides off (user)" "anc-claude" "$(cl --settings '{"skillOverrides":{"g-claude":"off"}}')" "" "$cb"
    check "P3.4 project + overrides off (anc)" "alpha-claude" \
        "$(cl --setting-sources project --settings '{"skillOverrides":{"anc-claude":"off"}}' --add-dir "$PROF/alpha")" "" "$pb"
    check "P3.5 skillOverrides name-only" "anc-claude,g-claude" "$(cl --settings '{"skillOverrides":{"g-claude":"name-only"}}')" "" "$cb"
    after="$(cl --settings '{"disableBundledSkills":true}')"
    nb="$(field total "$cb")"; na="$(field total "$after")"
    check "P3.6 disableBundledSkills (total $nb->$na)" "anc-claude,g-claude" "$after"
    [ "$na" -lt "$nb" ] 2>/dev/null || { echo "FAIL P3.6 total did not drop"; fail=1; }
    plb="$(cl --plugin-dir "$T/plug")"
    check "P3.7 --plugin-dir adds plugin skill" "anc-claude,g-claude,prof:pl-skill" "$plb"
    check "P3.8 skillOverrides skips plugins" "anc-claude,g-claude,prof:pl-skill" \
        "$(cl --plugin-dir "$T/plug" --settings '{"skillOverrides":{"pl-skill":"off","prof:pl-skill":"off"}}')" "" "$plb"
else
    echo "SKIP P3 claude not found (set CLAUDE_CMD)"; skipped="$skipped P3"
fi

if [ "$fail" = 0 ]; then r=PASS; else r=FAIL; fi
echo "RESULT: $r${skipped:+ (skipped:$skipped)}"
exit "$fail"
