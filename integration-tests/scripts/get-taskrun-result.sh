#!/usr/bin/env bash

#
# get-taskrun-result.sh
#
# Extract a result value from a TaskRun within a Tekton PipelineRun
#
# This script finds the TaskRun for a specified task in a PipelineRun
# and extracts the value of a specified result from that TaskRun.
#

set -euo pipefail

# Function to log messages to stderr
log() {
    echo "$@" >&2
}

# Function to display usage
usage() {
    log "Usage: $0 <pipelinerun-name> [task-name] [result-name] [namespace]"
    log "  pipelinerun-name: Name of the PipelineRun CR"
    log "  task-name: Name of the task in Pipeline"
    log "  result-name: Name of the result to extract"
    log "  namespace: Kubernetes namespace (default: current namespace)"
    log ""
    log "Example: $0 my-pipeline-run-abc123 create-pyxis-image sourceDataArtifacts my-namespace"
    exit 1
}

# Check if at least one argument is provided
if [ $# -lt 3 ]; then
    usage
fi

# Parse arguments
PLR_NAME="$1"
TASK_NAME="$2"
RESULT_NAME="$3"
NAMESPACE="${4:-}"

# Set namespace flag if provided
NS_FLAG=""
if [ -n "$NAMESPACE" ]; then
    NS_FLAG="-n $NAMESPACE"
fi

log "Looking for result '$RESULT_NAME' from task '$TASK_NAME' in PipelineRun '$PLR_NAME'"

# Get the PipelineRun and find the TaskRun for the specified task
TASKRUN_NAME=$(kubectl get pipelinerun "$PLR_NAME" $NS_FLAG -o json | \
    jq -r --arg task_name "$TASK_NAME" '
        .status.childReferences[]? // .status.taskRuns // empty |
        select(.pipelineTaskName == $task_name) | .name
    ')

# Check if TaskRun was found
if [ -z "$TASKRUN_NAME" ]; then
    log "Error: Could not find TaskRun for task '$TASK_NAME' in PipelineRun '$PLR_NAME'"
    exit 1
fi

log "Found TaskRun: $TASKRUN_NAME"

# Get the result value from the TaskRun
log "Extracting result '$RESULT_NAME'..."
RESULT_VALUE=$(kubectl get taskrun "$TASKRUN_NAME" $NS_FLAG -o json | \
    jq -r --arg result_name "$RESULT_NAME" '
        .status.results[]? | select(.name == $result_name) | .value
    ')

# Check if result was found
if [ -z "$RESULT_VALUE" ] || [ "$RESULT_VALUE" == "null" ]; then
    log "Error: Could not find result '$RESULT_NAME' in TaskRun '$TASKRUN_NAME'"
    log "Available results:"
    kubectl get taskrun "$TASKRUN_NAME" $NS_FLAG -o json | \
        jq -r '.status.results[]? | "  - " + .name' >&2
    exit 1
fi

log "✅️ Found result '$RESULT_NAME' value: $RESULT_VALUE"

# Output just the value (useful for piping to other commands)
echo "$RESULT_VALUE"
