"""Runs a hub tool in an action, with runfiles trees on or off, and records how it ended.

A vendored launcher finds its root in the runfiles tree of the action that
starts it, or, without a tree, in the runfiles manifest Bazel writes beside the
tool. The rule exists so that a test can show the same tool in both
configurations in one build, without a second Bazel invocation: Windows has no
runfiles tree unless `--enable_runfiles` is set.
"""

def _transition_impl(_settings, attr):
    # A tri-state option, set by its spelling on the command line.
    return {"//command_line_option:enable_runfiles": "yes" if attr.runfiles else "no"}

_runfiles_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = ["//command_line_option:enable_runfiles"],
)

# Arguments: the tool path, the output file, 1 to start the tool by its bare name through PATH.
# The action never fails: the test reads what it recorded.
_COMMAND = """
tool="$1"; out="$2"
if [ "$3" = 1 ]; then
    dir="$PWD/${tool%/*}"
    PATH="$dir:$PATH" "${tool##*/}" --version > "$out" 2>&1
else
    "$tool" --version > "$out" 2>&1
fi
echo "exit=$?" >> "$out"
# Without a tree the directory may still exist, holding only MANIFEST and an empty `_main`.
if [ -e "$tool.runfiles/_repo_mapping" ]; then
    echo "tree=yes" >> "$out"
else
    echo "tree=no" >> "$out"
fi
for f in "$tool.runfiles/MANIFEST" "$tool.runfiles_manifest"; do
    [ -f "$f" ] && echo "manifest=${f##*/}" >> "$out"
    [ -f "$f" ] && grep -m 3 '[.]launch$' "$f" | sed 's/^/launch_line=/' >> "$out"
done
for f in "${tool%/*}"/*.launch; do
    [ -f "$f" ] && echo "beside=${f##*/}" >> "$out"
done
exit 0
"""

def _launcher_status_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run_shell(
        outputs = [out],
        tools = [ctx.executable.tool],
        command = _COMMAND,
        arguments = [ctx.executable.tool.path, out.path, "1" if ctx.attr.by_name else "0"],
        mnemonic = "LauncherStatus",
    )
    return [DefaultInfo(files = depset([out]))]

launcher_status = rule(
    implementation = _launcher_status_impl,
    cfg = _runfiles_transition,
    attrs = {
        "by_name": attr.bool(
            default = False,
            doc = "Start the tool by its bare name, found through PATH, instead of by its path.",
        ),
        "runfiles": attr.bool(
            mandatory = True,
            doc = "Whether the action's configuration builds runfiles trees.",
        ),
        "tool": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "A hub tool to start.",
        ),
    },
    doc = "Output `<name>.txt`: what the tool printed, then `exit=<code>`, `tree=yes|no`, the runfiles " +
          "manifest files beside the tool with their `.launch` lines, and the records beside the tool.",
)
