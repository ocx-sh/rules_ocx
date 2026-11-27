<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API of rules_ocx.

Most consumers only need the `ocx` module extension
(`@rules_ocx//ocx:extensions.bzl`). The repository and build rules are
re-exported here for power users composing their own extensions on top of the
same vendored provisioning, and for the `tool.bzl` each hub generates.

<a id="ocx_set"></a>

## ocx_set

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_set")

ocx_set(<a href="#ocx_set-name">name</a>, <a href="#ocx_set-srcs">srcs</a>, <a href="#ocx_set-links">links</a>, <a href="#ocx_set-reserved">reserved</a>, <a href="#ocx_set-tools">tools</a>)
</pre>

Every file of one vendored set, with its declared links and restored reserved files as runfiles.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_set-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_set-srcs"></a>srcs |  File and directory labels of the vendored tree.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="ocx_set-links"></a>links |  Declared link path -> target.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="ocx_set-reserved"></a>reserved |  Stash path `_ocx_reserved/<n>` -> original path.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="ocx_set-tools"></a>tools |  Tool name -> [launcher path, record path].   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> List of strings</a> | optional |  `{}`  |


<a id="ocx_set_toolchain"></a>

## ocx_set_toolchain

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_set_toolchain")

ocx_set_toolchain(<a href="#ocx_set_toolchain-name">name</a>, <a href="#ocx_set_toolchain-set">set</a>)
</pre>

Exposes an `ocx_set` as a toolchain of the hub's `toolchain_type`.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_set_toolchain-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_set_toolchain-set"></a>set |  The `ocx_set` of this platform.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |


<a id="OcxSetInfo"></a>

## OcxSetInfo

<pre>
load("@rules_ocx//ocx:defs.bzl", "OcxSetInfo")

OcxSetInfo(<a href="#OcxSetInfo-files">files</a>, <a href="#OcxSetInfo-runfiles">runfiles</a>, <a href="#OcxSetInfo-tools">tools</a>)
</pre>

The files and tools of one platform's vendored set.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="OcxSetInfo-files"></a>files |  depset of every file of the set    |
| <a id="OcxSetInfo-runfiles"></a>runfiles |  runfiles of the whole set    |
| <a id="OcxSetInfo-tools"></a>tools |  dict: tool name -> struct(launcher = File, record = File)    |


<a id="make_ocx_tool_rule"></a>

## make_ocx_tool_rule

<pre>
load("@rules_ocx//ocx:defs.bzl", "make_ocx_tool_rule")

make_ocx_tool_rule(<a href="#make_ocx_tool_rule-toolchain_type">toolchain_type</a>)
</pre>

Creates the `ocx_tool` rule bound to one hub's toolchain type.

A rule's `toolchains = ["//:toolchain_type"]` is resolved against the
repository that defines the rule, not the one that instantiates it, so a
single `ocx_tool` in rules_ocx cannot serve many hubs (proved on Bazel
9.2.0). Each hub's generated `.bzl` calls this with its own
`Label("//:toolchain_type")`.

The rule is executable; attr `tool` (mandatory) names the tool. It outputs
symlinks to the launcher and the record under the basenames the manifest
gives them.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="make_ocx_tool_rule-toolchain_type"></a>toolchain_type |  a Label of the hub's `toolchain_type`, created in the hub's own `.bzl` so that it resolves in the hub.   |  none |

**RETURNS**

the rule.


<a id="ocx_download"></a>

## ocx_download

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_download")

ocx_download(<a href="#ocx_download-name">name</a>, <a href="#ocx_download-dist_manifest">dist_manifest</a>, <a href="#ocx_download-triple">triple</a>, <a href="#ocx_download-version">version</a>)
</pre>

Downloads a pinned ocx CLI release for the host platform.

The release row (URL + sha256) comes from the vendored `dist.json` snapshot
of `https://setup.ocx.sh/dist.json`. Corporate mirrors: set
`OCX_INSTALL_DIST_URL` to fetch a mirrored manifest instead, and/or
`OCX_INSTALL_MIRROR_URL` to rewrite the artifact download to
`<mirror>/<tag>/<filename>`. The artifact sha256 is enforced either way.

A mirrored manifest is itself verified when it is named `<sha256>.json`
(the form the official setup.ocx.sh installers write, as
`dist/<sha256>.json`) — the name carries the manifest's own digest, which
is then enforced on the fetch. Any other manifest name is fetched
unverified: the transport to the mirror is then all that stands behind the
rows it serves, sha256 included.

Local build: set `OCX_INSTALL_BINARY` (absolute path of an `ocx`
binary) and `OCX_INSTALL_BINARY_SHA256` (its digest, 64 lowercase hex) to use
it instead of the release. Both are required together; the file is copied
through the downloader, so a wrong digest fails the fetch and a later edit of
the source file has no effect. `version` and the dist manifest are then
ignored, and the binary's `ocx version` must still meet the floor below
(a pre-release of the floor version passes). Pass them with `--repo_env` and add `--lockfile_mode=off` (the pair
is not part of the lockfile).

`version` must be 0.6.8 or newer: that is the first ocx release with `ocx vendor`
and manifest schema version 2, the manifest this ruleset reads.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_download-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_download-dist_manifest"></a>dist_manifest |  Release manifest snapshot (dist.json schema 1).   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@rules_ocx//dist:dist.json"`  |
| <a id="ocx_download-triple"></a>triple |  Escape hatch: exact release target triple, e.g. 'x86_64-unknown-linux-gnu' to prefer the glibc build. Defaults to host detection (Linux maps to musl).   | String | optional |  `""`  |
| <a id="ocx_download-version"></a>version |  Exact ocx version to download, e.g. '0.6.8'. Must be 0.6.8 or newer.   | String | required |  |


<a id="ocx_hub_repo"></a>

## ocx_hub_repo

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_hub_repo")

ocx_hub_repo(<a href="#ocx_hub_repo-name">name</a>, <a href="#ocx_hub_repo-hub">hub</a>, <a href="#ocx_hub_repo-sets">sets</a>, <a href="#ocx_hub_repo-tools">tools</a>, <a href="#ocx_hub_repo-update">update</a>)
</pre>

The hub of a vendored tool collection.

Holds one toolchain per platform (each naming that platform's set repository
only inside `toolchain()`), one `ocx_tool` per tool name, and, when `update` is
set, `update`: an alias of the hub's pre-configured `ocx` target in
`@ocx_update`. Register it with
`register_toolchains("@<hub>//:all")`.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_hub_repo-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_hub_repo-hub"></a>hub |  The hub's own name; `update` aliases `@ocx_update//:hub_<hub>`.   | String | optional |  `""`  |
| <a id="ocx_hub_repo-sets"></a>sets |  platform -> label of that platform's `ocx_set_toolchain`.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="ocx_hub_repo-tools"></a>tools |  Tool names.   | List of strings | optional |  `[]`  |
| <a id="ocx_hub_repo-update"></a>update |  Whether `@ocx_update` has an update target for this hub; the hub then aliases it as `update`.   | Boolean | optional |  `False`  |


<a id="ocx_set_repo"></a>

## ocx_set_repo

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_set_repo")

ocx_set_repo(<a href="#ocx_set_repo-name">name</a>, <a href="#ocx_set_repo-allow_unverified">allow_unverified</a>, <a href="#ocx_set_repo-allow_yanked">allow_yanked</a>, <a href="#ocx_set_repo-bindings">bindings</a>, <a href="#ocx_set_repo-blob_dirs">blob_dirs</a>, <a href="#ocx_set_repo-config">config</a>,
             <a href="#ocx_set_repo-expected_available_platforms">expected_available_platforms</a>, <a href="#ocx_set_repo-expected_digest">expected_digest</a>, <a href="#ocx_set_repo-expected_tools">expected_tools</a>, <a href="#ocx_set_repo-groups">groups</a>, <a href="#ocx_set_repo-hub">hub</a>, <a href="#ocx_set_repo-index">index</a>, <a href="#ocx_set_repo-kind">kind</a>,
             <a href="#ocx_set_repo-no_config">no_config</a>, <a href="#ocx_set_repo-ocx">ocx</a>, <a href="#ocx_set_repo-ocx_lock">ocx_lock</a>, <a href="#ocx_set_repo-ocx_toml">ocx_toml</a>, <a href="#ocx_set_repo-package">package</a>, <a href="#ocx_set_repo-platform">platform</a>, <a href="#ocx_set_repo-sigstore_trusted_root">sigstore_trusted_root</a>, <a href="#ocx_set_repo-tier">tier</a>)
</pre>

One platform's vendored tool set, produced by `ocx vendor`.

The repository holds the vendored tree, the generated `BUILD.bazel` and the
`ocx_set` / `ocx_set_toolchain` targets over it.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_set_repo-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_set_repo-allow_unverified"></a>allow_unverified |  When true, sets OCX_NO_VERIFY=1 for every invocation — ocx's own documented equivalent of `--no-verify`, so no verify flag is ever put on an argv. When false, OCX_NO_VERIFY=0 is written anyway, so an ambient value cannot switch verification off. It cannot switch verification *on*: ocx attaches that only under an operator-configured `[[trust.policy]]`, so this attr can only decline to disable it — and `no_config = True` prunes the discovered tiers that policy lives in, so there is then nothing to decline and verification is off either way.   | Boolean | optional |  `False`  |
| <a id="ocx_set_repo-allow_yanked"></a>allow_yanked |  Whether resolution may fall back to a yanked release — sets OCX_ALLOW_YANKED for every invocation.   | Boolean | optional |  `False`  |
| <a id="ocx_set_repo-bindings"></a>bindings |  Tool names to bind (project tier).   | List of strings | optional |  `[]`  |
| <a id="ocx_set_repo-blob_dirs"></a>blob_dirs |  Directories passed as `--blob-dir`.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="ocx_set_repo-config"></a>config |  An ocx site config.toml (mirrors, registries) layered over the host's discovered config — not the project ocx.toml. Sets OCX_CONFIG for every invocation, overriding an ambient one, and the file is watched. Combine with no_config for a hermetic configuration.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_set_repo-expected_available_platforms"></a>expected_available_platforms |  available_platforms recorded in the fact; cross-checked against the manifest.   | List of strings | optional |  `[]`  |
| <a id="ocx_set_repo-expected_digest"></a>expected_digest |  Root platform manifest digest recorded in the fact; empty skips the check.   | String | optional |  `""`  |
| <a id="ocx_set_repo-expected_tools"></a>expected_tools |  `name:kind` rows recorded in the fact for this platform; cross-checked against the manifest.   | List of strings | optional |  `[]`  |
| <a id="ocx_set_repo-groups"></a>groups |  ocx.toml groups to vendor (project tier).   | List of strings | optional |  `[]`  |
| <a id="ocx_set_repo-hub"></a>hub |  Name of the hub this set belongs to, for the update hint.   | String | optional |  `""`  |
| <a id="ocx_set_repo-index"></a>index |  Optional index passed as `--index`.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_set_repo-kind"></a>kind |  The declaration kind, which decides the check tail and the vendor flags.   | String | optional |  `""`  |
| <a id="ocx_set_repo-no_config"></a>no_config |  Ignore the host's discovered config tiers (/etc, the user config, $OCX_HOME/config.toml) and the managed-config snapshot — sets OCX_NO_CONFIG=1, and blanks an ambient OCX_CONFIG, which OCX_NO_CONFIG alone does not prune. The `config` attr still applies. Use this when a corporate managed config must not reach the build; it also opts out of the exit-78 gate a required-but-unsynced managed config raises.   | Boolean | optional |  `False`  |
| <a id="ocx_set_repo-ocx"></a>ocx |  The pinned ocx CLI binary.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@ocx_tool//:ocx"`  |
| <a id="ocx_set_repo-ocx_lock"></a>ocx_lock |  The ocx.lock next to ocx_toml (project tier).   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_set_repo-ocx_toml"></a>ocx_toml |  The project ocx.toml (project tier).   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_set_repo-package"></a>package |  Package identifier (package tier).   | String | optional |  `""`  |
| <a id="ocx_set_repo-platform"></a>platform |  ocx platform key to vendor for.   | String | required |  |
| <a id="ocx_set_repo-sigstore_trusted_root"></a>sigstore_trusted_root |  A sigstore trusted-root.json pinned in-tree. Sets OCX_SIGSTORE_TRUSTED_ROOT for every invocation, overriding the ambient `<OCX_HOME>/sigstore/trusted-root.json` rung, and the file is watched.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_set_repo-tier"></a>tier |  Which `ocx vendor` form to call.   | String | required |  |


