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
   python3 scripts/bump_ocx.py --version 0.5.2
   ```

   Run it; do not read its source. `--help` documents the flags. It fetches
   the snapshot, validates the target version, rewrites the pin and every CI
   pin, and prints what changed. It writes nothing if validation fails.

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
