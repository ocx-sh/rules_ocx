# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""The `ocx` module extension.

Bootstraps the pinned ocx CLI (`@ocx_tool`) and declares, per `project` or
`package` tag, one hub repository and one set repository per platform.

What the hub needs to know before any set repository is fetched (which tools,
which platforms the lock serves) is recorded as a fact in `MODULE.bazel.lock`:
on a hit the extension runs no `ocx` and makes no request; on a
miss it runs `ocx vendor --manifest-only` once per listed platform. Besides
that, the implementation reads `module_ctx.os`, the tag's `ocx.lock` (and its
`ocx.toml`, on a miss only) and the `OCX_INSTALL_*` pair, and nothing else:
no other getenv, no watch of ambient config. The `ocx` runs get
their environment from `manifest_env()` plus whatever `module_ctx.execute`
inherits from the process.
"""

load("//ocx/private:download.bzl", "fetch_ocx_binary", "ocx_download")
load("//ocx/private:facts.bzl", "fact_cacheable", "fact_decode", "fact_hit", "fact_key", "fact_value", "manifest_env")
load("//ocx/private:hub.bzl", "hub_platform_error", "ocx_hub_repo")
load("//ocx/private:platforms.bzl", "host_info", "platform_constraints", "slug")
load("//ocx/private:repo_utils.bzl", "POLICY_ATTRS", "policy_kwargs", "resolve_policy", "run_ocx")
load("//ocx/private:set_repo.bzl", "ocx_set_repo", "vendor_args")
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
                  "release). Must be " + MIN_OCX_VERSION + " or newer, the first ocx release with " +
                  "`ocx vendor` and manifest schema version 1. The floor is checked " +
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
            doc = "Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'. Only a " +
                  "digest-pinned identifier is recorded as a fact and keeps the extension reproducible.",
        ),
        "platforms": attr.string_list(
            mandatory = True,
            doc = _PLATFORMS_DOC,
        ),
    },
)

def _tag_struct(kind, tag, lock = ""):
    """The fields a fact answers, as facts.bzl reads them."""
    return struct(
        kind = kind,
        name = tag.name,
        lock = lock,
        identifier = tag.package if kind == "package" else "",
        groups = tag.groups if kind == "project" else [],
        bindings = tag.bindings if kind == "project" else [],
        platforms = list(tag.platforms),
    )

def _manifest_facts(mctx, binary, host, policy, tier, tag, lock_text):
    """Runs `ocx vendor --manifest-only` once per platform and reads what the hub needs.

    Each run gets its own OCX_HOME and output directory inside the extension's
    working directory. module_ctx has no delete(); Bazel 9.2.0 clears
    the working directory when the extension is next evaluated (checked on a
    scratch extension), and within one evaluation every (tag, platform) has a
    directory of its own.

    Args:
        mctx: module_ctx.
        binary: path of the ocx executable.
        host: host_info() struct.
        policy: the resolve_policy() struct.
        tier: "project" or "package".
        tag: the tag instance.
        lock_text: the text of the project's ocx.lock ("" for the package tier).

    Returns:
        struct(available_platforms, tools): tools is {platform: [[name, kind], ...]}.
    """

    # The vendor runs against copies, so nothing it renders can land in the
    # checkout. The ocx.toml is read here, so a hit never reads it.
    work = "facts/" + tag.name
    project = ""
    if tier == "project":
        mctx.file(work + "/project/ocx.toml", mctx.read(tag.ocx_toml))
        mctx.file(work + "/project/ocx.lock", lock_text)
        project = str(mctx.path(work + "/project/ocx.toml"))
    index = getattr(tag, "index", None)  # the project tag has none
    config = str(mctx.path(tag.config)) if tag.config else ""
    trusted_root = str(mctx.path(policy.sigstore_trusted_root)) if policy.sigstore_trusted_root else ""

    available = None
    tools = {}

    # The first run tells what the lock serves; a platform outside that fails
    # naming it before ocx is asked for it. If the first run itself
    # fails, run_ocx() reports ocx's message with the argv, which carries `-p <platform>`.
    for platform in tag.platforms:
        scratch = "{}/{}".format(work, slug(platform))
        out = mctx.path(scratch + "/out")
        built = vendor_args(struct(
            tier = tier,
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
        argv = built.args + ["--manifest-only"]
        env = manifest_env(str(mctx.path(scratch + "/home")), config, tag.no_config, policy.allow_unverified, policy.allow_yanked, trusted_root)
        run_ocx(mctx, binary, argv, env, "ocx vendor --manifest-only for '{}'".format(platform), host.is_windows)
        parsed = parse_manifest(mctx.read(out.get_child("manifest.json"), watch = "no"))
        if parsed.error:
            fail(parsed.error)
        tools[platform] = [[t.name, t.kind] for t in parsed.manifest.tools]
        if available == None:
            available = parsed.manifest.available_platforms
            err = hub_platform_error(tag.platforms, available)
            if err:
                fail(err)
    return struct(available_platforms = available, tools = tools)

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

    seen = {"ocx_tool": True}
    host = host_info(module_ctx.os.name, module_ctx.os.arch)
    binary = []  # fetched at most once, and only when a fact misses
    new_facts = {}
    reproducible = True

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

                lock_text = module_ctx.read(tag.ocx_lock) if tier == "project" else ""
                fact_tag = _tag_struct(tier, tag, lock_text)
                key = fact_key(fact_tag)
                stored = module_ctx.facts[key] if key in module_ctx.facts else None

                if fact_cacheable(fact_tag) and fact_hit(fact_tag, stored):
                    value = stored
                else:
                    if not binary:
                        binary.append(fetch_ocx_binary(module_ctx, version, triple, dist_manifest))
                    computed = _manifest_facts(module_ctx, binary[0], host, policy, tier, tag, lock_text)
                    value = fact_value(fact_tag, computed.available_platforms, computed.tools)
                if fact_cacheable(fact_tag):
                    new_facts[key] = value
                else:
                    reproducible = False

                fact = fact_decode(value)
                if fact.error:
                    fail(fact.error)
                err = hub_platform_error(tag.platforms, fact.available_platforms)
                if err:
                    fail(err)

                sets = {}
                names = {}
                for platform in tag.platforms:
                    rows = fact.tools.get(platform)
                    if rows == None:
                        fail("rules_ocx: the recorded fact of '{}' has no tools for '{}'; run `bazel mod deps --lockfile_mode=update`".format(tag.name, platform))
                    for row in rows:
                        names[row[0]] = True
                    ocx_set_repo(
                        name = repos[platform],
                        tier = tier,
                        platform = platform,
                        ocx_toml = tag.ocx_toml if tier == "project" else None,
                        ocx_lock = tag.ocx_lock if tier == "project" else None,
                        groups = tag.groups if tier == "project" else [],
                        bindings = tag.bindings if tier == "project" else [],
                        package = tag.package if tier == "package" else "",
                        index = tag.index if tier == "package" else None,
                        blob_dirs = tag.blob_dirs,
                        expected_tools = ["{}:{}".format(row[0], row[1]) for row in rows],
                        expected_available_platforms = fact.available_platforms,
                        config = tag.config,
                        no_config = tag.no_config,
                        **policy_kwargs(policy)
                    )
                    sets[platform] = "@{}//:toolchain_impl".format(repos[platform])
                ocx_hub_repo(
                    name = tag.name,
                    sets = sets,
                    tools = sorted(names.keys()),
                )

    # No use_repo validation (root_module_direct_deps): the same extension is
    # commonly used through both a dev and a non-dev usage, and tags carry no
    # dev marker to attribute repos correctly.
    return module_ctx.extension_metadata(reproducible = reproducible, facts = new_facts)

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
