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