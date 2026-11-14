#!/usr/bin/env bash
# Task 0 of the OpenSpec change add-claude-harness (issue #22): native evidence
# for the Claude harness recipe. This script CALLS THE MODEL with the real login
# of the caller. Run it only as a dedicated sandbox account with its own Claude
# login. It refuses to run unless CLAUDE_SIGNED_IN_PROBE=1.
#
# All fixtures live in one mktemp directory. The script writes nothing to
# ~/.claude. It builds two snapshots by hand, in the D3 layout:
#   $T/ctx-claude.A  CLAUDE.md with marker A, skill a-snap, ctx-settings.json
#   $T/ctx-claude.B  an earlier task-B snapshot with marker B, skill b-snap
# and a canonical task-B profile next to the task-A workspace:
#   $T/tasks/B/profile  AGENTS.md with marker P, .agents/skills/b-prof
#
# Cases (tasks 0.1 to 0.4):
#   0.1 the init event lists a-snap
#   0.2 the answer contains marker A (with CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1);
#       0.2n records the same run without the variable (no pass/fail)
#   0.3 --settings <file> gives exit 0 and a successful result; 0.3n a missing
#       settings file must not give a successful result
#   0.4 no b-snap, no b-prof, no marker B and no marker P in any task-A run
#
# Exit 0 = PASS; 1 = FAIL; 2 = BLOCKED (refused, setup failed, or other-task leak).
set -uo pipefail

[ "${CLAUDE_SIGNED_IN_PROBE:-0}" = 1 ] || { echo "BLOCKED set CLAUDE_SIGNED_IN_PROBE=1 (calls the model, uses the real login)"; exit 2; }
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
LIMIT="${CLAUDE_CALL_LIMIT:-60}"
VAR=CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD

# shellcheck disable=SC2086  # CLAUDE_CMD is a word-split command by design
echo "client: Claude Code $(timeout 10 $CLAUDE_CMD --version 2>/dev/null | head -1)"
# shellcheck disable=SC2086
help="$(timeout 10 $CLAUDE_CMD --help 2>/dev/null)" || { echo "BLOCKED client-failed (--help)"; exit 2; }
case "$help" in *--add-dir*) ;; *) echo "BLOCKED client-unsupported (--add-dir)"; exit 2 ;; esac
case "$help" in *--settings*) ;; *) echo "BLOCKED client-unsupported (--settings)"; exit 2 ;; esac

T="$(mktemp -d)" || { echo "BLOCKED mktemp failed"; exit 2; }
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

rnd() { od -An -N6 -tx1 /dev/urandom | tr -d ' \n'; }
MA="MARK_A_$(rnd)"; MB="MARK_B_$(rnd)"; MP="MARK_P_$(rnd)"
SA="$T/ctx-claude.A"; SB="$T/ctx-claude.B"; WS="$T/tasks/A/ws"; PB="$T/tasks/B/profile"
skill() { mkdir -p "$1/$2" && printf -- '---\nname: %s\ndescription: canary %s\n---\nbody\n' "$2" "$2" >"$1/$2/SKILL.md"; }
snap() {  # snap <dir> <label> <marker> <skill>
    mkdir -p "$1" && chmod 700 "$1" &&
    printf '<!-- ctx profile 1 %s -->\n# Task %s\n%s\n' "$2" "$2" "$3" >"$1/CLAUDE.md" &&
    skill "$1/.claude/skills" "$4" &&
    printf '{"autoMemoryEnabled": false}\n' >"$1/ctx-settings.json"
}
{ snap "$SA" a "$MA" a-snap && snap "$SB" b "$MB" b-snap && mkdir -p "$WS" "$PB" &&
  printf '# Task B profile\n%s\n' "$MP" >"$PB/AGENTS.md" && skill "$PB/.agents/skills" b-prof &&
  git -C "$WS" init -q; } || { echo "BLOCKED fixture setup failed"; exit 2; }
echo "fixture: $(cd "$T" && find . -path '*/.git' -prune -o -type f -print | sort | tr '\n' ' ')"

PROMPT='List every line of your loaded instructions that starts with MARK_. Reply NONE if there is no such line.'
# run <use-var 0|1> [claude args]: one signed-in call in the task-A workspace.
# Prints rc, ok (successful non-empty answer), the canary skills, and markers.
run() {
    local usevar="$1"; shift
    local out="$T/run.jsonl" rc
    if [ "$usevar" = 1 ]; then
        # shellcheck disable=SC2086
        (cd "$WS" && echo "$PROMPT" | env "$VAR=1" timeout "$LIMIT" $CLAUDE_CMD -p --output-format stream-json --verbose "$@" >"$out" 2>/dev/null)
    else
        # shellcheck disable=SC2086
        (cd "$WS" && echo "$PROMPT" | env -u "$VAR" timeout "$LIMIT" $CLAUDE_CMD -p --output-format stream-json --verbose "$@" >"$out" 2>/dev/null)
    fi
    rc=$?
    python3 - "$out" "$rc" "$MA" "$MB" "$MP" <<'EOF'
import json, sys
path, rc, ma, mb, mp = sys.argv[1:6]
init = res = None
for line in open(path, encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") == "system" and d.get("subtype") == "init":
        init = d
    if d.get("type") == "result":
        res = d
sk = (init or {}).get("skills", [])
canary = sorted(s for s in sk if s in ("a-snap", "b-snap", "b-prof"))
ans = res.get("result") if isinstance(res, dict) and isinstance(res.get("result"), str) else ""
ok = int(rc == "0" and init is not None and res is not None and res.get("subtype") == "success"
         and res.get("is_error") is False and ans.strip() != "")
marks = [n for n, m in (("A", ma), ("B", mb), ("P", mp)) if m in ans]
print("rc=%s ok=%d skills=%s marks=%s" % (rc, ok, ",".join(canary) or "-", ",".join(marks) or "-"))
EOF
}
field() { local v=" $2"; v="${v#* "$1"=}"; printf '%s' "${v%% *}"; }
fail=0; leak=0
has() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }
noleak() {  # noleak <label> <run output>: case 0.4 on every task-A run
    local s m; s="$(field skills "$2")"; m="$(field marks "$2")"
    if has "$s" b-snap || has "$s" b-prof || has "$m" B || has "$m" P; then
        echo "BLOCKED other-task $1: $2"; leak=1
    fi
}
verdict() {  # verdict <label> <condition 0|1> <run output>
    if [ "$2" = 1 ]; then printf 'PASS %-40s %s\n' "$1" "$3"; else printf 'FAIL %-40s %s\n' "$1" "$3"; fail=1; fi
}

main="$(run 1 --add-dir "$SA" --settings "$SA/ctx-settings.json")"
noleak "0.1-0.3 recipe" "$main"
verdict "0.1 init lists a-snap" "$([ "$(field ok "$main")" = 1 ] && has "$(field skills "$main")" a-snap && echo 1 || echo 0)" "$main"
verdict "0.2 answer has marker A" "$([ "$(field ok "$main")" = 1 ] && has "$(field marks "$main")" A && echo 1 || echo 0)" "$main"
verdict "0.3 --settings file accepted" "$(field ok "$main")" "$main"

novar="$(run 0 --add-dir "$SA" --settings "$SA/ctx-settings.json")"
noleak "0.2n without variable" "$novar"
echo "INFO 0.2n without $VAR: $novar"

bad="$(run 1 --add-dir "$SA" --settings "$T/missing-settings.json")"
noleak "0.3n missing settings file" "$bad"
verdict "0.3n missing settings file rejected" "$([ "$(field ok "$bad")" = 0 ] && echo 1 || echo 0)" "$bad"

if [ "$leak" = 1 ]; then echo "RESULT: BLOCKED other-task"; exit 2; fi
if [ "$fail" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit "$fail"
