# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Module-extension facts: what `ocx` reported at resolution, cached in the lockfile (design 4.4).

One fact per tag. A fact is a hit only when every field that decided it still
equals the tag's, byte for byte; the key's `hash()` only spreads keys and is
never identity. Values carry `"v": 1` and are plain JSON, so a newer
rules_ocx can read or discard what an older one wrote.
"""

load(":repo_utils.bzl", "OCX_ENV_CLASSES", "policy_exports")

visibility(["//ocx", "//ocx/tests"])

_VERSION = 1

def fact_key(tag):
    """The facts key of one tag.

    Args:
        tag: struct(kind = "project"|"package", name, lock = "", identifier = "",
            groups = [], bindings = [], platforms = []).

    Returns:
        `project|<name>|<hash(lock)>:<len(lock)>` or `package|<name>|<identifier>`.
    """
    if tag.kind == "project":
        return "project|{}|{}:{}".format(tag.name, hash(tag.lock), len(tag.lock))
    return "package|{}|{}".format(tag.name, tag.identifier)

def _is_pinned(identifier):
    parts = identifier.rsplit("@sha256:", 1)
    return len(parts) == 2 and len(parts[1]) == 64 and all([c in "0123456789abcdef" for c in parts[1].elems()])

def fact_cacheable(tag):
    """Whether a tag may carry a fact at all.

    A project tag is pinned by its lock. A package tag is pinned only by an
    `@sha256:<64 lowercase hex>` digest; a floating tag resolves differently over time, so it
    gets no fact and the extension is not reproducible.

    Args:
        tag: as in fact_key().

    Returns:
        bool.
    """
    return tag.kind == "project" or _is_pinned(tag.identifier)

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

def fact_value(tag, available_platforms, tools):
    """The JSON text stored for a tag.

    Args:
        tag: as in fact_key().
        available_platforms: platforms the lock offers.
        tools: dict platform -> list of [name, kind].

    Returns:
        JSON string.
    """
    value = _inputs(tag)
    value.update({
        "available_platforms": list(available_platforms),
        # The manifest's schema_version, apart from `v` (the fact's own), as in design 4.4.
        "schema_version": 1,
        "tools": tools,
        "v": _VERSION,
    })
    return json.encode(value)

def _decode(stored):
    """json.decode of a stored value, as a struct(value, error)."""

    # json.decode cannot be caught in Starlark: refuse what is plainly not an
    # object first. A value that opens like one and is malformed inside aborts
    # resolution with a JSON error; only this extension writes these values, so
    # the recovery is to drop the entry or run `bazel mod deps --lockfile_mode=update`.
    if type(stored) != "string" or not stored.startswith("{"):
        return struct(value = None, error = "rules_ocx: a stored fact is not a JSON object")
    value = json.decode(stored)
    if value.get("v") != _VERSION:
        return struct(value = None, error = "rules_ocx: a stored fact has an unknown version")
    for field, kind in [("available_platforms", "list"), ("tools", "dict"), ("platforms", "list")]:
        if type(value.get(field)) != kind:
            return struct(value = None, error = "rules_ocx: a stored fact lacks `{}`".format(field))
    return struct(value = value, error = "")

def fact_hit(tag, stored):
    """Whether a stored fact still answers this tag; any field difference is a miss.

    Args:
        tag: as in fact_key().
        stored: the string from the lockfile, or None.

    Returns:
        bool.
    """
    if stored == None:
        return False
    decoded = _decode(stored)
    if decoded.error:
        return False
    return all([decoded.value.get(k) == v for k, v in _inputs(tag).items()])

def fact_decode(stored):
    """Decodes a stored fact for the C-RO-12 handoff.

    Args:
        stored: the string from the lockfile.

    Returns:
        struct(available_platforms, tools, error). `error` is "" on success;
        otherwise the other fields are empty. A value that starts with `{` but
        is malformed inside is not caught: json.decode aborts resolution, and
        the recovery is `bazel mod deps --lockfile_mode=update` (or deleting
        the entry from `MODULE.bazel.lock`).
    """
    decoded = _decode(stored)
    if decoded.error:
        return struct(available_platforms = [], tools = {}, error = decoded.error)
    return struct(
        available_platforms = decoded.value["available_platforms"],
        tools = decoded.value["tools"],
        error = "",
    )

def manifest_env(home, config, no_config, allow_unverified, allow_yanked, trusted_root):
    """The environment of one `ocx vendor --manifest-only` run (C-RO-11, C-RO-16).

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
        # OCX_NO_CONFIG alone does not prune an inherited OCX_CONFIG / OCX_PATCHES.
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
