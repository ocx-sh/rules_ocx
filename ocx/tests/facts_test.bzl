# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/facts.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:facts.bzl", "declaration_kind", "fact_decode_v2", "fact_hit", "fact_key", "fact_value_v2", "index_inputs", "index_paths", "manifest_env", "pinned_identifier", "resolve_args", "result_lines", "root_digest", "same_index_check", "update_names", "w1_line")

def _tag(**kwargs):
    base = dict(kind = "project", name = "tools", lock = "abc", identifier = "", index = "", groups = [], bindings = [], platforms = [], snapshot_files = None)
    base.update(kwargs)
    return struct(**base)

_TOOLS = {"linux/amd64": [["cmake", "binary"]]}
_PLATFORMS = ["linux/amd64"]

def _value(tag, **kwargs):
    # A v2 value of the tag's own kind; a project value holds no pins.
    args = dict(kind = tag.kind, available_platforms = _PLATFORMS, tools = _TOOLS, pins = {} if tag.kind == "project" else {p: "sha256:" + "1" * 64 for p in tag.platforms})
    args.update(kwargs)
    return fact_value_v2(tag, **args)

def _key_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, fact_key(_tag()) != fact_key(_tag(kind = "tag", identifier = "ocx.sh/x:1")))
    asserts.true(env, fact_key(_tag()) != fact_key(_tag(name = "other")))
    asserts.equals(env, fact_key(_tag()), fact_key(_tag()))
    asserts.equals(env, "project|tools", fact_key(_tag()))
    asserts.equals(env, "package|tools", fact_key(_tag(kind = "tag", identifier = "ocx.sh/x:1@sha256:aa")))
    asserts.equals(env, fact_key(_tag(lock = "abc")), fact_key(_tag(lock = "abd")), "a lock edit stays on the same key and misses on the value")
    return unittest.end(env)

def _hit_test_impl(ctx):
    env = unittest.begin(ctx)
    stored = _value(_tag())
    asserts.true(env, fact_hit(_tag(), stored))
    asserts.false(env, fact_hit(_tag(), None))
    return unittest.end(env)

def _miss_test_impl(ctx):
    env = unittest.begin(ctx)
    stored = _value(_tag())
    for change in [
        {"lock": "def"},
        {"groups": ["g"]},
        {"bindings": ["cmake"]},
        {"platforms": ["linux/amd64"]},
        {"name": "other"},
        {"kind": "tag"},
        {"identifier": "ocx.sh/x:1"},
    ]:
        asserts.false(env, fact_hit(_tag(**change), stored), "a changed {} must miss".format(change.keys()))
    return unittest.end(env)

def _populated_test_impl(ctx):
    env = unittest.begin(ctx)
    tag = _tag(groups = ["a", "b"], bindings = ["cmake", "ninja"], platforms = ["linux/amd64", "darwin/arm64"])
    stored = _value(tag)
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
    good = json.decode(_value(_tag()))
    asserts.true(env, fact_hit(_tag(), json.encode(good)), "control: an intact value hits")
    for field in ["available_platforms", "tools", "platforms", "lock", "pins", "kind"]:
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
    asserts.equals(env, "1", full["OCX_NO_VERIFY"])
    asserts.equals(env, "1", full["OCX_ALLOW_YANKED"])
    asserts.equals(env, "/root.json", full["OCX_SIGSTORE_TRUSTED_ROOT"])
    return unittest.end(env)

def _decode_test_impl(ctx):
    env = unittest.begin(ctx)
    decoded = fact_decode_v2(_value(_tag()))
    asserts.equals(env, _PLATFORMS, decoded["available_platforms"])
    asserts.equals(env, _TOOLS, decoded["tools"])
    asserts.equals(env, None, fact_decode_v2("not json"))
    asserts.equals(env, None, fact_decode_v2("[1]"), "not an object")
    asserts.equals(env, None, fact_decode_v2(None), "not a string")
    asserts.equals(env, None, fact_decode_v2("{\"v\": 3}"), "an unknown version")
    asserts.equals(env, None, fact_decode_v2("{\"v\": 2}"), "a missing field")
    asserts.false(env, fact_hit(_tag(), "{\"v\": 3}"), "an unknown version is a miss")
    asserts.false(env, fact_hit(_tag(), "garbage"), "an unreadable value is a miss")
    return unittest.end(env)

def _update_names_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], update_names(None))
    asserts.equals(env, [], update_names(""))
    asserts.equals(env, ["jq"], update_names("jq"))
    asserts.equals(env, ["jq", "cmake"], update_names(" jq, cmake ,,"))
    return unittest.end(env)

key_test = unittest.make(_key_test_impl)
hit_test = unittest.make(_hit_test_impl)
miss_test = unittest.make(_miss_test_impl)
populated_test = unittest.make(_populated_test_impl)
stored_shape_test = unittest.make(_stored_shape_test_impl)
manifest_env_test = unittest.make(_manifest_env_test_impl)
decode_test = unittest.make(_decode_test_impl)
update_names_test = unittest.make(_update_names_test_impl)

# ---- Run 2 contract (C-RO-18, C-RO-19): declaration kinds and v2 facts. ----

_D1 = "sha256:" + "1" * 64
_D2 = "sha256:" + "2" * 64
_PLATS = ["linux/amd64+libc.glibc", "linux/arm64+libc.glibc"]
_AVAILABLE = ["darwin/arm64", "linux/amd64+libc.glibc", "linux/arm64+libc.glibc"]

def _tag2(**kwargs):
    # `kind` is the declaration kind; `snapshot_files` is what index_inputs() read now, None for the other kinds.
    base = dict(kind = "tag", name = "jq", lock = "", identifier = "ghcr.io/acme/jq:1.8", index = "", groups = [], bindings = [], platforms = _PLATS, snapshot_files = None)
    base.update(kwargs)
    return struct(**base)

def _tools2(name = "jq"):
    return {p: [[name, "binary"]] for p in _PLATS}

_PINS = {_PLATS[0]: _D1, _PLATS[1]: _D2}

def _value2(tag = None, **kwargs):
    tag = tag or _tag2()
    args = dict(kind = tag.kind, available_platforms = _AVAILABLE, tools = _tools2(), pins = _PINS)
    args.update(kwargs)
    return fact_value_v2(tag, **args)

def _declaration_kind_test_impl(ctx):
    env = unittest.begin(ctx)
    pinned = "ghcr.io/acme/jq:1.8@sha256:" + "a" * 64
    asserts.equals(env, "project", declaration_kind(struct(kind = "project", name = "t", identifier = "", index = "")).kind)
    asserts.equals(env, "pinned", declaration_kind(struct(kind = "package", name = "jq", identifier = pinned, index = "")).kind)
    asserts.equals(env, "pinned", declaration_kind(struct(kind = "package", name = "jq", identifier = pinned, index = "//:snap")).kind, "an index on a pinned declaration is routing, not the lock")
    asserts.equals(env, "index", declaration_kind(struct(kind = "package", name = "jq", identifier = "ghcr.io/acme/jq:1.8", index = "//:snap")).kind)
    asserts.equals(env, "tag", declaration_kind(struct(kind = "package", name = "jq", identifier = "ghcr.io/acme/jq:1.8", index = "")).kind)
    asserts.equals(env, "tag", declaration_kind(struct(kind = "package", name = "jq", identifier = "ghcr.io/acme/jq@sha256:" + "A" * 64, index = "")).kind, "an uppercase digest is no digest")
    asserts.equals(env, "", declaration_kind(struct(kind = "package", name = "jq", identifier = "ghcr.io/acme/jq:1.8", index = "")).error)
    bad = declaration_kind(struct(kind = "package", name = "jq", identifier = "-x", index = ""))
    asserts.equals(env, "rules_ocx: 'jq': the identifier '-x' must start with a letter or digit", bad.error, "X7")
    return unittest.end(env)

def _key_v2_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "package|jq", fact_key(_tag2()))
    asserts.equals(env, "package|jq", fact_key(_tag2(identifier = "ghcr.io/acme/jq:1.9")), "the key does not hold the identifier")
    asserts.equals(env, "package|jq", fact_key(_tag2(kind = "pinned")))
    asserts.equals(env, "package|jq", fact_key(_tag2(kind = "index")))
    asserts.equals(env, "project|dev_tools", fact_key(_tag2(kind = "project", name = "dev_tools", lock = "abc")), "the key does not hold the lock")
    return unittest.end(env)

def _v1_misses_test_impl(ctx):
    env = unittest.begin(ctx)
    tag = _tag2()
    v1 = json.encode({
        "available_platforms": _AVAILABLE,
        "bindings": [],
        "groups": [],
        "identifier": tag.identifier,
        "kind": tag.kind,
        "lock": "",
        "name": tag.name,
        "platforms": _PLATS,
        "schema_version": 1,
        "tools": _tools2(),
        "v": 1,
    })
    asserts.false(env, fact_hit(tag, v1), "a v1 value is a miss")
    asserts.equals(env, None, fact_decode_v2(v1), "and does not decode")
    asserts.true(env, fact_hit(tag, _value2()), "a v2 value of the same inputs is a hit")
    return unittest.end(env)

def _golden_kinds_test_impl(ctx):
    env = unittest.begin(ctx)
    tag_value = json.decode(_value2())
    asserts.equals(env, {
        "available_platforms": _AVAILABLE,
        "bindings": [],
        "groups": [],
        "identifier": "ghcr.io/acme/jq:1.8",
        "kind": "tag",
        "lock": "",
        "name": "jq",
        "pins": _PINS,
        "platforms": _PLATS,
        "schema_version": 2,
        "tools": _tools2(),
        "v": 2,
    }, tag_value, "kind tag")
    asserts.equals(env, _PLATS, sorted(tag_value["tools"].keys()), "one tools key per platform")
    asserts.equals(env, tag_value, fact_decode_v2(_value2()), "tag round-trips")

    pinned = _tag2(kind = "pinned", identifier = "ghcr.io/acme/jq:1.8@sha256:" + "a" * 64)
    asserts.equals(env, "pinned", json.decode(_value2(pinned))["kind"])
    asserts.equals(env, _PINS, json.decode(_value2(pinned))["pins"], "pinned records the platform manifest digests")

    files = [["registry.example/p/rig/tool.json", 412, -1288001112], ["registry.example/config.json", -1, 0]]
    index = _tag2(kind = "index", name = "tool", identifier = "registry.example/rig/tool:1.0.0", platforms = [_PLATS[0]], snapshot_files = files)
    value = json.decode(_value2(index, available_platforms = [_PLATS[0]], tools = {_PLATS[0]: [["tool", "binary"]]}, pins = {_PLATS[0]: _D1}, snapshot_files = files))
    asserts.equals(env, {"files": files}, value["snapshot"], "kind index holds the snapshot files")
    asserts.equals(env, {_PLATS[0]: _D1}, value["pins"])

    project = _tag2(kind = "project", name = "dev_tools", identifier = "", lock = "LOCK", groups = ["lint"], platforms = ["linux/amd64"])
    pvalue = json.decode(_value2(project, available_platforms = ["linux/amd64"], tools = {"linux/amd64": [["actionlint", "binary"]]}, pins = {}))
    asserts.equals(env, "LOCK", pvalue["lock"])
    asserts.false(env, "pins" in pvalue and pvalue["pins"] != {}, "a project fact holds no pins: the lock is the authority")
    return unittest.end(env)

def _bad_pin_test_impl(ctx):
    env = unittest.begin(ctx)
    good = json.decode(_value2())
    asserts.equals(env, good, fact_decode_v2(json.encode(good)), "control: bare digests decode")
    for bad in ["ghcr.io/x@sha256:" + "1" * 64, "sha256:" + "G" * 64, "sha256:abc", "sha256:" + "1" * 65, ""]:
        broken = dict(good, pins = {_PLATS[0]: bad, _PLATS[1]: _D2})
        asserts.equals(env, None, fact_decode_v2(json.encode(broken)), "a pin of '{}' is a miss".format(bad))
        asserts.false(env, fact_hit(_tag2(), json.encode(broken)), "and the fact misses")
    return unittest.end(env)

def _update_switch_test_impl(ctx):
    env = unittest.begin(ctx)
    for kind in ["tag", "pinned", "index", "project"]:
        tag = _tag2(kind = kind)
        stored = _value2(tag, pins = {} if kind == "project" else _PINS)
        asserts.true(env, fact_hit(tag, stored, update_names = []), "control: {} hits with no switch".format(kind))
        asserts.true(env, fact_hit(tag, stored, update_names = ["other"]), "{} hits when the switch names another hub".format(kind))
        named = fact_hit(tag, stored, update_names = ["jq"])
        asserts.equals(env, kind != "tag", named, "the switch naming the hub forces a miss for kind tag only ({})".format(kind))
    return unittest.end(env)

def _index_inputs_test_impl(ctx):
    env = unittest.begin(ctx)
    paths = ["registry.example/p/rig/tool.json", "registry.example/config.json"]
    texts = {paths[0]: "one"}
    first = index_inputs("tool", paths, texts.get)
    asserts.equals(env, "", first.error)
    asserts.equals(env, [[paths[0], 3, hash("one")], [paths[1], -1, 0]], first.files, "an absent path is length -1, hash 0")
    changed = index_inputs("tool", paths, {paths[0]: "two"}.get)
    asserts.true(env, changed.files != first.files, "one file's text changes the inputs")
    appeared = index_inputs("tool", paths, {paths[0]: "one", paths[1]: "{}"}.get)
    asserts.true(env, appeared.files != first.files, "an absent path that appears changes the inputs")
    index = _tag2(kind = "index", snapshot_files = first.files)
    stored = _value2(index, snapshot_files = first.files)
    asserts.true(env, fact_hit(index, stored), "control: the same inputs hit")
    asserts.false(env, fact_hit(_tag2(kind = "index", snapshot_files = changed.files), stored), "a changed file is a miss")
    asserts.false(env, fact_hit(_tag2(kind = "index", snapshot_files = appeared.files), stored), "an appeared file is a miss")
    return unittest.end(env)

def _snapshot_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", index_inputs("tool", ["a/b.json"], {}.get).error, "control")
    for bad in ["../x", "/x", "a//b", "a\\b", "C:/x", "a/../b", ""]:
        err = index_inputs("tool", [bad], {}.get).error
        asserts.equals(env, "rules_ocx: 'tool': the manifest names the snapshot path '{}', which is not a plain relative path".format(bad), err, "X8 for '{}'".format(bad))
        files = [[bad, 1, 2]]
        value = json.decode(_value2(_tag2(kind = "index", snapshot_files = files), snapshot_files = files))
        asserts.equals(env, None, fact_decode_v2(json.encode(value)), "a stored fact with '{}' is a miss".format(bad))
    return unittest.end(env)

def _root_manifest(root, index_digest):
    # The root is the package named by selections[0].roots[0]; a dependency never counts.
    return struct(
        selections = [struct(roots = [root])],
        packages = [
            struct(digest = root, index_digest = index_digest),
            struct(digest = "sha256:" + "d" * 64, index_digest = "sha256:" + "e" * 64),
        ],
    )

def _same_index_test_impl(ctx):
    env = unittest.begin(ctx)
    one = "sha256:" + "9" * 64
    other = "sha256:" + "8" * 64
    asserts.equals(env, "", same_index_check("jq", [_root_manifest(_D1, one), _root_manifest(_D2, one)]), "one image index")
    asserts.equals(env, "", same_index_check("jq", [_root_manifest(_D1, ""), _root_manifest(_D2, "")]), "no index digest at all")
    asserts.equals(
        env,
        "rules_ocx: the tag of 'jq' moved while it was resolved; run the update again",
        same_index_check("jq", [_root_manifest(_D1, one), _root_manifest(_D2, other)]),
        "X3 for two image indexes",
    )
    return unittest.end(env)

declaration_kind_test = unittest.make(_declaration_kind_test_impl)
key_v2_test = unittest.make(_key_v2_test_impl)
v1_misses_test = unittest.make(_v1_misses_test_impl)
golden_kinds_test = unittest.make(_golden_kinds_test_impl)
bad_pin_test = unittest.make(_bad_pin_test_impl)
update_switch_test = unittest.make(_update_switch_test_impl)
index_inputs_test = unittest.make(_index_inputs_test_impl)
snapshot_paths_test = unittest.make(_snapshot_paths_test_impl)
same_index_test = unittest.make(_same_index_test_impl)

def _resolve_args_test_impl(ctx):
    env = unittest.begin(ctx)
    base = ["--format", "json", "package", "vendor", "-o", "/o", "-p", "linux/amd64", "--omit-links", "ghcr.io/acme/jq:1.8"]
    tag = resolve_args("tag", base)
    asserts.equals(env, ["--format", "json", "--remote", "package", "vendor", "-o", "/o", "-p", "linux/amd64", "--omit-links", "ghcr.io/acme/jq:1.8", "--manifest-only"], tag, "tag: --remote after --format json, then --manifest-only")
    asserts.false(env, "--frozen" in tag, "tag is never frozen")
    for kind in ["pinned", "project"]:
        got = resolve_args(kind, base)
        asserts.equals(env, base + ["--manifest-only"], got, kind)
    frozen = ["--format", "json", "--index", "/snap", "--frozen", "package", "vendor", "-o", "/o"]
    got = resolve_args("index", frozen)
    asserts.equals(env, frozen + ["--manifest-only"], got, "index keeps what vendor_args gave")
    asserts.false(env, "--remote" in got)
    return unittest.end(env)

def _manifest_of(selections):
    return struct(selections = selections)

def _root_digest_test_impl(ctx):
    env = unittest.begin(ctx)
    ok = root_digest("jq", _manifest_of([struct(roots = [_D1])]))
    asserts.equals(env, struct(digest = _D1, error = ""), ok)

    # n counts the selections, or the roots of the one selection there is.
    for bad, n in [([], 0), ([struct(roots = [])], 0), ([struct(roots = [_D1, _D2])], 2), ([struct(roots = [_D1]), struct(roots = [_D2])], 2)]:
        got = root_digest("jq", _manifest_of(bad))
        asserts.equals(env, "", got.digest)
        asserts.equals(env, "rules_ocx: 'jq': ocx package vendor reported {} selections or roots; a package needs exactly one".format(n), got.error, "X2")
    return unittest.end(env)

def _pinned_identifier_test_impl(ctx):
    env = unittest.begin(ctx)
    a = "sha256:" + "a" * 64
    for identifier, want in [
        ("ghcr.io/acme/jq:1.8", "ghcr.io/acme/jq@" + _D1),
        ("ghcr.io/acme/jq:1.8@" + a, "ghcr.io/acme/jq@" + _D1),
        ("ghcr.io/acme/jq@" + a, "ghcr.io/acme/jq@" + _D1),
        ("ghcr.io/acme/jq", "ghcr.io/acme/jq@" + _D1),
        ("localhost:5000/rig/tool:1.0.0", "localhost:5000/rig/tool@" + _D1),
        ("localhost:5000/tool", "localhost:5000/tool@" + _D1),
    ]:
        asserts.equals(env, want, pinned_identifier(identifier, _D1), identifier)
    return unittest.end(env)

def _index_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    one = struct(index_lookups = [struct(path = "b/x.json"), struct(path = "a/y.json")])
    two = struct(index_lookups = [struct(path = "a/y.json"), struct(path = "c/z.json")])
    none = struct(index_lookups = None)
    asserts.equals(env, ["a/y.json", "b/x.json", "c/z.json"], index_paths([one, two]), "sorted unique union")
    asserts.equals(env, ["a/y.json", "b/x.json"], index_paths([one, none]), "None lookups contribute nothing")
    asserts.equals(env, [], index_paths([none]))
    return unittest.end(env)

resolve_args_test = unittest.make(_resolve_args_test_impl)
root_digest_test = unittest.make(_root_digest_test_impl)
pinned_identifier_test = unittest.make(_pinned_identifier_test_impl)
index_paths_test = unittest.make(_index_paths_test_impl)

def _result_lines_test_impl(ctx):
    env = unittest.begin(ctx)
    p0, p1 = _PLATS
    d3 = "sha256:" + "3" * 64
    old = _value2()

    # A first resolve prints nothing, with or without the switch.
    asserts.equals(env, [], result_lines("jq", "tag", None, old, []))
    asserts.equals(env, [], result_lines("jq", "tag", None, old, ["jq"]))

    # A replaced v1 fact.
    v1 = json.encode({"v": 1, "kind": "tag", "name": "jq"})
    asserts.equals(env, ["rules_ocx: jq: resolved again (the stored fact was from an older rules_ocx)"], result_lines("jq", "tag", v1, old, []))

    # One line per platform whose pin moved; a platform with no old pin is skipped.
    for kind in ["tag", "pinned", "index"]:
        files = [["a.json", 1, 2]] if kind == "index" else None
        tag = _tag2(kind = kind, snapshot_files = files)
        stored = _value2(tag)
        moved = _value2(tag, pins = {p0: _D1, p1: d3})
        asserts.equals(env, ["rules_ocx: jq {}: {} -> {}".format(p1, _D2, d3)], result_lines("jq", kind, stored, moved, []), kind)
        both = _value2(tag, pins = {p0: _D2, p1: d3})
        asserts.equals(env, ["rules_ocx: jq {}: {} -> {}".format(p0, _D1, _D2), "rules_ocx: jq {}: {} -> {}".format(p1, _D2, d3)], result_lines("jq", kind, stored, both, []), kind)
        one = _value2(_tag2(kind = kind, platforms = [p0], snapshot_files = files), pins = {p0: _D1})
        grown = _value2(tag, pins = {p0: _D1, p1: d3})
        asserts.equals(env, [], result_lines("jq", kind, one, grown, []), "a new platform has no old pin: " + kind)

    # A project fact names no pin; it says its tools were recomputed.
    proj = _tag2(kind = "project", lock = "a")
    stored = _value2(proj, pins = {})
    changed = _value2(_tag2(kind = "project", lock = "b"), pins = {})
    asserts.equals(env, ["rules_ocx: jq: tools recomputed from the new ocx.lock"], result_lines("jq", "project", stored, changed, []))

    # `unchanged` only for a declaration the switch names.
    asserts.equals(env, ["rules_ocx: jq: unchanged"], result_lines("jq", "tag", old, old, ["jq"]))
    asserts.equals(env, [], result_lines("jq", "tag", old, old, []))
    asserts.equals(env, [], result_lines("jq", "tag", old, old, ["other"]))
    return unittest.end(env)

def _w1_line_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "rules_ocx: RULES_OCX_UPDATE=jq,cmake is set; those tag declarations resolve again on every evaluation while it is set", w1_line("jq,cmake"))
    asserts.equals(env, "", w1_line(None))
    asserts.equals(env, "", w1_line(""))
    asserts.equals(env, "", w1_line(" , "))
    return unittest.end(env)

result_lines_test = unittest.make(_result_lines_test_impl)
w1_line_test = unittest.make(_w1_line_test_impl)

def facts_test_suite(name):
    """Instantiates the facts.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(name, key_test, hit_test, miss_test, populated_test, stored_shape_test, manifest_env_test, decode_test, update_names_test, declaration_kind_test, key_v2_test, v1_misses_test, golden_kinds_test, bad_pin_test, update_switch_test, index_inputs_test, snapshot_paths_test, same_index_test, resolve_args_test, root_digest_test, pinned_identifier_test, index_paths_test, result_lines_test, w1_line_test)
