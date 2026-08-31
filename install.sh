#!/usr/bin/env bash
# shellcheck shell=bash
#
# install.sh - Install ctx.sh for bash/zsh
# ==========================================
#
# Copies ctx.sh to ~/.config/ctx/ctx.sh and prints the line to add to your
# shell rc file (~/.zshrc or ~/.bashrc) if it isn't already sourced there.
#
# Usage:
#   ./install.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC="$SCRIPT_DIR/ctx.sh"
DEST_DIR="$HOME/.config/ctx"
DEST="$DEST_DIR/ctx.sh"

if [ ! -f "$SRC" ]; then
    printf 'install.sh: error: could not find ctx.sh next to this script (%s)\n' "$SRC" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod 644 "$DEST"

printf 'Installed ctx.sh to %s\n' "$DEST"

SOURCE_LINE=". \"\$HOME/.config/ctx/ctx.sh\""

add_to_rc() {
    local rc_file="$1"
    if [ -f "$rc_file" ] && grep -qF "$DEST" "$rc_file" 2>/dev/null; then
        printf '%s already sources ctx.sh, skipping.\n' "$rc_file"
        return 0
    fi
    printf '\n# Load ctx - portable AI context switcher\n%s\n' "$SOURCE_LINE" >> "$rc_file"
    printf 'Added ctx.sh sourcing to %s\n' "$rc_file"
}

if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
    add_to_rc "$HOME/.zshrc"
fi

if [ -n "${BASH_VERSION:-}" ] || [ -f "$HOME/.bashrc" ]; then
    add_to_rc "$HOME/.bashrc"
fi

cat <<'EOF'

Installation complete.

Restart your shell, or run:
    source ~/.config/ctx/ctx.sh

Then try:
    ctx --help
    ctx review dotnet
    ctx current
    ctx clear

Set AI_CTX_PROFILES_CONFIG_ROOT if your ai-config directory is not at $HOME/work/ai-config:
    export AI_CTX_PROFILES_CONFIG_ROOT="/path/to/ai-config"
EOF
