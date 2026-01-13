#!/bin/bash
#
# send-slack-message.sh - Sends a message to Slack via webhook
#
# Usage:
#   ./send-slack-message.sh [options]
#
# Options:
#   --webhook URL      Slack webhook URL (or use SLACK_WEBHOOK_URL env var)
#   --message JSON     Message payload as JSON string
#   --file PATH        Read message payload from file
#   --dry-run          Show what would be sent without sending
#   --help             Show this help message
#
# Input:
#   If neither --message nor --file is provided, reads JSON from stdin
#
# Output:
#   Prints Slack API response
#   Exit 0 on success, 1 on failure
#

set -euo pipefail

# Defaults
WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
MESSAGE=""
MESSAGE_FILE=""
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --webhook)
            WEBHOOK_URL="$2"
            shift 2
            ;;
        --message)
            MESSAGE="$2"
            shift 2
            ;;
        --file)
            MESSAGE_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            head -25 "$0" | tail -n +2 | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate webhook URL (unless dry-run)
if [[ -z "$WEBHOOK_URL" && "$DRY_RUN" == "false" ]]; then
    echo "Error: Webhook URL required (--webhook or SLACK_WEBHOOK_URL env var)" >&2
    exit 1
fi

# Get the message content
if [[ -n "$MESSAGE" ]]; then
    PAYLOAD="$MESSAGE"
elif [[ -n "$MESSAGE_FILE" ]]; then
    if [[ ! -f "$MESSAGE_FILE" ]]; then
        echo "Error: Message file not found: $MESSAGE_FILE" >&2
        exit 1
    fi
    PAYLOAD=$(cat "$MESSAGE_FILE")
else
    # Read from stdin
    PAYLOAD=$(cat)
fi

# Validate JSON
if ! echo "$PAYLOAD" | jq . > /dev/null 2>&1; then
    echo "Error: Invalid JSON payload" >&2
    exit 1
fi

# Dry run mode
if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would send to Slack webhook:"
    echo "$PAYLOAD" | jq .
    exit 0
fi

# Send to Slack
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$WEBHOOK_URL")

# Parse response
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

# Check for success
# Slack webhooks return "ok" on success
if [[ "$HTTP_CODE" == "200" && "$BODY" == "ok" ]]; then
    echo "Message sent successfully" >&2
    exit 0
else
    echo "Error sending message to Slack" >&2
    echo "HTTP Status: $HTTP_CODE" >&2
    echo "Response: $BODY" >&2
    exit 1
fi
