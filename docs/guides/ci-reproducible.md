<!-- doc_type: how-to -->
<!-- doc_tier: everyday -->
# Fail CI on a stale lock and freeze packages and patches

This guide makes CI fail when a tool pin is stale and keeps ad-hoc packages and site patches from drifting.
It assumes you already provision tools with [`ocx.project`](pin-toolchain.md).

## Rely on the lock check

Every `ocx.project` fetch runs `ocx lock --check`.
When `ocx.toml` and `ocx.lock` disagree, the fetch fails with instructions, so a stale pin cannot reach a build.
Fix it locally and commit the result.

```console
$ ocx lock
```

The project tier writes nothing into your checkout.
It stores no shell-activation consent stamp, and the toolchain home that `ocx pull` renders lands in the fetched repository.
Launchers use digest-pinned store paths, never the moving `.ocx/toolchain/links` tree.

## Freeze ad-hoc packages

A floating tag such as `:latest` resolves at fetch time.
Pick one of two ways to freeze an `ocx.package`.

Commit an index snapshot, and the tag resolves from it until you refresh it.

```console
$ ocx --index index index update ocx.sh/jqlang/jq
```

```starlark
ocx.package(
    name = "jq_frozen",
    index = "//:index",
    package = "ocx.sh/jqlang/jq:latest",
)
```

Or pin the manifest digest per platform.
`ocx package install -p <platform> ocx.sh/jqlang/jq:latest` reports each digest.

```starlark
ocx.package(
    name = "jq_pinned",
    package = "ocx.sh/jqlang/jq:latest",
    pins = {
        "linux/amd64": "sha256:913ff41f5e643a73c17a2e560e349d8eea255f50b293156e58da15b957baacae",
        "darwin/arm64": "sha256:c5cf10597aacad9b7925f937c966ec72145ea6a40f7f7ef4cac11f90c43130b1",
    },
)
```

A platform without a pin falls back to `package`.
With neither `index` nor `pins`, the fetch log prints the digest it resolved.

## Freeze site patches

`ocx lock --check` does not cover patches.
If your site config composes patch packages, freeze them next to the lock file.

```console
$ ocx patch freeze
```

Commit `patches.snapshot.json` and point `patch_snapshot = "//:patches.snapshot.json"` at it.
Without the snapshot, patch companions resolve at fetch time.
Only `ocx patch sync` refreshes the snapshot, and it needs the network.

## Check the result

Run the same build twice on different machines, or after clearing the Bazel cache.
Every run should resolve to the digests in `ocx.lock`, `pins` or the index snapshot.
