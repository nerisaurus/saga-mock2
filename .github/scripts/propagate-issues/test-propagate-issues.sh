#!/bin/bash
#
# test-propagate-issues.sh - Tests for the issue propagation scripts
#
# Usage:
#   ./test-propagate-issues.sh
#
# Runs a series of test cases to verify the parsing and insertion logic
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_SCRIPT="$SCRIPT_DIR/parse-issues.sh"
INSERT_SCRIPT="$SCRIPT_DIR/insert-issues.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to run a test
run_test() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  ${YELLOW}Expected:${NC} $expected"
        echo -e "  ${YELLOW}Actual:${NC} $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Helper function to check if output contains expected substring
run_test_contains() {
    local test_name="$1"
    local expected_substring="$2"
    local actual="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    # Use grep with here-string to handle multi-line content properly
    if grep -qF -- "$expected_substring" <<< "$actual"; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  ${YELLOW}Expected to contain:${NC} $expected_substring"
        echo -e "  ${YELLOW}Actual:${NC} $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "========================================="
echo "Testing parse-issues.sh"
echo "========================================="

# Test 1: Simple bullet point with Resolves
TEST_INPUT="- Resolves #123"
EXPECTED="#123"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Simple bullet with Resolves" "$EXPECTED" "$ACTUAL"

# Test 2: Multiple issues
TEST_INPUT="- Resolves #123
- Resolves #456"
EXPECTED="#123
#456"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Multiple issues" "$EXPECTED" "$ACTUAL"

# Test 3: Cross-repo reference
TEST_INPUT="- Resolves myorg/myrepo#789"
EXPECTED="myorg/myrepo#789"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Cross-repo reference" "$EXPECTED" "$ACTUAL"

# Test 4: Mixed same-repo and cross-repo
TEST_INPUT="- Resolves #123
- Resolves other-org/other-repo#456"
EXPECTED="#123
other-org/other-repo#456"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Mixed same-repo and cross-repo" "$EXPECTED" "$ACTUAL"

# Test 5: Issue with extra text on line
TEST_INPUT="- Resolves #123 (see also #456)"
EXPECTED="#123
#456"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Issue with extra text" "$EXPECTED" "$ACTUAL"

# Test 6: Asterisk bullet point
TEST_INPUT="* Resolves #123"
EXPECTED="#123"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Asterisk bullet point" "$EXPECTED" "$ACTUAL"

# Test 7: Case insensitive (lowercase r)
TEST_INPUT="- resolves #123"
EXPECTED="#123"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Lowercase 'resolves'" "$EXPECTED" "$ACTUAL"

# Test 8: Inside code block should be ignored
TEST_INPUT="\`\`\`
- Resolves #123
\`\`\`"
EXPECTED=""
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Inside code block ignored" "$EXPECTED" "$ACTUAL"

# Test 9: Code block with content before/after
TEST_INPUT="- Resolves #111
\`\`\`
- Resolves #222
\`\`\`
- Resolves #333"
EXPECTED="#111
#333"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Code block with content around it" "$EXPECTED" "$ACTUAL"

# Test 10: No bullet point - should not match
TEST_INPUT="Resolves #123"
EXPECTED=""
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "No bullet point - should not match" "$EXPECTED" "$ACTUAL"

# Test 11: Duplicate issues should be deduplicated
TEST_INPUT="- Resolves #123
- Resolves #123"
EXPECTED="#123"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Duplicate issues deduplicated" "$EXPECTED" "$ACTUAL"

# Test 12: Indented bullet point
TEST_INPUT="  - Resolves #123"
EXPECTED="#123"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Indented bullet point" "$EXPECTED" "$ACTUAL"

# Test 13: Complex repo names with dots and hyphens
TEST_INPUT="- Resolves my-org.name/my-repo.name#123"
EXPECTED="my-org.name/my-repo.name#123"
ACTUAL=$("$PARSE_SCRIPT" "$TEST_INPUT")
run_test "Complex repo names with dots and hyphens" "$EXPECTED" "$ACTUAL"

echo ""
echo "========================================="
echo "Testing insert-issues.sh"
echo "========================================="

# Test 14: Insert into body with Issues Resolved section
TEST_BODY="### :memo: Notes
Some notes here

### :tada: Issues Resolved
- Resolves #100

### :test_tube: Test Plan
- Test 1"

RESULT=$("$INSERT_SCRIPT" --source-pr 456 --issues "#123" --target-body "$TEST_BODY")
SUCCESS=$(echo "$RESULT" | jq -r '.success')
run_test "Insert with Issues Resolved section - success" "true" "$SUCCESS"

NEW_BODY=$(echo "$RESULT" | jq -r '.body')
run_test_contains "Insert after Issues Resolved section" "<!-- PROPAGATED_ISSUES:START -->" "$NEW_BODY"
run_test_contains "Contains new subsection header" "#### Additional Issues Resolved (from PR #456)" "$NEW_BODY"
run_test_contains "Contains the issue reference" "- Resolves #123" "$NEW_BODY"

# Test 15: Deduplication - issue already exists
TEST_BODY="### Issues Resolved
- Resolves #123"

RESULT=$("$INSERT_SCRIPT" --source-pr 456 --issues "#123" --target-body "$TEST_BODY")
ISSUES_ADDED=$(echo "$RESULT" | jq -r '.issues_added | length')
run_test "Deduplication - existing issue not added" "0" "$ISSUES_ADDED"

# Test 16: Partial deduplication - one new, one existing
TEST_BODY="### Issues Resolved
- Resolves #123"

RESULT=$("$INSERT_SCRIPT" --source-pr 456 --issues "#123
#456" --target-body "$TEST_BODY")
ISSUES_ADDED=$(echo "$RESULT" | jq -r '.issues_added | length')
run_test "Partial deduplication - only new issue added" "1" "$ISSUES_ADDED"
ADDED_ISSUE=$(echo "$RESULT" | jq -r '.issues_added[0]')
run_test "Correct issue was added" "#456" "$ADDED_ISSUE"

# Test 17: Append to existing propagated section
TEST_BODY="### Issues Resolved
- Resolves #100

<!-- PROPAGATED_ISSUES:START -->
#### Additional Issues Resolved (from PR #200)
- Resolves #201
<!-- PROPAGATED_ISSUES:END -->

### Test Plan"

RESULT=$("$INSERT_SCRIPT" --source-pr 300 --issues "#301" --target-body "$TEST_BODY")
SUCCESS=$(echo "$RESULT" | jq -r '.success')
run_test "Append to existing propagated section - success" "true" "$SUCCESS"

NEW_BODY=$(echo "$RESULT" | jq -r '.body')
run_test_contains "Preserves existing propagated section" "from PR #200" "$NEW_BODY"
run_test_contains "Adds new subsection" "from PR #300" "$NEW_BODY"

# Test 18: Idempotency - same source PR already propagated
TEST_BODY="### Issues Resolved
- Resolves #100

<!-- PROPAGATED_ISSUES:START -->
#### Additional Issues Resolved (from PR #456)
- Resolves #123
<!-- PROPAGATED_ISSUES:END -->"

RESULT=$("$INSERT_SCRIPT" --source-pr 456 --issues "#999" --target-body "$TEST_BODY")
ISSUES_ADDED=$(echo "$RESULT" | jq -r '.issues_added | length')
run_test "Idempotency - same source PR not duplicated" "0" "$ISSUES_ADDED"

# Test 19: Body with no structure - should fail gracefully
TEST_BODY="Just some random text without any headers or structure."

RESULT=$("$INSERT_SCRIPT" --source-pr 456 --issues "#123" --target-body "$TEST_BODY")
SUCCESS=$(echo "$RESULT" | jq -r '.success')
run_test "No structure - fails gracefully" "false" "$SUCCESS"

REASON=$(echo "$RESULT" | jq -r '.reason')
run_test_contains "Failure reason explains the issue" "no recognizable structure" "$REASON"

# Test 20: Empty body with issues - should fail gracefully
RESULT=$("$INSERT_SCRIPT" --source-pr 456 --issues "#123" --target-body "")
SUCCESS=$(echo "$RESULT" | jq -r '.success')
run_test "Empty body - fails gracefully" "false" "$SUCCESS"

# Test 21: Cross-repo issue insertion
TEST_BODY="### Issues Resolved
- Resolves #100"

RESULT=$("$INSERT_SCRIPT" --source-pr 456 --issues "other-org/other-repo#789" --target-body "$TEST_BODY")
SUCCESS=$(echo "$RESULT" | jq -r '.success')
run_test "Cross-repo issue insertion - success" "true" "$SUCCESS"

NEW_BODY=$(echo "$RESULT" | jq -r '.body')
run_test_contains "Cross-repo reference in body" "- Resolves other-org/other-repo#789" "$NEW_BODY"

# Test 22: Body with only first section header (no second header to insert before)
TEST_BODY="### Notes
This PR does some stuff.

Some more text about the changes."

RESULT=$("$INSERT_SCRIPT" --source-pr 456 --issues "#123" --target-body "$TEST_BODY")
SUCCESS=$(echo "$RESULT" | jq -r '.success')
run_test "Single section body - inserts at end" "true" "$SUCCESS"

NEW_BODY=$(echo "$RESULT" | jq -r '.body')
run_test_contains "Section inserted at end" "<!-- PROPAGATED_ISSUES:START -->" "$NEW_BODY"

echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="
echo -e "Total: $TESTS_RUN | ${GREEN}Passed: $TESTS_PASSED${NC} | ${RED}Failed: $TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
