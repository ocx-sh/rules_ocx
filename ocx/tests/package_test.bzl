# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/package.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:package.bzl", "pinned_ref", "resolve_platform_queries")

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

def _platform_queries_test_impl(ctx):
    env = unittest.begin(ctx)

    # A fallback entry becomes that target's preference list; other targets
    # resolve to '[target]' (single platform, unchanged).
    asserts.equals(
        env,
        {
            "linux/arm64": ["linux/arm64", "linux/amd64"],
            "linux/amd64": ["linux/amd64"],
        },
        resolve_platform_queries(
            "jq",
            ["linux/arm64", "linux/amd64"],
            {"linux/arm64": ["linux/arm64", "linux/amd64"]},
        ),
    )

    # No fallbacks -> every target is its own single-element query.
    asserts.equals(
        env,
        {"linux/amd64": ["linux/amd64"], "windows/amd64": ["windows/amd64"]},
        resolve_platform_queries("jq", ["linux/amd64", "windows/amd64"], {}),
    )
    return unittest.end(env)

platform_queries_test = unittest.make(_platform_queries_test_impl)

def package_test_suite(name):
    """Instantiates the package.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        pinned_ref_test,
        platform_queries_test,
    )
