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
- The *committed* manifest is refreshed only by `scripts/bump_ocx.py`, which
  permits no change but *added* rows and validates every row it adds, so a
  rewritten, dropped or duplicated row upstream fails closed with no override
  flag (procedure: `.claude/rules/dist-snapshot.md`).
- `OCX_INSTALL_DIST_URL` bypasses all of that: it replaces the whole manifest
  with whatever the named URL serves — no sha256, no guard — and the sha256
  `download_and_extract` then enforces comes out of that same response.
  Setting it is an explicit out-of-band trust decision about the mirror,
  equivalent to trusting whoever publishes the ocx release itself.
- Package integrity is enforced by OCX itself via OCI digests; `ocx.lock`
  pins per-platform sha256 digests keyed to the upstream registry host,
  making lockfiles portable across mirrors.
- The host's ocx configuration is a trust boundary the build inherits: ocx
  layers system → user → `$OCX_HOME/config.toml` → the managed-config
  snapshot → `OCX_CONFIG` → `--config`, and the repository rules run inside
  that chain. A `[patches]` table in any of those tiers composes companion
  packages onto a resolved one, and `ocx lock --check` does not cover
  companions — without `patch_snapshot`, their digests resolve at fetch time.
  `OCX_NO_CONFIG` alone is not the fix: it prunes only the *discovered*
  tiers, which leaves an ambient `OCX_PATCHES` as the sole patch source. The
  `no_config = True` attr additionally blanks `OCX_CONFIG`, `OCX_PATCHES` and
  `OCX_PATCH_SNAPSHOT`; pair it with `config` / `patch_snapshot` to pin
  exactly what the build reads.
