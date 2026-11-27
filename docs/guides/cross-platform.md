<!-- doc_type: how-to -->
<!-- doc_tier: everyday -->
# Use tools for several platforms

This guide vendors one package for several platforms and runs the right one on each machine.
It also shows how to inspect the files of a platform you do not run.
It assumes you know how to declare an [`ocx.package`](ci-reproducible.md).

## Declare the platforms

List the platforms on the package.
rules_ocx creates one set repository per platform.
It also creates a hub that selects a toolchain by the platform an action executes on.

```starlark
ocx.package(
    name = "jq",
    index = "//:index",
    package = "ocx.sh/jqlang/jq:latest",
    platforms = [
        "darwin/amd64",
        "darwin/arm64",
        "linux/amd64",
        "linux/arm64",
        "windows/amd64",
    ],
)
use_repo(ocx, "jq")

register_toolchains("@jq//:all")
```

A build fetches the set of the platform it executes on and no other.
A platform that the package does not serve fails the build and names the platform.

`@jq//:jq` is the tool.
When a Linux machine and a macOS machine build the same target, each runs its own launcher.

## Name a platform with libc

A platform key can carry features, such as `linux/amd64+libc.musl`.
The hub lists the musl toolchain before the glibc one, so a musl executor gets the musl set.
A platform key with no libc feature, or with `libc.glibc`, adds no constraint.

## Read the files of a platform you do not run

A set repository is named `<tag>_<platform>`, with every character that is not a lowercase letter or digit turned into `_`.
Its `:set` target holds every file of the set.
Add the repository to `use_repo` and depend on `:set` to fetch it without running anything from it.

```starlark
use_repo(ocx, "jq", "jq_linux_arm64", "jq_windows_amd64")
```

```starlark
sh_test(
    name = "abi_test",
    srcs = ["abi_test.sh"],
    data = [
        "@jq_linux_arm64//:set",
        "@jq_windows_amd64//:set",
    ],
    env = {
        "JQ_LINUX_ARM64": "$(locations @jq_linux_arm64//:set)",
        "JQ_WINDOWS_AMD64": "$(locations @jq_windows_amd64//:set)",
    },
)
```

The test reads the first bytes of each binary and expects an ELF aarch64 file and a PE32+ file.
Run it with `bazel test //:abi_test` in `examples/cross_platform`.

## Run a tool in a repository rule

A repository rule cannot select a toolchain.
It can read a file of one set repository.
Build the label from a string, so that the sets of other platforms stay unfetched.
`examples/project/host_tool_version.bzl` runs `shellcheck --version` this way while Bazel fetches.

## Check the result

Run `bazel build @jq//:jq` on a Linux machine and on a macOS machine.
Each one fetches only its own set repository.

## Know the limits

- A Windows set cannot carry symlinks, because Bazel declares none there. A Windows set whose package lists a link fails and names the package.
- On macOS, the arm64 launcher carries a valid ad-hoc signature, which Apple silicon requires to start native code. Do not patch or strip a launcher: a changed byte invalidates the signature, which `codesign --verify` reports.
- On Windows, long paths can stop a tool from starting. See [Windows: path length](windows-path-length.md).
