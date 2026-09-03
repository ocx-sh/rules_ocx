# rules_ocx

Bazel module extension that provisions development tools through
[OCX](https://ocx.sh) — the OCI-backed package manager. Bootstrap the pinned
`ocx` CLI inside a repository rule, then let it resolve, download, and compose
tool packages; consume them as ordinary runnable Bazel targets.

rules_ocx deliberately **never re-implements OCX internals in Starlark**. All
resolution goes through the `ocx` binary; the durable contracts are
`ocx.lock` digests and the OCI manifests.

## Quick start

```starlark
# MODULE.bazel
bazel_dep(name = "rules_ocx", version = "0.1.0")

ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")

# Flagship: provision the workspace toolchain from ocx.toml + ocx.lock.
ocx.project(
    name = "tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
)

# Ad-hoc: a single package, tag-floating or digest-pinned.
ocx.package(
    name = "jq",
    package = "ocx.sh/jqlang/jq:latest",
)

use_repo(ocx, "jq", "tools")
```

```starlark
# BUILD.bazel
genrule(
    name = "pretty",
    srcs = ["data.json"],
    outs = ["pretty.json"],
    cmd = "$(location @jq//:jq) . $< > $@",
    tools = ["@jq//:jq"],
)

sh_test(
    name = "lint",
    srcs = ["lint_test.sh"],
    data = ["@tools//:shellcheck"],
    env = {"SHELLCHECK_BIN": "$(location @tools//:shellcheck)"},
)
```

Every executable the toolchain's packages declare as their public surface
(`ocx inspect --closure`, default group) becomes a runnable target
`@tools//:<name>`; a host-platform `ocx.package()` exposes its own the same
way at `@<name>//:<bin>` (with `platforms = [...]` the launchers live in the
per-platform repos — the `@<name>` hub aliases only `//:content`, or the lazy
`bins` names). A declared name that no directory on the composed PATH holds is
dropped silently — a missing target raises no error, so check
`bazel query @tools//...` if one you expected is absent.

Private executables stay out of the target list only while every package
declares a complete `binaries` surface. If one does not, the fetch falls back
to scanning PATH, which exposes that package's private executables too;
`//:env.bzl`'s `OCX_SCANNED_PACKAGES` names the packages that forced it.
`ocx.package()` also symlinks the package's `entrypoints/` next to
`content/` — a separate ocx list, not targets.

## How it works

1. The `ocx` extension creates `@ocx_tool` by downloading the **pinned** ocx
   release listed in the vendored [`dist/dist.json`](dist/dist.json) snapshot
   of `https://setup.ocx.sh/dist.json` (sha256-verified).
2. `ocx.project()` / `ocx.package()` repository rules shell out to that
   binary: `ocx lock --check` (staleness gate), `ocx pull` / `ocx package
   install` (populate the content-addressed store), `ocx --format json env`
   (composed environment).
3. Packages live in the shared `OCX_HOME` store (`~/.ocx` by default) —
   content-addressed, digest-pinned, hardlink-composed. Repository rules run
   unsandboxed, so the store is shared with your shell, direnv, and CI,
   fetched once per machine.
4. Generated repos contain launcher scripts (skylib `native_binary`) that
   apply the package environment and exec the store binaries — usable in
   `tools =`, `$(location …)`, `sh_test` `env`, and `bazel run`.

## Corporate mirrors

Same knobs as the [setup.ocx.sh installer](https://github.com/ocx-sh/setup.ocx.sh),
honored by the repository rules:

| Env var | Effect |
| --- | --- |
| `OCX_INSTALL_DIST_URL` | Fetch the release manifest from your mirror instead of the vendored snapshot. The mirrored manifest is itself verified when it is named `<sha256>.json` (the form the setup.ocx.sh installers write); any other name is fetched unverified. |
| `OCX_INSTALL_MIRROR_URL` | Rewrite the ocx binary download to `<mirror>/<tag>/<filename>`. The artifact sha256 is enforced either way — a mirror can move bytes, not change them. |
| `OCX_MIRRORS` | JSON map `{"ocx.sh": "https://mirror.corp/ocx"}` — package pulls go to the mirror; `ocx.lock` digests stay keyed to the upstream host, so lockfiles are portable. |
| `OCX_INSECURE_REGISTRIES` | Allow plain-HTTP mirrors (comma list). |
| `OCX_AUTH_<REGISTRY>_{TYPE,USER,TOKEN}` | Registry credentials (also: docker config). Not enumerable by Bazel — run `bazel fetch --force` after changing auth. |

Passed through to repo rules as well: `OCX_INDEX`, `OCX_OFFLINE`,
`OCX_FROZEN`, `OCX_REMOTE`, `OCX_JOBS`, `OCX_DEFAULT_REGISTRY`, `OCX_CONFIG`,
`OCX_NO_CONFIG`, `OCX_MANAGED_CONFIG`, `OCX_PATCHES`, `OCX_PATCH_SNAPSHOT`,
`OCX_SIGSTORE_TRUSTED_ROOT` — together with `OCX_MIRRORS` and `OCX_INSECURE_REGISTRIES` above, that is
the whole forwarded set. `OCX_HOME` is resolved rather than forwarded: it
selects the store the rules point ocx at.

The three path-valued ones (`OCX_CONFIG`, `OCX_PATCH_SNAPSHOT`,
`OCX_SIGSTORE_TRUSTED_ROOT`) must be **absolute**: a repository rule runs from
Bazel's own working directory, so a relative value names a different file than
it does in your shell and Bazel cannot watch it — it is refused rather than
forwarded unwatched. `file://` on the trusted root is the one accepted
spelling (ocx parses that one as a file reference): it is forwarded verbatim
and watched at the path behind the prefix, which must itself be absolute. Any
other scheme, and `file://` on the other two, are refused like any relative
value.

`OCX_NO_VERIFY` and `OCX_ALLOW_YANKED` are **not** among them: those two knobs
are never read from the environment and are written on every invocation, so an
exported value cannot switch verification off or let a yanked package through.
Ask for either explicitly with `ocx.policy(...)` below.

**Migrating**: `OCX_ALLOW_YANKED` used to be forwarded. A CI job that exported
it now resolves as if it had not — silently, with no error. (`OCX_NO_VERIFY` is
new with ocx 0.6.0 and was never forwarded.) Move the intent into MODULE.bazel:

```starlark
# before: OCX_ALLOW_YANKED=1 in the CI environment
ocx.policy(allow_yanked = True)   # after
```

That is the explicit pair, not the whole surface. `OCX_SIGSTORE_TRUSTED_ROOT`
is site-authoritative: with no `sigstore_trusted_root` attr set, an exported
value replaces the trust anchor signatures are checked against, and
`OCX_MIRRORS`/`OCX_INSECURE_REGISTRIES` redirect the transport. Set
`sigstore_trusted_root` and pin digests (`pins`, or an `@sha256:` reference) to
close both.

`OCX_PROJECT`, `OCX_GLOBAL`, `OCX_QUIET`, `OCX_NO_PROJECT` and
`OCX_NO_CONFIG_REFRESH` are deliberately *not* passed through — each carries a
fixed value on every invocation. Project context comes from the explicit
`--project` flag (which `--global` refuses to combine with), `--quiet` would
suppress the JSON reports the rules parse, `OCX_NO_PROJECT` closes the
directory walk a fetch would otherwise run from Bazel's own working directory,
and the managed-config refresh wants a TTY no repo rule has.

## Weakening posture: `ocx.policy`

```starlark
# MODULE.bazel — root module only, at most one tag; every attr defaults off.
ocx.policy(
    allow_unverified = True,       # OCX_NO_VERIFY=1 on every ocx call
    allow_yanked = True,           # OCX_ALLOW_YANKED=1
    sigstore_trusted_root = "//:trusted-root.json",
)
```

With no tag the defaults apply and nothing is loosened. The tag cannot *enable*
verification: ocx attaches that only under an operator-configured
`[[trust.policy]]`, so these attrs can only decline to switch it off. A
non-root or duplicate tag fails the build before any repository is declared.

Root-only governs the **tag**. The same three attrs also sit on the public
`ocx_project_repo` / `ocx_package_repo` rules in `//ocx:defs.bzl`, so a module
that declares one of those directly — instead of going through this extension —
sets its own posture, and nothing stops it.

## Managed config & patches

ocx layers its site configuration system → user → `$OCX_HOME/config.toml` →
managed-config snapshot → `OCX_CONFIG` → `--config`, and the repository rules
run inside that chain rather than around it: whatever mirrors, registries and
`[patches]` your host config declares apply to the fetch.

Because Bazel can only invalidate on inputs it knows, **every discovered config
path is watched** (with three exceptions, below) — including the ones that do
not exist yet. Creating
`~/.ocx/config.toml`, or letting `ocx config update` refresh the managed
snapshot, refetches the ocx repos. That is deliberate: a config edit that
changes what a fetch resolves must not survive as a stale cache entry.

Three exceptions: `/etc/ocx/config.toml` is skipped on Windows (ocx still
reads that literal path there, drive-relative, but it is not an absolute
Windows path and cannot be watched as spelled — a documented gap),
`isolated_home = True` drops the `$OCX_HOME`-rooted tiers (they sit
inside the repository being fetched, which Bazel cannot watch), and a lazy
`ocx.package(bins = …)` watches no tier at all — it never runs ocx at fetch
time, so its launcher resolves the host config live on first execution
instead. `ocx.project(bins = …)` is unaffected: it builds — and watches — the
environment before the lazy branch, because its `ocx lock --check` needs it.

Two attrs on both `ocx.project()` and `ocx.package()` take the host out of the
loop:

```starlark
ocx.project(
    name = "dev_tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    config = "//:ocx-config.toml",  # committed site config
    no_config = True,               # ignore every discovered tier
)
```

`config` sets `OCX_CONFIG` (overriding an ambient one) and is watched;
`no_config` sets `OCX_NO_CONFIG=1`, dropping the system, user, `$OCX_HOME` and
managed tiers while keeping an explicit `config`. It also blanks an ambient
`OCX_CONFIG`, `OCX_PATCHES` and `OCX_PATCH_SNAPSHOT`, which `OCX_NO_CONFIG`
alone does not prune — so a CI job that exports `OCX_PATCH_SNAPSHOT` and sets
`no_config = True` loses its patch pinning unless it also passes the
`patch_snapshot` attr, and nothing diagnoses that. Together the two attrs are
the hermetic pattern — the build reads exactly the file you committed. Lazy
launchers (`bins`) carry both into their runfiles, so a deferred
`ocx exec` / `ocx package exec` sees the same configuration the fetch did —
which also means each file is copied into the repository and uploaded as an
input with every action: keep credentials out of them.

**Patches** are companion packages a site config composes onto a base package's
environment (a `[patches]` table; never the project `ocx.toml`). `ocx lock
--check` deliberately does not cover them, so freeze them explicitly:

```console
$ ocx patch freeze          # writes patches.snapshot.json next to ocx.lock
```

Commit that file and point `patch_snapshot = "//:patches.snapshot.json"` at
it — it sets `OCX_PATCH_SNAPSHOT` and pins the companion digests. Without it,
companions resolve at fetch time. `ocx patch sync` is the only way to refresh
the snapshot; it mutates and needs the network (offline it exits 81).

**Managed config in CI**: a `[managed]` source that is required (the default)
but has never been synced exits **78 on every ocx command** — `lock --check`
included, before any network call. The repository rules never run `ocx config
setup` or `ocx config update` themselves; adoption stays an explicit human
step. The failure message names the command to run, and `no_config = True` /
`OCX_NO_CONFIG=1` opts the build out of the tier entirely. The background
snapshot refresh is pinned off (`OCX_NO_CONFIG_REFRESH=1`) — it wants a TTY no
repository rule has.

## Reproducibility

- **Project tier** is fully pinned by your committed `ocx.lock` (per-platform
  sha256 digests). A stale lock fails the fetch with instructions. In ocx 0.6.0
  both `ocx pull` and `ocx exec` record a shell-activation consent stamp under
  `$OCX_HOME/state/projects/`, keyed on the project directory they were pointed
  at; it only matters once you install the ocx shell hook, and `ocx shell
  revoke` clears it. The eager `ocx.project` fetch stamps **your checkout**
  (`isolated_home = True` keeps that stamp inside the repository instead). A
  lazy `ocx.project(bins = …)` launcher stamps on every `ocx exec`, i.e. at
  action time on every machine that runs the tool — but it points ocx at the
  fetched repository's own copy of `ocx.toml`, so the stamp keys on an
  output-base directory you never `cd` into and that can activate nothing.
  `bazel clean --expunge` removes that directory; the stamp itself lives in
  the shared `$OCX_HOME`, and `ocx shell revoke` is what removes it.
  `isolated_home` is not the escape there: it is incompatible with `bins`,
  since a lazy launcher must resolve the store on whatever machine executes
  it.
- **Package tier**, pick one:
  - `index = "//:index"` — commit an index snapshot
    (`ocx --index index index update ocx.sh/jqlang/jq`); tags resolve frozen from it,
    so `:latest` stays reproducible until you refresh the snapshot. OCX's
    native tag locking, works across all `platforms`.
  - `pins = {"linux/amd64": "sha256:…"}` — explicit per-platform manifest
    digests (reported by `ocx package install -p <platform>`).
  - Neither: floating tags resolve at fetch time; the fetch log prints the
    resolved digest.
- Remote execution is a non-goal for now: launchers reference absolute
  `OCX_HOME` store paths (the nixpkgs model). Use `isolated_home = True` to
  keep a store per repository if you need stricter isolation — at the cost
  of a full per-repository re-download, and it cannot be combined with
  `bins` (lazy provisioning) below.

## Lazy provisioning

Add `bins = [...]` to `ocx.project()` or `ocx.package()` and nothing is
pulled at fetch time: each name becomes a launcher that re-enters
`ocx exec` / `ocx package exec`, materializing content on its first
execution. Tool content never becomes a Bazel action input — actions key on
the lockfile (project) or the digest-pinned reference (package, so `pins`
or `@sha256:` is required) — and the POSIX launchers resolve everything
through runfiles, so the keys are identical across machines. The result: a
fully remote-cached build downloads **no tool content at all**, even on a
pristine machine. The first cache-miss action on a machine pays the pull
once, into the shared content-addressed store.

Trade-offs: `bins` names are not validated at fetch time, `//:content` /
`//:env.bzl` are unavailable (they would need materialized bytes), and the
first executions on a cold machine race on the store
([ocx#179](https://github.com/ocx-sh/ocx/issues/179)).

## API docs

Generated by stardoc into [`docs/`](docs/). Regenerate with
`bazel run //docs:update`.

## Examples

- [`examples/project`](examples/project) — workspace toolchain from ocx.toml/lock, eager + lazy
- [`examples/package`](examples/package) — ad-hoc packages: floating, frozen-index, digest-pinned, lazy
- [`examples/cross_platform`](examples/cross_platform) — per-platform repos + transitions

## License

Apache-2.0. See [LICENSE](LICENSE).
