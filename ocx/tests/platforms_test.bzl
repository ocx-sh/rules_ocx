# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/platforms.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:platforms.bzl", "host_info", "ocx_platform_constraints", "slug")

def _host_info_test_impl(ctx):
    env = unittest.begin(ctx)

    linux = host_info("linux", "amd64")
    asserts.equals(env, "x86_64-unknown-linux-musl", linux.triple)
    asserts.equals(env, "linux/amd64", linux.ocx_platform)
    asserts.false(env, linux.is_windows)
    asserts.equals(env, "", linux.exe_ext)

    arm = host_info("Linux", "aarch64")
    asserts.equals(env, "aarch64-unknown-linux-musl", arm.triple)
    asserts.equals(env, "linux/arm64", arm.ocx_platform)

    mac = host_info("mac os x", "aarch64")
    asserts.equals(env, "aarch64-apple-darwin", mac.triple)
    asserts.equals(env, "darwin/arm64", mac.ocx_platform)

    win = host_info("Windows 11", "amd64")
    asserts.equals(env, "x86_64-pc-windows-msvc", win.triple)
    asserts.equals(env, "windows/amd64", win.ocx_platform)
    asserts.true(env, win.is_windows)
    asserts.equals(env, ".exe", win.exe_ext)

    return unittest.end(env)

def _mappings_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "linux_arm64", slug("linux/arm64"))
    asserts.equals(env, "linux_arm64_libc_musl", slug("linux/arm64+libc.musl"))
    asserts.equals(env, "linux_amd64", slug("Linux//AMD64__"))  # lower + collapse + strip
    asserts.equals(
        env,
        ["@platforms//os:linux", "@platforms//cpu:aarch64"],
        ocx_platform_constraints("linux/arm64+libc.musl"),
    )
    asserts.equals(
        env,
        ["@platforms//os:osx", "@platforms//cpu:x86_64"],
        ocx_platform_constraints("darwin/amd64"),
    )
    asserts.equals(
        env,
        ["@platforms//os:windows", "@platforms//cpu:x86_64"],
        ocx_platform_constraints("windows/amd64"),
    )
    return unittest.end(env)

host_info_test = unittest.make(_host_info_test_impl)
mappings_test = unittest.make(_mappings_test_impl)

def platforms_test_suite(name):
    """Instantiates the platforms.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        host_info_test,
        mappings_test,
    )
