<!-- doc_type: explanation -->
<!-- doc_tier: everyday -->
# The vendor model

rules_ocx builds every tool from the output of `ocx vendor`.
This page states the model as a whole: what the rules read, what a tool set is, where facts live, what the launcher does and why actions need no network.

## The manifest contract

`ocx vendor` writes a directory for one platform: the package files, one launcher per tool and a `manifest.json`.
The manifest has a `schema_version`, and rules_ocx reads version 1.
It is the one `ocx` document the rules parse.
The rules read what the manifest lists (packages, tools, links, the environment each tool needs and the platforms available) and nothing else about the store or the registry.
A manifest with another schema version fails the fetch and names the version it carries.

## Tool sets

A tool set is what one `ocx.project` or `ocx.package` tag provides.
Each tag needs `platforms`, the full platform strings the build may run on.
The tag declares one hub repository under its name and one set repository per platform.
The set repository runs `ocx vendor` for its platform and generates its `BUILD.bazel` from the manifest.
The hub holds one toolchain per platform and one `ocx_tool` target per tool.
Bazel selects the toolchain of the platform an action runs on, so a build fetches only that platform's set repository.

## Facts

Before it declares the repositories, the extension needs to know which tools exist on which platform.
It runs `ocx vendor --manifest-only` once per listed platform and stores the answer as a fact in `MODULE.bazel.lock`.
A fact is a hit only when everything that decided it still matches: the text of `ocx.lock`, or the package identifier, with the platforms and groups.
While the fact is current, the extension runs no `ocx` and makes no request.
Commit `MODULE.bazel.lock` so that a fresh checkout reads the facts.

Every set repository checks its own manifest against the fact.
A difference fails the fetch and names `bazel mod deps --lockfile_mode=update`, which recomputes the facts.
A package whose identifier carries no digest resolves at fetch time, so the extension records no fact for it and its sets are not reproducible.
Pin the digest or use an index snapshot (see [Fail CI on a stale lock](../guides/ci-reproducible.md)).

## The launcher

The launcher of a tool is a small native program, not a script.
It applies the environment the manifest lists for the tool and starts the binary.
It finds its `.direct` sidecar and the package files beside itself, then in the runfiles tree of the action.
It exits 78 when it finds neither, which is why Windows builds need `--enable_runfiles`.
On macOS the arm64 launcher carries an ad-hoc signature, which Apple silicon requires to start native code.

## Remote execution

A set is a tree of files.
Bazel uploads it as the inputs of every action that uses one of its tools.
The launcher needs no shell, no `ocx` and no network, so the action runs the same on a remote executor that has none of them.
Inputs are content-addressed, so a tool pinned by digest gives the same action key on every machine and the remote cache hits.
[Build with remote execution and a remote cache](../guides/remote-cache.md) shows what runs where.

## What ocx is for

`ocx` runs only when Bazel fetches a repository: once per tag to compute a fact, once per set repository to vendor it.
No action runs `ocx`, and a build with the repositories already fetched needs neither the binary nor the network.
The extension downloads the `ocx` release it needs, pinned in the module and checked against its sha256.
That release must have `ocx vendor` and write manifest schema version 1.

## Related pages

- [How rules_ocx works](how-it-works.md): the fetch steps, what a set contains and what is shared with the shell.
- [Trust, config and patches](trust-and-config.md): who decides what a fetch may accept.
