#!/usr/bin/env bash
#
# Summary:
#   This script executes an end-to-end test for a software release process.
#   It simulates a complete workflow including:
#     - Setting up the environment and parsing command-line options.
#     - Decrypting secrets using Ansible Vault.
#     - Interacting with GitHub to create branches and merge pull requests.
#     - Creating and managing Kubernetes resources (namespaces, custom resources)
#       using kustomize and envsubst.
#     - Monitoring the initialization of Konflux Components.
#     - Waiting for and monitoring Tekton PipelineRuns related to component builds.
#     - Waiting for a Release custom resource to complete its lifecycle.
#     - Verifying the contents of the Release, including checking for
#       Jira issues, advisory details (fetched via a helper script), and CVE data.
#     - Performing cleanup of created resources upon script completion or error,
#       unless explicitly skipped.
#
# Command-line Options:
#   -sc, --skip-cleanup   : If set, the script will not perform cleanup operations
#                           (GitHub branches, Kubernetes resources) on exit.
#   -nocve, --no-cve       : If set, the script will not simulate the addition of a CVE. This
#                           affects the commit message during PR merge and the
#                           expected CVE data during release verification.
#                           The default mode is to include CVE data.
#
# Environment Variables (Expected, typically sourced from 'test.env'):
#   Required:
#     GITHUB_TOKEN                  - GitHub Personal Access Token for API interactions.
#     VAULT_PASSWORD_FILE           - Path to the Ansible Vault password file for secret decryption.
#     RELEASE_CATALOG_GIT_URL       - Git URL for the release service catalog (used by helper scripts).
#     RELEASE_CATALOG_GIT_REVISION  - Git revision (branch/tag) for the release service catalog.
#     component_branch              - The name of the component branch to be created.
#     component_base_branch         - The base branch from which the component branch is created.
#     component_repo_name           - The GitHub repository name (e.g., "owner/repo").
#     managed_namespace             - Kubernetes namespace for managed resources.
#     tenant_namespace              - Kubernetes namespace for tenant-specific resources and Release CR.
#     application_name              - The name of the AppStudio Application.
#     component_name                - The name of the AppStudio Component.
#     managed_sa_name               - ServiceAccount name in the managed namespace (used by get-advisory-content.sh).
#   Optional:
#     KUBECONFIG                    - Path to the Kubernetes configuration file.
#
# Dependencies:
#   External commands: ansible-vault, kubectl, kustomize, envsubst, curl, jq,
#                      oc, tkn, yq, mktemp.
#   Helper scripts: Located in the SCRIPT_DIR/../scripts/ directory, including:
#                     - delete-single-branch.sh
#                     - create-branch-from-base.sh
#                     - add-retry-comment-to-pr.sh
#                     - wait-for-release.sh
#                     - get-advisory-content.sh
#
# Exit Behavior:
#   - Exits 0 on successful completion of all steps and verifications.
#   - Exits with a non-zero status code on error.
#   - A trap is set to call the 'cleanup_resources' function on EXIT, regardless
#     of success or failure (unless --skip-cleanup is used).

set -eo pipefail

# --- Configuration & Global Variables ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
LIB_DIR="${SCRIPT_DIR}/../lib"

# Source environment variables (ensure this file exists and is correctly populated)
if [ -f "${SCRIPT_DIR}/test.env" ]; then
    . "${SCRIPT_DIR}/test.env"
else
    echo "error: test.env not found in ${SCRIPT_DIR}"
    exit 1
fi

# Source the function library
if [ -f "${LIB_DIR}/test-functions.sh" ]; then
    . "${LIB_DIR}/test-functions.sh"
else
    echo "error: Function library test-functions.sh not found in ${LIB_DIR}"
    exit 1
fi

# --- Global Script Variables (Defaults) ---
CLEANUP="true"
NO_CVE="false" # Default to false

# Variables that will be set by functions and used globally:
# component_branch, component_base_branch, component_repo_name (from test.env or similar)
# managed_namespace, tenant_namespace, application_name, component_name (from test.env or similar)
# managed_sa_name (from test.env or similar)
# GITHUB_TOKEN, VAULT_PASSWORD_FILE (from test.env)
# SCRIPT_DIR (defined above)
# LIB_DIR (defined above)
# tmpDir (set by create_kubernetes_resources)
# component_pr, pr_number (set by wait_for_component_initialization)
# SHA (set by merge_github_pr)
# component_push_plr_name (set by wait_for_plr_to_appear)
# RELEASE_NAME, RELEASE_NAMESPACE (set and exported by wait_for_release)
# advisory_yaml_dir (set by verify_release_contents)

# Function to verify Release contents
# Modifies global variable: advisory_yaml_dir
# Relies on global variables: RELEASE_NAME, RELEASE_NAMESPACE, SCRIPT_DIR, managed_namespace, managed_sa_name, NO_CVE
verify_release_contents() {
    echo "Verifying Release contents for ${RELEASE_NAME} in namespace ${RELEASE_NAMESPACE}..."
    local release_json
    release_json=$(kubectl get release/"${RELEASE_NAME}" -n "${RELEASE_NAMESPACE}" -ojson)
    if [ -z "$release_json" ]; then
        log_error "Could not retrieve Release JSON for ${RELEASE_NAME}"
    fi

    local failures=0
    local num_issues advisory_url advisory_internal_url catalog_url cve
    local severity topic description

    num_issues=$(jq -r '.status.collectors.tenant."jira-collector".releaseNotes.issues.fixed | length // 0' <<< "${release_json}")
    advisory_url=$(jq -r '.status.artifacts.advisory.url // ""' <<< "${release_json}")
    advisory_internal_url=$(jq -r '.status.artifacts.advisory.internal_url // ""' <<< "${release_json}")
    catalog_url=$(jq -r '.status.artifacts.catalog_urls[]?.url // ""' <<< "${release_json}")
    cve=$(jq -r '.status.collectors.tenant.cve.releaseNotes.cves[]? | select(.key == "CVE-2024-8260") | .key // ""' <<< "${release_json}")

    if [ -z "$advisory_internal_url" ]; then
        echo "Warning: advisory_internal_url is empty. Skipping advisory content check."
    else
        # advisory_yaml_dir is made global by not declaring it local
        advisory_yaml_dir=$(mktemp -d -p "$(pwd)")
        echo "Fetching advisory content to ${advisory_yaml_dir}..."
        "${SCRIPT_DIR}/../scripts/get-advisory-content.sh" "${managed_namespace}" "${managed_sa_name}" "${advisory_internal_url}" "${advisory_yaml_dir}"
        if [ ! -f "${advisory_yaml_dir}/advisory.yaml" ]; then
            echo "🔴 Advisory YAML not found at ${advisory_yaml_dir}/advisory.yaml"
            failures=$((failures+1))
        else
            severity=$(yq '.spec.severity // "null"' "${advisory_yaml_dir}/advisory.yaml")
            echo "Found severity: ${severity}"
            topic=$(yq '.spec.topic // ""' "${advisory_yaml_dir}/advisory.yaml")
            echo "Found topic: ${topic}"
            description=$(yq '.spec.description // ""' "${advisory_yaml_dir}/advisory.yaml")
            echo "Found description: ${description}"
        fi
    fi

    echo "Checking number of issues..."
    if [ "${num_issues}" -gt 0 ]; then
      echo "✅️ Number of issues (${num_issues}) is > 0"
    else
      echo "🔴 Incorrect number of issues. Found ${num_issues}, expected > 0"
      failures=$((failures+1))
    fi

    echo "Checking advisory URLs..."
    if [ -n "${advisory_url}" ]; then
      echo "✅️ advisory_url: ${advisory_url}"
    else
      echo "🔴 advisory_url was empty!"
      failures=$((failures+1))
    fi
    if [ -n "${advisory_internal_url}" ]; then
      echo "✅️ advisory_internal_url: ${advisory_internal_url}"
    else
      echo "🔴 advisory_internal_url was empty!"
      failures=$((failures+1))
    fi
    if [ -n "${catalog_url}" ]; then
        echo "✅️ catalog_url: ${catalog_url}"
    else
        echo "🟡 catalog_url was empty (optional?)" # Marked as optional based on original script's handling
        # If this should be a failure, uncomment the next line
        # failures=$((failures+1))
    fi

    if [ "${NO_CVE}" == "true" ]; then
      echo "Checking that no CVEs were found (as NO_CVE is true)..."
      if [ -z "${cve}" ]; then
        echo "✅️ CVE: <empty>"
      else
        echo "🔴 Incorrect CVE. Expected empty, Found '${cve}'!"
        failures=$((failures+1))
      fi
      local expected_severity="null"
      echo "Checking if severity is '${expected_severity}' (since NO_CVE is true)..."
       if [[ "${severity}" == "${expected_severity}" ]]; then
        echo "✅️ Found correct severity: ${severity}"
      else
        echo "🔴 Incorrect severity! Expected '${expected_severity}', Found '${severity}'"
        failures=$((failures+1))
      fi
    else
      echo "Checking that CVE 'CVE-2024-8260' was found..."
      if [ "${cve}" == "CVE-2024-8260" ]; then
        echo "✅️ CVE: ${cve}"
      else
        echo "🔴 Incorrect CVE. Expected 'CVE-2024-8260', Found '${cve}'!"
        failures=$((failures+1))
      fi
      local expected_severity="Moderate"
      echo "Checking if severity is ${expected_severity} (since NO_CVE is false)..."
      if [[ "${severity}" == "${expected_severity}" ]]; then
        echo "✅️ Found correct severity: ${severity}"
      else
        echo "🔴 Incorrect severity! Expected '${expected_severity}', Found '${severity}'"
        failures=$((failures+1))
      fi
    fi

    if [ -n "$advisory_internal_url" ] && [ -f "${advisory_yaml_dir}/advisory.yaml" ]; then
      local expected_topic_substring="Updated Application Stream container images for Red Hat Comp2 are now available"
      echo "Checking if topic contains '${expected_topic_substring}'..."
      if [[ "${topic}" == *"${expected_topic_substring}"* ]]; then
        echo "✅️ Found topic substring in: ${topic}"
      else
        echo "🔴 Did not find topic substring in: ${topic}!"
        failures=$((failures+1))
      fi

      substrings=(
          "Red Hat Comp2 1 container images"
          "* rh-advisories-component"
          "RELEASE-1502 (test issue for collector e2e testing)"
      )
      # Conditionally add CVE-2024-8260 to substrings if NO_CVE is false
      if [ "${NO_CVE}" == "false" ]; then
        substrings+=("CVE-2024-8260")
      fi

      all_found=true
      for substring in "${substrings[@]}"; do
          if grep -qF -- "$substring" <<< "${description}"; then
              echo "✅ Found: '$substring'"
          else
              echo "❌ Not Found: '$substring'"
              all_found=false
          fi
      done

      if [ "$all_found" = true ]; then
        echo "✅️ Found all required description substrings"
      else
        echo "🔴 Some required description substrings were NOT found."
        failures=$((failures+1))
      fi

    elif [ -n "$advisory_internal_url" ]; then
      echo "🔴 Skipping topic and description check as advisory YAML was not found/fetched."
    else
      echo "Skipping topic and description check as advisory_internal_url was empty."
    fi

    if [ "${failures}" -gt 0 ]; then
      echo "🔴 Test has FAILED with ${failures} failure(s)!"
      exit 1
    else
      echo "✅️ All release checks passed. Success!"
    fi
}

# --- Main Script Execution ---

# Trap EXIT signal to call cleanup function
# Pass error code, line number, and command to the cleanup function
trap 'cleanup_resources $? $LINENO "$BASH_COMMAND"' EXIT

check_env_vars "$@" # Pass all args for consistency, though check_env_vars doesn't use them
parse_options "$@" # Parses options and sets CLEANUP, NO_CVE

decrypt_secrets
create_github_branch
setup_namespaces # Ensures correct context before resource creation
create_kubernetes_resources # tmpDir is set here

wait_for_component_initialization # component_pr and pr_number are set here
merge_github_pr # SHA is set here

wait_for_plr_to_appear # component_push_plr_name is set here
wait_for_plr_to_complete

wait_for_release # RELEASE_NAME, RELEASE_NAMESPACE are set and exported here
verify_release_contents

echo "✅️ End-to-end test script completed successfully."
exit 0
