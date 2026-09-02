# Research: Bazel policy surfaces for module extensions

## Metadata

**Date:** 2026-09-02
**Domain:** packaging
**Triggered by:** adopting ocx 0.6.0 — adding a root-only `ocx.policy` tag class, translucent bootstrap knobs on `ocx.download`, and a self-verifying dist manifest
**Expires:** 2027-03-01

## Direct Answer

1. **Root-only tag class** (`module.is_root`) is the established bzlmod pattern (rules_python, rules_go `go_sdk`, toolchains_llvm, rules_rust, rules_scala). Enforcement splits: most rulesets *silently ignore* a non-root customization; none in the sample `fail()`. rules_ocx already `fail()`s on non-root `download`/`project` tags (`ocx/extensions.bzl:200,218`) — repo consistency wins over ecosystem convention for a *security policy* tag: a dependency's `ocx.policy(verify = False)` must be loud, not silently dropped. Bazel core considers `is_root` semantically weak for transitive deps (bazelbuild/bazel#22024, #21914); no replacement shipped.
2. **Translucent knobs (attr wins over `getenv`)** — rules_ocx's existing `config`/`patch_snapshot` label-over-env pattern is already ahead of rules_oci (`DOCKER_CONFIG` env-only) and rules_python (`PIP_INDEX_URL` substitution with a documented invalidation footgun on Bazel < 7.1). `repository_ctx.getenv()` is the correct tracked primitive. Nothing to adopt.
3. **`repository_ctx.download`** returns `struct(success, sha256, integrity, size_bytes, error)`; passing `sha256=` verifies the body and routes through the repository cache. **Unconfirmed:** built-in zip-slip / symlink-escape protection in `download_and_extract` — no doc or source found. Today the only extracted archive is the sha256-pinned release tarball, so this is not a live risk; re-verify before extracting anything less trusted.
4. **Sigstore/cosign in a repository rule** — no precedent. rules_oci's `cosign_sign`/`cosign_attest` are still developer-preview (bazel-contrib/rules_oci#235 open). Bazel's own mirror-auth surfaces are `--experimental_downloader_config`, `--credential_helper`, and `use_netrc()`/`read_netrc()` in `@bazel_tools//tools/build_defs/repo:utils.bzl` (already named in `.claude/rules/mirror-auth.md`). rules_ocx delegating verification to the `ocx` CLI (never re-implementing it in Starlark — invariant 1) is the right call.
5. **Semver compare** — `bazel_skylib` `lib/versions.bzl` (`versions.is_at_least`, `versions.parse`) is SemVer-compliant and `bazel_skylib` 1.9.0 is already a dependency (`MODULE.bazel:11`). No new helper needed.

## Technology Landscape

### Established (proven, widely accepted)

| Tool/Pattern | Status | Notes |
|---|---|---|
| Root-only tag via `module.is_root` | Standard | rules_python, rules_go, toolchains_llvm, rules_rust, rules_scala |
| `repository_ctx.getenv()` for tracked env reads | Standard | Bazel ≥ 7.1; rules_ocx already uses it everywhere |
| `sha256=`/`integrity=` on `ctx.download` | Standard | content-addressed repo cache |
| `bazel_skylib` `versions.bzl` | Mature | SemVer incl. pre-release |

### Emerging (early but promising)

| Tool/Pattern | Signal | Worth Watching Because |
|---|---|---|
| cosign/sigstore in Bazel fetch paths | rules_oci dev-preview, #235 open | rules_ocx would be first to *consume* verification at fetch time (via the CLI) |
| `--credential_helper` for repo downloads | Bazel 7+ | the sanctioned mirror-auth route if `mirror-auth.md`'s gap is ever closed |

### Declining (losing mindshare)

| Tool/Pattern | Signal | Avoid Because |
|---|---|---|
| WORKSPACE-macro toolchain registration | superseded by extension "toolchainization" (EngFlow 2025-05) | not applicable to a bzlmod-only ruleset |

## Design Patterns Worth Considering

- **Default-plus-root-override** (matts1, bazel#22024): the extension applies a safe default for every module and only the root may override — exactly the `ocx.policy` shape (defaults `verify = True`, `allow_yanked = False`; root may loosen).
- **Silent-ignore vs fail on non-root**: ecosystem majority silently ignores; rules_ocx fails. Keep failing — consistent with its sibling tags and safer for a policy surface.

## Key Findings

1. `is_root` critique — https://github.com/bazelbuild/bazel/discussions/22024, https://github.com/bazelbuild/bazel/issues/21914
2. Toolchainization / root-only settings — https://blog.engflow.com/2025/05/14/migrating-to-bazel-modules-aka-bzlmod---toolchainization/
3. `repository_ctx` download API — https://bazel.build/rules/lib/builtins/repository_ctx
4. rules_oci cosign still dev-preview — https://github.com/bazel-contrib/rules_oci/issues/235
5. rules_python env substitution + invalidation caveat — https://rules-python.readthedocs.io/en/stable/environment-variables.html
6. skylib versions — https://github.com/bazelbuild/bazel-skylib/blob/main/lib/versions.bzl
7. netrc is manual for `ctx.download` — https://github.com/bazelbuild/bazel/issues/18851

## Recommendation

Ship `ocx.policy` as a root-only tag class that `fail()`s on a non-root instance (repo convention). Keep attr-over-`getenv` translucency as-is. Use `bazel_skylib` `versions` for the 0.6.0 floor. Do not add Starlark-side tar guards now; the only extracted archive is sha256-pinned. Do not attempt sigstore verification in Starlark — the CLI does it.

## Sources

| Source | Type | Date | Relevance |
|---|---|---|---|
| https://bazel.build/rules/lib/builtins/repository_ctx | Docs | 2025 | download struct, sha256/integrity |
| https://github.com/bazelbuild/bazel/discussions/22024 | Discussion | 2024 (re-verify) | is_root semantics |
| https://blog.engflow.com/2025/05/14/migrating-to-bazel-modules-aka-bzlmod---toolchainization/ | Blog | 2025-05 | root-only tag pattern |
| https://github.com/bazel-contrib/rules_oci/issues/235 | Issue | open | cosign not public API |
| https://github.com/bazelbuild/bazel-skylib/blob/main/lib/versions.bzl | Repo | current | semver helper |
