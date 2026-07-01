# rules_ocx (bazel-ocx)

Bazel module extension + repository rules provisioning tools via the OCX
package manager (https://ocx.sh, source at `../ocx`). Successor to the
in-tree draft ocx-sh/ocx#12.

## Architecture (load-bearing)

- **One extension** `//ocx:extensions.bzl%ocx`, tag classes `download`
  (root-only), `project` (root-only), `package`. Extension impl is a pure
  function of tags → `reproducible = True`. All host detection happens in
  repository rules.
- **`@ocx_tool`**: pinned ocx binary, downloaded per the vendored
  `dist/dist.json` (snapshot of https://setup.ocx.sh/dist.json),
  sha256-enforced. Mirror knobs: `OCX_INSTALL_DIST_URL` (manifest),
  `OCX_INSTALL_MIRROR_URL` (artifact host, `<mirror>/<tag>/<filename>`).
- **Project tier** (`ocx.project`): watches ocx.toml+ocx.lock; runs
  `ocx lock --check` → `ocx pull` → `ocx --format json env`; renders
  launcher per discovered bin. **Package tier** (`ocx.package`): runs
  `ocx --format json package install/which/env [-p platform]`; symlinks
  store `content/` + `entrypoints/`.
- Shared `OCX_HOME` (~/.ocx) by default — repo rules are unsandboxed; the
  content-addressed store is the design win. `isolated_home = True` opts out.

## Invariants — do not violate

1. **Never re-implement OCX internals in Starlark**: no OCI protocol, no
   registry auth, no index/object-store layout knowledge, no lockfile
   parsing. The `ocx` CLI is the only interface; its `--format json` shapes
   (env entries, which paths, install report) are the parse surface.
2. The ocx CLI is version-unstable: `DEFAULT_OCX_VERSION`
   (`ocx/private/versions.bzl`) and `dist/dist.json` bump **together**.
3. Extension impls: no `module_ctx.os`, no getenv — repository rules only.
4. Sysexits from ocx (64 usage / 65 stale / 78 missing) map to actionable
   fail() messages that name the exact command to run.

## Two-tier ocx CLI contract (verified against 0.3.10)

- `ocx --format json env` → `{"entries":[{"key","value","type":"path"|"constant"}]}` (ordered).
- `ocx --format json package install <pkg>` → `{"<raw>":{identifier
  (digest-pinned), metadata, path}}`; `package which` → `{"<raw>":"<store-root>"}`
  (content at `<root>/content`); `package env` → entries as above.
- `ocx lock --check`: exit 0 current / 65 stale / 78 missing. Offline.
- Root flags before subcommand: `--format json --project <toml>`.
- Env passthrough (getenv-declared): OCX_HOME, OCX_MIRRORS,
  OCX_INSECURE_REGISTRIES, OCX_OFFLINE, OCX_FROZEN, OCX_REMOTE, OCX_JOBS,
  OCX_INDEX, OCX_DEFAULT_REGISTRY.

## Workflow

- `task verify` — lint + unit tests + examples. Run after any change.
- `bazel test //...` — unit tests (no network) + docs freshness.
- Examples under `examples/*` are the integration tests (live ocx.sh
  registry — dogfooding); each is its own module with `local_path_override`.
- `bazel run //docs:update` regenerates stardoc output; CI diff_tests it.
- `task dist:update` refreshes `dist/dist.json`.
- Conventional Commits; changelog via git-cliff; never push to remote;
  never commit to `main`.

## Dogfooding

The dev toolchain comes from the committed `ocx.toml`/`ocx.lock`
(bazelisk, actionlint, git-cliff, go-task, hawkeye, lychee, shellcheck).
`direnv allow` or `ocx run -- <cmd>` to use it. buildifier is not in the
ocx catalog yet → `buildifier_prebuilt` dev dependency.
