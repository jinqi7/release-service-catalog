# Collectors Multi-200 Integration Test

## Overview

This test suite validates the Konflux CI Release Service with **200+ components** to ensure the pipeline can handle large-scale releases with proper:
- Scalability testing
- Retry mechanisms for component builds
- Parallel execution control
- Comprehensive error handling
- Progress tracking and reporting

This is based on the standard `collectors` test case but enhanced for high-volume testing.

## Features

### 🚀 Scalability
- Supports 200+ components in a single application
- Configurable component count via `TOTAL_COMPONENTS` environment variable
- Batch processing to manage API rate limits and cluster load

### 🔄 Retry Mechanisms
- **Component Initialization Retry**: Up to 3 attempts per component with configurable delays
- **PR Merge Retry**: GitHub API retry logic with exponential backoff
- **PipelineRun Retry**: Automatic retry of failed builds (up to 2 retries per component)
- **Configurable Timeouts**: Per-stage timeouts for initialization, PLR appearance, and completion

### ⚡ Performance Optimization
- **Parallel Execution**: Configurable max parallel builds (default: 20)
- **Batched Operations**: GitHub API calls batched to avoid rate limits
- **Progress Tracking**: Real-time progress monitoring with percentage completion
- **Intelligent Waiting**: Reduced logging frequency to avoid output spam

### 📊 Monitoring & Reporting
- Real-time progress updates for each stage
- Component-level status tracking
- Detailed summary report at test completion
- Failure tracking with component indices

## Architecture

### Test Components

```
collectors-multi-200/
├── test.env                    # Configuration (200 component definitions)
├── test.sh                     # Main test logic with retry mechanisms
├── resources/
│   ├── tenant/
│   │   ├── generate-components.sh  # Script to generate 200 component YAMLs
│   │   ├── application.yaml
│   │   ├── component1.yaml
│   │   ├── component2.yaml
│   │   ├── ...
│   │   ├── component200.yaml
│   │   ├── rp.yaml
│   │   ├── sa.yaml
│   │   └── sa-rolebinding.yaml
│   └── managed/
│       ├── rpa.yaml
│       ├── sa.yaml
│       ├── sa-rolebinding.yaml
│       └── ec-policy.yaml
└── vault/
    ├── tenant-secrets.yaml (encrypted)
    ├── managed-secrets.yaml (encrypted)
    └── README.md
```

### Execution Flow

1. **Setup Phase**
   - Generate 200 component definitions
   - Decrypt vault secrets
   - Create GitHub repositories/branches (batched, with retry)

2. **Component Initialization Phase**
   - Wait for all 200 components to initialize (parallel, with retry)
   - Extract PR information for each component
   - Progress tracking: N/200 components initialized

3. **PR Merge Phase**
   - Patch component sources (multi-arch, source image build)
   - Merge all PRs (batched, with retry)
   - Progress tracking: N/200 PRs merged

4. **Build Phase**
   - Wait for PipelineRuns to appear (parallel, with timeout)
   - Monitor PipelineRun completion (parallel, with retry on failure)
   - Automatic retry for failed builds
   - Progress tracking: N/200 builds completed

5. **Release Phase**
   - Wait for release creation
   - Verify release contents (collectors, CVE data, SBOMs, etc.)
   - Validate 200-component snapshot

6. **Verification Phase**
   - Check advisory URLs and content
   - Verify SBOM uploads (product + 600 component SBOMs)
   - Validate CVE data collection
   - Verify multi-arch image builds

## Configuration

### Environment Variables (test.env)

| Variable | Default | Description |
|----------|---------|-------------|
| `TOTAL_COMPONENTS` | 200 | Number of components to test |
| `MAX_COMPONENT_RETRIES` | 3 | Retry attempts for component operations |
| `RETRY_DELAY_SECONDS` | 30 | Delay between retry attempts |
| `MAX_PLR_RETRIES` | 2 | PipelineRun retry attempts |
| `PLR_RETRY_DELAY_SECONDS` | 60 | Delay between PLR retries |
| `COMPONENT_INIT_TIMEOUT` | 600 | Component initialization timeout (seconds) |
| `PLR_APPEAR_TIMEOUT` | 600 | PipelineRun appearance timeout (seconds) |
| `PLR_COMPLETE_TIMEOUT` | 2400 | PipelineRun completion timeout (seconds) |
| `RELEASE_TIMEOUT` | 3600 | Release completion timeout (seconds) |
| `MAX_PARALLEL_BUILDS` | 20 | Maximum concurrent component builds |
| `MAX_PARALLEL_RELEASES` | 5 | Maximum concurrent releases |

### Customization

To test with a different number of components:

```bash
export TOTAL_COMPONENTS=500
./run-test.sh collectors-multi-200
```

## Prerequisites

### Required Tools
- `kubectl` with access to Konflux cluster
- `ansible-vault` for secret management
- `kustomize` for resource generation
- `jq`, `yq` for JSON/YAML processing
- `curl` for GitHub API access
- `git` for repository operations

### Required Secrets
See `vault/README.md` for detailed secret setup instructions.

### Required Environment Variables
- `GITHUB_TOKEN`: GitHub personal access token with repo permissions
- `VAULT_PASSWORD_FILE`: Path to Ansible Vault password file
- `RELEASE_CATALOG_GIT_URL`: Git URL for release service catalog
- `RELEASE_CATALOG_GIT_REVISION`: Git revision for release service catalog

## Usage

### Basic Execution

```bash
# Run the full test (200 components)
../run-test.sh collectors-multi-200
```

### With Custom Configuration

```bash
# Test with 500 components
export TOTAL_COMPONENTS=500
export MAX_PARALLEL_BUILDS=30
../run-test.sh collectors-multi-200
```

### Skip Cleanup (for debugging)

```bash
../run-test.sh collectors-multi-200 --skip-cleanup
```

### Without CVE Simulation

```bash
../run-test.sh collectors-multi-200 --no-cve
```

## Setup Instructions

### 1. Generate Component Definitions

Before running the test, generate the component YAML files:

```bash
cd resources/tenant
export TOTAL_COMPONENTS=200
./generate-components.sh
```

This creates:
- `component1.yaml` through `component200.yaml`
- Updated `kustomization.yaml` with all component references

### 2. Configure Secrets

Follow the instructions in `vault/README.md` to:
1. Copy secret templates
2. Fill in actual secret values
3. Encrypt with Ansible Vault

### 3. Verify Setup

```bash
# Check component files were generated
ls -1 resources/tenant/component*.yaml | wc -l
# Should output 200

# Check kustomization includes all components
grep "component.*\.yaml" resources/tenant/kustomization.yaml | wc -l
# Should output 200

# Verify secrets are encrypted
head -1 vault/tenant-secrets.yaml
# Should show: $ANSIBLE_VAULT;...
```

## Monitoring

### Real-Time Progress

The test provides real-time progress updates:

```
[2025-12-22 10:30:15] 📊 Progress: 45/200 (22%) components initialized
[2025-12-22 10:35:20] 📊 Progress: 120/200 (60%) PRs merged
[2025-12-22 11:15:45] 📊 Progress: 180/200 (90%) PipelineRuns completed
```

### Summary Report

At test completion, a summary is generated:

```
==========================================
Test Execution Summary
==========================================
Total components configured: 200
Components initialized: 200
Components built successfully: 200
Total failures: 0
==========================================
```

### Troubleshooting Failed Components

If components fail, check the tracking files:

```bash
# See which components failed initialization
cat ${tmpDir}/component_tracking/failed.txt

# See which PRs failed to merge
cat ${tmpDir}/component_tracking/merge_failed.txt

# See which PipelineRuns failed
cat ${tmpDir}/component_tracking/plr_failed.txt
```

## Performance Considerations

### Cluster Resources

Testing 200 components requires significant cluster resources:
- **CPU**: ~400-600 cores during peak build phase
- **Memory**: ~800-1200 GB during peak build phase
- **Storage**: ~500 GB for container images and artifacts

### Execution Time

Typical execution times:
- **Component Initialization**: ~20-30 minutes (200 components in parallel)
- **PR Merge**: ~10-15 minutes (batched operations)
- **Build Phase**: ~60-90 minutes (20 parallel builds at a time)
- **Release Phase**: ~30-45 minutes
- **Total**: ~2.5-3 hours for 200 components

### API Rate Limits

To avoid GitHub API rate limits:
- Operations are batched (default: 10 per batch)
- 2-second delay between batches
- Automatic retry with exponential backoff

## Retry Strategy

### Component Operations
1. **GitHub Repository Creation**
   - Retries: 3 attempts
   - Delay: 30 seconds between attempts
   - Failure handling: Exit on persistent failure

2. **Component Initialization**
   - Retries: Implicit (polling for 10 minutes)
   - Delay: 10 seconds between polls
   - Failure handling: Marked as failed, collected at end

3. **PR Merge**
   - Retries: 3 attempts
   - Delay: 30 seconds between attempts
   - Failure handling: Exit on persistent failure

4. **PipelineRun Execution**
   - Retries: 2 automatic retries via component annotation
   - Delay: 60 seconds between retries
   - Failure handling: Component marked as failed

## Verification

The test verifies:

✅ All 200 components initialize successfully
✅ All 200 PRs merge without errors
✅ All 200 builds complete successfully (with retries)
✅ Release contains all 200 components
✅ Advisory data collected correctly
✅ CVE data collected (when enabled)
✅ SBOM data uploaded to Atlas (1 product + 600 component SBOMs)
✅ Multi-arch images built (amd64 + arm64)
✅ Collectors data aggregated correctly

## Known Limitations

1. **Component Naming**: Components use index-based naming (comp1, comp2, ..., comp200)
2. **Same Repository**: All components use branches on the same repository (simplifies PAC configuration)
3. **Sequential Batching**: Some operations are batched sequentially to avoid overwhelming APIs
4. **Resource Intensive**: Requires substantial cluster resources

## Troubleshooting

### Issue: Components fail to initialize

**Symptoms**: Timeout waiting for components to initialize

**Solutions**:
- Check namespace exists: `kubectl get ns ${tenant_namespace}`
- Verify component creation: `kubectl get components -n ${tenant_namespace}`
- Check Pipelines as Code webhook: `kubectl get routes -n openshift-pipelines`
- Increase timeout: `export COMPONENT_INIT_TIMEOUT=1200`

### Issue: PipelineRuns fail repeatedly

**Symptoms**: Multiple components show PLR failures even after retries

**Solutions**:
- Check cluster resources: `kubectl top nodes`
- Verify Tekton installation: `kubectl get pods -n openshift-pipelines`
- Check for resource quotas: `kubectl describe quota -n ${tenant_namespace}`
- Reduce parallel builds: `export MAX_PARALLEL_BUILDS=10`

### Issue: GitHub API rate limit exceeded

**Symptoms**: 403 errors during repository creation or PR operations

**Solutions**:
- Verify GITHUB_TOKEN has sufficient quota
- Increase batch delays: Edit test.sh, increase `sleep 2` to `sleep 5`
- Reduce batch size: Edit test.sh, change `batch_size=10` to `batch_size=5`

### Issue: Out of memory during build phase

**Symptoms**: PipelineRuns fail with OOMKilled

**Solutions**:
- Reduce parallel builds: `export MAX_PARALLEL_BUILDS=10`
- Add node selectors/tolerations to pipeline definitions
- Increase node memory or add more nodes

## Contributing

When modifying this test:

1. **Test incrementally**: Start with smaller component counts (e.g., 10, 50) before testing 200+
2. **Monitor resources**: Watch cluster resources during test execution
3. **Update timeouts**: Adjust timeouts if operations consistently fail
4. **Document changes**: Update this README with any configuration changes

## Related Tests

- `collectors`: Base test with single component
- `fbc-release`: FBC catalog testing with multi-component support
- `multi_e2e`: Multi-component FBC testing with intelligent test matrix

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review test logs in `${tmpDir}/component_tracking/`
3. Check PipelineRun logs: `kubectl logs -n ${tenant_namespace} <plr-name>`
4. File an issue in the release-service-catalog repository
