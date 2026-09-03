# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for the `ocx.policy` tier: the classified env-var table, the
root-only policy reducer, and the pure argv builders that carry its decisions
into `ocx package install`, `ocx pull` and the lazy project launcher."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:package.bzl", "install_args")
load("//ocx/private:project.bzl", "lazy_project_command", "pull_args")
load(
    "//ocx/private:repo_utils.bzl",
    "CONFIG_ATTRS",
    "EAGER_LAZY_MODE",
    "OCX_ENV_CLASSES",
    "POLICY_ATTRS",
    "POLICY_DUPLICATE_MSG",
    "POLICY_NON_ROOT_MSG",
    "policy_exports",
    "policy_kwargs",
    "resolve_policy",
)

# C-001: the four classes, and how many rows each carries. A count is what
# catches a row that silently changed class — the per-row assertions below
# only see the row they are on.
_CLASS_SIZES = {"site": 10, "translucent": 4, "explicit": 2, "pinned": 5}

# C-001: the rows `no_config` blanks. OCX_SIGSTORE_TRUSTED_ROOT is deliberately
# absent — a trust root is not a config tier, and with `no_config` plus a
# `config` label carrying [[trust.policy]] ocx still reads the env rung.
_HERMETIC = ["OCX_PATCHES", "OCX_CONFIG", "OCX_PATCH_SNAPSHOT"]

def _env_classes_table_test_impl(ctx):
    """C-001/C-004: one table, four classes, every row well-formed."""
    env = unittest.begin(ctx)
    attrs = CONFIG_ATTRS.keys() + POLICY_ATTRS.keys()
    counts = {}
    hermetic = []
    for key, row in OCX_ENV_CLASSES.items():
        counts[row.cls] = counts.get(row.cls, 0) + 1
        asserts.true(env, row.cls in _CLASS_SIZES, key + " has unknown class '" + row.cls + "'")

        # Only a translucent row is a path, because only a translucent row has
        # an ambient value left to ctx.watch(): a site row is opaque, an
        # explicit one is never read, and a pinned one names no file.
        if row.path:
            asserts.equals(env, "translucent", row.cls, key + " sets path outside translucent")

        # A fixed value belongs to a pinned row and nowhere else. Asserted in
        # the other direction too — OCX_PROJECT pins the empty string, which
        # no truthiness test would catch.
        if row.cls != "pinned":
            asserts.equals(env, "", row.value, key + " carries a pinned value")

        # A translucent or explicit row is only overridable because a rule
        # attr exists to override it; every other row names none.
        if row.cls in ["translucent", "explicit"]:
            asserts.true(env, row.attr in attrs, key + " names attr '" + row.attr + "', which no rule declares")
        else:
            asserts.equals(env, "", row.attr, key + " names an attr its class never reads")
        if row.hermetic:
            hermetic.append(key)
    asserts.equals(env, _CLASS_SIZES, counts)
    asserts.equals(env, _HERMETIC, hermetic)

    # OCX_HOME is resolved, never classified: it is computed from the host and
    # `isolated_home`, and a row here would make it forwardable.
    asserts.false(env, "OCX_HOME" in OCX_ENV_CLASSES, "OCX_HOME belongs to no class")
    return unittest.end(env)

def _policy_exports_test_impl(ctx):
    """C-002: the weakening pair, always both keys — presence is the seal."""
    env = unittest.begin(ctx)
    asserts.equals(env, {"OCX_NO_VERIFY": "0", "OCX_ALLOW_YANKED": "0"}, policy_exports(False, False))
    asserts.equals(env, {"OCX_NO_VERIFY": "1", "OCX_ALLOW_YANKED": "0"}, policy_exports(True, False))
    asserts.equals(env, {"OCX_NO_VERIFY": "0", "OCX_ALLOW_YANKED": "1"}, policy_exports(False, True))
    asserts.equals(env, {"OCX_NO_VERIFY": "1", "OCX_ALLOW_YANKED": "1"}, policy_exports(True, True))
    return unittest.end(env)

def _tag(module, is_root, allow_unverified = False, allow_yanked = False, sigstore_trusted_root = None):
    """One `ocx.policy()` instance as _ocx_impl collects it.

    Args:
        module: the declaring module's name.
        is_root: whether that module is the root module.
        allow_unverified: the tag's `allow_unverified` attr.
        allow_yanked: the tag's `allow_yanked` attr.
        sigstore_trusted_root: the tag's `sigstore_trusted_root` label attr.

    Returns:
        the struct resolve_policy() consumes.
    """
    return struct(
        module = module,
        is_root = is_root,
        allow_unverified = allow_unverified,
        allow_yanked = allow_yanked,
        sigstore_trusted_root = sigstore_trusted_root,
    )

def _resolve_policy_test_impl(ctx):
    """C-005/C-006: root-only, at most one, and the values it threads."""
    env = unittest.begin(ctx)

    # S-001: no tag at all is the common case, and its defaults are the safe
    # ones — nothing is loosened and nothing is said about it.
    empty = resolve_policy([])
    asserts.equals(env, "", empty.error)
    asserts.equals(env, False, empty.allow_unverified)
    asserts.equals(env, False, empty.allow_yanked)
    asserts.equals(env, None, empty.sigstore_trusted_root)

    # S-002: the root's answer is threaded verbatim into every repo rule.
    one = resolve_policy([_tag(
        "root",
        True,
        allow_unverified = True,
        allow_yanked = True,
        sigstore_trusted_root = "//trust:trusted-root.json",
    )])
    asserts.equals(env, "", one.error)
    asserts.equals(env, True, one.allow_unverified)
    asserts.equals(env, True, one.allow_yanked)
    asserts.equals(env, "//trust:trusted-root.json", one.sigstore_trusted_root)

    # S-003: a dependency loosening the graph's trust posture stops the build
    # rather than being silently dropped — and the message names it, because
    # the root cannot grep a module graph for a tag it never wrote. The
    # expected text comes from the constant, so this test cannot pass by
    # spelling the message a second time.
    asserts.equals(
        env,
        POLICY_NON_ROOT_MSG.format("evil_dep"),
        resolve_policy([_tag("root", True), _tag("evil_dep", False)]).error,
    )
    asserts.equals(
        env,
        POLICY_NON_ROOT_MSG.format("first_dep"),
        resolve_policy([_tag("first_dep", False), _tag("second_dep", False)]).error,
    )

    # S-004: `mod.tags.policy` aggregates every use_extension() of a module,
    # so the root's dev and non-dev usages arrive as two instances of the same
    # module — two answers to a one-answer question.
    asserts.equals(
        env,
        POLICY_DUPLICATE_MSG,
        resolve_policy([_tag("root", True), _tag("root", True, allow_yanked = True)]).error,
    )
    return unittest.end(env)

def _policy_kwargs_test_impl(ctx):
    """C-004/C-006: the resolved policy reaches every repo rule, whole.

    extensions.bzl splats this dict at all three ocx_project_repo /
    ocx_package_repo declarations, so a policy attr the dict forgets is an
    attr no repository ever receives — and, since every default is the safe
    value, a silent one.
    """
    env = unittest.begin(ctx)

    # Pinned against a hand-written triple, so a fourth POLICY_ATTRS attr that
    # never reaches this dict cannot pass unnoticed.
    asserts.equals(
        env,
        {"allow_unverified": False, "allow_yanked": False, "sigstore_trusted_root": None},
        policy_kwargs(resolve_policy([])),
    )

    # A non-default policy is threaded value for value.
    asserts.equals(
        env,
        {
            "allow_unverified": True,
            "allow_yanked": True,
            "sigstore_trusted_root": "//trust:trusted-root.json",
        },
        policy_kwargs(resolve_policy([_tag(
            "root",
            True,
            allow_unverified = True,
            allow_yanked = True,
            sigstore_trusted_root = "//trust:trusted-root.json",
        )])),
    )
    return unittest.end(env)

# The argv prefix `_ocx_package_repo_impl` hands install_args(): root flags,
# the JSON format selector, then the `package` subcommand group.
_JSON_PKG = ["--format", "json", "package"]

_PKG = "ocx.sh/jqlang/jq:latest@sha256:" + "a" * 64

def _install_args_test_impl(ctx):
    """C-007: `ocx package install` carries no verify flag, under any policy.

    The posture rides on OCX_NO_VERIFY, which `make_ocx_env()` writes on every
    invocation — ocx's own documented equivalent of `--no-verify`.
    """
    env = unittest.begin(ctx)

    # The platform selector sits before the reference: anything placed after
    # the positional would be read as part of it.
    asserts.equals(
        env,
        _JSON_PKG + ["install", _PKG],
        install_args(_JSON_PKG, [], _PKG),
    )
    asserts.equals(
        env,
        _JSON_PKG + ["install", "-p", "linux/amd64", _PKG],
        install_args(_JSON_PKG, ["-p", "linux/amd64"], _PKG),
    )

    # Neither spelling of the flag ever appears — the exact-argv assertions
    # above already pin that, but this fails loudly if the builder grows one.
    for platform_arg in [[], ["-p", "linux/amd64"]]:
        argv = install_args(_JSON_PKG, platform_arg, _PKG)
        asserts.false(env, "--no-verify" in argv, "install argv carries --no-verify")
        asserts.false(env, "--verify" in argv, "install argv carries --verify")
    return unittest.end(env)

def _pull_args_test_impl(ctx):
    """C-007: `ocx pull` carries no verify flag at all.

    The project tier's posture is the pinned OCX_NO_VERIFY instead, attached
    once on the shared manager in ocx's own Context::try_init.
    """
    env = unittest.begin(ctx)
    project = ["--project", "/w/ocx.toml"]
    asserts.equals(env, project + ["pull"] + EAGER_LAZY_MODE, pull_args(project, [], []))

    # Groups stay behind the lazy-mode refusal, one comma-joined -g.
    asserts.equals(
        env,
        project + ["pull", "--platform", "linux/amd64"] + EAGER_LAZY_MODE + ["-g", "dev,ci"],
        pull_args(project, ["--platform", "linux/amd64"], ["dev", "ci"]),
    )
    return unittest.end(env)

def _lazy_project_command_test_impl(ctx):
    """C-015: the lazy project launcher re-enters `ocx exec`, not `ocx run`."""
    env = unittest.begin(ctx)

    # POSIX arm: runfiles-resolved fragments, so the script text is identical
    # on every machine. The builder quotes nothing — the caller already did.
    posix = lazy_project_command(
        '"$(rlocation r+ocx_tool/ocx)"',
        '"$(rlocation r+proj/ocx.toml)"',
        ["-g", "'dev,ci'"],
        "shellcheck",
    )
    asserts.equals(env, [
        '"$(rlocation r+ocx_tool/ocx)"',
        "--project",
        '"$(rlocation r+proj/ocx.toml)"',
        "exec",
        "-g",
        "'dev,ci'",
        "--",
        "shellcheck",
    ], posix)

    # Windows arm: baked absolute paths, no groups.
    asserts.equals(env, [
        '"C:\\repo\\ocx.exe"',
        "--project",
        '"C:\\repo\\ocx.toml"',
        "exec",
        "--",
        "shellcheck",
    ], lazy_project_command('"C:\\repo\\ocx.exe"', '"C:\\repo\\ocx.toml"', [], "shellcheck"))

    return unittest.end(env)

env_classes_table_test = unittest.make(_env_classes_table_test_impl)
policy_exports_test = unittest.make(_policy_exports_test_impl)
resolve_policy_test = unittest.make(_resolve_policy_test_impl)
policy_kwargs_test = unittest.make(_policy_kwargs_test_impl)
install_args_test = unittest.make(_install_args_test_impl)
pull_args_test = unittest.make(_pull_args_test_impl)
lazy_project_command_test = unittest.make(_lazy_project_command_test_impl)

def policy_test_suite(name):
    """Instantiates the ocx.policy tier test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        env_classes_table_test,
        policy_exports_test,
        resolve_policy_test,
        policy_kwargs_test,
        install_args_test,
        pull_args_test,
        lazy_project_command_test,
    )
