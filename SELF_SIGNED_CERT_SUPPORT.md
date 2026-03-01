# Self-Signed Certificate Support for Trusted Artifacts

## Summary

This implementation adds self-signed certificate support to all trusted-artifact stepactions, enabling tasks to push/pull artifacts from OCI registries (like in-cluster Quay) that use self-signed certificates.

## Changes Made

### Updated StepActions (4 files)

All four trusted-artifact stepactions now support self-signed certificates:

1. `stepactions/use-trusted-artifact/use-trusted-artifact.yaml`
2. `stepactions/use-trusted-artifact-array/use-trusted-artifact-array.yaml`
3. `stepactions/create-trusted-artifact/create-trusted-artifact.yaml`
4. `stepactions/create-trusted-artifact-array/create-trusted-artifact-array.yaml`

**New Parameter Added:**
```yaml
- name: caCertPath
  type: string
  default: ""
  description: Path to CA certificate bundle for TLS verification with self-signed certificates
```

**Environment Variable Set:**
```yaml
- name: CA_FILE
  value: $(params.caCertPath)
```

### How It Works

The `build-trusted-artifacts` image (used by all stepactions) includes built-in support for the `CA_FILE` environment variable:

```bash
# From build-trusted-artifacts/oras_opts.sh
if [[ -v CA_FILE ]]; then
    oras_opts+=(--ca-file=${CA_FILE})
fi
```

When `caCertPath` parameter is provided, it sets `CA_FILE`, which automatically adds `--ca-file` to all ORAS commands.

## Usage Example

### Task Configuration

Tasks that already mount CA certificates via ConfigMap can now pass the certificate path to stepactions:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: my-task
spec:
  params:
    - name: caTrustConfigMapName
      type: string
      default: trusted-ca
    - name: caTrustConfigMapKey
      type: string
      default: ca-bundle.crt

  volumes:
    - name: trusted-ca
      configMap:
        name: $(params.caTrustConfigMapName)
        items:
          - key: $(params.caTrustConfigMapKey)
            path: ca-bundle.crt
        optional: true

  stepTemplate:
    volumeMounts:
      - name: trusted-ca
        mountPath: /mnt/trusted-ca
        readOnly: true

  steps:
    - name: use-trusted-artifact
      ref:
        name: use-trusted-artifact
      params:
        - name: workDir
          value: /workspace/data
        - name: sourceDataArtifact
          value: $(params.artifact)
        - name: caCertPath
          value: /mnt/trusted-ca/ca-bundle.crt  # ✓ Enable self-signed cert support

    - name: create-trusted-artifact
      ref:
        name: create-trusted-artifact
      params:
        - name: ociStorage
          value: quay.local/myorg/artifacts  # In-cluster Quay with self-signed cert
        - name: workDir
          value: /workspace/output
        - name: sourceDataArtifact
          value: $(results.artifact.path)
        - name: caCertPath
          value: /mnt/trusted-ca/ca-bundle.crt  # ✓ Enable self-signed cert support
```

### Reference Implementation

See `tasks/managed/sign-oot-kmods/sign-oot-kmods.yaml` for a complete working example.

## Backward Compatibility

- **Fully backward compatible** - the `caCertPath` parameter has an empty default value
- Tasks that don't need self-signed certificate support can omit the parameter
- Existing tasks continue to work without modification

## Benefits

1. **Secure** - Uses proper certificate trust instead of `--insecure` flag
2. **Simple** - Only requires passing the certificate path parameter
3. **Standard** - Follows OCI/ORAS best practices for certificate handling
4. **Flexible** - Works with any ConfigMap-mounted CA bundle

## Testing

To test with an in-cluster Quay registry:

1. Create a ConfigMap with your Quay's CA certificate:
   ```bash
   kubectl create configmap trusted-ca \
     --from-file=ca-bundle.crt=/path/to/quay-ca.crt
   ```

2. Use tasks with the updated stepactions, passing `caCertPath` parameter

3. Verify artifacts are pushed/pulled successfully without TLS errors

## Related

- **Issue**: Trusted artifacts cannot be written to repositories using self-signed certificates
- **Use Case**: Red Hat Summit demo requiring in-cluster Quay repo
- **Upstream**: `build-trusted-artifacts` image already supports `CA_FILE` environment variable
