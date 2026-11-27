# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Reader of the `ocx vendor` manifest (`manifest.json`, schema_version 2).

Only what rules_ocx consumes is exposed; `environments[]` is deliberately left
out because the launchers apply it.

The manifest is untrusted input: ocx wrote it, but the directory it sits in is
a build input a person can edit. Every path becomes a label or a symlink in a
generated BUILD file, so each one is checked before it reaches a caller.

No path has a fixed prefix: ocx chooses its layout, so only the relations
between fields are checked (a content directory inside its package directory,
a record beside its launcher, tree paths inside the content directory).
"""

visibility(["//ocx", "//ocx/tests"])

# Windows reserved device names matched on the stem.
_DEVICES = ["CON", "PRN", "AUX", "NUL"] + [
    "COM" + str(n)
    for n in range(1, 10)
] + [
    "LPT" + str(n)
    for n in range(1, 10)
]

# Names Bazel reads as package or workspace markers, compared in lower case.
RESERVED_NAMES = ["build", "build.bazel", "module.bazel", "repo.bazel", "workspace", "workspace.bazel", "workspace.bzlmod"]

# Label-safe ASCII: a path becomes a label and a symlink in the generated BUILD
# file, so anything Bazel cannot name (`:`, `"`, `\\`, controls, non-ASCII) is
# refused at the boundary instead of surfacing as a label error later.
_SAFE = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 !#$%&'()*+,-.;=?@[]^_{}~"

def _bad_segment(segment, windows):
    """Why a path segment is refused, "" when it is fine."""
    if segment in ("", ".", ".."):
        return "empty, `.` or `..` segment"
    for char in segment.elems():
        if char not in _SAFE:
            return "character {} in a segment".format(repr(char))
    if windows:
        if segment[-1] in ". ":
            return "segment ends in `.` or a space"
        if segment.split(".")[0].rstrip(" ").upper() in _DEVICES:
            return "device name segment"
    return ""

def _path_error(path, what, windows, under = "", allow_equal = False):
    """Checks the rules of a manifest path field, "" when it holds.

    `under` demands the path lie below that directory (or equal it, with
    `allow_equal`): a path related to another manifest field must stay inside it.
    """
    if type(path) != "string" or not path:
        return "{}: not a non-empty string".format(what)
    if path.startswith("/"):
        return "{} '{}': leading `/`".format(what, path)
    for segment in path.split("/"):
        why = _bad_segment(segment, windows)
        if why:
            return "{} '{}': {}".format(what, path, why)
    if under and not (path.startswith(under + "/") or (allow_equal and path == under)):
        return "{} '{}': outside '{}'".format(what, path, under)
    return ""

def _under(path, directory):
    return path.startswith(directory + "/")

def _target_error(link, target, content_dir, windows):
    """Checks one link target: relative, and inside `content_dir` once joined onto its directory."""
    if type(target) != "string" or not target:
        return "link '{}': empty or non-string target".format(link)

    # `C:` and `\` forms are absolute on Windows; refuse them whatever the host.
    if target[0] in "/\\" or (len(target) > 1 and target[1] == ":"):
        return "link '{}' has an absolute target '{}'".format(link, target)
    if not _under(link, content_dir):
        return "link '{}' is outside its content_dir '{}'".format(link, content_dir)
    for segment in target.split("/"):
        # Backslash and colon are separators or stream markers on Windows.
        if windows and segment not in ("", ".", "..") and _bad_segment(segment, True):
            return "link '{}' has target '{}': {}".format(link, target, _bad_segment(segment, True))
    base = len(content_dir.split("/"))
    stack = link.split("/")[:-1]
    for segment in target.split("/"):
        if segment in ("", "."):
            continue
        if segment == "..":
            stack = stack[:-1]
            if len(stack) < base:
                return "link '{}' has target '{}' that resolves outside content_dir '{}'".format(link, target, content_dir)
        else:
            stack.append(segment)
    return ""

def _kind_error(value, kind, what):
    """Checks a value against one of: string, int, bool, list, dict, strings (a list of strings)."""
    if kind == "strings":
        if type(value) != "list":
            return "{}: expected a list of strings".format(what)
        for item in value:
            if type(item) != "string":
                return "{}: expected a list of strings".format(what)
        return ""
    if type(value) != kind:
        return "{}: expected {}, got {}".format(what, kind, type(value))
    return ""

def _fields_error(obj, spec, what):
    """Checks the required (`key`) and optional (`key?`) fields of one object."""
    if type(obj) != "dict":
        return "{}: expected an object".format(what)
    for key, kind in spec.items():
        optional = key.endswith("?")
        name = key.rstrip("?")
        if name not in obj:
            if optional:
                continue
            return "{}: missing field '{}'".format(what, name)
        err = _kind_error(obj[name], kind, "{}.{}".format(what, name))
        if err:
            return err
    return ""

_TOP = {
    "schema_version": "int",
    "content": "string",
    "platform": "string",
    "available_platforms": "strings",
    "vendor_id": "string",
    "packages": "list",
    "selections": "list",
    "tools": "list",
    "index_lookups?": "list",
}

_PACKAGE = {
    "identifier": "string",
    "digest": "string",
    "index_digest?": "string",
    "package_dir": "string",
    "content_dir": "string",
    "dependencies?": "strings",
    "names_declared": "bool",
    "entrypoints?": "list",
    "tree?": "dict",
}

_ENTRYPOINT = {"name": "string", "launcher_path": "string", "record_path": "string", "environment": "string"}

_SELECTION = {
    "id": "string",
    "groups?": "strings",
    "bindings?": "strings",
    "roots": "strings",
    "environment": "string",
    "launcher_dir": "string",
}

_TOOL = {
    "name": "string",
    "selection": "string",
    "kind": "string",
    "package": "string",
    "environment": "string",
    "target_path": "string",
    "launcher_path?": "string",
    "record_path?": "string",
}

# Bounds of one link walk; Linux itself stops at 40 symlink expansions.
_MAX_EXPANSIONS = 40
_MAX_STEPS = 4096

def tag_name_error(name):
    """Why a tag `name` cannot be one directory and repository name, "" when it can.

    The extension uses it as a path before Bazel validates the repository name,
    so `../x` from a non-root module must not reach `mctx.file` or `ocx vendor -o`.
    """
    why = _bad_segment(name, True)
    return "tag name '{}': {}".format(name, why) if why else ""

def _tool_name_error(name, windows):
    """A tool or entry-point name becomes a file name and a label: one safe segment.

    A reserved name is refused too: a launcher called `BUILD` would turn its
    directory into a package, and only `tree.files` are stashed.
    """
    why = _bad_segment(name, windows)
    if not why and name.lower() in RESERVED_NAMES:
        why = "reserved name (Bazel reads it as a package or workspace marker)"
    return "tool name '{}': {}".format(name, why) if why else ""

def _dirname(path):
    return path.rpartition("/")[0]

def _record_error(what, launcher, record):
    """A record sits in the same directory as its launcher; its name is read verbatim."""
    if _dirname(record) != _dirname(launcher):
        return "{}: record '{}' is not in the directory of its launcher '{}'".format(what, record, launcher)
    return ""

def _lookup_path_error(path, index_name):
    """X8: a snapshot path must be a plain relative path."""
    plain = path != "" and path[0] != "/" and "\\" not in path and not (len(path) > 1 and path[1] == ":")
    if plain:
        for segment in path.split("/"):
            if segment in ("", ".", ".."):
                plain = False
    if plain:
        return ""
    return "rules_ocx: '{}': the manifest names the snapshot path '{}', which is not a plain relative path".format(index_name, path)

def _tree_conflicts(packages):
    """Duplicate paths, a link on a file, a link inside a link-free directory.

    Compared exactly: package content may hold paths that differ only by case
    (terminfo's `E/Eterm` and `e/eterm`). The tree is already on the client's
    disk when this runs, and `BUILD.bazel` stays beside `build`.
    """
    seen = {}
    dirs = []
    for package in packages:
        if package.tree:
            dirs += package.tree.link_free_dirs
    for package in packages:
        if not package.tree:
            continue
        for entry in package.tree.files + package.tree.links:
            if entry.path in seen:
                return "path '{}' is listed twice among files and links".format(entry.path)
            seen[entry.path] = True
        for link in package.tree.links:
            for directory in dirs:
                if link.path.startswith(directory + "/"):
                    return "link '{}' lies inside link-free directory '{}'".format(link.path, directory)
    return ""

def _chain_error(package):
    """Resolves every link through the declared links; refuses one that leaves `content_dir`.

    `_target_error` reads a target lexically, so `a/b/c -> ../..` followed by
    `e -> a/b/c/../../x` looks inside while the real path climbs out. Here each
    path component that is itself a declared link is replaced by that link's
    target before the walk goes on. A loop, or more expansions than any real
    package needs, is refused.
    """
    links = {link.path: link.target for link in package.tree.links}
    base = len(package.content_dir.split("/"))
    for link in package.tree.links:
        stack = link.path.split("/")[:-1]
        queue = link.target.split("/")
        expansions = 0
        for _ in range(_MAX_STEPS):
            if not queue:
                break
            segment = queue.pop(0)
            if segment in ("", "."):
                continue
            if segment == "..":
                stack = stack[:-1]
                if len(stack) < base:
                    return "link '{}' has target '{}' that resolves outside content_dir '{}' through other links".format(link.path, link.target, package.content_dir)
                continue
            stack.append(segment)
            here = "/".join(stack)
            if here in links:
                expansions += 1
                if expansions > _MAX_EXPANSIONS:
                    return "link '{}' (target '{}') runs through too many links or a loop".format(link.path, link.target)
                stack.pop()
                queue = links[here].split("/") + queue
        if queue:
            return "link '{}' (target '{}') runs through too many links or a loop".format(link.path, link.target)
    return ""

def _parse_tree(tree, package, windows):
    """Returns struct(tree, error) for one package's `tree`."""
    err = _fields_error(tree, {"files": "list", "links?": "list", "link_free_dirs?": "strings"}, "tree of " + package.identifier)
    if err:
        return struct(tree = None, error = err)
    files = []
    for entry in tree["files"]:
        err = _fields_error(entry, {"path": "string", "executable": "bool"}, "tree file")
        err = err or _path_error(entry["path"], "tree file", windows, package.content_dir)
        if err:
            return struct(tree = None, error = err)
        files.append(struct(path = entry["path"], executable = entry["executable"]))
    links = []
    for entry in tree.get("links", []):
        err = _fields_error(entry, {"path": "string", "target": "string"}, "tree link")
        err = err or _path_error(entry["path"], "tree link", windows, package.content_dir)
        err = err or _target_error(entry["path"], entry["target"], package.content_dir, windows)
        if err:
            return struct(tree = None, error = err)
        links.append(struct(path = entry["path"], target = entry["target"]))
    dirs = tree.get("link_free_dirs", [])
    for path in dirs:
        err = _path_error(path, "link_free_dirs entry", windows, package.content_dir, True)
        if err:
            return struct(tree = None, error = err)
    return struct(
        tree = struct(files = files, links = links, link_free_dirs = dirs),
        error = "",
    )

def _parse_package(raw, content, windows):
    """Returns struct(package, error)."""
    err = _fields_error(raw, _PACKAGE, "package")
    if err:
        return struct(package = None, error = err)
    err = _path_error(raw["package_dir"], "package package_dir", windows)
    err = err or _path_error(raw["content_dir"], "package content_dir", windows, raw["package_dir"])
    if err:
        return struct(package = None, error = err)
    entrypoints = []
    for entry in raw.get("entrypoints", []):
        err = _fields_error(entry, _ENTRYPOINT, "entrypoint of " + raw["identifier"])
        err = err or _tool_name_error(entry.get("name"), windows)
        err = err or _path_error(entry.get("launcher_path"), "entrypoint launcher_path", windows, raw["package_dir"])
        err = err or _path_error(entry.get("record_path"), "entrypoint record_path", windows, raw["package_dir"])
        err = err or _record_error("entrypoint " + entry["name"], entry["launcher_path"], entry["record_path"])
        if err:
            return struct(package = None, error = err)
        entrypoints.append(struct(name = entry["name"], launcher_path = entry["launcher_path"], record_path = entry["record_path"], environment = entry["environment"]))
    package = struct(
        identifier = raw["identifier"],
        digest = raw["digest"],
        index_digest = raw.get("index_digest"),
        package_dir = raw["package_dir"],
        content_dir = raw["content_dir"],
        dependencies = raw.get("dependencies", []),
        names_declared = raw["names_declared"],
        entrypoints = entrypoints,
        tree = None,
    )
    if content == "absent":
        return struct(package = package, error = "")
    if "tree" not in raw:
        return struct(package = None, error = "package {} has no tree although content is '{}'".format(raw["identifier"], content))
    parsed = _parse_tree(raw["tree"], package, windows)
    if parsed.error:
        return struct(package = None, error = parsed.error)
    return struct(package = struct(
        identifier = package.identifier,
        digest = package.digest,
        index_digest = package.index_digest,
        package_dir = package.package_dir,
        content_dir = package.content_dir,
        dependencies = package.dependencies,
        names_declared = package.names_declared,
        entrypoints = package.entrypoints,
        tree = parsed.tree,
    ), error = "")

def parse_manifest(text, index_name = ""):
    """Parses and validates the text of a vendor manifest (pure).

    Errors the real body raises (returned, not raised): `schema_version != 2`;
    a link target that is absolute or resolves outside its package's
    `content_dir`; a missing or mistyped field; a path field with an
    empty, `.` or `..` segment, a leading `/`, or a character outside label-safe
    ASCII (on a `windows/*` platform also a device-name segment or one ending
    in `.` or a space); a file, link or `link_free_dirs` entry outside its
    `content_dir`, a `content_dir` or an entry-point launcher or record outside
    its `package_dir`; a record outside its launcher's directory, or a tool with
    only one of `launcher_path` and `record_path`; a duplicate file or link path,
    a link on a file's path or inside a link-free directory; an unsafe or
    duplicated tool name; an `index_lookups[].path` that is not a plain relative
    path; no `index_lookups` while `index_name` is given. No path has a fixed
    prefix. Unknown extra fields and unknown enum values are ignored (open enums).

    Args:
        text: the JSON text of the manifest.
        index_name: the set's name when it was vendored with `--index`, else "";
            it names the set in the index-input errors and makes `index_lookups`
            mandatory.

    Returns:
        struct(manifest, error). `error` is "" on success; otherwise `manifest`
        is None. `manifest` is struct(schema_version, content, platform,
        available_platforms, vendor_id, packages, selections, tools,
        index_lookups) where a package is struct(identifier, digest,
        index_digest, package_dir, content_dir, dependencies, names_declared,
        entrypoints, tree), `index_digest` is None when absent, an entrypoint is
        struct(name, launcher_path, record_path, environment), `tree` is None when
        `content == "absent"` else struct(files = [struct(path, executable)],
        links = [struct(path, target)], link_free_dirs = [str]), a selection is
        struct(id, groups, bindings, roots, environment, launcher_dir), a
        tool is struct(name, selection, kind, package, environment,
        target_path, launcher_path, record_path) with `launcher_path` None and
        `record_path` "" when absent, and `index_lookups` is None when absent
        else [struct(path, found)].
    """
    raw = json.decode(text, default = None)
    if type(raw) != "dict":
        return struct(manifest = None, error = "manifest is not a JSON object")
    if type(raw.get("schema_version")) != "int":
        return struct(manifest = None, error = "manifest has no integer schema_version")

    # First, so a later schema's different shape reads as a version error.
    if raw["schema_version"] != 2:
        return struct(manifest = None, error = "unsupported vendor manifest schema_version {}: this rules_ocx reads 2 — pin an ocx and rules_ocx pair that agree".format(raw["schema_version"]))
    err = _fields_error(raw, _TOP, "manifest")
    if err:
        return struct(manifest = None, error = err)
    windows = raw["platform"].startswith("windows/")
    content = raw["content"]

    packages = []
    for item in raw["packages"]:
        parsed = _parse_package(item, content, windows)
        if parsed.error:
            return struct(manifest = None, error = parsed.error)
        packages.append(parsed.package)

    selections = []
    for item in raw["selections"]:
        err = _fields_error(item, _SELECTION, "selection")
        err = err or _path_error(item.get("launcher_dir"), "selection launcher_dir", windows)
        if err:
            return struct(manifest = None, error = err)
        selections.append(struct(
            id = item["id"],
            groups = item.get("groups", []),
            bindings = item.get("bindings", []),
            roots = item["roots"],
            environment = item["environment"],
            launcher_dir = item["launcher_dir"],
        ))

    tools = []
    seen = {}
    for item in raw["tools"]:
        err = _fields_error(item, _TOOL, "tool")
        err = err or _path_error(item.get("target_path"), "tool target_path", windows)
        err = err or _tool_name_error(item["name"], windows)
        if not err and ("launcher_path" in item) != ("record_path" in item):
            err = "tool '{}': launcher_path and record_path come together or not at all".format(item["name"])
        if not err and "launcher_path" in item:
            err = _path_error(item["launcher_path"], "tool launcher_path", windows)
            err = err or _path_error(item["record_path"], "tool record_path", windows)
            err = err or _record_error("tool " + item["name"], item["launcher_path"], item["record_path"])
        if not err and (item["selection"], item["name"]) in seen:
            err = "tool '{}' of selection '{}' is listed twice".format(item["name"], item["selection"])
        seen[(item["selection"], item["name"])] = True
        if err:
            return struct(manifest = None, error = err)
        tools.append(struct(
            name = item["name"],
            selection = item["selection"],
            kind = item["kind"],
            package = item["package"],
            environment = item["environment"],
            target_path = item["target_path"],
            launcher_path = item.get("launcher_path"),
            record_path = item.get("record_path", ""),
        ))

    lookups = None
    if "index_lookups" in raw:
        lookups = []
        for item in raw["index_lookups"]:
            err = _fields_error(item, {"path": "string", "found": "bool"}, "index_lookups entry")
            err = err or _lookup_path_error(item["path"], index_name)
            if err:
                return struct(manifest = None, error = err)
            lookups.append(struct(path = item["path"], found = item["found"]))
    elif index_name:
        return struct(manifest = None, error = "rules_ocx: '{}': the manifest lists no index inputs; rules_ocx needs an ocx that reports them (MR-9)".format(index_name))

    err = _tree_conflicts(packages)
    for package in packages:
        err = err or (_chain_error(package) if package.tree else "")
    if err:
        return struct(manifest = None, error = err)
    return struct(manifest = struct(
        schema_version = raw["schema_version"],
        content = content,
        platform = raw["platform"],
        available_platforms = raw["available_platforms"],
        vendor_id = raw["vendor_id"],
        packages = packages,
        selections = selections,
        tools = tools,
        index_lookups = lookups,
    ), error = "")

def read_manifest(rctx, path, index_name = ""):
    """Reads a vendor manifest in a repository rule and fail()s on any error.

    Args:
        rctx: repository_ctx.
        path: path of the manifest file.
        index_name: see parse_manifest().

    Returns:
        the `manifest` struct of parse_manifest().
    """
    result = parse_manifest(rctx.read(path), index_name)
    if result.error:
        fail("rules_ocx: {}: {}".format(path, result.error))
    return result.manifest
