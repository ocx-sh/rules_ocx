# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Build rules over a vendored tool set: the set, its toolchain, and one tool."""

visibility(["//ocx", "//ocx/tests"])

# A plain FilesToRunProvider would not do: the sidecar File is needed to link
# `<name>.direct`.
OcxSetInfo = provider(
    doc = "The files and tools of one platform's vendored set.",
    fields = {
        "files": "depset of every file of the set",
        "runfiles": "runfiles of the whole set",
        "tools": "dict: tool name -> struct(launcher = File, sidecar = File)",
    },
)

def _package_rel(ctx, file):
    """The path of a source file of this package, relative to the package."""
    short = file.short_path
    if ctx.label.workspace_name:
        short = short[len("../" + ctx.label.workspace_name + "/"):]
    return short[len(ctx.label.package + "/"):] if ctx.label.package else short

def _ocx_set_impl(ctx):
    by_path = {_package_rel(ctx, f): f for f in ctx.files.srcs}
    outputs = []

    # Links are declared here, in the set's own package; never `root_symlinks`
    # of another repository's rule (it crashes Bazel 9.2.0 in the exec config).
    for path, target in ctx.attr.links.items():
        link = ctx.actions.declare_symlink(path)
        ctx.actions.symlink(output = link, target_path = target)
        outputs.append(link)

    # A reserved file was stashed under a name Bazel accepts; declare it back at
    # its original path so the runfiles tree holds it where the launcher expects.
    for stash, original in ctx.attr.reserved.items():
        if stash not in by_path:
            fail("{}: reserved stash '{}' is not in srcs".format(ctx.label, stash))
        restored = ctx.actions.declare_file(original)
        ctx.actions.symlink(output = restored, target_file = by_path[stash])
        outputs.append(restored)

    tools = {}
    for name, pair in ctx.attr.tools.items():
        if len(pair) != 2 or pair[0] not in by_path or pair[1] not in by_path:
            fail("{}: tool '{}' needs a launcher and a sidecar in srcs, got {}".format(ctx.label, name, pair))
        tools[name] = struct(launcher = by_path[pair[0]], sidecar = by_path[pair[1]])

    files = depset(ctx.files.srcs + outputs)
    runfiles = ctx.runfiles(files = ctx.files.srcs + outputs)
    return [
        DefaultInfo(files = files, runfiles = runfiles),
        OcxSetInfo(tools = tools, files = files, runfiles = runfiles),
    ]

ocx_set = rule(
    implementation = _ocx_set_impl,
    doc = "Every file of one vendored set, with its declared links and restored reserved files as runfiles.",
    attrs = {
        "links": attr.string_dict(doc = "Declared link path -> target."),
        "reserved": attr.string_dict(doc = "Stash path `_ocx_reserved/<n>` -> original path."),
        "srcs": attr.label_list(allow_files = True, doc = "File and directory labels of the vendored tree."),
        "tools": attr.string_list_dict(doc = "Tool name -> [launcher path, sidecar path]."),
    },
    provides = [OcxSetInfo],
)

def _ocx_set_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(ocx_set = ctx.attr.set[OcxSetInfo])]

ocx_set_toolchain = rule(
    implementation = _ocx_set_toolchain_impl,
    doc = "Exposes an `ocx_set` as a toolchain of the hub's `toolchain_type`.",
    attrs = {"set": attr.label(providers = [OcxSetInfo], doc = "The `ocx_set` of this platform.")},
)

def make_ocx_tool_rule(toolchain_type):
    """Creates the `ocx_tool` rule bound to one hub's toolchain type.

    A rule's `toolchains = ["//:toolchain_type"]` is resolved against the
    repository that defines the rule, not the one that instantiates it, so a
    single `ocx_tool` in rules_ocx cannot serve many hubs (proved on Bazel
    9.2.0). Each hub's generated `.bzl` calls this with its own
    `Label("//:toolchain_type")`.

    The rule is executable; attr `tool` (mandatory) names the tool. It outputs
    symlinks `<name>` and `<name>.direct`.

    Args:
        toolchain_type: a Label of the hub's `toolchain_type`, created in the
            hub's own `.bzl` so that it resolves in the hub.

    Returns:
        the rule.
    """

    def _ocx_tool_impl(ctx):
        info = ctx.toolchains[toolchain_type].ocx_set
        tool = info.tools.get(ctx.attr.tool)
        if not tool:
            fail("{}: the selected set holds no tool '{}' (it has: {})".format(ctx.label, ctx.attr.tool, ", ".join(sorted(info.tools))))

        # Beside each other in this package: the launcher finds `<name>.direct`
        # next to the path it was started by. A Windows launcher keeps
        # its `.exe`; its sidecar does not.
        suffix = ".exe" if tool.launcher.basename.endswith(".exe") else ""
        exe = ctx.actions.declare_file(ctx.attr.tool + suffix)
        ctx.actions.symlink(output = exe, target_file = tool.launcher, is_executable = True)
        sidecar = ctx.actions.declare_file(ctx.attr.tool + ".direct")
        ctx.actions.symlink(output = sidecar, target_file = tool.sidecar)
        return [DefaultInfo(
            executable = exe,
            files = depset([exe, sidecar]),
            runfiles = info.runfiles.merge(ctx.runfiles(files = [exe, sidecar])),
        )]

    return rule(
        implementation = _ocx_tool_impl,
        doc = "One tool of the toolchain-selected set: symlinks `<name>` and `<name>.direct`.",
        attrs = {"tool": attr.string(mandatory = True, doc = "Tool name.")},
        executable = True,
        toolchains = [config_common.toolchain_type(toolchain_type, mandatory = True)],
    )
