<!-- doc_type: how-to -->
<!-- doc_tier: everyday -->
# Use per-platform tools with transitions

This guide builds a tool for a platform other than your host, for example Linux arm64 binaries on a macOS machine.
It assumes you know how to declare an [`ocx.package`](ci-reproducible.md).

## Declare the platforms

List the platforms on the package. rules_ocx creates one repository per platform and a hub that selects by target platform.

```starlark
ocx.package(
    name = "jq",
    index = "//:index",
    package = "ocx.sh/jqlang/jq:latest",
    platforms = [
        "linux/amd64",
        "linux/arm64",
        "windows/amd64",
    ],
)
use_repo(ocx, "jq")
```

The hub `@jq` aliases only `//:content`.
The launchers live in the per-platform repositories.

## Transition to the target platform

A small rule changes `--platforms` for its `srcs`, so one build fetches `jq` for foreign platforms.

```starlark
def _transition_impl(_settings, attr):
    return {"//command_line_option:platforms": str(attr.target_platform)}

_platform_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)
```

The complete rule, `platform_filegroup`, is in [`examples/cross_platform/transition.bzl`](https://github.com/ocx-sh/rules_ocx/blob/main/examples/cross_platform/transition.bzl).
Use it with a `platform` target.

```starlark
platform(
    name = "linux_arm64",
    constraint_values = [
        "@platforms//cpu:aarch64",
        "@platforms//os:linux",
    ],
)

platform_filegroup(
    name = "jq_linux_arm64",
    srcs = ["@jq//:content"],
    target_platform = ":linux_arm64",
)
```

## Compose a foreign environment from the project lock

For an `ocx.project`, set `platform` to compose another platform's environment from the same `ocx.lock`.

```starlark
ocx.project(
    name = "tools_arm64",
    ocx_lock = "//:ocx.lock",
    ocx_toml = "//:ocx.toml",
    platform = "linux/arm64",
)
```

Its `env.bzl` holds the store paths of the arm64 binaries.
The repository has no runnable launchers, because those binaries do not run on the host.

## Check the result

The example test inspects the fetched binaries with `file -bL` and expects an ELF aarch64 file and a PE32+ file.
Run the same check on a Linux machine with `bazel test //:abi_test` in `examples/cross_platform`.
