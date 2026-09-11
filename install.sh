#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$HOME/.claude/skills"
cp -r "$DOTFILES_DIR/claude/skills/." "$HOME/.claude/skills/"

if [ -f "$DOTFILES_DIR/claude/CLAUDE.md" ]; then
  mkdir -p "$HOME/.claude"
  cp "$DOTFILES_DIR/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
fi

echo "Installed Claude Code personal skills + CLAUDE.md into \$HOME/.claude"
