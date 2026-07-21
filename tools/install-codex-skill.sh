#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
TARGET="$CODEX_HOME_DIR/skills/codex-pet-limit-rings"

mkdir -p "$CODEX_HOME_DIR/skills"
rm -rf "$TARGET"
cp -R "$ROOT/skills/codex-pet-limit-rings" "$TARGET"

echo "Installed Codex skill at $TARGET"
