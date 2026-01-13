#!/bin/bash
#
# parse-issues.sh - Extracts "Resolves #XXX" references from PR body text
#
# Usage:
#   ./parse-issues.sh "$PR_BODY"
#   echo "$PR_BODY" | ./parse-issues.sh
#
# Output:
#   Newline-delimited list of issue references (e.g., "#123" or "org/repo#456")
#   Empty output if no references found
#
# Rules:
#   - Only matches lines starting with bullet points (- or *)
#   - Skips content inside code blocks (triple backticks)
#   - Handles cross-repo references: org/repo#123
#   - Case-insensitive matching of "Resolves"
#

set -euo pipefail

# Read PR body from argument or stdin
if [[ $# -ge 1 ]]; then
    PR_BODY="$1"
else
    PR_BODY=$(cat)
fi

# Exit early if empty
if [[ -z "$PR_BODY" ]]; then
    exit 0
fi

# Process the PR body:
# 1. Remove code blocks (content between triple backticks)
# 2. Find lines with "Resolves" references
# 3. Extract the issue references

# Use awk to handle code block removal and pattern matching
echo "$PR_BODY" | awk '
BEGIN {
    in_code_block = 0
}

# Toggle code block state on triple backticks
/^```/ {
    in_code_block = !in_code_block
    next
}

# Skip lines inside code blocks
in_code_block {
    next
}

# Match bullet point lines with "Resolves" (case-insensitive)
# Pattern: optional whitespace, bullet (- or *), whitespace, "Resolves", whitespace, optional repo/, #number
/^[[:space:]]*[-*][[:space:]]+[Rr]esolves[[:space:]]+(([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?#[0-9]+)/ {
    # Extract the issue reference from the line
    line = $0
    
    # Use match to find the pattern
    # We need to handle both "#123" and "org/repo#123" formats
    while (match(line, /([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?#[0-9]+/)) {
        ref = substr(line, RSTART, RLENGTH)
        print ref
        # Move past this match to find any additional references on the same line
        line = substr(line, RSTART + RLENGTH)
    }
}
' | sort -u  # Remove duplicates and sort
