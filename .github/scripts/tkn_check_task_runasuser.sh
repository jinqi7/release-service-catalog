#!/usr/bin/env bash

#
# tkn_check_task_runasuser.sh
#
# Scans Tekton tasks in the CHANGED_FILES environment variable and ensures that Tekton tasks using Trusted Artifacts
# (those declaring ociStorage parameter) with non-release-service-utils (quay.io/konflux-ci/release-service-utils) images
# have proper security context (runAsUser: 1001) in their stepTemplate.
#

set -euo pipefail

# Function to log messages to stderr
log() {
    echo "$@" >&2
}

# Function to display usage
usage() {
    log "Usage: CHANGED_FILES=\"file1.yaml file2.yaml\" $0"
    log ""
    log "  CHANGED_FILES: Space-delimited list of files to check"
    log ""
    log "This script checks that any Tekton task using Trusted Artifacts (declaring ociStorage parameter)"
    log "with non-release-service-utils (quay.io/konflux-ci/release-service-utils) images has 'runAsUser: 1001'"
    log "defined in its stepTemplate.securityContext"
    log ""
    log "Notes:"
    log "  - Non-Tekton task files will be skipped gracefully"
    log "  - Only files with 'kind: Task' will be processed"
    log "  - Only tasks declaring 'ociStorage' parameter are checked (Trusted Artifacts tasks)"
    log ""
    log "Example: CHANGED_FILES=\"tasks/managed/task1/task1.yaml tasks/managed/task2/task2.yaml\" $0"
    exit 1
}

# Function to check if a task file has proper security context
check_task_security() {
    local task_file="$1"
    local task_name
    local has_non_konflux_image=false
    local has_security_context=false
    local exit_code=0
    local problematic_image=""

    # Get task name
    task_name=$(yq e '.metadata.name // "unknown"' "$task_file")
    
    log "Checking task: $task_name ($task_file)"

    # Check if task declares ociStorage parameter (indicates Trusted Artifacts usage)
    local has_oci_storage_param
    has_oci_storage_param=$(yq e '.spec.params[]? | select(.name == "ociStorage") | .name' "$task_file" 2>/dev/null || echo "")
    
    if [ -z "$has_oci_storage_param" ]; then
        log "  Skipping: Task does not declare ociStorage parameter (not using Trusted Artifacts)"
        return 0
    fi
    
    log "  Task declares ociStorage parameter, checking security context..."

    # Check if task has steps with non-release-service-utils images
    local step_count
    step_count=$(yq e '.spec.steps | length' "$task_file")
    
    if [ "$step_count" == "null" ] || [ "$step_count" == "0" ]; then
        log "  No steps found, skipping"
        return 0
    fi

    # Check each step for non-release-service-utils images
    for ((i = 0; i < step_count; i++)); do
        local image
        image=$(yq e ".spec.steps[$i].image // \"\"" "$task_file")
        
        # Skip null, empty, or missing images
        if [ -z "$image" ] || [ "$image" == "null" ]; then
            continue
        fi
        
        if [[ ! "$image" =~ ^quay\.io/konflux-ci/release-service-utils ]]; then
            log "  Found non-release-service-utils image: $image"
            has_non_konflux_image=true
            problematic_image="$image"
            break
        fi
    done

    # If no non-release-service-utils images found, task is compliant
    if [ "$has_non_konflux_image" == "false" ]; then
        log "  ✓ All images are from quay.io/konflux-ci/release-service-utils"
        return 0
    fi

    # Check if task has proper security context
    local run_as_user
    run_as_user=$(yq e '.spec.stepTemplate.securityContext.runAsUser // null' "$task_file")
    
    if [ "$run_as_user" == "1001" ]; then
        log "  ✓ Has required runAsUser: 1001 in stepTemplate"
        has_security_context=true
    else
        log "  ✗ Missing or incorrect runAsUser in stepTemplate.securityContext (image: $problematic_image)"
        log "    Expected: runAsUser: 1001"
        log "    Found: $run_as_user"
        exit_code=1
        # Set global variable for main function to access
        CURRENT_PROBLEMATIC_IMAGE="$problematic_image"
    fi

    return $exit_code
}

# Global variable to store current problematic image
CURRENT_PROBLEMATIC_IMAGE=""

# Main function
main() {
    local overall_exit_code=0
    local task_count=0
    local failed_tasks=0
    local failed_task_files=()
    local failed_task_images=()
    local skipped_files=0

    log "Processing files from CHANGED_FILES..."
    log "Looking for Tekton tasks using Trusted Artifacts (with ociStorage parameter) and"
    log "non-release-service-utils (quay.io/konflux-ci/release-service-utils) images..."
    log ""

    # Process files from CHANGED_FILES environment variable
    local task_files=()
    for file in $CHANGED_FILES; do
        # Check if file exists
        if [ ! -f "$file" ]; then
            log "Warning: File '$file' not found, skipping"
            skipped_files=$((skipped_files + 1))
            continue
        fi

        # Check if it's a YAML file
        if [[ ! "$file" =~ \.(yaml|yml)$ ]]; then
            log "Skipping non-YAML file: $file"
            skipped_files=$((skipped_files + 1))
            continue
        fi

        # Check if it's a Tekton Task
        local kind
        kind=$(yq e '.kind // ""' "$file" 2>/dev/null || echo "")
        
        if [ "$kind" == "Task" ]; then
            task_files+=("$file")
        else
            log "Skipping non-Task file: $file (kind: ${kind:-'unknown'})"
            skipped_files=$((skipped_files + 1))
        fi
    done
    
    # Process each task file
    for task_file in "${task_files[@]}"; do
        task_count=$((task_count + 1))
        
        # Reset global variable before each check
        CURRENT_PROBLEMATIC_IMAGE=""
        
        if ! check_task_security "$task_file"; then
            failed_tasks=$((failed_tasks + 1))
            overall_exit_code=1
            # Store full file path and problematic image for summary
            failed_task_files+=("$task_file")
            failed_task_images+=("$CURRENT_PROBLEMATIC_IMAGE")
        fi
        log ""
    done

    # Summary
    log "=========================================="
    log "Scan Summary:"
    log "  Files processed: $((task_count + skipped_files))"
    log "  Files skipped: $skipped_files"
    log "  Tekton tasks found: $task_count"
    
            if [ $failed_tasks -eq 0 ]; then
            log "  ✓ All tasks are compliant"
            log ""
            log "SUCCESS: All Trusted Artifacts tasks using non-release-service-utils images have proper security context"
        else
            log "  ✗ Failed tasks: $failed_tasks"
            log ""
            log "Failed tasks:"
            for i in "${!failed_task_files[@]}"; do
                log "  - ${failed_task_files[$i]} (image: ${failed_task_images[$i]})"
            done
            log ""
            log "FAILURE: Some Trusted Artifacts tasks using non-release-service-utils images are missing required security context"
            log ""
            log "To fix failing tasks, add the following to their stepTemplate:"
            log ""
            log "  stepTemplate:"
            log "    securityContext:"
            log "      runAsUser: 1001"
        fi

    exit $overall_exit_code
}

# Check environment variable
if [ -z "${CHANGED_FILES:-}" ]; then
    log "Error: CHANGED_FILES environment variable is not set or empty"
    usage
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    log "Error: yq is required but not installed"
    log "Please install yq: https://github.com/mikefarah/yq"
    exit 1
fi

# Execute main function
main 
