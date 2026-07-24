# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/package.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:package.bzl", "pinned_ref", "resolve_platforms")

_PINS = {
    "darwin/arm64": "sha256:" + "b" * 64,
    "linux/amd64": "sha256:" + "a" * 64,
}

def _pinned_ref_test_impl(ctx):
    env = unittest.begin(ctx)

    # Matching pin replaces any digest on the reference.
    asserts.equals(
        env,
        "ocx.sh/jq:latest@sha256:" + "a" * 64,
        pinned_ref("ocx.sh/jq:latest", _PINS, "linux/amd64"),
    )
    asserts.equals(
        env,
        "ocx.sh/jq:latest@sha256:" + "b" * 64,
        pinned_ref("ocx.sh/jq:latest@sha256:" + "c" * 64, _PINS, "darwin/arm64"),
    )

    # Unpinned platform falls back to the reference verbatim.
    asserts.equals(
        env,
        "ocx.sh/jq:latest",
        pinned_ref("ocx.sh/jq:latest", _PINS, "windows/amd64"),
    )
    asserts.equals(
        env,
        "ocx.sh/jq:latest",
        pinned_ref("ocx.sh/jq:latest", {}, "linux/amd64"),
    )
    return unittest.end(env)

pinned_ref_test = unittest.make(_pinned_ref_test_impl)

def _resolve_platforms_test_impl(ctx):
    env = unittest.begin(ctx)

    # alias remap: real diverges from declared; slugs key the map.
    asserts.equals(
        env,
        {
            "linux_amd64": struct(declared = "linux/amd64", real = "linux/amd64"),
            "linux_arm64": struct(declared = "linux/arm64", real = "linux/arm64+libc.musl"),
        },
        resolve_platforms(
            "jq",
            ["linux/amd64", "linux/arm64"],
            {"linux/arm64": "linux/arm64+libc.musl"},
        ).platforms,
    )

    # no aliases: real == declared.
    asserts.equals(
        env,
        {
            "linux_amd64": struct(declared = "linux/amd64", real = "linux/amd64"),
            "windows_amd64": struct(declared = "windows/amd64", real = "windows/amd64"),
        },
        resolve_platforms("jq", ["linux/amd64", "windows/amd64"], {}).platforms,
    )

    # alias key not in platforms -> error.
    asserts.false(
        env,
        resolve_platforms("jq", ["linux/amd64"], {"linux/arm64": "linux/amd64"}).error == "",
    )

    # two platforms colliding on one slug -> error.
    asserts.false(
        env,
        resolve_platforms("jq", ["linux/arm64", "linux+arm64"], {}).error == "",
    )
    return unittest.end(env)

resolve_platforms_test = unittest.make(_resolve_platforms_test_impl)

def package_test_suite(name):
    """Instantiates the package.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        pinned_ref_test,
        resolve_platforms_test,
    )
