#!/usr/bin/env bash
set -x

# INJECTED TEST SETUP - Create test data in workspace (first task mode)
echo "Setting up test data in workspace for testing..."
cat > "$(workspaces.data.path)"/data.json << EOF
{
  "ootsign": {
    "signing-secret": "my-secret",
    "checksumFingerprint": "my-fprint",
    "checksumKeytab": "my-keytab",
    "kmodsPath": "my-kmods",
    "vendor": "my-vendor",
    "artifact-repo-url": "my-artifact-url",
    "artifact-branch": "my-artifact-branch",
    "artifact-repo-token": "my-artifact-repo-token"
  }
}
EOF
cat > "$(workspaces.data.path)"/snapshot.json << EOF
{
  "application": "my-signing-app",
  "components": [
    {
      "name": "comp",
      "containerImage": "registry.io/image:tag"
    }
  ]
}
EOF
echo "Test data setup complete in workspace:"
ls -la "$(workspaces.data.path)"

# ORIGINAL TASK LOGIC STARTS HERE 