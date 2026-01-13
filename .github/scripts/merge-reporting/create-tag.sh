#!/bin/bash
#
# create-tag.sh - Creates a version tag for merge commits
#
# Usage:
#   ./create-tag.sh [options]
#
# Options:
#   --commit SHA       Commit to tag (default: HEAD)
#   --major VERSION    Major version prefix (e.g., "1" for v1.x.y)
#   --push             Push the tag to origin
#   --dry-run          Show what would be done without doing it
#   --help             Show this help message
#
# Output:
#   Prints the created tag name to stdout
#   Sets TAG_NAME in GITHUB_OUTPUT if running in GitHub Actions
#
# Tag format: YYYY-MM-DD-vX.Y-adjective-animal
#   - YYYY-MM-DD: Current date
#   - vX.Y: Version from commit count (X = commits/1000 % 1000, Y = commits % 1000)
#   - adjective-animal: Friendly name derived from commit SHA
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the wordlist
source "${SCRIPT_DIR}/lib/wordlist.sh"

# Defaults
COMMIT="HEAD"
MAJOR_VERSION=""
PUSH=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --commit)
            COMMIT="$2"
            shift 2
            ;;
        --major)
            MAJOR_VERSION="$2"
            shift 2
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            head -30 "$0" | tail -n +2 | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Get the full commit SHA
COMMIT_SHA=$(git rev-parse "$COMMIT")
COMMIT_SHORT=$(git rev-parse --short "$COMMIT")

# Calculate version from commit count
# Count all commits reachable from the target commit
COMMIT_COUNT=$(git rev-list --count "$COMMIT_SHA")

# Version segments (matching woot_ver.rb logic)
FIRST_SEGMENT=$(( (COMMIT_COUNT / 1000) % 1000 ))
SECOND_SEGMENT=$(( COMMIT_COUNT % 1000 ))

# Build version string
if [[ -n "$MAJOR_VERSION" ]]; then
    VERSION="v${MAJOR_VERSION}.${FIRST_SEGMENT}.${SECOND_SEGMENT}"
else
    VERSION="v${FIRST_SEGMENT}.${SECOND_SEGMENT}"
fi

# Get current date in UTC
DATE=$(date -u +"%Y-%m-%d")

# Generate friendly name from commit SHA
FRIENDLY_NAME=$(generate_friendly_name "$COMMIT_SHA")

# Build the full tag name
TAG_NAME="${DATE}-${VERSION}-${FRIENDLY_NAME}"

# Output for logging
if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would create tag: $TAG_NAME"
    echo "[dry-run] Commit: $COMMIT_SHA"
    echo "[dry-run] Commit count: $COMMIT_COUNT"
    echo "[dry-run] Version: $VERSION"
    echo "[dry-run] Friendly name: $FRIENDLY_NAME"
    if [[ "$PUSH" == "true" ]]; then
        echo "[dry-run] Would push to origin"
    fi
else
    # Create the tag
    git tag -a "$TAG_NAME" "$COMMIT_SHA" -m "Release $TAG_NAME"
    
    echo "Created tag: $TAG_NAME" >&2
    
    if [[ "$PUSH" == "true" ]]; then
        git push origin "$TAG_NAME"
        echo "Pushed tag to origin" >&2
    fi
fi

# Output the tag name (for capture by caller)
echo "$TAG_NAME"

# Set GitHub Actions output if available
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "tag_name=$TAG_NAME" >> "$GITHUB_OUTPUT"
    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
    echo "friendly_name=$FRIENDLY_NAME" >> "$GITHUB_OUTPUT"
    echo "commit_sha=$COMMIT_SHA" >> "$GITHUB_OUTPUT"
    echo "commit_short=$COMMIT_SHORT" >> "$GITHUB_OUTPUT"
fi


















