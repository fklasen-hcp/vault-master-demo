# Changelog

All notable changes to the Vault Demo Project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [1.4.3] - 2026-09-23

### Fixed
- **`host.minikube.internal` DNS (Podman driver)**: The Podman driver sets `host.minikube.internal` to a link-local IPv6 address (`fe80::1`) that is unreachable from pods, silently breaking all pod-to-Vault communication. `start-minikube` and `all-recover` now detect the real host gateway IP from `host.containers.internal` and patch both the Minikube node `/etc/hosts` and the CoreDNS ConfigMap with the correct IP, then restart CoreDNS. Files: `Makefile`, `scripts/setup/recover-after-reboot.sh`

- **PostgreSQL PVC hostPath permissions**: Minikube's hostPath provisioner creates PVC directories owned by `root`, causing the Bitnami PostgreSQL pod (UID 1001) to crash-loop on a fresh deploy. `install-postgresql-pod` now sets `podSecurityContext.fsGroup=1001` and `containerSecurityContext.runAsUser=1001` on the Helm install and runs `minikube ssh "sudo chown -R 1001:1001 <hostPath>"` after the PVC is bound. File: `Makefile`

- **GitLab PVC hostPath permissions**: Same root-ownership problem as PostgreSQL. `setup-gitlab-demo.sh` now waits for the `gitlab-data` PVC to bind, looks up the hostPath dynamically, and runs `minikube ssh "sudo chmod 777 <hostPath>"` before the pod creation wait loop. File: `scripts/setup/setup-gitlab-demo.sh`

- **Prometheus & Grafana PVC hostPath permissions**: Prometheus (UID 65534/nobody) and Grafana (UID 472) failed to start on fresh deploys due to root-owned hostPath directories. Setup script now pre-creates the hostPath directories with correct ownership via `minikube ssh`. Prometheus deployment YAML gains a `securityContext` block (`fsGroup: 65534`, `runAsUser: 65534`). Files: `scripts/setup/setup-audit-monitoring.sh`, `audit-monitoring/kubernetes/03-prometheus-deployment.yaml`

- **`make all-recover` missing audit device + port-forward restore**: After a reboot the `master-demo-audit/` file audit device was silently dropped and port-forwards had to be restored manually. `all-recover` now calls `enable-audit-log-rotation` and `port-forward-all` at the end of recovery. File: `Makefile`

- **Vault setup script — token validation + namespace-scoped auth list**: Three improvements to `setup-local-vault.sh`: (1) `VAULT_TOKEN` missing error now shows the exact `jq` command to source the token from `~/vault-init.json`; (2) `vault token lookup` fail-fast check added after the connectivity check so an expired token is caught before mid-script failures; (3) the `vault auth list` check inside the auth-enable block now runs with `VAULT_NAMESPACE=master-demo` to avoid false "auth not found" errors that caused the auth backend to be unnecessarily re-enabled on every run. File: `scripts/setup/setup-local-vault.sh`

- **Agentic AI — JWT auto-refresh removed**: Removed the fragile inline `import jwt as pyjwt` and "refresh within 5 minutes of expiry" heuristic from the `/api/chat` route. Token lifecycle is managed at login, not inside the chat handler. File: `agentic-ai-demo/ui/app.py`

- **Agentic AI — log entry modal**: All log entries (DB logs, Vault audit logs, JWT claims) now open a modal overlay on click showing the full entry at 120% font size with syntax highlighting preserved. Supports Escape key and click-outside-to-close. File: `agentic-ai-demo/ui/app.py`

- **VSO `gitlab-kv-secret` stale scaffold comment**: Confirmed removed — no `rolloutRestartTargets` comment block present. File: `static-secrets-gitlab-ci/gitlab-static-secret.yaml`

- **`.gitignore` — `*.hclic` added**: Prevents accidental commit of a Vault Enterprise license file. File: `.gitignore`

- **Control Groups entity seeding race condition**: The entity ID lookup in `setup-controlgroups-vault.sh` had no retry logic. If the pod was not fully ready when the script ran, the entity ID was silently empty, leaving the ops-team and security-team groups with no members — causing every control group approval to fail with "further authorization required". The lookup now retries up to 10 times (20 seconds apart) with a clear recovery message if all attempts fail. File: `scripts/setup/setup-controlgroups-vault.sh`

- **Agentic AI — Ollama model not ready before agent starts**: `ollama pull` was swallowing errors with a fallback echo, allowing the AI agent to deploy before the model existed. The pull now fails hard on error. A post-pull verification loop (up to 30 × 10s) confirms `ollama list` shows `llama3.2:1b` before the agent deployment begins. File: `Makefile`

---

## [1.4.2] - 2026-09-22

### Changed
- **Control Groups demo → Policy Governance demo**: Extended and rebranded the existing `controlgroups-demo` (port 10005) into a full policy governance showcase with two new demo panels above the existing secret-access flow.
  - **Demo 1 — Sentinel Policy Block**: A Sentinel EGP (`master-demo-sentinel-no-root-wildcard`) attached to `sys/policies/acl/*` at `hard-mandatory` enforcement blocks any policy write containing a root wildcard `path "*"`. The left panel shows the live rejection in real time.
  - **Demo 2 — Control Group Policy Gate**: Every write to `sys/policies/acl/master-demo-policy-*` is gated by a real Vault Control Group stanza. The "Create Policy" button freezes until the admin approves in the unified Admin Panel; the write then completes using the real CG accessor token.
  - **Unified Admin Panel**: All pending CG requests (both Policy Write and Secret Read) appear in one list with type badges (`[Policy Write]` / `[Secret Read]`). Approve dispatches to the correct Vault handler by request type.
  - **Combined Audit Log**: Single audit log replaces the two separate logs; records all events from both flows.
  - **All CG calls are real**: The previously simulated `request_secret` / `approve` / `unwrap` flow is replaced with real `sys/control-group/authorize` calls and accessor-token re-attempts throughout.
  - **New Vault resources**: `master-demo-sentinel-no-root-wildcard` (EGP), `master-demo-policy-admin` (ACL policy with CG stanza), `master-demo-policy-approver` (ACL policy), `policy-approvers` (identity group), plus two new K8s auth roles bound to the existing `controlgroups-demo-app` service account.
  - No new Kubernetes namespace or pod — everything runs in the existing `controlgroups-demo` namespace on port 10005.
  - Automatic entity group seeding in `deploy-controlgroups-demo` target via `scripts/setup/seed-controlgroups-entities.sh`.
  - Files changed: `control-groups/app.py`, `scripts/setup/setup-controlgroups-vault.sh`, `scripts/setup/setup-policy-governance.sh`, `scripts/setup/seed-controlgroups-entities.sh`, `scripts/cleanup/cleanup-all.sh`, `Makefile`, `README.md`

---

## [1.4.0] - 2026-08-12

### Changed
- **Docker Desktop → Podman Desktop migration**: Full migration from Docker Desktop to Podman Desktop as the container runtime on macOS. All demos verified working end-to-end after migration.

  **Container runtime changes:**
  - `Makefile` (`build-agentic-agent`, `build-agentic-ui`): Replaced `minikube docker-env` + `docker build` with `minikube podman-env` + `podman build`
  - `scripts/setup/setup-audit-monitoring.sh`: Updated `vault-audit-exporter` image build to use `minikube podman-env` + `podman build`
  - `AGENTS.md`: Updated image build workflow and all examples to use `podman build`

  **Minikube startup changes:**
  - `Makefile` (`start-minikube`): Added explicit `--driver=podman --container-runtime=cri-o --mount --mount-string="$HOME:/host-home"` flags. The `--mount` flag replaces the previous `minikube mount` background-process approach which is not supported with the Podman driver on macOS. The `--container-runtime=cri-o` flag is required for `minikube podman-env` compatibility.
  - `Makefile` (`start-minikube`): Added explicit error handling with actionable diagnostic messages if Podman is not running or not in PATH.

  **Mount handling changes (all scripts):**
  - `scripts/setup/setup-audit-monitoring.sh`: Replaced 40-line `minikube mount` background process with a simple `/host-home` presence verification check
  - `scripts/setup/setup-agentic-vault.sh`: Same — mount block replaced with presence check
  - `scripts/setup/recover-after-reboot.sh`: "Restart mount" step replaced with "Verify mount" step
  - `scripts/setup/recover-pki-rotation.sh`: Same

  **Documentation and prerequisites:**
  - `README.md`: Updated `minikube start` command to include `--driver=podman --container-runtime=cri-o`; updated prerequisites to reference Podman Desktop with recommended podman machine sizing (≥8 CPUs, ≥20 GB RAM, ≥60 GB disk)

### Fixed
- **GitLab demo - Apple Silicon (arm64) compatibility**: Replaced hardcoded `x86_64-v16.11.1` GitLab runner helper image with `arm64-v16.11.1` in `scripts/setup/setup-gitlab-demo.sh`. The x86_64 binary caused a Go runtime `lfstack.push` fatal crash under QEMU emulation with the Podman driver. This was previously masked by Docker Desktop's transparent Rosetta 2 integration.
- **GitLab demo - OOM kill during token creation**: Increased GitLab pod memory limit from 4 GB to 6 GB (request: 3 GB) in `static-secrets-gitlab-ci/manifests/gitlab-simple.yaml` to prevent OOM kill during `gitlab-rails runner` token creation. Added 60-second stabilisation delay in `scripts/setup/setup-gitlab-demo.sh` after services are ready before attempting the token creation.
- **Audit monitoring - CRI-O image reference**: Updated `audit-monitoring/kubernetes/01-exporter-deployment.yaml` to reference `localhost/vault-audit-exporter:latest` instead of `vault-audit-exporter:latest`. CRI-O requires the `localhost/` prefix for locally-built images, unlike Docker which resolved unqualified names automatically.

## [1.1.0] - 2026-06-12

### Changed
- **README.md - Updated Title and Description**: Changed repository title from "Vault Secrets Operator with Local Vault Enterprise" to "HashiCorp Vault Enterprise Demo Suite" to better reflect the comprehensive nature of the demos beyond just VSO
  - Updated title to emphasize the demo suite nature of the repository
  - Rewrote overview section to highlight all 7 demos and their capabilities
  - Clarified that VSO is used in some demos (static, dynamic, PKI) but not all
  - Better organized component descriptions to show the full scope of Vault features demonstrated

### Added
- **README.md - Demo Screenshots**: Added visual screenshots for all interactive demos
  - Added `images/` directory for demo screenshots
  - GitLab CI/CD pipeline screenshot showing Vault secret integration
  - Dynamic Secrets UI showing auto-rotating PostgreSQL credentials
  - PKI Certificate Auto-Renewal UI displaying certificate details
  - Encryption as a Service UI with Transit and Transform engines
  - Control Groups UI showing multi-party authorization workflow
  - Agentic AI Security main UI with chat interface and audit logs
  - Agentic AI JWT claims display showing token structure
  - Audit Monitoring Grafana dashboard with comprehensive metrics

### Fixed
- **Agentic AI Demo - Audit Log Access**: Fixed container creation timeout and enabled audit log viewing in UI
  - Added Minikube mount setup in `scripts/setup/setup-agentic-vault.sh` to mount `$HOME` to `/host-home`
  - Mount process runs in background and persists until Minikube is stopped
  - UI can now access Vault audit logs at `/host-home/audit.log`
  - Restored audit-log volume mount in `agentic-ai-demo/ui/deployment.yaml`

- **Agentic AI Demo - Entity-Based Authorization**: Implemented Vault JWT-based user authorization for the agentic demo
  - JWT auth method at `master-demo-jwt/` with RSA256 key pair
  - RSA private key stored in Vault KV for JWT signing
  - RSA public key used for JWT validation
  - Agent authenticates users with JWT to get Vault tokens
  - UI fetches JWT private key from Vault on startup (with HMAC fallback)
  - Agent fetches JWT public key from Vault on startup (with HMAC fallback)
  - Updated `scripts/setup/setup-agentic-vault.sh` to configure JWT auth
  - Updated `agentic-ai-demo/ui/app.py` to use RS256 JWT signing
  - Updated `agentic-ai-demo/agent/agent.py` to authenticate users via JWT auth
  - ConfigMap-based deployment for UI (no Docker image needed)
  - Added UI deployment to `deploy-agentic-demo` Makefile target
- **Agentic AI Demo - Phase 2 Testing**: Created comprehensive test script (`scripts/test/test-agentic-agent.sh`) to validate AI Agent service functionality including JWT validation, Vault authentication, database credential retrieval, LLM integration, and permission enforcement for both Alice (read-only) and Bob (admin) users
- **Makefile**: Added `test-agentic-agent` target to run AI Agent service tests
- **Agentic AI Security Demo** - Advanced demo showcasing secure AI agent workflows (2026-06-01)
  - SPIFFE/SPIRE integration for workload identity
  - Vault SPIFFE auth method (Vault 2.0 feature)
  - User-scoped database permissions (Alice: read-only, Bob: admin)
  - Local LLM integration with Ollama (Llama 3.2 1B)
  - Complete audit trail with user and agent context
  - Resource checking script (`scripts/setup/check-resources.sh`)
  - SPIRE server and agent deployments with proper RBAC permissions
  - Ollama deployment with automatic model download
  - AI agent service with FastAPI
  - Vault configuration script (`scripts/setup/setup-agentic-vault.sh`)
  - Comprehensive Makefile targets for deployment and monitoring
  - Port 10006 for Agentic AI demo UI
- CHANGELOG.md file to track project changes (2026-05-28)
- Favicon (browser tab icon) to all demo web interfaces using Vault logo (2026-05-28)
  - encryption-secrets/app-simple.py
  - control-groups/app.py
  - pki-secrets/app-deployment.yaml
  - dynamic-secrets/app-deployment-ui.yaml

### Changed
- **Agentic AI Demo - Group-Based Authorization Enforcement** (2026-06-05): Corrected authorization flow so Vault derives policies from JWT group claims via Identity groups
  - Replaced app-selected JWT roles with a generic JWT role in `scripts/setup/setup-agentic-vault.sh`
  - Added Vault Identity external groups for `readers` and `admins`
  - Added JWT group aliases so `groups` claim values map automatically to Vault Identity groups
  - Attached `master-demo-agentic-readonly` and `master-demo-agentic-admin` policies to Vault Identity groups instead of JWT roles
  - Updated `agentic-ai-demo/agent/agent.py` so the agent no longer chooses `alice` or `bob` as the security boundary
  - Preserved JWT token creation in `agentic-ai-demo/ui/app.py` as claims-only (`sub`, `groups`, `iss`, `aud`)
  - Corrected prior documentation to reflect that automatic group-based policy assignment is now enforced in Vault
- **Improved Agentic AI demo deployment** - Added automatic Vault and PostgreSQL dependency management (2026-06-01)
  - Created `ensure-vault-and-postgresql` target that checks if Vault and PostgreSQL are deployed
  - Automatically sets up Vault (with VSO) if not running
  - Automatically deploys PostgreSQL if not present
  - Ensures proper initialization order: Vault → PostgreSQL → Agentic AI components
  - Updated `agentic-demo` and `agentic-demo-only` targets to use `ensure-vault-and-postgresql`
  - Eliminates manual Vault and PostgreSQL deployment steps for users
- Updated `master-demo` Makefile target to include resource checking and conditional Agentic AI deployment (2026-06-01)
- Updated `port-forward-all` target to include Agentic AI demo (port 10006) (2026-06-01)
- Updated `stop-port-forwards` target to include Agentic AI demo (2026-06-01)
- Updated cleanup script to include Agentic AI resources (2026-06-01)
  - Added SPIFFE auth method cleanup
  - Added Agentic AI policies cleanup
  - Added agentic-demo namespace cleanup
- Updated README.md with comprehensive Agentic AI demo documentation (2026-06-01)
  - Added to table of contents as Demo #6
  - Renumbered Audit Monitoring to Demo #7
  - Added port mapping (10006)
  - Detailed architecture and features
  - Resource requirements and deployment modes
- Clarified port mapping structure in AGENTS.md (demos 10000+, services 9999 and below) (2026-05-28)
- Removed version history section from AGENTS.md in favor of CHANGELOG.md (2026-05-28)

### Deprecated

### Removed

### Fixed

### Security

---

## [1.1.0] - 2026-05-27

### Added
- AGENTS.md file with comprehensive AI assistant guidelines
- DESIGN_SYSTEM.md with UI/UX standards and component patterns
- Reminder in AGENTS.md to update `port-forward-all` target when adding new demos

### Changed
- Standardized UI design across all demos (white H1/H2 titles, gray borders)
- Updated all demos to follow design system standards
- Improved consistency in Makefile targets and naming conventions

### Fixed
- UI inconsistencies across different demos
- Missing Vault logo backgrounds in some demos
- Incorrect color schemes (yellow titles changed to white)

---

## [1.0.0] - 2026-05-27

### Added
- Initial project structure with multiple Vault demonstration scenarios
- Dynamic Secrets demo with PostgreSQL integration
- PKI Secrets demo with certificate management
- Encryption Secrets demo with Transit and Transform engines
- Control Groups demo for multi-party authorization
- Audit Monitoring with Prometheus and Grafana
- Static Secrets GitLab CI/CD integration demo
- Comprehensive Makefile with deployment and management targets
- Setup scripts for all demos in `scripts/setup/`
- Cleanup scripts in `scripts/cleanup/`
- Test utilities in `scripts/test/`
- README.md with project documentation
- LICENSE file (MIT)

### Features
- Vault Secrets Operator (VSO) integration
- Kubernetes-based deployments
- Minikube local development support
- Port forwarding for all demos
- Automated Vault configuration scripts
- Audit log rotation and monitoring
- Multi-namespace support

---

## Notes

### Version Numbering
- **Major version** (X.0.0): Breaking changes or major feature additions
- **Minor version** (0.X.0): New features, demos, or significant improvements
- **Patch version** (0.0.X): Bug fixes, documentation updates, minor improvements

### Categories
- **Added**: New features, demos, or files
- **Changed**: Changes to existing functionality
- **Deprecated**: Features that will be removed in future versions
- **Removed**: Removed features or files
- **Fixed**: Bug fixes
- **Security**: Security-related changes

### Contribution Guidelines
When making changes:
1. Update this CHANGELOG.md in the [Unreleased] section
2. Use present tense ("Add feature" not "Added feature")
3. Include date in YYYY-MM-DD format
4. Group related changes together
5. Reference issue numbers when applicable
6. Move changes from [Unreleased] to a new version section when releasing

---

[Unreleased]: https://github.com/yourusername/master-demo/compare/v1.4.3...HEAD
[1.4.3]: https://github.com/yourusername/master-demo/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/yourusername/master-demo/compare/v1.4.0...v1.4.2
[1.4.0]: https://github.com/yourusername/master-demo/compare/v1.3.3...v1.4.0
[1.1.0]: https://github.com/yourusername/master-demo/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/yourusername/master-demo/releases/tag/v1.0.0