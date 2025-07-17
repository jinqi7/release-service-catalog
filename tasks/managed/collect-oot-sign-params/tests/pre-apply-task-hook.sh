#!/usr/bin/env bash

# This script modifies the task to inject test data setup for testing

TASK_PATH="$1"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo "Updating collect-oot-sign-params task with test setup logic"

# Add test setup script to the beginning of the collect-oot-sign-params step script
yq -i '.spec.steps[] |= select(.name == "collect-oot-sign-params").script = load_str("'$SCRIPT_DIR'/test-setup.sh") + .script' "$TASK_PATH"

 