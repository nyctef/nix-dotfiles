#!/usr/bin/env bash
# Workaround for https://github.com/anthropics/claude-code/issues/17087
# bwrap sandbox creates empty read-only files in CWD by bind-mounting
# /dev/null over dotfiles and git internals. This hook cleans them up
# after each Bash tool invocation.

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [ -z "$CWD" ]; then
  exit 0
fi

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
  HEAD
  config
  hooks
  objects
  refs
)

for f in "${SANDBOX_ARTIFACTS[@]}"; do
  target="$CWD/$f"
  # Only remove if it's an empty regular file (0 bytes) — don't touch real files
  if [ -f "$target" ] && [ ! -s "$target" ]; then
    rm -f "$target" 2>/dev/null
  # Or an empty directory created by the bug
  elif [ -d "$target" ] && [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
    rmdir "$target" 2>/dev/null
  fi
done
