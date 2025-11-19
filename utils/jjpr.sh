#!/usr/bin/env bash

set -euo pipefail

branch=$(gh pr list | fzf | cut -f 3)
if [[ -z $branch ]]; then
    return
fi

# Check if local branch exists
local_exists=$(jj bookmark list --no-pager "$branch" 2>/dev/null | grep -c "^$branch:")

if [[ $local_exists -eq 0 ]]; then
    # Branch not tracked locally, check out from origin
    echo "Branch '$branch' not tracked locally. Creating from origin..."
    jj new "$branch@origin"
else
    # Local branch exists, check if it diverges from remote
    local_commit=$(jj log -r "$branch" --no-graph --no-pager -T 'commit_id' 2>/dev/null | head -n1)
    remote_commit=$(jj log -r "$branch@origin" --no-graph --no-pager -T 'commit_id' 2>/dev/null | head -n1)

    if [[ "$local_commit" == "$remote_commit" ]]; then
        # Local and remote point to same commit
        echo "Checking out '$branch' (in sync with origin)"
        jj new "$branch"
    else
        # Diverged - show the difference
        echo "WARNING: '$branch' has diverged from origin!"
        echo ""
        echo "Local commits not in origin:"
        jj log -r "$branch...$branch@origin" --no-pager 2>/dev/null || echo "  (none)"
        echo ""
        echo "Remote commits not in local:"
        jj log -r "$branch@origin...$branch" --no-pager 2>/dev/null || echo "  (none)"
        echo ""
        read -r -p "Check out [l]ocal, [r]emote, or [c]ancel? " choice
        case "$choice" in
            l|L) jj new "$branch" ;;
            r|R) jj new "$branch@origin" ;;
            *) echo "Cancelled."; return 1 ;;
        esac
    fi
fi