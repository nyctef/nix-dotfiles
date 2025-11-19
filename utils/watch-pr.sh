#!/usr/bin/env bash

# Watch a PR and notify when it goes green
# Usage: watch-pr.sh [owner] [repo]

OWNER="${1:-}"
REPO="${2:-}"

# Build repo flag for gh commands
if [ -n "$OWNER" ] && [ -n "$REPO" ]; then
  REPO_FLAG=(--repo "${OWNER}/${REPO}")
else
  REPO_FLAG=()
fi

# Let user select a PR with fzf
PR_NUMBER=$(gh pr list "${REPO_FLAG[@]}" --json number,title,author,headRefName --jq '.[] | "#\(.number) \(.title) (@\(.author.login)) [\(.headRefName)]"' | \
  fzf --prompt="Select PR to watch: " --height=40% --reverse | \
  sed 's/^#\([0-9]*\).*/\1/')

if [ -z "$PR_NUMBER" ]; then
  echo "No PR selected"
  exit 1
fi

echo "Monitoring PR #${PR_NUMBER} status..."

while true; do
  PR_DATA=$(gh pr view "${PR_NUMBER}" "${REPO_FLAG[@]}" --json statusCheckRollup,state 2>/dev/null)
  STATUS=$(echo "$PR_DATA" | jq -r '[.statusCheckRollup[] | select(.conclusion != null and .conclusion != "") | .conclusion] | unique | .[]')
  PENDING_COUNT=$(echo "$PR_DATA" | jq '[.statusCheckRollup[] | select(.conclusion == null or .conclusion == "")] | length')
  SUCCESS_COUNT=$(echo "$PR_DATA" | jq '[.statusCheckRollup[] | select(.conclusion == "SUCCESS")] | length')
  TOTAL_COUNT=$(echo "$PR_DATA" | jq '[.statusCheckRollup[]] | length')
  STATE=$(echo "$PR_DATA" | jq -r '.state')

  if [ "$PENDING_COUNT" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - PR has ${PENDING_COUNT} pending checks, waiting..."
  elif [ "$STATE" = "MERGED" ] || [ "$STATE" = "CLOSED" ]; then
    echo -e "PR is ${STATE}\a"
    exit 0
  elif echo "$STATUS" | grep -qi "FAILURE\|CANCELLED\|TIMED_OUT"; then
    echo -e "❌ PR #${PR_NUMBER} has failing checks\a"
    exit 1
  elif [ "$TOTAL_COUNT" -gt "0" ] && [ "$SUCCESS_COUNT" = "$TOTAL_COUNT" ]; then
    echo -e "✅ PR #${PR_NUMBER} is GREEN!\a"
    exit 0
  else
    echo -e "⚠️  PR #${PR_NUMBER} has no checks or unclear status (${SUCCESS_COUNT}/${TOTAL_COUNT} successful)\a"
    exit 0
  fi
  
  sleep 60
done
