#!/usr/bin/env bash

#TASK_PATH="$1"
#SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Add mocks to the beginning of task step script
#yq -i '.spec.steps[0].script = load_str("'$SCRIPT_DIR'/mocks.sh") + .spec.steps[0].script' "$TASK_PATH"



#!/usr/bin/env bash

TASK_PATH="$1"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Add mocks to the beginning of the extract-kmods step script
# The extract-kmods step is step[2] in the trusted artifacts structure
yq -i '.spec.steps[2].script = load_str("'$SCRIPT_DIR'/mocks.sh") + .spec.steps[2].script' "$TASK_PATH"
