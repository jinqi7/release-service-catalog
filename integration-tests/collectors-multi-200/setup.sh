#!/usr/bin/env bash
#
# Setup script for collectors-multi-200 test suite
# This script helps prepare the test environment
#

set -eo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TOTAL_COMPONENTS=${TOTAL_COMPONENTS:-200}

echo "=========================================="
echo "Collectors Multi-200 Test Setup"
echo "=========================================="
echo ""

# Step 1: Generate component definitions
echo "Step 1: Generating ${TOTAL_COMPONENTS} component definitions..."
cd "${SCRIPT_DIR}/resources/tenant"
export TOTAL_COMPONENTS
./generate-components.sh

if [ $? -eq 0 ]; then
    echo "✅ Component definitions generated successfully"
else
    echo "🔴 Failed to generate component definitions"
    exit 1
fi

# Step 2: Verify generation
echo ""
echo "Step 2: Verifying component file count..."
COMPONENT_COUNT=$(ls -1 component*.yaml 2>/dev/null | wc -l)
if [ "$COMPONENT_COUNT" -eq "$TOTAL_COMPONENTS" ]; then
    echo "✅ Found $COMPONENT_COUNT component files (expected $TOTAL_COMPONENTS)"
else
    echo "🔴 Component count mismatch: found $COMPONENT_COUNT, expected $TOTAL_COMPONENTS"
    exit 1
fi

# Step 3: Check kustomization
echo ""
echo "Step 3: Verifying kustomization.yaml..."
KUSTOMIZE_COUNT=$(grep -c "component.*\.yaml" kustomization.yaml || echo "0")
if [ "$KUSTOMIZE_COUNT" -eq "$TOTAL_COMPONENTS" ]; then
    echo "✅ Kustomization includes all $TOTAL_COMPONENTS components"
else
    echo "🔴 Kustomization mismatch: includes $KUSTOMIZE_COUNT, expected $TOTAL_COMPONENTS"
    exit 1
fi

cd "${SCRIPT_DIR}"

# Step 4: Check vault secrets
echo ""
echo "Step 4: Checking vault secrets..."
SECRETS_READY=true

if [ ! -f "vault/tenant-secrets.yaml" ]; then
    echo "⚠️  vault/tenant-secrets.yaml not found"
    echo "   Please copy vault/tenant-secrets.yaml.template and fill in actual values"
    SECRETS_READY=false
fi

if [ ! -f "vault/managed-secrets.yaml" ]; then
    echo "⚠️  vault/managed-secrets.yaml not found"
    echo "   Please copy vault/managed-secrets.yaml.template and fill in actual values"
    SECRETS_READY=false
fi

if [ "$SECRETS_READY" = true ]; then
    # Check if secrets are encrypted
    if head -1 vault/tenant-secrets.yaml | grep -q "^\$ANSIBLE_VAULT"; then
        echo "✅ vault/tenant-secrets.yaml is encrypted"
    else
        echo "⚠️  vault/tenant-secrets.yaml exists but is NOT encrypted"
        echo "   Run: ansible-vault encrypt vault/tenant-secrets.yaml --vault-password-file <path>"
    fi

    if head -1 vault/managed-secrets.yaml | grep -q "^\$ANSIBLE_VAULT"; then
        echo "✅ vault/managed-secrets.yaml is encrypted"
    else
        echo "⚠️  vault/managed-secrets.yaml exists but is NOT encrypted"
        echo "   Run: ansible-vault encrypt vault/managed-secrets.yaml --vault-password-file <path>"
    fi
fi

# Step 5: Environment variable check
echo ""
echo "Step 5: Checking required environment variables..."
VARS_OK=true

if [ -z "$GITHUB_TOKEN" ]; then
    echo "⚠️  GITHUB_TOKEN not set"
    VARS_OK=false
fi

if [ -z "$VAULT_PASSWORD_FILE" ]; then
    echo "⚠️  VAULT_PASSWORD_FILE not set"
    VARS_OK=false
fi

if [ -z "$RELEASE_CATALOG_GIT_URL" ]; then
    echo "⚠️  RELEASE_CATALOG_GIT_URL not set"
    VARS_OK=false
fi

if [ -z "$RELEASE_CATALOG_GIT_REVISION" ]; then
    echo "⚠️  RELEASE_CATALOG_GIT_REVISION not set"
    VARS_OK=false
fi

if [ "$VARS_OK" = true ]; then
    echo "✅ All required environment variables are set"
fi

# Summary
echo ""
echo "=========================================="
echo "Setup Summary"
echo "=========================================="
echo "Total components: ${TOTAL_COMPONENTS}"
echo "Component files: ${COMPONENT_COUNT}"
echo "Kustomization entries: ${KUSTOMIZE_COUNT}"
echo ""

if [ "$SECRETS_READY" = true ] && [ "$VARS_OK" = true ]; then
    echo "✅ Setup complete! You can now run the test:"
    echo ""
    echo "   cd .."
    echo "   ./run-test.sh collectors-multi-200"
    echo ""
else
    echo "⚠️  Setup incomplete. Please address the warnings above."
    echo ""
    echo "Next steps:"
    if [ "$SECRETS_READY" = false ]; then
        echo "  1. Setup vault secrets (see vault/README.md)"
    fi
    if [ "$VARS_OK" = false ]; then
        echo "  2. Export required environment variables"
    fi
    echo ""
    exit 1
fi
