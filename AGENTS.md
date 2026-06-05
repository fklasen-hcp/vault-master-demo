# AI Agent Guide for Vault Demo Project

This document provides guidance for AI assistants (like Claude, ChatGPT, etc.) working on this Vault demonstration project. It ensures consistency, quality, and awareness of project standards.

## 📋 Essential Files to Review First

Before making any changes, **ALWAYS** review these files:

1. **DESIGN_SYSTEM.md** - UI/UX standards, colors, typography, component patterns
2. **README.md** - Project overview, demo descriptions, setup instructions
3. **Makefile** - Available commands, deployment targets, port mappings
4. **CHANGELOG.md** - Project change history (UPDATE THIS when making changes!)
5. **This file (AGENTS.md)** - Project guidelines and best practices

## 🎨 Design System Compliance

### Before Creating/Modifying Any UI:

1. **Read DESIGN_SYSTEM.md completely** - It defines all visual standards
2. **Compare with existing demos** - Check `encryption-secrets/app-simple.py` or `dynamic-secrets/app-deployment.yaml` for reference implementations
3. **Key Design Rules:**
   - Use `zoom: 0.8` on body element
   - Include Vault logo background watermark (opacity 0.08)
   - H1 titles are WHITE (#FFFFFF), not yellow
   - H2 section titles are WHITE with GRAY borders (#333333)
   - No emojis in UI
   - Remove "Demo" from titles (e.g., "Vault Control Groups" not "Vault Control Groups Demo")
   - No subtitles in header section
   - Yellow (#FFD814) is for labels, buttons, and accents only

### Common Mistakes to Avoid:

❌ Yellow H1/H2 titles (should be white)  
❌ Yellow borders on H2 (should be gray #333333)  
❌ Missing Vault logo background  
❌ Missing `zoom: 0.8`  
❌ Using emojis in section titles  
❌ Including "Demo" in page titles
❌ Adding subtitles in header

## 🚨 CRITICAL: No Manual Fixes

**NEVER apply manual fixes during development or troubleshooting!**

All fixes, configurations, and changes MUST be added to the appropriate setup scripts or deployment files. This ensures:
- Changes persist across clean deployments
- Other developers can reproduce the setup
- The project remains maintainable
- Documentation stays accurate

### Examples of Manual Fixes to AVOID:
❌ Running `kubectl create` commands manually
❌ Running `vault write` commands manually
❌ Editing files inside running containers
❌ Creating resources without updating scripts
❌ Fixing permissions manually

### Instead, DO THIS:
✅ Add commands to setup scripts in `scripts/setup/`
✅ Update deployment YAML files
✅ Update Makefile targets
✅ Update cleanup scripts in `scripts/cleanup/`
✅ Document changes in CHANGELOG.md

**If you discover a fix during troubleshooting, immediately add it to the appropriate script before moving on.**

## 🚨 CRITICAL: Don't Assume - Investigate and Verify

**NEVER make assumptions about root causes without verification!**

When troubleshooting issues:
- ❌ Don't assume what the problem is
- ❌ Don't jump to conclusions based on symptoms
- ❌ Don't apply fixes without understanding the root cause
- ✅ Investigate systematically
- ✅ Verify each hypothesis with evidence
- ✅ Check logs, status, and actual behavior
- ✅ Test assumptions before implementing fixes

### Example:
If logs are empty:
1. ❌ DON'T assume: "The filter must be wrong"
2. ✅ DO verify: Check if the log file has recent entries
3. ✅ DO verify: Check if the file is accessible
4. ✅ DO verify: Check if there are any errors in the application logs
5. ✅ DO verify: Test the filter logic with actual data

**Only implement fixes after you've verified the actual root cause.**

## 🚨 CRITICAL: Updating Docker Images in Kubernetes

### The Problem
When using `imagePullPolicy: Never` (for local development with Minikube), Kubernetes will NOT pull updated images even after rebuilding them. This causes pods to run old code even though you've made changes.

### Symptoms
- Code changes don't appear in running pods
- `kubectl exec` shows old code in the container
- Rebuilding Docker image and deleting pods doesn't help
- Docker build uses cached layers

### The Solution
**ALWAYS use this workflow when updating application code:**

```bash
# 1. Build the Docker image (use --no-cache if needed)
cd <demo-directory>
docker build -t <image-name>:latest .

# 2. Load image into Minikube
minikube image load <image-name>:latest

# 3. DELETE AND REAPPLY the deployment (not just delete the pod!)
kubectl delete -f deployment.yaml
sleep 2
kubectl apply -f deployment.yaml
```

### Why This Works
- Deleting the deployment removes the pod AND the deployment spec
- Reapplying creates a fresh deployment that pulls the latest image from Minikube's cache
- Just deleting the pod keeps the old deployment spec, which may reference cached image layers

### Example
```bash
# Update agentic AI demo UI
cd agentic-ai-demo/ui
docker build -t agentic-ui:latest .
minikube image load agentic-ui:latest
kubectl delete -f deployment.yaml
sleep 2
kubectl apply -f deployment.yaml
```

### Verification
Always verify the deployed code matches your changes:
```bash
kubectl exec -n <namespace> <pod-name> -- cat /app/<file>.py | grep "<unique-code-snippet>"
```


## 🏗️ Project Structure

```
master-demo/
├── AGENTS.md                    # This file - AI assistant guide
├── CHANGELOG.md                 # Project change history (UPDATE THIS!)
├── DESIGN_SYSTEM.md             # UI/UX standards (READ FIRST for UI work)
├── README.md                    # Project documentation
├── Makefile                     # All deployment commands
├── audit-monitoring/            # Prometheus + Grafana monitoring
├── control-groups/              # Multi-party authorization demo
├── dynamic-secrets/             # PostgreSQL dynamic credentials
├── encryption-secrets/          # Transit encryption + Transform (FPE)
├── pki-secrets/                 # PKI certificate management
├── static-secrets-gitlab-ci/    # GitLab CI/CD integration
├── scripts/
│   ├── setup/                   # Setup scripts for each demo
│   ├── cleanup/                 # Cleanup scripts
│   └── test/                    # Testing utilities
```

## 🔧 Development Workflow

### When Adding a New Demo:

1. **Plan the architecture** - Review similar demos first
2. **Create directory structure:**
   ```
   new-demo/
   ├── app.py or app-deployment.yaml
   ├── service.yaml
   ├── vault-auth-*.yaml
   └── vault-*-secret.yaml
   ```
3. **Create setup script** in `scripts/setup/setup-<demo>-vault.sh`
4. **Add Makefile targets:**
   - `setup-<demo>-vault`
   - `deploy-<demo>-demo`
   - `<demo>-port-forward`
   - `<demo>-logs`
   - `<demo>-status`
   - `clean-<demo>`
5. **Update `port-forward-all` target** - Add port forward to Makefile's `port-forward-all` target:
   - Add pkill line to kill existing port-forwards
   - Add port-forward command with proper port number
   - Add to the output display section
   - Add to `stop-port-forwards` target
6. **Update cleanup script** - Add to `scripts/cleanup/cleanup-all.sh`
7. **Update README.md** - Add demo documentation and port mapping
8. **Follow DESIGN_SYSTEM.md** - Ensure UI compliance

### When Modifying Existing Code:

1. **Read related files together** - Use multi-file read operations
2. **Check for similar patterns** - Look at other demos for consistency
3. **Test changes** - Verify with user before marking complete
4. **Update documentation** - Keep README.md and comments current
5. **Update CHANGELOG.md** - Add entry in [Unreleased] section describing the change

## 📝 Code Standards

### Python (Flask Apps):

- Use `hvac` library for Vault interactions
- Authenticate via Kubernetes auth method
- Read service account token from `/var/run/secrets/kubernetes.io/serviceaccount/token`
- Use environment variables for configuration
- Follow existing app structure (see `encryption-secrets/app-simple.py`)

### Bash Scripts:

- Include color output (RED, GREEN, YELLOW, BLUE, NC)
- Check for required environment variables
- Provide clear error messages
- Use `set -e` for error handling
- Add descriptive comments

### Kubernetes Manifests:

- Use consistent naming: `<demo>-demo` namespace
- Include ServiceAccount, Role, RoleBinding
- Use ConfigMaps for application code
- Set resource limits
- Follow existing patterns

## 🎯 Vault Configuration Standards

### Namespaces:
- All demos use `master-demo` namespace
- Set via `VAULT_NAMESPACE` environment variable

### Auth Methods:
- Kubernetes auth at `master-demo-auth`
- Roles named: `master-demo-auth-role-<demo>`

### Secrets Engines:
- KV v2: `master-demo-kv`
- Transit: `master-demo-encryption-transit`
- Transform: `master-demo-encryption-transform`
- PKI: `master-demo-pki`
- Database: `master-demo-database`

### Policies:
- Named: `master-demo-policy-<demo>`
- Follow least-privilege principle
- Include clear comments

## 🔍 Common Tasks

### Adding a New Vault Feature:

1. Check if similar feature exists in other demos
2. Create setup script in `scripts/setup/`
3. Add Vault configuration (policies, auth, secrets engine)
4. Create Kubernetes manifests
5. Add Makefile targets
6. Update cleanup script
7. Document in README.md
8. If the change affects authorization flow, cleanup behavior, or demo architecture, update the relevant sections in [README.md](README.md) and ensure [scripts/cleanup/cleanup-all.sh](scripts/cleanup/cleanup-all.sh) and [clean-agentic](Makefile:1067) remain aligned

### Fixing UI Issues:

1. **ALWAYS read DESIGN_SYSTEM.md first**
2. Compare with working demos (encryption, dynamic-secrets)
3. Check for all required elements:
   - Vault logo background
   - Correct colors (white H1/H2, gray borders)
   - Zoom level
   - No emojis
   - Proper title format
4. Test changes before completion

### Debugging:

- Check logs: `make <demo>-logs`
- Check status: `make <demo>-status`
- Port forward: `make <demo>-port-forward`
- Vault logs: `kubectl logs -n vault vault-0`

## 📚 Key Concepts

### Vault Secrets Operator (VSO):
- Manages secrets in Kubernetes
- Uses VaultAuth and VaultStaticSecret/VaultDynamicSecret CRDs
- Syncs secrets to Kubernetes Secrets
- Configured per demo

### Minikube Setup:
- Local Kubernetes cluster
- Vault accessible at `host.minikube.internal:8200`
- Use `VAULT_SKIP_VERIFY=true` for TLS

### Port Mappings:
**Demos (10000+):**
- 10001: Dynamic Secrets (PostgreSQL)
- 10002: PKI Secrets
- 10003: Encryption Secrets
- 10004: Audit Monitoring (Grafana)
- 10005: Control Groups
- 10006: GitLab (if deployed)

**Supporting Services (9999 and below):**
- 8200: Vault Server
- 5432: PostgreSQL (internal)

## ⚠️ Important Notes

### DO:
✅ Read DESIGN_SYSTEM.md before any UI work
✅ Check existing demos for patterns
✅ Use multi-file read operations
✅ Test changes before completion
✅ Update documentation (README.md, CHANGELOG.md)
✅ Follow naming conventions
✅ Add cleanup steps
✅ **Update CHANGELOG.md for every change made**

### DON'T:
❌ Skip reading DESIGN_SYSTEM.md
❌ Use emojis in UI
❌ Make yellow H1/H2 titles
❌ Forget Vault logo background
❌ Hardcode values (use env vars)
❌ Leave orphaned resources
❌ Forget to update README.md
❌ Forget to add new demo to `port-forward-all` target in Makefile

## 🤝 Working with Users

### Communication:
- Be direct and technical
- Don't ask unnecessary questions
- Use tools to gather information
- Wait for confirmation after tool use
- Present results concisely

### Task Completion:
- Break tasks into steps
- Use one tool per message
- Update todo list as you progress
- Use `attempt_completion` when done
- Include clear next steps

## 📖 Additional Resources

- **Vault Documentation**: https://developer.hashicorp.com/vault
- **Kubernetes Documentation**: https://kubernetes.io/docs/
- **hvac Python Library**: https://hvac.readthedocs.io/

---

**Remember**: This project prioritizes consistency, quality, and user experience. Always review DESIGN_SYSTEM.md before making UI changes, follow established patterns from existing demos, and update CHANGELOG.md for all changes.