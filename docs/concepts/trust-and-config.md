<!-- doc_type: explanation -->
<!-- doc_tier: integration -->
# Trust and config

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
The same three attributes sit on the public `ocx_set_repo` rule, so a module that declares it directly sets its own posture.

## Why two environment variables never pass through

`OCX_NO_VERIFY` and `OCX_ALLOW_YANKED` are never read from the environment.
rules_ocx writes them on every invocation, so an exported value cannot switch verification off.
An exported `OCX_ALLOW_YANKED` has no effect.
Ask for yanked releases with `ocx.policy(allow_yanked = True)`.

`OCX_SIGSTORE_TRUSTED_ROOT` is different: it is site-authoritative.
Without the `sigstore_trusted_root` attribute, an exported value replaces the trust anchor.
`OCX_MIRRORS` and `OCX_INSECURE_REGISTRIES` redirect the transport.
Set `sigstore_trusted_root` and pin digests with `ocx.lock` or an `@sha256:` reference to close both.

## The config chain

OCX layers system, user, `$OCX_HOME/config.toml`, the managed-config snapshot, `OCX_CONFIG` and `--config`.
Every `ocx` run of rules_ocx has a fresh scratch `OCX_HOME`, so the `$OCX_HOME` tiers of your machine do not apply.
Whatever mirrors and registries your system and user config declare apply to the fetch.

Bazel can only invalidate on inputs it knows, so a set repository watches every discovered config path, including paths that do not exist yet.
Creating a user config file therefore refetches the set repositories.
That is deliberate: a config edit that changes a resolution must not survive as a stale cache entry.
The extension, which computes the facts, watches no ambient config.

To take the host out of the loop, commit a config and ignore the rest.

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

`config` sets `OCX_CONFIG`.
`no_config` sets `OCX_NO_CONFIG=1` and drops the system, user and managed tiers.
It also blanks an ambient `OCX_CONFIG`.

## Patches

A patch never reaches a vendored set.
The manifest of a set is the same with or without `[patches]` in a config, so the rules model no patch companions and `OCX_PATCHES` and `OCX_PATCH_SNAPSHOT` change nothing in a set.

## Managed config in CI

A required `[managed]` source that was never synced exits 78 on every ocx command.
The repository rules never run `ocx config setup` or `ocx config update`, because adopting a managed config is an explicit human step.
The failure message names the command to run.
`no_config = True` opts the build out of the tier.

## Exceptions to the watching rule

- `/etc/ocx/config.toml` is skipped on Windows, because it is not an absolute Windows path.
- A tag with `no_config = True` watches no discovered tier.
