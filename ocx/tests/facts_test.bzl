# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/facts.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:facts.bzl", "fact_cacheable", "fact_decode", "fact_hit", "fact_key", "fact_value", "manifest_env")

def _tag(**kwargs):
    base = dict(kind = "project", name = "tools", lock = "abc", identifier = "", groups = [], bindings = [], platforms = [])
    base.update(kwargs)
    return struct(**base)

_TOOLS = {"linux/amd64": [["cmake", "binary"]]}
_PLATFORMS = ["linux/amd64"]

def _key_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, fact_key(_tag()) != fact_key(_tag(kind = "package", identifier = "ocx.sh/x:1")))
    asserts.true(env, fact_key(_tag()) != fact_key(_tag(name = "other")))
    asserts.equals(env, fact_key(_tag()), fact_key(_tag()))
    asserts.equals(env, "project|tools|{}:3".format(hash("abc")), fact_key(_tag()))
    asserts.equals(env, "package|tools|ocx.sh/x:1@sha256:aa", fact_key(_tag(kind = "package", identifier = "ocx.sh/x:1@sha256:aa")))
    asserts.true(env, fact_key(_tag(lock = "abc")) != fact_key(_tag(lock = "abd")), "a lock edit moves the key")
    return unittest.end(env)

def _hit_test_impl(ctx):
    env = unittest.begin(ctx)
    stored = fact_value(_tag(), _PLATFORMS, _TOOLS)
    asserts.true(env, fact_hit(_tag(), stored))
    asserts.false(env, fact_hit(_tag(), None))
    return unittest.end(env)

def _miss_test_impl(ctx):
    env = unittest.begin(ctx)
    stored = fact_value(_tag(), _PLATFORMS, _TOOLS)
    for change in [
        {"lock": "def"},
        {"groups": ["g"]},
        {"bindings": ["cmake"]},
        {"platforms": ["linux/amd64"]},
        {"name": "other"},
        {"kind": "package"},
        {"identifier": "ocx.sh/x:1"},
    ]:
        asserts.false(env, fact_hit(_tag(**change), stored), "a changed {} must miss".format(change.keys()))
    return unittest.end(env)

def _cacheable_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, fact_cacheable(_tag()), "a project tag is always pinned by its lock")
    digest = "a" * 64
    asserts.true(env, fact_cacheable(_tag(kind = "package", identifier = "ocx.sh/x:1@sha256:" + digest)))
    asserts.true(env, fact_cacheable(_tag(kind = "package", identifier = "ocx.sh/x@sha256:" + digest)))
    for bad in ["@sha256:aa", "@sha256:" + "A" * 64, "@sha256:" + digest + "0", "@sha256:" + "g" * 64, "@sha256:"]:
        asserts.false(env, fact_cacheable(_tag(kind = "package", identifier = "ocx.sh/x:1" + bad)), "'{}' is no digest".format(bad))
    asserts.false(env, fact_cacheable(_tag(kind = "package", identifier = "ocx.sh/x:1")), "a floating tag gets no fact")
    return unittest.end(env)

def _populated_test_impl(ctx):
    env = unittest.begin(ctx)
    tag = _tag(groups = ["a", "b"], bindings = ["cmake", "ninja"], platforms = ["linux/amd64", "darwin/arm64"])
    stored = fact_value(tag, _PLATFORMS, _TOOLS)
    asserts.true(env, fact_hit(tag, stored), "control: the same populated tag hits")
    for change in [
        {"groups": ["b", "a"]},
        {"groups": ["a"]},
        {"bindings": ["ninja", "cmake"]},
        {"platforms": ["darwin/arm64", "linux/amd64"]},
        {"platforms": ["linux/amd64"]},
    ]:
        asserts.false(env, fact_hit(_tag(**dict({"groups": ["a", "b"], "bindings": ["cmake", "ninja"], "platforms": ["linux/amd64", "darwin/arm64"]}, **change)), stored), "a changed {} must miss".format(change.keys()))
    return unittest.end(env)

def _stored_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    good = json.decode(fact_value(_tag(), _PLATFORMS, _TOOLS))
    asserts.true(env, fact_hit(_tag(), json.encode(good)), "control: an intact value hits")
    for field in ["available_platforms", "tools", "platforms", "lock"]:
        broken = {k: v for k, v in good.items() if k != field}
        asserts.false(env, fact_hit(_tag(), json.encode(broken)), "a value without `{}` must miss".format(field))
    return unittest.end(env)

def _manifest_env_test_impl(ctx):
    env = unittest.begin(ctx)
    plain = manifest_env("/h", "", False, False, False, "")
    asserts.equals(env, "/h", plain["OCX_HOME"])
    asserts.equals(env, "1", plain["OCX_NO_PROJECT"], "a pinned row")
    asserts.equals(env, "0", plain["OCX_NO_VERIFY"], "the explicit policy rows are always written")
    asserts.equals(env, "0", plain["OCX_ALLOW_YANKED"])
    asserts.false(env, "OCX_CONFIG" in plain, "no ambient or site row is read or forwarded")
    asserts.false(env, "OCX_NO_CONFIG" in plain)

    full = manifest_env("/h", "/c.toml", True, True, True, "/root.json")
    asserts.equals(env, "/c.toml", full["OCX_CONFIG"])
    asserts.equals(env, "1", full["OCX_NO_CONFIG"])
    asserts.equals(env, "", full["OCX_PATCHES"], "no_config blanks the hermetic rows")
    asserts.equals(env, "1", full["OCX_NO_VERIFY"])
    asserts.equals(env, "1", full["OCX_ALLOW_YANKED"])
    asserts.equals(env, "/root.json", full["OCX_SIGSTORE_TRUSTED_ROOT"])
    return unittest.end(env)

def _decode_test_impl(ctx):
    env = unittest.begin(ctx)
    decoded = fact_decode(fact_value(_tag(), _PLATFORMS, _TOOLS))
    asserts.equals(env, "", decoded.error)
    asserts.equals(env, _PLATFORMS, decoded.available_platforms)
    asserts.equals(env, _TOOLS, decoded.tools)
    asserts.true(env, fact_decode("not json").error != "")
    asserts.true(env, fact_decode("[1]").error != "", "not an object")
    asserts.true(env, fact_decode("{\"v\": 2}").error != "", "an unknown version")
    asserts.true(env, fact_decode("{\"v\": 1}").error != "", "a missing field")
    asserts.false(env, fact_hit(_tag(), "{\"v\": 2}"), "an unknown version is a miss")
    asserts.false(env, fact_hit(_tag(), "garbage"), "an unreadable value is a miss")
    return unittest.end(env)

key_test = unittest.make(_key_test_impl)
hit_test = unittest.make(_hit_test_impl)
miss_test = unittest.make(_miss_test_impl)
cacheable_test = unittest.make(_cacheable_test_impl)
populated_test = unittest.make(_populated_test_impl)
stored_shape_test = unittest.make(_stored_shape_test_impl)
manifest_env_test = unittest.make(_manifest_env_test_impl)
decode_test = unittest.make(_decode_test_impl)

def facts_test_suite(name):
    """Instantiates the facts.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(name, key_test, hit_test, miss_test, populated_test, stored_shape_test, manifest_env_test, cacheable_test, decode_test)
