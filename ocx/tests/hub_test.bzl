# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/hub.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:hub.bzl", "hub_build_content", "hub_content_error", "hub_platform_error", "hub_tool_bzl")

_SETS = {
    "linux/amd64+libc.glibc": "@set_glibc//:toolchain_impl",
    "linux/amd64+libc.musl": "@set_musl//:toolchain_impl",
}

def _build_content_test_impl(ctx):
    env = unittest.begin(ctx)
    content = hub_build_content(_SETS, ["cmake", "ninja"])
    asserts.equals(env, 1, content.count("toolchain_type("), "one toolchain_type")
    asserts.true(env, content.index("@set_musl//") < content.index("@set_glibc//"), "musl registered before glibc")
    asserts.equals(env, 2, content.count("ocx_tool("), "one ocx_tool per name")
    asserts.equals(env, 2, content.count("@set_glibc//") + content.count("@set_musl//"), "set repos named only inside toolchain()")
    return unittest.end(env)

def _build_content_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    content = hub_build_content(_SETS, ["cmake", "ninja"])
    asserts.true(env, 'load(":tool.bzl", "ocx_tool")' in content, "ocx_tool comes from the hub's own tool.bzl")
    asserts.true(env, 'toolchain_type = ":toolchain_type"' in content)
    asserts.true(env, 'toolchain = "@set_musl//:toolchain_impl"' in content)
    asserts.true(env, '"@rules_ocx//ocx/constraints:musl"' in content, "musl exec constraint")
    asserts.equals(env, 1, content.count("constraints:musl"), "glibc carries no libc constraint")
    asserts.true(env, content.index("ocx_toolchain_000_") < content.index("ocx_toolchain_001_"), "registration order is name order")
    asserts.true(env, 'ocx_tool(\n    name = "cmake",\n    tool = "cmake",' in content)
    return unittest.end(env)

def _tool_bzl_test_impl(ctx):
    env = unittest.begin(ctx)
    text = hub_tool_bzl()
    asserts.true(env, 'load("@rules_ocx//ocx:defs.bzl", "make_ocx_tool_rule")' in text)
    asserts.true(env, 'ocx_tool = make_ocx_tool_rule(Label("//:toolchain_type"))' in text, "the type resolves in the hub")
    return unittest.end(env)

def _content_error_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", hub_content_error(_SETS, ["cmake", "ninja"]), "control")
    for name in ["toolchain_type", "ocx_toolchain_000_x", "tool.bzl", "BUILD.bazel", "BUILD"]:
        err = hub_content_error(_SETS, ["cmake", name])
        asserts.true(env, "'{}'".format(name) in err, "a tool named '{}' collides".format(name))
    err = hub_content_error({"freebsd/amd64": "@s//:t"}, ["cmake"])
    asserts.true(env, "freebsd/amd64" in err, "an unmappable platform is named")
    return unittest.end(env)

def _platform_error_test_impl(ctx):
    env = unittest.begin(ctx)
    available = ["linux/amd64+libc.glibc", "windows/amd64"]
    asserts.equals(env, "", hub_platform_error(["linux/amd64+libc.glibc"], available))
    err = hub_platform_error(["darwin/arm64"], available)
    asserts.true(env, "darwin/arm64" in err, "names the platform")
    asserts.true(env, "windows/amd64" in err, "lists what the lock offers")
    asserts.true(env, "linux/arm64" in hub_platform_error(["linux/amd64+libc.glibc", "linux/arm64"], available), "the first fit does not hide a later miss")
    asserts.true(env, hub_platform_error([], available) != "", "an empty list is refused")
    return unittest.end(env)

build_content_test = unittest.make(_build_content_test_impl)
build_content_shape_test = unittest.make(_build_content_shape_test_impl)
tool_bzl_test = unittest.make(_tool_bzl_test_impl)
content_error_test = unittest.make(_content_error_test_impl)
platform_error_test = unittest.make(_platform_error_test_impl)

def _update_alias_test_impl(ctx):
    env = unittest.begin(ctx)
    content = hub_build_content(_SETS, ["jq"], name = "jq")
    asserts.true(env, 'name = "update"' in content, "the hub carries an update alias")
    asserts.true(env, '"@ocx_update//:hub_jq"' in content, "aliasing the update repository's target for this hub")
    asserts.true(env, "alias(" in content)
    asserts.false(env, "alias(" in hub_build_content(_SETS, ["jq"]), "a hub without an update target carries no alias")
    asserts.false(env, "ocx_update" in hub_build_content(_SETS, ["jq"]), "and names nothing of the update repository")
    return unittest.end(env)

def _update_reserved_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", hub_content_error(_SETS, ["jq"]), "control")
    err = hub_content_error(_SETS, ["jq", "update"])
    asserts.true(env, "'update'" in err, "a tool named update collides with the alias: " + err)
    return unittest.end(env)

update_alias_test = unittest.make(_update_alias_test_impl)
update_reserved_test = unittest.make(_update_reserved_test_impl)

def hub_test_suite(name):
    """Instantiates the hub.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(name, build_content_test, build_content_shape_test, tool_bzl_test, content_error_test, platform_error_test, update_alias_test, update_reserved_test)
