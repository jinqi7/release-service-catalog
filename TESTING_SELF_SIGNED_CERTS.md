# Testing Self-Signed Certificate Support

This guide explains how to test the self-signed certificate support for trusted-artifact stepactions.

## Option 1: Quick Local Verification (Recommended for Initial Testing)

Test that the `caCertPath` parameter is correctly passed to the stepactions.

### Step 1: Create a Test Certificate

```bash
# Create a dummy self-signed certificate for testing
mkdir -p /tmp/test-certs
openssl req -x509 -newkey rsa:4096 -keyout /tmp/test-certs/key.pem \
  -out /tmp/test-certs/ca-bundle.crt -days 365 -nodes \
  -subj "/CN=test-registry.local"
```

### Step 2: Create a ConfigMap with the Certificate

```bash
kubectl create configmap test-trusted-ca \
  --from-file=ca-bundle.crt=/tmp/test-certs/ca-bundle.crt
```

### Step 3: Create a Simple Test Task

Create a test file `test-stepaction-ca-cert.yaml`:

```yaml
---
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: test-stepaction-ca-cert
spec:
  taskSpec:
    params:
      - name: caCertPath
        type: string
        default: /mnt/trusted-ca/ca-bundle.crt
    volumes:
      - name: trusted-ca
        configMap:
          name: test-trusted-ca
          items:
            - key: ca-bundle.crt
              path: ca-bundle.crt
    stepTemplate:
      volumeMounts:
        - name: trusted-ca
          mountPath: /mnt/trusted-ca
          readOnly: true
    steps:
      - name: verify-ca-file-env
        image: quay.io/redhat-appstudio/build-trusted-artifacts:e02102ede09aa07187cba066ad547a54724e5cf4
        env:
          - name: CA_FILE
            value: $(params.caCertPath)
        script: |
          #!/bin/bash
          set -e

          echo "Testing CA_FILE environment variable support..."

          # Check if CA_FILE is set
          if [ -z "$CA_FILE" ]; then
            echo "ERROR: CA_FILE environment variable is not set"
            exit 1
          fi
          echo "✓ CA_FILE is set to: $CA_FILE"

          # Check if the file exists at the path
          if [ ! -f "$CA_FILE" ]; then
            echo "ERROR: Certificate file does not exist at $CA_FILE"
            exit 1
          fi
          echo "✓ Certificate file exists at $CA_FILE"

          # Verify file is readable
          if ! cat "$CA_FILE" > /dev/null; then
            echo "ERROR: Cannot read certificate file"
            exit 1
          fi
          echo "✓ Certificate file is readable"

          # Show certificate info
          echo "Certificate content (first 5 lines):"
          head -5 "$CA_FILE"

          # Verify oras_opts.sh behavior
          source /oras_opts.sh
          echo "✓ Sourced oras_opts.sh successfully"

          # Check if --ca-file is added to oras_opts
          if [[ " ${oras_opts[@]} " =~ " --ca-file=${CA_FILE} " ]]; then
            echo "✓ SUCCESS: --ca-file=${CA_FILE} was added to oras_opts"
          else
            echo "ERROR: --ca-file was not added to oras_opts"
            echo "oras_opts contents: ${oras_opts[@]}"
            exit 1
          fi

          echo ""
          echo "All checks passed! CA certificate support is working correctly."
```

### Step 4: Run the Test

```bash
kubectl apply -f test-stepaction-ca-cert.yaml

# Watch the test run
kubectl logs -f test-stepaction-ca-cert

# Expected output should show:
# ✓ CA_FILE is set to: /mnt/trusted-ca/ca-bundle.crt
# ✓ Certificate file exists at /mnt/trusted-ca/ca-bundle.crt
# ✓ Certificate file is readable
# ✓ Sourced oras_opts.sh successfully
# ✓ SUCCESS: --ca-file=/mnt/trusted-ca/ca-bundle.crt was added to oras_opts
# All checks passed! CA certificate support is working correctly.
```

### Step 5: Clean Up

```bash
kubectl delete taskrun test-stepaction-ca-cert
kubectl delete configmap test-trusted-ca
rm -rf /tmp/test-certs
```

---

## Option 2: Integration Test with Local Registry

Test with a real OCI registry using self-signed certificates.

### Step 1: Set Up Local Registry with Self-Signed Certificate

```bash
# Create certificates for the registry
mkdir -p /tmp/registry-certs
cd /tmp/registry-certs

# Generate CA key and certificate
openssl req -x509 -newkey rsa:4096 -days 365 -nodes \
  -keyout ca-key.pem -out ca-cert.pem \
  -subj "/CN=Registry CA"

# Generate registry key
openssl genrsa -out registry-key.pem 4096

# Create certificate signing request
openssl req -new -key registry-key.pem -out registry.csr \
  -subj "/CN=registry.local"

# Sign the certificate
cat > registry-cert-ext.cnf << EOF
subjectAltName = DNS:registry.local,DNS:localhost,IP:127.0.0.1
EOF

openssl x509 -req -in registry.csr -CA ca-cert.pem -CAkey ca-key.pem \
  -CAcreateserial -out registry-cert.pem -days 365 \
  -extfile registry-cert-ext.cnf

# Start a local registry with TLS
docker run -d --name registry-tls \
  -p 5443:443 \
  -v /tmp/registry-certs:/certs \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:443 \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry-cert.pem \
  -e REGISTRY_HTTP_TLS_KEY=/certs/registry-key.pem \
  registry:2

# Add to /etc/hosts if needed
echo "127.0.0.1 registry.local" | sudo tee -a /etc/hosts
```

### Step 2: Create Kubernetes Secret and ConfigMap

```bash
# Create auth secret for the registry
kubectl create secret docker-registry registry-creds \
  --docker-server=registry.local:5443 \
  --docker-username=testuser \
  --docker-password=testpass

# Create ConfigMap with CA certificate
kubectl create configmap registry-ca \
  --from-file=ca-bundle.crt=/tmp/registry-certs/ca-cert.pem
```

### Step 3: Test with sign-oot-kmods Task

```bash
# Run the local test for sign-oot-kmods which now uses caCertPath
./scripts/run-local-tests.sh tasks/managed/sign-oot-kmods

# Check the logs to ensure no TLS errors
kubectl logs -l tekton.dev/task=sign-oot-kmods --all-containers
```

### Step 4: Verify Artifacts Were Pushed

```bash
# List artifacts in the registry
curl --cacert /tmp/registry-certs/ca-cert.pem \
  https://registry.local:5443/v2/_catalog

# Verify the artifact was pushed successfully
# (Look for your test artifacts in the catalog)
```

### Step 5: Clean Up

```bash
docker stop registry-tls
docker rm registry-tls
kubectl delete secret registry-creds
kubectl delete configmap registry-ca
rm -rf /tmp/registry-certs
sudo sed -i '/registry.local/d' /etc/hosts
```

---

## Option 3: Test with Existing Task Tests

Verify the implementation doesn't break existing tests.

### Run All Tests for Modified Task

```bash
# Test sign-oot-kmods (which was updated as reference)
./scripts/run-local-tests.sh tasks/managed/sign-oot-kmods

# Check test results
cat test-results/summary.txt
```

### Run Tests for All Tasks Using Trusted Artifacts

```bash
# Find all tasks using trusted artifacts
grep -r "use-trusted-artifact\|create-trusted-artifact" tasks/managed/ -l

# Test them all
./scripts/run-local-tests.sh --parallel 3 tasks/managed/
```

---

## Option 4: Manual Verification with In-Cluster Quay

For testing with an actual in-cluster Quay instance (the real use case):

### Prerequisites

1. In-cluster Quay instance running
2. Quay configured with self-signed certificates
3. Access to Quay's CA certificate

### Steps

```bash
# 1. Extract Quay's CA certificate
kubectl get secret -n quay-enterprise quay-config-bundle \
  -o jsonpath='{.data.ssl\.cert}' | base64 -d > /tmp/quay-ca.crt

# 2. Create ConfigMap with Quay CA
kubectl create configmap quay-trusted-ca \
  --from-file=ca-bundle.crt=/tmp/quay-ca.crt

# 3. Update task parameters to use Quay registry
# Edit your TaskRun to set:
# - ociStorage: quay.cluster.local/myorg/artifacts
# - caTrustConfigMapName: quay-trusted-ca

# 4. Run the task
kubectl apply -f my-taskrun.yaml

# 5. Verify no TLS errors in logs
kubectl logs -f <taskrun-pod>

# Expected: Artifacts pushed/pulled successfully without certificate errors
```

---

## Validation Checklist

After running tests, verify:

- [ ] `CA_FILE` environment variable is set correctly in stepaction containers
- [ ] Certificate file is accessible at the mounted path
- [ ] `oras_opts.sh` adds `--ca-file` flag to ORAS commands
- [ ] No TLS certificate errors in task logs
- [ ] Artifacts are successfully pushed to registry with self-signed certs
- [ ] Artifacts are successfully pulled from registry with self-signed certs
- [ ] Existing tasks without `caCertPath` still work (backward compatibility)
- [ ] Empty `caCertPath` parameter doesn't cause errors

---

## Troubleshooting

### Issue: "certificate signed by unknown authority"

**Cause**: Certificate is not being passed to ORAS or path is incorrect.

**Solution**:
```bash
# Verify ConfigMap exists
kubectl get configmap trusted-ca -o yaml

# Verify volume mount in task
kubectl get taskrun <name> -o yaml | grep -A 5 "volumeMounts"

# Check step parameters
kubectl get taskrun <name> -o yaml | grep -A 3 "caCertPath"
```

### Issue: "CA_FILE environment variable is not set"

**Cause**: `caCertPath` parameter not passed to stepaction.

**Solution**: Ensure task step includes:
```yaml
params:
  - name: caCertPath
    value: /mnt/trusted-ca/ca-bundle.crt
```

### Issue: "no such file or directory"

**Cause**: Certificate not mounted or wrong path.

**Solution**:
```bash
# Check if file exists in the pod
kubectl exec -it <pod-name> -- ls -la /mnt/trusted-ca/

# Verify volume mount path matches parameter path
```

---

## Success Criteria

The implementation is working correctly when:

1. ✅ Stepactions accept `caCertPath` parameter
2. ✅ `CA_FILE` environment variable is set in stepaction containers
3. ✅ ORAS commands include `--ca-file` flag
4. ✅ Artifacts can be pushed/pulled from registries with self-signed certs
5. ✅ No TLS certificate errors in logs
6. ✅ Existing tests pass without modification
7. ✅ Tasks without `caCertPath` continue to work (backward compatibility)
