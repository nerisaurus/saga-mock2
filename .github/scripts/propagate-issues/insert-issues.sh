#!/bin/bash
#
# insert-issues.sh - Inserts issue references into a PR body
#
# Usage:
#   ./insert-issues.sh --source-pr NUM --issues "ISSUES" --target-body "BODY"
#
# Arguments:
#   --source-pr     The PR number that was merged (for attribution)
#   --issues        Newline-delimited list of issue references (e.g., "#123\norg/repo#456")
#   --target-body   The current body of the target PR
#
# Output:
#   JSON object with:
#     - success: boolean - whether insertion was successful
#     - body: string - the new PR body (only if success=true)
#     - issues_added: array - list of issues that were actually added (after deduplication)
#     - reason: string - explanation (especially if success=false)
#
# Strategy:
#   1. Check for existing markers - if found, append within them
#   2. Search for "Issues Resolved" section header
#   3. If found: insert markers after the section ends
#   4. If not found: insert after first major section or fall back to comment
#

set -euo pipefail

# Parse arguments
SOURCE_PR=""
ISSUES=""
TARGET_BODY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-pr)
            SOURCE_PR="$2"
            shift 2
            ;;
        --issues)
            ISSUES="$2"
            shift 2
            ;;
        --target-body)
            TARGET_BODY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$SOURCE_PR" || -z "$ISSUES" ]]; then
    echo '{"success": false, "body": "", "issues_added": [], "reason": "Missing required arguments"}'
    exit 0
fi

# Handle empty target body
if [[ -z "$TARGET_BODY" ]]; then
    TARGET_BODY=""
fi

# Markers for the propagated issues section
START_MARKER="<!-- PROPAGATED_ISSUES:START -->"
END_MARKER="<!-- PROPAGATED_ISSUES:END -->"

# Function to check if an issue reference already exists in text
issue_exists_in_text() {
    local issue="$1"
    local text="$2"
    
    # Escape special regex characters in the issue reference
    local escaped_issue=$(echo "$issue" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Check if the issue appears in the text (case-insensitive for "Resolves")
    if echo "$text" | grep -qi "[Rr]esolves[[:space:]]\+${escaped_issue}"; then
        return 0
    fi
    
    # Also check for the raw reference without "Resolves" (in case someone just wrote #123)
    if echo "$text" | grep -qE "(^|[^A-Za-z0-9])${escaped_issue}([^0-9]|$)"; then
        return 0
    fi
    
    return 1
}

# Function to build the new sub-section for this PR
build_subsection() {
    local source_pr="$1"
    local issues="$2"  # newline-delimited
    
    local section="#### Additional Issues Resolved (from PR #${source_pr})"
    
    while IFS= read -r issue; do
        if [[ -n "$issue" ]]; then
            section="$section
- Resolves $issue"
        fi
    done <<< "$issues"
    
    echo "$section"
}

# Collect issues that need to be added (after deduplication)
ISSUES_TO_ADD=""
while IFS= read -r issue; do
    if [[ -n "$issue" ]]; then
        if ! issue_exists_in_text "$issue" "$TARGET_BODY"; then
            if [[ -z "$ISSUES_TO_ADD" ]]; then
                ISSUES_TO_ADD="$issue"
            else
                ISSUES_TO_ADD="$ISSUES_TO_ADD
$issue"
            fi
        fi
    fi
done <<< "$ISSUES"

# If no new issues to add, return success with empty additions
if [[ -z "$ISSUES_TO_ADD" ]]; then
    echo '{"success": true, "body": "", "issues_added": [], "reason": "All issues already exist in target PR"}'
    exit 0
fi

# Convert issues to JSON array for output
ISSUES_JSON_ARRAY=$(echo "$ISSUES_TO_ADD" | jq -R -s 'split("\n") | map(select(length > 0))')

# Build the new sub-section
NEW_SUBSECTION=$(build_subsection "$SOURCE_PR" "$ISSUES_TO_ADD")

# Strategy 1: Check for existing markers
if echo "$TARGET_BODY" | grep -qF "$START_MARKER"; then
    # Found existing markers - append within them
    
    # Extract content between markers
    BEFORE_MARKERS=$(echo "$TARGET_BODY" | awk -v marker="$START_MARKER" '
        BEGIN { found = 0 }
        $0 ~ marker { found = 1; print; exit }
        { print }
    ')
    BEFORE_MARKERS=${BEFORE_MARKERS%"$START_MARKER"}
    
    AFTER_MARKERS=$(echo "$TARGET_BODY" | awk -v marker="$END_MARKER" '
        BEGIN { found = 0 }
        found { print }
        $0 ~ marker { found = 1 }
    ')
    
    BETWEEN_MARKERS=$(echo "$TARGET_BODY" | awk -v start="$START_MARKER" -v end="$END_MARKER" '
        BEGIN { capture = 0 }
        $0 ~ start { capture = 1; next }
        $0 ~ end { capture = 0; next }
        capture { print }
    ')
    
    # Check if this source PR already has a section (idempotency)
    if echo "$BETWEEN_MARKERS" | grep -qF "from PR #${SOURCE_PR})"; then
        # Already has a section for this PR - don't duplicate
        echo "{\"success\": true, \"body\": \"\", \"issues_added\": [], \"reason\": \"PR #${SOURCE_PR} already has a propagated section\"}"
        exit 0
    fi
    
    # Append new sub-section
    NEW_BODY="${BEFORE_MARKERS}${START_MARKER}
${BETWEEN_MARKERS}
${NEW_SUBSECTION}
${END_MARKER}${AFTER_MARKERS}"
    
    # Output success
    echo "$NEW_BODY" | jq -Rs --argjson issues "$ISSUES_JSON_ARRAY" '{
        success: true,
        body: .,
        issues_added: $issues,
        reason: "Appended to existing propagated issues section"
    }'
    exit 0
fi

# Strategy 2: Find "Issues Resolved" section and insert after it
# Look for common header patterns (case-insensitive)
# Patterns: "### Issues Resolved", "### :tada: Issues Resolved", "## Issues Resolved", "**Issues Resolved**", etc.

# Use awk to find the section and determine insertion point
INSERTION_RESULT=$(echo "$TARGET_BODY" | awk '
BEGIN {
    found_section = 0
    section_start = 0
    in_list = 0
    last_list_line = 0
    line_num = 0
}

{
    line_num++
    lines[line_num] = $0
}

# Match "Issues Resolved" header (various formats)
/^#+[[:space:]]*:?[^:]*:?[[:space:]]*[Ii]ssues[[:space:]]+[Rr]esolved/ ||
/^\*\*[[:space:]]*[Ii]ssues[[:space:]]+[Rr]esolved/ {
    if (!found_section) {
        found_section = 1
        section_start = line_num
    }
}

# Track bullet list continuation after finding section
found_section && /^[[:space:]]*[-*][[:space:]]/ {
    in_list = 1
    last_list_line = line_num
}

# Detect end of list (blank line or new section after being in a list)
found_section && in_list && (/^[[:space:]]*$/ || /^#+[[:space:]]/ || /^\*\*/) {
    # List ended
}

END {
    if (found_section && last_list_line > 0) {
        # Insert after the last bullet point in the Issues Resolved section
        print "INSERT_AFTER:" last_list_line
    } else if (found_section) {
        # Found header but no list items - insert right after header
        print "INSERT_AFTER:" section_start
    } else {
        print "NOT_FOUND"
    }
}
')

if [[ "$INSERTION_RESULT" == "NOT_FOUND" ]]; then
    # Strategy 3: Try to find any reasonable insertion point
    # Look for first major section header and insert after the first section
    
    FIRST_SECTION_END=$(echo "$TARGET_BODY" | awk '
    BEGIN {
        found_first_header = 0
        first_header_line = 0
        line_num = 0
    }
    
    {
        line_num++
    }
    
    # Match any markdown header
    /^#+[[:space:]]/ {
        if (!found_first_header) {
            found_first_header = 1
            first_header_line = line_num
        } else if (first_header_line > 0) {
            # Found second header - insert before it
            print "INSERT_BEFORE:" line_num
            exit
        }
    }
    
    END {
        if (found_first_header && first_header_line > 0) {
            # Only one section found, insert at end
            print "INSERT_AT_END"
        } else {
            print "NO_STRUCTURE"
        }
    }
    ')
    
    if [[ "$FIRST_SECTION_END" == "NO_STRUCTURE" ]]; then
        # Cannot find safe insertion point - fall back to comment
        echo "{\"success\": false, \"body\": \"\", \"issues_added\": [], \"reason\": \"Could not find a safe insertion point - PR body has no recognizable structure\"}"
        exit 0
    fi
    
    # Build the full propagated issues section with markers
    FULL_SECTION="${START_MARKER}
${NEW_SUBSECTION}
${END_MARKER}"
    
    if [[ "$FIRST_SECTION_END" == "INSERT_AT_END" ]]; then
        # Insert at end of body
        NEW_BODY="${TARGET_BODY}

${FULL_SECTION}"
    else
        # Insert before second section
        INSERT_LINE=$(echo "$FIRST_SECTION_END" | sed 's/INSERT_BEFORE://')
        
        NEW_BODY=$(echo "$TARGET_BODY" | awk -v insert_line="$INSERT_LINE" -v section="$FULL_SECTION" '
        {
            if (NR == insert_line) {
                print ""
                print section
                print ""
            }
            print
        }
        ')
    fi
    
    echo "$NEW_BODY" | jq -Rs --argjson issues "$ISSUES_JSON_ARRAY" '{
        success: true,
        body: .,
        issues_added: $issues,
        reason: "Created new propagated issues section (no Issues Resolved section found)"
    }'
    exit 0
fi

# Extract insertion point from result
INSERT_AFTER_LINE=$(echo "$INSERTION_RESULT" | sed 's/INSERT_AFTER://')

# Build the full propagated issues section with markers
FULL_SECTION="${START_MARKER}
${NEW_SUBSECTION}
${END_MARKER}"

# Insert the section after the specified line
NEW_BODY=$(echo "$TARGET_BODY" | awk -v insert_line="$INSERT_AFTER_LINE" -v section="$FULL_SECTION" '
{
    print
    if (NR == insert_line) {
        print ""
        print section
    }
}
')

echo "$NEW_BODY" | jq -Rs --argjson issues "$ISSUES_JSON_ARRAY" '{
    success: true,
    body: .,
    issues_added: $issues,
    reason: "Inserted after Issues Resolved section"
}'

