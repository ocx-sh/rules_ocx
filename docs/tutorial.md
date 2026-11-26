<!-- doc_type: tutorial -->
<!-- doc_tier: first-steps -->
# Run shellcheck in a Bazel test without installing it

In this tutorial you add rules_ocx to a Bazel workspace and run `shellcheck` in an `sh_test`.
You never install `shellcheck` on your machine.
It takes about ten minutes.

You need Bazel 9.
You also need an `ocx` CLI with the `vendor` command to write the lock file ([install it](https://ocx.sh/install/)).
rules_ocx wraps `ocx`. It downloads a pinned `ocx` build itself and runs it for every fetch.

## Pin the tool

Create an empty directory, then declare the tool in `ocx.toml`.

```toml
[tools]
shellcheck = "ocx.sh/shellcheck/shellcheck:latest"
```

Resolve it to digests in `ocx.lock`.

```console
$ ocx lock
```

Commit both files later. The lock file is what makes every build use the same bytes.

## Declare the module

Create `MODULE.bazel`.
`platforms` names every platform a build may run the tool on, spelled as the lock keys them.
Each one must be a platform the lock serves.

```starlark
module(name = "tutorial")

bazel_dep(name = "rules_ocx", version = "0.5.0")
bazel_dep(name = "rules_shell", version = "0.6.1")

ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")
ocx.project(
    name = "tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    platforms = ["linux/amd64", "darwin/arm64"],
)
use_repo(ocx, "tools")

register_toolchains("@tools//:all")
```

Pin Bazel 9 by writing `9.2.0` into `.bazelversion`.

On Windows, put `common:windows --enable_runfiles` in a `.bazelrc`.
The tools look for their files in the runfiles tree, and without it they exit 78.
If a tool fails to start on a long path, see [Windows: path length](guides/cross-platform.md#windows-path-length).

## Write the test

Create `lint_test.sh` and run `chmod +x lint_test.sh`.

```bash
#!/usr/bin/env bash
set -euo pipefail

grep -q "version:" <<<"$("$SHELLCHECK_BIN" --version)"
echo "shellcheck OK"
```

Create `BUILD.bazel`.
The test gets the tool through `data` and finds its path through `$(location ...)`.

```starlark
load("@rules_shell//shell:sh_test.bzl", "sh_test")

sh_test(
    name = "lint",
    srcs = ["lint_test.sh"],
    data = ["@tools//:shellcheck"],
    env = {"SHELLCHECK_BIN": "$(location @tools//:shellcheck)"},
)
```

## Run it

```console
$ bazel test //:lint
```

The first run fetches `ocx` and the `shellcheck` set for your platform, then reports `//:lint` as `PASSED`.
The sets of the other platforms stay unfetched.

## Check what you got

List the targets that rules_ocx created.

```console
$ bazel query @tools//...
```

The list contains `@tools//:shellcheck` and one toolchain per platform.
A platform the lock does not serve fails the build and names the platform, so the list never drops one silently.

## Next steps

- [Share the same `ocx.toml` with developers](guides/pin-toolchain.md)
- [Make CI fail when the lock is stale](guides/ci-reproducible.md)
- [Read how rules_ocx works](concepts/how-it-works.md)
