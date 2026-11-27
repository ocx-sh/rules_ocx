<!-- doc_type: landing -->
<!-- doc_tier: first-steps -->
# rules_ocx

Bazel module extension that provisions pinned CLI tools, such as `jq` or `shellcheck`, as runnable targets through the [OCX](https://ocx.sh) package manager.
Tools run in local actions and on remote executors that have no network and no `ocx`.

```starlark
# MODULE.bazel
bazel_dep(name = "rules_ocx", version = "0.5.1")

ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")

# Provision the workspace toolchain from ocx.toml and ocx.lock.
ocx.project(
    name = "tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    platforms = [
        "darwin/arm64",
        "linux/amd64",
        "linux/arm64",
        "windows/amd64",
    ],
)

use_repo(ocx, "tools")

register_toolchains("@tools//:all")
```

Every executable a package declares becomes a target such as `@tools//:shellcheck`.
rules_ocx needs Bazel 9 and a recent `ocx`; see the [requirements](https://github.com/ocx-sh/rules_ocx#requirements).

[Start the tutorial](tutorial.md) to run `shellcheck` in a Bazel test without installing it.

## Pick a goal

- [Share one toolchain between Bazel and developers](guides/pin-toolchain.md): one `ocx.toml` and `ocx.lock` for both
- [Fail CI on a stale lock](guides/ci-reproducible.md): freeze ad-hoc packages
- [Update locked tools](guides/update-locks.md): move the pins with `bazel run @hub//:update` or `bazel mod deps`
- [Build behind a corporate mirror](guides/offline-mirror.md): mirrors, proxy CAs and offline fetches
- [Use tools for several platforms](guides/cross-platform.md): one hub, one set per platform
- [Windows: path length](guides/windows-path-length.md): keep paths short enough for tools to start
- [Build with remote execution and a remote cache](guides/remote-cache.md): what runs where, and how to keep actions stable

## Understand and look up

- [The vendor model](concepts/design.md): manifest, tool sets, facts, launcher and remote execution
- [How rules_ocx works](concepts/how-it-works.md): the fetch steps and what a vendored set is
- [Trust and config](concepts/trust-and-config.md): policy, managed config and the config chain
- [Environment variables](reference/environment.md): which ones reach the repository rules
- [Rules and macros](defs.md): `ocx_set_repo`, `ocx_hub_repo` and the rest of `defs.bzl`
- [Module extension](extensions.md): `project`, `package`, `download` and `policy` tags

Source, issues and examples live in the [GitHub repository](https://github.com/ocx-sh/rules_ocx).
