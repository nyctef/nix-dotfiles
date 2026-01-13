#!/usr/bin/env bash
# Claude Code Notification Hook
# Displays notifications using wsl-toast when Claude prompts for input
#
# Documentation: https://code.claude.com/docs/en/hooks#notification
#
# Expected input format (JSON via stdin):
# {
#   "session_id": "abc123",
#   "transcript_path": "/path/to/transcript.jsonl",
#   "cwd": "/current/working/directory",
#   "permission_mode": "default",
#   "hook_event_name": "Notification",
#   "message": "The notification message to display",
#   "notification_type": "idle_prompt|permission_prompt|auth_success|elicitation_dialog"
# }

# Read JSON from stdin
INPUT=$(cat)

# Extract the message and notification_type from JSON
MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude needs your attention"')
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "notification"')

# Set title based on notification type
case "$NOTIFICATION_TYPE" in
  "idle_prompt")
    TITLE="Claude Waiting"
    ;;
  "permission_prompt")
    TITLE="Claude Permission"
    ;;
  "auth_success")
    TITLE="Claude Auth"
    ;;
  "elicitation_dialog")
    TITLE="Claude Input"
    ;;
  *)
    TITLE="Claude Code"
    ;;
esac

# Call wsl-toast with the extracted message
wsl-toast "$TITLE" "$MESSAGE"
