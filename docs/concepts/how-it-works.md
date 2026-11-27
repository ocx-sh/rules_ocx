<!-- doc_type: explanation -->
<!-- doc_tier: everyday -->
# How rules_ocx works

rules_ocx deliberately never re-implements OCX internals in Starlark.
All resolution and all copying goes through the `ocx` binary.
The one `ocx` document it parses is the `manifest.json` that `ocx vendor` writes.
The durable contracts are the `ocx.lock` digests and the OCI manifests.

## Why shell out to ocx

OCI protocol, registry auth and the store layout belong to OCX.
If rules_ocx copied them, every OCX change would need a matching Starlark change.
A missing capability becomes an issue against [ocx-sh/ocx](https://github.com/ocx-sh/ocx), not a workaround in this module.

## The steps

1. The `ocx` extension creates `@ocx_tool` by downloading the pinned `ocx` release listed in the vendored `dist/dist.json` snapshot of `https://setup.ocx.sh/dist.json`. The download is sha256-verified. 
2. For each `ocx.project` or `ocx.package` tag, the extension needs to know which tools exist on which platform. It runs `ocx vendor --manifest-only` once per listed platform and records the answer as a fact in `MODULE.bazel.lock`. While the fact is current, the extension runs no `ocx` and makes no request.
3. The extension declares one hub repository named by the tag, and one set repository per platform. A set repository runs `ocx vendor` for its platform and keeps the result: the package files, one launcher per tool and a manifest.
4. The hub holds one toolchain per platform and one `ocx_tool` target per tool. Bazel picks the toolchain of the platform an action executes on, so a build fetches only that platform's set repository.

## A vendored set

A set is a directory of real files in a short layout.
Launchers and their `.launch` records sit in `l/`.
Each package sits in `p/<HEX16>/`, with its content in `c/` and its entry points in `e/`.
`<HEX16>` is a key of 16 hex digits that `ocx` derives from the package digest.
The rules read each launcher and record path from `manifest.json` and derive no file name.

Package content, the launchers and their records are file labels or directory labels of the set repository.
Links that a package declares become symlinks that the `ocx_set` rule declares.
The set repository generates its `BUILD.bazel` from `manifest.json` alone and reads no store layout.

Each launcher is a small native program, not a script.
It applies the package environment and starts the binary.
It needs no shell, no `ocx` and no network, so it runs on a remote executor that has none of them.
It finds its record beside itself, and its root through the runfiles tree of the action, then through the runfiles manifest.

Bazel declares no symlinks on Windows, so a Windows set whose manifest lists a link fails and names the package.
Empty directories of a package are not visible to actions on a remote executor.
The rig showed this on Buildbarn and NativeLink: both drop an empty directory that a local build keeps.

## What is shared

Every `ocx` run gets a fresh scratch `OCX_HOME` inside its own directory, deleted before it returns.
The store of your shell is never read, and nothing a fetch writes lands in it.
`HOME` and the process environment stay yours, so a Docker credential helper still works.

A set repository keeps no layer cache between fetches.
A refetch downloads the layers again.
Two things avoid it: `blob_dirs` on the tag, or Bazel's repository cache serving the repository.

## Hermetic in which sense

Bazel's [hermeticity guide](https://bazel.build/basics/hermeticity) names the benefit: tool versions that no host install can change.

rules_ocx gets there through digests in the lock file, not through a sandbox.
A tool pinned this way gives the same bytes on every machine, which is what keeps cache hits stable.

## Related pages

- [Trust and config](trust-and-config.md) explains who decides what a fetch may accept.
- [Share one toolchain](../guides/pin-toolchain.md) puts this into practice.
- [Remote execution and caching](../guides/remote-cache.md) shows what runs where.
