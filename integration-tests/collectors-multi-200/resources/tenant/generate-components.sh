#!/usr/bin/env bash
#
# Script to generate component YAML files for 200+ components
# This is executed during test setup to create all component definitions
#

set -eo pipefail

# Get the total number of components from environment or default to 200
TOTAL_COMPONENTS=${TOTAL_COMPONENTS:-200}
OUTPUT_DIR=${OUTPUT_DIR:-$(dirname "$0")}

echo "Generating ${TOTAL_COMPONENTS} component definitions..."

# Generate component 1 (primary component)
cat > "${OUTPUT_DIR}/component1.yaml" <<EOF
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  annotations:
    git-provider: github
    build.appstudio.openshift.io/request: configure-pac
    image.redhat.com/generate: '{"visibility": "public"}'
    build.appstudio.openshift.io/pipeline: '{"name": "docker-build-multi-platform-oci-ta", "bundle": "latest"}'
  name: \${component_name}
  labels:
    originating-tool: "\${originating_tool}"
spec:
  application: \${application_name}
  componentName: \${component_name}
  secret: pipelines-as-code-secret-\${component_name}
  source:
    git:
      dockerfileUrl: Dockerfile
      revision: \${component_branch}
      url: "\${component_git_url}"
EOF

# Generate components 2 through TOTAL_COMPONENTS
for i in $(seq 2 ${TOTAL_COMPONENTS}); do
  cat > "${OUTPUT_DIR}/component${i}.yaml" <<EOF
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  annotations:
    git-provider: github
    build.appstudio.openshift.io/request: configure-pac
    image.redhat.com/generate: '{"visibility": "public"}'
    build.appstudio.openshift.io/pipeline: '{"name": "docker-build-multi-platform-oci-ta", "bundle": "latest"}'
  name: \${component${i}_name}
  labels:
    originating-tool: "\${originating_tool}"
spec:
  application: \${application_name}
  componentName: \${component${i}_name}
  secret: pipelines-as-code-secret-\${component_name}
  source:
    git:
      dockerfileUrl: Dockerfile
      revision: \${component${i}_branch}
      url: "\${component${i}_git_url}"
EOF
done

# Generate kustomization.yaml
cat > "${OUTPUT_DIR}/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${tenant_namespace}
resources:
  - application.yaml
  - sa.yaml
  - sa-rolebinding.yaml
  - rp.yaml
  - secrets/tenant-secrets.yaml
EOF

# Add all component files to kustomization
for i in $(seq 1 ${TOTAL_COMPONENTS}); do
  echo "  - component${i}.yaml" >> "${OUTPUT_DIR}/kustomization.yaml"
done

echo "✅ Generated ${TOTAL_COMPONENTS} component YAML files and kustomization.yaml"
