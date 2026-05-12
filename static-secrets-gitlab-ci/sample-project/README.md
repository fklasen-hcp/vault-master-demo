# Vault Secrets Demo - GitLab CI/CD Pipeline

This is a sample GitLab project that demonstrates how to consume secrets from HashiCorp Vault in a CI/CD pipeline using the Vault Secrets Operator (VSO).

## Overview

This pipeline showcases:
- **Vault Secrets Operator** syncing secrets from Vault to Kubernetes
- **GitLab Runner** (Kubernetes executor) mounting secrets as environment variables
- **Live secret updates** - change secrets in Vault and see them reflected in pipeline runs

## Architecture

```
Vault (vso-demo-kv/webapp/config)
    ↓
VSO syncs to Kubernetes Secret (secretkv)
    ↓
GitLab Runner mounts secret
    ↓
Pipeline reads environment variables
```

## How to Use

### 1. Initial Pipeline Run

1. Navigate to **CI/CD → Pipelines** in GitLab
2. Click **Run Pipeline**
3. Observe the secret values in the job output

Expected output:
```
Username from Vault: static-user
Password from Vault: static-password
```

### 2. Test Secret Updates

1. Update the secret in Vault:
   ```bash
   vault kv put vso-demo-kv/webapp/config \
     username="updated-user" \
     password="updated-pass"
   ```

2. Wait 30 seconds for VSO to sync the secret

3. Re-run the pipeline in GitLab

4. Observe the updated values

## Configuration

### Vault Path
- **Engine**: `vso-demo-kv` (KV v2)
- **Path**: `webapp/config`
- **Keys**: `username`, `password`

### Kubernetes Secret
- **Namespace**: `gitlab-demo`
- **Name**: `secretkv`
- **Sync Interval**: 30 seconds

### VSO Resources
- **VaultAuth**: `gitlab-auth`
- **VaultStaticSecret**: `gitlab-kv-secret`

## Troubleshooting

### Secrets Not Appearing

Check if VSO has synced the secret:
```bash
kubectl get secret secretkv -n gitlab-demo
kubectl describe vaultstaticsecret gitlab-kv-secret -n gitlab-demo
```

### Pipeline Fails

Check runner logs:
```bash
kubectl logs -n gitlab-demo -l app=gitlab-runner
```

## Security Notes

⚠️ **Demo Configuration**: This pipeline displays secrets in plain text for demonstration purposes.

In production:
- Use secret masking in GitLab
- Avoid echoing secrets to logs
- Use Vault Agent Injector for direct Vault integration

---

**Made with Bob** 🤖