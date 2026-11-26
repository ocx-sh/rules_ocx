# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/manifest.bzl."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//ocx/private:manifest.bzl", "archive_type", "artifact_url", "manifest_sha256", "select_release")
load("//ocx/private:versions.bzl", "DEFAULT_OCX_VERSION", "MIN_OCX_VERSION", "NO_SUPPORTED_RELEASE_NOTE", "local_binary_version_error", "min_version_error")

_MANIFEST = {
    "schema": 1,
    "latest": {"version": "0.7.1", "channel": "stable"},
    "releases": [
        {
            "version": "0.7.1",
            "channel": "stable",
            "tag": "v0.7.1",
            "target": "x86_64-unknown-linux-musl",
            "filename": "ocx-x86_64-unknown-linux-musl.tar.gz",
            "sha256": "a" * 64,
            "url": "https://github.com/ocx-sh/ocx/releases/download/v0.7.1/ocx-x86_64-unknown-linux-musl.tar.gz",
        },
        {
            "version": "0.7.0",
            "channel": "stable",
            "tag": "v0.7.0",
            "target": "x86_64-unknown-linux-musl",
            "filename": "ocx-x86_64-unknown-linux-musl.tar.gz",
            "sha256": "b" * 64,
            "url": "https://github.com/ocx-sh/ocx/releases/download/v0.7.0/ocx-x86_64-unknown-linux-musl.tar.gz",
        },
    ],
}

def _select_release_test_impl(ctx):
    env = unittest.begin(ctx)
    row = select_release(_MANIFEST, "0.7.0", ["x86_64-unknown-linux-musl"])
    asserts.equals(env, "b" * 64, row["sha256"])
    asserts.equals(env, "v0.7.0", row["tag"])
    return unittest.end(env)

_WIN_GNULLVM = "x86_64-pc-windows-gnullvm"
_WIN_MSVC = "x86_64-pc-windows-msvc"
_WIN_TARGETS = [_WIN_GNULLVM, _WIN_MSVC]

def _win_manifest(*targets):
    return {
        "schema": 1,
        "releases": [
            {"version": "1.0.0", "target": t, "sha256": "c" * 64}
            for t in targets
        ],
    }

# Windows host candidates are [gnullvm, msvc]: first one with a row wins.
def _select_release_windows_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, _WIN_GNULLVM, select_release(_win_manifest(_WIN_GNULLVM), "1.0.0", _WIN_TARGETS)["target"])
    asserts.equals(env, _WIN_MSVC, select_release(_win_manifest(_WIN_MSVC), "1.0.0", _WIN_TARGETS)["target"])
    asserts.equals(env, _WIN_GNULLVM, select_release(_win_manifest(_WIN_MSVC, _WIN_GNULLVM), "1.0.0", _WIN_TARGETS)["target"])
    return unittest.end(env)

# Held in a constant: the traceback echoes the call site's source line.
_NO_ROW_FRAGMENT = "not found in the dist manifest"

def _select_release_none_subject_impl(_ctx):
    select_release(_win_manifest("aarch64-apple-darwin"), "1.0.0", _WIN_TARGETS)
    return []

_select_release_none_subject = rule(implementation = _select_release_none_subject_impl)

def _select_release_none_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, _NO_ROW_FRAGMENT)
    return analysistest.end(env)

select_release_none_test = analysistest.make(
    _select_release_none_test_impl,
    expect_failure = True,
)

def _artifact_url_test_impl(ctx):
    env = unittest.begin(ctx)
    row = select_release(_MANIFEST, "0.7.1", ["x86_64-unknown-linux-musl"])

    # No mirror: manifest URL verbatim.
    asserts.equals(env, row["url"], artifact_url(row, None))
    asserts.equals(env, row["url"], artifact_url(row, ""))

    # Mirror: <mirror>/<tag>/<filename>, trailing slash tolerated.
    expected = "https://mirror.corp/ocx/v0.7.1/ocx-x86_64-unknown-linux-musl.tar.gz"
    asserts.equals(env, expected, artifact_url(row, "https://mirror.corp/ocx"))
    asserts.equals(env, expected, artifact_url(row, "https://mirror.corp/ocx/"))
    return unittest.end(env)

def _archive_type_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "zip", archive_type("ocx-x86_64-pc-windows-msvc.zip"))
    asserts.equals(env, "tar.gz", archive_type("ocx-x86_64-unknown-linux-musl.tar.gz"))
    return unittest.end(env)

# The message fragment, held in a constant (.claude/rules/starlark.md).
_MALFORMED_FRAGMENT = "is not a dotted-numeric version"

# 64 lowercase hex characters.
_HEX = "0123456789abcdef" * 4

_DIST = "https://mirror.example/dist/"

# The comparison, against a floor of its own so that raising MIN_OCX_VERSION
# changes no case: below, equal, a pre-release of equal, above and malformed.
def _min_version_error_test_impl(ctx):
    env = unittest.begin(ctx)
    floor = "1.2.3"
    fragment = "requires ocx 1.2.3 or newer"

    for below in ["1.2.2", "1.1.9", "0.9.9", "1.2", "1.2.2-rc1+5"]:
        got = min_version_error(below, floor)
        asserts.true(env, fragment in got, "%r must be refused with the floor message, got: %r" % (below, got))

    asserts.equals(env, "", min_version_error("1.2.3", floor))
    asserts.equals(env, "", min_version_error("1.2.3-pr784+20261126073008", floor))
    asserts.equals(env, "", min_version_error("1.2.4", floor))
    asserts.equals(env, "", min_version_error("1.3.0", floor))

    # Numeric, not lexical: "1.10.0" < "1.2.3" as strings.
    asserts.equals(env, "", min_version_error("1.10.0", floor))

    # Malformed versions get their own message, since the floor would
    # misdiagnose a spelling problem as an out-of-date pin.
    for bad in ["v1.2.3", "", " 1.2.3", "1.2.", "-rc1", "x.y.z"]:
        got = min_version_error(bad, floor)
        asserts.true(env, _MALFORMED_FRAGMENT in got, "%r must be refused as malformed, got: %r" % (bad, got))

    # Both messages name the floor they were given.
    asserts.true(env, "1.2.3" in min_version_error("0.1.0", floor))
    asserts.true(env, MIN_OCX_VERSION in min_version_error("0.0.1"))
    asserts.true(env, "OCX_INSTALL_BINARY" in NO_SUPPORTED_RELEASE_NOTE)
    return unittest.end(env)

# A locally supplied binary is checked on what `ocx version` printed.
def _local_binary_version_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", local_binary_version_error(0, MIN_OCX_VERSION + "-pr784+20261126073008\n"))
    asserts.equals(env, "", local_binary_version_error(0, MIN_OCX_VERSION + "\n"))
    asserts.equals(env, "", local_binary_version_error(0, "ocx 9.9.9-fake-one\n"))
    asserts.equals(env, "", local_binary_version_error(0, "ocx " + MIN_OCX_VERSION + "\n"))

    # Below the floor and unreadable are different messages, both naming the variable.
    below = local_binary_version_error(0, "0.0.1\n")
    asserts.true(env, "OCX_INSTALL_BINARY is ocx 0.0.1" in below, below)
    for code, out in [(2, ""), (0, ""), (0, "ocx\n"), (0, "v0.7.0\n"), (0, "garbage text")]:
        got = local_binary_version_error(code, out)
        asserts.true(env, "OCX_INSTALL_BINARY did not report a version" in got, got)
    asserts.true(env, "exited 2" in local_binary_version_error(2, ""))
    asserts.false(env, _MALFORMED_FRAGMENT in below)
    return unittest.end(env)

# The shipped default satisfies the floor, except in the one known state: the
# default is still the last release without `ocx vendor` (none carries it yet).
# Remove _KNOWN_PRE_VENDOR_DEFAULT when DEFAULT_OCX_VERSION moves to a release
# that has `ocx vendor`.
_KNOWN_PRE_VENDOR_DEFAULT = "0.6.6"

def _default_satisfies_floor_test_impl(ctx):
    env = unittest.begin(ctx)
    if DEFAULT_OCX_VERSION != _KNOWN_PRE_VENDOR_DEFAULT:
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
select_release_windows_test = unittest.make(_select_release_windows_test_impl)
artifact_url_test = unittest.make(_artifact_url_test_impl)
archive_type_test = unittest.make(_archive_type_test_impl)
min_version_error_test = unittest.make(_min_version_error_test_impl)
local_binary_version_test = unittest.make(_local_binary_version_test_impl)
default_satisfies_floor_test = unittest.make(_default_satisfies_floor_test_impl)
manifest_sha256_test = unittest.make(_manifest_sha256_test_impl)

def manifest_test_suite(name):
    """Instantiates the manifest.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    subject = name + "_none_subject"
    _select_release_none_subject(name = subject, tags = ["manual"])
    unittest.suite(
        name,
        select_release_test,
        select_release_windows_test,
        partial.make(select_release_none_test, target_under_test = ":" + subject),
        artifact_url_test,
        archive_type_test,
        min_version_error_test,
        local_binary_version_test,
        default_satisfies_floor_test,
        manifest_sha256_test,
    )
