# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Pure helpers over the setup.ocx.sh dist.json release manifest.

Manifest schema (flat rows, schema 1):
    {"schema": 1, "latest": {...}, "releases": [
        {"version", "channel", "tag", "target", "filename", "sha256", "url"}, ...]}
"""

visibility(["//ocx", "//ocx/tests"])

_HEX_DIGITS = "0123456789abcdef"

def select_release(manifest, version, target):
    """Finds the manifest row for an exact version and target triple.

    Args:
        manifest: decoded dist.json object.
        version: exact ocx version, e.g. "0.3.10".
        target: cargo-dist target triple, e.g. "x86_64-unknown-linux-musl".

    Returns:
        The matching release row (dict).
    """
    if manifest.get("schema") != 1:
        fail("rules_ocx: unsupported dist.json schema '{}'".format(manifest.get("schema")))
    for row in manifest["releases"]:
        if row["version"] == version and row["target"] == target:
            return row
    fail(("rules_ocx: ocx {} for {} not found in the dist manifest — " +
          "run 'task dist:update' or point OCX_INSTALL_DIST_URL at a manifest " +
          "that contains it").format(version, target))

def archive_type(filename):
    """Maps a release filename to the explicit download_and_extract type.

    ocx releases ship .zip (windows), .tar.gz (>= 0.4.3), and .tar.xz (older).

    Args:
        filename: release row filename, e.g. "ocx-x86_64-unknown-linux-musl.tar.gz".

    Returns:
        Archive type string for repository_ctx.download_and_extract().
    """
    if filename.endswith(".zip"):
        return "zip"
    if filename.endswith(".tar.gz"):
        return "tar.gz"
    return "tar.xz"

def manifest_sha256(url):
    """Extracts a self-verifying sha256 from a dist.json manifest URL.

    A manifest whose name carries its own digest can be enforced on the
    fetch itself instead of trusting the transport; the official www-setup
    installers write that name as `dist/<sha256>.json` (mirrors
    `dist_pin_digest`). Only the URL's last path segment is read, after a
    `#` fragment and a `?` query are cut: it must be 64 lowercase hex
    characters followed by ".json". Any other name is not a parse error —
    it means the manifest isn't self-verifying, so the caller falls back to
    an unverified fetch.

    Args:
        url: value of OCX_INSTALL_DIST_URL.

    Returns:
        The 64-character lowercase-hex digest, or "" when the URL's last
        segment is not a <sha256>.json manifest name.
    """
    segment = url.split("#")[0].split("?")[0].split("/")[-1]
    if len(segment) != 69 or not segment.endswith(".json"):
        return ""
    digest = segment[:64]
    for char in digest.elems():
        if char not in _HEX_DIGITS:
            return ""
    return digest

def artifact_url(row, mirror_url):
    """Resolves the download URL for a release row, honoring a mirror.

    Mirrors relocate artifacts but never alter them: the caller must keep
    enforcing row["sha256"]. Rewrite matches the setup.ocx.sh installer:
    `<mirror>/<tag>/<filename>`.

    Args:
        row: a release row from select_release().
        mirror_url: value of OCX_INSTALL_MIRROR_URL, or None/"".

    Returns:
        URL string.
    """
    if mirror_url:
        return "{}/{}/{}".format(mirror_url.rstrip("/"), row["tag"], row["filename"])
    return row["url"]
