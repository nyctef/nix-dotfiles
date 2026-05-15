#!/usr/bin/env bash
set -euo pipefail

# List all worktrees in porcelain format, extract just the paths (awk),
# skip the first entry which is the primary worktree (tail), then remove each one.
# Without --force, removal fails if the worktree has uncommitted changes.
git worktree list --porcelain \
  | awk '/^worktree / {print $2}' \
  | tail -n +2 \
  | while read -r path; do
      echo "Removing worktree: $path"
      git worktree remove "$path" || echo "  Skipping $path (failed to remove)"
    done

echo "Done."
