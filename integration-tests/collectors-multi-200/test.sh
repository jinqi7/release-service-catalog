#!/usr/bin/env bash
#
# Test script for collectors-multi-200 test suite
# This script manages 200+ components with comprehensive retry mechanisms
# to ensure reliability in large-scale release testing.
#

# --- Global Script Variables (Defaults) ---
CLEANUP="true"
NO_CVE="false" # Default to false

# Tracking arrays for components
declare -gA COMPONENT_STATUS=()          # Track component initialization status
declare -gA COMPONENT_PR_STATUS=()       # Track PR merge status
declare -gA COMPONENT_PLR_STATUS=()      # Track PipelineRun status
declare -gA COMPONENT_RETRY_COUNT=()     # Track retry attempts per component

# Progress tracking
declare -g TOTAL_COMPONENTS_INITIALIZED=0
declare -g TOTAL_COMPONENTS_BUILT=0
declare -g TOTAL_FAILURES=0

# --- Helper Functions ---

log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ℹ️  $*"
}

log_success() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $*"
}

log_warning() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $*"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 🔴 $*"
}

log_progress() {
    local current=$1
    local total=$2
    local operation=$3
    local percentage=$((current * 100 / total))
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 📊 Progress: ${current}/${total} (${percentage}%) ${operation}"
}

# --- GitHub Repository Management with Retry ---

create_github_repository() {
    log_info "Creating GitHub repositories/branches for ${TOTAL_COMPONENTS} components..."

    local failed_repos=()
    local created_count=0

    # Always create component 1 repo
    log_info "Creating primary component repository..."
    local retry_count=0
    local success=false

    while [ $retry_count -lt ${MAX_COMPONENT_RETRIES} ] && [ "$success" = false ]; do
        if "${SUITE_DIR}/../scripts/copy-branch-to-repo-git.sh" \
            "${component_base_repo_name}" "${component_base_branch}" \
            "${component_repo_name}" "${component_branch}"; then
            success=true
            created_count=$((created_count + 1))
            log_success "Primary component repository created"
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt ${MAX_COMPONENT_RETRIES} ]; then
                log_warning "Failed to create primary repo, retry ${retry_count}/${MAX_COMPONENT_RETRIES} in ${RETRY_DELAY_SECONDS}s"
                sleep ${RETRY_DELAY_SECONDS}
            fi
        fi
    done

    if [ "$success" = false ]; then
        log_error "Failed to create primary repository after ${MAX_COMPONENT_RETRIES} attempts"
        exit 1
    fi

    # Create branches for components 2 through TOTAL_COMPONENTS
    # Use batched parallel execution to avoid overwhelming GitHub API
    local batch_size=10
    for batch_start in $(seq 2 ${batch_size} ${TOTAL_COMPONENTS}); do
        local batch_end=$((batch_start + batch_size - 1))
        if [ $batch_end -gt ${TOTAL_COMPONENTS} ]; then
            batch_end=${TOTAL_COMPONENTS}
        fi

        log_info "Creating batch: components ${batch_start} to ${batch_end}..."

        for i in $(seq ${batch_start} ${batch_end}); do
            (
                local repo_name_var="component${i}_repo_name"
                local branch_var="component${i}_branch"
                local repo_name="${!repo_name_var}"
                local branch="${!branch_var}"

                if [ -n "${repo_name}" ] && [ -n "$branch" ] && [ "$branch" != "$component_branch" ]; then
                    local comp_retry_count=0
                    local comp_success=false

                    while [ $comp_retry_count -lt ${MAX_COMPONENT_RETRIES} ] && [ "$comp_success" = false ]; do
                        if "${SUITE_DIR}/../scripts/copy-branch-to-repo-git.sh" \
                            "${component_base_repo_name}" "${component_base_branch}" \
                            "${repo_name}" "${branch}" 2>&1 | sed "s/^/  [comp${i}] /"; then
                            comp_success=true
                            log_success "Component ${i} repository/branch created"
                        else
                            comp_retry_count=$((comp_retry_count + 1))
                            if [ $comp_retry_count -lt ${MAX_COMPONENT_RETRIES} ]; then
                                log_warning "Component ${i}: retry ${comp_retry_count}/${MAX_COMPONENT_RETRIES} in ${RETRY_DELAY_SECONDS}s"
                                sleep ${RETRY_DELAY_SECONDS}
                            fi
                        fi
                    done

                    if [ "$comp_success" = false ]; then
                        echo "FAILED:${i}" >> "${tmpDir}/failed_repos.txt"
                    else
                        echo "SUCCESS:${i}" >> "${tmpDir}/success_repos.txt"
                    fi
                fi
            ) &
        done

        # Wait for current batch to complete
        wait

        # Update progress
        if [ -f "${tmpDir}/success_repos.txt" ]; then
            created_count=$(wc -l < "${tmpDir}/success_repos.txt")
        fi
        log_progress "$created_count" "${TOTAL_COMPONENTS}" "repositories created"

        # Small delay between batches to avoid API rate limits
        sleep 2
    done

    # Check for failures
    if [ -f "${tmpDir}/failed_repos.txt" ]; then
        local failed_count=$(wc -l < "${tmpDir}/failed_repos.txt")
        log_error "${failed_count} repositories failed to create"
        cat "${tmpDir}/failed_repos.txt"
        exit 1
    fi

    log_success "All ${TOTAL_COMPONENTS} repositories/branches created successfully"
}

# --- Component Initialization with Retry ---

wait_for_single_component_initialization() {
    local comp_name=$1
    local comp_index=$2
    local max_attempts=$((COMPONENT_INIT_TIMEOUT / 10))  # 10-second intervals
    local attempt=1
    local component_annotations=""
    local initialization_success=false
    local comp_pr=""
    local comp_pr_number=""

    while [ $attempt -le $max_attempts ]; do
        # Try to get component annotations
        component_annotations=$(kubectl get component/"${comp_name}" -n "${tenant_namespace}" -ojson 2>/dev/null | \
            jq -r --arg k "build.appstudio.openshift.io/status" '.metadata.annotations[$k] // ""')

        if [ -n "${component_annotations}" ]; then
            comp_pr=$(jq -r '.pac."merge-url" // ""' <<< "${component_annotations}")
            if [ -n "${comp_pr}" ]; then
                initialization_success=true
                break
            else
                if [ $((attempt % 6)) -eq 0 ]; then  # Log every minute
                    log_info "Component ${comp_index} (${comp_name}): waiting for PR... (attempt ${attempt}/${max_attempts})"
                fi
                sleep 10
            fi
        else
            if [ $((attempt % 6)) -eq 0 ]; then  # Log every minute
                log_info "Component ${comp_index} (${comp_name}): waiting for initialization... (attempt ${attempt}/${max_attempts})"
            fi
            sleep 10
        fi

        attempt=$((attempt + 1))
    done

    if [ "$initialization_success" = false ]; then
        log_error "Component ${comp_index} (${comp_name}) failed to initialize after ${max_attempts} attempts"
        COMPONENT_STATUS["comp${comp_index}"]="INIT_FAILED"
        return 1
    fi

    comp_pr_number=$(cut -f7 -d/ <<< "${comp_pr}")
    if [ -z "${comp_pr_number}" ]; then
        log_error "Component ${comp_index}: Could not extract PR number from ${comp_pr}"
        COMPONENT_STATUS["comp${comp_index}"]="INIT_FAILED"
        return 1
    fi

    # Store PR info to file (will be read back by parent shell)
    echo "${comp_index}|${comp_pr}|${comp_pr_number}" >> "${tmpDir}/component_tracking/pr_data.txt"

    COMPONENT_STATUS["comp${comp_index}"]="INITIALIZED"
    log_success "Component ${comp_index} (${comp_name}) initialized: PR #${comp_pr_number}"
    return 0
}

wait_for_component_initialization() {
    log_info "Waiting for ${TOTAL_COMPONENTS} components to initialize..."

    # Initialize tracking files
    mkdir -p "${tmpDir}/component_tracking"
    > "${tmpDir}/component_tracking/initialized.txt"
    > "${tmpDir}/component_tracking/failed.txt"
    > "${tmpDir}/component_tracking/pr_data.txt"

    # Process components in batches
    local batch_size=20
    local initialized_count=0

    for batch_start in $(seq 1 ${batch_size} ${TOTAL_COMPONENTS}); do
        local batch_end=$((batch_start + batch_size - 1))
        if [ $batch_end -gt ${TOTAL_COMPONENTS} ]; then
            batch_end=${TOTAL_COMPONENTS}
        fi

        log_info "Initializing batch: components ${batch_start} to ${batch_end}..."

        for i in $(seq ${batch_start} ${batch_end}); do
            (
                if [ $i -eq 1 ]; then
                    local comp_name="${component_name}"
                else
                    local name_var="component${i}_name"
                    local comp_name="${!name_var}"
                fi

                if wait_for_single_component_initialization "${comp_name}" "$i"; then
                    echo "$i" >> "${tmpDir}/component_tracking/initialized.txt"
                else
                    echo "$i" >> "${tmpDir}/component_tracking/failed.txt"
                fi
            ) &
        done

        # Wait for batch completion
        wait

        # Update progress
        if [ -f "${tmpDir}/component_tracking/initialized.txt" ]; then
            initialized_count=$(wc -l < "${tmpDir}/component_tracking/initialized.txt")
        fi
        log_progress "$initialized_count" "${TOTAL_COMPONENTS}" "components initialized"
    done

    # Final check
    local failed_count=0
    if [ -f "${tmpDir}/component_tracking/failed.txt" ]; then
        failed_count=$(wc -l < "${tmpDir}/component_tracking/failed.txt")
    fi

    if [ $failed_count -gt 0 ]; then
        log_error "${failed_count} components failed to initialize"
        cat "${tmpDir}/component_tracking/failed.txt"
        exit 1
    fi

    # Read PR data from file and set global variables
    if [ -f "${tmpDir}/component_tracking/pr_data.txt" ]; then
        while IFS='|' read -r comp_idx comp_pr comp_pr_num; do
            if [ "${comp_idx}" -eq 1 ]; then
                component_pr="${comp_pr}"
                pr_number="${comp_pr_num}"
            else
                eval "component${comp_idx}_pr=\"${comp_pr}\""
                eval "component${comp_idx}_pr_number=\"${comp_pr_num}\""
            fi
        done < "${tmpDir}/component_tracking/pr_data.txt"
    fi

    TOTAL_COMPONENTS_INITIALIZED=$initialized_count
    log_success "All ${initialized_count} components initialized successfully"
}

# --- PR Merge with Retry ---

merge_single_component_pr() {
    local pr_num=$1
    local repo_name=$2
    local comp_index=$3
    local commit_message="This fixes CVE-2024-8260"

    if [ "${NO_CVE}" == "true" ]; then
        commit_message="e2e test"
    fi

    local merge_result
    local attempt=1
    local success=false

    while [ $attempt -le ${MAX_COMPONENT_RETRIES} ] && [ "$success" = false ]; do
        set +e
        merge_result=$(curl -L \
          -X PUT \
          -H "Accept: application/vnd.github+json" \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "https://api.github.com/repos/${repo_name}/pulls/${pr_num}/merge" \
          -d "{\"commit_title\":\"e2e test\",\"commit_message\":\"${commit_message}\"}" --silent --show-error --fail-with-body 2>&1)

        if [ $? -eq 0 ]; then
            success=true
            local sha=$(jq -r '.sha' <<< "${merge_result}")
            if [ -z "$sha" ] || [ "$sha" == "null" ]; then
                log_error "Component ${comp_index}: Could not get SHA from merge result"
                success=false
            else
                # Store SHA to file (will be read back by parent shell)
                echo "${comp_index}:${sha}" >> "${tmpDir}/component_tracking/sha_data.txt"
                COMPONENT_PR_STATUS["comp${comp_index}"]="MERGED"
                log_success "Component ${comp_index}: PR #${pr_num} merged (SHA: ${sha})"
            fi
        else
            log_warning "Component ${comp_index}: PR merge attempt ${attempt}/${MAX_COMPONENT_RETRIES} failed"
            if [ $attempt -lt ${MAX_COMPONENT_RETRIES} ]; then
                sleep ${RETRY_DELAY_SECONDS}
            fi
        fi
        set -e

        attempt=$((attempt + 1))
    done

    if [ "$success" = false ]; then
        log_error "Component ${comp_index}: Failed to merge PR #${pr_num} after ${MAX_COMPONENT_RETRIES} attempts"
        COMPONENT_PR_STATUS["comp${comp_index}"]="MERGE_FAILED"
        return 1
    fi

    return 0
}

merge_github_pr() {
    log_info "Merging PRs for ${TOTAL_COMPONENTS} components..."

    mkdir -p "${tmpDir}/component_tracking"
    > "${tmpDir}/component_tracking/merged.txt"
    > "${tmpDir}/component_tracking/merge_failed.txt"
    > "${tmpDir}/component_tracking/sha_data.txt"

    # Merge in batches to avoid overwhelming GitHub API
    local batch_size=10
    local merged_count=0

    for batch_start in $(seq 1 ${batch_size} ${TOTAL_COMPONENTS}); do
        local batch_end=$((batch_start + batch_size - 1))
        if [ $batch_end -gt ${TOTAL_COMPONENTS} ]; then
            batch_end=${TOTAL_COMPONENTS}
        fi

        log_info "Merging batch: PRs ${batch_start} to ${batch_end}..."

        for i in $(seq ${batch_start} ${batch_end}); do
            (
                if [ $i -eq 1 ]; then
                    local pr_num="${pr_number}"
                    local repo_name="${component_repo_name}"
                else
                    local pr_number_var="component${i}_pr_number"
                    local repo_name_var="component${i}_repo_name"
                    local pr_num="${!pr_number_var}"
                    local repo_name="${!repo_name_var}"
                fi

                if [ -n "${pr_num}" ] && [ -n "${repo_name}" ]; then
                    if merge_single_component_pr "${pr_num}" "${repo_name}" "$i"; then
                        echo "$i" >> "${tmpDir}/component_tracking/merged.txt"
                    else
                        echo "$i" >> "${tmpDir}/component_tracking/merge_failed.txt"
                    fi
                fi
            ) &
        done

        wait

        # Update progress
        if [ -f "${tmpDir}/component_tracking/merged.txt" ]; then
            merged_count=$(wc -l < "${tmpDir}/component_tracking/merged.txt")
        fi
        log_progress "$merged_count" "${TOTAL_COMPONENTS}" "PRs merged"

        # Delay between batches
        sleep 2
    done

    # Check for failures
    local failed_count=0
    if [ -f "${tmpDir}/component_tracking/merge_failed.txt" ]; then
        failed_count=$(wc -l < "${tmpDir}/component_tracking/merge_failed.txt")
    fi

    if [ $failed_count -gt 0 ]; then
        log_error "${failed_count} PRs failed to merge"
        cat "${tmpDir}/component_tracking/merge_failed.txt"
        exit 1
    fi

    # Read SHA data from file and set global variables
    if [ -f "${tmpDir}/component_tracking/sha_data.txt" ]; then
        while IFS=: read -r comp_idx sha; do
            if [ "${comp_idx}" -eq 1 ]; then
                SHA="${sha}"
                component_sha="${sha}"
            else
                eval "component${comp_idx}_sha=\"${sha}\""
            fi
        done < "${tmpDir}/component_tracking/sha_data.txt"
    fi

    log_success "All ${merged_count} PRs merged successfully"
}

# --- PipelineRun Monitoring with Retry ---

wait_for_single_plr_to_appear() {
    local sha=$1
    local comp_index=$2
    local timeout=${PLR_APPEAR_TIMEOUT}
    local start_time=$(date +%s)
    local found_plr_name=""

    while [ -z "$found_plr_name" ]; do
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))

        if [ $elapsed_time -ge $timeout ]; then
            log_error "Component ${comp_index}: Timeout waiting for PipelineRun (SHA: ${sha})"
            return 1
        fi

        sleep 10
        # Find PipelineRun by SHA label, regardless of status (could be Running, True, or False)
        found_plr_name=$(kubectl get pr -l "pipelinesascode.tekton.dev/sha=$sha" -n "${tenant_namespace}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')

        if [ $((elapsed_time % 60)) -eq 0 ] && [ $elapsed_time -gt 0 ]; then
            log_info "Component ${comp_index}: Still waiting for PipelineRun... (${elapsed_time}s elapsed)"
        fi
    done

    log_success "Component ${comp_index}: Found PipelineRun ${found_plr_name}"

    # Store PLR name to file (will be read back by parent shell)
    echo "${comp_index}:${found_plr_name}" >> "${tmpDir}/component_tracking/plr_data.txt"

    echo "${found_plr_name}"
    return 0
}

wait_for_plr_to_appear() {
    log_info "Waiting for PipelineRuns to appear for ${TOTAL_COMPONENTS} components..."

    # Ensure tracking directory exists
    mkdir -p "${tmpDir}/component_tracking"
    > "${tmpDir}/component_tracking/plr_found.txt"
    > "${tmpDir}/component_tracking/plr_not_found.txt"
    > "${tmpDir}/component_tracking/plr_data.txt"

    # Process in batches
    local batch_size=${MAX_PARALLEL_BUILDS}
    local found_count=0

    for batch_start in $(seq 1 ${batch_size} ${TOTAL_COMPONENTS}); do
        local batch_end=$((batch_start + batch_size - 1))
        if [ $batch_end -gt ${TOTAL_COMPONENTS} ]; then
            batch_end=${TOTAL_COMPONENTS}
        fi

        log_info "Waiting for PipelineRuns batch: ${batch_start} to ${batch_end}..."

        for i in $(seq ${batch_start} ${batch_end}); do
            (
                if [ $i -eq 1 ]; then
                    local sha="${component_sha}"
                else
                    local sha_var="component${i}_sha"
                    local sha="${!sha_var}"
                fi

                if [ -n "${sha}" ]; then
                    if wait_for_single_plr_to_appear "${sha}" "$i" > /dev/null 2>&1; then
                        echo "$i" >> "${tmpDir}/component_tracking/plr_found.txt"
                    else
                        echo "$i" >> "${tmpDir}/component_tracking/plr_not_found.txt"
                    fi
                fi
            ) &
        done

        wait

        if [ -f "${tmpDir}/component_tracking/plr_found.txt" ]; then
            found_count=$(wc -l < "${tmpDir}/component_tracking/plr_found.txt")
        fi
        log_progress "$found_count" "${TOTAL_COMPONENTS}" "PipelineRuns found"
    done

    # Check for failures
    local not_found_count=0
    if [ -f "${tmpDir}/component_tracking/plr_not_found.txt" ]; then
        not_found_count=$(wc -l < "${tmpDir}/component_tracking/plr_not_found.txt")
    fi

    if [ $not_found_count -gt 0 ]; then
        log_error "${not_found_count} PipelineRuns did not appear"
        cat "${tmpDir}/component_tracking/plr_not_found.txt"
        exit 1
    fi

    # Read PLR data from file and set global variables
    if [ -f "${tmpDir}/component_tracking/plr_data.txt" ]; then
        while IFS=: read -r comp_idx plr_name; do
            if [ "${comp_idx}" -eq 1 ]; then
                component_push_plr_name="${plr_name}"
            else
                eval "component${comp_idx}_push_plr_name=\"${plr_name}\""
            fi
        done < "${tmpDir}/component_tracking/plr_data.txt"
    fi

    log_success "All ${found_count} PipelineRuns found"
}

wait_for_single_plr_to_complete() {
    local plr_name=$1
    local comp_index=$2
    local timeout=${PLR_COMPLETE_TIMEOUT}
    local start_time=$(date +%s)
    local completed=""
    local retry_count=0

    # Verify the PipelineRun exists
    if ! kubectl get pipelinerun "${plr_name}" -n "${tenant_namespace}" >/dev/null 2>&1; then
        log_error "Component ${comp_index}: PipelineRun ${plr_name} does not exist"
        return 1
    fi

    while true; do
        local elapsed_time=$(( $(date +%s) - start_time ))

        if [ $elapsed_time -ge $timeout ]; then
            log_error "Component ${comp_index}: Timeout waiting for PipelineRun ${plr_name}"
            return 1
        fi

        sleep 10

        # Get PipelineRun status
        local plr_status
        plr_status=$(kubectl get pipelinerun "${plr_name}" -n "${tenant_namespace}" -o json 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$plr_status" ]; then
            completed=$(jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status' <<<"$plr_status" 2>/dev/null || echo "")
        fi

        if [ "$completed" == "True" ]; then
            log_success "Component ${comp_index}: PipelineRun ${plr_name} completed successfully"
            COMPONENT_PLR_STATUS["comp${comp_index}"]="SUCCEEDED"
            return 0
        elif [ "$completed" == "False" ]; then
            log_warning "Component ${comp_index}: PipelineRun ${plr_name} failed"

            if [ $retry_count -lt ${MAX_PLR_RETRIES} ]; then
                retry_count=$((retry_count + 1))
                log_info "Component ${comp_index}: Retry ${retry_count}/${MAX_PLR_RETRIES} - triggering new build"

                # Get component name
                if [ $comp_index -eq 1 ]; then
                    local comp_name="${component_name}"
                    local sha="${component_sha}"
                else
                    local name_var="component${comp_index}_name"
                    local comp_name="${!name_var}"
                    local sha_var="component${comp_index}_sha"
                    local sha="${!sha_var}"
                fi

                # Trigger retry
                kubectl annotate components/${comp_name} build.appstudio.openshift.io/request=trigger-pac-build -n "${tenant_namespace}" --overwrite

                sleep ${PLR_RETRY_DELAY_SECONDS}

                # Wait for new PLR and capture the name
                local new_plr_name
                if new_plr_name=$(wait_for_single_plr_to_appear "${sha}" "${comp_index}" 2>&1); then
                    # Update PLR name and reset timeout
                    plr_name="${new_plr_name}"
                    start_time=$(date +%s)
                    completed=""
                    log_info "Component ${comp_index}: Monitoring retry PipelineRun ${plr_name}"
                else
                    log_error "Component ${comp_index}: Failed to find retry PipelineRun"
                    COMPONENT_PLR_STATUS["comp${comp_index}"]="FAILED"
                    return 1
                fi
            else
                log_error "Component ${comp_index}: Max retries (${MAX_PLR_RETRIES}) exceeded"
                COMPONENT_PLR_STATUS["comp${comp_index}"]="FAILED"
                return 1
            fi
        fi

        # Log progress every 2 minutes if still running
        if [ $((elapsed_time % 120)) -eq 0 ] && [ $elapsed_time -gt 0 ]; then
            log_info "Component ${comp_index}: PipelineRun ${plr_name} still running... (${elapsed_time}s elapsed)"
        fi
    done

    return 0
}

wait_for_plr_to_complete() {
    log_info "Waiting for ${TOTAL_COMPONENTS} PipelineRuns to complete..."

    # Ensure tracking directory exists
    mkdir -p "${tmpDir}/component_tracking"
    > "${tmpDir}/component_tracking/plr_completed.txt"
    > "${tmpDir}/component_tracking/plr_failed.txt"

    # Process in controlled batches to manage cluster load
    local batch_size=${MAX_PARALLEL_BUILDS}
    local completed_count=0

    for batch_start in $(seq 1 ${batch_size} ${TOTAL_COMPONENTS}); do
        local batch_end=$((batch_start + batch_size - 1))
        if [ $batch_end -gt ${TOTAL_COMPONENTS} ]; then
            batch_end=${TOTAL_COMPONENTS}
        fi

        log_info "Waiting for completion batch: ${batch_start} to ${batch_end}..."

        for i in $(seq ${batch_start} ${batch_end}); do
            (
                if [ $i -eq 1 ]; then
                    local plr_name="${component_push_plr_name}"
                else
                    local plr_name_var="component${i}_push_plr_name"
                    local plr_name="${!plr_name_var}"
                fi

                if [ -n "${plr_name}" ]; then
                    if wait_for_single_plr_to_complete "${plr_name}" "$i"; then
                        echo "$i" >> "${tmpDir}/component_tracking/plr_completed.txt"
                    else
                        echo "$i" >> "${tmpDir}/component_tracking/plr_failed.txt"
                    fi
                fi
            ) &
        done

        wait

        if [ -f "${tmpDir}/component_tracking/plr_completed.txt" ]; then
            completed_count=$(wc -l < "${tmpDir}/component_tracking/plr_completed.txt")
        fi
        log_progress "$completed_count" "${TOTAL_COMPONENTS}" "PipelineRuns completed"
    done

    # Final check
    local failed_count=0
    if [ -f "${tmpDir}/component_tracking/plr_failed.txt" ]; then
        failed_count=$(wc -l < "${tmpDir}/component_tracking/plr_failed.txt")
    fi

    if [ $failed_count -gt 0 ]; then
        log_error "${failed_count} PipelineRuns failed"
        log_error "Failed components:"
        cat "${tmpDir}/component_tracking/plr_failed.txt"
        exit 1
    fi

    # Verify that we actually processed PLRs
    if [ $completed_count -eq 0 ]; then
        log_error "No PipelineRuns were found to monitor. Expected ${TOTAL_COMPONENTS} PipelineRuns."
        log_error "This likely means PLR names were not set by wait_for_plr_to_appear."
        exit 1
    fi

    if [ $completed_count -ne ${TOTAL_COMPONENTS} ]; then
        log_error "Only ${completed_count}/${TOTAL_COMPONENTS} PipelineRuns completed successfully"
        exit 1
    fi

    TOTAL_COMPONENTS_BUILT=$completed_count
    log_success "All ${completed_count} PipelineRuns completed successfully"
}

# --- Release Management ---

wait_for_releases() {
    log_info "Waiting for Releases for application ${application_name}..."
    # TODO: jing
    # Get all the snapshot and find the one with all the components
    # jq -r ".spec.components | length"' <<< "${release_json}"
    # create release for the snapshot
    #
    #
    local RELEASE_2_NAME="release-idempotent-2-${uuid}"
    echo "Creating second release with SAME snapshot..."
    local RELEASE_2_START=$(date +%s)

    cat <<EOF | kubectl apply -f -
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: ${RELEASE_2_NAME}
  namespace: ${tenant_namespace}
  labels:
    originating-tool: "${originating_tool}"
    test-type: "idempotent-second-release"
spec:
  snapshot: ${SNAPSHOT_NAME}
  releasePlan: ${release_plan_name}
EOF

    echo "Waiting for Release-2 to complete..."
    export RELEASE_NAME="${RELEASE_2_NAME}"
    export RELEASE_NAMESPACE="${tenant_namespace}"
    "${SCRIPT_DIR}/../scripts/wait-for-release.sh"

    log_success "Found releases: ${release_names}"

    # Wait for each release to complete
    export RELEASE_NAMESPACE=${tenant_namespace}
    export RELEASE_NAMES="${release_names}"

    local release_count=$(echo ${release_names} | wc -w)
    log_info "Waiting for ${release_count} release(s) to complete..."

    for release in ${release_names}; do
        export RELEASE_NAME=${release}
        log_info "Monitoring release: ${release}"
        "${SUITE_DIR}/../scripts/wait-for-release.sh" &
    done

    # Wait for all release monitoring jobs to finish
    wait

    log_success "All releases completed"
}

# --- Release Verification ---

verify_atlas_url() {
    local url="$1"
    local prefix="https://atlas.release.stage.devshift.net/sboms/urn:uuid:"

    if [[ ! "$url" == "$prefix"* ]]; then
        echo "🔴 Atlas URL '$url' has invalid prefix"
        return 1
    fi

    local uuid_str="${url#$prefix}"

    # UUID v7 regex pattern
    if [[ ! "$uuid_str" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
        echo "🔴 Could not parse UUID '$uuid_str' or UUID is not version 7"
        return 1
    fi

    return 0
}

verify_sboms() {
    local sboms_json="$1"
    local expected_component_count=$2
    local any_failures=0

    local product_sboms
    product_sboms=$(jq -r '.product[]? // empty' <<< "$sboms_json" 2>/dev/null)
    local product_count
    product_count=$(jq -r '.product | length // 0' <<< "$sboms_json" 2>/dev/null)

    if [ "$product_count" -eq 1 ]; then
        log_success "Found expected number of product SBOMs: $product_count"
        while IFS= read -r atlas_url; do
            if [ -n "$atlas_url" ]; then
                if verify_atlas_url "$atlas_url"; then
                    log_success "Valid product SBOM Atlas URL: $atlas_url"
                else
                    any_failures=1
                fi
            fi
        done <<< "$product_sboms"
    else
        log_error "Incorrect number of product SBOMs. Expected 1, found: $product_count"
        any_failures=1
    fi

    local component_sboms
    component_sboms=$(jq -r '.component[]? // empty' <<< "$sboms_json" 2>/dev/null)
    local component_count
    component_count=$(jq -r '.component | length // 0' <<< "$sboms_json" 2>/dev/null)

    # For 200+ components, expect 200+ * 3 component SBOMs (base + source + other)
    local expected_sbom_count=$((expected_component_count * 3))

    if [ "$component_count" -ge "$expected_sbom_count" ]; then
        log_success "Found sufficient component SBOMs: $component_count (expected >= $expected_sbom_count)"
    else
        log_error "Incorrect number of component SBOMs. Expected >= $expected_sbom_count, found: $component_count"
        any_failures=1
    fi

    if [ "$any_failures" -eq 1 ]; then
        return 1
    fi

    return 0
}

verify_release_contents() {
    log_info "Verifying release contents for ${TOTAL_COMPONENTS} components..."

    local failed_releases=""
    for RELEASE_NAME in ${RELEASE_NAMES}; do
        log_info "Verifying Release: ${RELEASE_NAME}"

        local release_json
        release_json=$(kubectl get release/"${RELEASE_NAME}" -n "${RELEASE_NAMESPACE}" -ojson)
        if [ -z "$release_json" ]; then
            log_error "Could not retrieve Release JSON for ${RELEASE_NAME}"
            failed_releases="${RELEASE_NAME} ${failed_releases}"
            continue
        fi

        local failures=0

        # Verify component count in release
        local component_count
        component_count=$(jq -r '.spec.snapshot | jq -r ".spec.components | length"' <<< "${release_json}" 2>/dev/null || echo "0")
        log_info "Release contains ${component_count} components"

        if [ "$component_count" -ne "${TOTAL_COMPONENTS}" ]; then
            log_warning "Component count mismatch: expected ${TOTAL_COMPONENTS}, found ${component_count}"
        fi

        # Verify collectors data
        local num_issues advisory_url advisory_internal_url catalog_url cve
        num_issues=$(jq -r '.status.collectors.tenant."jira-collector".releaseNotes.issues.fixed | length // 0' <<< "${release_json}")
        advisory_url=$(jq -r '.status.artifacts.advisory.url // ""' <<< "${release_json}")
        advisory_internal_url=$(jq -r '.status.artifacts.advisory.internal_url // ""' <<< "${release_json}")
        catalog_url=$(jq -r '.status.artifacts.catalog_urls[]?.url // ""' <<< "${release_json}")
        cve=$(jq -r '.status.collectors.tenant.cve.releaseNotes.cves[]? | select(.key == "CVE-2024-8260") | .key // ""' <<< "${release_json}")

        # Verify image architectures
        local image_arches
        image_arches=$(jq -r '.status.artifacts.images[0].arches | sort | join(" ") // ""' <<< "${release_json}")
        if [ "$image_arches" = "amd64 arm64" ]; then
            log_success "Found required image arches: amd64 arm64"
        else
            log_error "Some required image arches were NOT found: expected: amd64 arm64, found: ${image_arches}"
            failures=$((failures+1))
        fi

        # Verify advisory
        if [ -n "${advisory_url}" ]; then
            log_success "advisory_url: ${advisory_url}"
        else
            log_error "advisory_url was empty!"
            failures=$((failures+1))
        fi

        # Verify SBOMs
        local sboms
        sboms=$(jq -r '.status.artifacts.sboms // ""' <<< "${release_json}")
        if [ -z "$sboms" ] || [ "$sboms" = "null" ]; then
            log_error "The release artifact does NOT contain the 'sboms' field."
            failures=$((failures+1))
        else
            if verify_sboms "$sboms" "${TOTAL_COMPONENTS}"; then
                log_success "SBOM verification passed"
            else
                log_error "SBOM verification failed"
                failures=$((failures+1))
            fi
        fi

        # Verify CVE data
        if [ "${NO_CVE}" == "true" ]; then
            if [ -z "${cve}" ]; then
                log_success "CVE: <empty> (as expected with NO_CVE=true)"
            else
                log_error "Expected no CVE, found: ${cve}"
                failures=$((failures+1))
            fi
        else
            if [ "${cve}" == "CVE-2024-8260" ]; then
                log_success "CVE: ${cve}"
            else
                log_error "Expected CVE-2024-8260, found: ${cve}"
                failures=$((failures+1))
            fi
        fi

        if [ "${failures}" -gt 0 ]; then
            log_error "Release ${RELEASE_NAME} verification FAILED with ${failures} failure(s)"
            failed_releases="${RELEASE_NAME} ${failed_releases}"
        else
            log_success "Release ${RELEASE_NAME} verification PASSED"
        fi
    done

    if [ -n "${failed_releases}" ]; then
        log_error "The following releases FAILED verification: ${failed_releases}"
        exit 1
    else
        log_success "All releases verified successfully!"
    fi
}

# Patch component source before merge to add multi-arch and source image build
patch_component_source_before_merge() {
    log_info "Patching component sources to add multi-arch support and source image build..."

    # Get secret value from the tenant secrets file
    set +x
    secret_value=$(yq '. | select(.metadata.name | contains("pipelines-as-code-secret-")) | .stringData.password' ${SUITE_DIR}/resources/tenant/secrets/tenant-secrets.yaml)
    export GH_TOKEN=${secret_value}

    # Only patch the primary component to avoid overwhelming GitHub API
    # In a real scenario, you might patch all or a subset
    local file_names=".tekton/${component_name}-pull-request.yaml .tekton/${component_name}-push.yaml"

    for file_name in ${file_names}; do
        log_info "Patching ${file_name} for primary component..."

        head_sha=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
            "https://api.github.com/repos/${component_repo_name}/pulls/${pr_number}" | jq -r '.head.sha')

        decoded_contents=$(curl -s -H "Authorization: token ${GH_TOKEN}" \
            "https://api.github.com/repos/${component_repo_name}/contents/${file_name}?ref=${head_sha}" | \
            jq -r '.content' | base64 -d)

        local work_dir=$(mktemp -d)
        nopath_file_name=$(basename "${file_name}")
        echo "${decoded_contents}" > "${work_dir}/${nopath_file_name}"
        yq -i '(.spec.params[] | select(.name == "build-platforms") | .value) += ["linux/arm64"]' "${work_dir}/${nopath_file_name}"
        yq -i '.spec.params += [{"name": "build-source-image", "value": "true"}]' "${work_dir}/${nopath_file_name}"
        encoded_contents=$(base64 -w 0 <<< "$(cat "${work_dir}/${nopath_file_name}")")
        #rm -rf "${work_dir}"

        "${SCRIPT_DIR}/scripts/update-file-in-pull-request.sh" \
            "${component_repo_name}" \
            "${pr_number}" \
            "${file_name}" \
            "Update component source before merge" \
            "${encoded_contents}"
    done

    log_success "Component source patching complete"
}

# Generate summary report
generate_summary_report() {
    log_info "=========================================="
    log_info "Test Execution Summary"
    log_info "=========================================="
    log_info "Total components configured: ${TOTAL_COMPONENTS}"
    log_info "Components initialized: ${TOTAL_COMPONENTS_INITIALIZED}"
    log_info "Components built successfully: ${TOTAL_COMPONENTS_BUILT}"
    log_info "Total failures: ${TOTAL_FAILURES}"
    log_info "=========================================="
}

# Override cleanup to include summary
original_cleanup=$(declare -f cleanup_resources)
eval "wrapped_${original_cleanup}"

cleanup_resources() {
    generate_summary_report
    wrapped_cleanup_resources "$@"
}
