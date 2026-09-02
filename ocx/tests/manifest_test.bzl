# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/manifest.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:manifest.bzl", "archive_type", "artifact_url", "manifest_sha256", "select_release")
load("//ocx/private:versions.bzl", "DEFAULT_OCX_VERSION", "MIN_OCX_VERSION", "min_version_error")

_MANIFEST = {
    "schema": 1,
    "latest": {"version": "0.3.10", "channel": "stable"},
    "releases": [
        {
            "version": "0.3.10",
            "channel": "stable",
            "tag": "v0.3.10",
            "target": "x86_64-unknown-linux-musl",
            "filename": "ocx-x86_64-unknown-linux-musl.tar.xz",
            "sha256": "a" * 64,
            "url": "https://github.com/ocx-sh/ocx/releases/download/v0.3.10/ocx-x86_64-unknown-linux-musl.tar.xz",
        },
        {
            "version": "0.3.9",
            "channel": "stable",
            "tag": "v0.3.9",
            "target": "x86_64-unknown-linux-musl",
            "filename": "ocx-x86_64-unknown-linux-musl.tar.xz",
            "sha256": "b" * 64,
            "url": "https://github.com/ocx-sh/ocx/releases/download/v0.3.9/ocx-x86_64-unknown-linux-musl.tar.xz",
        },
    ],
}

def _select_release_test_impl(ctx):
    env = unittest.begin(ctx)
    row = select_release(_MANIFEST, "0.3.9", "x86_64-unknown-linux-musl")
    asserts.equals(env, "b" * 64, row["sha256"])
    asserts.equals(env, "v0.3.9", row["tag"])
    return unittest.end(env)

def _artifact_url_test_impl(ctx):
    env = unittest.begin(ctx)
    row = select_release(_MANIFEST, "0.3.10", "x86_64-unknown-linux-musl")

    # No mirror: manifest URL verbatim.
    asserts.equals(env, row["url"], artifact_url(row, None))
    asserts.equals(env, row["url"], artifact_url(row, ""))

    # Mirror: <mirror>/<tag>/<filename>, trailing slash tolerated.
    expected = "https://mirror.corp/ocx/v0.3.10/ocx-x86_64-unknown-linux-musl.tar.xz"
    asserts.equals(env, expected, artifact_url(row, "https://mirror.corp/ocx"))
    asserts.equals(env, expected, artifact_url(row, "https://mirror.corp/ocx/"))
    return unittest.end(env)

def _archive_type_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "zip", archive_type("ocx-x86_64-pc-windows-msvc.zip"))
    asserts.equals(env, "tar.gz", archive_type("ocx-x86_64-unknown-linux-musl.tar.gz"))
    asserts.equals(env, "tar.xz", archive_type("ocx-x86_64-unknown-linux-musl.tar.xz"))
    return unittest.end(env)

# The two message fragments, held in constants (.claude/rules/starlark.md).
_FLOOR_FRAGMENT = "requires ocx 0.6.0 or newer"
_MALFORMED_FRAGMENT = "is not a dotted-numeric version"

# 64 lowercase hex characters.
_HEX = "0123456789abcdef" * 4

_DIST = "https://mirror.example/dist/"

# Covers: C-012, S-008 — ocx.download(version) below the 0.6.0 floor is refused
# before any download; at or above it the floor is silent.
def _min_version_error_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "0.6.0", MIN_OCX_VERSION)

    below = min_version_error("0.5.8")
    asserts.true(
        env,
        _FLOOR_FRAGMENT in below,
        "0.5.8 must be refused with the floor message, got: %r" % below,
    )

    asserts.equals(env, "", min_version_error("0.6.0"))
    asserts.equals(env, "", min_version_error("0.7.1"))

    # Numeric, not lexical: "0.10.0" < "0.6.0" as strings.
    asserts.equals(env, "", min_version_error("0.10.0"))

    # Malformed versions are refused, not waved through as a skylib dev build
    # ("v0.6.0", "") or crashed on ("0.6.") — and with their own message, since
    # the floor would misdiagnose a spelling problem as an out-of-date pin.
    for bad in ["v0.6.0", "", " 0.5.8", "0.6."]:
        got = min_version_error(bad)
        asserts.true(
            env,
            _MALFORMED_FRAGMENT in got,
            "%r must be refused as malformed, got: %r" % (bad, got),
        )

    # Well-formed but below (0, 6, 0): the floor message, not the malformed one.
    below_short = min_version_error("0.6")
    asserts.true(
        env,
        _FLOOR_FRAGMENT in below_short,
        "0.6 must be refused with the floor message, got: %r" % below_short,
    )

    # Invariant: the shipped pin always satisfies the floor.
    asserts.equals(env, "", min_version_error(DEFAULT_OCX_VERSION))
    return unittest.end(env)

# Covers: C-014, S-009 — a self-verifying dist manifest name
# <64 lowercase hex>.json yields its digest; every other name yields "".
def _manifest_sha256_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, _HEX, manifest_sha256(_DIST + _HEX + ".json"))

    # Query and fragment are cut before the segment is read.
    asserts.equals(env, _HEX, manifest_sha256(_DIST + _HEX + ".json?x=1"))
    asserts.equals(env, _HEX, manifest_sha256(_DIST + _HEX + ".json#frag"))

    # Wrong digest length (68- and 70-character segments).
    asserts.equals(env, "", manifest_sha256(_DIST + _HEX[:63] + ".json"))
    asserts.equals(env, "", manifest_sha256(_DIST + _HEX + "0.json"))

    # Uppercase hex is not accepted.
    asserts.equals(env, "", manifest_sha256(_DIST + _HEX.upper() + ".json"))

    # Right length, wrong extension; and the plain non-.json case.
    asserts.equals(env, "", manifest_sha256(_DIST + _HEX + "0.txt"))
    asserts.equals(env, "", manifest_sha256(_DIST + _HEX + ".txt"))

    # A 69-character .json segment whose leading 64 chars are not all hex.
    asserts.equals(env, "", manifest_sha256(_DIST + _HEX[:63] + "g.json"))

    # Ordinary manifest names stay unverified, with or without a path.
    asserts.equals(env, "", manifest_sha256("https://h/dist.json"))
    asserts.equals(env, "", manifest_sha256("dist.json"))
    return unittest.end(env)

select_release_test = unittest.make(_select_release_test_impl)
artifact_url_test = unittest.make(_artifact_url_test_impl)
archive_type_test = unittest.make(_archive_type_test_impl)
min_version_error_test = unittest.make(_min_version_error_test_impl)
manifest_sha256_test = unittest.make(_manifest_sha256_test_impl)

def manifest_test_suite(name):
    """Instantiates the manifest.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        select_release_test,
        artifact_url_test,
        archive_type_test,
        min_version_error_test,
        manifest_sha256_test,
    )
