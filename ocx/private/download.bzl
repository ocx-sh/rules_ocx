# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Repository rule bootstrapping the pinned ocx CLI binary.

Downloads the release archive listed in the vendored dist.json snapshot
(sha256-enforced), honoring the same corporate-mirror knobs as the
setup.ocx.sh installer. Binary-only placement — never runs `ocx self setup`.
"""

load(":manifest.bzl", "archive_type", "artifact_url", "manifest_sha256", "select_release")
load(":platforms.bzl", "host_info")
load(":versions.bzl", "MIN_OCX_VERSION", "min_version_error")

visibility(["//ocx", "//ocx/tests"])

_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files(glob(["ocx*"]))

filegroup(
    name = "binary",
    srcs = ["ocx"],
)
"""

def _ocx_download_impl(ctx):
    err = min_version_error(ctx.attr.version)
    if err:
        fail(err)

    host = host_info(ctx.os.name, ctx.os.arch)
    triple = ctx.attr.triple or host.triple

    dist_url = ctx.getenv("OCX_INSTALL_DIST_URL")
    if dist_url:
        ctx.download(dist_url, "dist.json", sha256 = manifest_sha256(dist_url))
        manifest = json.decode(ctx.read("dist.json"))
    else:
        manifest = json.decode(ctx.read(ctx.attr.dist_manifest))

    row = select_release(manifest, ctx.attr.version, triple)
    url = artifact_url(row, ctx.getenv("OCX_INSTALL_MIRROR_URL"))
    ctx.download_and_extract(url, output = "extracted", sha256 = row["sha256"], type = archive_type(row["filename"]))

    bin_name = "ocx" + host.exe_ext
    nested = ctx.path("extracted/ocx-{}/{}".format(triple, bin_name))
    flat = ctx.path("extracted/" + bin_name)
    source = nested if nested.exists else flat
    if not source.exists:
        fail("rules_ocx: '{}' not found in the extracted ocx archive from {}".format(bin_name, url))

    # Stable label `//:ocx` regardless of platform; Windows additionally gets
    # the executable `ocx.exe` sibling that ocx_bin() prefers.
    ctx.symlink(source, "ocx")
    if host.exe_ext:
        ctx.symlink(source, "ocx.exe")
    ctx.file("BUILD.bazel", _BUILD)

ocx_download = repository_rule(
    implementation = _ocx_download_impl,
    doc = """Downloads a pinned ocx CLI release for the host platform.

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

`version` must be {} or newer: rules_ocx drives `ocx exec` and
`--no-verify`, neither of which exists on older releases.""".format(MIN_OCX_VERSION),
    attrs = {
        "dist_manifest": attr.label(
            default = "//dist:dist.json",
            allow_single_file = [".json"],
            doc = "Release manifest snapshot (dist.json schema 1).",
        ),
        "triple": attr.string(
            doc = "Escape hatch: exact release target triple, e.g. " +
                  "'x86_64-unknown-linux-gnu' to prefer the glibc build. " +
                  "Defaults to host detection (Linux maps to musl).",
        ),
        "version": attr.string(
            mandatory = True,
            doc = "Exact ocx version to download, e.g. '0.6.0'. Must be " +
                  "{} or newer.".format(MIN_OCX_VERSION),
        ),
    },
)
