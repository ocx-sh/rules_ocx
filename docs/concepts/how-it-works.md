<!-- doc_type: explanation -->
<!-- doc_tier: everyday -->
# How rules_ocx works

rules_ocx deliberately never re-implements OCX internals in Starlark.
All resolution goes through the `ocx` binary.
The durable contracts are the `ocx.lock` digests and the OCI manifests.

## Why shell out to ocx

OCI protocol, registry auth and the store layout belong to OCX.
If rules_ocx copied them, every OCX change would need a matching Starlark change.
A missing capability becomes an issue against [ocx-sh/ocx](https://github.com/ocx-sh/ocx), not a workaround in this module.

## The four steps

1. The `ocx` extension creates `@ocx_tool` by downloading the pinned `ocx` release listed in the vendored `dist/dist.json` snapshot of `https://setup.ocx.sh/dist.json`. The download is sha256-verified.
2. The `ocx.project` and `ocx.package` repository rules run that binary. They call `ocx lock --check` as the staleness gate, `ocx pull` or `ocx package install` to fill the store, and `ocx --format json env --pinned` for the composed environment.
3. Packages live in the shared `OCX_HOME` store, `~/.ocx` by default. It is content-addressed, digest-pinned and hardlink-composed.
4. Each generated repository contains launcher scripts that apply the package environment and run the store binaries. They work in `tools =`, in `$(location ...)`, in `sh_test` `env` and with `bazel run`.

## What is shared

Repository rules run unsandboxed, so the store is shared with your shell and with CI.
A package is fetched once per machine.
Launchers therefore reference absolute store paths, as nixpkgs does. Remote execution is a non-goal at 0.5.0.
`isolated_home = True` keeps one store per repository, at the cost of a full re-download.

## Hermetic in which sense

Bazel's [hermeticity guide](https://bazel.build/basics/hermeticity) names the benefit: tool versions that no host install can change.

rules_ocx gets there through digests in the lock file, not through a sandbox.
A tool pinned this way gives the same bytes on every machine, which is what keeps cache hits stable.

## Related pages

- [Trust and config](trust-and-config.md) explains who decides what a fetch may accept.
- [Share one toolchain](../guides/pin-toolchain.md) puts this into practice.
