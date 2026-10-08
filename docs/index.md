<!-- doc_type: landing -->
<!-- doc_tier: first-steps -->
# rules_ocx

Bazel module extension that provisions pinned CLI tools, such as `jq` or `shellcheck`, as runnable targets through the [OCX](https://ocx.sh) package manager.

```starlark
# MODULE.bazel
bazel_dep(name = "rules_ocx", version = "0.5.0")

ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")

# Provision the workspace toolchain from ocx.toml and ocx.lock.
ocx.project(
    name = "tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
)

use_repo(ocx, "tools")
```

Every executable a package declares becomes a target such as `@tools//:shellcheck`.

[Start the tutorial](tutorial.md) to run `shellcheck` in a Bazel test without installing it.

## Pick a goal

- [Share one toolchain between Bazel and developers](guides/pin-toolchain.md): one `ocx.toml` and `ocx.lock` for both
- [Fail CI on a stale lock](guides/ci-reproducible.md): freeze packages and patches
- [Build behind a corporate mirror](guides/offline-mirror.md): mirrors, proxy CAs and anonymous read
- [Use per-platform tools with transitions](guides/cross-platform.md): build for a platform other than the host
- [Keep tool bytes out of remote-cached actions](guides/remote-cache.md): lazy provisioning with `bins`

## Understand and look up

- [How rules_ocx works](concepts/how-it-works.md): why it shells out to `ocx` and what is shared
- [Trust and config](concepts/trust-and-config.md): policy, managed config and patches
- [Environment variables](reference/environment.md): which ones reach the repository rules
- [Rules and macros](defs.md): `ocx_package_repo`, `ocx_project_repo` and the rest of `defs.bzl`
- [Module extension](extensions.md): `project`, `package`, `download` and `policy` tags

Source, issues and examples live in the [GitHub repository](https://github.com/ocx-sh/rules_ocx).
