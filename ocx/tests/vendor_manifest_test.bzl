# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for ocx/private/vendor_manifest.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//ocx/private:vendor_manifest.bzl", "parse_manifest", "tag_name_error")
load(":testdata/vendor_manifest_example.bzl", "EXAMPLE")

_PKG = "packages/ocx.sh/sha256/1f/2e3d4c5b6a79881f2e3d4c5b6a7988"

def _with_target(target):
    return EXAMPLE.replace('"target": "cmake"', '"target": "{}"'.format(target))

def _example_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_manifest(EXAMPLE)
    asserts.equals(env, "", result.error)
    m = result.manifest
    asserts.equals(env, 1, m.schema_version)
    asserts.equals(env, "present", m.content)
    asserts.equals(env, "linux/amd64+libc.glibc", m.platform)
    asserts.equals(env, ["darwin/arm64", "linux/amd64+libc.glibc", "windows/amd64"], m.available_platforms)
    asserts.equals(env, 1, len(m.packages))
    pkg = m.packages[0]
    asserts.equals(env, _PKG + "/content", pkg.content_dir)
    asserts.true(env, pkg.names_declared)
    asserts.equals(env, [struct(path = _PKG + "/content/bin/cmake", executable = True)], pkg.tree.files)
    asserts.equals(env, [struct(path = _PKG + "/content/bin/cmake3", target = "cmake")], pkg.tree.links)
    asserts.equals(env, [_PKG + "/content/share"], pkg.tree.link_free_dirs)
    asserts.equals(env, 1, len(m.selections))
    asserts.equals(env, "selections/default/shells/default/bin", m.selections[0].launcher_dir)
    tool = m.tools[0]
    asserts.equals(env, "cmake", tool.name)
    asserts.equals(env, "binary", tool.kind)
    asserts.equals(env, "selections/default/shells/default/bin/cmake", tool.launcher_path)
    return unittest.end(env)

def _schema_version_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_manifest(EXAMPLE.replace('"schema_version": 1', '"schema_version": 2'))
    asserts.true(env, result.error != "", "schema_version 2 must be refused")
    asserts.equals(env, None, result.manifest)
    return unittest.end(env)

def _link_target_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, parse_manifest(_with_target("/etc/passwd")).error != "", "absolute target")
    asserts.true(env, parse_manifest(_with_target("../../x")).error != "", "target escaping content_dir")

    # V-69 control: the same shape inside content_dir is accepted.
    asserts.equals(env, "", parse_manifest(_with_target("../share/cmake")).error)
    return unittest.end(env)

def _mutated(mutate):
    raw = json.decode(EXAMPLE)
    mutate(raw)
    return json.encode(raw)

def _set_file_path(sub):
    def mutate(raw):
        raw["packages"][0]["tree"]["files"][0]["path"] = _PKG + "/content/" + sub

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
        raw["selections"][0].pop("groups")

    result = parse_manifest(_mutated(mutate))
    asserts.equals(env, "", result.error)
    asserts.equals(env, None, result.manifest.tools[0].launcher_path)
    asserts.equals(env, [], result.manifest.selections[0].groups)
    return unittest.end(env)

def _path_rules_test_impl(ctx):
    env = unittest.begin(ctx)

    # The newline and the backslash are refused by the label-safe allow-list,
    # not by JSON, which carries both.
    for bad in ["../x", "a//x", "a/./x", "a/b:c", "a\\b", "a/\n/b", 'a/"b', "a/\303\251", "a/\t"]:
        asserts.true(env, parse_manifest(_set_file_path(bad)).error != "", "refused: " + repr(bad))
    asserts.true(env, parse_manifest(_set_file_path("x").replace(_PKG + "/content/x", "/abs/x")).error != "", "leading slash")
    asserts.equals(env, "", parse_manifest(_set_file_path("packages/a b/c")).error, "a space is a legal character")

    # Windows-only rules: device names and trailing dots or spaces.
    def windows(path):
        def mutate(raw):
            raw["platform"] = "windows/amd64"
            raw["packages"][0]["tree"]["links"] = []
            raw["packages"][0]["tree"]["files"][0]["path"] = _PKG + "/content/" + path

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
    outside = _mutated(lambda raw: raw["packages"][0]["tree"]["links"][0].update({"path": "selections/x"}))
    asserts.true(env, parse_manifest(outside).error != "", "a link outside content_dir")
    return unittest.end(env)

def _conflicts_test_impl(ctx):
    env = unittest.begin(ctx)
    content = _PKG + "/content/"

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
    # case-sensitive package tree is legitimate content, not a conflict (C-RO-05
    # likewise keeps `BUILD.bazel` beside `build`). The exact-duplicate check
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

    asserts.true(env, check(lambda raw: _tree(raw)["files"][0].update({"path": "selections/x"})) != "", "file outside content_dir")
    asserts.true(env, check(lambda raw: _tree(raw).update({"link_free_dirs": ["packages/other"]})) != "", "dir outside content_dir")
    asserts.equals(env, "", check(lambda raw: _tree(raw).update({"links": [], "link_free_dirs": [_PKG + "/content"]})), "the content_dir itself may be link-free")
    asserts.true(env, check(lambda raw: raw["selections"][0].update({"launcher_dir": "packages/x"})) != "", "launcher_dir outside selections/")
    asserts.true(env, check(lambda raw: raw["tools"][0].update({"target_path": "selections/x"})) != "", "target_path outside packages/")
    asserts.true(env, check(lambda raw: raw["tools"][0].update({"launcher_path": "packages/x"})) != "", "launcher_path outside selections/")
    asserts.true(env, check(lambda raw: raw["packages"][0].update({"package_dir": "selections/x"})) != "", "package_dir outside packages/")
    asserts.true(env, check(lambda raw: raw["packages"][0].update({"content_dir": "packages/else"})) != "", "content_dir outside package_dir")
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
        row = '{{"name": "{0}", "launcher_path": "{1}/entrypoints/{0}", "environment": "entrypoint:x:{0}"}}'.format(name, _PKG)
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
    content = _PKG + "/content/"

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
    )
