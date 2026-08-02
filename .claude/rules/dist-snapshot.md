# dist/dist.json snapshot procedure

`dist/dist.json` is a vendored snapshot of `https://setup.ocx.sh/dist.json`
(the OCX release manifest: rows of
`{version, channel, tag, target, filename, sha256, url}`).

- Refresh: `task dist:update` — `scripts/bump_ocx.py --snapshot-only`, which
  fetches, runs every guard, and only then writes the file; the pin and the
  CI pins stay put. CI `update-dist.yml` runs the same script without that
  flag on a schedule and opens a PR that refreshes the snapshot *and* moves
  the pin to the newest stable. The ocx CLI is version-unstable — that PR is
  a proposal, not a rubber stamp: read the ocx changelog for the versions
  being crossed before merging it.
- **A refresh may only add rows**, and **every added row clears the same
  per-row bar as the pinned one** — stable channel, 64-lowercase-hex sha256,
  a url that *parses* to the ocx release host, a mapped archive extension.
  The whole manifest is written, not just the pinned version, and
  `ocx.download(version = …)` lets a consumer select any row in it, so a row
  nothing pins today is still reachable. If upstream rewrites, drops or
  duplicates a row already in the snapshot, or adds a column to existing
  rows, the refresh exits non-zero and writes nothing. There is deliberately
  **no override flag**: a moved sha256 is either an upstream incident or an
  attack, and neither is resolved by re-running with `--force`. Investigate
  at the source, and only then decide — by hand, in a reviewed commit.
- The url check parses; it does not prefix-match. `github.com` normalises
  dot segments server-side, so
  `…/ocx-sh/ocx/releases/download/../../../../other/repo/releases/download/v1/x.tar.gz`
  starts with the artifact prefix and serves *another repository's* asset.
  Scheme, host, path prefix and dot segments are checked separately, and a
  url carrying CR, LF, tab, NUL, a query or a fragment is refused outright.
- Bumping to a new ocx release (snapshot + pin + CI pins + verification):
  use the `update-dist` skill.
- **Always bump together with `DEFAULT_OCX_VERSION`**
  (`ocx/private/versions.bzl`): the pinned version must exist in the
  snapshot for all 8 targets — `task dist:check` (= `bump_ocx.py --check`,
  offline) verifies that, plus per-row stable channel, hex sha256, artifact
  host and a mapped archive extension, plus a whole-file shape check: a
  `releases` list of rows carrying a string version and target, with no
  `(version, target)` appearing twice. A duplicate is red repo-wide, not
  only on the refresh path, because `select_release()` takes the *first*
  match — a second row shadows a committed sha256 however it landed. It all
  runs in `task lint`, so every PR re-checks the committed file, not just
  the ones that refresh it. The 8-target count is the one check scoped to
  the pinned version: an unconditional one would false-fire while upstream
  is mid-publish.
- Never edit rows by hand; the sha256 values are the security boundary
  (mirrors can relocate artifacts, never alter them). `.gitattributes` marks
  this file `linguist-generated`, so GitHub collapses its diff — a row that
  slips past the guards will not be caught by eye in review.
