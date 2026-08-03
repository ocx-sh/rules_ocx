# Starlark style & structure

- Public API surface is `//ocx:defs.bzl` (rules/macros) and
  `//ocx:extensions.bzl` (the `ocx` module extension). Everything else lives
  under `ocx/private/` and is not loadable by consumers.
- Every public symbol carries a docstring — stardoc renders `docs/` from
  them; `bazel test //docs/...` fails when committed docs drift
  (`bazel run //docs:update` regenerates).
- buildifier clean (`task format` / CI check). Attribute docs on every attr.
- Repository rules own all host/env interaction: `repository_ctx.getenv`
  for every env var consulted (Bazel tracks invalidation), `watch()` labels
  they read. Module extension impls stay pure: no os, no env, no downloads.
- Parse only documented ocx `--format json` shapes. Never parse plain-text
  output, never read OCX_HOME layout directly. Two exceptions: execing
  rendered absolute paths returned by the CLI, and the config tiers
  `ambient_config_paths()` hand-constructs to watch
  (`$OCX_HOME/config.toml`, `state/managed-config/snapshot.json`,
  `state/managed-config/config.toml`). ocx has no read-only command that
  reports those paths, so they are unavoidably hard-coded — and the watch
  fails *open*: relocate the directory upstream and it silently covers
  nothing, with no error. Re-verify the layout on every ocx bump (the
  `update-dist` skill lists it).
- Errors: map ocx sysexits to fail() with the user-fixable command, e.g.
  exit 65 → "ocx.lock is stale — run `ocx lock` and commit the result".
