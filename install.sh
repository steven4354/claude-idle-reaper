#!/bin/bash
# claude-idle-reaper installer (macOS).
#   install:   curl -fsSL https://raw.githubusercontent.com/steven4354/claude-idle-reaper/main/install.sh | bash
#   uninstall: curl -fsSL https://raw.githubusercontent.com/steven4354/claude-idle-reaper/main/install.sh | bash -s -- --uninstall
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/steven4354/claude-idle-reaper/main"
SCRIPT_DEST="$HOME/.claude/scripts/reap-idle-claude.sh"
PLIST="$HOME/Library/LaunchAgents/com.user.claude-idle-reaper.plist"
LABEL="com.user.claude-idle-reaper"

[ "$(uname)" = "Darwin" ] || { echo "claude-idle-reaper is macOS-only (BSD stat/date + launchd)." >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$SCRIPT_DEST"
  echo "Uninstalled. Log left at ~/.claude/scripts/idle-reaper.log if you want it."
  exit 0
fi

command -v claude >/dev/null 2>&1 || \
  echo "warning: 'claude' not found on PATH — the reaper needs it for summaries (set CLAUDE_BIN in the plist if it lives elsewhere)." >&2

mkdir -p "$HOME/.claude/scripts"
# running from a checkout uses the local copy; `curl | bash` fetches from the repo
if [ -f "$(dirname "$0")/reap-idle-claude.sh" ]; then
  cp "$(dirname "$0")/reap-idle-claude.sh" "$SCRIPT_DEST"
else
  curl -fsSL "$REPO_RAW/reap-idle-claude.sh" -o "$SCRIPT_DEST"
fi
chmod +x "$SCRIPT_DEST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DEST</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$HOME/.claude/scripts/idle-reaper.log</string>
  <key>StandardErrorPath</key><string>$HOME/.claude/scripts/idle-reaper.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed: $SCRIPT_DEST"
echo "Loaded launchd agent '$LABEL' (runs every 5 min; log: ~/.claude/scripts/idle-reaper.log)"
echo
echo "Dry run — what it would reap right now:"
DRY_RUN=1 bash "$SCRIPT_DEST"
echo
echo "Tune by editing $PLIST — add an EnvironmentVariables dict, e.g. IDLE_MINS"
echo "(minutes of tab idle; IDLE_HOURS still works), QUIET_MINS, or StartInterval."
