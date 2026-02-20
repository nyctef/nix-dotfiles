#!/usr/bin/env bash
# Patch Claude Code settings.json with declarative configuration
# This script is idempotent - safe to run multiple times

set -euo pipefail

SETTINGS_FILE="${HOME}/.claude/settings.json"
SETTINGS_DIR="$(dirname "$SETTINGS_FILE")"

# Ensure .claude directory exists
mkdir -p "$SETTINGS_DIR"

# Initialize settings.json if it doesn't exist or is a symlink
if [ -L "$SETTINGS_FILE" ]; then
    echo "Removing symlinked settings.json to allow mutable management"
    rm "$SETTINGS_FILE"
fi

if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Initializing settings.json"
    echo '{}' > "$SETTINGS_FILE"
fi

# Define our declarative settings
DECLARATIVE_SETTINGS='
{
  "extraKnownMarketplaces": {
    "local-plugins": {
      "source": {
        "source": "directory",
        "path": "'${HOME}'/.claude-plugins"
      }
    },
    "superpowers-marketplace": {
      "source": {
        "source": "github",
        "repo": "obra/superpowers-marketplace"
      }
    }
  },
  "enabledPlugins": {
    "csharp-lsp@local-plugins": true,
    "superpowers@superpowers-marketplace": true
  },
  "hooks": {
    "Notification": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "'${HOME}'/.dotfiles/utils/claude-notification-hook.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "'${HOME}'/.dotfiles/utils/claude-sandbox-cleanup-hook.sh"
          }
        ]
      }
    ]
  }
}
'

# Read current settings
CURRENT_SETTINGS=$(cat "$SETTINGS_FILE")

# Merge declarative settings with current settings
# Our declarative settings take precedence for the keys we manage
MERGED_SETTINGS=$(echo "$CURRENT_SETTINGS" | jq --argjson declarative "$DECLARATIVE_SETTINGS" '
  . as $current |
  $declarative |
  .extraKnownMarketplaces = ($current.extraKnownMarketplaces // {}) * .extraKnownMarketplaces |
  .enabledPlugins = ($current.enabledPlugins // {}) * .enabledPlugins |
  $current * .
')

# Check if update is needed
if [ "$CURRENT_SETTINGS" = "$MERGED_SETTINGS" ]; then
    echo "settings.json is already up to date"
    exit 0
fi

# Write updated settings
echo "Updating settings.json with declarative configuration"
echo "$MERGED_SETTINGS" > "$SETTINGS_FILE"

echo "Successfully patched settings.json"
