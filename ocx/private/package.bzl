# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Package-tier repository rules: provision a single OCI package via the ocx
CLI (`package install` → `package which` → `package env`), plus the
multi-platform hub that select()s between per-platform repos."""

load(":platforms.bzl", "host_info", "ocx_platform_constraints", "os_arch", "slug")
load(
    ":repo_utils.bzl",
    "CONFIG_ATTRS",
    "EAGER_LAZY_MODE",
    "bat_value",
    "check_bin_names",
    "decode_json",
    "discover_bins",
    "is_absolute_path",
    "make_ocx_env",
    "ocx_bin",
    "render_env_bzl",
    "render_launchers_build",
    "render_lazy_launcher",
    "rlocation_path",
    "run_ocx",
    "sh_quote",
    "stage_lazy_config",
    "write_launchers",
)

visibility(["//ocx", "//ocx/tests"])

def _lazy_package(ctx, host, pkg):
    """Renders text-only launchers deferring `ocx package install` to first use.

    The fetch touches neither the network nor the ocx binary (POSIX): each
    launcher embeds the digest-pinned reference and re-enters
    `ocx package exec`, which auto-installs missing content. The digest in
    the script text is the action-key identity — tool content never becomes
    a Bazel input.
    """
    if ctx.attr.isolated_home:
        fail("rules_ocx: bins (lazy provisioning) is incompatible with isolated_home — " +
             "the store must be resolvable on whatever machine executes the launcher")
    if ctx.attr.index:
        fail("rules_ocx: bins (lazy provisioning) cannot use an index snapshot — the snapshot " +
             "resolves at fetch time only; pin the digest via `pins` or an '@sha256:' reference")
    if "@sha256:" not in pkg:
        fail(("rules_ocx: lazy package '{}' must be digest-pinned — the digest is the only " +
              "action-key identity when content is deferred; add the platform to `pins` or " +
              "use an '@sha256:' reference").format(pkg))
    check_bin_names(ctx.attr.bins)
    staged = stage_lazy_config(ctx, host.is_windows)
    ext = ".bat" if host.is_windows else ".sh"

    # The POSIX arm sh_quote()s this; the Batch arm has to refuse instead,
    # because a literal quote closes the region with no in-place escape and
    # cmd.exe then reads `&` as a statement separator. `ocx.package` is not
    # root-only, so this string reaches us from any module in the graph.
    safe_pkg = bat_value(pkg) if host.is_windows else None
    if host.is_windows and safe_pkg == None:
        fail(("rules_ocx: refusing to render a lazy launcher for package '{}' — a literal " +
              "quote in the reference has no escape inside a batch file. Use a reference " +
              "without one.").format(pkg))
    for name in ctx.attr.bins:
        if host.is_windows:
            command = ['"{}"'.format(ocx_bin(ctx)), "package", "exec", '"{}"'.format(safe_pkg)]
        else:
            command = ['"$(rlocation {})"'.format(rlocation_path(ctx.attr.ocx)), "package", "exec", sh_quote(pkg)]
        command += ["--", name]
        ctx.file(
            "launchers/" + name + ext,
            render_lazy_launcher(command, host.is_windows, exports = staged.exports),
            executable = True,
        )
    data = [str(ctx.attr.ocx)] + staged.data
    if not host.is_windows:
        data.append("@bazel_tools//tools/bash/runfiles")
    ctx.file("BUILD.bazel", render_launchers_build(
        [struct(name = name, target = None) for name in ctx.attr.bins],
        host.is_windows,
        data = data,
    ))

def pinned_ref(package, pins, platform):
    """Applies the per-platform manifest pin for `platform`, if any.

    Args:
        package: the fallback reference 'registry/repo[:tag][@sha256:…]'.
        pins: {ocx platform key: 'sha256:…' manifest digest}.
        platform: the ocx platform key this repository provisions.

    Returns:
        the reference to install.
    """
    pin = pins.get(platform, "")
    if not pin:
        return package
    if not pin.startswith("sha256:"):
        fail("rules_ocx: pins[\"{}\"] must be a 'sha256:…' manifest digest, got '{}'".format(platform, pin))
    return package.split("@")[0] + "@" + pin

def resolve_platforms(name, platforms, aliases):
    """Validates aliases and maps each declared platform to its slug + real platform.

    Every `aliases` key must be a declared platform; its value is the real ocx
    platform sent to `-p`. Two declared platforms reducing to the same slug is an
    error (they would collide on repo/config_setting names).

    Args:
        name: the ocx.package tag name (for error messages).
        platforms: the declared target platform keys.
        aliases: {declared platform key: real ocx platform sent to `-p`}.

    Returns:
        struct(error = "" | message, platforms = {slug: struct(declared, real)}).
    """
    for key in aliases:
        if key not in platforms:
            return struct(
                error = ("rules_ocx: ocx.package '{}': platform_aliases key '{}' is " +
                         "not one of platforms {}").format(name, key, platforms),
                platforms = {},
            )
    out = {}
    for p in platforms:
        s = slug(p)
        if s in out:
            return struct(
                error = ("rules_ocx: ocx.package '{}': platforms '{}' and '{}' both " +
                         "reduce to slug '{}' — rename one").format(name, out[s].declared, p, s),
                platforms = {},
            )
        out[s] = struct(declared = p, real = aliases.get(p, p))
    return struct(error = "", platforms = out)

def _ocx_package_repo_impl(ctx):
    host = host_info(ctx.os.name, ctx.os.arch)
    pkg = pinned_ref(ctx.attr.package, ctx.attr.pins, ctx.attr.platform or host.ocx_platform)
    if ctx.attr.bins:
        _lazy_package(ctx, host, pkg)
        return
    binary = ocx_bin(ctx)
    ctx.path(ctx.attr.ocx)  # fetch ordering
    ocx_env = make_ocx_env(ctx, host, ctx.attr.isolated_home)
    root_flags = []
    hints = {}
    if ctx.attr.index:
        index = ctx.path(ctx.attr.index)
        ctx.watch_tree(index)
        root_flags = ["--index", str(index), "--frozen"]
        hints[81] = ("'{}' is not in the committed index snapshot — refresh it: " +
                     "`ocx --index {} index update {}` and commit the result").format(
            pkg,
            index,
            ctx.attr.package.split("@")[0].split(":")[0],
        )
    json_pkg = root_flags + ["--format", "json", "package"]
    real = ctx.attr.resolved_platform or ctx.attr.platform
    platform_arg = ["-p", real] if real else []

    # ponytail: os/arch-only compare — a musl repo (real 'linux/amd64+libc.musl')
    # reads "runnable" on a glibc linux/amd64 host. Acceptable: the CLI resolves the
    # right leaf at run time; upgrade to feature-aware host matching only if a launcher
    # actually mis-selects.
    runnable = real == "" or os_arch(real) == host.ocx_platform

    stdout = run_ocx(
        ctx,
        binary,
        json_pkg + ["install"] + platform_arg + [pkg],
        ocx_env.env,
        "installing " + pkg,
        host.is_windows,
        hints = hints,
        retries = 2,
    )
    report = decode_json(stdout, "ocx package install")
    identifier = report.values()[0]["identifier"]
    if "@sha256:" not in pkg and not ctx.attr.index:
        # buildifier: disable=print
        print(("rules_ocx: '{}' ({}) resolved to '{}' — copy the digest into " +
               "ocx.package(pins = ...) for reproducibility").format(
            pkg,
            ctx.attr.platform or "host",
            identifier,
        ))

    stdout = run_ocx(
        ctx,
        binary,
        json_pkg + ["which"] + platform_arg + EAGER_LAZY_MODE + [pkg],
        ocx_env.env,
        "locating " + pkg,
        host.is_windows,
    )
    answer = decode_json(stdout, "ocx package which").values()[0]

    # `{"path", "kind"}`, not a bare string: a deferred tool has no package
    # directory yet, so ocx reports its shim tree and says which of the two it
    # answered with. Externally sourced like every other string parsed here and
    # checked before it becomes a symlink target, so a drifted report names the
    # pin to move instead of tracebacking out of ctx.symlink().
    root = answer["path"] if type(answer) == "dict" and type(answer.get("path")) == "string" else None
    if root == None or not is_absolute_path(root, host.is_windows):
        fail(("rules_ocx: ocx package which reported '{}' for '{}', not an absolute store " +
              "path — the pinned ocx CLI and rules_ocx disagree on the report shape. Move " +
              "DEFAULT_OCX_VERSION (ocx/private/versions.bzl) to an ocx release this " +
              "rules_ocx parses, or upgrade rules_ocx.").format(answer, pkg))

    # The whole reason ocx discriminates the two: a `shim` root holds `bin/`
    # launchers and no `content/`, so symlinking it would dangle. EAGER_LAZY_MODE
    # already outranks every ladder tier that could ask for one, which makes this
    # the assertion that the flag did its job — not a case to handle.
    if answer.get("kind") != "package":
        fail(("rules_ocx: ocx package which answered '{}' for '{}' with a '{}' directory, not a " +
              "package one — it holds generated launchers instead of the content/ this rule " +
              "symlinks. rules_ocx passes '--lazy-mode never' precisely so this cannot happen; " +
              "report it against rules_ocx with the pinned ocx version.").format(
            root,
            pkg,
            answer.get("kind"),
        ))

    stdout = run_ocx(
        ctx,
        binary,
        json_pkg + ["env"] + platform_arg + EAGER_LAZY_MODE + [pkg],
        ocx_env.env,
        "composing the environment of " + pkg,
        host.is_windows,
    )
    entries = decode_json(stdout, "ocx package env")["entries"]

    # The store is content-addressed and digest-pinned: symlinks into it are
    # stable for the lifetime of the pin.
    ctx.symlink(root + "/content", "content")
    if ctx.path(root + "/entrypoints").exists:
        ctx.symlink(root + "/entrypoints", "entrypoints")

    # Foreign platforms expose no launchers, so they skip the closure call too.
    discovered = struct(bins = [], scanned = [], rejected = [])
    if runnable:
        # `inspect --closure` spends its 65 on a closure conflict; the generic
        # hint names a lockfile this tier does not have.
        closure_hints = dict(hints)
        closure_hints[65] = ("the closure of '{}' conflicts — two packages in it declare the " +
                             "same entrypoint, or one repository resolved to two digests; run " +
                             "'ocx package inspect --closure {}' to see the pair").format(pkg, pkg)
        discovered = discover_bins(
            ctx,
            run_ocx(
                ctx,
                binary,
                json_pkg + ["inspect", "--closure"] + platform_arg + [pkg],
                ocx_env.env,
                "reading the declared surface of " + pkg,
                host.is_windows,
                hints = closure_hints,
            ),
            "ocx package inspect --closure",
            entries,
            host.is_windows,
        )
    write_launchers(ctx, discovered.bins, entries, ocx_env.home, str(binary), host.is_windows)
    ctx.file("env.bzl", render_env_bzl(entries, ocx_env.home, discovered.scanned, discovered.rejected))
    ctx.file("BUILD.bazel", render_launchers_build(
        discovered.bins,
        host.is_windows,
        extra = "\n".join([
            'exports_files(["env.bzl"])',
            "",
            "filegroup(",
            '    name = "content",',
            '    srcs = glob(["content/**"], allow_empty = True),',
            ")",
            "",
        ]),
    ))

ocx_package_repo = repository_rule(
    implementation = _ocx_package_repo_impl,
    doc = """Provisions a single OCX package from an OCI registry.

`//:content` is the package tree; every executable the package declares as
its public surface (`ocx package inspect --closure`) becomes a runnable
target `//:<name>` (host-platform repos only). A package shipping no
complete `binaries` metadata falls back to scanning the composed PATH, which
also exposes its private executables — `//:env.bzl`'s `OCX_SCANNED_PACKAGES`
names the packages that forced it. For reproducibility, commit an index
snapshot and reference it
via `index` (tags then resolve frozen from the snapshot), or pin
per-platform manifest digests via `pins` — plain floating tags resolve at
fetch time and log the resolved digest.

With `bins`, provisioning is lazy: nothing is installed at fetch time, and
each named executable becomes a launcher re-entering `ocx package exec` —
content materializes on first execution and never becomes a Bazel action
input (`//:content` is not available in lazy mode).""",
    attrs = CONFIG_ATTRS | {
        "bins": attr.string_list(
            doc = "Lazy provisioning: names of the executables to expose (not " +
                  "validated at fetch time). When set, nothing is installed during " +
                  "the fetch — each name becomes a launcher re-entering " +
                  "`ocx package exec`, keyed on the digest-pinned reference. " +
                  "Requires a digest-pinned identity (`pins` or '@sha256:'); " +
                  "incompatible with isolated_home and index.",
        ),
        "index": attr.label(
            doc = "Committed ocx index snapshot directory (created with " +
                  "`ocx --index <dir> index update <package>`). When set, tag " +
                  "resolution is frozen to the snapshot (`--index --frozen`): " +
                  "floating tags become reproducible until the snapshot is refreshed.",
        ),
        "isolated_home": attr.bool(
            default = False,
            doc = "Keep the ocx store inside this repository instead of the shared user OCX_HOME.",
        ),
        "ocx": attr.label(
            default = "@ocx_tool//:ocx",
            allow_single_file = True,
            doc = "The pinned ocx CLI binary.",
        ),
        "package": attr.string(
            mandatory = True,
            doc = "Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'.",
        ),
        "pins": attr.string_dict(
            doc = "ocx platform key -> 'sha256:…' manifest digest overriding the " +
                  "digest of `package` for that platform.",
        ),
        "platform": attr.string(
            doc = "ocx platform key ('linux/amd64', …) to provision for; empty = host.",
        ),
        "resolved_platform": attr.string(
            doc = "Real ocx platform sent to `-p` — lets a declared `platform` be aliased " +
                  "to a different real one (variant/feature build). Empty = derive from " +
                  "`platform`. Runnable-target gating compares its os/arch prefix to the " +
                  "host; `pins` still key on `platform`.",
        ),
    },
)

def _ocx_package_hub_impl(ctx):
    lines = ['package(default_visibility = ["//visibility:public"])', ""]
    seen = {}  # ",".join(constraints) -> real platform, for the duplicate guard
    for s, real in ctx.attr.platform_reals.items():
        constraints = ocx_platform_constraints(real)  # fails on unknown os/arch
        key = ",".join(constraints)
        if key in seen:
            fail(("rules_ocx: hub '{}': platforms '{}' and '{}' both derive constraints " +
                  "{} — a select() cannot tell them apart").format(
                ctx.attr.name,
                seen[key],
                real,
                constraints,
            ))
        seen[key] = real
        lines += [
            "config_setting(",
            '    name = "{}",'.format(s),
            "    constraint_values = [",
        ] + ['        "{}",'.format(c) for c in constraints] + [
            "    ],",
            ")",
            "",
        ]

    # Lazy hubs alias launchers (no content exists); eager hubs alias content.
    for target in ctx.attr.bins or ["content"]:
        lines += [
            "alias(",
            '    name = "{}",'.format(target),
            "    actual = select({",
        ]
        for s, repo in ctx.attr.platform_repos.items():
            lines.append('        ":{}": "@{}//:{}",'.format(s, repo, target))
        lines += [
            "    }),",
            ")",
            "",
        ]
    ctx.file("BUILD.bazel", "\n".join(lines))

ocx_package_hub = repository_rule(
    implementation = _ocx_package_hub_impl,
    doc = """Multi-platform hub for an ocx.package() with `platforms`.

`//:content` (or, with `bins`, each named launcher) select()s the
per-platform package repo matching the target platform — combine with a
platform transition to fetch foreign-platform tools (e.g. for container
images).""",
    attrs = {
        "bins": attr.string_list(
            doc = "Lazy mode: launcher names to alias instead of //:content.",
        ),
        "platform_reals": attr.string_dict(
            mandatory = True,
            doc = "repo slug -> real ocx platform, the source of each config_setting's " +
                  "Bazel constraint_values.",
        ),
        "platform_repos": attr.string_dict(
            mandatory = True,
            doc = "repo slug -> apparent name of the per-platform package repo.",
        ),
    },
)
