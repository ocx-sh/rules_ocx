# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Package-tier repository rules: provision a single OCI package via the ocx
CLI (`package install` → `package which` → `package env`), plus the
multi-platform hub that select()s between per-platform repos."""

load(":platforms.bzl", "OCX_PLATFORMS", "host_info")
load(
    ":repo_utils.bzl",
    "decode_json",
    "make_ocx_env",
    "ocx_bin",
    "render_env_bzl",
    "render_launchers_build",
    "render_lazy_launcher",
    "rlocation_path",
    "run_ocx",
    "scan_bins",
    "write_launchers",
)

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
    ext = ".bat" if host.is_windows else ".sh"
    for name in ctx.attr.bins:
        if host.is_windows:
            command = ['"{}"'.format(ocx_bin(ctx)), "package", "exec", '"{}"'.format(pkg)]
        else:
            command = ['"$(rlocation {})"'.format(rlocation_path(ctx.attr.ocx)), "package", "exec", "'{}'".format(pkg)]
        command += ["--", name]
        ctx.file("launchers/" + name + ext, render_lazy_launcher(command, host.is_windows), executable = True)
    data = [str(ctx.attr.ocx)]
    if not host.is_windows:
        data.append("@bazel_tools//tools/bash/runfiles")
    ctx.file("BUILD.bazel", render_launchers_build(
        [struct(name = name, target = None) for name in ctx.attr.bins],
        host.is_windows,
        data = data,
    ))

def _platform_args(platform):
    return ["-p", platform] if platform else []

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

def _ocx_package_repo_impl(ctx):
    host = host_info(ctx.os.name, ctx.os.arch)
    pkg = pinned_ref(ctx.attr.package, ctx.attr.pins, ctx.attr.platform or host.ocx_platform)
    if ctx.attr.bins:
        _lazy_package(ctx, host, pkg)
        return
    binary = ocx_bin(ctx)
    ctx.path(ctx.attr.ocx)  # fetch ordering
    ocx_env = make_ocx_env(ctx, ctx.attr.isolated_home)
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
    runnable = ctx.attr.platform in ("", host.ocx_platform)

    stdout = run_ocx(
        ctx,
        binary,
        json_pkg + ["install"] + _platform_args(ctx.attr.platform) + [pkg],
        ocx_env.env,
        "installing " + pkg,
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
        json_pkg + ["which"] + _platform_args(ctx.attr.platform) + [pkg],
        ocx_env.env,
        "locating " + pkg,
    )
    root = decode_json(stdout, "ocx package which").values()[0]

    stdout = run_ocx(
        ctx,
        binary,
        json_pkg + ["env"] + _platform_args(ctx.attr.platform) + [pkg],
        ocx_env.env,
        "composing the environment of " + pkg,
    )
    entries = decode_json(stdout, "ocx package env")["entries"]

    # The store is content-addressed and digest-pinned: symlinks into it are
    # stable for the lifetime of the pin.
    ctx.symlink(root + "/content", "content")
    if ctx.path(root + "/entrypoints").exists:
        ctx.symlink(root + "/entrypoints", "entrypoints")

    bins = scan_bins(ctx, entries, host.is_windows) if runnable else []
    write_launchers(ctx, bins, entries, ocx_env.home, str(binary), host.is_windows)
    ctx.file("env.bzl", render_env_bzl(entries, ocx_env.home))
    ctx.file("BUILD.bazel", render_launchers_build(
        bins,
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

`//:content` is the package tree; every executable reachable through the
package environment becomes a runnable target `//:<name>` (host-platform
repos only). For reproducibility, commit an index snapshot and reference it
via `index` (tags then resolve frozen from the snapshot), or pin
per-platform manifest digests via `pins` — plain floating tags resolve at
fetch time and log the resolved digest.

With `bins`, provisioning is lazy: nothing is installed at fetch time, and
each named executable becomes a launcher re-entering `ocx package exec` —
content materializes on first execution and never becomes a Bazel action
input (`//:content` is not available in lazy mode).""",
    attrs = {
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
    },
)

def _ocx_package_hub_impl(ctx):
    lines = ['package(default_visibility = ["//visibility:public"])', ""]
    conditions = {}
    for platform, repo in ctx.attr.platform_repos.items():
        if platform not in OCX_PLATFORMS:
            fail("rules_ocx: unknown ocx platform '{}' (known: {})".format(
                platform,
                ", ".join(OCX_PLATFORMS.keys()),
            ))
        setting = platform.replace("/", "_")
        conditions[platform] = setting
        lines += [
            "config_setting(",
            '    name = "{}",'.format(setting),
            "    constraint_values = [",
        ] + ['        "{}",'.format(c) for c in OCX_PLATFORMS[platform]] + [
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
        for platform, repo in ctx.attr.platform_repos.items():
            lines.append('        ":{}": "@{}//:{}",'.format(conditions[platform], repo, target))
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
        "platform_repos": attr.string_dict(
            mandatory = True,
            doc = "ocx platform key -> apparent name of the per-platform package repo.",
        ),
    },
)
