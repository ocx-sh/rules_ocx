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

Point an `ocx.project` tag at the pair.

```starlark
ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")
ocx.project(
    name = "tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
)
use_repo(ocx, "tools")
```

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

## Use the same pin in the shell

Developers run the pinned versions with `ocx exec`.

```console
$ ocx exec -- shellcheck --version
```

This repository does the same for its own tools: `ocx exec -- bazelisk` runs the Bazel launcher pinned in its `ocx.toml`.

## Check the result

Run `bazel query @tools//...` and confirm that each tool in `ocx.toml` appears.
A tool whose binary is not on the composed PATH is dropped without an error.

Project tags work in the root module only.
