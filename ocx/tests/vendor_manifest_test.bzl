# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/vendor_manifest.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:vendor_manifest.bzl", "parse_manifest", "tag_name_error")
load(":testdata/vendor_manifest_example.bzl", "EXAMPLE")

_PKG2 = "p/1f2e3d4c5b6a7988"

def _with_target(target):
    return EXAMPLE.replace('"target": "cmake"', '"target": "{}"'.format(target))

def _example_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_manifest(EXAMPLE)
    asserts.equals(env, "", result.error)
    m = result.manifest
    asserts.equals(env, 2, m.schema_version)
    asserts.equals(env, "present", m.content)
    asserts.equals(env, "linux/amd64+libc.glibc", m.platform)
    asserts.equals(env, ["darwin/arm64", "linux/amd64+libc.glibc", "windows/amd64"], m.available_platforms)
    asserts.equals(env, 2, len(m.packages))
    pkg = m.packages[0]
    asserts.equals(env, _PKG2 + "/c", pkg.content_dir)
    asserts.true(env, pkg.names_declared)
    asserts.equals(env, [struct(path = _PKG2 + "/c/bin/cmake", executable = True)], pkg.tree.files)
    asserts.equals(env, [struct(path = _PKG2 + "/c/bin/cmake3", target = "cmake")], pkg.tree.links)
    asserts.equals(env, [_PKG2 + "/c/share"], pkg.tree.link_free_dirs)
    asserts.equals(env, 1, len(m.selections))
    asserts.equals(env, "l", m.selections[0].launcher_dir)
    tool = m.tools[0]
    asserts.equals(env, "cmake", tool.name)
    asserts.equals(env, "binary", tool.kind)
    asserts.equals(env, "l/cmake", tool.launcher_path)
    return unittest.end(env)

def _schema_version_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", parse_manifest(EXAMPLE).error, "control: schema_version 2 parses")
    for bad in ["3", "0", "1"]:
        result = parse_manifest(EXAMPLE.replace('"schema_version": 2', '"schema_version": ' + bad))
        asserts.true(env, "unsupported vendor manifest schema_version " + bad in result.error, "schema_version {} is refused: {}".format(bad, result.error))
        asserts.equals(env, None, result.manifest)
    text = parse_manifest(EXAMPLE.replace('"schema_version": 2', '"schema_version": "2"'))
    asserts.true(env, "no integer schema_version" in text.error, "a non-integer is refused: " + text.error)
    return unittest.end(env)

def _link_target_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, parse_manifest(_with_target("/etc/passwd")).error != "", "absolute target")
    asserts.true(env, parse_manifest(_with_target("../../x")).error != "", "target escaping content_dir")

    # Control: the same shape inside content_dir is accepted.
    asserts.equals(env, "", parse_manifest(_with_target("../share/cmake")).error)
    return unittest.end(env)

def _mutated(mutate):
    raw = json.decode(EXAMPLE)
    mutate(raw)
    return json.encode(raw)

def _set_file_path(sub):
    def mutate(raw):
        raw["packages"][0]["tree"]["files"][0]["path"] = _PKG2 + "/c/" + sub

    return _mutated(mutate)

def _tree(raw):
    return raw["packages"][0]["tree"]

def _absent_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_manifest(_mutated(lambda raw: raw.update({"content": "absent"})))
    asserts.equals(env, "", result.error)
    asserts.equals(env, None, result.manifest.packages[0].tree)
    return unittest.end(env)

def _open_enum_test_impl(ctx):
    env = unittest.begin(ctx)

    def mutate(raw):
        raw["future_field"] = {"anything": 1}
        raw["tools"][0]["kind"] = "a-kind-from-the-future"
        raw["packages"][0]["extra"] = True

    result = parse_manifest(_mutated(mutate))
    asserts.equals(env, "", result.error)
    asserts.equals(env, "a-kind-from-the-future", result.manifest.tools[0].kind)
    return unittest.end(env)

def _optional_test_impl(ctx):
    env = unittest.begin(ctx)

    def mutate(raw):
        raw["tools"][0].pop("launcher_path")
        raw["tools"][0].pop("record_path")
        raw["selections"][0].pop("groups")

    result = parse_manifest(_mutated(mutate))
    asserts.equals(env, "", result.error)
    asserts.equals(env, None, result.manifest.tools[0].launcher_path)
    asserts.equals(env, "", result.manifest.tools[0].record_path)
    asserts.equals(env, [], result.manifest.selections[0].groups)
    return unittest.end(env)

def _path_rules_test_impl(ctx):
    env = unittest.begin(ctx)

    # The newline and the backslash are refused by the label-safe allow-list,
    # not by JSON, which carries both.
    for bad in ["../x", "a//x", "a/./x", "a/b:c", "a\\b", "a/\n/b", 'a/"b', "a/\303\251", "a/\t"]:
        asserts.true(env, parse_manifest(_set_file_path(bad)).error != "", "refused: " + repr(bad))
    asserts.true(env, parse_manifest(_set_file_path("x").replace(_PKG2 + "/c/x", "/abs/x")).error != "", "leading slash")
    asserts.equals(env, "", parse_manifest(_set_file_path("packages/a b/c")).error, "a space is a legal character")

    # Windows-only rules: device names and trailing dots or spaces.
    def windows(path):
        def mutate(raw):
            raw["platform"] = "windows/amd64"
            raw["packages"][0]["tree"]["links"] = []
            raw["packages"][0]["tree"]["files"][0]["path"] = _PKG2 + "/c/" + path

        return parse_manifest(_mutated(mutate)).error

    asserts.true(env, windows("a/CON.txt") != "", "device name")
    asserts.true(env, windows("a/CON .txt") != "", "device name with a space before the extension")
    asserts.true(env, windows("a/b.") != "", "trailing dot")
    asserts.equals(env, "", windows("a/b"))
    asserts.equals(env, "", parse_manifest(_set_file_path("a/CON.txt")).error, "linux keeps device names")
    return unittest.end(env)

def _target_forms_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, _with_target("x") != EXAMPLE, "the replacement landed")
    for bad in ["\\x", "C:\\x", "c:x", "../../../x", "bin/../../../../x"]:
        asserts.true(env, parse_manifest(_with_target(bad)).error != "", "refused target: " + bad)
    for good in ["./cmake", "../bin/cmake", "a/b/../../cmake"]:
        asserts.equals(env, "", parse_manifest(_with_target(good)).error, "accepted target: " + good)

    # Windows: segment rules reach the target too.
    def windows_target(target):
        def mutate(raw):
            raw["platform"] = "windows/amd64"
            _tree(raw)["links"][0]["target"] = target

        return parse_manifest(_mutated(mutate)).error

    asserts.true(env, windows_target("a/CON") != "", "device name in a target")
    asserts.true(env, windows_target("a/b.") != "", "trailing dot in a target")
    asserts.equals(env, "", windows_target("a/b"), "control")
    outside = _mutated(lambda raw: raw["packages"][0]["tree"]["links"][0].update({"path": "p/x"}))
    asserts.true(env, parse_manifest(outside).error != "", "a link outside content_dir")
    return unittest.end(env)

def _conflicts_test_impl(ctx):
    env = unittest.begin(ctx)
    content = _PKG2 + "/c/"

    def check(mutate):
        return parse_manifest(_mutated(mutate)).error

    def dup_file(raw):
        _tree(raw)["files"].append({"path": content + "bin/cmake", "executable": False})

    def dup_case(raw):
        _tree(raw)["files"].append({"path": content + "bin/CMAKE", "executable": False})

    def case_file_and_link(raw):
        _tree(raw)["links"].append({"path": content + "bin/CMAKE-link", "target": "cmake"})
        _tree(raw)["files"].append({"path": content + "bin/cmake-LINK", "executable": False})
        _tree(raw)["links"].append({"path": content + "bin/Cmake", "target": "cmake"})

    def link_on_file(raw):
        _tree(raw)["links"].append({"path": content + "bin/cmake", "target": "x"})

    def link_in_free_dir(raw):
        _tree(raw)["links"].append({"path": content + "share/l", "target": "x"})

    def fine(raw):
        _tree(raw)["files"].append({"path": content + "bin/other", "executable": False})
        _tree(raw)["links"].append({"path": content + "bin/l2", "target": "cmake"})

    asserts.true(env, check(dup_file) != "", "duplicate file")

    # A terminfo database holds `terminfo/E/Eterm` and `terminfo/e/eterm`; a
    # case-sensitive package tree is legitimate content, not a conflict. The exact-duplicate check
    # above is its control: it still fires.
    asserts.equals(env, "", check(dup_case), "paths differing only by case are distinct files")
    asserts.equals(env, "", check(case_file_and_link), "a link beside a file differing only by case")
    asserts.true(env, check(link_on_file) != "", "link on a file's path")
    asserts.true(env, check(link_in_free_dir) != "", "link inside a link-free directory")
    asserts.equals(env, "", check(fine), "control: a distinct file and link")
    return unittest.end(env)

def _containment_test_impl(ctx):
    env = unittest.begin(ctx)

    def check(mutate):
        return parse_manifest(_mutated(mutate)).error

    asserts.true(env, check(lambda raw: _tree(raw)["files"][0].update({"path": "p/other/x"})) != "", "file outside content_dir")
    asserts.true(env, check(lambda raw: _tree(raw).update({"link_free_dirs": ["p/other"]})) != "", "dir outside content_dir")
    asserts.equals(env, "", check(lambda raw: _tree(raw).update({"links": [], "link_free_dirs": [_PKG2 + "/c"]})), "the content_dir itself may be link-free")

    # Field relations: content_dir under package_dir; the error names content_dir.
    moved = parse_manifest(_mutated(lambda raw: raw["packages"][0].update({"package_dir": "p/else"})))
    asserts.true(env, "content_dir" in moved.error, "content_dir outside package_dir: " + moved.error)
    asserts.true(env, check(lambda raw: raw["packages"][0].update({"content_dir": "p/else/c"})) != "", "content_dir outside package_dir, the other way")

    def entry_paths(launcher, record):
        row = '{{"name": "serve", "launcher_path": "{}", "record_path": "{}", "environment": "entrypoint:x:serve"}}'.format(launcher, record)
        return parse_manifest(EXAMPLE.replace('"entrypoints": []', '"entrypoints": [' + row + "]")).error

    asserts.equals(env, "", entry_paths(_PKG2 + "/e/serve", _PKG2 + "/e/serve.launch"), "control: an entry point inside package_dir")
    asserts.true(env, entry_paths("p/x/serve", "p/x/serve.launch") != "", "entry-point launcher outside package_dir")
    asserts.true(env, entry_paths(_PKG2 + "/e/serve", "p/x/serve.launch") != "", "entry-point record outside package_dir")

    # Fields without a relation to another field accept any top-level name.
    asserts.equals(env, "", check(lambda raw: raw["selections"][0].update({"launcher_dir": "other/dir"})), "launcher_dir under another top-level name")
    asserts.equals(env, "", check(lambda raw: raw["tools"][0].update({"target_path": "other/x"})), "target_path under another top-level name")
    asserts.equals(env, "", check(lambda raw: raw["tools"][0].update({"launcher_path": "other/cmake", "record_path": "other/cmake.launch"})), "launcher and record under another top-level name")
    asserts.true(env, check(lambda raw: raw["tools"][0].update({"target_path": "../x"})) != "", "target_path keeps the per-path rules")
    return unittest.end(env)

def _tool_name_test_impl(ctx):
    env = unittest.begin(ctx)

    def check(name):
        return parse_manifest(_mutated(lambda raw: raw["tools"][0].update({"name": name}))).error

    for bad in ["a/b", "..", "a\\b", "a:b", "", "a\"b"]:
        asserts.true(env, check(bad) != "", "refused tool name " + repr(bad))
    asserts.equals(env, "", check("clang-format_19.1"))

    # A launcher named like a Bazel marker would turn its directory into a package.
    for marker in ["BUILD", "build.bazel", "Module.bazel", "REPO.bazel", "WORKSPACE", "workspace.bzlmod"]:
        asserts.true(env, "reserved" in check(marker), "refused reserved tool name " + marker)

    def entry(name):
        # Text, not a key access: the interface guard keeps `entrypoints` keys in vendor_manifest.bzl alone.
        row = '{{"name": "{0}", "launcher_path": "{1}/entrypoints/{0}", "record_path": "{1}/entrypoints/{0}.launch", "environment": "entrypoint:x:{0}"}}'.format(name, _PKG2)
        return parse_manifest(EXAMPLE.replace('"entrypoints": []', '"entrypoints": [' + row + "]")).error

    asserts.equals(env, "", entry("serve"), "control: an ordinary entry point")
    asserts.true(env, "reserved" in entry("BUILD"), "refused reserved entry-point name")

    def twice(raw):
        raw["tools"].append(dict(raw["tools"][0]))

    asserts.true(env, parse_manifest(_mutated(twice)).error != "", "same name twice in one selection")
    return unittest.end(env)

def _tag_name_test_impl(ctx):
    env = unittest.begin(ctx)
    for bad in ["../x", "..", "a/b", "", ".", "a\\b"]:
        asserts.true(env, tag_name_error(bad) != "", "refused tag name " + repr(bad))
    asserts.equals(env, "", tag_name_error("tools"), "control")
    asserts.equals(env, "", tag_name_error("my_tools-2.0"), "control with punctuation")
    return unittest.end(env)

def _link_chain_test_impl(ctx):
    env = unittest.begin(ctx)
    content = _PKG2 + "/c/"

    def check(links):
        def mutate(raw):
            _tree(raw)["links"] += [{"path": content + path, "target": target} for path, target in links]

        return parse_manifest(_mutated(mutate)).error

    # A link that climbs, through a directory link, out of the content root.
    escape = [("a/b/c", "../.."), ("e", "a/b/c/../../x")]
    asserts.true(env, "outside" in check(escape) or "resolves" in check(escape), "chain escapes: " + check(escape))

    # Controls: the same shapes that stay inside, and a plain sibling `..` link.
    asserts.equals(env, "", check([("a/b/c", "../.."), ("e", "a/b/c/f")]), "chain stays inside")
    asserts.equals(env, "", check([("lib/libfoo.so", "../lib64/libfoo.so")]), "ordinary relative link")
    asserts.true(env, check([("a", "b"), ("b", "a")]) != "", "a link loop is refused")
    return unittest.end(env)

def _shape_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", parse_manifest(EXAMPLE).error, "control: the schema 2 fixture parses")
    asserts.true(env, parse_manifest("").error != "", "empty")
    asserts.true(env, parse_manifest("[]").error != "", "not an object")
    asserts.true(env, parse_manifest("{}").error != "", "no schema_version")
    asserts.true(env, parse_manifest(_mutated(lambda raw: raw.pop("platform"))).error != "", "missing platform")
    asserts.true(env, parse_manifest(_mutated(lambda raw: raw["tools"][0].update({"name": 1}))).error != "", "mistyped tool name")
    no_tree = _mutated(lambda raw: raw["packages"][0].pop("tree"))
    asserts.true(env, parse_manifest(no_tree).error != "", "present content needs a tree")
    return unittest.end(env)

example_test = unittest.make(_example_test_impl)
schema_version_test = unittest.make(_schema_version_test_impl)
link_target_test = unittest.make(_link_target_test_impl)
absent_test = unittest.make(_absent_test_impl)
open_enum_test = unittest.make(_open_enum_test_impl)
optional_test = unittest.make(_optional_test_impl)
path_rules_test = unittest.make(_path_rules_test_impl)
target_forms_test = unittest.make(_target_forms_test_impl)
shape_test = unittest.make(_shape_test_impl)
conflicts_test = unittest.make(_conflicts_test_impl)
containment_test = unittest.make(_containment_test_impl)
tool_name_test = unittest.make(_tool_name_test_impl)
tag_name_test = unittest.make(_tag_name_test_impl)
link_chain_test = unittest.make(_link_chain_test_impl)

# ---- Run 2 contract (C-RO-23): schema 2, record beside launcher, no fixed prefixes, index inputs. ----

def _v2_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_manifest(EXAMPLE)
    asserts.equals(env, "", result.error, "the schema 2 fixture parses")
    m = result.manifest
    asserts.equals(env, 2, m.schema_version)
    asserts.equals(env, 2, len(m.packages))
    asserts.equals(env, _PKG2 + "/c", m.packages[0].content_dir, "the short layout has no packages/ prefix")
    asserts.equals(env, "sha256:9c8b7a6f5e4d3c2b9c8b7a6f5e4d3c2b9c8b7a6f5e4d3c2b9c8b7a6f5e4d3c2b", m.packages[0].index_digest)
    asserts.equals(env, None, m.index_lookups, "no index_lookups without --index")
    asserts.equals(env, "l", m.selections[0].launcher_dir)
    return unittest.end(env)

def _record_path_test_impl(ctx):
    env = unittest.begin(ctx)
    m = parse_manifest(EXAMPLE).manifest
    tool = m.tools[0]
    asserts.equals(env, "l/cmake", tool.launcher_path)
    asserts.equals(env, "l/cmake.launch", tool.record_path, "the record path is read verbatim")
    entry = m.packages[1].entrypoints[0]
    asserts.equals(env, "p/5a0c1e9d2b7f3a4c/e/npm", entry.launcher_path)
    asserts.equals(env, "p/5a0c1e9d2b7f3a4c/e/npm.launch", entry.record_path)

    def without_launcher(raw):
        raw["tools"][0].pop("launcher_path")
        raw["tools"][0].pop("record_path")

    bare = parse_manifest(_mutated(without_launcher))
    asserts.equals(env, "", bare.error, "a tool may have neither")
    asserts.equals(env, "", bare.manifest.tools[0].record_path, "no launcher, no record")
    return unittest.end(env)

def _record_beside_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", parse_manifest(EXAMPLE).error, "control: the fixture parses")
    moved = parse_manifest(_mutated(lambda raw: raw["tools"][0].update({"record_path": "l/sub/cmake.launch"})))
    asserts.true(env, "record" in moved.error and "launcher" in moved.error, "a record outside its launcher's directory: " + moved.error)
    alone = parse_manifest(_mutated(lambda raw: raw["tools"][0].pop("record_path")))
    asserts.true(env, "record" in alone.error, "a launcher without its record: " + alone.error)
    return unittest.end(env)

def _v1_x5_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_manifest(EXAMPLE.replace('"schema_version": 2', '"schema_version": 1'))
    asserts.equals(env, "unsupported vendor manifest schema_version 1: this rules_ocx reads 2 — pin an ocx and rules_ocx pair that agree", result.error, "X5")
    asserts.equals(env, None, result.manifest)
    return unittest.end(env)

def _no_fixed_prefix_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", parse_manifest(EXAMPLE).error, "control")

    # Every path moves under another top-level name: the parser relates fields to each other, it names no prefix.
    moved = parse_manifest(EXAMPLE.replace('"p/', '"v/'))
    asserts.equals(env, "", moved.error, "a package directory under another top-level name parses: " + moved.error)
    outside = parse_manifest(_mutated(lambda raw: raw["packages"][0].update({"content_dir": "p/elsewhere/c"})))
    asserts.true(env, outside.error != "" and "content_dir" in outside.error, "content_dir must stay under package_dir: " + outside.error)
    return unittest.end(env)

def _index_lookups_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", parse_manifest(EXAMPLE).error, "control")
    missing = parse_manifest(EXAMPLE, index_name = "tool")
    asserts.equals(env, "rules_ocx: 'tool': the manifest lists no index inputs; rules_ocx needs an ocx that reports them (MR-9)", missing.error, "X9")

    def with_lookups(path):
        return _mutated(lambda raw: raw.update({"index_lookups": [{"path": path, "found": True}, {"path": "registry.example/config.json", "found": False}]}))

    ok = parse_manifest(with_lookups("registry.example/p/rig/tool.json"), index_name = "tool")
    asserts.equals(env, "", ok.error)
    asserts.equals(env, [struct(path = "registry.example/p/rig/tool.json", found = True), struct(path = "registry.example/config.json", found = False)], ok.manifest.index_lookups)
    asserts.equals(env, "", parse_manifest(with_lookups("registry.example/p/rig/tool.json")).error, "without an index name the field is optional")
    bad = parse_manifest(with_lookups("../x"), index_name = "tool")
    asserts.equals(env, "rules_ocx: 'tool': the manifest names the snapshot path '../x', which is not a plain relative path", bad.error, "X8")
    return unittest.end(env)

v2_test = unittest.make(_v2_test_impl)
record_path_test = unittest.make(_record_path_test_impl)
record_beside_launcher_test = unittest.make(_record_beside_launcher_test_impl)
v1_x5_test = unittest.make(_v1_x5_test_impl)
no_fixed_prefix_test = unittest.make(_no_fixed_prefix_test_impl)
index_lookups_test = unittest.make(_index_lookups_test_impl)

def vendor_manifest_test_suite(name):
    """Instantiates the vendor_manifest.bzl test suite.

    Args:
        name: name of the test suite target.
    """
    unittest.suite(
        name,
        example_test,
        schema_version_test,
        link_target_test,
        absent_test,
        open_enum_test,
        optional_test,
        path_rules_test,
        target_forms_test,
        shape_test,
        conflicts_test,
        containment_test,
        tool_name_test,
        tag_name_test,
        link_chain_test,
        v2_test,
        record_path_test,
        record_beside_launcher_test,
        v1_x5_test,
        no_fixed_prefix_test,
        index_lookups_test,
    )
