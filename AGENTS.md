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
  `ocx lock --check` → `ocx pull` → `ocx --format json env` →
  `ocx --format json inspect --closure`; renders a launcher per executable the
  closure's interface surface declares. **Package tier** (`ocx.package`):
  runs `ocx --format json package install/which/env`, then
  `package inspect --closure` (`[-p platform]` throughout); symlinks store
  `content/` + `entrypoints/`. Both skip the closure call for a foreign
  platform (no launchers there) and fall back to scanning the composed PATH
  when a package declares no complete `binaries`.
- Shared `OCX_HOME` (~/.ocx) by default — repo rules are unsandboxed; the
  content-addressed store is the design win. Two independent opt-outs:
  `isolated_home = True` moves the store into the repository, which drops the
  `$OCX_HOME`-rooted config tiers from the watch set but still loads and
  watches `/etc` (POSIX only) and the user config dir; `no_config = True` is
  the config-ambience one.

## Invariants — do not violate

1. **Never re-implement OCX internals in Starlark**: no OCI protocol, no
   registry auth, no index/object-store layout knowledge, no lockfile
   parsing. The `ocx` CLI is the only interface; its `--format json` shapes
   (env entries, which paths, install report, closure surface) are the parse
   surface.
2. The ocx CLI is version-unstable: `DEFAULT_OCX_VERSION`
   (`ocx/private/versions.bzl`) and `dist/dist.json` bump **together**.
3. Extension impls: no `module_ctx.os`, no getenv — repository rules only.
4. Every sysexit **reachable from a repository rule** (table in the CLI
   contract section) maps to a fail() naming the user-fixable action, or the
   condition to check, and the exact command where one exists; 75 is retried
   before it ever reaches a
   fail(). 82 is deliberately absent from `SYSEXIT_HINTS` — only
   `ocx config setup` / `ocx self setup` raise it, and invariant 5 forbids a
   repo rule from running either.
5. Repository rules watch the ambient ocx config tiers — except lazy
   `ocx.package(bins = …)`, which returns before `make_ocx_env()` and leaves
   config resolution to the launcher at run time. (`ocx.project(bins = …)`
   is unaffected: it calls `make_ocx_env()` — the only function that watches
   — before the lazy branch, because `lock --check` needs the env it
   returns.)
   Managed config is hint-only — never run `ocx config setup/update` from a
   repo rule.

## Two-tier ocx CLI contract (verified against 0.5.2)

- `ocx --format json env` → `{"entries":[{"key","value","type":"path"|"constant"}],
  "binaries":[…],"entrypoints":[…]}` (ordered). Parsing `.entries` only stays
  correct; `entries[].source` appears only with `--show-patches`. A consumer
  applies entries by **prepending** each `path` one in list order
  (move-to-front dedup), so effective search precedence per key is the
  *reverse* of the list — ocx pushes the synthetic `<pkg>/entrypoints` PATH
  entry last precisely so entrypoint launchers shadow `bin/`.
- `ocx --format json package install <pkg>` → `{"<raw>":{identifier
  (digest-pinned), metadata, path}}`; `package which` → `{"<raw>":"<store-root>"}`
  (content at `<root>/content`); `package env` → entries as above.
- `ocx --format json [package] inspect --closure` →
  `{"packages":[{identifier, closure:{deps, surface:{interface, private},
  conflicts}}]}`; each surface is `{binaries:[{name, package}], entrypoints,
  env, binaries_complete}`. Only the entry's `identifier` and
  `closure.surface.interface` (`binaries[].name`, `entrypoints[].name`,
  `binaries_complete`) are read — the command surface is the **union** of the
  two arrays, deduped by name. A name may appear in both; which *file* it
  resolves to is composed-PATH precedence (the `entrypoints/` launcher
  shadows `bin/`), never array order. `private` is the private-axis projection (which also repeats
  the public entries) and never becomes a target. `closure` is omitted for an
  unresolved binding (a candidate list, or one projected off ocx.lock); that,
  like any other shape drift — including an absent `entrypoints`, which
  `SurfaceOut` always serializes — is a fail() naming `DEFAULT_OCX_VERSION`,
  not a mapped sysexit. `binaries_complete = false` means the claim is
  possibly incomplete → fall back to scanning PATH; it covers `binaries`
  only, entrypoint claims are always authoritative.
- `ocx lock --check`: exit 0 current / 65 stale / 78 missing. Offline.
- Root flags before subcommand: `--format json --project <toml>`.
- Sysexits: 64 usage · 65 data/stale · 69 unavailable · 74 io · 75 transient
  (retried) · 77 permission · 78 config error (missing/unsupported lock **or**
  a required-but-unsynced managed config) · 79 not found (incl. a required
  patch companion) · 80 auth · 81 blocked by policy · 82 dirty rc.
- Config precedence: system (`/etc/ocx/config.toml`, literal on every OS —
  the repo rules skip watching it on Windows, which has no `/etc`) →
  user config dir → `$OCX_HOME/config.toml` → managed-config snapshot
  (`$OCX_HOME/state/managed-config/`) → `OCX_CONFIG` → `--config`.
- `[patches]` is a **site-config tier only** — never the project ocx.toml.
  Composed companions are invisible in the `package install` JSON report, and
  `lock --check` never covers them; `ocx patch freeze` →
  `patches.snapshot.json` (`OCX_PATCH_SNAPSHOT`) is the only freeze,
  `ocx patch sync` the only refresh (mutating, offline → 81).
- Env passthrough (getenv-declared, all 14): OCX_MIRRORS,
  OCX_INSECURE_REGISTRIES, OCX_OFFLINE, OCX_FROZEN, OCX_REMOTE, OCX_JOBS,
  OCX_INDEX, OCX_DEFAULT_REGISTRY, OCX_CONFIG, OCX_NO_CONFIG,
  OCX_MANAGED_CONFIG, OCX_ALLOW_YANKED, OCX_PATCHES, OCX_PATCH_SNAPSHOT.
  OCX_HOME is resolved, not forwarded; OCX_NO_CONFIG_REFRESH is pinned to 1.

## Workflow

- `task verify` — lint + unit tests + examples. Run after any change.
- `bazel test //...` — unit tests (no network) + docs freshness.
- Examples under `examples/*` are the integration tests (live ocx.sh
  registry — dogfooding); each is its own module with `local_path_override`.
  No example or e2e module sets `config`, `no_config`, `patch_snapshot` or
  `isolated_home` — that tier has unit coverage only.
- `bazel run //docs:update` regenerates stardoc output; CI diff_tests it.
- `task dist:update` refreshes `dist/dist.json`.
- Conventional Commits; changelog via git-cliff; never push to remote;
  never commit to `main`.

## Dogfooding

The dev toolchain comes from the committed `ocx.toml`/`ocx.lock`
(bazelisk, actionlint, git-cliff, task, hawkeye, lychee, shellcheck).
`direnv allow` or `ocx run -- <cmd>` to use it. buildifier is not in the
ocx catalog yet → `buildifier_prebuilt` dev dependency.

## Spec / plan / ADR conventions

- Specs live in `.agents/specs/`, plans in `.agents/plans/`, ADRs in
  `.agents/adr/`, research notes in `.agents/research/`; format: plain
  markdown per the templates in `.agents/templates/`.
- `.agents/worktrees/` holds transient agent checkouts (gitignored);
  `.agents/memory/` is team-shared and committed.

## Product

- What: Bazel module extension provisioning dev tools via the OCX package
  manager (OCI-backed, content-addressed).
- Users: Bazel monorepo maintainers; runs local + CI.
- Related repos: ocx-sh/ocx (CLI), ocx-sh/setup.ocx.sh (installer).
- Research keywords: Bazel module extensions, repository rules, hermetic
  dev tools, OCI artifacts as packages, tool provisioning.
- Comparable tools: theoremlp/rules_multitool, rules_nixpkgs,
  buildifier_prebuilt (single-tool); outside Bazel: aqua, mise, Hermit.

## Agent notes

- **This file is the single source of truth for agent context. Edit only
  AGENTS.md** — `CLAUDE.md` is a one-line `@AGENTS.md` import shim and must
  stay that way.
- `.claude/rules/` holds focused procedure docs (Starlark style, release,
  dist snapshot). Claude Code auto-loads them; other harnesses read them
  before touching those areas.
- Use non-interactive shell flags (`cp -f`, `rm -f`, `apt-get -y`, …) —
  interactive prompts hang agents.
