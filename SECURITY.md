# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in rules_ocx, please report it responsibly.

**Email:** [contact@michael-herwig.de](mailto:contact@michael-herwig.de)

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact

We will acknowledge receipt within 48 hours and aim to provide a fix or mitigation plan within 7 days for critical issues.

## Supported Versions

Only the latest release is supported with security updates.

## Trust model

- The ocx binary bootstrap verifies the sha256 recorded in the vendored
  `dist/dist.json` manifest — corporate mirrors (`OCX_INSTALL_MIRROR_URL`)
  can relocate artifacts but cannot alter them.
- Package integrity is enforced by OCX itself via OCI digests; `ocx.lock`
  pins per-platform sha256 digests keyed to the upstream registry host,
  making lockfiles portable across mirrors.
