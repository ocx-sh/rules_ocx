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
ocx.package(<a href="#ocx.package-name">name</a>, <a href="#ocx.package-bins">bins</a>, <a href="#ocx.package-index">index</a>, <a href="#ocx.package-isolated_home">isolated_home</a>, <a href="#ocx.package-package">package</a>, <a href="#ocx.package-pins">pins</a>, <a href="#ocx.package-platforms">platforms</a>)
ocx.project(<a href="#ocx.project-name">name</a>, <a href="#ocx.project-bins">bins</a>, <a href="#ocx.project-groups">groups</a>, <a href="#ocx.project-isolated_home">isolated_home</a>, <a href="#ocx.project-ocx_lock">ocx_lock</a>, <a href="#ocx.project-ocx_toml">ocx_toml</a>)
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
| <a id="ocx.package-bins"></a>bins |  Lazy provisioning: names of the executables to expose. When set, nothing is installed at fetch time — each name becomes a launcher re-entering `ocx package exec`, materializing the package on first execution. Requires a digest-pinned identity (`pins` or '@sha256:'); `//:content` is not available in lazy mode.   | List of strings | optional |  `[]`  |
| <a id="ocx.package-index"></a>index |  Committed ocx index snapshot directory (created with `ocx --index <dir> index update <package>`, refreshed the same way). When set, tag resolution is frozen to the snapshot — floating tags like ':latest' become reproducible until the snapshot is refreshed.   | <a href="https://bazel.build/concepts/labels">Label</a> | optional |  `None`  |
| <a id="ocx.package-isolated_home"></a>isolated_home |  Use a repository-local ocx store instead of the shared user OCX_HOME.   | Boolean | optional |  `False`  |
| <a id="ocx.package-package"></a>package |  Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'. Freeze tag resolution with `index`, or pin per-platform manifest digests with `pins`.   | String | required |  |
| <a id="ocx.package-pins"></a>pins |  Per-platform manifest pins: ocx platform key -> 'sha256:…' digest of that platform's manifest (as reported by `ocx package install -p <platform>`). The matching platform installs 'registry/repo@<digest>'; unpinned platforms fall back to `package`.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="ocx.package-platforms"></a>platforms |  ocx platform keys ('linux/amd64', …) to provision in addition to the host: creates '<name>_<os>_<arch>' repos plus a '<name>' hub whose //:content select()s by target platform. Empty = host only.   | List of strings | optional |  `[]`  |

<a id="ocx.project"></a>

### project

Provisions the toolchain of a workspace ocx.toml + ocx.lock. Root module only.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="ocx.project-name"></a>name |  Name of the generated repository.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="ocx.project-bins"></a>bins |  Lazy provisioning: names of the executables to expose. When set, nothing is pulled at fetch time — each name becomes a launcher re-entering `ocx run`, materializing the toolchain on first execution. Actions key on the lockfile, so fully remote-cached builds download no tool content.   | List of strings | optional |  `[]`  |
| <a id="ocx.project-groups"></a>groups |  Additional ocx.toml groups to pull into the store.   | List of strings | optional |  `[]`  |
| <a id="ocx.project-isolated_home"></a>isolated_home |  Use a repository-local ocx store instead of the shared user OCX_HOME.   | Boolean | optional |  `False`  |
| <a id="ocx.project-ocx_lock"></a>ocx_lock |  The committed ocx.lock (watched; edits refetch).   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="ocx.project-ocx_toml"></a>ocx_toml |  The project ocx.toml.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


