#!/bin/bash

# Script to find open PRs where a file was modified and check if they contain a specific SHA string
# Usage: ./find-pr-with-sha.sh <org/repo> <sha-string> <file-path>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print usage
usage() {
    echo "Usage: $0 <org/repo> <search-string> <file-path>"
    echo ""
    echo "Find open PRs where a file was modified and check if the file contains a specific string"
    echo ""
    echo "Examples:"
    echo "  $0 microsoft/vscode 'console.log' src/main.ts"
    echo "  $0 kubernetes/kubernetes 'TODO:' pkg/controller/deployment.go"
    echo ""
    echo "Environment variables:"
    echo "  GITHUB_TOKEN - GitHub token for authentication (recommended to avoid rate limits)"
    echo "  MAX_PRS      - Maximum number of PRs to check (default: 20)"
    exit 1
}

# Function to log messages
log_info() {
    echo -e "$1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [ -n "${DEBUG:-}" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Function to make GitHub API requests
github_api_request() {
    local url="$1"
    local curl_cmd="curl -s"
    
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_cmd="$curl_cmd -H 'Authorization: token $GITHUB_TOKEN'"
    fi
    
    # Add API version header
    curl_cmd="$curl_cmd -H 'Accept: application/vnd.github.v3+json'"
    
    # Make request and capture response with status
    local response
    response=$(eval "$curl_cmd -w '%{http_code}' '$url'")
    
    # Extract HTTP status code (last 3 characters)
    local http_status="${response: -3}"
    # Extract response body (everything except last 3 characters)
    local response_body="${response%???}"
    
    if [ "$http_status" -eq 200 ]; then
        echo "$response_body"
        return 0
    elif [ "$http_status" -eq 422 ]; then
        # Unprocessable Entity - often means invalid search query but not necessarily an error
        log_warn "Search query may be invalid (HTTP 422)"
        echo "$response_body"
        return 0
    else
        log_error "API request failed with status $http_status"
        log_error "URL: $url"
        if [ "$http_status" -eq 404 ]; then
            log_error "Repository not found or not accessible"
        elif [ "$http_status" -eq 403 ]; then
            log_error "Access forbidden - check GitHub token permissions or rate limits"
        fi
        log_error "Response: $response_body"
        return 1
    fi
}

# Function to extract PR numbers from search results
extract_pr_numbers() {
    local json_response="$1"
    
    # First check if we have any items in the search results
    local total_count
    total_count=$(echo "$json_response" | grep -o '"total_count":[[:space:]]*[0-9]*' | head -1 | sed 's/.*:[[:space:]]*//')
    
    if [ -n "${DEBUG:-}" ]; then
        echo "Total count from GitHub: ${total_count:-unknown}" >&2
    fi
    
    if [ -n "$total_count" ] && [ "$total_count" -eq 0 ]; then
        if [ -n "${DEBUG:-}" ]; then
            echo "GitHub returned total_count=0, no results found" >&2
        fi
        return 1  # No results found
    fi
    
    # Extract PR numbers from the items array
    # Since we filter by type:pr in the search query, all results should be PRs
    # Use a simpler approach to extract just the numeric PR numbers
    local pr_numbers
    pr_numbers=$(echo "$json_response" | grep -o '"number":[[:space:]]*[0-9][0-9]*' | grep -o '[0-9][0-9]*' | sort -nu)
    
    if [ -n "${DEBUG:-}" ]; then
        echo "Extracted PR numbers: '$pr_numbers'" >&2
    fi
    
    if [ -z "$pr_numbers" ]; then
        if [ -n "${DEBUG:-}" ]; then
            echo "No PR numbers found in response" >&2
        fi
        return 1
    fi
    
    echo "$pr_numbers"
    return 0
}

# Function to check if a file was modified in a PR
check_file_modified_in_pr() {
    local repo_path="$1"
    local pr_number="$2"
    local target_file="$3"
    
    if [ -n "${DEBUG:-}" ]; then
        echo "Checking if file '$target_file' was modified in PR #$pr_number" >&2
    fi
    
    # Get PR files
    local files_url="https://api.github.com/repos/$repo_path/pulls/$pr_number/files"
    local files_response
    
    if ! files_response=$(github_api_request "$files_url"); then
        return 1
    fi
    
    # Extract filenames from the response
    local modified_files
    modified_files=$(echo "$files_response" | grep -o '"filename":[[:space:]]*"[^"]*"' | sed 's/.*"filename":[[:space:]]*"//' | sed 's/"$//')
    
    # Check if target file is in the list of modified files
    if echo "$modified_files" | grep -q "^$target_file$"; then
        if [ -n "${DEBUG:-}" ]; then
            echo "File '$target_file' was modified in PR #$pr_number" >&2
        fi
        return 0
    else
        if [ -n "${DEBUG:-}" ]; then
            echo "File '$target_file' was not modified in PR #$pr_number" >&2
        fi
        return 1
    fi
}

# Function to check if string exists in file content of a PR
check_string_in_file() {
    local repo_path="$1"
    local pr_number="$2"
    local target_file="$3"
    local search_string="$4"
    
    if [ -n "${DEBUG:-}" ]; then
        echo "Checking if string '$search_string' exists in file '$target_file' in PR #$pr_number" >&2
    fi
    
    # First get PR details to get the head SHA
    local pr_url="https://api.github.com/repos/$repo_path/pulls/$pr_number"
    local pr_response
    
    if ! pr_response=$(github_api_request "$pr_url"); then
        return 1
    fi
    
    # Extract head SHA from PR response
    local head_sha
    head_sha=$(echo "$pr_response" | grep -o '"sha":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"sha":[[:space:]]*"//' | sed 's/"$//')
    
    if [ -z "$head_sha" ]; then
        if [ -n "${DEBUG:-}" ]; then
            echo "Could not extract head SHA from PR #$pr_number" >&2
        fi
        return 1
    fi
    
    if [ -n "${DEBUG:-}" ]; then
        echo "PR #$pr_number head SHA: $head_sha" >&2
    fi
    
    # Get file content at the PR's head commit
    local file_url="https://api.github.com/repos/$repo_path/contents/$target_file?ref=$head_sha"
    local file_response
    
    if ! file_response=$(github_api_request "$file_url"); then
        if [ -n "${DEBUG:-}" ]; then
            echo "Could not get file content for '$target_file' at commit $head_sha in PR #$pr_number" >&2
        fi
        return 1
    fi
    
    # Extract and decode the base64 content
    # GitHub API can split base64 content across multiple lines, so we need a more robust approach
    local base64_content
    base64_content=$(echo "$file_response" | sed -n '/"content":/,/"encoding":/p' | grep -v '"encoding":' | sed 's/.*"content":[[:space:]]*"//' | sed 's/"[[:space:]]*$//' | sed 's/\\n//g' | tr -d '\n' | tr -d ' ')
    
    if [ -z "$base64_content" ]; then
        if [ -n "${DEBUG:-}" ]; then
            echo "Could not extract base64 content from file response" >&2
            echo "File response preview: $(echo "$file_response" | head -c 300)..." >&2
        fi
        return 1
    fi
    
    if [ -n "${DEBUG:-}" ]; then
        echo "Extracted base64 content length: ${#base64_content}" >&2
        echo "Base64 content preview: ${base64_content:0:50}..." >&2
    fi
    
    # Decode base64 and search for the string
    local file_content
    file_content=$(echo "$base64_content" | base64 -d 2>/dev/null)
    local decode_result=$?
    
    # Check if we actually got content, regardless of exit code
    # Some base64 implementations return non-zero even on successful decode
    if [ -z "$file_content" ]; then
        if [ -n "${DEBUG:-}" ]; then
            echo "Base64 decode returned empty content (exit code: $decode_result)" >&2
            echo "Trying alternative base64 decoding approaches..." >&2
            
            # Try with different base64 implementations
            if command -v openssl >/dev/null 2>&1; then
                file_content=$(echo "$base64_content" | openssl base64 -d 2>/dev/null)
                if [ -n "$file_content" ]; then
                    echo "Successfully decoded using openssl base64" >&2
                fi
            fi
        fi
        
        if [ -z "$file_content" ]; then
            if [ -n "${DEBUG:-}" ]; then
                echo "All base64 decoding attempts returned empty content" >&2
            fi
            return 1
        fi
    else
        if [ -n "${DEBUG:-}" ]; then
            echo "Successfully decoded base64 content (length: ${#file_content}, exit code: $decode_result)" >&2
        fi
    fi
    
    # Check if the search string exists in the file content
    if echo "$file_content" | grep -q -F "$search_string"; then
        if [ -n "${DEBUG:-}" ]; then
            echo "String '$search_string' found in file '$target_file' in PR #$pr_number" >&2
        fi
        return 0
    else
        if [ -n "${DEBUG:-}" ]; then
            echo "String '$search_string' not found in file '$target_file' in PR #$pr_number" >&2
        fi
        return 1
    fi
}

# Function to get PR details
get_pr_details() {
    local repo_path="$1"
    local pr_number="$2"
    
    local pr_url="https://api.github.com/repos/$repo_path/pulls/$pr_number"
    local pr_response
    
    if ! pr_response=$(github_api_request "$pr_url"); then
        return 1
    fi
    
    local title=$(echo "$pr_response" | grep -o '"title":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"title":[[:space:]]*"//' | sed 's/"$//')
    local state=$(echo "$pr_response" | grep -o '"state":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"state":[[:space:]]*"//' | sed 's/"$//')
    local author=$(echo "$pr_response" | grep -o '"login":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"login":[[:space:]]*"//' | sed 's/"$//')
    local created_at=$(echo "$pr_response" | grep -o '"created_at":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"created_at":[[:space:]]*"//' | sed 's/"$//')
    local merged_at=$(echo "$pr_response" | grep -o '"merged_at":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"merged_at":[[:space:]]*"//' | sed 's/"$//')
    
    echo "  Title: $title"
    echo "  State: $state"
    echo "  Author: $author"
    echo "  Created: $created_at"
    if [ "$merged_at" != "null" ] && [ -n "$merged_at" ]; then
        echo "  Merged: $merged_at"
    fi
    echo "  URL: https://github.com/$repo_path/pull/$pr_number"
}

# Check if required arguments are provided
if [ $# -ne 3 ]; then
    log_error "Invalid number of arguments"
    usage
fi

REPO_PATH="$1"
SEARCH_STRING="$2"
FILE_PATH="$3"
MAX_PRS="${MAX_PRS:-20}"

# Validate repository path format
if [[ ! "$REPO_PATH" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    log_error "Invalid repository path format. Expected format: org/repo"
    exit 1
fi

# Validate search string (should not be empty)
if [ -z "$SEARCH_STRING" ]; then
    log_error "Search string cannot be empty"
    exit 1
fi

# Check if GitHub token is available
if [ -z "${GITHUB_TOKEN:-}" ]; then
    log_warn "GITHUB_TOKEN not set. API requests may be rate limited"
fi

log_info "Searching for open PRs in '$REPO_PATH' that modified '$FILE_PATH'"
log_info "Looking for string: $SEARCH_STRING"
log_info "Maximum PRs to check: $MAX_PRS"

# URL encode the file path
ENCODED_FILE_PATH=$(echo "$FILE_PATH" | sed 's/ /%20/g' | sed 's/\//%2F/g')

# Search for open PRs in the repository
# Using GitHub's search API to find all open PRs, then filter by file modifications
SEARCH_URL="https://api.github.com/search/issues?q=repo:$REPO_PATH+type:pr+state:open&sort=updated&order=desc&per_page=$MAX_PRS"

# Debug: Show search URL if in debug mode
if [ -n "${DEBUG:-}" ]; then
    log_debug "Search URL: $SEARCH_URL"
    log_debug "Making search request to GitHub API..."
fi

# Make the search request
SEARCH_RESPONSE=$(github_api_request "$SEARCH_URL")
if [ $? -ne 0 ]; then
    log_error "Failed to search for PRs"
    exit 1
fi

# Debug: Show first part of response if in debug mode
if [ -n "${DEBUG:-}" ]; then
    log_debug "Search response received, parsing results..."
    log_debug "Search response preview: $(echo "$SEARCH_RESPONSE" | head -c 200)..."
    log_debug "Extracting PR numbers from search response..."
fi

# Check total_count first for early exit
TOTAL_COUNT=$(echo "$SEARCH_RESPONSE" | grep -o '"total_count":[[:space:]]*[0-9]*' | head -1 | sed 's/.*:[[:space:]]*//')

if [ -n "${DEBUG:-}" ]; then
    log_debug "Total count from response: ${TOTAL_COUNT:-not found}"
fi

if [ -n "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -eq 0 ]; then
    if [ -n "${DEBUG:-}" ]; then
        log_debug "Total count is 0, no results found"
    fi
    PR_NUMBERS=""
    EXTRACT_EXIT_CODE=1
else
    PR_NUMBERS=$(extract_pr_numbers "$SEARCH_RESPONSE")
    EXTRACT_EXIT_CODE=$?
fi

if [ -n "${DEBUG:-}" ]; then
    log_debug "Extract exit code: $EXTRACT_EXIT_CODE"
    log_debug "PR_NUMBERS content: '$PR_NUMBERS'"
    log_debug "PR_NUMBERS length: ${#PR_NUMBERS}"
fi

# Check if extraction failed (no results) or PR_NUMBERS is empty
if [ $EXTRACT_EXIT_CODE -ne 0 ] || [ -z "$PR_NUMBERS" ] || [ -z "$(echo "$PR_NUMBERS" | tr -d '[:space:]')" ]; then
    log_warn "No open PRs found in repository '$REPO_PATH'"
    
    # Show some debug info about what we searched for
    log_info "Search was performed for:"
    log_info "  Repository: $REPO_PATH"
    
    # Parse total_count from response for additional info
    if [ -z "$TOTAL_COUNT" ]; then
        TOTAL_COUNT=$(echo "$SEARCH_RESPONSE" | grep -o '"total_count":[[:space:]]*[0-9]*' | sed 's/.*:[[:space:]]*//')
    fi
    if [ -n "$TOTAL_COUNT" ]; then
        log_info "  Total open PRs in repository: $TOTAL_COUNT"
    elif [ -n "${DEBUG:-}" ]; then
        log_debug "Could not find total_count in response"
    fi
    
    exit 0
fi

if [ -n "${DEBUG:-}" ]; then
    log_debug "Found PR numbers, continuing with processing..."
fi

log_info "Found $(echo "$PR_NUMBERS" | wc -l) open PRs in repository, filtering by file modifications..."
echo ""

# First, filter PRs by file modifications, then check for SHA
RELEVANT_PRS=()
FOUND_PRS=()
CHECKED_COUNT=0

for pr_number in $PR_NUMBERS; do
    CHECKED_COUNT=$((CHECKED_COUNT + 1))
    
    echo "Checking PR #$pr_number ($CHECKED_COUNT/$(echo "$PR_NUMBERS" | wc -l)) for file modifications..."
    
    # First check if this PR modified the target file
    if check_file_modified_in_pr "$REPO_PATH" "$pr_number" "$FILE_PATH"; then
        echo "  ✓ File '$FILE_PATH' was modified in PR #$pr_number"
        RELEVANT_PRS+=("$pr_number")
        
        # Now check if the file contains the search string
        if check_string_in_file "$REPO_PATH" "$pr_number" "$FILE_PATH" "$SEARCH_STRING"; then
            log_info "  ✅ Found string '$SEARCH_STRING' in file '$FILE_PATH' in PR #$pr_number"
            FOUND_PRS+=("$pr_number")
            
            # Get and display PR details
            get_pr_details "$REPO_PATH" "$pr_number"
            echo ""
        else
            echo "  ❌ String not found in file '$FILE_PATH' in PR #$pr_number"
        fi
    else
        echo "  ⏭️  File '$FILE_PATH' not modified in PR #$pr_number"
    fi
    
    # Add a small delay to be nice to the API
    sleep 0.5
done

# Continue to summary
echo "Summary:"
echo "========="
echo "Open PRs checked: $CHECKED_COUNT"
echo "PRs that modified '$FILE_PATH': ${#RELEVANT_PRS[@]}"
echo "PRs containing string: ${#FOUND_PRS[@]}"

if [ ${#RELEVANT_PRS[@]} -eq 0 ]; then
    log_warn "No open PRs found that modified the file '$FILE_PATH'"
    exit 0
elif [ ${#FOUND_PRS[@]} -gt 0 ]; then
    echo ""
    log_info "PRs containing string '$SEARCH_STRING':"
    for pr in "${FOUND_PRS[@]}"; do
        echo "  - PR #$pr: https://github.com/$REPO_PATH/pull/$pr"
    done
    exit 0
else
    log_warn "String '$SEARCH_STRING' was not found in file '$FILE_PATH' in any open PR"
    exit 1
fi 
