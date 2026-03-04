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
    "superpowers-marketplace": {
      "source": {
        "source": "github",
        "repo": "obra/superpowers-marketplace"
      }
    }
  },
  "enabledPlugins": {
    "csharp-lsp@claude-plugins-official": true,
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

# Clean up stale local-plugins references from previous configuration
CURRENT_SETTINGS=$(echo "$CURRENT_SETTINGS" | jq '
  del(.extraKnownMarketplaces["local-plugins"]) |
  del(.enabledPlugins["csharp-lsp@local-plugins"])
')

# Clean up stale local plugin cache, installed_plugins, and known_marketplaces entries
INSTALLED_PLUGINS="${HOME}/.claude/plugins/installed_plugins.json"
if [ -f "$INSTALLED_PLUGINS" ] && jq -e '.plugins["csharp-lsp@local-plugins"]' "$INSTALLED_PLUGINS" > /dev/null 2>&1; then
    UPDATED_INSTALLED=$(jq 'del(.plugins["csharp-lsp@local-plugins"])' "$INSTALLED_PLUGINS")
    echo "$UPDATED_INSTALLED" > "$INSTALLED_PLUGINS"
fi

KNOWN_MARKETPLACES="${HOME}/.claude/plugins/known_marketplaces.json"
if [ -f "$KNOWN_MARKETPLACES" ] && jq -e '.["local-plugins"]' "$KNOWN_MARKETPLACES" > /dev/null 2>&1; then
    UPDATED_MARKETPLACES=$(jq 'del(.["local-plugins"])' "$KNOWN_MARKETPLACES")
    echo "$UPDATED_MARKETPLACES" > "$KNOWN_MARKETPLACES"
fi

rm -rf "${HOME}/.claude/plugins/cache/local-plugins"

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
