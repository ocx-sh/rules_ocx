---
name: update-dist
description: Update rules_ocx to a newer ocx CLI release — refresh the dist/dist.json snapshot, bump DEFAULT_OCX_VERSION and the CI setup-ocx pins in lockstep, then prove the pinned binary really downloads, extracts and runs. Use when asked to update or bump ocx, pin a new ocx version, refresh the dist snapshot, adopt a just-published ocx release, or when a release changes archive format (e.g. tar.xz to tar.gz).
---

# Update the pinned ocx release

Three things move together or the build breaks: the vendored snapshot
(`dist/dist.json`), the pin (`DEFAULT_OCX_VERSION`), and the `setup-ocx`
version in `.github/workflows/*.yml`. `scripts/bump_ocx.py` moves all three
and refuses to write a pin the snapshot cannot support.

## Procedure

1. **Bump.** From the repo root:

   ```sh
   python3 scripts/bump_ocx.py                  # newest stable
   python3 scripts/bump_ocx.py --version 0.5.2  # a version you chose
   python3 scripts/bump_ocx.py --snapshot-only  # refresh only; pin stays put
   python3 scripts/bump_ocx.py --check          # offline; validate what is committed
   ```

   Run it; do not read its source. `--help` documents the flags; the three
   modes are mutually exclusive. It fetches the snapshot, runs the guards
   below, rewrites the pin and every CI pin, and prints what changed. Nothing
   is written unless every guard passes — including the snapshot itself.

### What it refuses, and what to do about it

`setup.ocx.sh` is the one input this repo cannot verify out of band: it names
the versions, the artifacts and the sha256 that `@ocx_tool` will execute. Each
refusal below is a supply-chain signal, not a nuisance. **None of them has an
override flag** — the fix is upstream, or a deliberate reviewed commit.

| Refusal | What it means |
|---|---|
| `latest` is not channel `stable` | Auto-select follows that pointer. Read the changelog, then pin by hand with `--version`. |
| pin would move backwards | Auto-select never rolls back. `--version` is the deliberate override. |
| a committed row was rewritten upstream | Its sha256 (or url, tag, filename, channel) moved. A committed row is immutable. |
| a committed row disappeared upstream | A released artifact must not vanish. |
| `(version, target)` appears twice | `select_release()` takes the *first* match, so a duplicate shadows a committed sha256 — the shape a poisoned manifest takes. |
| a new column on every row | A new field changes what an already-committed row means. |
| a row is not channel `stable` / sha256 not 64 lowercase hex / url not on the ocx release host / an archive extension `archive_type()` does not map | Per-row validation. It covers the pinned version **and every row a refresh adds** — the whole manifest is written, and `ocx.download(version = …)` lets a consumer select any row in it. `--check` re-runs it on every PR via `task lint`. |
| fewer than 8 targets | The release may still be publishing; retry. This is the one check scoped to the version being pinned — an unconditional one would false-fire mid-publish. |

`--version` is the only bypass, and it bypasses exactly two things: the
forward-only check and the `latest` channel check. Every row-level guard still
applies to a version named by hand.

The url check parses the url; it does not prefix-match. `github.com` normalises
dot segments server-side, so a url of
`…/ocx-sh/ocx/releases/download/../../../../other/repo/releases/download/v1/x.tar.gz`
starts with the artifact prefix and still serves *another repository's* release
asset — and `artifact_url()` hands the value to `download_and_extract` verbatim,
with the sha256 from the same row. Scheme, host, path prefix and dot segments
are checked separately; CR, LF, tab, NUL, a query string or a fragment are
refused outright.

`python3 scripts/bump_ocx_test.py` pins all of the above; `task lint` runs it.

2. **Act on an archive-format NOTE.** If the script reports the archive
   format changed, `archive_type()` in `ocx/private/manifest.bzl` must map
   the new extension — it falls back to `tar.xz`, so an unmapped format
   fails at extraction, not at download. Update its docstring to name the
   real cutover version too.

3. **Verify.** `task verify` is the gate (lint + unit tests + examples).
   `task lint` now runs `task dist:check`, so the lockstep invariant is
   checked here and on every PR.

4. **Prove the binary actually works** — step 3 can pass on a cached
   download. Force a real fetch:

   ```sh
   ocx run -- bazelisk --output_base=/tmp/ocx-fresh \
     test //ocx/tests:ocx_tool_test --repository_cache=/tmp/ocx-emptycache \
     --test_output=all
   ```

   The test prints the resolved version; it must be the new one. A fresh
   `--output_base` alone is not enough — Bazel's repository cache is shared
   across output bases, so pass an empty `--repository_cache` as well.

5. **Commit** per repo convention: Conventional Commits, never push, never
   commit to `main` (`git switch -c chore/bump-ocx-<version>` first).
   Subject: `chore(dist): bump ocx CLI to <version>`.

## When the archive format changes

Verify all 8 targets, not just the host — the host exercises one triple, and
the layout `download.bzl` expects (`ocx-<triple>/ocx` nested, or the binary
flat at the archive root) is what breaks. Download each row, confirm its
sha256 matches the snapshot, and list the archive:

```sh
python3 - <<'EOF'
import json
rows = [r for r in json.load(open("dist/dist.json"))["releases"]
        if r["version"] == "<version>"]
for r in rows:
    print(r["target"], r["filename"], r["sha256"], r["url"])
EOF
```

Then `curl -fsSL <url> -o <filename>`, `sha256sum`, and `tar tzf` / `unzip -l`
each one. A mismatched sha256 means the snapshot is wrong or the artifact was
relocated — stop and investigate; never hand-edit rows.

CI's `bcr-parity` job builds `e2e/bzlmod` on linux, windows, macOS-arm64 and
macOS-under-Rosetta, so those platforms get exercised there rather than
locally.

## Invariants

- Never hand-edit `dist/dist.json` rows; the sha256 values are the security
  boundary. Refresh the whole file.
- The pinned version must exist in the snapshot for all 8 targets.
- CI's `setup-ocx` pins are the dogfooding CLI, separate from `@ocx_tool`.
  They are bumped so CI runs the version the rules ship; leaving them stale
  means CI never exercises it.
- The ocx CLI is version-unstable. If `task verify` fails after a bump, the
  CLI's `--format json` surface likely changed — check `install`, `which`,
  `env` shapes and the sysexit codes against
  `.claude/rules/starlark.md` before adapting the Starlark.
