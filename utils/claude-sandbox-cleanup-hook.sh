#!/usr/bin/env bash
# Workaround for https://github.com/anthropics/claude-code/issues/17087
# bwrap sandbox creates artifacts in CWD. On native Linux these are empty
# read-only regular files (mode 444). On WSL2 they appear as character
# device nodes (bind mounts of /dev/null) that cannot be removed while
# the sandbox is running.
#
# This hook can be called two ways:
#   1. As a PostToolUse hook (stdin = JSON with cwd field)
#   2. Directly from a shell wrapper: claude-sandbox-cleanup-hook.sh <directory>

set -euo pipefail

# Files known to be created by the sandbox bug
SANDBOX_ARTIFACTS=(
  .bash_profile
  .bashrc
  .gitconfig
  .gitmodules
  .profile
  .ripgreprc
  .zprofile
  .zshrc
  .mcp.json
  .vscode
  .idea
  .claude
  HEAD
  config
  hooks
  objects
  refs
)

# Determine CWD: from argument, or from hook JSON stdin
if [ $# -ge 1 ]; then
  CWD="$1"
else
  INPUT=$(cat)
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
fi

if [ -z "$CWD" ]; then
  exit 0
fi

for f in "${SANDBOX_ARTIFACTS[@]}"; do
  target="$CWD/$f"

  # Case 1: character device (WSL2 bind mount of /dev/null)
  if [ -c "$target" ]; then
    rm -f "$target" 2>/dev/null || true
  # Case 2: empty regular file with read-only permissions (native Linux)
  elif [ -f "$target" ] && [ ! -s "$target" ]; then
    rm -f "$target" 2>/dev/null || true
  # Case 3: empty directory created by the bug
  elif [ -d "$target" ] && [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
    rmdir "$target" 2>/dev/null || true
  fi
done
