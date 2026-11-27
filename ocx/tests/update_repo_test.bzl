# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/update_repo.bzl (argument quoting, env, targets, eligibility)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:update_repo.bzl", "has_update_target", "in_main_repo", "quote_arg", "update_args", "update_build_content", "update_env")

def _quote_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        ("plain", "'plain'"),
        ("a b", "'a b'"),
        ("C:\\Users\\me\\ocx.toml", "'C:\\Users\\me\\ocx.toml'"),
        ("-g=lint,test", "'-g=lint,test'"),
        ("it's", "'it'\\''s'"),
        ("$(location x) $HOME", "'$$(location x) $$HOME'"),
        ("", "''"),
    ]
    for value, want in cases:
        asserts.equals(env, want, quote_arg(value), "quote " + repr(value))
    return unittest.end(env)

def _env_test_impl(ctx):
    env = unittest.begin(ctx)
    pinned = {"OCX_PROJECT": "", "OCX_GLOBAL": "0", "OCX_QUIET": "0", "OCX_NO_PROJECT": "1", "OCX_NO_CONFIG_REFRESH": "1"}
    plain = update_env(False, "", "", False, False)
    asserts.equals(env, dict(pinned, OCX_NO_VERIFY = "0", OCX_ALLOW_YANKED = "0"), plain, "defaults")
    asserts.equals(env, ["OCX_PROJECT", "OCX_GLOBAL", "OCX_QUIET", "OCX_NO_PROJECT", "OCX_NO_CONFIG_REFRESH", "OCX_NO_VERIFY", "OCX_ALLOW_YANKED"], list(plain.keys()), "order")
    hermetic = update_env(True, "", "", False, False)
    asserts.equals(env, "", hermetic["OCX_CONFIG"], "no_config blanks OCX_CONFIG")
    asserts.equals(env, "1", hermetic["OCX_NO_CONFIG"], "no_config sets OCX_NO_CONFIG")
    asserts.false(env, "OCX_NO_CONFIG" in plain or "OCX_CONFIG" in plain, "and only then")
    both = update_env(True, "/w/c.toml", "/w/root.json", True, True)
    asserts.equals(env, "/w/c.toml", both["OCX_CONFIG"], "a declared config outranks the blank")
    asserts.equals(env, "/w/root.json", both["OCX_SIGSTORE_TRUSTED_ROOT"], "trusted root")
    asserts.equals(env, "1", both["OCX_NO_VERIFY"], "allow_unverified")
    asserts.equals(env, "1", both["OCX_ALLOW_YANKED"], "allow_yanked")
    asserts.false(env, "OCX_SIGSTORE_TRUSTED_ROOT" in plain, "no trusted root unless declared")
    return unittest.end(env)

def _args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ["--project", "/w/ocx.toml", "update", "--no-pull"], update_args("project", "/w/ocx.toml", "", [], []))
    asserts.equals(env, ["--project", "/w/ocx.toml", "update", "--no-pull", "-g", "lint", "-g", "test", "cmake"], update_args("project", "/w/ocx.toml", "", ["lint", "test"], ["cmake"]))
    asserts.equals(env, ["--index", "/w/index", "index", "update", "ghcr.io/acme/jq:1.8"], update_args("index", "/w/index", "ghcr.io/acme/jq:1.8", [], []))
    return unittest.end(env)

def _build_test_impl(ctx):
    env = unittest.begin(ctx)
    targets = [struct(name = "tools", args = ["--project", "C:\\my dir\\ocx.toml", "update", "--no-pull"], env = {"OCX_NO_VERIFY": "0"})]
    text = update_build_content("@@+ocx+ocx_tool//:ocx", targets)
    asserts.true(env, 'load(":rule.bzl", "ocx_update")' in text)
    asserts.true(env, 'name = "hub_tools"' in text)
    asserts.true(env, 'src = "@@+ocx+ocx_tool//:ocx"' in text)
    asserts.true(env, """args = ["'--project'", "'C:\\\\my dir\\\\ocx.toml'", "'update'", "'--no-pull'"],""" in text, text)
    asserts.true(env, 'env = {"OCX_NO_VERIFY": "0"},' in text)
    asserts.false(env, "hub_" in update_build_content("@o//:ocx", []), "no declaration, no target")
    return unittest.end(env)

def _label(name, package = "", repo = ""):
    return struct(name = name, package = package, repo_name = repo)

def _eligibility_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = _label("ocx.lock", "tools")
    toml = _label("ocx.toml", "tools")
    asserts.true(env, has_update_target("project", lock, toml, None), "project in the main repository")
    asserts.false(env, has_update_target("project", _label("ocx.lock", "tools", "dep+"), toml, None), "lock of a dependency")
    asserts.false(env, has_update_target("project", lock, _label("ocx.toml", "tools", "dep+"), None), "toml of a dependency")
    asserts.false(env, has_update_target("project", _label("my.lock", "tools"), toml, None), "a lock not named ocx.lock")
    asserts.false(env, has_update_target("project", lock, _label("tools.toml", "tools"), None), "a toml not named ocx.toml")
    asserts.false(env, has_update_target("project", lock, _label("ocx.toml", "other"), None), "lock and toml in different packages")
    asserts.true(env, has_update_target("index", None, None, _label("index", "idx")), "index in the main repository")
    asserts.false(env, has_update_target("index", None, None, _label("index", "idx", "dep+")), "index of a dependency")
    asserts.false(env, has_update_target("tag", None, None, None), "tag")
    asserts.false(env, has_update_target("pinned", None, None, None), "pinned")
    return unittest.end(env)

def _main_repo_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, in_main_repo(struct(repo_name = "")), "a main-repository file, from any module")
    asserts.false(env, in_main_repo(struct(repo_name = "dep+")), "a root module naming a file of a dependency")
    asserts.true(env, in_main_repo(None), "a kind without a file")
    return unittest.end(env)

quote_test = unittest.make(_quote_test_impl)
env_test = unittest.make(_env_test_impl)
args_test = unittest.make(_args_test_impl)
build_test = unittest.make(_build_test_impl)
eligibility_test = unittest.make(_eligibility_test_impl)
main_repo_test = unittest.make(_main_repo_test_impl)

def update_repo_test_suite(name):
    """Instantiates the update_repo.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(name, quote_test, env_test, args_test, build_test, eligibility_test, main_repo_test)
