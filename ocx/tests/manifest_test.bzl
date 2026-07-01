# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/manifest.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:manifest.bzl", "artifact_url", "select_release")

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

select_release_test = unittest.make(_select_release_test_impl)
artifact_url_test = unittest.make(_artifact_url_test_impl)

def manifest_test_suite(name):
    """Instantiates the manifest.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        select_release_test,
        artifact_url_test,
    )
