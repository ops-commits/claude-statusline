#!/usr/bin/env bash
set -e

REPO="ops-commits/claude-statusline"
RAW="https://raw.githubusercontent.com/$REPO/main/statusline-command.sh"
DEST="$HOME/.claude/statusline-command.sh"
SETTINGS="$HOME/.claude/settings.json"

echo "Installing claude-statusline..."

# Reset old version's throttle state (keeps cache — stale data beats no data)
rm -f /tmp/claude/statusline-last-attempt \
      /tmp/claude/statusline-backoff \
      /tmp/claude/statusline-update-checked 2>/dev/null

# Download script (overwrites any existing version)
curl -fsSL "$RAW" -o "$DEST"
chmod +x "$DEST"

# Patch settings.json
if [ -f "$SETTINGS" ]; then
  # Add statusLine config, preserving existing settings
  python3 -c "
import json, pathlib
p = pathlib.Path('$SETTINGS')
s = json.loads(p.read_text())
s['statusLine'] = {'type': 'command', 'command': '$DEST'}
p.write_text(json.dumps(s, indent=2) + '\n')
" 2>/dev/null || {
    # Fallback: use jq if python3 fails
    tmp=$(mktemp)
    jq --arg cmd "$DEST" '.statusLine = {type: "command", command: $cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  }
else
  mkdir -p "$(dirname "$SETTINGS")"
  printf '{\n  "statusLine": {\n    "type": "command",\n    "command": "%s"\n  }\n}\n' "$DEST" > "$SETTINGS"
fi

echo "Done. Restart Claude Code to see the status line."
echo "Auto-updates daily from github.com/$REPO"
