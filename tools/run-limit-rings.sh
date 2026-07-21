#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/tmp/CodexPetLimitRings.app"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"

pkill -TERM -f "$BIN" 2>/dev/null || true

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null
open -n "$APP"

echo "Codex Pet Limit Rings launched from $APP"
