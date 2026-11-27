# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""The `ocx` module extension.

Bootstraps the pinned ocx CLI (`@ocx_tool`) and declares, per `project` or
`package` tag, one hub repository and one set repository per platform.

What the hub needs to know before any set repository is fetched (which tools,
which platforms the lock serves, the platform manifest digest each package
resolved to) is recorded as a fact in `MODULE.bazel.lock`, one per declaration
of every kind: on a hit the extension runs no `ocx` and makes no request; on a
miss it runs `ocx vendor --manifest-only` once per listed platform. Besides
that, the implementation reads `module_ctx.os`, the tag's `ocx.lock` (and its
`ocx.toml`, on a miss only), the files of an index snapshot, the
`OCX_INSTALL_*` pair and `RULES_OCX_UPDATE` (a recorded `getenv`), and nothing
else: no other getenv, no watch of ambient config. The `ocx` runs get their
environment from `manifest_env()` plus whatever `module_ctx.execute` inherits
from the process.
"""

load("//ocx/private:download.bzl", "fetch_ocx_binary", "ocx_download")
load("//ocx/private:facts.bzl", "declaration_kind", "fact_decode_v2", "fact_hit", "fact_key", "fact_value_v2", "index_inputs", "index_paths", "manifest_env", "pinned_identifier", "resolve_args", "result_lines", "root_digest", "same_index_check", "update_names", "w1_line")
load("//ocx/private:hub.bzl", "hub_platform_error", "ocx_hub_repo")
load("//ocx/private:platforms.bzl", "host_info", "platform_constraints", "slug")
load("//ocx/private:repo_utils.bzl", "POLICY_ATTRS", "policy_kwargs", "resolve_policy", "run_ocx")
load("//ocx/private:set_repo.bzl", "ocx_set_repo", "vendor_args")
load("//ocx/private:update_repo.bzl", "in_main_repo", "ocx_update_repo")
load("//ocx/private:vendor_manifest.bzl", "parse_manifest", "tag_name_error")
load("//ocx/private:versions.bzl", "DEFAULT_OCX_VERSION", "MIN_OCX_VERSION")

_download = tag_class(
    doc = "Overrides the ocx CLI bootstrap. Root module only; at most one.",
    attrs = {
        "dist_manifest": attr.label(
            default = "//dist:dist.json",
            doc = "dist.json release manifest snapshot to resolve the download from.",
        ),
        "triple": attr.string(
            doc = "Exact release target triple, overriding host detection.",
        ),
        "version": attr.string(
            doc = "Exact ocx version (default: the version pinned with this rules_ocx " +
                  "release; until a release with `ocx vendor` is listed, the default is below " +
                  "the floor and the download fails with a message saying so). Must be " + MIN_OCX_VERSION + " or newer, the first ocx release with " +
                  "`ocx vendor` and manifest schema version 2. The floor is checked " +
                  "before any download.",
        ),
    },
)

_PLATFORMS_DOC = (
    "Full ocx platform strings to provision ('linux/amd64+libc.glibc', ...), exactly as " +
    "the lock keys them. Every one must be a platform the lock serves: a platform it " +
    "cannot serve fails resolution naming it, and none is dropped silently."
)

_BLOB_DIRS_DOC = (
    "Directories of pre-fetched blobs, each passed to ocx as `--blob-dir` so the " +
    "vendor runs offline."
)

_project = tag_class(
    doc = "Vendors the toolchain of a workspace ocx.toml + ocx.lock, one set per platform, " +
          "behind one hub. Root module only.",
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the generated hub repository.",
        ),
        "bindings": attr.string_list(
            doc = "Binding names to vendor; empty = every binding of the selected groups.",
        ),
        "blob_dirs": attr.label_list(doc = _BLOB_DIRS_DOC),
        "config": attr.label(
            doc = "An ocx site config.toml (mirrors, registries) layered over the " +
                  "host's discovered config — not the project ocx.toml; sets OCX_CONFIG for " +
                  "every invocation, overriding an ambient one, and is watched. Combine with " +
                  "no_config for a hermetic configuration.",
        ),
        "groups": attr.string_list(
            doc = "ocx.toml groups to vendor. Reserved names: 'default' = the " +
                  "top-level [tools] table, 'all' = default + every group.",
        ),
        "no_config": attr.bool(
            default = False,
            doc = "Reach for it when a corporate managed config must not reach the build: " +
                  "ignores the host's discovered tiers (/etc, the user config, " +
                  "$OCX_HOME/config.toml) and the managed-config snapshot, and opts out of the " +
                  "exit-78 gate a required-but-unsynced managed config raises.",
        ),
        "ocx_lock": attr.label(
            mandatory = True,
            doc = "The committed ocx.lock next to `ocx_toml`; its text is part of the recorded fact, so an edit recomputes it.",
        ),
        "ocx_toml": attr.label(
            mandatory = True,
            doc = "The project ocx.toml.",
        ),
        "platforms": attr.string_list(
            mandatory = True,
            doc = _PLATFORMS_DOC,
        ),
    },
)

_policy = tag_class(
    doc = "Sets the build's weakening posture — unverified installs, yanked releases, a " +
          "pinned sigstore trusted root — as a function of MODULE.bazel alone. Root module " +
          "only; at most one.",
    # The same schema the repository rules declare: one wording, one default,
    # and a fourth policy attr is one row there rather than two that can
    # disagree.
    attrs = POLICY_ATTRS,
)

_package = tag_class(
    doc = "Vendors a single OCX package from an OCI registry, one set per platform, behind one hub.",
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the generated hub repository.",
        ),
        "blob_dirs": attr.label_list(doc = _BLOB_DIRS_DOC),
        "config": attr.label(
            doc = "An ocx site config.toml (mirrors, registries) layered over the " +
                  "host's discovered config — not the project ocx.toml; sets OCX_CONFIG for " +
                  "every invocation, overriding an ambient one, and is watched. Combine with " +
                  "no_config for a hermetic configuration.",
        ),
        "index": attr.label(
            doc = "Committed ocx index snapshot directory (created with " +
                  "`ocx --index <dir> index update <package>`). When set, tag resolution is " +
                  "frozen to the snapshot.",
        ),
        "no_config": attr.bool(
            default = False,
            doc = "Reach for it when a corporate managed config must not reach the build: " +
                  "ignores the host's discovered tiers (/etc, the user config, " +
                  "$OCX_HOME/config.toml) and the managed-config snapshot, and opts out of the " +
                  "exit-78 gate a required-but-unsynced managed config raises.",
        ),
        "package": attr.string(
            mandatory = True,
            doc = "Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'. Every " +
                  "declaration is locked: `MODULE.bazel.lock` records the platform manifest " +
                  "digest each listed platform resolved to, and a tag resolves again only on a " +
                  "fact miss.",
        ),
        "platforms": attr.string_list(
            mandatory = True,
            doc = _PLATFORMS_DOC,
        ),
    },
)

def _tag_struct(tier, kind, tag, lock = "", snapshot_files = None):
    """The fields a fact answers, as facts.bzl reads them."""
    return struct(
        kind = kind,
        name = tag.name,
        lock = lock,
        identifier = tag.package if tier == "package" else "",
        groups = tag.groups if tier == "project" else [],
        bindings = tag.bindings if tier == "project" else [],
        platforms = list(tag.platforms),
        index = str(tag.index) if tier == "package" and tag.index else "",
        snapshot_files = snapshot_files,
    )

def _stored_snapshot_files(mctx, tag, stored):
    """The inputs of an index fact as they read now; None when no stored index fact names any.

    A present file is watched through `read`, an absent one through `watch`,
    so its appearance re-evaluates the extension too.
    """
    fact = fact_decode_v2(stored)
    if fact == None or fact["kind"] != "index":
        return None
    return index_inputs(tag.name, [row[0] for row in fact["snapshot"]["files"]], _snapshot_reader(mctx, tag)).files

def _snapshot_reader(mctx, tag):
    """A function path -> file text (None when absent) over the tag's snapshot directory."""
    root = mctx.path(tag.index)

    def read(path):
        child = root.get_child(path)
        if child.exists:
            return mctx.read(child, watch = "yes")
        mctx.watch(child)
        return None

    return read

def _hint(kind, tag):
    """The X1 / X4 hint of a failed resolve: a function exit code -> text."""

    def hint(code):
        if kind == "tag":
            return "MODULE.bazel.lock holds no digests for '{}'; resolve the tag once online and commit MODULE.bazel.lock, pin a digest in the identifier, or give the package an index snapshot".format(tag.name)
        if kind == "index" and code == 81:
            return "the index snapshot {} has no entry for {}; run bazel run @{}//:update".format(tag.index, tag.package, tag.name)
        return ""

    return hint

def _resolve(mctx, binary, host, policy, tier, kind, tag, lock_text, attempt = ""):
    """Runs `ocx vendor --manifest-only` once per platform.

    Each run gets its own OCX_HOME and output directory inside the extension's
    working directory. module_ctx has no delete(); Bazel 9.2.0 clears
    the working directory when the extension is next evaluated (checked on a
    scratch extension), and within one evaluation every (tag, platform,
    attempt) has a directory of its own.

    Args:
        mctx: module_ctx.
        binary: path of the ocx executable.
        host: host_info() struct.
        policy: the resolve_policy() struct.
        tier: "project" or "package".
        kind: the declaration kind.
        tag: the tag instance.
        lock_text: the text of the project's ocx.lock ("" for the package tier).
        attempt: "" for the first resolve, a distinct suffix for a retry.

    Returns:
        struct(manifests): one parse_manifest() manifest per platform, in the
        tag's order.
    """

    # The vendor runs against copies, so nothing it renders can land in the
    # checkout. The ocx.toml is read here, so a hit never reads it.
    work = "facts/" + tag.name + attempt
    project = ""
    if tier == "project":
        mctx.file(work + "/project/ocx.toml", mctx.read(tag.ocx_toml))
        mctx.file(work + "/project/ocx.lock", lock_text)
        project = str(mctx.path(work + "/project/ocx.toml"))
    index = getattr(tag, "index", None)  # the project tag has none
    config = str(mctx.path(tag.config)) if tag.config else ""
    trusted_root = str(mctx.path(policy.sigstore_trusted_root)) if policy.sigstore_trusted_root else ""

    if not tag.platforms:
        fail(hub_platform_error([], []))
    manifests = []
    for platform in tag.platforms:
        scratch = "{}/{}".format(work, slug(platform))
        out = mctx.path(scratch + "/out")
        built = vendor_args(struct(
            tier = tier,
            kind = kind,
            out = str(out),
            platform = platform,
            groups = tag.groups if tier == "project" else [],
            bindings = tag.bindings if tier == "project" else [],
            package = tag.package if tier == "package" else "",
            project = project,
            index = str(mctx.path(index)) if index else "",
            blob_dirs = [str(mctx.path(d)) for d in tag.blob_dirs],
        ))
        if built.error:
            fail(built.error)
        argv = resolve_args(kind, built.args)
        env = manifest_env(str(mctx.path(scratch + "/home")), config, tag.no_config, policy.allow_unverified, policy.allow_yanked, trusted_root)
        run_ocx(mctx, binary, argv, env, "ocx vendor --manifest-only for '{}'".format(platform), host.is_windows, _hint(kind, tag))
        text = mctx.read(out.get_child("manifest.json"), watch = "no")
        parsed = parse_manifest(text, index_name = tag.name) if kind == "index" else parse_manifest(text)
        if parsed.error:
            fail(parsed.error)
        manifests.append(parsed.manifest)
        if len(manifests) == 1:
            # Before the next platform reaches ocx: a platform outside the index fails with no further fetch.
            err = hub_platform_error(tag.platforms, parsed.manifest.available_platforms)
            if err:
                fail(err)
    return struct(manifests = manifests)

def _ocx_impl(module_ctx):
    version = DEFAULT_OCX_VERSION
    dist_manifest = Label("//dist:dist.json")
    triple = ""

    # Resolved before any repository is declared: a non-root or duplicate
    # ocx.policy() tag must fail() the module resolution outright, not leave
    # a partially-declared repo graph behind.
    policy_instances = [
        struct(
            module = mod.name,
            is_root = mod.is_root,
            allow_unverified = tag.allow_unverified,
            allow_yanked = tag.allow_yanked,
            sigstore_trusted_root = tag.sigstore_trusted_root,
        )
        for mod in module_ctx.modules
        for tag in mod.tags.policy
    ]
    policy = resolve_policy(policy_instances)
    if policy.error:
        fail(policy.error)

    download_tags = 0
    for mod in module_ctx.modules:
        for tag in mod.tags.download:
            if not mod.is_root:
                fail("rules_ocx: ocx.download() may only be used by the root module (used by '{}')".format(mod.name))
            download_tags += 1
            if download_tags > 1:
                fail("rules_ocx: at most one ocx.download() tag is allowed")
            version = tag.version or version
            dist_manifest = tag.dist_manifest
            triple = tag.triple

    ocx_download(
        name = "ocx_tool",
        version = version,
        dist_manifest = dist_manifest,
        triple = triple,
    )

    seen = {"ocx_tool": True, "ocx_update": True}
    host = host_info(module_ctx.os.name, module_ctx.os.arch)
    binary = []  # fetched at most once, and only when a fact misses
    new_facts = {}

    # One recorded read per evaluation; it only decides whether a `tag` fact is trusted.
    raw_update = module_ctx.getenv("RULES_OCX_UPDATE")
    update = update_names(raw_update)
    warning = w1_line(raw_update)
    if warning:
        print(warning)  # buildifier: disable=print
    declarations = []
    update_files = {}

    for mod in module_ctx.modules:
        for tier, tags in [("project", mod.tags.project), ("package", mod.tags.package)]:
            for tag in tags:
                # Before any path or repository is built from the name.
                err = tag_name_error(tag.name)
                if err:
                    fail("rules_ocx: {} (module '{}')".format(err, mod.name))
                if tier == "project" and not mod.is_root:
                    fail("rules_ocx: ocx.project() may only be used by the root module (used by '{}')".format(mod.name))

                # Unmappable and duplicate platforms fail before any ocx run.
                repos = {}
                for platform in tag.platforms:
                    mapped = platform_constraints(platform)
                    if mapped.error:
                        fail(mapped.error)
                    repo = "{}_{}".format(tag.name, slug(platform))
                    if repo in repos.values():
                        fail("rules_ocx: platforms of '{}' collide on repository name '{}'".format(tag.name, repo))
                    repos[platform] = repo
                for name in [tag.name] + repos.values():
                    if name in seen:
                        fail("rules_ocx: duplicate repository name '{}'".format(name))
                    seen[name] = True

                decl = declaration_kind(struct(
                    kind = tier,
                    name = tag.name,
                    identifier = tag.package if tier == "package" else "",
                    index = str(tag.index) if tier == "package" and tag.index else "",
                ))
                if decl.error:
                    fail(decl.error)
                kind = decl.kind

                lock_text = module_ctx.read(tag.ocx_lock) if tier == "project" else ""
                key = fact_key(struct(kind = kind, name = tag.name))
                stored = module_ctx.facts[key] if key in module_ctx.facts else None
                snapshot = _stored_snapshot_files(module_ctx, tag, stored) if kind == "index" else None
                fact_tag = _tag_struct(tier, kind, tag, lock_text, snapshot)

                hit = fact_hit(fact_tag, stored, update)
                if hit:
                    value = stored
                else:
                    if not binary:
                        binary.append(fetch_ocx_binary(module_ctx, version, triple, dist_manifest))
                    resolved = _resolve(module_ctx, binary[0], host, policy, tier, kind, tag, lock_text)
                    if kind == "tag":
                        # Step 8: every platform must come from one image index; retry the whole declaration once.
                        if same_index_check(tag.name, resolved.manifests):
                            resolved = _resolve(module_ctx, binary[0], host, policy, tier, kind, tag, lock_text, "/retry")
                        err = same_index_check(tag.name, resolved.manifests)
                        if err:
                            fail(err)
                    manifests = resolved.manifests
                    pins = {}
                    if kind != "project":
                        for platform, manifest in zip(tag.platforms, manifests):
                            root = root_digest(tag.name, manifest)
                            if root.error:
                                fail(root.error)
                            pins[platform] = root.digest
                    files = None
                    if kind == "index":
                        inputs = index_inputs(tag.name, index_paths(manifests), _snapshot_reader(module_ctx, tag))
                        if inputs.error:
                            fail(inputs.error)
                        files = inputs.files
                    value = fact_value_v2(
                        fact_tag,
                        kind,
                        manifests[0].available_platforms,
                        {p: [[t.name, t.kind] for t in m.tools] for p, m in zip(tag.platforms, manifests)},
                        pins,
                        files,
                    )
                new_facts[key] = value
                for line in result_lines(tag.name, kind, stored, value, update):
                    print(line)  # buildifier: disable=print

                fact = fact_decode_v2(value)
                if fact == None:
                    fail("rules_ocx: the fact of '{}' does not decode; run `bazel mod deps --lockfile_mode=update`".format(tag.name))
                if hit:
                    # A miss checked the platforms inside the resolve.
                    err = hub_platform_error(tag.platforms, fact["available_platforms"])
                    if err:
                        fail(err)

                sets = {}
                names = {}
                locked = kind in ["tag", "pinned", "index"]
                for platform in tag.platforms:
                    rows = fact["tools"].get(platform)
                    if rows == None:
                        fail("rules_ocx: the recorded fact of '{}' has no tools for '{}'; run `bazel mod deps --lockfile_mode=update`".format(tag.name, platform))
                    for row in rows:
                        names[row[0]] = True
                    pin = fact["pins"][platform] if locked else ""
                    ocx_set_repo(
                        name = repos[platform],
                        tier = tier,
                        kind = kind,
                        hub = tag.name,
                        platform = platform,
                        ocx_toml = tag.ocx_toml if tier == "project" else None,
                        ocx_lock = tag.ocx_lock if tier == "project" else None,
                        groups = tag.groups if tier == "project" else [],
                        bindings = tag.bindings if tier == "project" else [],
                        package = pinned_identifier(tag.package, pin) if kind in ["tag", "pinned"] else (tag.package if tier == "package" else ""),
                        index = tag.index if tier == "package" else None,
                        blob_dirs = tag.blob_dirs,
                        expected_digest = pin,
                        expected_tools = ["{}:{}".format(row[0], row[1]) for row in rows],
                        expected_available_platforms = fact["available_platforms"] if kind in ["index", "project"] else [],
                        config = tag.config,
                        no_config = tag.no_config,
                        **policy_kwargs(policy)
                    )
                    sets[platform] = "@{}//:toolchain_impl".format(repos[platform])
                ocx_hub_repo(
                    name = tag.name,
                    sets = sets,
                    tools = sorted(names.keys()),
                    hub = tag.name,
                )

                declarations.append(json.encode({
                    "allow_unverified": policy.allow_unverified,
                    "allow_yanked": policy.allow_yanked,
                    "bindings": list(tag.bindings) if tier == "project" else [],
                    "groups": list(tag.groups) if tier == "project" else [],
                    "identifier": tag.package if tier == "package" else "",
                    "kind": kind,
                    "main_repo": in_main_repo(tag.ocx_lock if tier == "project" else tag.index),
                    "name": tag.name,
                    "no_config": tag.no_config,
                }))
                for suffix, label in [
                    ("lock", tag.ocx_lock if tier == "project" else None),
                    ("index", tag.index if tier == "package" else None),
                    ("config", tag.config),
                    ("trusted_root", policy.sigstore_trusted_root),
                ]:
                    if label:
                        update_files["{}:{}".format(tag.name, suffix)] = label

    # Lazy: nothing of it runs until someone builds an `update` target.
    ocx_update_repo(
        name = "ocx_update",
        declarations = declarations,
        files = update_files,
        ocx = "@ocx_tool//:ocx",
    )

    # No use_repo validation (root_module_direct_deps): the same extension is
    # commonly used through both a dev and a non-dev usage, and tags carry no
    # dev marker to attribute repos correctly.
    return module_ctx.extension_metadata(reproducible = True, facts = new_facts)

ocx = module_extension(
    implementation = _ocx_impl,
    doc = """Provisions tools through the OCX package manager.

Always creates `@ocx_tool` (the pinned ocx CLI). `ocx.project()` vendors a
workspace toolchain from ocx.toml/ocx.lock; `ocx.package()` vendors an
individual OCI package; each becomes a hub repository named by the tag, with
one toolchain per platform: register it with
`register_toolchains("@<name>//:all")`. `ocx.policy()` sets the build's
weakening posture (root module only). See the tag class docs for details.""",
    tag_classes = {
        "download": _download,
        "package": _package,
        "policy": _policy,
        "project": _project,
    },
)
