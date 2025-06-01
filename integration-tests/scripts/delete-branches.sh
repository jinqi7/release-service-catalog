#!/usr/bin/env bash
#
# Summary:
#   Deletes all branches in a specified GitHub repository except for the 'main'
#   branch and any branches containing '-base' in their names.
#
# Parameters:
#   $1: repo_name - The name of the GitHub repository (e.g., "owner/repo").
#
# Environment Variables:
#   GITHUB_TOKEN  - A GitHub personal access token with permissions to list and
#                   delete branches in the repository. Required.
#
# Dependencies:
#   curl, jq, grep

set -eo pipefail

if [ -z "$GITHUB_TOKEN" ] ; then
  echo "🔴 error: missing env var GITHUB_TOKEN"
  exit 1
fi

repo_name=$1
if [ -z "$repo_name" ] ; then
  echo "🔴 error: missing parameter repo_name"
  exit 1
fi

branches_json=$(curl -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/$repo_name/branches 2> /dev/null)

branches=$(jq -r '.[].name' <<< "${branches_json}" | grep -v '\-base' | grep -v main)

for branch in $branches;
do
  echo $branch
  curl -L \
    -X DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/$repo_name/git/refs/heads/$branch
done
