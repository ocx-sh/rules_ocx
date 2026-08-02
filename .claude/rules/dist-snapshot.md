# dist/dist.json snapshot procedure

`dist/dist.json` is a vendored snapshot of `https://setup.ocx.sh/dist.json`
(the OCX release manifest: rows of
`{version, channel, tag, target, filename, sha256, url}`).

- Refresh: `task dist:update` (curl + sanity check). CI `update-dist.yml`
  runs `scripts/bump_ocx.py` on a schedule and opens a PR that refreshes the
  snapshot *and* moves the pin to the newest stable. The ocx CLI is
  version-unstable — that PR is a proposal, not a rubber stamp: read the ocx
  changelog for the versions being crossed before merging it.
- Bumping to a new ocx release (snapshot + pin + CI pins + verification):
  use the `update-dist` skill.
- **Always bump together with `DEFAULT_OCX_VERSION`**
  (`ocx/private/versions.bzl`): the pinned version must exist in the
  snapshot for all 8 targets — `task dist:check` verifies.
- Never edit rows by hand; the sha256 values are the security boundary
  (mirrors can relocate artifacts, never alter them).
