<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API of rules_ocx.

Most consumers only need the `ocx` module extension
(`@rules_ocx//ocx:extensions.bzl`). The repository rules are re-exported
here for power users composing their own extensions on top of the same
CLI-backed provisioning.

<a id="ocx_platform_constraints"></a>

## ocx_platform_constraints

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_platform_constraints")

ocx_platform_constraints(<a href="#ocx_platform_constraints-platform">platform</a>)
</pre>

Bazel constraint labels for the os/arch prefix of an ocx platform key.

'linux/arm64+libc.musl' -> ['@platforms//os:linux', '@platforms//cpu:aarch64'].
For toolchain authors composing exec_compatible_with; also the hub's source
of config_setting constraint_values. Fails on an unmappable os/arch.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="ocx_platform_constraints-platform"></a>platform |  an ocx platform key ('os/arch[/variant][+feature,...]').   |  none |

**RETURNS**

[os_constraint_label, cpu_constraint_label].


<a id="ocx_download"></a>

## ocx_download

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_download")

ocx_download(<a href="#ocx_download-name">name</a>, <a href="#ocx_download-dist_manifest">dist_manifest</a>, <a href="#ocx_download-repo_mapping">repo_mapping</a>, <a href="#ocx_download-triple">triple</a>, <a href="#ocx_download-version">version</a>)
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

`version` must be 0.6.0 or newer: rules_ocx drives `ocx exec` and pins
`OCX_NO_VERIFY`, neither of which exists on older releases.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_download-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_download-dist_manifest"></a>dist_manifest |  Release manifest snapshot (dist.json schema 1).   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@rules_ocx//dist:dist.json"`  |
| <a id="ocx_download-repo_mapping"></a>repo_mapping |  In `WORKSPACE` context only: a dictionary from local repository name to global repository name. This allows controls over workspace dependency resolution for dependencies of this repository.<br><br>For example, an entry `"@foo": "@bar"` declares that, for any time this repository depends on `@foo` (such as a dependency on `@foo//some:target`, it should actually resolve that dependency within globally-declared `@bar` (`@bar//some:target`).<br><br>This attribute is _not_ supported in `MODULE.bazel` context (when invoking a repository rule inside a module extension's implementation function).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  |
| <a id="ocx_download-triple"></a>triple |  Escape hatch: exact release target triple, e.g. 'x86_64-unknown-linux-gnu' to prefer the glibc build. Defaults to host detection (Linux maps to musl).   | String | optional |  `""`  |
| <a id="ocx_download-version"></a>version |  Exact ocx version to download, e.g. '0.6.0'. Must be 0.6.0 or newer.   | String | required |  |


<a id="ocx_package_hub"></a>

## ocx_package_hub

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_package_hub")

ocx_package_hub(<a href="#ocx_package_hub-name">name</a>, <a href="#ocx_package_hub-bins">bins</a>, <a href="#ocx_package_hub-platform_reals">platform_reals</a>, <a href="#ocx_package_hub-platform_repos">platform_repos</a>, <a href="#ocx_package_hub-repo_mapping">repo_mapping</a>)
</pre>

Multi-platform hub for an ocx.package() with `platforms`.

`//:content` (or, with `bins`, each named launcher) select()s the
per-platform package repo matching the target platform — combine with a
platform transition to fetch foreign-platform tools (e.g. for container
images).

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_package_hub-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_package_hub-bins"></a>bins |  Lazy mode: launcher names to alias instead of //:content.   | List of strings | optional |  `[]`  |
| <a id="ocx_package_hub-platform_reals"></a>platform_reals |  repo slug -> real ocx platform, the source of each config_setting's Bazel constraint_values.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | required |  |
| <a id="ocx_package_hub-platform_repos"></a>platform_repos |  repo slug -> apparent name of the per-platform package repo.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | required |  |
| <a id="ocx_package_hub-repo_mapping"></a>repo_mapping |  In `WORKSPACE` context only: a dictionary from local repository name to global repository name. This allows controls over workspace dependency resolution for dependencies of this repository.<br><br>For example, an entry `"@foo": "@bar"` declares that, for any time this repository depends on `@foo` (such as a dependency on `@foo//some:target`, it should actually resolve that dependency within globally-declared `@bar` (`@bar//some:target`).<br><br>This attribute is _not_ supported in `MODULE.bazel` context (when invoking a repository rule inside a module extension's implementation function).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  |


<a id="ocx_package_repo"></a>

## ocx_package_repo

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_package_repo")

ocx_package_repo(<a href="#ocx_package_repo-name">name</a>, <a href="#ocx_package_repo-allow_unverified">allow_unverified</a>, <a href="#ocx_package_repo-allow_yanked">allow_yanked</a>, <a href="#ocx_package_repo-bins">bins</a>, <a href="#ocx_package_repo-config">config</a>, <a href="#ocx_package_repo-index">index</a>, <a href="#ocx_package_repo-isolated_home">isolated_home</a>,
                 <a href="#ocx_package_repo-no_config">no_config</a>, <a href="#ocx_package_repo-ocx">ocx</a>, <a href="#ocx_package_repo-package">package</a>, <a href="#ocx_package_repo-patch_snapshot">patch_snapshot</a>, <a href="#ocx_package_repo-pins">pins</a>, <a href="#ocx_package_repo-platform">platform</a>, <a href="#ocx_package_repo-repo_mapping">repo_mapping</a>,
                 <a href="#ocx_package_repo-resolved_platform">resolved_platform</a>, <a href="#ocx_package_repo-sigstore_trusted_root">sigstore_trusted_root</a>)
</pre>

Provisions a single OCX package from an OCI registry.

`//:content` is the package tree; every executable the package declares as
its public surface (`ocx package inspect --closure`) becomes a runnable
target `//:<name>` (host-platform repos only). A package shipping no
complete `binaries` metadata falls back to scanning the composed PATH, which
also exposes its private executables — `//:env.bzl`'s `OCX_SCANNED_PACKAGES`
names the packages that forced it. For reproducibility, commit an index
snapshot and reference it
via `index` (tags then resolve frozen from the snapshot), or pin
per-platform manifest digests via `pins` — plain floating tags resolve at
fetch time and log the resolved digest.

With `bins`, provisioning is lazy: nothing is installed at fetch time, and
each named executable becomes a launcher re-entering `ocx package exec` —
content materializes on first execution and never becomes a Bazel action
input (`//:content` is not available in lazy mode).

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_package_repo-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_package_repo-allow_unverified"></a>allow_unverified |  When true, sets OCX_NO_VERIFY=1 for every invocation — ocx's own documented equivalent of `--no-verify`, so no verify flag is ever put on an argv. When false, OCX_NO_VERIFY=0 is written anyway, so an ambient value cannot switch verification off. It cannot switch verification *on*: ocx attaches that only under an operator-configured `[[trust.policy]]`, so this attr can only decline to disable it — and `no_config = True` prunes the discovered tiers that policy lives in, so there is then nothing to decline and verification is off either way.   | Boolean | optional |  `False`  |
| <a id="ocx_package_repo-allow_yanked"></a>allow_yanked |  Whether resolution may fall back to a yanked release — sets OCX_ALLOW_YANKED for every invocation.   | Boolean | optional |  `False`  |
| <a id="ocx_package_repo-bins"></a>bins |  Lazy provisioning: names of the executables to expose (not validated at fetch time). When set, nothing is installed during the fetch — each name becomes a launcher re-entering `ocx package exec`, keyed on the digest-pinned reference. Requires a digest-pinned identity (`pins` or '@sha256:'); incompatible with isolated_home and index.   | List of strings | optional |  `[]`  |
| <a id="ocx_package_repo-config"></a>config |  An ocx site config.toml (mirrors, registries, [patches]) layered over the host's discovered config — not the project ocx.toml. Sets OCX_CONFIG for every invocation, overriding an ambient one, and the file is watched. Combine with no_config for a hermetic configuration. With `bins` it is copied into the repository and uploaded as an input with every action — keep credentials out of it.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_package_repo-index"></a>index |  Committed ocx index snapshot directory (created with `ocx --index <dir> index update <package>`). When set, tag resolution is frozen to the snapshot (`--index --frozen`): floating tags become reproducible until the snapshot is refreshed.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_package_repo-isolated_home"></a>isolated_home |  Keep the ocx store inside this repository instead of the shared user OCX_HOME. It also relocates OCX_HOME, so ocx's `~/.ocx/sigstore/trusted-root.json` rung is not found there — with a trust policy configured, trusted-root resolution falls through to the Rekor trust-root cache and then a live TUF fetch; offline it stops at the cache and fails outright, as ocx ships no embedded root.   | Boolean | optional |  `False`  |
| <a id="ocx_package_repo-no_config"></a>no_config |  Ignore the host's discovered config tiers (/etc, the user config, $OCX_HOME/config.toml) and the managed-config snapshot — sets OCX_NO_CONFIG=1, and blanks an ambient OCX_CONFIG, OCX_PATCHES and OCX_PATCH_SNAPSHOT, which OCX_NO_CONFIG alone does not prune. The `config` and `patch_snapshot` attrs still apply. Use this when a corporate managed config must not reach the build; it also opts out of the exit-78 gate a required-but-unsynced managed config raises.   | Boolean | optional |  `False`  |
| <a id="ocx_package_repo-ocx"></a>ocx |  The pinned ocx CLI binary.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@ocx_tool//:ocx"`  |
| <a id="ocx_package_repo-package"></a>package |  Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'.   | String | required |  |
| <a id="ocx_package_repo-patch_snapshot"></a>patch_snapshot |  A committed patches.snapshot.json (written by `ocx patch freeze` next to ocx.lock) freezing the digests of the patch companions composed onto this environment. Sets OCX_PATCH_SNAPSHOT. `ocx lock --check` does not cover companions — without a frozen snapshot they resolve at fetch time. With `bins` it is copied into the repository and uploaded as an input with every action — keep credentials out of it.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_package_repo-pins"></a>pins |  ocx platform key -> 'sha256:…' manifest digest overriding the digest of `package` for that platform.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="ocx_package_repo-platform"></a>platform |  ocx platform key ('linux/amd64', …) to provision for; empty = host.   | String | optional |  `""`  |
| <a id="ocx_package_repo-repo_mapping"></a>repo_mapping |  In `WORKSPACE` context only: a dictionary from local repository name to global repository name. This allows controls over workspace dependency resolution for dependencies of this repository.<br><br>For example, an entry `"@foo": "@bar"` declares that, for any time this repository depends on `@foo` (such as a dependency on `@foo//some:target`, it should actually resolve that dependency within globally-declared `@bar` (`@bar//some:target`).<br><br>This attribute is _not_ supported in `MODULE.bazel` context (when invoking a repository rule inside a module extension's implementation function).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  |
| <a id="ocx_package_repo-resolved_platform"></a>resolved_platform |  Real ocx platform sent to `-p` — lets a declared `platform` be aliased to a different real one (variant/feature build). Empty = derive from `platform`. Runnable-target gating compares its os/arch prefix to the host; `pins` still key on `platform`.   | String | optional |  `""`  |
| <a id="ocx_package_repo-sigstore_trusted_root"></a>sigstore_trusted_root |  A sigstore trusted-root.json pinned in-tree. Sets OCX_SIGSTORE_TRUSTED_ROOT for every invocation, overriding the ambient `<OCX_HOME>/sigstore/trusted-root.json` rung, and the file is watched. Under lazy provisioning (`bins` on `ocx.project`/`ocx.package`) it is copied into the repository and uploaded as an input with every action.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |


<a id="ocx_project_repo"></a>

## ocx_project_repo

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_project_repo")

ocx_project_repo(<a href="#ocx_project_repo-name">name</a>, <a href="#ocx_project_repo-allow_unverified">allow_unverified</a>, <a href="#ocx_project_repo-allow_yanked">allow_yanked</a>, <a href="#ocx_project_repo-bins">bins</a>, <a href="#ocx_project_repo-config">config</a>, <a href="#ocx_project_repo-groups">groups</a>, <a href="#ocx_project_repo-isolated_home">isolated_home</a>,
                 <a href="#ocx_project_repo-no_config">no_config</a>, <a href="#ocx_project_repo-ocx">ocx</a>, <a href="#ocx_project_repo-ocx_lock">ocx_lock</a>, <a href="#ocx_project_repo-ocx_toml">ocx_toml</a>, <a href="#ocx_project_repo-patch_snapshot">patch_snapshot</a>, <a href="#ocx_project_repo-platform">platform</a>, <a href="#ocx_project_repo-repo_mapping">repo_mapping</a>,
                 <a href="#ocx_project_repo-sigstore_trusted_root">sigstore_trusted_root</a>)
</pre>

Provisions the toolchain declared in a workspace ocx.toml/ocx.lock.

Fails when the lockfile is stale or missing (fix with `ocx lock`). Every
executable the toolchain's packages declare as their public surface
(`ocx inspect --closure`) becomes a runnable target `//:<name>`; a package
shipping no complete `binaries` metadata falls back to scanning the composed
PATH, which also exposes its private executables — `//:env.bzl`'s
`OCX_SCANNED_PACKAGES` names the packages that forced it. The raw
environment is loadable from the same file (`OCX_ENV`, `OCX_HOME`).

With `bins`, provisioning is lazy: nothing is pulled at fetch time, and each
named executable becomes a launcher that re-enters `ocx exec` — content
materializes on first execution and never becomes a Bazel action input, so
fully remote-cached builds download no tool content at all.

`groups` scopes both the pull and the composed environment. Omitted, ocx's
defaults apply: every group is pulled, but only the default `[tools]` table
is composed into launchers — name groups explicitly (or use the reserved
`all`) to expose their executables.

`platform` composes a foreign platform's environment from the same
ocx.lock: that platform's leaves are pulled into the store and `env.bzl`
holds their absolute store paths (sysroots, target libraries, container
image content). Foreign repos expose no runnable launchers — the binaries
do not run on this host.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_project_repo-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_project_repo-allow_unverified"></a>allow_unverified |  When true, sets OCX_NO_VERIFY=1 for every invocation — ocx's own documented equivalent of `--no-verify`, so no verify flag is ever put on an argv. When false, OCX_NO_VERIFY=0 is written anyway, so an ambient value cannot switch verification off. It cannot switch verification *on*: ocx attaches that only under an operator-configured `[[trust.policy]]`, so this attr can only decline to disable it — and `no_config = True` prunes the discovered tiers that policy lives in, so there is then nothing to decline and verification is off either way.   | Boolean | optional |  `False`  |
| <a id="ocx_project_repo-allow_yanked"></a>allow_yanked |  Whether resolution may fall back to a yanked release — sets OCX_ALLOW_YANKED for every invocation.   | Boolean | optional |  `False`  |
| <a id="ocx_project_repo-bins"></a>bins |  Lazy provisioning: names of the executables to expose (not validated at fetch time). When set, nothing is pulled during the fetch — each name becomes a launcher re-entering `ocx exec`, and actions key on the lockfile (a runfile) instead of tool content. Incompatible with isolated_home.   | List of strings | optional |  `[]`  |
| <a id="ocx_project_repo-config"></a>config |  An ocx site config.toml (mirrors, registries, [patches]) layered over the host's discovered config — not the project ocx.toml. Sets OCX_CONFIG for every invocation, overriding an ambient one, and the file is watched. Combine with no_config for a hermetic configuration. With `bins` it is copied into the repository and uploaded as an input with every action — keep credentials out of it.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_project_repo-groups"></a>groups |  ocx.toml groups to provision (comma-joined into `-g` for `ocx pull`, `ocx env`, and lazy `ocx exec`). Reserved names: 'default' = the top-level [tools] table, 'all' = default + every declared group.   | List of strings | optional |  `[]`  |
| <a id="ocx_project_repo-isolated_home"></a>isolated_home |  Keep the ocx store inside this repository instead of the shared user OCX_HOME. It also relocates OCX_HOME, so ocx's `~/.ocx/sigstore/trusted-root.json` rung is not found there — with a trust policy configured, trusted-root resolution falls through to the Rekor trust-root cache and then a live TUF fetch; offline it stops at the cache and fails outright, as ocx ships no embedded root.   | Boolean | optional |  `False`  |
| <a id="ocx_project_repo-no_config"></a>no_config |  Ignore the host's discovered config tiers (/etc, the user config, $OCX_HOME/config.toml) and the managed-config snapshot — sets OCX_NO_CONFIG=1, and blanks an ambient OCX_CONFIG, OCX_PATCHES and OCX_PATCH_SNAPSHOT, which OCX_NO_CONFIG alone does not prune. The `config` and `patch_snapshot` attrs still apply. Use this when a corporate managed config must not reach the build; it also opts out of the exit-78 gate a required-but-unsynced managed config raises.   | Boolean | optional |  `False`  |
| <a id="ocx_project_repo-ocx"></a>ocx |  The pinned ocx CLI binary.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@ocx_tool//:ocx"`  |
| <a id="ocx_project_repo-ocx_lock"></a>ocx_lock |  The ocx.lock next to ocx_toml; watched so lock changes refetch.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx_project_repo-ocx_toml"></a>ocx_toml |  The project ocx.toml declaring the toolchain.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx_project_repo-patch_snapshot"></a>patch_snapshot |  A committed patches.snapshot.json (written by `ocx patch freeze` next to ocx.lock) freezing the digests of the patch companions composed onto this environment. Sets OCX_PATCH_SNAPSHOT. `ocx lock --check` does not cover companions — without a frozen snapshot they resolve at fetch time. With `bins` it is copied into the repository and uploaded as an input with every action — keep credentials out of it.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_project_repo-platform"></a>platform |  ocx platform key ('linux/arm64', …) to compose for; empty = host. A foreign platform pulls that platform's leaves from the same ocx.lock and exposes env.bzl only (no runnable launchers). Incompatible with bins — lazy launchers already resolve the executing host at run time.   | String | optional |  `""`  |
| <a id="ocx_project_repo-repo_mapping"></a>repo_mapping |  In `WORKSPACE` context only: a dictionary from local repository name to global repository name. This allows controls over workspace dependency resolution for dependencies of this repository.<br><br>For example, an entry `"@foo": "@bar"` declares that, for any time this repository depends on `@foo` (such as a dependency on `@foo//some:target`, it should actually resolve that dependency within globally-declared `@bar` (`@bar//some:target`).<br><br>This attribute is _not_ supported in `MODULE.bazel` context (when invoking a repository rule inside a module extension's implementation function).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  |
| <a id="ocx_project_repo-sigstore_trusted_root"></a>sigstore_trusted_root |  A sigstore trusted-root.json pinned in-tree. Sets OCX_SIGSTORE_TRUSTED_ROOT for every invocation, overriding the ambient `<OCX_HOME>/sigstore/trusted-root.json` rung, and the file is watched. Under lazy provisioning (`bins` on `ocx.project`/`ocx.package`) it is copied into the repository and uploaded as an input with every action.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |


