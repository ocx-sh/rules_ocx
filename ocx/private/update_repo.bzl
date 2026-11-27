# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""The `ocx_update` repository: a data plan and the program that reads it.

The rule writes `plan.txt`, one value per line, and one program per target
(`update.sh`, or `update.bat` on Windows) that reads it, so no tag value ever
becomes program text: the only values written into a program are the absolute
plan path, the absolute ocx path, a target index and the pinned env rows. It
declares one executable target per hub, `hub_<name>`, and `update` for all
declarations. Not reproducible: the plan holds absolute paths of this machine.
"""

load(":repo_utils.bzl", "OCX_ENV_CLASSES")

visibility(["//ocx", "//ocx/tests"])

UPDATE_SH_TEMPLATE = Label("//ocx/private:update.sh.tpl")
UPDATE_BAT_TEMPLATE = Label("//ocx/private:update.bat.tpl")

_ALNUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
_TAG_CHARS = _ALNUM + "._:/@+=,-"

def _e10(name, value, reason):
    return "rules_ocx: '{}': cannot write an update step for '{}': {}".format(name, value, reason)

def check_value(name, value, path = False):
    """Whether a value may reach the plan file (pure; E10).

    Tag values (hub names, identifiers, groups, bindings): first character
    `A-Za-z0-9`, then only `A-Za-z0-9._:/@+=,-`; no `..` segment; no userinfo,
    that is no `@` before the first `/`. A path may hold spaces and non-ASCII;
    only `"`, `%` and a newline are refused.

    Args:
        name: the declaration (hub) name, for the message.
        value: the value to check.
        path: True when the value is a file path.

    Returns:
        "" when the value is allowed, else
        `rules_ocx: '<name>': cannot write an update step for '<value>': <reason>`.
    """
    if path:
        for c, reason in [('"', "a path may not hold '\"'"), ("%", "a path may not hold '%'"), ("\n", "a path may not hold a newline")]:
            if c in value:
                return _e10(name, value, reason)
        return ""
    if not value:
        return ""
    if value[0] not in _ALNUM:
        return _e10(name, value, "the first character must be a letter or digit")
    for c in value.elems():
        if c not in _TAG_CHARS:
            return _e10(name, value, "the character '{}' is not allowed".format(c))
    if ".." in value.split("/"):
        return _e10(name, value, "it holds a '..' segment")
    if "/" in value and "@" in value.split("/")[0]:
        return _e10(name, value, "it holds userinfo (an '@' before the first '/')")
    return ""

def _flag(b):
    return "true" if b else "false"

def plan_content(declarations):
    """The `plan.txt` text (pure).

    Per declaration, one value per line in this fixed order: name, kind,
    main-repository flag (`true`/`false`), `write_path`, identifier, config,
    `no_config` (`true`/`false`), `allow_unverified`, `allow_yanked`,
    trusted root, the number of groups and each group, the number of bindings
    and each binding. An empty value is an empty line. No header, no
    separator: declarations follow one another.

    Args:
        declarations: list of struct(name, kind, main_repo, write_path,
            identifier, config, no_config, allow_unverified, allow_yanked,
            trusted_root, groups, bindings). `write_path` is
            `<package>/<name>` of the lock or snapshot, workspace-relative.

    Returns:
        the plan text, each line ending in a newline.
    """
    lines = []
    for d in declarations:
        lines += [d.name, d.kind, _flag(d.main_repo), d.write_path, d.identifier, d.config]
        lines += [_flag(d.no_config), _flag(d.allow_unverified), _flag(d.allow_yanked), d.trusted_root]
        lines += [str(len(d.groups))] + list(d.groups)
        lines += [str(len(d.bindings))] + list(d.bindings)
    return "".join([line + "\n" for line in lines])

def _refuse(error):
    return struct(error = error, exit_code = 64, selected = [], notices = [])

def select_declarations(declarations, target, args, workspace):
    """Decides what an update run touches, before anything runs (pure).

    Checks in this order: E9 (`workspace` is None), then for the all-declarations
    target E3 (an argument starting with `-`) and E1 (an argument that is no
    hub name), then E2 (a package hub with arguments). No names selects every
    declaration. E4 (kind `pinned`) and E5 (`main_repo` false) become notices
    and leave the declaration out of `selected`. No declaration at all is the
    notice `rules_ocx: no ocx declarations`, exit 0.

    Args:
        declarations: list of struct(name, kind, main_repo).
        target: "" for `@rules_ocx//:update`, else the hub name.
        args: list of argument strings.
        workspace: value of BUILD_WORKSPACE_DIRECTORY, or None.

    Returns:
        struct(error, exit_code, selected, notices). `error` is "" or the
        E1/E2/E3/E9 text (exit code 64); `selected` the names whose steps run,
        in name order; `notices` the E4/E5 lines, or the no-declaration line.
    """
    if not workspace:
        return _refuse("rules_ocx: run this target with bazel run")
    by_name = {d.name: d for d in declarations}
    names = sorted(by_name.keys())
    if target == "":
        for a in args:
            if a.startswith("-"):
                return _refuse("rules_ocx: @rules_ocx//:update takes declaration names only; pass ocx update arguments to @<name>//:update")
        for a in args:
            if a not in by_name:
                return _refuse("rules_ocx: no ocx declaration is named '{}'; known: {}".format(a, ", ".join(names)))
        wanted = sorted({a: True for a in args}.keys()) if args else names
    else:
        d = by_name.get(target)
        if d == None:
            return _refuse("rules_ocx: no ocx declaration is named '{}'; known: {}".format(target, ", ".join(names)))
        if d.kind != "project" and args:
            return _refuse("rules_ocx: '{}' is an ocx.package declaration; its update takes no arguments".format(target))
        wanted = [target]
    if not names:
        return struct(error = "", exit_code = 0, selected = [], notices = ["rules_ocx: no ocx declarations"])
    selected = []
    notices = []
    for n in wanted:
        d = by_name[n]
        if d.kind == "pinned":
            notices.append("rules_ocx: {}: pinned by digest in MODULE.bazel; edit the identifier to move it".format(n))
        elif not d.main_repo and d.kind == "project":
            notices.append("rules_ocx: {}: its ocx.lock is not in this workspace; update it in the module that holds it".format(n))
        elif not d.main_repo and d.kind == "index":
            notices.append("rules_ocx: {}: its index snapshot is not in this workspace; update it in the module that holds it".format(n))
        else:
            selected.append(n)
    return struct(error = "", exit_code = 0, selected = selected, notices = notices)

def _sh_quote(value):
    return "'" + value.replace("'", "'\\''") + "'"

def _fill(text, substitutions):
    """Replaces each placeholder once, never inside a value that was just inserted."""
    chunks = [(text, False)]
    for key, value in substitutions:
        parts = []
        for chunk, inserted in chunks:
            if inserted:
                parts.append((chunk, True))
                continue
            for i, piece in enumerate(chunk.split(key)):
                if i:
                    parts.append((value, True))
                parts.append((piece, False))
        chunks = parts
    return "".join([chunk for chunk, _ in chunks])

def _env_lines(windows):
    """The pinned and the hermetic rows of OCX_ENV_CLASSES, as program text.

    Returns:
        (pinned, hermetic): the lines that set each pinned row to its fixed
        value, and the lines that blank each row `no_config` blanks.
    """
    pinned = []
    hermetic = []
    for key, row in OCX_ENV_CLASSES.items():
        if row.cls == "pinned":
            pinned.append(('set "{}={}"' if windows else "export {}={}").format(key, row.value if windows else _sh_quote(row.value)))
        if row.hermetic:
            hermetic.append(('set "{}="' if windows else "export {}=''").format(key))
    return "\n".join(["  " + line for line in pinned]), "\n".join(["  " + line for line in hermetic])

_PROGRAM_BZL = """# Generated by ocx_update_repo.
def _impl(ctx):
    out = ctx.actions.declare_file("{}_program.{}".format(ctx.label.name, ctx.file.src.extension))
    ctx.actions.expand_template(template = ctx.file.src, output = out, substitutions = {}, is_executable = True)
    return [DefaultInfo(executable = out, files = depset([out]))]

ocx_update_program = rule(
    implementation = _impl,
    attrs = {"src": attr.label(allow_single_file = [".sh", ".bat"], mandatory = True)},
    executable = True,
)
"""

def in_main_repo(label):
    """Whether a declared lock or index file belongs to the main repository (pure).

    Only such a file may be written by the update program. The label's repository
    decides, not the module that declared it: a root module can name a file of a
    dependency, and `@@//:file` from any module names the main repository.

    Args:
        label: the `ocx_lock` or `index` label, or None for a kind without a file.

    Returns:
        True when `label` is None or its canonical repository name is empty.
    """
    return label == None or label.repo_name == ""

def _write_path(label):
    return label.name if not label.package else label.package + "/" + label.name

def _ocx_update_repo_impl(rctx):
    windows = "windows" in rctx.os.name.lower()
    ext = "bat" if windows else "sh"
    decoded = [json.decode(text) for text in rctx.attr.declarations]
    decoded = sorted(decoded, key = lambda d: d["name"])
    declarations = []
    for d in decoded:
        name = d["name"]
        label = rctx.attr.files.get(name + ":lock") if d["kind"] == "project" else (rctx.attr.files.get(name + ":index") if d["kind"] == "index" else None)
        if d["kind"] in ["project", "index"] and label == None:
            fail("rules_ocx: '{}': the {} declaration reached the update repository without its file".format(name, d["kind"]))
        config = rctx.attr.files.get(name + ":config")
        trusted_root = rctx.attr.files.get(name + ":trusted_root")
        declarations.append(struct(
            name = name,
            kind = d["kind"],
            main_repo = d["main_repo"],
            write_path = _write_path(label) if label != None else "",
            identifier = d["identifier"],
            config = str(rctx.path(config)) if config != None else "",
            no_config = d["no_config"],
            allow_unverified = d["allow_unverified"],
            allow_yanked = d["allow_yanked"],
            trusted_root = str(rctx.path(trusted_root)) if trusted_root != None else "",
            groups = d["groups"],
            bindings = d["bindings"],
        ))

    plan = str(rctx.path("plan.txt"))
    ocx = str(rctx.path(rctx.attr.ocx))
    for value in [plan, ocx]:
        error = check_value("ocx_update", value, True)
        if error:
            fail(error)
    for d in declarations:
        tags = [d.name, d.identifier] + list(d.groups) + list(d.bindings)
        paths = [d.write_path, d.config, d.trusted_root]
        for value, path in [(v, False) for v in tags] + [(v, True) for v in paths]:
            error = check_value(d.name, value, path)
            if error:
                fail(error)

    rctx.file("plan.txt", plan_content(declarations))
    pinned, hermetic = _env_lines(windows)
    template = rctx.read(rctx.path(UPDATE_BAT_TEMPLATE if windows else UPDATE_SH_TEMPLATE)).replace("\r\n", "\n")
    build = ['load(":program.bzl", "ocx_update_program")', ""]
    targets = [("update", 0)] + [("hub_" + d.name, i + 1) for i, d in enumerate(declarations)]
    for target, index in targets:
        text = _fill(template, [
            ("@PLAN@", plan if windows else _sh_quote(plan)),
            ("@OCX@", ocx if windows else _sh_quote(ocx)),
            ("@TARGET@", str(index)),
            ("@PINNED_ENV@", pinned),
            ("@HERMETIC_ENV@", hermetic),
        ])
        if windows:
            text = text.replace("\n", "\r\n")
        rctx.file("{}.{}".format(target, ext), text, executable = True)
        build += ["ocx_update_program(", "    name = {},".format(repr(target)), "    src = {},".format(repr("{}.{}".format(target, ext))), '    visibility = ["//visibility:public"],', ")", ""]
    rctx.file("program.bzl", _PROGRAM_BZL)
    rctx.file("BUILD.bazel", "\n".join(build))

ocx_update_repo = repository_rule(
    implementation = _ocx_update_repo_impl,
    doc = """The update programs of every declaration.

Writes `plan.txt` and one program per target (`update.sh`, or `update.bat` on
Windows) from the templates, and declares the executable targets `hub_<name>`
and `update`. Every tag value is rejected (E10) unless it is safe in the plan;
no tag value is written into a program.""",
    attrs = {
        "declarations": attr.string_list(
            doc = "One `json.encode`d object per declaration, with keys name, kind, main_repo (bool), identifier, no_config, allow_unverified, allow_yanked, groups, bindings.",
        ),
        "files": attr.string_keyed_label_dict(
            doc = "Keys `<name>:lock`, `<name>:index`, `<name>:config`, `<name>:trusted_root`.",
        ),
        "ocx": attr.label(
            mandatory = True,
            doc = "The ocx binary, `@ocx_tool//:ocx`; resolved with `rctx.path` only when the update is built.",
        ),
    },
)
