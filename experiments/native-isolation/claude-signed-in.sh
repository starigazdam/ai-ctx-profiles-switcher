#!/usr/bin/env bash
# Signed-in P3 probe for issue #83: Claude Code skill visibility with a real
# subscription login. Unlike run-probes.sh, this script CALLS THE MODEL (one
# short prompt per check, 8 checks) and uses the real account of the caller.
#
# Run it only as a dedicated sandbox account (the issue used the AIBOX `agent`
# user), never as a developer account. It refuses to run unless
# CLAUDE_SIGNED_IN_PROBE=1 is set.
#
# Writes: one mktemp directory, plus one fixture skill `g-global` in
# ~/.claude/skills (the user skill root cannot be redirected without changing
# HOME, which would drop the login). At exit it removes the fixture skill, and
# it removes ~/.claude/skills only when this run created it.
#
# Exit 0 = every check held; 1 = a mismatch; 2 = refused or not signed in.
set -uo pipefail

[ "${CLAUDE_SIGNED_IN_PROBE:-0}" = 1 ] || { echo "BLOCKED set CLAUDE_SIGNED_IN_PROBE=1 (calls the model, uses the real login)"; exit 2; }
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
SK="$HOME/.claude/skills"
GLOBAL="$SK/g-global"
[ -e "$GLOBAL" ] && { echo "BLOCKED $GLOBAL exists; refusing to overwrite it"; exit 2; }

auth="$($CLAUDE_CMD auth status 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s/%s" % (d.get("loggedIn"), d.get("authMethod")))' 2>/dev/null)"
echo "client: Claude Code $($CLAUDE_CMD --version 2>/dev/null | head -1)"
echo "auth: $auth"
[ "${auth%%/*}" = True ] || { echo "BLOCKED not signed in"; exit 2; }

T="$(mktemp -d)"
had_sk=0; [ -d "$SK" ] && had_sk=1
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "$T" "$GLOBAL"; [ "$had_sk" = 1 ] || rmdir "$SK" 2>/dev/null; }
trap cleanup EXIT

mk() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: canary %s\n---\nbody\n' "$2" "$2" >"$1/$2/SKILL.md"; }
mk "$SK" g-global
WS="$T/anc/ws"; PROF="$T/prof/A"
mkdir -p "$WS"
mk "$T/anc/.claude/skills" anc-claude
mk "$PROF/.claude/skills" alpha-claude
mkdir -p "$T/plug/skills" "$T/plug/.claude-plugin"
printf -- '---\nname: pl-skill\ndescription: canary pl\n---\nbody\n' >"$T/plug/skills/SKILL.md"
echo '{"name":"prof","version":"0.0.1"}' >"$T/plug/.claude-plugin/plugin.json"
fail=0

# run [claude args]: one signed-in prompt; prints the fixture skills from the
# stream-json init event and loggedin=1 when the result is a model answer.
run() {
  # shellcheck disable=SC2086  # CLAUDE_CMD is a word-split command by design
  (cd "$WS" && echo x | $CLAUDE_CMD -p --output-format stream-json --verbose "$@" 2>/dev/null) |
  python3 -c '
import json, sys
init = res = None
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    if d.get("subtype") == "init": init = d
    if d.get("type") == "result": res = str(d.get("result", ""))
sk = (init or {}).get("skills", [])
f = sorted(s for s in sk if s in ("g-global", "anc-claude", "alpha-claude", "prof:pl-skill"))
logged = 0 if (res is None or "Not logged in" in res) else 1
print("total=%d fixture=%s loggedin=%d" % (len(sk), ",".join(f) or "-", logged))'
}
field() { local v=" $2"; v="${v#* "$1"=}"; printf '%s' "${v%% *}"; }
check() {  # check <label> <expected fixture csv> <actual>; a run must reach the model
  if [ "$(field fixture "$3")" = "$2" ] && [ "$(field loggedin "$3")" = 1 ]; then
    printf 'PASS %-46s %s\n' "$1" "$3"
  else printf 'FAIL %-46s %s (want fixture=%s loggedin=1)\n' "$1" "$3" "$2"; fail=1; fi
}

check "P3.0s baseline signed-in (user source)" "anc-claude,g-global" "$(run)"
check "P3.1s --add-dir profile skill" "alpha-claude,anc-claude,g-global" "$(run --add-dir "$PROF")"
check "P3.2s --setting-sources project" "alpha-claude,anc-claude" "$(run --setting-sources project --add-dir "$PROF")"
check "P3.3s skillOverrides off (user skill)" "anc-claude" "$(run --settings '{"skillOverrides":{"g-global":"off"}}')"
check "P3.4s project + overrides off (ancestor)" "alpha-claude" \
  "$(run --setting-sources project --settings '{"skillOverrides":{"anc-claude":"off"}}' --add-dir "$PROF")"
check "P3.5s skillOverrides name-only" "anc-claude,g-global" "$(run --settings '{"skillOverrides":{"g-global":"name-only"}}')"
check "P3.7s --plugin-dir adds plugin skill" "anc-claude,g-global,prof:pl-skill" "$(run --plugin-dir "$T/plug")"
check "P3.8s skillOverrides skips plugin skills" "anc-claude,g-global,prof:pl-skill" \
  "$(run --plugin-dir "$T/plug" --settings '{"skillOverrides":{"pl-skill":"off","prof:pl-skill":"off"}}')"

if [ "$fail" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$fail"
