<!-- doc_type: how-to -->
<!-- doc_tier: everyday -->
# Fail CI on a stale lock and freeze packages and patches

This guide makes CI fail when a tool pin is stale and keeps ad-hoc packages and site patches from drifting.
It assumes you already provision tools with [`ocx.project`](pin-toolchain.md).

## Rely on the lock check

Every set of an `ocx.project` is vendored from the committed `ocx.lock`.
When `ocx.toml` and `ocx.lock` disagree, `ocx vendor` exits 65 and names `ocx lock`, so a stale pin cannot reach a build.
Fix it locally and commit the result.

```console
$ ocx lock
```

The extension records what the lock provides as a fact in `MODULE.bazel.lock`.
The fact holds the text of `ocx.lock`, so an edit of the lock recomputes it.
Commit `MODULE.bazel.lock`, so that a fresh checkout reads the facts and runs no `ocx` before a set is fetched.

Every set repository checks its own manifest against the fact.
A difference fails the fetch and names `bazel mod deps --lockfile_mode=update`.

The fetch writes nothing into your checkout.
Each `ocx` run uses a scratch `OCX_HOME` and stores no shell-activation consent stamp.

## Freeze ad-hoc packages

A floating tag such as `:latest` resolves at fetch time, and the extension then records no fact.
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
    platforms = ["linux/amd64", "darwin/arm64"],
)
```

Or pin the digest in the identifier.
A digest-pinned package is recorded as a fact, and the repositories it produces are reproducible.

```starlark
ocx.package(
    name = "jq_pinned",
    package = "ocx.sh/jqlang/jq:latest@sha256:c295300441831e002c0ba54df8e6126cdd4064c63be2464bdc6b68d0012beec6",
    platforms = ["linux/amd64", "darwin/arm64"],
)
```

## Freeze site patches

`ocx lock --check` does not cover patches.
If your site config composes patch packages, freeze them next to the lock file.

```console
$ ocx patch freeze
```

Commit `patches.snapshot.json` and export `OCX_PATCH_SNAPSHOT` as its absolute path.
Without the snapshot, patch companions resolve at fetch time.
Only `ocx patch sync` refreshes the snapshot, and it needs the network.

## Check the result

Run the same build twice on different machines, or after clearing the Bazel cache.
Every run should resolve to the digests in `ocx.lock`, the digest in the package identifier or the index snapshot.
