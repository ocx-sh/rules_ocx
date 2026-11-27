<!-- doc_type: how-to -->
<!-- doc_tier: integration -->
# Build with remote execution and a remote cache

This guide makes actions that use a vendored tool run on remote executors that have no network and no `ocx`, and keeps those actions cacheable.
It assumes you provision tools with [`ocx.project` or `ocx.package`](pin-toolchain.md).

## Know what the executor receives

A set is a tree of files in a repository.
Bazel uploads it as the inputs of every action that uses one of its tools.
The launcher in it is a native program.
It needs no shell, no `ocx` and no network on the executor.
It looks for its files beside itself or in the runfiles tree of the action.

Remote execution is supported.

## Require what the build needs

- Bazel 9. The module declares `bazel_compatibility = [">=9.0.0"]` and needs Bazel 9 or newer.
- A supported `ocx`, because the extension and every set repository run it: see [what ocx is for](../concepts/design.md#what-ocx-is-for).
- `platforms` on every tag, naming each platform an executor may have.

## Keep action keys stable

Every action that uses a tool of a set keys on the whole set.
A change to any package in the set re-runs all of those actions.
Declare one `ocx.project` tag per group a target needs, so that a change to an unrelated group leaves the key alone.

```starlark
ocx.project(
    name = "lint_tools",
    groups = ["lint"],
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    platforms = ["linux/amd64", "darwin/arm64"],
)
ocx.project(
    name = "build_tools",
    groups = ["build"],
    ocx_toml = "//:ocx.toml",
    ocx_lock = "//:ocx.lock",
    platforms = ["linux/amd64", "darwin/arm64"],
)
```

Pin the packages.
A project tag is pinned by its lock.
An `ocx.package` is pinned by a digest in its identifier or by an index snapshot.
A floating tag is pinned by the digests in `MODULE.bazel.lock` until you [update it](update-locks.md).

## Share the repository contents cache with trusted lanes only

Bazel can share fetched repositories between clients through a remote repository contents cache (`--experimental_remote_repo_contents_cache`).
A fresh client then skips the set repository rule and makes no registry request.

Only trusted CI lanes write that cache.
A client that writes it decides what every other client receives, so an untrusted client must read it and never write it.
Each set repository is fetched into a scratch `OCX_HOME` from digest-verified blobs, and the home of the machine is never read.
A tampered home on one machine cannot reach the cache.

## Know the limits

- Empty directories of a package are not visible to actions on a remote executor.
- A Windows set cannot carry symlinks.
- A set repository keeps no layer cache between fetches. Give the tag `blob_dirs` when a fetch must not reach the registry.
- A tool finds the packages of its own set and nothing from another tag.

## Check the result

Run the same build on a second machine with an empty output base, the same remote cache and the repository contents cache on.
The registry sees no request for the set, and the actions are cache hits.
