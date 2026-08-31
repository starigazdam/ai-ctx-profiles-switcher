# Claude Code compatibility PoC

This is an **offline, unauthenticated** sandbox for issue #15. It does not invoke a real Claude service and does not touch `~/.claude`, `~/.claude.json`, credentials, sessions, or plugins.

## Run

Requirements: POSIX shell and Python 3.

```bash
set -eu
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

mkdir -p "$sandbox/project/.claude/skills/demo" "$sandbox/config"
printf '%s\n' '# Demo project' > "$sandbox/project/CLAUDE.md"
printf '%s\n' '# Demo skill' > "$sandbox/project/.claude/skills/demo/SKILL.md"
printf '%s\n' '{"permissions":{"deny":["Bash(rm -rf *)"]}}' \
  > "$sandbox/project/.claude/settings.json"

cat > "$sandbox/fake-claude" <<'EOF'
#!/bin/sh
set -eu
printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR-}"
printf 'PWD=%s\n' "$PWD"
printf 'CLAUDE_MD=%s\n' "$PWD/CLAUDE.md"
printf 'SKILL=%s\n' "$PWD/.claude/skills/demo/SKILL.md"
[ -n "${CLAUDE_CONFIG_DIR-}" ]
[ -f "$PWD/CLAUDE.md" ]
[ -f "$PWD/.claude/skills/demo/SKILL.md" ]
[ -f "$PWD/.claude/settings.json" ]
EOF
chmod 700 "$sandbox/fake-claude"

(
  cd "$sandbox/project"
  CLAUDE_CONFIG_DIR="$sandbox/config" "$sandbox/fake-claude"
)

# Assert that no real Claude state was used.
test -d "$sandbox/config"
test ! -e "$HOME/.claude/ctx-issue-15-poc"
```

## Expected assertions

- The fake client sees the temporary `CLAUDE_CONFIG_DIR`.
- Project instructions, skills, and settings are discovered through the project-local `.claude` tree.
- No login, network, credentials, or real user configuration is needed.
- The temporary directory is deleted on exit.

This PoC proves only path/layout feasibility. It does **not** prove that Claude Code atomically writes, or safely follows, symlinked settings, databases, sessions, plugins, or other managed state. That requires an explicit version-pinned experiment using a disposable authenticated configuration and must be implemented separately.
