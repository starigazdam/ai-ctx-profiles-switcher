#!/usr/bin/env bash
# Signed-in P3 probe for issue #83: Claude Code skill visibility with a real
# subscription login. Unlike run-probes.sh, this script CALLS THE MODEL (one
# short prompt per check, 8 checks) and uses the real account of the caller.
#
# Run it only as a dedicated sandbox account with its own Claude login, never
# as a developer account. It refuses to run unless CLAUDE_SIGNED_IN_PROBE=1.
#
# Writes: one mktemp directory, plus one fixture skill `g-global` in
# ~/.claude/skills (the user skill root cannot move without a HOME change,
# which would drop the login). The script creates the fixture directory
# atomically and deletes it only when this run created it. It deletes
# ~/.claude/skills only when this run created it and it is empty.
#
# A check passes only when the claude process exits 0, the stream has a
# result event with subtype "success", is_error false and a non-empty answer,
# and the init event lists exactly the expected fixture skills. Only the
# fixture names are compared, not the full skill list.
#
# Exit 0 = every check held; 1 = a mismatch; 2 = refused or setup failed.
set -uo pipefail

[ "${CLAUDE_SIGNED_IN_PROBE:-0}" = 1 ] || { echo "BLOCKED set CLAUDE_SIGNED_IN_PROBE=1 (calls the model, uses the real login)"; exit 2; }
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
SK="$HOME/.claude/skills"
GLOBAL="$SK/g-global"

auth() {  # prints loggedIn/authMethod/subscriptionType
    # shellcheck disable=SC2086  # CLAUDE_CMD is a word-split command by design
    $CLAUDE_CMD auth status 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("%s/%s/%s" % (d.get("loggedIn"), d.get("authMethod"), d.get("subscriptionType")))' 2>/dev/null
}
# shellcheck disable=SC2086
echo "client: Claude Code $($CLAUDE_CMD --version 2>/dev/null | head -1)"
before="$(auth)"
echo "auth before: $before"
[ "${before%%/*}" = True ] || { echo "BLOCKED not signed in"; exit 2; }

T="$(mktemp -d)" || { echo "BLOCKED mktemp failed"; exit 2; }
had_sk=0; [ -d "$SK" ] && had_sk=1
echo "skills dir existed before: $had_sk"
owned=0
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    rm -rf "$T"
    [ "$owned" = 1 ] && rm -rf "$GLOBAL"
    [ "$had_sk" = 1 ] || rmdir "$SK" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$SK" || { echo "BLOCKED cannot create $SK"; exit 2; }
# mkdir without -p fails on any existing entry, also a dangling symlink.
mkdir "$GLOBAL" 2>/dev/null || { echo "BLOCKED $GLOBAL exists; refusing to touch it"; exit 2; }
owned=1
mk() { mkdir -p "$1/$2" && printf -- '---\nname: %s\ndescription: canary %s\n---\nbody\n' "$2" "$2" >"$1/$2/SKILL.md"; }
WS="$T/anc/ws"; PROF="$T/prof/A"
{ mk "$SK" g-global && mkdir -p "$WS" "$T/plug/skills" "$T/plug/.claude-plugin" &&
  mk "$T/anc/.claude/skills" anc-claude && mk "$PROF/.claude/skills" alpha-claude &&
  printf -- '---\nname: pl-skill\ndescription: canary pl\n---\nbody\n' >"$T/plug/skills/SKILL.md" &&
  echo '{"name":"prof","version":"0.0.1"}' >"$T/plug/.claude-plugin/plugin.json"; } ||
  { echo "BLOCKED fixture setup failed"; exit 2; }
fail=0

# run [claude args]: one signed-in prompt. Prints rc, the fixture skills from
# the init event, and ok=1 only for a successful non-empty model answer.
run() {
    local out="$T/run.jsonl" rc
    # shellcheck disable=SC2086
    (cd "$WS" && echo 'Reply with the word ok.' | $CLAUDE_CMD -p --output-format stream-json --verbose "$@" >"$out" 2>/dev/null)
    rc=$?
    python3 - "$out" "$rc" <<'EOF'
import json, sys
init = res = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") == "system" and d.get("subtype") == "init":
        init = d
    if d.get("type") == "result":
        res = d
sk = (init or {}).get("skills", [])
f = sorted(s for s in sk if s in ("g-global", "anc-claude", "alpha-claude", "prof:pl-skill"))
ok = int(sys.argv[2] == "0" and init is not None and res is not None
         and res.get("subtype") == "success" and res.get("is_error") is False
         and isinstance(res.get("result"), str) and res["result"].strip() != "")
print("rc=%s total=%d fixture=%s ok=%d" % (sys.argv[2], len(sk), ",".join(f) or "-", ok))
EOF
}
field() { local v=" $2"; v="${v#* "$1"=}"; printf '%s' "${v%% *}"; }
check() {  # check <label> <expected fixture csv> <actual>
    if [ "$(field fixture "$3")" = "$2" ] && [ "$(field ok "$3")" = 1 ]; then
        printf 'PASS %-46s %s\n' "$1" "$3"
    else printf 'FAIL %-46s %s (want fixture=%s ok=1)\n' "$1" "$3" "$2"; fail=1; fi
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

after="$(auth)"
echo "auth after: $after"
[ "$after" = "$before" ] || { echo "FAIL auth state changed"; fail=1; }

if [ "$fail" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$fail"
