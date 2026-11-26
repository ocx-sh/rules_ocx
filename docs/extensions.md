<!-- Generated with Stardoc: http://skydoc.bazel.build -->

The `ocx` module extension.

Bootstraps the pinned ocx CLI (`@ocx_tool`) and declares, per `project` or
`package` tag, one hub repository and one set repository per platform.

What the hub needs to know before any set repository is fetched (which tools,
which platforms the lock serves) is recorded as a fact in `MODULE.bazel.lock`
(design 4.4): on a hit the extension runs no `ocx` and makes no request; on a
miss it runs `ocx vendor --manifest-only` once per listed platform. Besides
that, the implementation reads `module_ctx.os`, the tag's `ocx.lock` (and its
`ocx.toml`, on a miss only) and the `OCX_INSTALL_*` pair, and nothing else
(C-RO-11): no other getenv, no watch of ambient config. The `ocx` runs get
their environment from `manifest_env()` plus whatever `module_ctx.execute`
inherits from the process.

<a id="ocx"></a>

## ocx

<pre>
ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")
ocx.download(<a href="#ocx.download-dist_manifest">dist_manifest</a>, <a href="#ocx.download-triple">triple</a>, <a href="#ocx.download-version">version</a>)
ocx.package(<a href="#ocx.package-name">name</a>, <a href="#ocx.package-blob_dirs">blob_dirs</a>, <a href="#ocx.package-config">config</a>, <a href="#ocx.package-index">index</a>, <a href="#ocx.package-no_config">no_config</a>, <a href="#ocx.package-package">package</a>, <a href="#ocx.package-platforms">platforms</a>)
ocx.policy(<a href="#ocx.policy-allow_unverified">allow_unverified</a>, <a href="#ocx.policy-allow_yanked">allow_yanked</a>, <a href="#ocx.policy-sigstore_trusted_root">sigstore_trusted_root</a>)
ocx.project(<a href="#ocx.project-name">name</a>, <a href="#ocx.project-bindings">bindings</a>, <a href="#ocx.project-blob_dirs">blob_dirs</a>, <a href="#ocx.project-config">config</a>, <a href="#ocx.project-groups">groups</a>, <a href="#ocx.project-no_config">no_config</a>, <a href="#ocx.project-ocx_lock">ocx_lock</a>, <a href="#ocx.project-ocx_toml">ocx_toml</a>, <a href="#ocx.project-platforms">platforms</a>)
</pre>

Provisions tools through the OCX package manager.

Always creates `@ocx_tool` (the pinned ocx CLI). `ocx.project()` vendors a
workspace toolchain from ocx.toml/ocx.lock; `ocx.package()` vendors an
individual OCI package; each becomes a hub repository named by the tag, with
one toolchain per platform: register it with
`register_toolchains("@<name>//:all")`. `ocx.policy()` sets the build's
weakening posture (root module only). See the tag class docs for details.


**TAG CLASSES**

<a id="ocx.download"></a>

### download

Overrides the ocx CLI bootstrap. Root module only; at most one.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx.download-dist_manifest"></a>dist_manifest |  dist.json release manifest snapshot to resolve the download from.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@rules_ocx//dist:dist.json"`  |
| <a id="ocx.download-triple"></a>triple |  Exact release target triple, overriding host detection.   | String | optional |  `""`  |
| <a id="ocx.download-version"></a>version |  Exact ocx version (default: the version pinned with this rules_ocx release). Must be 0.6.1 or newer — rules_ocx passes `--pinned` to `ocx env`/`exec` and pins `OCX_NO_CONSENT`, and the floor is checked before any download.   | String | optional |  `""`  |

<a id="ocx.package"></a>

### package

Vendors a single OCX package from an OCI registry, one set per platform, behind one hub.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx.package-name"></a>name |  Name of the generated hub repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx.package-blob_dirs"></a>blob_dirs |  Directories of pre-fetched blobs, each passed to ocx as `--blob-dir` so the vendor runs offline.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="ocx.package-config"></a>config |  An ocx site config.toml (mirrors, registries, [patches]) layered over the host's discovered config — not the project ocx.toml; sets OCX_CONFIG for every invocation, overriding an ambient one, and is watched. Combine with no_config for a hermetic configuration.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.package-index"></a>index |  Committed ocx index snapshot directory (created with `ocx --index <dir> index update <package>`). When set, tag resolution is frozen to the snapshot.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.package-no_config"></a>no_config |  Reach for it when a corporate managed config must not reach the build: ignores the host's discovered tiers (/etc, the user config, $OCX_HOME/config.toml) and the managed-config snapshot, and opts out of the exit-78 gate a required-but-unsynced managed config raises.   | Boolean | optional |  `False`  |
| <a id="ocx.package-package"></a>package |  Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'. Only a digest-pinned identifier is recorded as a fact and keeps the extension reproducible.   | String | required |  |
| <a id="ocx.package-platforms"></a>platforms |  Full ocx platform strings to provision ('linux/amd64+libc.glibc', ...), exactly as the lock keys them. Every one must be a platform the lock serves: a platform it cannot serve fails resolution naming it, and none is dropped silently.   | List of strings | required |  |

<a id="ocx.policy"></a>

### policy

Sets the build's weakening posture — unverified installs, yanked releases, a pinned sigstore trusted root — as a function of MODULE.bazel alone. Root module only; at most one.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx.policy-allow_unverified"></a>allow_unverified |  When true, sets OCX_NO_VERIFY=1 for every invocation — ocx's own documented equivalent of `--no-verify`, so no verify flag is ever put on an argv. When false, OCX_NO_VERIFY=0 is written anyway, so an ambient value cannot switch verification off. It cannot switch verification *on*: ocx attaches that only under an operator-configured `[[trust.policy]]`, so this attr can only decline to disable it — and `no_config = True` prunes the discovered tiers that policy lives in, so there is then nothing to decline and verification is off either way.   | Boolean | optional |  `False`  |
| <a id="ocx.policy-allow_yanked"></a>allow_yanked |  Whether resolution may fall back to a yanked release — sets OCX_ALLOW_YANKED for every invocation.   | Boolean | optional |  `False`  |
| <a id="ocx.policy-sigstore_trusted_root"></a>sigstore_trusted_root |  A sigstore trusted-root.json pinned in-tree. Sets OCX_SIGSTORE_TRUSTED_ROOT for every invocation, overriding the ambient `<OCX_HOME>/sigstore/trusted-root.json` rung, and the file is watched.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |

<a id="ocx.project"></a>

### project

Vendors the toolchain of a workspace ocx.toml + ocx.lock, one set per platform, behind one hub. Root module only.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx.project-name"></a>name |  Name of the generated hub repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx.project-bindings"></a>bindings |  Binding names to vendor; empty = every binding of the selected groups.   | List of strings | optional |  `[]`  |
| <a id="ocx.project-blob_dirs"></a>blob_dirs |  Directories of pre-fetched blobs, each passed to ocx as `--blob-dir` so the vendor runs offline.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="ocx.project-config"></a>config |  An ocx site config.toml (mirrors, registries, [patches]) layered over the host's discovered config — not the project ocx.toml; sets OCX_CONFIG for every invocation, overriding an ambient one, and is watched. Combine with no_config for a hermetic configuration.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.project-groups"></a>groups |  ocx.toml groups to vendor. Reserved names: 'default' = the top-level [tools] table, 'all' = default + every group.   | List of strings | optional |  `[]`  |
| <a id="ocx.project-no_config"></a>no_config |  Reach for it when a corporate managed config must not reach the build: ignores the host's discovered tiers (/etc, the user config, $OCX_HOME/config.toml) and the managed-config snapshot, and opts out of the exit-78 gate a required-but-unsynced managed config raises.   | Boolean | optional |  `False`  |
| <a id="ocx.project-ocx_lock"></a>ocx_lock |  The committed ocx.lock next to `ocx_toml`; its text is part of the recorded fact, so an edit recomputes it.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx.project-ocx_toml"></a>ocx_toml |  The project ocx.toml.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx.project-platforms"></a>platforms |  Full ocx platform strings to provision ('linux/amd64+libc.glibc', ...), exactly as the lock keys them. Every one must be a platform the lock serves: a platform it cannot serve fails resolution naming it, and none is dropped silently.   | List of strings | required |  |


