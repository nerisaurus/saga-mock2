#!/bin/bash
#
# gather-merge-info.sh - Collects information about a merge commit
#
# Usage:
#   ./gather-merge-info.sh [options]
#
# Options:
#   --commit SHA       Commit to analyze (default: HEAD)
#   --repo OWNER/NAME  Repository (default: from git remote)
#   --tag TAG_NAME     Tag name to include in output
#   --config PATH      Path to config file
#   --help             Show this help message
#
# Output:
#   JSON object with all collected merge information
#
# Environment:
#   GITHUB_TOKEN       Required for API calls
#   GH_TOKEN           Alternative to GITHUB_TOKEN
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
COMMIT="HEAD"
REPO=""
TAG_NAME=""
CONFIG_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --commit)
            COMMIT="$2"
            shift 2
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --tag)
            TAG_NAME="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
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

# Get GitHub token
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "Warning: No GITHUB_TOKEN set, API calls may fail" >&2
fi

# Detect repository from git remote if not provided
if [[ -z "$REPO" ]]; then
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        echo "Error: Could not detect repository, use --repo OWNER/NAME" >&2
        exit 1
    fi
fi

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

# Get commit information
COMMIT_SHA=$(git rev-parse "$COMMIT")
COMMIT_SHORT=$(git rev-parse --short "$COMMIT")
COMMIT_MESSAGE=$(git log -1 --format="%s" "$COMMIT_SHA")
COMMIT_BODY=$(git log -1 --format="%b" "$COMMIT_SHA")
COMMIT_AUTHOR=$(git log -1 --format="%an" "$COMMIT_SHA")
COMMIT_AUTHOR_EMAIL=$(git log -1 --format="%ae" "$COMMIT_SHA")
COMMIT_DATE=$(git log -1 --format="%aI" "$COMMIT_SHA")

# Detect if this is a merge commit (has multiple parents)
PARENT_COUNT=$(git rev-list --parents -n 1 "$COMMIT_SHA" | wc -w)
PARENT_COUNT=$((PARENT_COUNT - 1))  # Subtract the commit itself
IS_MERGE=$([[ $PARENT_COUNT -gt 1 ]] && echo "true" || echo "false")

# Get diff stats
DIFF_STATS=$(git diff --shortstat "${COMMIT_SHA}^..${COMMIT_SHA}" 2>/dev/null || echo "")
FILES_CHANGED=$(echo "$DIFF_STATS" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
LINES_ADDED=$(echo "$DIFF_STATS" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
LINES_DELETED=$(echo "$DIFF_STATS" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")

# Initialize output JSON
OUTPUT=$(jq -n \
    --arg sha "$COMMIT_SHA" \
    --arg short "$COMMIT_SHORT" \
    --arg message "$COMMIT_MESSAGE" \
    --arg body "$COMMIT_BODY" \
    --arg author "$COMMIT_AUTHOR" \
    --arg author_email "$COMMIT_AUTHOR_EMAIL" \
    --arg date "$COMMIT_DATE" \
    --arg tag "$TAG_NAME" \
    --arg repo "$REPO" \
    --argjson is_merge "$IS_MERGE" \
    --argjson parent_count "$PARENT_COUNT" \
    --argjson files_changed "${FILES_CHANGED:-0}" \
    --argjson lines_added "${LINES_ADDED:-0}" \
    --argjson lines_deleted "${LINES_DELETED:-0}" \
    '{
        commit: {
            sha: $sha,
            short: $short,
            message: $message,
            body: $body,
            author: $author,
            author_email: $author_email,
            date: $date,
            is_merge: $is_merge,
            parent_count: $parent_count
        },
        tag: $tag,
        repo: $repo,
        diff: {
            files_changed: $files_changed,
            lines_added: $lines_added,
            lines_deleted: $lines_deleted
        },
        pr: null,
        checks: [],
        linked_issues: [],
        concerns: []
    }')

# Function to make GitHub GraphQL requests
gh_graphql() {
    local query="$1"
    local variables="${2:-{}}"
    
    if [[ -z "$GITHUB_TOKEN" ]]; then
        echo "{}" 
        return 1
    fi
    
    curl -s -H "Authorization: bearer $GITHUB_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"query\": $(echo "$query" | jq -Rs .), \"variables\": $variables}" \
        https://api.github.com/graphql
}

# Function to make GitHub REST requests
gh_rest() {
    local endpoint="$1"
    
    if [[ -z "$GITHUB_TOKEN" ]]; then
        echo "{}"
        return 1
    fi
    
    curl -s -H "Authorization: bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com$endpoint"
}

# Try to find the PR that was merged (if this is a merge commit)
PR_NUMBER=""
PR_DATA=""

if [[ "$IS_MERGE" == "true" || "$COMMIT_MESSAGE" =~ ^Merge\ pull\ request\ \#([0-9]+) ]]; then
    # Try to extract PR number from merge commit message
    if [[ "$COMMIT_MESSAGE" =~ \#([0-9]+) ]]; then
        PR_NUMBER="${BASH_REMATCH[1]}"
    fi
fi

# If we couldn't find PR from message, try to find via API
if [[ -z "$PR_NUMBER" && -n "$GITHUB_TOKEN" ]]; then
    # Search for PRs merged with this commit
    SEARCH_RESULT=$(gh_rest "/repos/$REPO/commits/$COMMIT_SHA/pulls")
    if [[ $(echo "$SEARCH_RESULT" | jq 'if type == "array" then length else 0 end') -gt 0 ]]; then
        PR_NUMBER=$(echo "$SEARCH_RESULT" | jq -r '.[0].number')
    fi
fi

# If we found a PR, get detailed info
if [[ -n "$PR_NUMBER" && "$PR_NUMBER" != "null" ]]; then
    # GraphQL query for PR details including closing issues
    PR_QUERY='
    query($owner: String!, $repo: String!, $number: Int!) {
        repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
                number
                title
                body
                state
                merged
                mergedAt
                mergedBy {
                    login
                    name
                }
                author {
                    login
                }
                headRefName
                baseRefName
                labels(first: 20) {
                    nodes {
                        name
                    }
                }
                reviews(last: 20) {
                    nodes {
                        state
                        author {
                            login
                        }
                    }
                }
                commits {
                    totalCount
                }
                closingIssuesReferences(first: 50) {
                    nodes {
                        number
                        title
                        state
                        repository {
                            nameWithOwner
                        }
                    }
                }
            }
        }
    }'
    
    PR_VARS=$(jq -n \
        --arg owner "$OWNER" \
        --arg repo "$REPO_NAME" \
        --argjson number "$PR_NUMBER" \
        '{owner: $owner, repo: $repo, number: $number}')
    
    PR_RESPONSE=$(gh_graphql "$PR_QUERY" "$PR_VARS")
    
    if [[ $(echo "$PR_RESPONSE" | jq '.data.repository.pullRequest != null') == "true" ]]; then
        PR_DATA=$(echo "$PR_RESPONSE" | jq '.data.repository.pullRequest')
        
        # Extract PR info
        PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
        PR_AUTHOR=$(echo "$PR_DATA" | jq -r '.author.login // "unknown"')
        PR_MERGED_BY=$(echo "$PR_DATA" | jq -r '.mergedBy.login // "unknown"')
        PR_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
        PR_LABELS=$(echo "$PR_DATA" | jq '[.labels.nodes[].name]')
        PR_COMMIT_COUNT=$(echo "$PR_DATA" | jq '.commits.totalCount')
        
        # Process reviews
        REVIEWS=$(echo "$PR_DATA" | jq '[.reviews.nodes[] | {state: .state, author: .author.login}]')
        APPROVALS=$(echo "$REVIEWS" | jq '[.[] | select(.state == "APPROVED")] | length')
        CHANGES_REQUESTED=$(echo "$REVIEWS" | jq '[.[] | select(.state == "CHANGES_REQUESTED")]')
        
        # Process linked issues
        LINKED_ISSUES=$(echo "$PR_DATA" | jq '[.closingIssuesReferences.nodes[] | {
            number: .number,
            title: .title,
            state: .state,
            repo: .repository.nameWithOwner,
            is_cross_repo: (.repository.nameWithOwner != "'"$REPO"'")
        }]')
        
        # Update output with PR info
        OUTPUT=$(echo "$OUTPUT" | jq \
            --argjson pr_number "$PR_NUMBER" \
            --arg pr_title "$PR_TITLE" \
            --arg pr_author "$PR_AUTHOR" \
            --arg pr_merged_by "$PR_MERGED_BY" \
            --arg pr_branch "$PR_BRANCH" \
            --argjson pr_labels "$PR_LABELS" \
            --argjson pr_commit_count "$PR_COMMIT_COUNT" \
            --argjson reviews "$REVIEWS" \
            --argjson approvals "$APPROVALS" \
            --argjson changes_requested "$CHANGES_REQUESTED" \
            --argjson linked_issues "$LINKED_ISSUES" \
            '.pr = {
                number: $pr_number,
                title: $pr_title,
                author: $pr_author,
                merged_by: $pr_merged_by,
                branch: $pr_branch,
                labels: $pr_labels,
                commit_count: $pr_commit_count,
                reviews: $reviews,
                approvals: $approvals,
                changes_requested: $changes_requested
            } | .linked_issues = $linked_issues')
    fi
fi

# Get check runs for the commit
if [[ -n "$GITHUB_TOKEN" ]]; then
    CHECKS_RESPONSE=$(gh_rest "/repos/$REPO/commits/$COMMIT_SHA/check-runs")
    
    if [[ $(echo "$CHECKS_RESPONSE" | jq '.check_runs != null') == "true" ]]; then
        CHECKS=$(echo "$CHECKS_RESPONSE" | jq '[.check_runs[] | {
            name: .name,
            status: .status,
            conclusion: .conclusion,
            url: .html_url
        }]')
        
        OUTPUT=$(echo "$OUTPUT" | jq --argjson checks "$CHECKS" '.checks = $checks')
    fi
fi

# Detect concerns
CONCERNS="[]"

# Concern: Not from a PR
if [[ -z "$PR_NUMBER" || "$PR_NUMBER" == "null" ]]; then
    CONCERNS=$(echo "$CONCERNS" | jq '. + [{
        type: "no_pr",
        severity: "warning",
        message: "Not from a PR (direct push or force push)"
    }]')
fi

# Concern: Failed checks
if [[ $(echo "$OUTPUT" | jq '[.checks[] | select(.conclusion == "failure")] | length') -gt 0 ]]; then
    FAILED_CHECKS=$(echo "$OUTPUT" | jq -r '[.checks[] | select(.conclusion == "failure") | .name] | join(", ")')
    CONCERNS=$(echo "$CONCERNS" | jq --arg names "$FAILED_CHECKS" '. + [{
        type: "failed_checks",
        severity: "error",
        message: ("Failed checks: " + $names)
    }]')
fi

# Concern: Pending checks
if [[ $(echo "$OUTPUT" | jq '[.checks[] | select(.status != "completed")] | length') -gt 0 ]]; then
    CONCERNS=$(echo "$CONCERNS" | jq '. + [{
        type: "pending_checks",
        severity: "info",
        message: "Some checks were still pending"
    }]')
fi

# Concern: Changes requested
if [[ -n "$PR_NUMBER" && "$PR_NUMBER" != "null" ]]; then
    if [[ $(echo "$OUTPUT" | jq '.pr.changes_requested | length') -gt 0 ]]; then
        REQUESTERS=$(echo "$OUTPUT" | jq -r '[.pr.changes_requested[].author] | unique | join(", ")')
        CONCERNS=$(echo "$CONCERNS" | jq --arg names "$REQUESTERS" '. + [{
            type: "changes_requested",
            severity: "warning",
            message: ("Outstanding change requests from: " + $names)
        }]')
    fi
fi

# Concern: No linked issues (mild)
if [[ $(echo "$OUTPUT" | jq '.linked_issues | length') -eq 0 && -n "$PR_NUMBER" && "$PR_NUMBER" != "null" ]]; then
    CONCERNS=$(echo "$CONCERNS" | jq '. + [{
        type: "no_linked_issues",
        severity: "info",
        message: "No linked issues"
    }]')
fi

# Add concerns to output
OUTPUT=$(echo "$OUTPUT" | jq --argjson concerns "$CONCERNS" '.concerns = $concerns')

# Output the final JSON
echo "$OUTPUT" | jq .
