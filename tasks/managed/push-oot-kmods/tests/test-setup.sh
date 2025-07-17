#!/usr/bin/env bash
set -x

# INJECTED TEST SETUP - Create test data for push-oot-kmods task
echo "Setting up test data for push-oot-kmods task..."

# Create the signed kmods directory and dummy modules in dataDir for trusted artifacts mode
echo "Creating dummy signed kmods and envfile in dataDir..."
mkdir -p "$(params.dataDir)/$(params.signedKmodsPath)/"
echo "SIGNED_MODULE1" > "$(params.dataDir)/$(params.signedKmodsPath)/mod1.ko"
echo "SIGNED_MODULE2" > "$(params.dataDir)/$(params.signedKmodsPath)/mod2.ko"

# Create envfile with mock environment variables
cat > "$(params.dataDir)/$(params.signedKmodsPath)/envfile" << EOF
DRIVER_VENDOR="$(params.vendor)"
DRIVER_VERSION="1.0.0"
KERNEL_VERSION="5.14.0"
EOF

# Also create mocked-envfile for the check-result task (won't be removed by main script)
cat > "$(params.dataDir)/$(params.signedKmodsPath)/mocked-envfile" << EOF
DRIVER_VENDOR="$(params.vendor)"
DRIVER_VERSION="1.0.0"
KERNEL_VERSION="5.14.0"
EOF

# Also create in workspace when trusted artifacts are skipped
if [ -d "$(workspaces.signed-kmods.path)" ]; then
    echo "Also creating dummy signed kmods in workspace for workspace mode..."
    mkdir -p "$(workspaces.signed-kmods.path)/$(params.signedKmodsPath)/"
    echo "SIGNED_MODULE1" > "$(workspaces.signed-kmods.path)/$(params.signedKmodsPath)/mod1.ko"
    echo "SIGNED_MODULE2" > "$(workspaces.signed-kmods.path)/$(params.signedKmodsPath)/mod2.ko"
    
    # Create envfile in workspace too
    cat > "$(workspaces.signed-kmods.path)/$(params.signedKmodsPath)/envfile" << EOF
DRIVER_VENDOR="$(params.vendor)"
DRIVER_VERSION="1.0.0"
KERNEL_VERSION="5.14.0"
EOF
    
    # Also create mocked-envfile for the check-result task
    cat > "$(workspaces.signed-kmods.path)/$(params.signedKmodsPath)/mocked-envfile" << EOF
DRIVER_VENDOR="$(params.vendor)"
DRIVER_VERSION="1.0.0"
KERNEL_VERSION="5.14.0"
EOF
fi

echo "Test data setup complete:"
echo "DataDir contents:"
ls -la "$(params.dataDir)" || echo "dataDir does not exist"
if [ -d "$(params.dataDir)/$(params.signedKmodsPath)" ]; then
    ls -la "$(params.dataDir)/$(params.signedKmodsPath)"
fi
echo "Workspace contents:"
ls -la "$(workspaces.signed-kmods.path)" || echo "workspace does not exist"
if [ -d "$(workspaces.signed-kmods.path)/$(params.signedKmodsPath)" ]; then
    ls -la "$(workspaces.signed-kmods.path)/$(params.signedKmodsPath)"
fi

# ORIGINAL TASK LOGIC STARTS HERE 