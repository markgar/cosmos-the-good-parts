#!/usr/bin/env bash
set -euo pipefail

# Bootstrap private agents and skills into this book workspace.
# Clones book-agents repo if needed, then symlinks .github/agents and .github/skills.

REPO_URL="https://github.com/markgar/book-agents.git"
AGENTS_DIR="$HOME/dev/book-agents"

# Clone if not already present
if [ ! -d "$AGENTS_DIR" ]; then
    echo "Cloning book-agents to $AGENTS_DIR..."
    git clone "$REPO_URL" "$AGENTS_DIR"
else
    echo "book-agents already at $AGENTS_DIR — pulling latest..."
    git -C "$AGENTS_DIR" pull --ff-only
fi

# Remove existing (copies or stale symlinks)
rm -rf .github/agents .github/skills

# Symlink
ln -sf "$AGENTS_DIR/agents" .github/agents
ln -sf "$AGENTS_DIR/skills" .github/skills

echo "Done. Symlinked:"
echo "  .github/agents -> $AGENTS_DIR/agents"
echo "  .github/skills -> $AGENTS_DIR/skills"
echo ""
echo "Edit agents in either location — they're the same files."
echo "To back up: cd $AGENTS_DIR && git add -A && git commit -m 'update' && git push"
