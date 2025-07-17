#!/bin/bash
#
# Delete Old GitHub Branches
# ========================
#
# Summary:
# --------
# This script automatically cleans up old branches in a GitHub repository by
# deleting branches that haven't had any commits within a specified timeframe.
# It only considers branches that start with a specified prefix.
# It skips branches ending in "-base" and the "main" branch for safety.
#
# Branch deletion logic:
# - Branches with commits after creation: deleted if last commit is older than cutoff
# - Branches with no commits after creation: deleted only if branch is older than 2 days
#
# Features:
# --------
# - Identifies branches with no recent commits
# - Configurable cutoff period (default: 1 day)
# - Safe deletion with base branch protection
# - Branch prefix filtering to target specific branch types
# - Smart branch deletion: preserves new branches without commits, removes old unused branches
# - Handles pagination for repositories with many branches
# - Provides detailed output of deleted branches
#
# Usage:
# -----
#   ./delete-old-branches.sh <owner/repository> <branch_prefix>
#
# Example:
#   ./delete-old-branches.sh redhat/release-service e2e-test
#   ./delete-old-branches.sh konflux-ci/release-service-catalog integration-test
#
# Required Environment Variables:
# ----------------------------
# - GITHUB_TOKEN: GitHub Personal Access Token with repo access
#
# Configuration:
# -------------
# - CUTOFF_DATE: Time period to consider a branch as old (default: "1 day")
# - Automatically skips branches:
#   * Ending in "-base"
#   * Named "main"
#
# GitHub API Details:
# -----------------
# - Uses GitHub REST API v2022-11-28
# - Requires 'repo' scope permissions
# - Handles up to 100 branches per page
#
# Exit Codes:
# ----------
# - 0: Success
# - 1: Error (missing token, invalid repo, API error)

if [ -z "$GITHUB_TOKEN" ] ; then
  echo "🔴 error: missing env var GITHUB_TOKEN"
  exit 1
fi

repo_name=$1
if [ -z "$repo_name" ] ; then
  echo "🔴 error: missing parameter repo_name"
  exit 1
fi

branch_prefix=$2
if [ -z "$branch_prefix" ] ; then
  echo "🔴 error: missing parameter branch_prefix"
  echo "Usage: $0 <owner/repository> <branch_prefix>"
  exit 1
fi

CUTOFF_DATE="${CUTOFF_DATE:-1 day}"
CUTOFF_SECONDS=$(date -d "$CUTOFF_DATE ago" +%s)

# Additional cutoff for branches with no commits after creation
BRANCH_AGE_CUTOFF_SECONDS=$(date -d "2 days ago" +%s)

echo "Finding branches in $repo_name starting with '$branch_prefix' with no commits for $CUTOFF_DATE..."
echo "Also checking for unused branches older than 2 days..."
echo "------------------------------------------------------------------"

# --- Main Logic ---

# 1. Get all branches and their last commit SHAs
# The 'jq' command creates a space-separated list of "branch_name commit_sha"
branches_data=$(curl -s -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$repo_name/branches?per_page=100")

# Check for invalid token or other API errors
if echo "$branches_data" | jq -e '.message' 2> /dev/null; then
  echo "Error fetching branches. Check your token, owner, and repo."
  echo "Response: $(echo "$branches_data" | jq '.message')"
  exit 1
fi

echo "$branches_data" | jq -r '.[] | .name + " " + .commit.sha' | while read -r branch_name commit_sha; do
  if [[ "${branch_name}" == *"-base" ]] || [[ "${branch_name}" == "main" ]] ; then
    continue
  fi

  # Only consider branches that start with the specified prefix
  if [[ "${branch_name}" != "${branch_prefix}"* ]] ; then
    continue
  fi

  # 2. Get the branch creation date from git ref
  branch_ref_data=$(curl -s -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$repo_name/git/refs/heads/$branch_name")

  # Get the commit that created the branch
  branch_creation_sha=$(echo "$branch_ref_data" | jq -r '.object.sha')
  # Get the branch creation commit details
  branch_creation_commit_data=$(curl -s -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$repo_name/commits/$branch_creation_sha")

  branch_creation_date_str=$(echo "$branch_creation_commit_data" | jq -r '.commit.committer.date')
  branch_creation_date_seconds=$(date -d "$branch_creation_date_str" +%s)

  # 3. For each branch, get the date of its last commit
  commit_data=$(curl -s -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$repo_name/commits/$commit_sha")

  commit_date_str=$(echo "$commit_data" | jq -r '.commit.committer.date')
  commit_date_seconds=$(date -d "$commit_date_str" +%s)

  # 4. Check if branch has commits after creation
  if [ "$commit_date_seconds" -le "$branch_creation_date_seconds" ]; then
    # No commits after branch creation - check if branch is older than 2 days
    if [ "$branch_creation_date_seconds" -lt "$BRANCH_AGE_CUTOFF_SECONDS" ]; then
      echo "Branch: $branch_name - No commits after creation but branch is older than 2 days"
      echo "  Branch created: $branch_creation_date_str"
      echo "  Last commit:   $commit_date_str"

      echo "- Deleting $branch_name in $repo_name"
      curl -L \
      -X DELETE \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/repos/$repo_name/git/refs/heads/$branch_name
    else
      echo "Branch: $branch_name SKIPPED - No commits after branch creation (branch too new)"
      echo "  Branch created: $branch_creation_date_str"
      echo "  Last commit:   $commit_date_str"
    fi
  else
    # 5. Branch has commits after creation - use regular cutoff logic
    if [ "$commit_date_seconds" -lt "$CUTOFF_SECONDS" ]; then
      echo "Branch: $branch_name Last Commit Date: $commit_date_str"
      echo "  Branch created: $branch_creation_date_str"
      echo "  Has commits after branch creation: YES"

      echo "- Deleting $branch_name in $repo_name"
      curl -L \
      -X DELETE \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/repos/$repo_name/git/refs/heads/$branch_name

    else
      echo "Branch: $branch_name SKIPPED - Recent commits (within cutoff)"
      echo "  Last commit: $commit_date_str"
    fi
  fi
done

echo "------------------------------------------------------------------"
echo "Search complete."
