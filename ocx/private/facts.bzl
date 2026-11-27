# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Module-extension facts: what `ocx` reported at resolution, cached in the lockfile.

One fact per declaration, of every kind (`project`, `pinned`, `index`, `tag`).
A fact is a hit only when every field that decided it still equals the
declaration's, byte for byte, and, for a declaration of kind `tag`, only when
`RULES_OCX_UPDATE` does not name it; the key's `hash()` only spreads keys and is
never identity. Values carry `"v": 2` and are plain JSON, so a newer rules_ocx
can read or discard what an older one wrote: a value of another version, or one
whose pins are not bare platform manifest digests, is a miss. The recorded pins
are what makes a `tag` or `index` declaration reproducible.
"""

load(":manifest.bzl", "is_sha256")
load(":repo_utils.bzl", "OCX_ENV_CLASSES", "policy_exports")

visibility(["//ocx", "//ocx/tests"])

_VERSION = 2
_KINDS = ["project", "pinned", "index", "tag"]
_SHA256_PREFIX = "sha256:"

def fact_key(tag):
    """The facts key of one declaration.

    Args:
        tag: struct(kind = "project"|"pinned"|"index"|"tag", name, ...).

    Returns:
        `project|<name>` or `package|<name>`: neither the identifier nor the lock
        is in the key, so an edit to either is a miss on the same entry.
    """
    if tag.kind == "project":
        return "project|{}".format(tag.name)
    return "package|{}".format(tag.name)

def update_names(value):
    """The hub names `RULES_OCX_UPDATE` selects (pure).

    Args:
        value: the variable's text, or None when it is unset.

    Returns:
        list of names: the comma-separated parts, stripped, empties dropped.
    """
    if not value:
        return []
    return [n.strip() for n in value.split(",") if n.strip()]

def _inputs(tag):
    """The fields of the tag a fact answers; compared exactly."""
    return {
        "bindings": list(tag.bindings),
        "groups": list(tag.groups),
        "identifier": tag.identifier,
        "kind": tag.kind,
        "lock": tag.lock,
        "name": tag.name,
        "platforms": list(tag.platforms),
    }

def _plain_path(path):
    """Whether a snapshot path is a plain relative path: no `..`, empty segment, `\\` or drive."""
    if type(path) != "string" or not path or path.startswith("/") or "\\" in path:
        return False
    segments = path.split("/")
    if segments[0][1:2] == ":":
        return False
    return not any([s == "" or s == ".." for s in segments])

def _is_digest(pin):
    return type(pin) == "string" and pin.startswith(_SHA256_PREFIX) and is_sha256(pin[len(_SHA256_PREFIX):])

def _is_snapshot_file(row):
    return type(row) == "list" and len(row) == 3 and _plain_path(row[0]) and type(row[1]) == "int" and type(row[2]) == "int"

def declaration_kind(tag):
    """Classifies one declaration (pure).

    Order: `ocx.project` is `project`; an `ocx.package` whose identifier ends
    in `@sha256:<64 lowercase hex>` is `pinned`; one with an `index` is
    `index`; any other is `tag`.

    Args:
        tag: struct(kind = "project"|"package", name, identifier, index), with
            `index` "" when the declaration gives none.

    Returns:
        struct(kind, error). `error` is "" or X7
        (`rules_ocx: '<name>': the identifier '<identifier>' must start with a letter or digit`)
        for an identifier whose first character is not `A-Za-z0-9`.
    """
    if tag.kind == "project":
        return struct(kind = "project", error = "")
    if not tag.identifier or tag.identifier[0] not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789":
        return struct(kind = "", error = "rules_ocx: '{}': the identifier '{}' must start with a letter or digit".format(tag.name, tag.identifier))
    parts = tag.identifier.rsplit("@" + _SHA256_PREFIX, 1)
    if len(parts) == 2 and is_sha256(parts[1]):
        return struct(kind = "pinned", error = "")
    return struct(kind = "index" if tag.index else "tag", error = "")

def fact_value_v2(tag, kind, available_platforms, tools, pins = {}, snapshot_files = None):
    """The JSON text stored for a declaration, `"v": 2`.

    Args:
        tag: as in fact_key(); `tag.kind` is the declaration kind.
        kind: the declaration kind, `project`, `pinned`, `index` or `tag`.
        available_platforms: platforms the first resolve reported.
        tools: dict platform -> list of [name, kind], one key per platform.
        pins: dict platform -> bare platform manifest digest (never an image index).
        snapshot_files: for kind `index`, [[path, length, hash], ...].

    Returns:
        JSON string.
    """
    value = _inputs(tag)
    value.update({
        "available_platforms": list(available_platforms),
        "kind": kind,
        "pins": dict(pins),
        # The manifest's schema_version, apart from `v` (the fact's own).
        "schema_version": 2,
        "tools": tools,
        "v": _VERSION,
    })
    if kind == "index":
        value["snapshot"] = {"files": list(snapshot_files or [])}
    return json.encode(value)

def fact_decode_v2(stored):
    """Decodes a stored v2 fact.

    A value that starts with `{` but is malformed inside is not caught:
    json.decode cannot be caught in Starlark and aborts resolution. Only this
    extension writes these values, so the recovery is
    `bazel mod deps --lockfile_mode=update` (or deleting the entry from
    `MODULE.bazel.lock`).

    Args:
        stored: the string from the lockfile.

    Returns:
        the decoded dict, or None on a miss: `v` is not 2, a field is missing
        or mistyped, a pin is not a `sha256:<64 lowercase hex>` digest (or is
        missing for a platform of a kind other than `project`), or a snapshot
        path breaks the path rules.
    """

    # json.decode cannot be caught: refuse what is plainly not an object first.
    if type(stored) != "string" or not stored.startswith("{"):
        return None
    value = json.decode(stored)
    if value.get("v") != _VERSION or value.get("kind") not in _KINDS:
        return None
    for field, kind in [("available_platforms", "list"), ("tools", "dict"), ("platforms", "list"), ("pins", "dict")]:
        if type(value.get(field)) != kind:
            return None
    pins = value["pins"]
    if not all([_is_digest(pin) for pin in pins.values()]):
        return None
    if value["kind"] != "project" and not all([p in pins for p in value["platforms"]]):
        return None
    if value["kind"] == "index":
        snapshot = value.get("snapshot")
        if type(snapshot) != "dict" or type(snapshot.get("files")) != "list":
            return None
        if not all([_is_snapshot_file(row) for row in snapshot["files"]]):
            return None
    return value

def fact_hit(tag, stored, update_names = []):
    """Whether a stored fact still answers this declaration; any difference is a miss.

    Args:
        tag: as in fact_key(), plus `snapshot_files` (what index_inputs() read
            now) for kind `index`.
        stored: the string from the lockfile, or None.
        update_names: the hub names `RULES_OCX_UPDATE` selects; one that names
            a declaration of kind `tag` forces a miss.

    Returns:
        bool.
    """
    if tag.kind == "tag" and tag.name in update_names:
        return False
    value = fact_decode_v2(stored)
    if value == None:
        return False
    if not all([value.get(k) == v for k, v in _inputs(tag).items()]):
        return False
    return tag.kind != "index" or value["snapshot"]["files"] == [list(row) for row in tag.snapshot_files or []]

def manifest_env(home, config, no_config, allow_unverified, allow_yanked, trusted_root):
    """The environment of one `ocx vendor --manifest-only` run.

    Built from the arguments alone, with no getenv and no watch: the pinned
    rows of OCX_ENV_CLASSES, the explicit policy rows, the tag's `config` and
    `no_config` in their attr form, and a fresh OCX_HOME. Everything else
    (HOME, Docker config, an exported OCX_INSECURE_REGISTRIES, ...) reaches
    ocx because `module_ctx.execute` inherits the process environment.

    Args:
        home: path of the fresh scratch OCX_HOME.
        config: absolute path of the tag's `config` file, or "".
        no_config: the tag's `no_config`.
        allow_unverified: resolved ocx.policy() `allow_unverified`.
        allow_yanked: resolved ocx.policy() `allow_yanked`.
        trusted_root: absolute path of the policy's `sigstore_trusted_root`, or "".

    Returns:
        environment dict.
    """
    env = {"OCX_HOME": home}
    for key, row in OCX_ENV_CLASSES.items():
        if row.cls == "pinned":
            env[key] = row.value
    if no_config:
        # OCX_NO_CONFIG alone does not prune an inherited OCX_CONFIG.
        for key, row in OCX_ENV_CLASSES.items():
            if row.hermetic:
                env[key] = ""
        env["OCX_NO_CONFIG"] = "1"
    if config:
        env["OCX_CONFIG"] = config
    if trusted_root:
        env["OCX_SIGSTORE_TRUSTED_ROOT"] = trusted_root
    env.update(policy_exports(allow_unverified, allow_yanked))
    return env

def index_inputs(name, paths, read):
    """The snapshot inputs of a fact of kind `index` (pure).

    Args:
        name: the declaration name, for the message.
        paths: the manifest's `index_lookups` paths.
        read: function path -> the file text, or None when the path is absent.

    Returns:
        struct(files, error). `files` is [[path, length, hash], ...] with
        length -1 and hash 0 for an absent path; `error` is "" or X8
        (`rules_ocx: '<name>': the manifest names the snapshot path '<path>', which is not a plain relative path`)
        for a path that is absolute, holds `..`, an empty segment, a backslash or a drive letter.
    """
    files = []
    for path in paths:
        if not _plain_path(path):
            return struct(files = [], error = "rules_ocx: '{}': the manifest names the snapshot path '{}', which is not a plain relative path".format(name, path))
        text = read(path)
        files.append([path, -1, 0] if text == None else [path, len(text), hash(text)])
    return struct(files = files, error = "")

def same_index_check(name, manifests):
    """Step 8: every platform's root came from one image index (pure).

    Args:
        name: the declaration name.
        manifests: one parse_manifest() manifest per platform. The root is the
            package whose digest is `selections[0].roots[0]`.

    Returns:
        "" when all roots share one `index_digest` or none has one, else X2 for
        a manifest without exactly one root, else X3
        (`rules_ocx: the tag of '<name>' moved while it was resolved; run the update again`).
    """
    digests = {}
    for manifest in manifests:
        found = root_digest(name, manifest)
        if found.error:
            return found.error
        root = found.digest
        for package in manifest.packages:
            index_digest = getattr(package, "index_digest", None)
            if package.digest == root and index_digest:
                digests[index_digest] = True
    if len(digests) > 1:
        return "rules_ocx: the tag of '{}' moved while it was resolved; run the update again".format(name)
    return ""

def resolve_args(kind, args):
    """The extension's resolve argv from `vendor_args(...).args` (pure).

    Args:
        kind: the declaration kind.
        args: the argv after the binary, starting `--format json`.

    Returns:
        `args` with `--remote` right after `--format json` for kind `tag`
        only, and `--manifest-only` appended.
    """
    if kind == "tag":
        return args[:2] + ["--remote"] + args[2:] + ["--manifest-only"]
    return args + ["--manifest-only"]

def root_digest(name, manifest):
    """The one root of a package resolve (pure).

    Args:
        name: the declaration name.
        manifest: a parse_manifest() manifest.

    Returns:
        struct(digest, error); `error` is X2 unless there is exactly one selection with exactly one root.
    """
    selections = manifest.selections
    if len(selections) == 1 and len(selections[0].roots) == 1:
        return struct(digest = selections[0].roots[0], error = "")
    n = len(selections[0].roots) if len(selections) == 1 else len(selections)
    return struct(digest = "", error = "rules_ocx: '{}': ocx package vendor reported {} selections or roots; a package needs exactly one".format(name, n))

def pinned_identifier(identifier, pin):
    """The identifier a set vendors: `<registry/repo>@<pin>` (pure).

    Args:
        identifier: the declared identifier.
        pin: the platform manifest digest.

    Returns:
        the identifier without its tag and digest, plus `@<pin>`.
    """
    bare = identifier.split("@")[0]

    # A `:` before the last `/` is a registry port, not a tag.
    head, sep, last = bare.rpartition("/")
    return head + sep + last.split(":")[0] + "@" + pin

def index_paths(manifests):
    """The sorted unique union of the manifests' `index_lookups` paths (pure).

    Args:
        manifests: parse_manifest() manifests, one per platform.

    Returns:
        list of paths.
    """
    paths = {}
    for manifest in manifests:
        for lookup in getattr(manifest, "index_lookups", None) or []:
            paths[lookup.path] = True
    return sorted(paths.keys())

def result_lines(name, kind, stored, value, update_names):
    """The result lines of one declaration, text after `rules_ocx: ` included (pure).

    Args:
        name: the declaration name.
        kind: the declaration kind.
        stored: the lockfile's string for the key, or None.
        value: the text now recorded.
        update_names: the hub names `RULES_OCX_UPDATE` selects.

    Returns:
        list of lines: one per platform whose pin moved (kinds `tag`, `pinned`,
        `index`), `tools recomputed` (kind `project`), `resolved again` (a
        replaced v1 fact), or `unchanged` for a name the switch selects; none
        for a first resolve.
    """

    # json.decode cannot be caught: refuse what is plainly not an object first.
    if type(stored) != "string" or not stored.startswith("{"):
        return []
    old = json.decode(stored)
    if old.get("v") == 1:
        return ["rules_ocx: {}: resolved again (the stored fact was from an older rules_ocx)".format(name)]
    old = fact_decode_v2(stored)
    new = fact_decode_v2(value)
    if old == None or new == None:
        return []
    if old == new:
        return ["rules_ocx: {}: unchanged".format(name)] if name in update_names else []
    if kind == "project":
        return ["rules_ocx: {}: tools recomputed from the new ocx.lock".format(name)]
    return [
        "rules_ocx: {} {}: {} -> {}".format(name, platform, old["pins"][platform], pin)
        for platform, pin in sorted(new["pins"].items())
        if platform in old["pins"] and old["pins"][platform] != pin
    ]

def w1_line(raw):
    """W1: the warning for a set `RULES_OCX_UPDATE`, or "" when it names nothing (pure).

    Args:
        raw: the variable's text, or None when it is unset.

    Returns:
        the line, text after `rules_ocx: ` included.
    """
    if not update_names(raw):
        return ""
    return "rules_ocx: RULES_OCX_UPDATE={} is set; those tag declarations resolve again on every evaluation while it is set".format(raw)
