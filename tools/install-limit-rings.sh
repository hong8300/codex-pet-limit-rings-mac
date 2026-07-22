#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CODEX_PET_LIMIT_RINGS_APP:-$HOME/Applications/CodexPetLimitRings.app}"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/com.codex-pet.limit-rings.plist"
OLD_APP="${CODEX_LIMIT_AURA_APP:-$HOME/Applications/CodexLimitAura.app}"
OLD_BIN="$OLD_APP/Contents/MacOS/CodexLimitAura"
OLD_AGENT="$AGENT_DIR/com.codex-pet.limit-aura.plist"
GUI_TARGET="gui/$(id -u)"
CURRENT_STEP="starting"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

step() {
  CURRENT_STEP="$1"
  log "$CURRENT_STEP"
}

on_error() {
  local status=$?
  log "Failed while: $CURRENT_STEP"
  exit "$status"
}

trap on_error ERR

step "Preparing install directories..."
mkdir -p "$(dirname "$APP")" "$AGENT_DIR" "$HOME/Library/Logs"

step "Stopping existing LaunchAgent and app..."
launchctl bootout "$GUI_TARGET" "$AGENT" >/dev/null 2>&1 || true
launchctl bootout "$GUI_TARGET" "$OLD_AGENT" >/dev/null 2>&1 || true
pkill -TERM -f "$BIN" >/dev/null 2>&1 || true
pkill -TERM -f "$OLD_BIN" >/dev/null 2>&1 || true
pkill -TERM -f "CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings" >/dev/null 2>&1 || true
pkill -TERM -f "CodexLimitAura.app/Contents/MacOS/CodexLimitAura" >/dev/null 2>&1 || true

step "Removing old prototype files..."
rm -f "$OLD_AGENT"
rm -rf "$OLD_APP"

step "Building Codex Pet Limit Rings app..."
BUILT_APP="$("$ROOT/tools/build-limit-rings.sh" "$APP")"
log "Build complete: $BUILT_APP"

step "Writing LaunchAgent..."
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.codex-pet.limit-rings</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/CodexPetLimitRings.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/CodexPetLimitRings.err.log</string>
</dict>
</plist>
PLIST

step "Loading LaunchAgent..."
launchctl bootstrap "$GUI_TARGET" "$AGENT"

step "Starting app..."
launchctl kickstart -k "$GUI_TARGET/com.codex-pet.limit-rings"

log "Install complete: $APP"
log "Launch at login: enabled"
log "Menu bar item: Codex Pet Limit Rings icon"
