# Vault Secrets

This directory contains encrypted secret files for the collectors-multi-200 test suite.

## Setup Instructions

1. **Copy the templates:**
   ```bash
   cp tenant-secrets.yaml.template tenant-secrets.yaml
   cp managed-secrets.yaml.template managed-secrets.yaml
   ```

2. **Fill in the actual secret values:**
   - Edit `tenant-secrets.yaml` and replace all `CHANGE_ME_*` placeholders with actual values
   - Edit `managed-secrets.yaml` and replace all `CHANGE_ME_*` placeholders with actual values

3. **Encrypt the secrets:**
   ```bash
   ansible-vault encrypt vault/tenant-secrets.yaml --vault-password-file /path/to/vault-password-file
   ansible-vault encrypt vault/managed-secrets.yaml --vault-password-file /path/to/vault-password-file
   ```

## Required Secrets

### Tenant Secrets
- **pipelines-as-code-secret**: GitHub personal access token for Pipelines as Code integration
- **jira-collectors-secret**: JIRA API token for collector integration

### Managed Secrets
- **push**: Container registry credentials (quay.io or other registry)
- **pyxis**: Pyxis API client certificate and key
- **atlas-staging-sso-secret**: Atlas SSO client credentials
- **atlas-retry-s3-staging-secret**: AWS S3 credentials for Atlas retry mechanism
- **konflux-cosign-signing-stage**: Cosign key pair and password for image signing
- **konflux-ci-konflux-release-trusted-artifacts-pull-secret**: Container pull secret for trusted artifacts

## Security Notes

- Never commit unencrypted secret files to git
- Always verify files are encrypted before committing:
  ```bash
  head -1 vault/tenant-secrets.yaml  # Should show $ANSIBLE_VAULT;...
  head -1 vault/managed-secrets.yaml # Should show $ANSIBLE_VAULT;...
  ```
- The vault password file should be stored securely and never committed to git
