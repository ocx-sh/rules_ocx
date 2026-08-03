# dist/dist.json snapshot procedure

`dist/dist.json` is a vendored snapshot of `https://setup.ocx.sh/dist.json`
(the OCX release manifest: rows of
`{version, channel, tag, target, filename, sha256, url}`).

- Refresh: `task dist:update` — `scripts/bump_ocx.py --snapshot-only`, which
  fetches, runs the additions-only check plus the per-row bar on every added
  row and on the pinned version's 8, and only then writes the file; the pin
  and the CI pins stay put. Re-validating *every* committed row is
  `--check`'s job, which `task dist:update` chains immediately after. CI
  `update-dist.yml` runs the same script without that flag on a schedule and
  opens a PR that refreshes the snapshot *and* moves the pin to the newest
  stable. The ocx CLI is version-unstable — that PR is
  a proposal, not a rubber stamp: read the ocx changelog for the versions
  being crossed before merging it.
- **A refresh may only add rows**, and **every added row clears the same
  per-row bar as the pinned one** — stable channel, 64-lowercase-hex sha256,
  a url that *parses* to the ocx release host, a `tag` and a `filename` that
  are each one path segment, a mapped archive extension.
  The whole manifest is written, not just the pinned version, and
  `ocx.download(version = …)` lets a consumer select any row in it, so a row
  nothing pins today is still reachable. If upstream rewrites, drops or
  duplicates a row already in the snapshot, or adds a column to existing
  rows, the refresh exits non-zero and writes nothing. There is deliberately
  **no override flag**: a moved sha256 is either an upstream incident or an
  attack, and neither is resolved by re-running with `--force`. Investigate
  at the source, and only then decide — by hand, in a reviewed commit.
- The url check is an **allowlist**, not a prefix match: the decoded path
  must fullmatch exactly two `[A-Za-z0-9._+-]` segments — `<tag>/<filename>`
  — under the literal `/ocx-sh/ocx/releases/download/` prefix. It is three
  cooperating checks, and each is the *only* one refusing a payload class,
  so none is redundant: the allowlist refuses a literal or `%5c` backslash
  and any extra path segment; `startswith(ARTIFACT_PATH)` on the **raw**
  path refuses `…/releases/download%2fv1/x.tar.gz`, whose decoded path
  fullmatches cleanly; and `".." not in path.split("/")` refuses a bare
  `..`, which clears the charset. The shape matters as much as the charset —
  with two segments and no separator in the class, a traversal cannot
  descend again. A blocklist of separator characters is an open set, and
  this guard has already been defeated twice — the second time by four
  payload classes at once. Generation 1, `startswith()` alone, fell to
  `…/ocx-sh/ocx/releases/download/../../../../other/repo/releases/download/v1/x.tar.gz`
  (`github.com` normalises dot segments server-side and serves *another
  repository's* asset). Generation 2, `startswith` plus a `..`-segment
  refusal, fell to a literal backslash, a `%5c`-encoded one, an extra path
  segment and a `%2f` separator — a backslash is one path segment to
  `urlsplit` and four traversals to github.com.
  `tag` and `filename` *are* those two segments — the mirror url is
  `<mirror>/<tag>/<filename>` — so they are validated against the same
  charset constant by construction, not by coincidence, **and against `.`
  and `..` separately**, because the charset admits a dot segment and one
  `..` still walks a level out of the release directory. Before that, an
  unvalidated `tag` of `../../../..` escaped a mirror's path root.
  The host is `p.netloc` compared as an exact string, never
  `.hostname`, which would accept `user@github.com` and `github.com:443`. A
  url carrying CR, LF, tab, NUL, a query or a fragment is refused outright.
- Bumping to a new ocx release (snapshot + pin + CI pins + verification):
  use the `update-dist` skill.
- **Always bump together with `DEFAULT_OCX_VERSION`**
  (`ocx/private/versions.bzl`): target coverage is checked two ways — the
  pinned version must cover **at least 8** targets (a coarse floor; upstream
  adding a 9th is a normal release and must not turn `task lint` red), and a
  bump **may not drop any target the outgoing pin already covers**. That
  second set is read from the *committed* snapshot, so upstream cannot shrink
  the set it is judged against, and no target list is hardcoded anywhere. A
  rename trips it deliberately: the host whose row vanished would otherwise
  hit `select_release()`'s `fail()` in `ocx/private/manifest.bzl`, so the
  message names the missing target and points at the ocx releases page.
  `task dist:check` (= `bump_ocx.py --check`, offline) verifies that, plus a
  whole-file shape check (a `releases` list of rows carrying a string version
  and target, with no `(version, target)` appearing twice), plus the per-row
  bar — stable channel, hex sha256, artifact host, single-segment tag and
  filename, mapped archive extension — **on every row in the file, not only
  the pinned version's**. A row nobody pins today is still a url+sha256 pair
  `ocx.download(version = …)` can select, so the only checks scoped to the pin
  are the two coverage ones: an unconditional count would false-fire while
  upstream is mid-publish. A duplicate is likewise red repo-wide, not only on
  the refresh path, because `select_release()` takes the *first* match — a
  second row shadows a committed sha256 however it landed. It all runs in
  `task lint`, so every PR re-checks the committed file, not just the ones
  that refresh it — the refresh guards (additions-only) never see a
  hand-edited commit at all.
- Never edit rows by hand; the sha256 values are the security boundary
  (mirrors can relocate artifacts, never alter them). `.gitattributes` marks
  this file `linguist-generated`, so GitHub collapses its diff — a row that
  slips past the guards will not be caught by eye in review.
