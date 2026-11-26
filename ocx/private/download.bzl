# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Repository rule and helpers bootstrapping the pinned ocx CLI binary.

Downloads the release archive listed in the vendored dist.json snapshot
(sha256-enforced), honoring the same corporate-mirror knobs as the
setup.ocx.sh installer. Binary-only placement — never runs `ocx self setup`.
"""

load(":facts.bzl", "manifest_env")
load(":manifest.bzl", "archive_type", "artifact_url", "is_sha256", "manifest_sha256", "select_release")
load(":platforms.bzl", "host_info")
load(":versions.bzl", "DEFAULT_OCX_VERSION", "MIN_OCX_VERSION", "NO_SUPPORTED_RELEASE_NOTE", "local_binary_version_error", "min_version_error")

visibility(["//ocx", "//ocx/tests"])

_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files(glob(["ocx*"]))

filegroup(
    name = "binary",
    srcs = ["ocx"],
)
"""

def local_binary_request(path, sha256):
    """Validates the OCX_INSTALL_BINARY / OCX_INSTALL_BINARY_SHA256 pair.

    Args:
        path: value of OCX_INSTALL_BINARY (absolute path), or "".
        sha256: value of OCX_INSTALL_BINARY_SHA256, or "".

    Returns:
        struct(url, sha256, error). Both empty: `url` is "" (use the released
        pin). Both set and valid: `url` is the file:// URL to download from.
        Anything else: `error` is non-empty.
    """
    if not path and not sha256:
        return struct(url = "", sha256 = "", error = "")
    if path and not sha256:
        return struct(url = "", sha256 = "", error = "rules_ocx: OCX_INSTALL_BINARY is set but OCX_INSTALL_BINARY_SHA256 is not; " +
                                                     "a local ocx is only trusted together with its sha256")
    if sha256 and not path:
        return struct(url = "", sha256 = "", error = "rules_ocx: OCX_INSTALL_BINARY_SHA256 is set but OCX_INSTALL_BINARY is not")
    if not is_sha256(sha256):
        return struct(url = "", sha256 = "", error = "rules_ocx: OCX_INSTALL_BINARY_SHA256 must be 64 lowercase hex characters, got '{}'".format(sha256))

    normalized = path.replace("\\", "/")

    # The path goes into a URL unencoded, so a character that changes URL meaning is refused, as is a UNC path.
    for char in [" ", "%", "#", "?"]:
        if char in normalized:
            return struct(url = "", sha256 = "", error = "rules_ocx: OCX_INSTALL_BINARY must not contain '{}' (it is used as a file:// URL), got '{}'".format(char, path))
    if normalized.startswith("//"):
        return struct(url = "", sha256 = "", error = "rules_ocx: OCX_INSTALL_BINARY must not be a UNC path, got '{}'".format(path))
    if normalized.startswith("/"):
        url = "file://" + normalized
    elif len(normalized) > 2 and normalized[1] == ":" and normalized[2] == "/":
        url = "file:///" + normalized  # Windows drive path
    else:
        return struct(url = "", sha256 = "", error = "rules_ocx: OCX_INSTALL_BINARY must be an absolute path, got '{}'".format(path))
    return struct(url = url, sha256 = sha256, error = "")

def fetch_ocx_binary(ctx, version, triple = "", dist_manifest = None):
    """Fetches the ocx binary into `ctx`'s directory and returns its path.

    Works with a repository_ctx and a module_ctx: only calls both share
    (`getenv`, `os`, `path`, `read`, `download`, `download_and_extract`) are used.

    With OCX_INSTALL_BINARY and OCX_INSTALL_BINARY_SHA256 set, that file is
    copied through `ctx.download` (a wrong hash fails the fetch; a later edit of
    the source file changes nothing) and its `ocx version` is checked against
    the floor. Otherwise the release `version` is taken from the dist manifest.

    Args:
        ctx: repository_ctx or module_ctx.
        version: exact released ocx version (ignored for a local binary).
        triple: optional exact release target triple; default is host detection.
        dist_manifest: label of the dist.json snapshot; default `//dist:dist.json`.

    Returns:
        The path of the fetched `ocx` (`ocx.exe` on Windows).
    """
    host = host_info(ctx.os.name, ctx.os.arch)
    bin_name = "ocx" + host.exe_ext

    request = local_binary_request(ctx.getenv("OCX_INSTALL_BINARY") or "", ctx.getenv("OCX_INSTALL_BINARY_SHA256") or "")
    if request.error:
        fail(request.error)
    if request.url:
        local = "local/" + bin_name
        ctx.download(request.url, local, sha256 = request.sha256, executable = True)
        # The same scratch environment as every other ocx run: no ambient OCX_* and a fresh OCX_HOME.
        env = manifest_env(str(ctx.path("local_version_home")), "", True, False, False, "")
        reported = ctx.execute([ctx.path(local), "version"], environment = env, timeout = 30)
        err = local_binary_version_error(reported.return_code, reported.stdout)
        if err:
            fail(err)
        return ctx.path(local)

    err = min_version_error(version)
    if err:
        if version == DEFAULT_OCX_VERSION:
            err += NO_SUPPORTED_RELEASE_NOTE
        fail(err)

    triples = [triple] if triple else host.triples

    dist_url = ctx.getenv("OCX_INSTALL_DIST_URL")
    if dist_url:
        ctx.download(dist_url, "dist.json", sha256 = manifest_sha256(dist_url))
        manifest = json.decode(ctx.read("dist.json"))
    else:
        manifest = json.decode(ctx.read(dist_manifest or Label("//dist:dist.json")))

    if not manifest.get("releases"):
        fail("rules_ocx: ocx {} is not available.".format(version) + NO_SUPPORTED_RELEASE_NOTE)
    row = select_release(manifest, version, triples)
    url = artifact_url(row, ctx.getenv("OCX_INSTALL_MIRROR_URL"))
    ctx.download_and_extract(url, output = "extracted", sha256 = row["sha256"], type = archive_type(row["filename"]))

    nested = ctx.path("extracted/ocx-{}/{}".format(row["target"], bin_name))
    flat = ctx.path("extracted/" + bin_name)
    source = nested if nested.exists else flat
    if not source.exists:
        fail("rules_ocx: '{}' not found in the extracted ocx archive from {}".format(bin_name, url))
    return source

def _ocx_download_impl(ctx):
    source = fetch_ocx_binary(ctx, ctx.attr.version, ctx.attr.triple, ctx.attr.dist_manifest)
    host = host_info(ctx.os.name, ctx.os.arch)

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

Local build: set `OCX_INSTALL_BINARY` (absolute path of an `ocx`
binary) and `OCX_INSTALL_BINARY_SHA256` (its digest, 64 lowercase hex) to use
it instead of the release. Both are required together; the file is copied
through the downloader, so a wrong digest fails the fetch and a later edit of
the source file has no effect. `version` and the dist manifest are then
ignored, and the binary's `ocx version` must still meet the floor below
(a pre-release of the floor version passes). Pass them with `--repo_env` and add `--lockfile_mode=off` (the pair
is not part of the lockfile).

`version` must be {} or newer: that is the first ocx release with `ocx vendor`
and manifest schema version 1, the manifest this ruleset reads.""".format(MIN_OCX_VERSION),
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
            doc = "Exact ocx version to download, e.g. '{0}'. Must be {0} or newer.".format(MIN_OCX_VERSION),
        ),
    },
)
