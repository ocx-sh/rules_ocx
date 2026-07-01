# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for the launcher/env renderers in ocx/private/repo_utils.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:repo_utils.bzl", "render_env_bzl", "render_launcher", "render_lazy_launcher")

_ENTRIES = [
    {"key": "PATH", "value": "/store/aa/content/bin", "type": "path"},
    {"key": "PATH", "value": "/store/bb/content", "type": "path"},
    {"key": "JAVA_HOME", "value": "/store/cc/content", "type": "constant"},
]

def _sh_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    script = render_launcher(_ENTRIES, "/store/aa/content/bin/tool", "/home/u/.ocx", "/repo/ocx", False)
    asserts.true(env, script.startswith("#!/usr/bin/env bash"))
    asserts.true(env, 'export OCX_HOME="/home/u/.ocx"' in script)
    asserts.true(env, 'export OCX_BINARY_PIN="/repo/ocx"' in script)

    # Both path values joined in declaration order, existing value appended.
    asserts.true(env, 'export PATH="/store/aa/content/bin:/store/bb/content${PATH:+:${PATH}}"' in script)

    # Constants replace.
    asserts.true(env, 'export JAVA_HOME="/store/cc/content"' in script)
    asserts.true(env, script.endswith('exec "/store/aa/content/bin/tool" "$@"\n'))
    return unittest.end(env)

def _bat_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    script = render_launcher(_ENTRIES, "C:\\store\\tool.exe", "C:\\Users\\u\\.ocx", "C:\\repo\\ocx.exe", True)
    asserts.true(env, script.startswith("@echo off"))
    asserts.true(env, 'set "PATH=/store/aa/content/bin;/store/bb/content;%PATH%"' in script)
    asserts.true(env, 'set "JAVA_HOME=/store/cc/content"' in script)
    asserts.true(env, '"C:\\store\\tool.exe" %*' in script)
    return unittest.end(env)

def _sh_lazy_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    script = render_lazy_launcher(
        ['"$(rlocation repo+ocx_tool/ocx)"', "package", "exec", "'ocx.sh/jq@sha256:abc'", "--", "jq"],
        False,
    )
    asserts.true(env, script.startswith("#!/usr/bin/env bash"))

    # Machine-independent: runfiles resolution, no absolute paths, no baked store.
    asserts.true(env, "runfiles.bash initialization" in script)
    asserts.false(env, "OCX_HOME" in script)
    asserts.true(env, 'export OCX_PROJECT=""' in script)
    asserts.true(env, script.endswith(
        "exec \"$(rlocation repo+ocx_tool/ocx)\" package exec 'ocx.sh/jq@sha256:abc' -- jq \"$@\"\n",
    ))
    return unittest.end(env)

def _bat_lazy_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    script = render_lazy_launcher(
        ['"C:\\repo\\ocx.exe"', "--project", '"C:\\repo\\ocx.toml"', "run", "--", "shellcheck"],
        True,
    )
    asserts.true(env, script.startswith("@echo off"))
    asserts.true(env, 'set "OCX_PROJECT="' in script)
    asserts.true(env, '"C:\\repo\\ocx.exe" --project "C:\\repo\\ocx.toml" run -- shellcheck %*' in script)
    return unittest.end(env)

def _env_bzl_test_impl(ctx):
    env = unittest.begin(ctx)
    content = render_env_bzl(_ENTRIES, "/home/u/.ocx")

    # Must be valid Starlark that round-trips the entries through JSON.
    asserts.true(env, "OCX_ENV = _DATA[\"entries\"]" in content)
    asserts.true(env, "OCX_HOME = _DATA[\"home\"]" in content)
    asserts.true(env, "/store/aa/content/bin" in content)
    return unittest.end(env)

sh_launcher_test = unittest.make(_sh_launcher_test_impl)
bat_launcher_test = unittest.make(_bat_launcher_test_impl)
sh_lazy_launcher_test = unittest.make(_sh_lazy_launcher_test_impl)
bat_lazy_launcher_test = unittest.make(_bat_lazy_launcher_test_impl)
env_bzl_test = unittest.make(_env_bzl_test_impl)

def launcher_test_suite(name):
    """Instantiates the launcher-rendering test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        sh_launcher_test,
        bat_launcher_test,
        sh_lazy_launcher_test,
        bat_lazy_launcher_test,
        env_bzl_test,
    )
