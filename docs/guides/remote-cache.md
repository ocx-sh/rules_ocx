<!-- doc_type: how-to -->
<!-- doc_tier: integration -->
# Keep tool bytes out of remote-cached actions

This guide makes a fully remote-cached build download no tool content, even on a machine that has never seen the tools.
It assumes you provision tools with `ocx.project` or `ocx.package`.

## Switch to lazy provisioning

Add `bins` to the tag, listing the executables you use.

```starlark
ocx.project(
    name = "tools_lazy",
    bins = [
        "shellcheck",
        "shfmt",
    ],
    ocx_lock = "//:ocx.lock",
    ocx_toml = "//:ocx.toml",
)
```

Nothing is pulled at fetch time.
Each name becomes a launcher that re-enters `ocx exec` and materializes the content on its first execution.

## Pin the package for the package tier

An `ocx.package` with `bins` needs `pins` or an `@sha256:` reference, so the action key is stable.

```starlark
ocx.package(
    name = "jq_lazy",
    bins = ["jq"],
    package = "ocx.sh/jqlang/jq:latest",
    pins = {
        "linux/amd64": "sha256:913ff41f5e643a73c17a2e560e349d8eea255f50b293156e58da15b957baacae",
        "darwin/arm64": "sha256:c5cf10597aacad9b7925f937c966ec72145ea6a40f7f7ef4cac11f90c43130b1",
    },
)
```

Tool content never becomes an action input.
Actions key on the lock file (project) or the digest-pinned reference (package).
The POSIX launchers resolve everything through runfiles, so the keys match across machines.

## Know the trade-offs

- `bins` names are not validated at fetch time.
- `//:content` and `//:env.bzl` are unavailable, because they need materialized bytes.
- `isolated_home = True` cannot be combined with `bins`.
- The first executions on a cold machine race on the store ([ocx-sh/ocx#179](https://github.com/ocx-sh/ocx/issues/179)).

## Check the result

Run a build whose actions all hit the remote cache on a pristine machine.
The shared `OCX_HOME` store stays empty of tool content.
The first cache-miss action on that machine pays the pull once.
