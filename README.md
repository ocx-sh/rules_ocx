<!-- doc_type: readme -->
# rules_ocx

Bazel module extension that provisions development tools through
[OCX](https://ocx.sh), the OCI-backed package manager. It vendors each tool
set with `ocx vendor`. Tools run as ordinary Bazel targets in local actions
and on remote executors that have no network and no `ocx`.

rules_ocx deliberately **never re-implements OCX internals in Starlark**. All
resolution goes through the `ocx` binary. The one `ocx` document it parses is
the `manifest.json` that `ocx vendor` writes. The durable contracts are the
`ocx.lock` digests and the OCI manifests.

## Requirements

- Bazel 9. The module declares `bazel_compatibility = [">=9.0.0"]`.
- An `ocx` release that has `ocx vendor` and writes manifest schema version 2.
  rules_ocx downloads a pinned `ocx` itself and runs `ocx vendor` for every set.
- On Windows, long paths matter: see
  [Windows: path length](docs/guides/windows-path-length.md). A build needs no
  `--enable_runfiles`, because the launcher also reads the runfiles manifest.
- `platforms` on every `ocx.project` and `ocx.package` tag.

## Quick start

```starlark
# MODULE.bazel
bazel_dep(name = "rules_ocx", version = "0.5.1")

ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")

# Flagship: provision the workspace toolchain from ocx.toml + ocx.lock.
ocx.project(
    name = "tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    platforms = [
        "darwin/arm64",
        "linux/amd64",
        "windows/amd64",
    ],
)

# Ad-hoc: a single package, digest-pinned.
ocx.package(
    name = "jq",
    package = "ocx.sh/jqlang/jq:latest@sha256:c295300441831e002c0ba54df8e6126cdd4064c63be2464bdc6b68d0012beec6",
    platforms = [
        "darwin/arm64",
        "linux/amd64",
        "windows/amd64",
    ],
)

use_repo(ocx, "jq", "tools")

register_toolchains(
    "@jq//:all",
    "@tools//:all",
)
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

`platforms` names every platform an action may execute on, spelled as the
lock keys it. Each one must be a platform the lock serves, or the build fails
and names the platform. A build fetches only the set of the platform it
executes on.

Every executable the selected tools declare becomes a target `@<name>//:<tool>`
of the hub. The files of each platform are in the set repository
`@<name>_<platform>`, for example `@tools_linux_amd64//:set`. Every character
that is not a lowercase letter or digit becomes `_`.

A tag vendors the groups it names as one set. Every action that uses one of
its tools keys on the whole set. Declare one `ocx.project` tag per group a
target needs, so that a change to an unrelated group leaves its key alone.

## How it works

The whole model is on one page: [The vendor model](https://ocx.sh/integrations/bazel/concepts/design/).

1. The `ocx` extension creates `@ocx_tool` by downloading the **pinned** ocx
   release listed in the vendored [`dist/dist.json`](dist/dist.json) snapshot
   of `https://setup.ocx.sh/dist.json` (sha256-verified).
2. For each tag, the extension runs `ocx vendor --manifest-only` once per
   platform and records which tools exist as a fact in `MODULE.bazel.lock`.
   While the fact is current it runs no `ocx` and makes no request.
3. Each set repository runs `ocx vendor` for its platform into a fresh scratch
   `OCX_HOME` and generates its `BUILD.bazel` from `manifest.json` alone. The
   hub declares one toolchain per platform and one `ocx_tool` per tool.
4. A launcher is a native program, not a script. It applies the package
   environment and starts the binary. It needs no shell, no `ocx` and no
   network, so it runs on a remote executor that has none of them.

## Corporate mirrors

Guide: <https://ocx.sh/integrations/bazel/guides/offline-mirror/>.

Same knobs as the [setup.ocx.sh installer](https://github.com/ocx-sh/setup.ocx.sh),
honored by the repository rules:

| Env var | Effect |
| --- | --- |
| `OCX_INSTALL_DIST_URL` | Fetch the release manifest from your mirror instead of the vendored snapshot. The mirrored manifest is itself verified when it is named `<sha256>.json` (the form the setup.ocx.sh installers write); any other name is fetched unverified. |
| `OCX_INSTALL_MIRROR_URL` | Rewrite the ocx binary download to `<mirror>/<tag>/<filename>`. The artifact sha256 is enforced either way. A mirror can move bytes, not change them. |
| `OCX_INSTALL_BINARY`, `OCX_INSTALL_BINARY_SHA256` | Use a local `ocx` binary instead of a release. Both are required together. A wrong digest fails the fetch, and the binary must meet the [minimum `ocx`](#requirements). Pass them with `--repo_env` and `--lockfile_mode=off`. |
| `OCX_MIRRORS` | JSON map `{"ocx.sh": "https://mirror.corp/ocx"}`. Package pulls go to the mirror. `ocx.lock` digests stay keyed to the upstream host, so lockfiles are portable. |
| `OCX_INSECURE_REGISTRIES` | Allow plain-HTTP mirrors (comma list). |
| `OCX_AUTH_<REGISTRY>_{TYPE,USER,TOKEN}` | Registry credentials (also: docker config). Not enumerable by Bazel, so run `bazel fetch --force` after changing auth. |

Passed through to repo rules as well:
`OCX_INDEX`, `OCX_OFFLINE`,
`OCX_FROZEN`, `OCX_REMOTE`, `OCX_JOBS`, `OCX_DEFAULT_REGISTRY`, `OCX_CONFIG`,
`OCX_NO_CONFIG`, `OCX_MANAGED_CONFIG`,
`OCX_SIGSTORE_TRUSTED_ROOT` and `OCX_EXTRA_CA_CERTS` (extra TLS roots, for
example a corporate proxy CA). Together with `OCX_MIRRORS` and
`OCX_INSECURE_REGISTRIES` above, that is the whole forwarded set. `OCX_HOME` is
never forwarded: every `ocx` run gets a fresh scratch `OCX_HOME`.

The two path-valued ones (`OCX_CONFIG` and
`OCX_SIGSTORE_TRUSTED_ROOT`) must be **absolute**. A repository rule runs from
Bazel's own working directory, so a relative value names a different file than
it does in your shell. Bazel cannot watch it. It is refused rather than
forwarded unwatched.

`file://` on the trusted root is the one accepted spelling. It is forwarded
verbatim and watched at the path behind the prefix, which must itself be
absolute. Any other scheme, and `file://` on the other
two, are refused like any relative value.

`OCX_NO_VERIFY` and `OCX_ALLOW_YANKED` are **not** among them. Those two knobs
are never read from the environment. They are written on every invocation, so
an exported value cannot switch verification off or let a yanked package through.
Ask for either explicitly with `ocx.policy(...)` below.

`OCX_SIGSTORE_TRUSTED_ROOT` is site-authoritative. With no
`sigstore_trusted_root` attr set, an exported value replaces the trust anchor
that signatures are checked against. `OCX_MIRRORS` and
`OCX_INSECURE_REGISTRIES` redirect the transport. Set `sigstore_trusted_root`
and pin digests (`ocx.lock`, or an `@sha256:` reference) to close both.

`OCX_PROJECT`, `OCX_GLOBAL`, `OCX_QUIET`, `OCX_NO_PROJECT`
and `OCX_NO_CONFIG_REFRESH` are
deliberately *not* passed through. Each carries a fixed value on every
invocation. Project context comes from the explicit `--project` flag, and
`--quiet` would suppress the JSON reports the rules parse. `OCX_NO_PROJECT`
closes the directory walk a fetch would otherwise run from Bazel's own working
directory.

The managed-config refresh wants a TTY no repo rule has.

## Weakening posture: `ocx.policy`

Guide: <https://ocx.sh/integrations/bazel/concepts/trust-and-config/>.

```starlark
# MODULE.bazel: root module only, at most one tag; every attr defaults off.
ocx.policy(
    allow_unverified = True,       # OCX_NO_VERIFY=1 on every ocx call
    allow_yanked = True,           # OCX_ALLOW_YANKED=1
    sigstore_trusted_root = "//:trusted-root.json",
)
```

With no tag the defaults apply and nothing is loosened. The tag cannot *enable*
verification. ocx attaches that only under an operator-configured
`[[trust.policy]]`, so these attrs can only decline to switch it off. A
non-root or duplicate tag fails the build before any repository is declared.

Root-only governs the **tag**. The same three attrs also sit on the public
`ocx_set_repo` rule in `//ocx:defs.bzl`. A module that declares that rule
directly, instead of going through this extension, sets its own posture.

## Managed config

Guide: <https://ocx.sh/integrations/bazel/concepts/trust-and-config/>.

ocx layers its site configuration system, user, `$OCX_HOME/config.toml`,
managed-config snapshot, `OCX_CONFIG` and `--config`. The repository rules run
inside that chain rather than around it. Whatever mirrors and
registries your system and user config declare apply to the fetch. The
`$OCX_HOME` tiers of your machine do not, because every run has a scratch home.

Because Bazel can only invalidate on inputs it knows, a set repository
**watches every discovered config path**, including the ones that do not exist
yet. Creating a user config file refetches the set repositories. That is
deliberate: a config edit that changes what a fetch resolves must not survive
as a stale cache entry. `/etc/ocx/config.toml` is skipped on Windows, because
ocx reads that literal path there drive-relative and it is not an absolute
Windows path.

Two attrs on both `ocx.project()` and `ocx.package()` take the host out of the
loop:

```starlark
ocx.project(
    name = "dev_tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    platforms = ["linux/amd64"],
    config = "//:ocx-config.toml",  # committed site config
    no_config = True,               # ignore every discovered tier
)
```

`config` sets `OCX_CONFIG` and overrides an ambient one. `no_config` sets
`OCX_NO_CONFIG=1` and drops the system, user and managed tiers. It keeps an
explicit `config`, and it blanks an ambient `OCX_CONFIG`. Together the two attrs are the hermetic pattern: the
build reads exactly the file you committed.

**Managed config in CI**: a `[managed]` source that is required (the default)
but has never been synced exits **78 on every ocx command**. The repository
rules never run `ocx config setup` or `ocx config update` themselves. Adoption
stays an explicit human step. The failure message names the command to run, and
`no_config = True` or `OCX_NO_CONFIG=1` opts the build out of the tier.

## Reproducibility

Guide: <https://ocx.sh/integrations/bazel/guides/ci-reproducible/>.

- **Project tier** is fully pinned by your committed `ocx.lock` (per-platform
  sha256 digests). A stale lock fails `ocx vendor` with exit 65 and names
  `ocx lock`. Nothing is written to your checkout.
- **Package tier**, pick one:
  - `index = "//:index"` freezes tags. Commit an index snapshot
    (`ocx --index index index update ocx.sh/jqlang/jq`) and tags resolve from
    it until you refresh it.
  - A digest in the identifier (`ocx.sh/jqlang/jq:latest@sha256:...`) pins the
    package. The extension records a fact for it, and the repositories it
    produces are reproducible.
  - Neither: a floating tag resolves once, and the extension records the
    platform manifest digests in `MODULE.bazel.lock`. A moved tag changes
    nothing until `bazel mod deps --lockfile_mode=update
    --repo_env=RULES_OCX_UPDATE=<hub>`. A `project` or `index` hub updates its
    own files with `bazel run @<hub>//:update`. See
    [Update locked tools](docs/guides/update-locks.md).
- Commit `MODULE.bazel.lock`, so that a fresh checkout reads the facts and runs
  no `ocx` before a set is fetched.

## Remote execution and caching

Guide: <https://ocx.sh/integrations/bazel/guides/remote-cache/>.

Remote execution is supported. Bazel uploads a set as the inputs of every
action that uses one of its tools. The native launcher needs nothing else on
the executor.

- Only trusted CI lanes write a shared remote repository contents cache. Each
  set is fetched into a scratch `OCX_HOME` from digest-verified blobs, and the
  home of the machine is never read.
- Empty directories of a package are not visible to actions on a remote
  executor.
- A Windows set cannot carry symlinks, because Bazel declares none there. A
  Windows set whose manifest lists a link fails and names the package.
- A set repository keeps no layer cache between fetches. Give the tag
  `blob_dirs`, directories of pre-fetched blobs, when a fetch must run offline.

## API docs

Read the tutorial, guides and API reference at <https://ocx.sh/integrations/bazel/>.
Stardoc generates the API pages into [`docs/`](docs/). Regenerate them with
`bazel run //docs:update`. The site builds from `docs/` with `task site:build`.

## Documentation

- [Tutorial](https://ocx.sh/integrations/bazel/tutorial/): run `shellcheck` in a Bazel test without installing it
- [Share one toolchain](https://ocx.sh/integrations/bazel/guides/pin-toolchain/) between Bazel and developers
- [Environment variables](https://ocx.sh/integrations/bazel/reference/environment/) that reach the repository rules

## Examples

- [`examples/project`](examples/project): workspace toolchain from ocx.toml/lock, and a repository rule that runs a tool of a set
- [`examples/package`](examples/package): ad-hoc packages: floating, frozen-index and digest-pinned
- [`examples/cross_platform`](examples/cross_platform): one package for five platforms, launcher and ABI checks

## License

Apache-2.0. See [LICENSE](LICENSE).
