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
  with whatever the named URL serves. A URL whose last path segment is
  `<sha256>.json` is fetched with that digest enforced; any other name is
  fetched unverified — and the sha256 `download_and_extract` then enforces
  comes out of that same response. Setting it is an explicit out-of-band trust decision about the mirror,
  equivalent to trusting whoever publishes the ocx release itself.
- What a build verifies or accepts is decided by `MODULE.bazel` alone:
  `ocx.policy(allow_unverified, allow_yanked)` is written on every invocation
  and never read from the environment. Ambient variables can still weaken
  transport or trust — `OCX_MIRRORS`, `OCX_INSECURE_REGISTRIES`,
  `OCX_EXTRA_CA_CERTS`, and `OCX_SIGSTORE_TRUSTED_ROOT` unless the
  `sigstore_trusted_root` attr is set; digest-pinned references (`@sha256:`; a
  project's `ocx.lock` always pins) are the mitigation.
- Package integrity is enforced by OCX itself via OCI digests; `ocx.lock`
  pins per-platform sha256 digests keyed to the upstream registry host,
  making lockfiles portable across mirrors.
- The host's ocx configuration is a trust boundary the build inherits: ocx
  layers system → user → `$OCX_HOME/config.toml` → the managed-config
  snapshot → `OCX_CONFIG` → `--config`, and the repository rules run inside
  that chain. `[patches]` never reaches a vendored tool: a vendor is a
  render, and companions are not modelled in it, so `OCX_PATCHES` and
  `OCX_PATCH_SNAPSHOT` change nothing in the vendored environment. Mirrors,
  registries and the trust policy do apply. `OCX_NO_CONFIG` alone prunes only
  the *discovered* tiers; the `no_config = True` attr additionally blanks
  `OCX_CONFIG`, `OCX_PATCHES` and `OCX_PATCH_SNAPSHOT`, and pairs with
  `config` to pin exactly what the build reads.
