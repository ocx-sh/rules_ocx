<!-- doc_type: explanation -->
<!-- doc_tier: integration -->
# Trust, config and patches

A fetch runs inside OCX's configuration chain rather than around it.
This page explains who can change what a fetch accepts, and which knobs close those paths.

## The posture tag

`ocx.policy` loosens verification, and it only ever loosens.
It cannot enable verification, because OCX attaches that only under an operator-configured `[[trust.policy]]`.

```starlark
ocx.policy(
    allow_unverified = True,       # OCX_NO_VERIFY=1 on every ocx call
    allow_yanked = True,           # OCX_ALLOW_YANKED=1
    sigstore_trusted_root = "//:trusted-root.json",
)
```

With no tag, nothing is loosened.
The tag is root-module only and at most one may exist.
The same three attributes sit on the public `ocx_project_repo` and `ocx_package_repo` rules, so a module that declares those directly sets its own posture.

## Why two environment variables never pass through

`OCX_NO_VERIFY` and `OCX_ALLOW_YANKED` are never read from the environment.
rules_ocx writes them on every invocation, so an exported value cannot switch verification off.
A CI job that used to export `OCX_ALLOW_YANKED` resolves as if it had not, silently.
Move that intent into `ocx.policy(allow_yanked = True)`.

`OCX_SIGSTORE_TRUSTED_ROOT` is different: it is site-authoritative.
Without the `sigstore_trusted_root` attribute, an exported value replaces the trust anchor.
`OCX_MIRRORS` and `OCX_INSECURE_REGISTRIES` redirect the transport.
Set `sigstore_trusted_root` and pin digests with `pins` or an `@sha256:` reference to close both.

## The config chain

OCX layers system, user, `$OCX_HOME/config.toml`, the managed-config snapshot, `OCX_CONFIG` and `--config`.
Whatever mirrors, registries and `[patches]` your host config declares apply to the fetch.

Bazel can only invalidate on inputs it knows, so every discovered config path is watched, including paths that do not exist yet.
Creating `~/.ocx/config.toml` therefore refetches the ocx repositories.
That is deliberate: a config edit that changes a resolution must not survive as a stale cache entry.

To take the host out of the loop, commit a config and ignore the rest.

```starlark
ocx.project(
    name = "dev_tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    config = "//:ocx-config.toml",  # committed site config
    no_config = True,               # ignore every discovered tier
)
```

`config` sets `OCX_CONFIG`.
`no_config` sets `OCX_NO_CONFIG=1` and drops the system, user, `$OCX_HOME` and managed tiers.
It also blanks an ambient `OCX_CONFIG`, `OCX_PATCHES` and `OCX_PATCH_SNAPSHOT`.
Pass `patch_snapshot` as well, or the build loses its patch pinning without a diagnostic.
Lazy launchers copy both files into runfiles, so keep credentials out of them.

## Patches

Patches are companion packages that a site config composes onto a base package's environment.
They come from a `[patches]` table, never from the project `ocx.toml`.
[Freeze them](../guides/ci-reproducible.md) with `ocx patch freeze`, because `ocx lock --check` does not cover them.

## Managed config in CI

A required `[managed]` source that was never synced exits 78 on every ocx command.
The repository rules never run `ocx config setup` or `ocx config update`, because adopting a managed config is an explicit human step.
The failure message names the command to run.
`no_config = True` opts the build out of the tier.

## Exceptions to the watching rule

- `/etc/ocx/config.toml` is skipped on Windows, because it is not an absolute Windows path.
- `isolated_home = True` drops the `$OCX_HOME` tiers.
- A lazy `ocx.package(bins = ...)` watches no tier. Its launcher resolves the host config on first execution.
