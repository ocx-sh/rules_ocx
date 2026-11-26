# rules_ocx (bazel-ocx)

Bazel module extension + repository rules provisioning tools via the OCX
package manager (https://ocx.sh, source at `../ocx`).

## Architecture (load-bearing)

- **One extension** `//ocx:extensions.bzl%ocx`, tag classes `download`
  (root-only), `project` (root-only), `package`, `policy` (root-only, at most
  one). Each `project`/`package` tag yields one hub repository named by the tag
  and one set repository per entry of its `platforms` (`<name>_<slug>`).
- **Vendor, not launch.** A set repository runs
  `ocx vendor -o <repo>/.vendor_out -p <platform> --omit-links [-g …] [names…]`
  (`ocx package vendor` for the package tier), moves the three top-level
  entries (`manifest.json`, `packages/`, `selections/`) into the repository and
  generates one `BUILD.bazel` from `manifest.json`. Tools run through the
  native `.direct` launcher ocx writes: no ocx, no `OCX_HOME`, no network at
  action time, so the tree runs under remote execution. Reserved names
  (`BUILD`, `WORKSPACE`, …, matched case-insensitively) inside a package are
  moved to `_ocx_reserved/<n>` and declared back at their path.
- **Facts.** What the hub needs before any set is fetched (tool names and
  kinds per platform, `available_platforms`) is a *fact* stored in
  `MODULE.bazel.lock`, keyed by the tag and checked against the tag's inputs
  (`ocx/private/facts.bzl`). A hit runs no ocx and makes no request; a miss runs
  `ocx vendor --manifest-only` once per platform. Every set repository
  cross-checks its real manifest against the fact (platform, tools, available
  platforms) and fails naming `bazel mod deps --lockfile_mode=update`.
- **`@ocx_tool`**: pinned ocx binary, downloaded per the vendored
  `dist/dist.json` (snapshot of https://setup.ocx.sh/dist.json),
  sha256-enforced. `MIN_OCX_VERSION` is the floor, the first ocx release
  whose `ocx vendor` writes manifest schema version 1; below it
  `ocx.download(version = …)` fails before any download. Mirror knobs (site
  settings, env-only): `OCX_INSTALL_DIST_URL` (manifest),
  `OCX_INSTALL_MIRROR_URL` (artifact host, `<mirror>/<tag>/<filename>`). An
  `OCX_INSTALL_BINARY` + `OCX_INSTALL_BINARY_SHA256` pair replaces the download
  with a local build; a mismatch fails.
- Every ocx run (extension and repository rule) gets a fresh scratch
  `OCX_HOME` inside its working directory, deleted before return; the client's
  own home is never read. `HOME`, Docker configuration and the rest of the
  process environment are inherited, so credential helpers work.
- **Policy tier** (`ocx.policy`, root-only, at most one): the build's
  *signature and yank* posture is a function of `MODULE.bazel` alone.
  `allow_unverified` (→ `OCX_NO_VERIFY`) and `allow_yanked` (→ `OCX_ALLOW_YANKED`)
  are **explicit-only** — never read from the ambient environment, always
  written, so an exported CI variable cannot decide what a build verifies or
  accepts. A non-root or duplicate tag `fail()`s before any repo is declared.
  It cannot *enable* verification: ocx attaches that only under an operator
  `[[trust.policy]]`, and `no_config = True` prunes the discovered tier that
  would carry one.

## Invariants — do not violate

1. **Never re-implement OCX internals in Starlark**: no OCI protocol, no
   registry auth, no index/object-store layout knowledge, no lockfile
   parsing. The `ocx` CLI is the only interface. The `manifest.json` that
   `ocx vendor` writes is the one ocx document rules_ocx parses
   (`ocx/private/vendor_manifest.bzl`); no other ocx report is read. The text
   of `ocx.lock` is hashed into a fact and never parsed.
2. The ocx CLI is version-unstable: `DEFAULT_OCX_VERSION`
   (`ocx/private/versions.bzl`) and `dist/dist.json` bump **together**.
3. Extension impls may read `module_ctx.os`, read the tag's `ocx.lock` with
   `module_ctx.read` (its `ocx.toml` only on a miss), read the `OCX_INSTALL_*`
   variables, download ocx and run `ocx vendor --manifest-only`, and only to
   compute facts that miss. Nothing else: no other getenv, no watch of ambient
   config, never a credential or secret variable. The run inherits the process
   environment (see the env paragraph of the CLI contract). Everything else
   that touches the host stays in repository rules.
4. Every sysexit **reachable from a repository rule** (table in the CLI
   contract section) maps to a fail() naming the user-fixable action, or the
   condition to check, and the exact command where one exists; 75 is retried
   before it ever reaches a
   fail(). 82 is deliberately absent from `SYSEXIT_HINTS` — only
   `ocx config setup` / `ocx self setup` raise it, and invariant 5 forbids a
   repo rule from running either; so is 86, raised only by publishing.
5. Managed config is hint-only — never run `ocx config setup/update` from a
   repo rule, and likewise never `ocx self setup`, nor `ocx shell allow` /
   `ocx shell revoke`, which write and delete the per-project consent stamp
   under `$OCX_HOME/state/projects/`. `ocx vendor` writes no consent stamp.

## ocx CLI contract

- The only ocx argv rules_ocx builds is `ocx --format json vendor …` and
  `ocx --format json package vendor …` (`scripts/check_ocx_interface.py` fails
  on any other, and on any ocx-home path segment). Root flags precede the
  subcommand: `--format json --project <toml> --index … --blob-dir …`.
- `manifest.json` (`schema_version` 1) is read by
  `ocx/private/vendor_manifest.bzl`, which treats it as untrusted: every path
  is label-safe, stays under its `content_dir`, link targets are relative and
  are resolved through the declared links so a chain cannot climb out of the
  tree, exact duplicate paths are refused (paths that differ only by case are
  legitimate package content, e.g. terminfo), tag and tool names are one safe
  segment. A manifest whose platform differs from the requested one, or a
  Windows set that lists links, fails.
- Sysexits: 64 usage · 65 data/stale · 69 unavailable · 74 io · 75 transient
  (retried twice) · 77 permission · 78 config · 79 not found · 80 auth · 81
  blocked by policy · 83 transparency log unavailable · 85 unsupported signing
  key backend. `SYSEXIT_HINTS` (`ocx/private/repo_utils.bzl`) maps each code a
  repository rule can reach to a `fail()` naming the user-fixable action.
- Config precedence: system (`/etc/ocx/config.toml`) → user config dir →
  `$OCX_HOME/config.toml` → managed-config snapshot → `OCX_CONFIG` →
  `--config`. The scratch `OCX_HOME` removes the last two `$OCX_HOME` tiers
  from the client's reach; the tag's `config` label sets `OCX_CONFIG`, and
  `no_config` prunes the discovered tiers.
- Env handling is one classified table, `OCX_ENV_CLASSES`
  (`ocx/private/repo_utils.bzl`): *site* (forwarded verbatim by repository
  rules: mirrors, insecure registries, offline, index, default registry,
  extra CA certs, …), *translucent* (ambient unless a tag attr
  overrides: `OCX_CONFIG`, `OCX_SIGSTORE_TRUSTED_ROOT`,
  `OCX_NO_CONFIG`), *explicit* (`OCX_NO_VERIFY`, `OCX_ALLOW_YANKED`, only from
  `ocx.policy()`) and *pinned* (a fixed value on every call). The extension
  reads no variable of the table (invariant 3): its `ocx vendor --manifest-only`
  run takes the pinned and explicit rows and the tag's attrs, and inherits the
  rest of the process environment through `module_ctx.execute`. That is the
  design: routing configuration (mirrors, registries, index) and credentials
  must reach it, patches never reach a vendored environment, and any difference
  they cause in the tool list is caught by the set repository's cross-check.
  `OCX_MIRRORS`, `OCX_INSECURE_REGISTRIES` and `OCX_EXTRA_CA_CERTS` can weaken
  transport and `OCX_SIGSTORE_TRUSTED_ROOT` trust unless the
  `sigstore_trusted_root` attr is set; digest-pinned references and a locked
  system config are the mitigation.

## Workflow

- `task verify` — lint + workflow lint + basic-tier tests + examples + site build. Run after any change.
  CI (`verify-basic` per PR, `verify-deep` nightly) runs the `ci:*` tasks of `taskfile.yml`; deep covers
  the Bazel-version matrix, examples, BCR parity, pin completeness and offline determinism.
- `bazel test //...` — unit tests (no network) + docs freshness.
- Examples under `examples/*` are the integration tests (live ocx.sh
  registry — dogfooding); each is its own module with `local_path_override`.
  No example or e2e module sets `config`, `no_config`,
  `sigstore_trusted_root` or `isolated_home` — that tier has unit coverage
  only. `examples/package` does declare `ocx.policy()` at its defaults, so the
  tag's acceptance is covered end to end; its weakening effects are not.
- `task site:lighthouse` — Lighthouse 100x4 + budgets (`site/lighthouse.budgets.mjs`) over every built
  site page, mobile; `task site:test` is its offline unit test. CI runs both on site PRs.
- `bazel run //docs:update` regenerates stardoc output; CI diff_tests it.
- `task dist:update` refreshes `dist/dist.json`.
- Conventional Commits; changelog via git-cliff; never push to remote;
  never commit to `main`.

## Dogfooding

The dev toolchain comes from the committed `ocx.toml`/`ocx.lock`
(bazelisk, actionlint, buildifier, git-cliff, task, hawkeye, lychee, shellcheck, grouped by CI role:
`ocx exec -g lint -- <tool>`; the lint group is also what `@dev_tools` exposes to Bazel).
ocx's prompt hook activates it: `ocx self setup --hook` once, then
`ocx shell allow` in this checkout (the hook stays inert until the project
has a consent stamp); `ocx exec -- <cmd>` for a one-off. buildifier comes from ocx
(`task buildifier:check` / `buildifier:fix`); there is no `buildifier_prebuilt` dev dependency.

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
