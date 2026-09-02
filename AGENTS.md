# rules_ocx (bazel-ocx)

Bazel module extension + repository rules provisioning tools via the OCX
package manager (https://ocx.sh, source at `../ocx`). Successor to the
in-tree draft ocx-sh/ocx#12.

## Architecture (load-bearing)

- **One extension** `//ocx:extensions.bzl%ocx`, tag classes `download`
  (root-only), `project` (root-only), `package`, `policy` (root-only, at most
  one). Extension impl is a pure function of tags → `reproducible = True`. All
  host detection happens in repository rules.
- **`@ocx_tool`**: pinned ocx binary, downloaded per the vendored
  `dist/dist.json` (snapshot of https://setup.ocx.sh/dist.json),
  sha256-enforced. **Floor: ocx ≥ 0.6.0** (`MIN_OCX_VERSION`), because the
  lazy project launcher re-enters `ocx exec` (`ocx run` is
  hidden-and-warning in 0.6, deleted in 0.7) and `package install` takes
  `--no-verify` — `ocx.download(version = …)` below it fails before any
  download. Mirror knobs (site settings, env-only — no attrs):
  `OCX_INSTALL_DIST_URL` (manifest), `OCX_INSTALL_MIRROR_URL` (artifact host,
  `<mirror>/<tag>/<filename>`). A manifest URL whose last path segment is
  `<64 lowercase hex>.json` (www-setup's `dist_pin_digest` convention) is
  fetched with that digest enforced; any other name is fetched unverified, as
  before.
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
- **Policy tier** (`ocx.policy`, root-only, at most one): the build's
  *signature and yank* posture is a function of `MODULE.bazel` alone.
  `allow_unverified` (→ `OCX_NO_VERIFY` plus `--no-verify` on `package
  install`) and `allow_yanked` (→ `OCX_ALLOW_YANKED`) are **explicit-only** —
  never read from the ambient environment, always written, so an exported CI
  variable cannot decide what a build verifies or accepts. A non-root or
  duplicate tag `fail()`s before any repo is declared — root-only governs the
  `ocx.policy` **tag**, not the module graph: a module driving
  `ocx_project_repo`/`ocx_package_repo` from `//ocx:defs.bzl` directly sets
  its own attrs. `resolve_policy()` is the pure reducer; the resolved triple
  is threaded into every
  `ocx_project_repo`/`ocx_package_repo` (the hub gets none — it runs no ocx).
  It cannot *enable* verification: ocx attaches that only under an operator
  `[[trust.policy]]`, so with none configured the defaults are a no-op, and
  `no_config = True` prunes the discovered tier that would carry one.

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
   repo rule, and likewise never `ocx self setup`, nor `ocx shell allow` /
   `ocx shell revoke`, which write and delete the per-project consent stamp
   under `$OCX_HOME/state/projects/`. (0.6.0's `ocx shell` group is `allow`,
   `completion`, `revoke`, `state`; the last two only read, but a fetch has no
   use for either.)
   `ocx pull` and `ocx exec` stamp shell-activation consent, unconditional in
   0.6.0 (no flag, env, TTY or hook gates it), at
   `$OCX_HOME/state/projects/<key>/consent.json`, keyed on the `--project`
   toml's canonical dir. Once the shell hook is installed that stamp lets the
   project `[env]` apply on `cd` unprompted; `lock --check`, `env` and
   `inspect --closure` stamp nothing. Documented side effect of the tiers that
   pull — [ocx-sh/ocx#400](https://github.com/ocx-sh/ocx/issues/400) asks for
   `OCX_NO_CONSENT` (one pinned row once it lands). Only the eager
   `ocx.project` tier stamps the user's checkout, and that is the case
   `isolated_home = True` confines to the repository; the lazy `bins`
   launchers' `ocx exec` stamps at action time but passes
   `--project "$(rlocation <repo>/ocx.toml)"`, so it keys on an output-base
   copy that can activate nothing (`bazel clean --expunge` drops that
   directory, not the stamp, which lives in the shared `$OCX_HOME`) — and
   `isolated_home` is no escape there, both lazy tiers `fail()` on `bins` +
   `isolated_home` (`project.bzl`, `package.bzl`). `ocx shell revoke` is the
   only thing that clears a stamp.

## Two-tier ocx CLI contract (verified against 0.6.0)

- `ocx --format json env` → `{"entries":[{"key","value","type":"path"|"constant"|"list"
  [,"separator"]}], "binaries":[…],"entrypoints":[…],"integrations":[…],
  "advisories":[…]}` (ordered). Parsing `.entries` only stays correct — the
  three sibling arrays are always serialized (empty when there is nothing) and
  none becomes a target; `entries[].source` appears only with `--show-patches`,
  as the object `{kind:"patch", rule, companion}`. A consumer
  applies entries by **prepending** each `path` one in list order
  (move-to-front dedup), so effective search precedence per key is the
  *reverse* of the list — ocx pushes the synthetic `<pkg>/entrypoints` PATH
  entry last precisely so entrypoint launchers shadow `bin/`. A `list` entry
  instead **appends** at the back with move-to-back dedup, folded on its
  `separator` (absent ⇒ a space), and an empty value is a no-op that must not
  bring the key into existence — `append_unique()`/`fold_lists()` replay both.
  A `type` outside those three is shape drift → fail() naming the pin to move
  in the consumer's terms (upgrade rules_ocx, or `ocx.download(version = …)`),
  never the private constant; folding it into a constant would silently
  *replace* an environment ocx would have extended.
- **Lazy composition is refused on every eager path** (`EAGER_LAZY_MODE`).
  `ocx pull` writes a shim tree instead of content when the ladder
  `--lazy-mode ▸ [package."<id>"] ▸ [group.<g>] ▸ toolchain ▸ OCX_LAZY_MODE ▸
  never` resolves to `always`, and `env`/`which` then report it — a launcher
  baked against that fetches its tool inside a Bazel action. Only the CLI tier
  outranks a project's own ocx.toml, so `OCX_LAZY_MODE` is *not* the lever. The
  flag is accepted by exactly seven composing commands (`env`, `exec`, `pull`,
  `direnv export`, `package env`, `package exec`, `package which`); `package
  install`/`select` always materialize and reject it, `inspect --closure` never
  composes. The `bins` tiers pass it nowhere — deferring at run time is their
  whole point.
- `ocx --format json package install <pkg>` → `{"<raw>":{identifier
  (digest-pinned), metadata, path}}`; `package which` →
  `{"<raw>":{"path":"<dir>","kind":"package"|"shim"}}` (**0.5.8: an object, not
  a bare string** — a deferred tool has no package root yet, so ocx reports its
  shim tree and names which of the two it answered with; `kind != "package"` is
  a fail(), since only a package root has the `content/` the rule symlinks);
  `package env` → entries as above. Only
  `identifier` and the `which` path/kind are read — 0.5.5 replaced the
  recorded-platform `metadata` field with a build receipt, invisibly here.
- `ocx --format json [package] inspect --closure` →
  `{"packages":[{identifier, closure:{deps, surface:{interface, private},
  conflicts}}]}`; each surface is `{binaries:[{name, package}], entrypoints,
  env, integrations, binaries_complete}`. Only the entry's `identifier` and
  `closure.surface.interface` (`binaries[].name`, `entrypoints[].name`,
  `binaries_complete`) are read — the command surface is the **union** of the
  two arrays, deduped by name. A name may appear in both; which *file* it
  resolves to is composed-PATH precedence (the `entrypoints/` launcher
  shadows `bin/`), never array order. `private` is the private-axis projection (which also repeats
  the public entries) and never becomes a target. `closure` is omitted for an
  unresolved binding (a candidate list, or one projected off ocx.lock); that,
  like any other shape drift — including an absent `entrypoints`, which
  `SurfaceOut` always serializes — is a fail() naming the pin to move in the
  consumer's terms (upgrade rules_ocx, or `ocx.download(version = …)`), not a
  mapped sysexit. `binaries_complete = false` means the claim is
  possibly incomplete → fall back to scanning PATH; it covers `binaries`
  only, entrypoint claims are always authoritative.
- `ocx lock --check`: exit 0 current / 65 stale / 78 missing. Offline.
- Root flags before subcommand: `--format json --project <toml>`.
- Sysexits: 64 usage · 65 data/stale · 69 unavailable · 74 io · 75 transient
  (retried) · 77 permission · 78 config error (missing/unsupported lock **or**
  a required-but-unsynced managed config) · 79 not found (incl. a required
  patch companion) · 80 auth · 81 blocked by policy · 82 dirty rc · 83
  transparency log unavailable · 84 registry without the OCI Referrers API ·
  85 unsupported signing key backend. 0.5.3 moved
  a registry timeout or rate-limit from 69 to 75; 69 stays reachable (oci
  client, project resolve, index), so both hints earn their place. 0.6.0's 83
  and 85 are raised only inside `maybe_auto_verify`, the gate an operator
  `[[trust.policy]]` attaches to a *materializing* fetch — of the eight
  commands these rules run that is the project tier's `pull` and `env` plus
  `package install` and `package env`, never `lock --check`, `package which`
  or either `inspect --closure`. 84 is mapped for the contract only: 0.6.0's
  verify path folds `ReferrersUnsupported` into 79, leaving 84 write-path
  only, which no repo rule reaches. None of the three is retried — a
  transparency-log outage is settled for longer than three round-trips and 85
  is deterministic — and the 83 and 84 hints offer
  `ocx.policy(allow_unverified = True)` as their last route.
- Config precedence: system (`/etc/ocx/config.toml`, literal on every OS —
  on Windows Rust resolves it drive-relative, so `C:\etc\ocx\config.toml` is
  a real tier there; the repo rules skip watching it anyway because that
  spelling is not an absolute Windows path and the drive is not knowable at
  fetch time — a documented gap, not an absent tier) →
  user config dir → `$OCX_HOME/config.toml` → managed-config snapshot
  (`$OCX_HOME/state/managed-config/`) → `OCX_CONFIG` → `--config`.
- **Sigstore trusted root** — its own six-rung ladder, only partly a config
  tier: `--sigstore-trusted-root` ▸ `OCX_SIGSTORE_TRUSTED_ROOT` ▸
  `[trust.sigstore]` in the config.toml tiers ▸
  `$OCX_HOME/sigstore/trusted-root.json` ▸ the Rekor trust-root cache ▸ a live
  TUF fetch. `no_config` prunes rung 3 with the rest of the discovered tiers,
  but not rungs 2 and 4 — which is why the `$OCX_HOME` rung is watched outside
  the `no_config` gate: with `no_config` plus a `config` label carrying
  `[[trust.policy]]`, ocx still reads it. The rungs rules_ocx touches are
  `OCX_SIGSTORE_TRUSTED_ROOT` (translucent: the `sigstore_trusted_root` attr
  overrides an ambient value) and the convention path
  (`sigstore_trust_root_path()`, hand-constructed, watch fails open —
  re-verify on every bump). `isolated_home` relocates `OCX_HOME` and so drops
  rung 4; resolution then falls through to the Rekor trust-root cache and then
  a live TUF fetch, and offline it stops at the cache and fails outright, as
  ocx ships no embedded root.
- `[patches]` is a **site-config tier only** — never the project ocx.toml.
  Composed companions are invisible in the `package install` JSON report, and
  `lock --check` never covers them; `ocx patch freeze` →
  `patches.snapshot.json` (`OCX_PATCH_SNAPSHOT`) is the only freeze,
  `ocx patch sync` the only refresh (mutating, offline → 81). 0.5.6 keys
  companions by **tag** and bumped the snapshot to V2, dropping V1 — a
  `patch_snapshot` frozen by an older ocx exits 65, which is why that hint
  names `ocx patch freeze` alongside `ocx lock`. Companion pins moved out of
  the shared local index into `$OCX_HOME/state/patch-companions/`, still under
  the `state/` root `isolated_home` relocates.
- Env handling is **one classified table**, `OCX_ENV_CLASSES`
  (`ocx/private/repo_utils.bzl`), keyed by variable name — a new ocx variable
  is one row plus its class, not four structures that can disagree. Four
  classes:
  - *site* (10, forwarded verbatim): OCX_MIRRORS, OCX_INSECURE_REGISTRIES,
    OCX_OFFLINE, OCX_FROZEN, OCX_REMOTE, OCX_JOBS, OCX_INDEX,
    OCX_DEFAULT_REGISTRY, OCX_MANAGED_CONFIG, OCX_PATCHES. `OCX_MIRRORS` and
    `OCX_INSECURE_REGISTRIES` are the residual ambient *transport*-weakening
    path the policy tier does not close — a CI image exporting both routes
    every fetch at a plain-HTTP host of its choosing. Digest pinning (`pins`
    or an `@sha256:` reference) is the mitigation; a system
    `/etc/ocx/config.toml` locking the host shut is the other, and
    `no_config = True` prunes that one. `OCX_SIGSTORE_TRUSTED_ROOT`
    (*translucent*, below) is the third residual and the only one that weakens
    *trust* rather than transport: with no `sigstore_trusted_root` attr set it
    replaces the anchor ocx's auto-verify hook checks against, so
    `allow_unverified = False` is not by itself a claim about *whose*
    signature verified. Setting the attr closes it.
  - *translucent* (4, ambient unless an attr overrides): OCX_CONFIG
    (`config`), OCX_PATCH_SNAPSHOT (`patch_snapshot`),
    OCX_SIGSTORE_TRUSTED_ROOT (`sigstore_trusted_root`), OCX_NO_CONFIG
    (`no_config`).
  - *explicit* (2, **never** read from the environment, always written from
    the resolved `ocx.policy()`): OCX_NO_VERIFY, OCX_ALLOW_YANKED.
  - *pinned* (5, a fixed value on every invocation): OCX_PROJECT "",
    OCX_GLOBAL "0", OCX_QUIET "0", OCX_NO_PROJECT "1",
    OCX_NO_CONFIG_REFRESH "1". A lazy launcher re-exports all of them but
    OCX_QUIET.
  Env passthrough (getenv-declared, all 14) is exactly site ∪ translucent.
  `OCX_ALLOW_YANKED` left that set **in this release** — ocx 0.6.0 still reads
  it, but rules_ocx no longer forwards an ambient value and instead always
  writes it (**breaking**: it no longer works as an ambient escape hatch,
  write `ocx.policy(allow_yanked = True)`) — and `OCX_SIGSTORE_TRUSTED_ROOT`
  joined it. OCX_HOME is resolved, not forwarded.
  Never forwarded and needing no neutralization: OCX_LAZY_MODE /
  OCX_LAZY_REPORT (outranked by the `--lazy-mode never` above), OCX_ENV
  (ocx strips an inherited one on every compose; its decoder refuses `OCX_*`
  keys outright), and OCX_CEILING_PATH (its only reader is the project CWD
  walk, which `OCX_NO_PROJECT=1` closes).

## Workflow

- `task verify` — lint + unit tests + examples. Run after any change.
- `bazel test //...` — unit tests (no network) + docs freshness.
- Examples under `examples/*` are the integration tests (live ocx.sh
  registry — dogfooding); each is its own module with `local_path_override`.
  No example or e2e module sets `config`, `no_config`, `patch_snapshot`,
  `sigstore_trusted_root` or `isolated_home` — that tier has unit coverage
  only. `examples/package` does declare `ocx.policy()` at its defaults, so the
  tag's acceptance is covered end to end; its weakening effects are not.
- `bazel run //docs:update` regenerates stardoc output; CI diff_tests it.
- `task dist:update` refreshes `dist/dist.json`.
- Conventional Commits; changelog via git-cliff; never push to remote;
  never commit to `main`.

## Dogfooding

The dev toolchain comes from the committed `ocx.toml`/`ocx.lock`
(bazelisk, actionlint, git-cliff, task, hawkeye, lychee, shellcheck).
`direnv allow`, or 0.6.0's prompt hook (`ocx self setup --hook` once, then
`ocx shell allow` in this checkout — the hook stays inert until the project
has a consent stamp); `ocx exec -- <cmd>` for a one-off. buildifier is not in the
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
