#!/bin/bash
#
# build-slack-message.sh - Transforms merge info JSON into Slack Block Kit format
#
# Usage:
#   ./build-slack-message.sh [options]
#
# Options:
#   --input PATH       Input JSON file (or reads from stdin)
#   --config PATH      Path to config file for user mappings, etc.
#   --help             Show this help message
#
# Output:
#   Slack Block Kit JSON message to stdout
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
INPUT_FILE=""
CONFIG_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --input)
            INPUT_FILE="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --help)
            head -18 "$0" | tail -n +2 | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Read input
if [[ -n "$INPUT_FILE" ]]; then
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "Error: Input file not found: $INPUT_FILE" >&2
        exit 1
    fi
    INPUT=$(cat "$INPUT_FILE")
else
    INPUT=$(cat)
fi

# Validate JSON
if ! echo "$INPUT" | jq . > /dev/null 2>&1; then
    echo "Error: Invalid JSON input" >&2
    exit 1
fi

# Load config if provided
USER_MAPPING="{}"
HIGHLIGHT_LABELS="[]"
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    USER_MAPPING=$(jq '.userMapping // {}' "$CONFIG_FILE")
    HIGHLIGHT_LABELS=$(jq '.labels.highlight // []' "$CONFIG_FILE")
fi

# Extract data from input
REPO=$(echo "$INPUT" | jq -r '.repo')
TAG=$(echo "$INPUT" | jq -r '.tag // ""')
COMMIT_SHA=$(echo "$INPUT" | jq -r '.commit.sha')
COMMIT_SHORT=$(echo "$INPUT" | jq -r '.commit.short')
COMMIT_MESSAGE=$(echo "$INPUT" | jq -r '.commit.message')
COMMIT_AUTHOR=$(echo "$INPUT" | jq -r '.commit.author')
IS_MERGE=$(echo "$INPUT" | jq -r '.commit.is_merge')

FILES_CHANGED=$(echo "$INPUT" | jq -r '.diff.files_changed')
LINES_ADDED=$(echo "$INPUT" | jq -r '.diff.lines_added')
LINES_DELETED=$(echo "$INPUT" | jq -r '.diff.lines_deleted')

HAS_PR=$(echo "$INPUT" | jq '.pr != null')
CONCERNS=$(echo "$INPUT" | jq '.concerns')
HAS_CONCERNS=$(echo "$INPUT" | jq '.concerns | length > 0')
HAS_ERRORS=$(echo "$INPUT" | jq '[.concerns[] | select(.severity == "error")] | length > 0')

# Helper function to map GitHub username to Slack display
map_user() {
    local github_user="$1"
    local slack_name
    slack_name=$(echo "$USER_MAPPING" | jq -r --arg u "$github_user" '.[$u] // empty')
    
    if [[ -n "$slack_name" ]]; then
        echo "$slack_name"
    else
        # Return GitHub username with indicator that it's not mapped
        echo "⌐ $github_user"
    fi
}

# Build GitHub URLs
GITHUB_BASE="https://github.com/$REPO"
COMMIT_URL="$GITHUB_BASE/commit/$COMMIT_SHA"
TAG_URL="$GITHUB_BASE/releases/tag/$TAG"

# Start building the message
BLOCKS="[]"

# ============================================
# Header Block - Tag name or commit info
# ============================================
if [[ -n "$TAG" && "$TAG" != "" ]]; then
    HEADER_TEXT="🚀 $TAG"
    HEADER_URL="$TAG_URL"
else
    HEADER_TEXT="🚀 Merge to main ($COMMIT_SHORT)"
    HEADER_URL="$COMMIT_URL"
fi

BLOCKS=$(echo "$BLOCKS" | jq --arg text "$HEADER_TEXT" '. + [{
    "type": "header",
    "text": {
        "type": "plain_text",
        "text": $text,
        "emoji": true
    }
}]')

# ============================================
# Warning Block (if there are concerns with errors)
# ============================================
if [[ "$HAS_ERRORS" == "true" ]]; then
    ERROR_MESSAGES=$(echo "$CONCERNS" | jq -r '[.[] | select(.severity == "error") | .message] | join("\n")')
    WARNING_BLOCK=$(jq -n --arg msg "⚠️ WARNING: $ERROR_MESSAGES" '{
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": $msg
        }
    }')
    BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$WARNING_BLOCK" '. + [$block]')
fi

# Non-PR warning (direct push)
if [[ "$HAS_PR" == "false" ]]; then
    DIRECT_PUSH_BLOCK=$(jq -n '{
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": "⚠️ *Direct push to main* (not from a PR)"
        }
    }')
    BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$DIRECT_PUSH_BLOCK" '. + [$block]')
fi

# ============================================
# PR Info Section (if from PR)
# ============================================
if [[ "$HAS_PR" == "true" ]]; then
    PR_NUMBER=$(echo "$INPUT" | jq -r '.pr.number')
    PR_TITLE=$(echo "$INPUT" | jq -r '.pr.title')
    PR_AUTHOR=$(echo "$INPUT" | jq -r '.pr.author')
    PR_MERGED_BY=$(echo "$INPUT" | jq -r '.pr.merged_by')
    PR_BRANCH=$(echo "$INPUT" | jq -r '.pr.branch')
    PR_LABELS=$(echo "$INPUT" | jq '.pr.labels')
    PR_COMMIT_COUNT=$(echo "$INPUT" | jq -r '.pr.commit_count')
    APPROVALS=$(echo "$INPUT" | jq -r '.pr.approvals')
    
    PR_URL="$GITHUB_BASE/pull/$PR_NUMBER"
    
    # Map users
    PR_AUTHOR_DISPLAY=$(map_user "$PR_AUTHOR")
    PR_MERGED_BY_DISPLAY=$(map_user "$PR_MERGED_BY")
    
    # Check for highlighted labels
    LABEL_BADGES=""
    while IFS= read -r label; do
        if [[ -n "$label" ]]; then
            # Check if this label should be highlighted
            IS_HIGHLIGHTED=$(echo "$HIGHLIGHT_LABELS" | jq --arg l "$label" 'any(. == $l)')
            if [[ "$IS_HIGHLIGHTED" == "true" ]]; then
                case "$label" in
                    *[Hh]otfix*)
                        LABEL_BADGES="$LABEL_BADGES 🔥 $label"
                        ;;
                    *[Ss]ecurity*)
                        LABEL_BADGES="$LABEL_BADGES 🔒 $label"
                        ;;
                    *[Bb]reaking*)
                        LABEL_BADGES="$LABEL_BADGES ⚡ $label"
                        ;;
                    *)
                        LABEL_BADGES="$LABEL_BADGES 🏷️ $label"
                        ;;
                esac
            fi
        fi
    done < <(echo "$PR_LABELS" | jq -r '.[]')
    
    # Build PR section
    PR_TEXT="*PR:* <$PR_URL|#$PR_NUMBER $PR_TITLE> - by $PR_AUTHOR_DISPLAY ($PR_BRANCH)"
    if [[ "$PR_AUTHOR" != "$PR_MERGED_BY" ]]; then
        PR_TEXT="$PR_TEXT\n*Merged by:* $PR_MERGED_BY_DISPLAY"
    fi
    
    PR_SECTION=$(jq -n --arg text "$PR_TEXT" '{
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": $text
        }
    }')
    BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$PR_SECTION" '. + [$block]')
    
    # Label badges (if any)
    if [[ -n "$LABEL_BADGES" ]]; then
        LABEL_BLOCK=$(jq -n --arg text "$LABEL_BADGES" '{
            "type": "context",
            "elements": [{
                "type": "mrkdwn",
                "text": $text
            }]
        }')
        BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$LABEL_BLOCK" '. + [$block]')
    fi
fi

# ============================================
# Check Status Section
# ============================================
CHECKS=$(echo "$INPUT" | jq '.checks')
CHECKS_COUNT=$(echo "$CHECKS" | jq 'length')

if [[ "$CHECKS_COUNT" -gt 0 ]]; then
    PASSED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "success")] | length')
    FAILED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "failure")] | length')
    PENDING=$(echo "$CHECKS" | jq '[.[] | select(.status != "completed")] | length')
    SKIPPED=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "skipped")] | length')
    
    if [[ "$FAILED" -gt 0 ]]; then
        CHECK_EMOJI="❌"
        CHECK_TEXT="$FAILED failed"
        if [[ "$PASSED" -gt 0 ]]; then
            CHECK_TEXT="$CHECK_TEXT, $PASSED passed"
        fi
    elif [[ "$PENDING" -gt 0 ]]; then
        CHECK_EMOJI="⏳"
        CHECK_TEXT="$PENDING pending, $PASSED passed"
    elif [[ "$PASSED" -gt 0 ]]; then
        CHECK_EMOJI="✅"
        CHECK_TEXT="All $PASSED checks passed"
    else
        CHECK_EMOJI="⚪"
        CHECK_TEXT="$SKIPPED skipped"
    fi
    
    CHECK_SECTION=$(jq -n --arg text "$CHECK_EMOJI *Checks:* $CHECK_TEXT" '{
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": $text
        }
    }')
    BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$CHECK_SECTION" '. + [$block]')
    
    # Show failed checks detail
    if [[ "$FAILED" -gt 0 ]]; then
        FAILED_DETAILS=""
        while IFS= read -r check; do
            NAME=$(echo "$check" | jq -r '.name')
            URL=$(echo "$check" | jq -r '.url')
            FAILED_DETAILS="$FAILED_DETAILS  • <$URL|$NAME>\n"
        done < <(echo "$CHECKS" | jq -c '.[] | select(.conclusion == "failure")')
        
        FAILED_BLOCK=$(jq -n --arg text "$FAILED_DETAILS" '{
            "type": "context",
            "elements": [{
                "type": "mrkdwn",
                "text": $text
            }]
        }')
        BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$FAILED_BLOCK" '. + [$block]')
    fi
fi

# ============================================
# Reviews Section (if from PR with reviews)
# ============================================
if [[ "$HAS_PR" == "true" ]]; then
    REVIEWS=$(echo "$INPUT" | jq '.pr.reviews')
    REVIEW_COUNT=$(echo "$REVIEWS" | jq 'length')
    
    if [[ "$REVIEW_COUNT" -gt 0 ]]; then
        REVIEW_TEXT=""
        
        # Group by reviewer, taking their latest state
        REVIEWER_STATES=$(echo "$REVIEWS" | jq 'group_by(.author) | map({author: .[0].author, state: .[-1].state})')
        
        while IFS= read -r reviewer; do
            AUTHOR=$(echo "$reviewer" | jq -r '.author')
            STATE=$(echo "$reviewer" | jq -r '.state')
            AUTHOR_DISPLAY=$(map_user "$AUTHOR")
            
            case "$STATE" in
                "APPROVED")
                    REVIEW_TEXT="$REVIEW_TEXT ✔️ $AUTHOR_DISPLAY"
                    ;;
                "CHANGES_REQUESTED")
                    REVIEW_TEXT="$REVIEW_TEXT ⁉️ $AUTHOR_DISPLAY"
                    ;;
                "COMMENTED")
                    REVIEW_TEXT="$REVIEW_TEXT 💬 $AUTHOR_DISPLAY"
                    ;;
                *)
                    REVIEW_TEXT="$REVIEW_TEXT 👁️ $AUTHOR_DISPLAY"
                    ;;
            esac
        done < <(echo "$REVIEWER_STATES" | jq -c '.[]')
        
        if [[ -n "$REVIEW_TEXT" ]]; then
            REVIEW_BLOCK=$(jq -n --arg text "*Reviews:*$REVIEW_TEXT" '{
                "type": "context",
                "elements": [{
                    "type": "mrkdwn",
                    "text": $text
                }]
            }')
            BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$REVIEW_BLOCK" '. + [$block]')
        fi
    fi
fi

# ============================================
# Linked Issues Section
# ============================================
LINKED_ISSUES=$(echo "$INPUT" | jq '.linked_issues')
ISSUES_COUNT=$(echo "$LINKED_ISSUES" | jq 'length')

if [[ "$ISSUES_COUNT" -gt 0 ]]; then
    ISSUES_TEXT="*Linked Issues ($ISSUES_COUNT):*\n"
    
    while IFS= read -r issue; do
        ISSUE_NUM=$(echo "$issue" | jq -r '.number')
        ISSUE_TITLE=$(echo "$issue" | jq -r '.title')
        ISSUE_STATE=$(echo "$issue" | jq -r '.state')
        ISSUE_REPO=$(echo "$issue" | jq -r '.repo')
        IS_CROSS_REPO=$(echo "$issue" | jq -r '.is_cross_repo')
        
        # Build issue reference
        if [[ "$IS_CROSS_REPO" == "true" ]]; then
            ISSUE_REF="$ISSUE_REPO#$ISSUE_NUM"
            ISSUE_URL="https://github.com/$ISSUE_REPO/issues/$ISSUE_NUM"
        else
            ISSUE_REF="#$ISSUE_NUM"
            ISSUE_URL="$GITHUB_BASE/issues/$ISSUE_NUM"
        fi
        
        # State indicator
        case "$ISSUE_STATE" in
            "CLOSED")
                STATE_ICON="✓"
                ;;
            "OPEN")
                STATE_ICON="○"
                ;;
            *)
                STATE_ICON="?"
                ;;
        esac
        
        ISSUES_TEXT="$ISSUES_TEXT  • $STATE_ICON <$ISSUE_URL|$ISSUE_REF> $ISSUE_TITLE\n"
    done < <(echo "$LINKED_ISSUES" | jq -c '.[]')
    
    ISSUES_SECTION=$(jq -n --arg text "$ISSUES_TEXT" '{
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": $text
        }
    }')
    BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$ISSUES_SECTION" '. + [$block]')
elif [[ "$HAS_PR" == "true" ]]; then
    # Mild warning for no linked issues
    NO_ISSUES_BLOCK=$(jq -n '{
        "type": "context",
        "elements": [{
            "type": "mrkdwn",
            "text": "😶‍🌫️ No linked issues"
        }]
    }')
    BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$NO_ISSUES_BLOCK" '. + [$block]')
fi

# ============================================
# Divider
# ============================================
BLOCKS=$(echo "$BLOCKS" | jq '. + [{"type": "divider"}]')

# ============================================
# Summary Context Line
# ============================================
SUMMARY_PARTS=""

if [[ "$HAS_PR" == "true" ]]; then
    PR_COMMIT_COUNT=$(echo "$INPUT" | jq -r '.pr.commit_count')
    SUMMARY_PARTS="📦 $PR_COMMIT_COUNT commits"
else
    SUMMARY_PARTS="📦 1 commit"
fi

SUMMARY_PARTS="$SUMMARY_PARTS • $FILES_CHANGED files • +$LINES_ADDED/-$LINES_DELETED lines"

if [[ "$HAS_PR" == "true" ]]; then
    APPROVALS=$(echo "$INPUT" | jq -r '.pr.approvals')
    if [[ "$APPROVALS" -gt 0 ]]; then
        SUMMARY_PARTS="$SUMMARY_PARTS • $APPROVALS approvals"
    fi
fi

SUMMARY_BLOCK=$(jq -n --arg text "$SUMMARY_PARTS" '{
    "type": "context",
    "elements": [{
        "type": "mrkdwn",
        "text": $text
    }]
}')
BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$SUMMARY_BLOCK" '. + [$block]')

# ============================================
# Action Buttons
# ============================================
ACTIONS_ELEMENTS="[]"

if [[ "$HAS_PR" == "true" ]]; then
    PR_NUMBER=$(echo "$INPUT" | jq -r '.pr.number')
    PR_URL="$GITHUB_BASE/pull/$PR_NUMBER"
    
    ACTIONS_ELEMENTS=$(echo "$ACTIONS_ELEMENTS" | jq --arg url "$PR_URL" '. + [{
        "type": "button",
        "text": {
            "type": "plain_text",
            "text": "View PR"
        },
        "url": $url
    }]')
fi

# Compare URL (commit to previous)
COMPARE_URL="$GITHUB_BASE/commit/$COMMIT_SHA"
ACTIONS_ELEMENTS=$(echo "$ACTIONS_ELEMENTS" | jq --arg url "$COMPARE_URL" '. + [{
    "type": "button",
    "text": {
        "type": "plain_text",
        "text": "View Changes"
    },
    "url": $url
}]')

# Tag URL (if we have a tag)
if [[ -n "$TAG" && "$TAG" != "" ]]; then
    ACTIONS_ELEMENTS=$(echo "$ACTIONS_ELEMENTS" | jq --arg url "$TAG_URL" '. + [{
        "type": "button",
        "text": {
            "type": "plain_text",
            "text": "View Tag"
        },
        "url": $url
    }]')
fi

ACTIONS_BLOCK=$(jq -n --argjson elements "$ACTIONS_ELEMENTS" '{
    "type": "actions",
    "elements": $elements
}')
BLOCKS=$(echo "$BLOCKS" | jq --argjson block "$ACTIONS_BLOCK" '. + [$block]')

# ============================================
# Build final message
# ============================================
MESSAGE=$(jq -n --argjson blocks "$BLOCKS" '{
    "blocks": $blocks
}')

echo "$MESSAGE" | jq .


















