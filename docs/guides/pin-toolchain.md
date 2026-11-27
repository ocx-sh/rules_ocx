<!-- doc_type: how-to -->
<!-- doc_tier: everyday -->
# Share one toolchain between Bazel and developers

This guide makes Bazel and your shell use the same tool versions from one pair of files, `ocx.toml` and `ocx.lock`.
It assumes the module setup from the [tutorial](../tutorial.md).

## Declare the tools once

List every tool in `ocx.toml`.

```toml
[tools]
shellcheck = "ocx.sh/shellcheck/shellcheck:latest"
shfmt = "ocx.sh/shfmt/shfmt:latest"
```

Run `ocx lock` and commit both `ocx.toml` and `ocx.lock`.

## Provision them in Bazel

Point an `ocx.project` tag at the pair, list the platforms, and register the hub's toolchains.

```starlark
ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")
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
use_repo(ocx, "tools")

register_toolchains("@tools//:all")
```

`platforms` is required.
Each entry must be a platform the lock serves, spelled as the lock keys it.
Name every platform an action may execute on, because a tool has no set for a platform you left out.

Each executable the packages declare becomes `@tools//:<name>`, for example `@tools//:shfmt`.
Use it in `tools =` of a `genrule` or in `data =` of a test.

```starlark
genrule(
    name = "shell_report",
    srcs = ["smelly.sh"],
    outs = ["shell_report.txt"],
    cmd = "echo shfmt: > $@ && (($(location @tools//:shfmt) -d $< 2>> $@) || true) && " +
          "echo shellcheck: >> $@ && (($(location @tools//:shellcheck) $< >> $@) || true)",
    tools = [
        "@tools//:shellcheck",
        "@tools//:shfmt",
    ],
)
```

## Use one tag per group a target needs

A tag vendors the tools of the groups it names as one set.
Every action that uses a tool of the set keys on the whole set.
Add a group to `groups` only when its tools belong together.
Give a tool that few targets use its own tag, so that an update to it re-runs only those targets.

```starlark
ocx.project(
    name = "build_tools",
    groups = ["build"],
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    platforms = ["linux/amd64"],
)
```

The names `default` and `all` are reserved: `default` is the top-level `[tools]` table, and `all` is `default` plus every group.
`bindings` narrows a tag to some of the binding names of its groups.
A tool's environment is composed from its own set.
It finds the other packages of that set and nothing from another tag.

Project tags work in the root module only.

## Use the same pin in the shell

Developers run the pinned versions with `ocx exec`.

```console
$ ocx exec -- shellcheck --version
```

This repository does the same for its own tools: `ocx exec -- bazelisk` runs the Bazel launcher pinned in its `ocx.toml`.

## Check the result

Run `bazel query @tools//...` and confirm that each tool in `ocx.toml` appears.
A missing target means the tag selects other groups or bindings.
A tool that the set of one platform lacks fails the build and names the tools that set has.
