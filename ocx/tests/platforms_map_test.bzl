# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for the platform-string -> constraint mapping of ocx/private/platforms.bzl (C-RO-09)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:platforms.bzl", "platform_constraints")

_LINUX = "@platforms//os:linux"
_X86 = "@platforms//cpu:x86_64"
_ARM = "@platforms//cpu:aarch64"
_MUSL = "@rules_ocx//ocx/constraints:musl"

def _ok(env, platform, expected):
    got = platform_constraints(platform)
    asserts.equals(env, "", got.error, "error for " + platform)
    asserts.equals(env, expected, got.constraints, "constraints for " + platform)

def _os_arch_test_impl(ctx):
    env = unittest.begin(ctx)
    _ok(env, "linux/amd64", [_LINUX, _X86])
    _ok(env, "linux/arm64", [_LINUX, _ARM])
    _ok(env, "darwin/arm64", ["@platforms//os:macos", _ARM])
    _ok(env, "darwin/amd64", ["@platforms//os:macos", _X86])
    _ok(env, "windows/amd64", ["@platforms//os:windows", _X86])
    _ok(env, "windows/arm64", ["@platforms//os:windows", _ARM])
    _ok(env, "wasip1/wasm", ["@platforms//os:wasi", "@platforms//cpu:wasm32"])
    return unittest.end(env)

def _libc_test_impl(ctx):
    env = unittest.begin(ctx)
    _ok(env, "linux/amd64+libc.musl", [_LINUX, _X86, _MUSL])
    _ok(env, "linux/arm64+libc.musl", [_LINUX, _ARM, _MUSL])

    # glibc, no libc feature and any other feature add nothing.
    _ok(env, "linux/amd64+libc.glibc", [_LINUX, _X86])
    _ok(env, "linux/amd64", [_LINUX, _X86])
    _ok(env, "linux/amd64+gpu.cuda", [_LINUX, _X86])
    _ok(env, "linux/amd64+libc.glibc,gpu.cuda", [_LINUX, _X86])
    _ok(env, "linux/amd64+gpu.cuda,libc.musl", [_LINUX, _X86, _MUSL])
    return unittest.end(env)

def _variant_test_impl(ctx):
    env = unittest.begin(ctx)
    _ok(env, "linux/arm64/v8", [_LINUX, _ARM])
    _ok(env, "linux/arm64/v8+libc.musl", [_LINUX, _ARM, _MUSL])
    return unittest.end(env)

def _unmappable_test_impl(ctx):
    env = unittest.begin(ctx)
    for platform in ["freebsd/amd64", "linux/riscv64", "linux", "", "/amd64", "linux/"]:
        got = platform_constraints(platform)
        asserts.equals(env, [], got.constraints, "no constraints for '{}'".format(platform))
        asserts.true(env, got.error != "", "an error for '{}'".format(platform))
        asserts.true(env, "'{}'".format(platform) in got.error, "the error names '{}'".format(platform))
    return unittest.end(env)

os_arch_test = unittest.make(_os_arch_test_impl)
libc_test = unittest.make(_libc_test_impl)
variant_test = unittest.make(_variant_test_impl)
unmappable_test = unittest.make(_unmappable_test_impl)

def platforms_map_test_suite(name):
    """Instantiates the platform constraint mapping test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(name, os_arch_test, libc_test, variant_test, unmappable_test)
