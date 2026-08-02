# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for the pure helpers in ocx/private/repo_utils.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//ocx/private:repo_utils.bzl",
    "ambient_config_paths",
    "declared_bins",
    "render_env_bzl",
    "render_launcher",
    "render_lazy_launcher",
)

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

    # Eager launchers never re-enter ocx for resolution, so the fetch-time
    # config must not leak into them.
    asserts.false(env, "OCX_CONFIG" in script)
    asserts.false(env, "OCX_PATCH_SNAPSHOT" in script)
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
        exports = {
            "OCX_NO_CONFIG": "1",
            "OCX_CONFIG": "$(rlocation repo+pkg/config.toml)",
        },
    )
    asserts.true(env, script.startswith("#!/usr/bin/env bash"))

    # Machine-independent: runfiles resolution, no absolute paths, no baked store.
    asserts.true(env, "runfiles.bash initialization" in script)
    asserts.false(env, "OCX_HOME" in script)
    asserts.true(env, 'export OCX_PROJECT=""' in script)

    # Staged config travels with the launcher, resolved through runfiles.
    asserts.true(env, 'export OCX_NO_CONFIG="1"' in script)
    asserts.true(env, 'export OCX_CONFIG="$(rlocation repo+pkg/config.toml)"' in script)
    asserts.false(env, 'export OCX_CONFIG="/' in script)
    asserts.true(env, script.index("export OCX_CONFIG=") < script.index("\nexec "))
    asserts.true(env, script.endswith(
        "exec \"$(rlocation repo+ocx_tool/ocx)\" package exec 'ocx.sh/jq@sha256:abc' -- jq \"$@\"\n",
    ))
    return unittest.end(env)

def _bat_lazy_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    script = render_lazy_launcher(
        ['"C:\\repo\\ocx.exe"', "--project", '"C:\\repo\\ocx.toml"', "run", "--", "shellcheck"],
        True,
        exports = {"OCX_CONFIG": "C:\\repo\\config.toml"},
    )
    asserts.true(env, script.startswith("@echo off"))
    asserts.true(env, 'set "OCX_PROJECT="' in script)
    asserts.true(env, 'set "OCX_CONFIG=C:\\repo\\config.toml"' in script)
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

def _closure_package(identifier, binaries, complete = True):
    return {
        "identifier": identifier,
        "closure": {
            "surface": {
                "interface": {
                    "binaries": [{"name": n, "package": identifier} for n in binaries],
                    "binaries_complete": complete,
                },
            },
        },
    }

def _declared_bins_test_impl(ctx):
    env = unittest.begin(ctx)

    surface = declared_bins([
        _closure_package("ocx.sh/a/a:latest@sha256:aa", ["shellcheck"]),
        _closure_package("ocx.sh/b/b:latest@sha256:bb", ["shfmt", "shellcheck"]),
    ])

    # Declaration order, and the first package claiming a name wins (PATH semantics).
    asserts.equals(env, ["shellcheck", "shfmt"], surface.names)
    asserts.equals(env, [], surface.incomplete)

    # An empty complete claim is a real answer: the package exposes nothing.
    asserts.equals(env, [], declared_bins([_closure_package("ocx.sh/c/c:latest", [])]).names)

    # One incomplete package poisons the batch — the union is now a subset of PATH.
    mixed = declared_bins([
        _closure_package("ocx.sh/a/a:latest@sha256:aa", ["shellcheck"]),
        _closure_package("ocx.sh/legacy:latest@sha256:cc", [], complete = False),
    ])
    asserts.equals(env, ["ocx.sh/legacy:latest@sha256:cc"], mixed.incomplete)

    return unittest.end(env)

def _ambient_config_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    posix_env = {"XDG_CONFIG_HOME": "/x/cfg", "HOME": "/home/u", "APPDATA": ""}

    # Linux: /etc tier, XDG user config, then the three OCX_HOME-rooted tiers.
    asserts.equals(env, [
        "/etc/ocx/config.toml",
        "/x/cfg/ocx/config.toml",
        "/home/u/.ocx/config.toml",
        "/home/u/.ocx/state/managed-config/snapshot.json",
        "/home/u/.ocx/state/managed-config/config.toml",
    ], ambient_config_paths(False, False, posix_env, "/home/u/.ocx"))

    # Unset XDG_CONFIG_HOME falls back to ~/.config; so does a relative one.
    for xdg in ["", "cfg"]:
        paths = ambient_config_paths(
            False,
            False,
            {"XDG_CONFIG_HOME": xdg, "HOME": "/home/u"},
            "",
        )
        asserts.equals(env, ["/etc/ocx/config.toml", "/home/u/.config/ocx/config.toml"], paths)

    # macOS ignores XDG entirely.
    asserts.equals(env, [
        "/etc/ocx/config.toml",
        "/home/u/Library/Application Support/ocx/config.toml",
    ], ambient_config_paths(False, True, posix_env, ""))

    # Windows: APPDATA, backslashes, no /etc tier.
    asserts.equals(env, [
        "C:\\Users\\u\\AppData\\Roaming\\ocx\\config.toml",
        "C:\\Users\\u\\.ocx\\config.toml",
        "C:\\Users\\u\\.ocx\\state\\managed-config\\snapshot.json",
        "C:\\Users\\u\\.ocx\\state\\managed-config\\config.toml",
    ], ambient_config_paths(
        True,
        False,
        {"APPDATA": "C:\\Users\\u\\AppData\\Roaming", "HOME": "", "XDG_CONFIG_HOME": ""},
        "C:\\Users\\u\\.ocx",
    ))

    # Nothing to discover: no home (isolated_home) and no env at all.
    asserts.equals(env, ["/etc/ocx/config.toml"], ambient_config_paths(False, False, {}, ""))
    return unittest.end(env)

sh_launcher_test = unittest.make(_sh_launcher_test_impl)
bat_launcher_test = unittest.make(_bat_launcher_test_impl)
sh_lazy_launcher_test = unittest.make(_sh_lazy_launcher_test_impl)
bat_lazy_launcher_test = unittest.make(_bat_lazy_launcher_test_impl)
env_bzl_test = unittest.make(_env_bzl_test_impl)
declared_bins_test = unittest.make(_declared_bins_test_impl)
ambient_config_paths_test = unittest.make(_ambient_config_paths_test_impl)

def launcher_test_suite(name):
    """Instantiates the repo_utils pure-helper test suite.

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
        declared_bins_test,
        ambient_config_paths_test,
    )
