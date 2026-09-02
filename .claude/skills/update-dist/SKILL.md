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
   below, rewrites the pin and every CI pin, and prints what changed. A guard
   that refuses writes nothing at all — the snapshot included. The three
   writes themselves are not atomic: a `setup-ocx` step whose `version:` it
   cannot rewrite is a hard error raised *after* the snapshot and the pin have
   landed — and it writes each workflow as it finishes it, so earlier ones are
   repinned too. Fix the workflow, then
   `git checkout dist/dist.json ocx/private/versions.bzl .github/workflows`
   and re-run.

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
| a row is not channel `stable` / sha256 not 64 lowercase hex / url not on the ocx release host / `tag` or `filename` is not a single path segment / an archive extension `archive_type()` does not map | Per-row validation. It covers the pinned version **and every row a refresh adds** — the whole manifest is written, and `ocx.download(version = …)` lets a consumer select any row in it. `--check` re-runs it on every PR via `task lint`. |
| fewer than 8 targets | The coarse floor: the release may still be publishing; retry. More than 8 is fine — upstream adding a target is a normal release. |
| the bump drops a target the current pin covers | Measured against the target set in the *committed* snapshot, so upstream cannot shrink what it is judged against. A rename lands here: the host that lost its row would hit `select_release()`'s `fail()` in `ocx/private/manifest.bzl`. Check the releases page before pinning. |

`--version` is the only bypass, and it bypasses exactly two things: the
forward-only check and the `latest` channel check. Every row-level guard still
applies to a version named by hand.

The url check is three cooperating checks, not one — remove any and a bypass
opens:

1. **The allowlist** (on the *decoded* path): it must fullmatch exactly two
   `[A-Za-z0-9._+-]` segments, `<tag>/<filename>`, under the literal
   `/ocx-sh/ocx/releases/download/` prefix. It refuses a literal backslash,
   a `%5c`-encoded one (which decodes to a character outside the charset)
   and any extra path segment. It does **not** refuse `%2f` — see 3.
2. **The dot-segment refusal**: a bare `..` clears the charset above, so
   `".." not in path.split("/")` is still doing work.
3. **`startswith(ARTIFACT_PATH)` on the *raw* path**: it is the only check that
   refuses `…/releases/download%2fv1/x.tar.gz`, whose decoded path passes the
   regex.

It is built as an allowlist because the blocklist alternative has been defeated
twice — `startswith()` alone by dot segments (`github.com` normalises them
server-side, serving *another repository's* release asset), then `startswith`
plus the `..` refusal by four payload classes at once: a literal backslash, a
`%5c`-encoded one, an extra path segment and a `%2f` separator. Enumerating
separators is an open set.

`tag` and `filename` are validated against that same charset, sharing one
constant with the url pattern because they *are* its two path segments — and
`OCX_INSTALL_MIRROR_URL` rebuilds the download as `<mirror>/<tag>/<filename>`,
where an unvalidated `tag` of `../../../..` escaped the mirror's path root. The host is `p.netloc` compared exactly,
never `.hostname`. CR, LF, tab, NUL, a query string or a fragment are refused
outright. All of it matters because `artifact_url()` hands the url to
`download_and_extract` verbatim, with the sha256 from the same attacker-authored
row.

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
   ocx exec -- bazelisk --output_base=/tmp/ocx-fresh \
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

Verify every target of the new pin, not just the host — the host exercises one
triple, and the layout `download.bzl` expects (`ocx-<triple>/ocx` nested, or
the binary flat at the archive root) is what breaks. Download each row, confirm its
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
- The pinned version must cover at least 8 targets, and every target the
  outgoing pin covers.
- CI's `setup-ocx` pins are the dogfooding CLI, separate from `@ocx_tool`.
  They are bumped so CI runs the version the rules ship; leaving them stale
  means CI never exercises it.
- The ocx CLI is version-unstable. If `task verify` fails after a bump, the
  CLI's `--format json` surface likely changed — check the `install`,
  `which`, `env` and `inspect --closure` shapes and the sysexit codes against
  AGENTS.md's "Two-tier ocx CLI contract" before adapting the Starlark.
- Two couplings to ocx fail *open*, so no test in this repo catches a drift —
  the unit tests pin what rules_ocx emits, not what ocx actually does.
  Re-verify both by hand on every bump:
  - Every path `ambient_config_paths()` hard-codes and watches:
    `/etc/ocx/config.toml`, the platform user-config dir (`XDG_CONFIG_HOME`
    or `~/.config`, `~/Library/Application Support` on macOS, `%APPDATA%` on
    Windows), and `$OCX_HOME/{config.toml, state/managed-config/snapshot.json,
    state/managed-config/config.toml}`. ocx reports none of them through a
    read-only command, so if a release relocates one the watch covers nothing
    and nothing errors — a site config edit stops refetching.
  - `sigstore_trust_root_path()` in `ocx/private/repo_utils.bzl`, which
    hard-codes ocx's rung-4 trusted-root convention
    `$OCX_HOME/sigstore/trusted-root.json`. Same failure mode: relocate the
    directory upstream and the watch covers nothing, so editing or dropping in
    a trusted root stops refetching the repos that verified against it.
  - The self-verifying manifest convention `manifest_sha256()` parses —
    `dist/<sha256>.json`, a 64-lowercase-hex name published alongside
    `dist.json`. It mirrors www-setup's `dist_pin_digest` (`src/install.sh`);
    if the installers change the name shape, the manifest silently downloads
    unverified, exactly as an unrecognized name does today.
  - `_TRUTHY` in `ocx/private/repo_utils.bzl`, which re-implements ocx's
    `BooleanString` set. A spelling ocx starts accepting that this list omits
    is silently read as false.
