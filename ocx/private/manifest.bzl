# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Pure helpers over the setup.ocx.sh dist.json release manifest.

Manifest schema (flat rows, schema 1):
    {"schema": 1, "latest": {...}, "releases": [
        {"version", "channel", "tag", "target", "filename", "sha256", "url"}, ...]}
"""

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
