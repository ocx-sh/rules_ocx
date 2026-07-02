<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API of rules_ocx.

Most consumers only need the `ocx` module extension
(`@rules_ocx//ocx:extensions.bzl`). The repository rules are re-exported
here for power users composing their own extensions on top of the same
CLI-backed provisioning.

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
`<mirror>/<tag>/<filename>`. The manifest sha256 is enforced either way.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_download-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_download-dist_manifest"></a>dist_manifest |  Release manifest snapshot (dist.json schema 1).   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@rules_ocx//dist:dist.json"`  |
| <a id="ocx_download-repo_mapping"></a>repo_mapping |  In `WORKSPACE` context only: a dictionary from local repository name to global repository name. This allows controls over workspace dependency resolution for dependencies of this repository.<br><br>For example, an entry `"@foo": "@bar"` declares that, for any time this repository depends on `@foo` (such as a dependency on `@foo//some:target`, it should actually resolve that dependency within globally-declared `@bar` (`@bar//some:target`).<br><br>This attribute is _not_ supported in `MODULE.bazel` context (when invoking a repository rule inside a module extension's implementation function).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  |
| <a id="ocx_download-triple"></a>triple |  Escape hatch: exact release target triple, e.g. 'x86_64-unknown-linux-gnu' to prefer the glibc build. Defaults to host detection (Linux maps to musl).   | String | optional |  `""`  |
| <a id="ocx_download-version"></a>version |  Exact ocx version to download, e.g. '0.3.10'.   | String | required |  |


<a id="ocx_package_hub"></a>

## ocx_package_hub

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_package_hub")

ocx_package_hub(<a href="#ocx_package_hub-name">name</a>, <a href="#ocx_package_hub-bins">bins</a>, <a href="#ocx_package_hub-platform_repos">platform_repos</a>, <a href="#ocx_package_hub-repo_mapping">repo_mapping</a>)
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
| <a id="ocx_package_hub-platform_repos"></a>platform_repos |  ocx platform key -> apparent name of the per-platform package repo.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | required |  |
| <a id="ocx_package_hub-repo_mapping"></a>repo_mapping |  In `WORKSPACE` context only: a dictionary from local repository name to global repository name. This allows controls over workspace dependency resolution for dependencies of this repository.<br><br>For example, an entry `"@foo": "@bar"` declares that, for any time this repository depends on `@foo` (such as a dependency on `@foo//some:target`, it should actually resolve that dependency within globally-declared `@bar` (`@bar//some:target`).<br><br>This attribute is _not_ supported in `MODULE.bazel` context (when invoking a repository rule inside a module extension's implementation function).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  |


<a id="ocx_package_repo"></a>

## ocx_package_repo

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_package_repo")

ocx_package_repo(<a href="#ocx_package_repo-name">name</a>, <a href="#ocx_package_repo-bins">bins</a>, <a href="#ocx_package_repo-index">index</a>, <a href="#ocx_package_repo-isolated_home">isolated_home</a>, <a href="#ocx_package_repo-ocx">ocx</a>, <a href="#ocx_package_repo-package">package</a>, <a href="#ocx_package_repo-pins">pins</a>, <a href="#ocx_package_repo-platform">platform</a>, <a href="#ocx_package_repo-repo_mapping">repo_mapping</a>)
</pre>

Provisions a single OCX package from an OCI registry.

`//:content` is the package tree; every executable reachable through the
package environment becomes a runnable target `//:<name>` (host-platform
repos only). For reproducibility, commit an index snapshot and reference it
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
| <a id="ocx_package_repo-bins"></a>bins |  Lazy provisioning: names of the executables to expose (not validated at fetch time). When set, nothing is installed during the fetch — each name becomes a launcher re-entering `ocx package exec`, keyed on the digest-pinned reference. Requires a digest-pinned identity (`pins` or '@sha256:'); incompatible with isolated_home and index.   | List of strings | optional |  `[]`  |
| <a id="ocx_package_repo-index"></a>index |  Committed ocx index snapshot directory (created with `ocx --index <dir> index update <package>`). When set, tag resolution is frozen to the snapshot (`--index --frozen`): floating tags become reproducible until the snapshot is refreshed.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx_package_repo-isolated_home"></a>isolated_home |  Keep the ocx store inside this repository instead of the shared user OCX_HOME.   | Boolean | optional |  `False`  |
| <a id="ocx_package_repo-ocx"></a>ocx |  The pinned ocx CLI binary.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@ocx_tool//:ocx"`  |
| <a id="ocx_package_repo-package"></a>package |  Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'.   | String | required |  |
| <a id="ocx_package_repo-pins"></a>pins |  ocx platform key -> 'sha256:…' manifest digest overriding the digest of `package` for that platform.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="ocx_package_repo-platform"></a>platform |  ocx platform key ('linux/amd64', …) to provision for; empty = host.   | String | optional |  `""`  |
| <a id="ocx_package_repo-repo_mapping"></a>repo_mapping |  In `WORKSPACE` context only: a dictionary from local repository name to global repository name. This allows controls over workspace dependency resolution for dependencies of this repository.<br><br>For example, an entry `"@foo": "@bar"` declares that, for any time this repository depends on `@foo` (such as a dependency on `@foo//some:target`, it should actually resolve that dependency within globally-declared `@bar` (`@bar//some:target`).<br><br>This attribute is _not_ supported in `MODULE.bazel` context (when invoking a repository rule inside a module extension's implementation function).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  |


<a id="ocx_project_repo"></a>

## ocx_project_repo

<pre>
load("@rules_ocx//ocx:defs.bzl", "ocx_project_repo")

ocx_project_repo(<a href="#ocx_project_repo-name">name</a>, <a href="#ocx_project_repo-bins">bins</a>, <a href="#ocx_project_repo-groups">groups</a>, <a href="#ocx_project_repo-isolated_home">isolated_home</a>, <a href="#ocx_project_repo-ocx">ocx</a>, <a href="#ocx_project_repo-ocx_lock">ocx_lock</a>, <a href="#ocx_project_repo-ocx_toml">ocx_toml</a>, <a href="#ocx_project_repo-repo_mapping">repo_mapping</a>)
</pre>

Provisions the toolchain declared in a workspace ocx.toml/ocx.lock.

Fails when the lockfile is stale or missing (fix with `ocx lock`). Every
executable reachable through the composed environment's `path` entries
becomes a runnable target `//:<name>`; the raw environment is loadable from
`//:env.bzl` (`OCX_ENV`, `OCX_HOME`).

With `bins`, provisioning is lazy: nothing is pulled at fetch time, and each
named executable becomes a launcher that re-enters `ocx run` — content
materializes on first execution and never becomes a Bazel action input, so
fully remote-cached builds download no tool content at all.

`groups` scopes both the pull and the composed environment. Omitted, ocx's
defaults apply: every group is pulled, but only the default `[tools]` table
is composed into launchers — name groups explicitly (or use the reserved
`all`) to expose their executables.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx_project_repo-name"></a>name |  A unique name for this repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx_project_repo-bins"></a>bins |  Lazy provisioning: names of the executables to expose (not validated at fetch time). When set, nothing is pulled during the fetch — each name becomes a launcher re-entering `ocx run`, and actions key on the lockfile (a runfile) instead of tool content. Incompatible with isolated_home.   | List of strings | optional |  `[]`  |
| <a id="ocx_project_repo-groups"></a>groups |  ocx.toml groups to provision (comma-joined into `-g` for `ocx pull`, `ocx env`, and lazy `ocx run`). Reserved names: 'default' = the top-level [tools] table, 'all' = default + every declared group.   | List of strings | optional |  `[]`  |
| <a id="ocx_project_repo-isolated_home"></a>isolated_home |  Keep the ocx store inside this repository instead of the shared user OCX_HOME.   | Boolean | optional |  `False`  |
| <a id="ocx_project_repo-ocx"></a>ocx |  The pinned ocx CLI binary.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `"@ocx_tool//:ocx"`  |
| <a id="ocx_project_repo-ocx_lock"></a>ocx_lock |  The ocx.lock next to ocx_toml; watched so lock changes refetch.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx_project_repo-ocx_toml"></a>ocx_toml |  The project ocx.toml declaring the toolchain.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx_project_repo-repo_mapping"></a>repo_mapping |  In `WORKSPACE` context only: a dictionary from local repository name to global repository name. This allows controls over workspace dependency resolution for dependencies of this repository.<br><br>For example, an entry `"@foo": "@bar"` declares that, for any time this repository depends on `@foo` (such as a dependency on `@foo//some:target`, it should actually resolve that dependency within globally-declared `@bar` (`@bar//some:target`).<br><br>This attribute is _not_ supported in `MODULE.bazel` context (when invoking a repository rule inside a module extension's implementation function).   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  |


