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
load("//ocx/private:package.bzl", "ocx_package_hub", "ocx_package_repo")
load("//ocx/private:platforms.bzl", "repo_suffix")
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
        "groups": attr.string_list(
            doc = "Additional ocx.toml groups to pull into the store.",
        ),
        "isolated_home": attr.bool(
            default = False,
            doc = "Use a repository-local ocx store instead of the shared user OCX_HOME.",
        ),
        "ocx_lock": attr.label(
            mandatory = True,
            doc = "The committed ocx.lock (watched; edits refetch).",
        ),
        "ocx_toml": attr.label(
            mandatory = True,
            doc = "The project ocx.toml.",
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
        "isolated_home": attr.bool(
            default = False,
            doc = "Use a repository-local ocx store instead of the shared user OCX_HOME.",
        ),
        "package": attr.string(
            mandatory = True,
            doc = "Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'. " +
                  "A digest here pins one platform manifest — use `pins` to stay " +
                  "reproducible across platforms.",
        ),
        "pins": attr.string_dict(
            doc = "Per-platform manifest pins: ocx platform key -> 'sha256:…' digest " +
                  "of that platform's manifest (as reported by " +
                  "`ocx package install -p <platform>`). The matching platform " +
                  "installs 'registry/repo@<digest>'; unpinned platforms fall back " +
                  "to `package`.",
        ),
        "platforms": attr.string_list(
            doc = "ocx platform keys ('linux/amd64', …) to provision in addition to " +
                  "the host: creates '<name>_<os>_<arch>' repos plus a '<name>' hub " +
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
                groups = tag.groups,
                isolated_home = tag.isolated_home,
            )

        for tag in mod.tags.package:
            if tag.name in seen:
                fail("rules_ocx: duplicate repository name '{}'".format(tag.name))
            seen[tag.name] = True
            if tag.platforms:
                platform_repos = {}
                for platform in tag.platforms:
                    repo = "{}_{}".format(tag.name, repo_suffix(platform))
                    platform_repos[platform] = repo
                    ocx_package_repo(
                        name = repo,
                        package = tag.package,
                        pins = tag.pins,
                        platform = platform,
                        isolated_home = tag.isolated_home,
                    )
                ocx_package_hub(
                    name = tag.name,
                    platform_repos = platform_repos,
                )
            else:
                ocx_package_repo(
                    name = tag.name,
                    package = tag.package,
                    pins = tag.pins,
                    isolated_home = tag.isolated_home,
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
