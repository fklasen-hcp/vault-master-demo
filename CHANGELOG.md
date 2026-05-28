# Changelog

All notable changes to the Vault Demo Project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- CHANGELOG.md file to track project changes (2026-05-28)
- Favicon (browser tab icon) to all demo web interfaces using Vault logo (2026-05-28)
  - encryption-secrets/app-simple.py
  - control-groups/app.py
  - pki-secrets/app-deployment.yaml
  - dynamic-secrets/app-deployment-ui.yaml

### Changed
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