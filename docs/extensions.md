<!-- Generated with Stardoc: http://skydoc.bazel.build -->

The `ocx` module extension.

Bootstraps the pinned ocx CLI (`@ocx_tool`) and declares repositories that
provision tools through it. The implementation is a pure function of the
tags — all host detection and environment access happens inside the
repository rules — so the extension is marked reproducible and stays out of
MODULE.bazel.lock.

<a id="ocx"></a>

## ocx

<pre>
ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")
ocx.download(<a href="#ocx.download-dist_manifest">dist_manifest</a>, <a href="#ocx.download-triple">triple</a>, <a href="#ocx.download-version">version</a>)
ocx.package(<a href="#ocx.package-name">name</a>, <a href="#ocx.package-bins">bins</a>, <a href="#ocx.package-config">config</a>, <a href="#ocx.package-index">index</a>, <a href="#ocx.package-isolated_home">isolated_home</a>, <a href="#ocx.package-no_config">no_config</a>, <a href="#ocx.package-package">package</a>, <a href="#ocx.package-patch_snapshot">patch_snapshot</a>, <a href="#ocx.package-pins">pins</a>,
            <a href="#ocx.package-platform_aliases">platform_aliases</a>, <a href="#ocx.package-platforms">platforms</a>)
ocx.project(<a href="#ocx.project-name">name</a>, <a href="#ocx.project-bins">bins</a>, <a href="#ocx.project-config">config</a>, <a href="#ocx.project-groups">groups</a>, <a href="#ocx.project-isolated_home">isolated_home</a>, <a href="#ocx.project-no_config">no_config</a>, <a href="#ocx.project-ocx_lock">ocx_lock</a>, <a href="#ocx.project-ocx_toml">ocx_toml</a>,
            <a href="#ocx.project-patch_snapshot">patch_snapshot</a>, <a href="#ocx.project-platform">platform</a>)
</pre>

Provisions tools through the OCX package manager.

Always creates `@ocx_tool` (the pinned ocx CLI). `ocx.project()` provisions
a workspace toolchain from ocx.toml/ocx.lock; `ocx.package()` provisions
individual OCI packages. See the tag class docs for details.


**TAG CLASSES**

<a id="ocx.download"></a>

### download

Overrides the ocx CLI bootstrap. Root module only; at most one.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx.download-dist_manifest"></a>dist_manifest |  dist.json release manifest snapshot to resolve the download from.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@rules_ocx//dist:dist.json"`  |
| <a id="ocx.download-triple"></a>triple |  Exact release target triple, overriding host detection.   | String | optional |  `""`  |
| <a id="ocx.download-version"></a>version |  Exact ocx version (default: the version pinned with this rules_ocx release).   | String | optional |  `""`  |

<a id="ocx.package"></a>

### package

Provisions a single OCX package from an OCI registry.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx.package-name"></a>name |  Name of the generated repository (hub name when `platforms` is set).   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx.package-bins"></a>bins |  Lazy provisioning: names of the executables to expose. Nothing is installed at fetch time — each name becomes a launcher re-entering `ocx package exec`, materializing the package on first execution, and no host config tier is watched because the launcher resolves configuration live on each run. Requires a digest-pinned identity (`pins` or '@sha256:'); `//:content` is unavailable in lazy mode, and `index` is incompatible because a snapshot resolves at fetch time only.   | List of strings | optional |  `[]`  |
| <a id="ocx.package-config"></a>config |  An ocx site config.toml (mirrors, registries, [patches]) layered over the host's discovered config — not the project ocx.toml; sets OCX_CONFIG for every invocation, overriding an ambient one, and is watched. Combine with no_config for a hermetic configuration; with `bins` it is copied into the repo and uploaded with every action — keep credentials out of it.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.package-index"></a>index |  Committed ocx index snapshot directory (created with `ocx --index <dir> index update <package>`, refreshed the same way). When set, tag resolution is frozen to the snapshot — floating tags like ':latest' become reproducible until the snapshot is refreshed.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.package-isolated_home"></a>isolated_home |  Reach for it when this build must neither touch nor be touched by the host store: uses a repository-local ocx store instead of the shared user OCX_HOME, at the cost of a full per-repository download (nothing shared with your shell, direnv, other repos or CI) and the $OCX_HOME-rooted config tiers no longer being watched. Incompatible with bins: a lazy launcher must resolve the store on whatever machine executes it.   | Boolean | optional |  `False`  |
| <a id="ocx.package-no_config"></a>no_config |  Reach for it when a corporate managed config must not reach the build: ignores the host's discovered tiers (/etc, the user config, $OCX_HOME/config.toml) and the managed-config snapshot, and opts out of the exit-78 gate a required-but-unsynced managed config raises. Sets OCX_NO_CONFIG=1 and additionally blanks an ambient OCX_CONFIG, OCX_PATCHES and OCX_PATCH_SNAPSHOT, which OCX_NO_CONFIG alone does not prune; the `config` and `patch_snapshot` attrs still apply.   | Boolean | optional |  `False`  |
| <a id="ocx.package-package"></a>package |  Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'. Freeze tag resolution with `index`, or pin per-platform manifest digests with `pins`.   | String | required |  |
| <a id="ocx.package-patch_snapshot"></a>patch_snapshot |  A committed patches.snapshot.json (`ocx patch freeze`, written next to ocx.lock) pinning the digests of the patch companions composed onto this environment; sets OCX_PATCH_SNAPSHOT. `ocx lock --check` does not cover companions, so without it they resolve at fetch time; with `bins` it is copied into the repo and uploaded with every action — keep credentials out of it.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.package-pins"></a>pins |  Per-platform manifest pins: ocx platform key -> 'sha256:…' digest of that platform's manifest (as reported by `ocx package install -p <platform>`). The matching platform installs 'registry/repo@<digest>'; unpinned platforms fall back to `package`.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="ocx.package-platform_aliases"></a>platform_aliases |  Optional declared-platform -> real-platform remap. Each key must appear in `platforms`; its value is the canonical ocx platform actually sent to `-p` and used to derive the hub's Bazel constraints. Everything Bazel-facing — repo suffix, `pins` lookup, config_setting, use_repo name — still keys on the declared platform; undeclared platforms are sent as-is. Example: {'linux/arm64': 'linux/arm64+libc.musl'} provisions a musl arm64 build under the plain 'linux/arm64' target.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="ocx.package-platforms"></a>platforms |  ocx platform keys ('linux/amd64', …) to provision in addition to the host: creates '<name>_<slug>' repos plus a '<name>' hub whose //:content select()s by target platform. Empty = host only.   | List of strings | optional |  `[]`  |

<a id="ocx.project"></a>

### project

Provisions the toolchain of a workspace ocx.toml + ocx.lock. Root module only.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx.project-name"></a>name |  Name of the generated repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx.project-bins"></a>bins |  Lazy provisioning: names of the executables to expose. When set, nothing is pulled at fetch time — each name becomes a launcher re-entering `ocx run`, materializing the toolchain on first execution. Actions key on the lockfile, so fully remote-cached builds download no tool content.   | List of strings | optional |  `[]`  |
| <a id="ocx.project-config"></a>config |  An ocx site config.toml (mirrors, registries, [patches]) layered over the host's discovered config — not the project ocx.toml; sets OCX_CONFIG for every invocation, overriding an ambient one, and is watched. Combine with no_config for a hermetic configuration; with `bins` it is copied into the repo and uploaded with every action — keep credentials out of it.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.project-groups"></a>groups |  ocx.toml groups to provision (scopes both the pull and the composed environment). Reserved names: 'default' = the top-level [tools] table, 'all' = default + every group.   | List of strings | optional |  `[]`  |
| <a id="ocx.project-isolated_home"></a>isolated_home |  Reach for it when this build must neither touch nor be touched by the host store: uses a repository-local ocx store instead of the shared user OCX_HOME, at the cost of a full per-repository download (nothing shared with your shell, direnv, other repos or CI) and the $OCX_HOME-rooted config tiers no longer being watched. Incompatible with bins: a lazy launcher must resolve the store on whatever machine executes it.   | Boolean | optional |  `False`  |
| <a id="ocx.project-no_config"></a>no_config |  Reach for it when a corporate managed config must not reach the build: ignores the host's discovered tiers (/etc, the user config, $OCX_HOME/config.toml) and the managed-config snapshot, and opts out of the exit-78 gate a required-but-unsynced managed config raises. Sets OCX_NO_CONFIG=1 and additionally blanks an ambient OCX_CONFIG, OCX_PATCHES and OCX_PATCH_SNAPSHOT, which OCX_NO_CONFIG alone does not prune; the `config` and `patch_snapshot` attrs still apply.   | Boolean | optional |  `False`  |
| <a id="ocx.project-ocx_lock"></a>ocx_lock |  The committed ocx.lock (watched; edits refetch).   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx.project-ocx_toml"></a>ocx_toml |  The project ocx.toml.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx.project-patch_snapshot"></a>patch_snapshot |  A committed patches.snapshot.json (`ocx patch freeze`, written next to ocx.lock) pinning the digests of the patch companions composed onto this environment; sets OCX_PATCH_SNAPSHOT. `ocx lock --check` does not cover companions, so without it they resolve at fetch time; with `bins` it is copied into the repo and uploaded with every action — keep credentials out of it.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.project-platform"></a>platform |  ocx platform key ('linux/arm64', …) to compose for; empty = host. A foreign platform pulls that platform's leaves from the same ocx.lock and exposes env.bzl only (no runnable launchers). Incompatible with bins.   | String | optional |  `""`  |


