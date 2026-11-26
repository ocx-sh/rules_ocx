# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/update_repo.bzl (plan file, value rules, selection)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:update_repo.bzl", "check_value", "plan_content", "select_declarations")

def _declaration(**kwargs):
    base = dict(
        name = "jq",
        kind = "tag",
        main_repo = True,
        write_path = "",
        identifier = "ghcr.io/acme/jq:1.8",
        config = "",
        no_config = False,
        allow_unverified = False,
        allow_yanked = False,
        trusted_root = "",
        groups = [],
        bindings = [],
    )
    base.update(kwargs)
    return struct(**base)

_PROJECT = _declaration(
    name = "dev_tools",
    kind = "project",
    write_path = "tools/ocx.lock",
    identifier = "",
    config = "/home/u/ocx config.toml",
    no_config = True,
    groups = ["lint", "test"],
    bindings = ["cmake"],
)
_TAG = _declaration()

# Fixed field order, one value per line, empty values as empty lines, no header.
_GOLDEN = "\n".join([
    "dev_tools",
    "project",
    "true",
    "tools/ocx.lock",
    "",
    "/home/u/ocx config.toml",
    "true",
    "false",
    "false",
    "",
    "2",
    "lint",
    "test",
    "1",
    "cmake",
    "jq",
    "tag",
    "true",
    "",
    "ghcr.io/acme/jq:1.8",
    "",
    "false",
    "false",
    "false",
    "",
    "0",
    "0",
]) + "\n"

def _plan_golden_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, _GOLDEN, plan_content([_PROJECT, _TAG]))
    return unittest.end(env)

def _value_rules_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", check_value("jq", "ghcr.io/acme/jq:1.8"), "control: an identifier")
    asserts.equals(env, "", check_value("jq", "lint"), "control: a group")
    asserts.equals(env, "", check_value("jq", "a-b.c_d:e/f@g+h=i,j"), "every allowed character")
    for bad in ["a;b", "-x", "a b", "a/../b", "user@host/x", "a$b", "a`b"]:
        err = check_value("dev_tools", bad)
        asserts.true(env, err.startswith("rules_ocx: 'dev_tools': cannot write an update step for '{}': ".format(bad)), "E10 for '{}': {}".format(bad, err))
    asserts.equals(env, "", check_value("jq", "/ws/my dir/ocx.lock", path = True), "a path with a space")
    asserts.equals(env, "", check_value("jq", "/ws/café/ocx.lock", path = True), "a non-ASCII path")
    for bad in ['/ws/a"b', "/ws/a%b", "/ws/a\nb"]:
        err = check_value("jq", bad, path = True)
        asserts.true(env, err.startswith("rules_ocx: 'jq': cannot write an update step for "), "E10 for path {}: {}".format(repr(bad), err))
    return unittest.end(env)

def _stub(name, kind, main_repo = True):
    return struct(name = name, kind = kind, main_repo = main_repo)

_DECLS = [_stub("dev_tools", "project"), _stub("jq", "tag"), _stub("node", "pinned"), _stub("tool", "index", main_repo = False)]

def _selection_test_impl(ctx):
    env = unittest.begin(ctx)

    # E9 first, before any argument is looked at.
    e9 = select_declarations(_DECLS, "", ["-x", "nope"], None)
    asserts.equals(env, "rules_ocx: run this target with bazel run", e9.error, "E9")
    asserts.equals(env, 64, e9.exit_code)

    # E3 before E1.
    e3 = select_declarations(_DECLS, "", ["-x", "nope"], "/ws")
    asserts.equals(env, "rules_ocx: @rules_ocx//:update takes declaration names only; pass ocx update arguments to @<name>//:update", e3.error, "E3")
    asserts.equals(env, 64, e3.exit_code)
    e1 = select_declarations(_DECLS, "", ["nope"], "/ws")
    asserts.equals(env, "rules_ocx: no ocx declaration is named 'nope'; known: dev_tools, jq, node, tool", e1.error, "E1")
    asserts.equals(env, 64, e1.exit_code)

    # E2: a package hub takes no arguments; a project hub does.
    e2 = select_declarations(_DECLS, "jq", ["x"], "/ws")
    asserts.equals(env, "rules_ocx: 'jq' is an ocx.package declaration; its update takes no arguments", e2.error, "E2")
    asserts.equals(env, 64, e2.exit_code)
    project = select_declarations(_DECLS, "dev_tools", ["-g", "lint"], "/ws")
    asserts.equals(env, "", project.error)
    asserts.equals(env, ["dev_tools"], project.selected)

    # No names: every declaration; E4 and E5 are notices with exit 0 and leave the declaration out.
    everything = select_declarations(_DECLS, "", [], "/ws")
    asserts.equals(env, "", everything.error)
    asserts.equals(env, 0, everything.exit_code)
    asserts.equals(env, ["dev_tools", "jq"], everything.selected)
    asserts.equals(env, [
        "rules_ocx: node: pinned by digest in MODULE.bazel; edit the identifier to move it",
        "rules_ocx: tool: its index snapshot is not in this workspace; update it in the module that holds it",
    ], everything.notices)
    named = select_declarations(_DECLS, "", ["node"], "/ws")
    asserts.equals(env, [], named.selected, "a pinned name selects nothing")
    asserts.equals(env, 0, named.exit_code, "E4 is a notice")

    # No declaration at all.
    empty = select_declarations([], "", [], "/ws")
    asserts.equals(env, ["rules_ocx: no ocx declarations"], empty.notices)
    asserts.equals(env, 0, empty.exit_code)
    asserts.equals(env, [], empty.selected)
    return unittest.end(env)

plan_golden_test = unittest.make(_plan_golden_test_impl)
value_rules_test = unittest.make(_value_rules_test_impl)
selection_test = unittest.make(_selection_test_impl)

def update_repo_test_suite(name):
    """Instantiates the update_repo.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(name, plan_golden_test, value_rules_test, selection_test)
