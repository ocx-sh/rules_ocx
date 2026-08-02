# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for the pure helpers in ocx/private/repo_utils.bzl."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//ocx/private:repo_utils.bzl",
    "SYSEXIT_HINTS",
    "ambient_config_paths",
    "closure_packages",
    "declared_bins",
    "is_absolute_path",
    "path_dirs",
    "render_env_bzl",
    "render_launcher",
    "render_lazy_launcher",
    "truthy",
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

    # Both selectors neutralized. OCX_GLOBAL is a BooleanString: "0" is falsy,
    # "" is invalid and makes ocx log a warning on every launcher-run tool.
    asserts.true(env, 'export OCX_PROJECT=""' in script)
    asserts.true(env, 'export OCX_GLOBAL="0"' in script)

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
    asserts.true(env, 'set "OCX_GLOBAL=0"' in script)
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

    # The unvalidated PATH-scan fallback is recorded in the generated repo:
    # empty when every target came from declared metadata, else the packages
    # that forced it.
    asserts.true(env, "OCX_SCANNED_PACKAGES = _DATA[\"scanned\"]" in content)
    asserts.false(env, "ocx.sh/legacy:latest" in content)
    asserts.true(env, "ocx.sh/legacy:latest" in render_env_bzl(
        _ENTRIES,
        "/home/u/.ocx",
        ["ocx.sh/legacy:latest@sha256:cc"],
    ))
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

def _closure_packages_test_impl(ctx):
    """H5: a well-formed `inspect --closure` report passes through unchanged."""
    env = unittest.begin(ctx)

    # An incomplete `binaries` claim is well-formed — declared_bins() reports
    # it — so the guard must check that the key is present, not that it is true.
    packages = [
        _closure_package("ocx.sh/a/a:latest@sha256:aa", ["shellcheck"]),
        _closure_package("ocx.sh/b/b:latest@sha256:bb", [], complete = False),
    ]
    stdout = json.encode({"packages": packages, "resolved": 2})
    asserts.equals(env, packages, closure_packages(stdout, "ocx inspect --closure"))

    # Nothing to validate is not a drift: an empty surface is a real answer.
    asserts.equals(env, [], closure_packages(
        json.encode({"packages": []}),
        "ocx inspect --closure",
    ))
    return unittest.end(env)

# H5: reports that must be rejected. `packages` is serialized unconditionally,
# but a per-entry `closure` is absent for every non-closure body — the three
# keys declared_bins() indexes are exactly what drifts.
_MALFORMED_CLOSURE_REPORTS = {
    "no_closure": [{"identifier": "ocx.sh/a/a:latest@sha256:aa"}],
    "no_interface": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {}},
    }],
    "no_binaries": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {"binaries_complete": True}}},
    }],
    "no_binaries_complete": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {"binaries": []}}},
    }],
    # Present but not iterable as declared_bins() iterates it: a key check
    # alone passes this through to a raw traceback.
    "binaries_not_a_list": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {"binaries": "oops", "binaries_complete": True}}},
    }],
    # declared_bins() indexes `identifier` for every incomplete package.
    "no_identifier": [{
        "closure": {"surface": {"interface": {"binaries": [], "binaries_complete": False}}},
    }],
    # EVERY entry is validated, not just the first.
    "second_entry_bad": [
        _closure_package("ocx.sh/a/a:latest@sha256:aa", ["shellcheck"]),
        {"identifier": "ocx.sh/b/b:latest@sha256:bb"},
    ],
}

def _bad_closure_report_impl(ctx):
    closure_packages(ctx.attr.report, "ocx inspect --closure")
    return []

# A fail() cannot be caught from a unittest impl, so the guard is exercised
# through a target whose analysis is expected to fail.
_bad_closure_report = rule(
    implementation = _bad_closure_report_impl,
    attrs = {"report": attr.string()},
)

def _closure_packages_guard_test_impl(ctx):
    """H5: a malformed report fails, naming the pin that has to move."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "DEFAULT_OCX_VERSION")
    return analysistest.end(env)

closure_packages_guard_test = analysistest.make(
    _closure_packages_guard_test_impl,
    expect_failure = True,
)

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

    # Windows without APPDATA: no /etc tier and no user tier — only OCX_HOME's.
    asserts.equals(env, [
        "C:\\Users\\u\\.ocx\\config.toml",
        "C:\\Users\\u\\.ocx\\state\\managed-config\\snapshot.json",
        "C:\\Users\\u\\.ocx\\state\\managed-config\\config.toml",
    ], ambient_config_paths(
        True,
        False,
        {"APPDATA": "", "HOME": "/home/u", "XDG_CONFIG_HOME": "/x/cfg"},
        "C:\\Users\\u\\.ocx",
    ))

    # macOS without HOME: no Application Support tier to derive, and XDG stays
    # ignored even though it is the only thing set.
    asserts.equals(env, [
        "/etc/ocx/config.toml",
        "/home/u/.ocx/config.toml",
        "/home/u/.ocx/state/managed-config/snapshot.json",
        "/home/u/.ocx/state/managed-config/config.toml",
    ], ambient_config_paths(
        False,
        True,
        {"HOME": "", "XDG_CONFIG_HOME": "/x/cfg", "APPDATA": "C:\\Users\\u\\AppData\\Roaming"},
        "/home/u/.ocx",
    ))

    # Nothing to discover: no home (isolated_home) and no env at all.
    asserts.equals(env, ["/etc/ocx/config.toml"], ambient_config_paths(False, False, {}, ""))
    return unittest.end(env)

def _is_absolute_path_test_impl(ctx):
    """B1: only a genuinely absolute path for that host is absolute."""
    env = unittest.begin(ctx)

    for path in ["/home/u/.ocx", "/"]:
        asserts.true(env, is_absolute_path(path, False), path + " is absolute on POSIX")

    # A relative OCX_HOME or HOME is what makes repository_ctx.watch() blow up
    # with a raw traceback; `~` is a shell nicety, not a path.
    for path in [".ocx", "~/.ocx", "~\\.ocx", "ocx", "home/u/.ocx", ""]:
        asserts.false(env, is_absolute_path(path, False), repr(path) + " is relative on POSIX")

    for path in [
        "C:\\Users\\u\\.ocx",
        "C:/Users/u/.ocx",
        "c:\\Users\\u\\.ocx",
        "\\\\server\\share\\ocx",
        # Forward-slash UNC, symmetric with the `C:/` spelling — Win32 accepts
        # either separator and ocx renders whatever the user exported.
        "//server/share/ocx",
    ]:
        asserts.true(env, is_absolute_path(path, True), path + " is absolute on Windows")

    # Drive-relative is not absolute: one leading backslash means "root of the
    # current drive", `C:x` means "cwd of drive C".
    for path in ["\\Windows\\System32", "C:", "C:ocx", ".ocx", "~\\.ocx", "ocx", ""]:
        asserts.false(env, is_absolute_path(path, True), repr(path) + " is relative on Windows")

    # Cross-host: a POSIX root is not a Windows absolute path.
    asserts.false(env, is_absolute_path("/home/u", True), "POSIX root is not absolute on Windows")
    return unittest.end(env)

def _path_dirs_test_impl(ctx):
    """Only PATH names directories that hold executables."""
    env = unittest.begin(ctx)

    asserts.equals(env, ["/store/aa/content/bin", "/store/bb/content"], path_dirs(_ENTRIES))

    # A package contributing other colon-lists uses the same `path` type; those
    # directories hold libraries and man pages, not tools.
    asserts.equals(env, ["/store/aa/content/bin"], path_dirs([
        {"key": "LD_LIBRARY_PATH", "value": "/store/aa/content/lib", "type": "path"},
        {"key": "PATH", "value": "/store/aa/content/bin", "type": "path"},
        {"key": "MANPATH", "value": "/store/aa/content/share/man", "type": "path"},
        {"key": "PKG_CONFIG_PATH", "value": "/store/aa/content/lib/pkgconfig", "type": "path"},
        {"key": "PATH", "value": "/store/aa/content/sbin", "type": "constant"},
    ]))

    # ocx serializes the key verbatim from package metadata — a package
    # spelling it `Path` still names the directory the tools live in.
    asserts.equals(env, ["/store/aa/content/bin"], path_dirs([
        {"key": "Path", "value": "/store/aa/content/bin", "type": "path"},
    ]))
    asserts.equals(env, [], path_dirs([]))
    return unittest.end(env)

def _truthy_test_impl(ctx):
    env = unittest.begin(ctx)
    for value in ["1", "y", "yes", "on", "true", "YES", "On", "TRUE"]:
        asserts.true(env, truthy(value), repr(value) + " is truthy")

    # ocx's falsy strings, plus unset and an unrecognized value — the latter is
    # ocx's own error to raise, not this predicate's.
    for value in ["0", "n", "no", "off", "false", "", "maybe"]:
        asserts.false(env, truthy(value), repr(value) + " is not truthy")
    asserts.false(env, truthy(None), "unset is not truthy")
    return unittest.end(env)

# W17: every sysexit AGENTS.md documents as reachable from a repository rule.
_DOCUMENTED_SYSEXITS = [64, 65, 69, 74, 75, 77, 78, 79, 80, 81]

def _sysexit_hints_test_impl(ctx):
    """W17: the hint table covers the documented sysexits, and nothing else."""
    env = unittest.begin(ctx)

    # Both directions at once: nothing documented is missing, nothing
    # undocumented has crept in.
    asserts.equals(env, _DOCUMENTED_SYSEXITS, sorted(SYSEXIT_HINTS.keys()))
    for code in _DOCUMENTED_SYSEXITS:
        asserts.true(env, SYSEXIT_HINTS[code], "sysexit {} has an empty hint".format(code))

    # 82 (dirty rc) is deliberately absent: only `ocx config setup` / `ocx self
    # setup` raise it, and invariant 5 forbids a repo rule from running either.
    asserts.false(env, 82 in SYSEXIT_HINTS, "sysexit 82 is unreachable from a repository rule")
    return unittest.end(env)

sh_launcher_test = unittest.make(_sh_launcher_test_impl)
bat_launcher_test = unittest.make(_bat_launcher_test_impl)
sh_lazy_launcher_test = unittest.make(_sh_lazy_launcher_test_impl)
bat_lazy_launcher_test = unittest.make(_bat_lazy_launcher_test_impl)
env_bzl_test = unittest.make(_env_bzl_test_impl)
declared_bins_test = unittest.make(_declared_bins_test_impl)
closure_packages_test = unittest.make(_closure_packages_test_impl)
ambient_config_paths_test = unittest.make(_ambient_config_paths_test_impl)
is_absolute_path_test = unittest.make(_is_absolute_path_test_impl)
path_dirs_test = unittest.make(_path_dirs_test_impl)
truthy_test = unittest.make(_truthy_test_impl)
sysexit_hints_test = unittest.make(_sysexit_hints_test_impl)

def launcher_test_suite(name):
    """Instantiates the repo_utils pure-helper test suite.

    Args:
        name: name of the test suite target.
    """
    guards = []
    for case, packages in _MALFORMED_CLOSURE_REPORTS.items():
        subject = "{}_malformed_{}".format(name, case)
        _bad_closure_report(
            name = subject,
            report = json.encode({"packages": packages}),
            tags = ["manual"],
        )
        guards.append(partial.make(
            closure_packages_guard_test,
            target_under_test = ":" + subject,
        ))

    unittest.suite(
        name,
        sh_launcher_test,
        bat_launcher_test,
        sh_lazy_launcher_test,
        bat_lazy_launcher_test,
        env_bzl_test,
        declared_bins_test,
        closure_packages_test,
        ambient_config_paths_test,
        is_absolute_path_test,
        path_dirs_test,
        truthy_test,
        sysexit_hints_test,
        *guards
    )
