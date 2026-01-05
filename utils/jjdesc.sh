#!/usr/bin/env bash

set -euo pipefail

# Default to current change (@) if no argument provided
change="${1:-@}"

# Check if the change exists
if ! jj log -r "$change" --no-graph --no-pager -T 'change_id' &>/dev/null; then
    echo "Error: Change '$change' not found"
    exit 1
fi

# Get current description
current_desc=$(jj log -r "$change" --no-graph --no-pager -T 'description' 2>/dev/null)

# Check if description is empty or just whitespace
if [[ -n "$(echo "$current_desc" | tr -d '[:space:]')" ]]; then
    echo "Change '$change' already has a description:"
    echo "$current_desc"
    echo ""
    read -r -p "Overwrite? [y/N] " choice
    case "$choice" in
        y|Y) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

# Get the diff for the change
echo "Generating commit message from diff..."
diff=$(jj diff -r "$change")

# Generate commit message using claude CLI
prompt="Generate a concise git commit message (one line, no more than 72 characters) based on this diff. Output ONLY the commit message, nothing else.

Diff:
$diff"

commit_msg=$(claude -p "$prompt")

# Clean up the message (remove any extra whitespace/newlines)
commit_msg=$(echo "$commit_msg" | tr -d '\n' | xargs)

echo ""
echo "Generated commit message:"
echo "  $commit_msg"
echo ""
read -r -p "Accept this message? [Y/n] " choice

case "$choice" in
    n|N)
        echo "Cancelled."
        exit 0
        ;;
    *)
        jj describe -r "$change" -m "$commit_msg"
        echo "Description set successfully!"
        ;;
esac
