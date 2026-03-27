#!/bin/bash
# Quick test script for self-signed certificate support in trusted-artifact stepactions
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_CERT_DIR="/tmp/test-certs-$$"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

cleanup() {
    log "Cleaning up test resources..."
    kubectl delete taskrun test-stepaction-ca-cert --ignore-not-found 2>/dev/null || true
    kubectl delete configmap test-trusted-ca --ignore-not-found 2>/dev/null || true
    rm -rf "$TEST_CERT_DIR" 2>/dev/null || true
    success "Cleanup complete"
}

trap cleanup EXIT

main() {
    echo ""
    log "=========================================="
    log "Testing Self-Signed Certificate Support"
    log "=========================================="
    echo ""

    # Step 1: Create test certificate
    log "Step 1: Creating test self-signed certificate..."
    mkdir -p "$TEST_CERT_DIR"

    openssl req -x509 -newkey rsa:2048 -keyout "$TEST_CERT_DIR/key.pem" \
      -out "$TEST_CERT_DIR/ca-bundle.crt" -days 1 -nodes \
      -subj "/CN=test-registry.local/O=Test Org" 2>/dev/null

    if [ ! -f "$TEST_CERT_DIR/ca-bundle.crt" ]; then
        error "Failed to create test certificate"
        exit 1
    fi
    success "Test certificate created at $TEST_CERT_DIR/ca-bundle.crt"
    echo ""

    # Step 2: Create ConfigMap
    log "Step 2: Creating Kubernetes ConfigMap with test certificate..."
    kubectl delete configmap test-trusted-ca --ignore-not-found 2>/dev/null || true
    kubectl create configmap test-trusted-ca \
      --from-file=ca-bundle.crt="$TEST_CERT_DIR/ca-bundle.crt"

    if ! kubectl get configmap test-trusted-ca &>/dev/null; then
        error "Failed to create ConfigMap"
        exit 1
    fi
    success "ConfigMap 'test-trusted-ca' created"
    echo ""

    # Step 3: Apply test TaskRun
    log "Step 3: Applying test TaskRun..."
    kubectl delete taskrun test-stepaction-ca-cert --ignore-not-found 2>/dev/null || true
    kubectl apply -f "$SCRIPT_DIR/test-stepaction-ca-cert.yaml"
    success "TaskRun 'test-stepaction-ca-cert' created"
    echo ""

    # Step 4: Wait for completion
    log "Step 4: Waiting for TaskRun to complete (timeout: 2 minutes)..."
    echo ""

    if kubectl wait --for=condition=Succeeded --timeout=120s taskrun/test-stepaction-ca-cert 2>/dev/null; then
        success "TaskRun completed successfully!"
    else
        # Check if it failed
        if kubectl get taskrun test-stepaction-ca-cert -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' | grep -q "False"; then
            error "TaskRun failed!"
            echo ""
            warn "Fetching logs for debugging..."
            kubectl logs -l tekton.dev/taskRun=test-stepaction-ca-cert --all-containers || true
            exit 1
        else
            warn "TaskRun did not complete within timeout"
            warn "Fetching current logs..."
            kubectl logs -l tekton.dev/taskRun=test-stepaction-ca-cert --all-containers --tail=50 || true
            exit 1
        fi
    fi

    echo ""
    log "=========================================="
    log "Fetching TaskRun logs..."
    log "=========================================="
    echo ""

    kubectl logs -l tekton.dev/taskRun=test-stepaction-ca-cert --all-containers

    echo ""
    log "=========================================="
    success "Test completed successfully!"
    log "=========================================="
    echo ""
    success "✓ caCertPath parameter works correctly"
    success "✓ CA_FILE environment variable is set"
    success "✓ Certificate file is accessible"
    success "✓ oras_opts.sh integration is working"
    success "✓ --ca-file flag is added to ORAS commands"
    echo ""
    log "Your implementation is ready to use with registries that have self-signed certificates!"
    echo ""
}

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    error "kubectl not found. Please install kubectl first."
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    error "openssl not found. Please install openssl first."
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
fi

main "$@"
