# Changelog

All notable changes to the Vault Demo Project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Agentic AI Demo - Audit Log Access** (2026-06-04): Fixed container creation timeout and enabled audit log viewing in UI
  - Added Minikube mount setup in `scripts/setup/setup-agentic-vault.sh` to mount `$HOME` to `/host-home`
  - Mount process runs in background and persists until Minikube is stopped
  - UI can now access Vault audit logs at `/host-home/audit.log`
  - Restored audit-log volume mount in `agentic-ai-demo/ui/deployment.yaml`

### Added
- **Agentic AI Demo - Entity-Based Authorization** (2026-06-01): Implemented Vault JWT-based user authorization for the agentic demo
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

[Unreleased]: https://github.com/yourusername/master-demo/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/yourusername/master-demo/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/yourusername/master-demo/releases/tag/v1.0.0