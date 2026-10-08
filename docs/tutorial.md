<!-- doc_type: tutorial -->
<!-- doc_tier: first-steps -->
# Run shellcheck in a Bazel test without installing it

In this tutorial you add rules_ocx to a Bazel workspace and run `shellcheck` in an `sh_test`.
You never install `shellcheck` on your machine.
It takes about ten minutes.

You need Bazel 8 or later.
You also need the `ocx` CLI to write the lock file ([install it](https://ocx.sh/install/)).
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

```starlark
module(name = "tutorial")

bazel_dep(name = "rules_ocx", version = "0.5.0")
bazel_dep(name = "rules_shell", version = "0.6.1")

ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")
ocx.project(
    name = "tools",
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
)
use_repo(ocx, "tools")
```

## Write the test

Create `lint_test.sh` and make it executable.

```bash
#!/usr/bin/env bash
set -euo pipefail

"$SHELLCHECK_BIN" --version | grep -q "version:"
echo "shellcheck OK"
```

```console
$ chmod +x lint_test.sh
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

The first run fetches `ocx` and `shellcheck`, then reports `//:lint` as `PASSED`.

## Check what you got

List the targets that rules_ocx created.

```console
$ bazel query @tools//...
```

The list contains `@tools//:shellcheck`.
A tool that is declared but missing from this list raises no error, so run this query whenever a target you expect is absent.

## Next steps

- [Share the same `ocx.toml` with developers](guides/pin-toolchain.md)
- [Make CI fail when the lock is stale](guides/ci-reproducible.md)
- [Read how rules_ocx works](concepts/how-it-works.md)
