"""A repository rule that runs a tool of a vendored set while Bazel fetches.

The set repository of the host is the only one fetched: the label is read
from a string, so the other platforms' sets stay unfetched.
"""

def _host_platform(rctx):
    os_name = rctx.os.name.lower()
    os = "windows" if os_name.startswith("windows") else ("darwin" if os_name.startswith("mac") else "linux")
    arch = "arm64" if rctx.os.arch in ["aarch64", "arm64"] else "amd64"
    return "{}/{}".format(os, arch)

def _impl(rctx):
    platform = _host_platform(rctx)
    label = rctx.attr.tools.get(platform)
    if not label:
        fail("host_tool_version: no tool for platform '{}'".format(platform))

    # A label that names no file makes the execute below fail the fetch, so a
    # wrong path cannot pass as a tool that ran.
    tool = rctx.path(Label(label))
    result = rctx.execute([str(tool), "--version"])
    if result.return_code != 0:
        fail("{} --version exited {}: {}".format(tool, result.return_code, result.stderr))
    rctx.file("version.txt", result.stdout)
    rctx.file("BUILD.bazel", 'exports_files(["version.txt"])\n')

host_tool_version = repository_rule(
    implementation = _impl,
    attrs = {
        "tools": attr.string_dict(
            mandatory = True,
            doc = "Platform ('os/arch') to the label of the launcher file in that platform's set.",
        ),
    },
)
