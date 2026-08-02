# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""The `ocx` module extension.

Bootstraps the pinned ocx CLI (`@ocx_tool`) and declares repositories that
provision tools through it. The implementation is a pure function of the
tags — all host detection and environment access happens inside the
repository rules — so the extension is marked reproducible and stays out of
MODULE.bazel.lock.
"""

load("//ocx/private:download.bzl", "ocx_download")
load("//ocx/private:package.bzl", "ocx_package_hub", "ocx_package_repo", "resolve_platforms")
load("//ocx/private:project.bzl", "ocx_project_repo")
load("//ocx/private:versions.bzl", "DEFAULT_OCX_VERSION")

_download = tag_class(
    doc = "Overrides the ocx CLI bootstrap. Root module only; at most one.",
    attrs = {
        "dist_manifest": attr.label(
            default = "//dist:dist.json",
            doc = "dist.json release manifest snapshot to resolve the download from.",
        ),
        "triple": attr.string(
            doc = "Exact release target triple, overriding host detection.",
        ),
        "version": attr.string(
            doc = "Exact ocx version (default: the version pinned with this rules_ocx release).",
        ),
    },
)

_project = tag_class(
    doc = "Provisions the toolchain of a workspace ocx.toml + ocx.lock. Root module only.",
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the generated repository.",
        ),
        "bins": attr.string_list(
            doc = "Lazy provisioning: names of the executables to expose. When set, " +
                  "nothing is pulled at fetch time — each name becomes a launcher " +
                  "re-entering `ocx run`, materializing the toolchain on first " +
                  "execution. Actions key on the lockfile, so fully remote-cached " +
                  "builds download no tool content.",
        ),
        "config": attr.label(
            doc = "An ocx site config.toml (mirrors, registries, [patches]) layered over the " +
                  "host's discovered config — not the project ocx.toml. Sets OCX_CONFIG for " +
                  "every invocation, overriding an ambient one, and the file is watched. " +
                  "Combine with no_config for a hermetic configuration.",
        ),
        "groups": attr.string_list(
            doc = "ocx.toml groups to provision (scopes both the pull and the " +
                  "composed environment). Reserved names: 'default' = the " +
                  "top-level [tools] table, 'all' = default + every group.",
        ),
        "isolated_home": attr.bool(
            default = False,
            doc = "Use a repository-local ocx store instead of the shared user OCX_HOME.",
        ),
        "no_config": attr.bool(
            default = False,
            doc = "Ignore the host's discovered config tiers (/etc, the user config, " +
                  "$OCX_HOME/config.toml) and the managed-config snapshot — sets OCX_NO_CONFIG=1. " +
                  "An explicit `config` still applies. Use this when a corporate managed config " +
                  "must not reach the build; it also opts out of the exit-78 gate a " +
                  "required-but-unsynced managed config raises.",
        ),
        "ocx_lock": attr.label(
            mandatory = True,
            doc = "The committed ocx.lock (watched; edits refetch).",
        ),
        "ocx_toml": attr.label(
            mandatory = True,
            doc = "The project ocx.toml.",
        ),
        "patch_snapshot": attr.label(
            doc = "A committed patches.snapshot.json (written by `ocx patch freeze` next to " +
                  "ocx.lock) freezing the digests of the patch companions composed onto this " +
                  "environment. Sets OCX_PATCH_SNAPSHOT. `ocx lock --check` does not cover " +
                  "companions — without a frozen snapshot they resolve at fetch time.",
        ),
        "platform": attr.string(
            doc = "ocx platform key ('linux/arm64', …) to compose for; empty = host. " +
                  "A foreign platform pulls that platform's leaves from the same " +
                  "ocx.lock and exposes env.bzl only (no runnable launchers). " +
                  "Incompatible with bins.",
        ),
    },
)

_package = tag_class(
    doc = "Provisions a single OCX package from an OCI registry.",
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the generated repository (hub name when `platforms` is set).",
        ),
        "bins": attr.string_list(
            doc = "Lazy provisioning: names of the executables to expose. When set, " +
                  "nothing is installed at fetch time — each name becomes a launcher " +
                  "re-entering `ocx package exec`, materializing the package on first " +
                  "execution. Requires a digest-pinned identity (`pins` or " +
                  "'@sha256:'); `//:content` is not available in lazy mode.",
        ),
        "config": attr.label(
            doc = "An ocx site config.toml (mirrors, registries, [patches]) layered over the " +
                  "host's discovered config — not the project ocx.toml. Sets OCX_CONFIG for " +
                  "every invocation, overriding an ambient one, and the file is watched. " +
                  "Combine with no_config for a hermetic configuration.",
        ),
        "index": attr.label(
            doc = "Committed ocx index snapshot directory (created with " +
                  "`ocx --index <dir> index update <package>`, refreshed the same " +
                  "way). When set, tag resolution is frozen to the snapshot — " +
                  "floating tags like ':latest' become reproducible until the " +
                  "snapshot is refreshed.",
        ),
        "isolated_home": attr.bool(
            default = False,
            doc = "Use a repository-local ocx store instead of the shared user OCX_HOME.",
        ),
        "no_config": attr.bool(
            default = False,
            doc = "Ignore the host's discovered config tiers (/etc, the user config, " +
                  "$OCX_HOME/config.toml) and the managed-config snapshot — sets OCX_NO_CONFIG=1. " +
                  "An explicit `config` still applies. Use this when a corporate managed config " +
                  "must not reach the build; it also opts out of the exit-78 gate a " +
                  "required-but-unsynced managed config raises.",
        ),
        "package": attr.string(
            mandatory = True,
            doc = "Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'. " +
                  "Freeze tag resolution with `index`, or pin per-platform " +
                  "manifest digests with `pins`.",
        ),
        "patch_snapshot": attr.label(
            doc = "A committed patches.snapshot.json (written by `ocx patch freeze` next to " +
                  "ocx.lock) freezing the digests of the patch companions composed onto this " +
                  "environment. Sets OCX_PATCH_SNAPSHOT. `ocx lock --check` does not cover " +
                  "companions — without a frozen snapshot they resolve at fetch time.",
        ),
        "pins": attr.string_dict(
            doc = "Per-platform manifest pins: ocx platform key -> 'sha256:…' digest " +
                  "of that platform's manifest (as reported by " +
                  "`ocx package install -p <platform>`). The matching platform " +
                  "installs 'registry/repo@<digest>'; unpinned platforms fall back " +
                  "to `package`.",
        ),
        "platform_aliases": attr.string_dict(
            doc = "Optional declared-platform -> real-platform remap. Each key must appear " +
                  "in `platforms`; its value is the canonical ocx platform actually sent to " +
                  "`-p` and used to derive the hub's Bazel constraints. Everything Bazel-facing " +
                  "— repo suffix, `pins` lookup, config_setting, use_repo name — still keys on " +
                  "the declared platform; undeclared platforms are sent as-is. Example: " +
                  "{'linux/arm64': 'linux/arm64+libc.musl'} provisions a musl arm64 build under " +
                  "the plain 'linux/arm64' target.",
        ),
        "platforms": attr.string_list(
            doc = "ocx platform keys ('linux/amd64', …) to provision in addition to " +
                  "the host: creates '<name>_<slug>' repos plus a '<name>' hub " +
                  "whose //:content select()s by target platform. Empty = host only.",
        ),
    },
)

def _ocx_impl(module_ctx):
    version = DEFAULT_OCX_VERSION
    dist_manifest = Label("//dist:dist.json")
    triple = ""
    seen = {}

    download_tags = 0
    for mod in module_ctx.modules:
        for tag in mod.tags.download:
            if not mod.is_root:
                fail("rules_ocx: ocx.download() may only be used by the root module")
            download_tags += 1
            if download_tags > 1:
                fail("rules_ocx: at most one ocx.download() tag is allowed")
            version = tag.version or version
            dist_manifest = tag.dist_manifest
            triple = tag.triple

    ocx_download(
        name = "ocx_tool",
        version = version,
        dist_manifest = dist_manifest,
        triple = triple,
    )

    for mod in module_ctx.modules:
        for tag in mod.tags.project:
            if not mod.is_root:
                fail("rules_ocx: ocx.project() may only be used by the root module")
            if tag.name in seen:
                fail("rules_ocx: duplicate repository name '{}'".format(tag.name))
            seen[tag.name] = True
            ocx_project_repo(
                name = tag.name,
                ocx_toml = tag.ocx_toml,
                ocx_lock = tag.ocx_lock,
                bins = tag.bins,
                groups = tag.groups,
                platform = tag.platform,
                isolated_home = tag.isolated_home,
                config = tag.config,
                no_config = tag.no_config,
                patch_snapshot = tag.patch_snapshot,
            )

        for tag in mod.tags.package:
            if tag.name in seen:
                fail("rules_ocx: duplicate repository name '{}'".format(tag.name))
            seen[tag.name] = True

            # Validates platform_aliases (keys ⊆ platforms) even in the host-only
            # branch below, where a non-empty dict is a mistake.
            resolved = resolve_platforms(tag.name, tag.platforms, tag.platform_aliases)
            if resolved.error:
                fail(resolved.error)
            if tag.platforms:
                platform_repos = {}
                platform_reals = {}
                for s, info in resolved.platforms.items():
                    repo = "{}_{}".format(tag.name, s)
                    platform_repos[s] = repo
                    platform_reals[s] = info.real
                    ocx_package_repo(
                        name = repo,
                        package = tag.package,
                        bins = tag.bins,
                        index = tag.index,
                        pins = tag.pins,
                        platform = info.declared,
                        resolved_platform = info.real,
                        isolated_home = tag.isolated_home,
                        config = tag.config,
                        no_config = tag.no_config,
                        patch_snapshot = tag.patch_snapshot,
                    )
                ocx_package_hub(
                    name = tag.name,
                    bins = tag.bins,
                    platform_repos = platform_repos,
                    platform_reals = platform_reals,
                )
            else:
                ocx_package_repo(
                    name = tag.name,
                    package = tag.package,
                    bins = tag.bins,
                    index = tag.index,
                    pins = tag.pins,
                    isolated_home = tag.isolated_home,
                    config = tag.config,
                    no_config = tag.no_config,
                    patch_snapshot = tag.patch_snapshot,
                )

    # No use_repo validation (root_module_direct_deps): the same extension is
    # commonly used through both a dev and a non-dev usage, and tags carry no
    # dev marker to attribute repos correctly.
    return module_ctx.extension_metadata(reproducible = True)

ocx = module_extension(
    implementation = _ocx_impl,
    doc = """Provisions tools through the OCX package manager.

Always creates `@ocx_tool` (the pinned ocx CLI). `ocx.project()` provisions
a workspace toolchain from ocx.toml/ocx.lock; `ocx.package()` provisions
individual OCI packages. See the tag class docs for details.""",
    tag_classes = {
        "download": _download,
        "package": _package,
        "project": _project,
    },
)
