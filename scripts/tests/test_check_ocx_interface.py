#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
"""Self-test for check_ocx_interface.py. Run: python3 scripts/tests/test_check_ocx_interface.py

Each fixture is a one-file tree under a temp dir; the guard runs as a
subprocess so the exit code is the real one (a planted `env` call -> 1).
Every red case asserts the exact set of classes, so a wrong class is caught.
"""

import pathlib
import subprocess
import sys
import tempfile

GUARD = pathlib.Path(__file__).resolve().parent.parent / "check_ocx_interface.py"

CLEAN = '''"""Docstring may say ["--format", "json", "env"] and layers/ freely."""
# comment: ["--format", "json", "env"], metadata.json, x["env"]
def f(ctx, pkg, run_ocx, home):
    """Also a docstring: ocx env --pinned, home.get_child("layers")."""
    a = ["--format", "json", "vendor", "-o", "out"]
    b = ["--format", "json", "package", "vendor", "-o", "out"]
    c = pkg.entrypoints + pkg.dependencies + pkg.binaries
    d = "packages/foo/entrypoints/bar"  # manifest-relative: fine
    e = other["name"]
    g = ["info", "debug"]  # a list of words, no ocx evidence
    h = ["env"]
    i = ["--format", "json", "vendor", x[0], [1]]
    j = "my-install.json"
    k = home.get_child("vendor")
    run_ocx(ctx, "/bin/ocx", a, {}, "vendoring", False)
    return a, b, c, d, e, g, h, i, j, k
'''

RED = [
    # (classes, source)
    ({"subcommand"}, 'x = ["--format", "json", "env"]\n'),
    ({"subcommand"}, 'x = ["--format", "json"] + project + ["pull"]\n'),
    ({"subcommand"}, 'x = ["--format", "json", "package", "install"]\n'),
    ({"subcommand"}, 'x = [binary, "--project", toml, "exec", "--pinned"]\n'),
    ({"subcommand"}, 'x = [ocx_bin(ctx), "package", "exec", g(pkg)]\n'),
    ({"subcommand"}, 'x = [binary, "env"]\n'),
    ({"subcommand"}, 'x = ["--format", "json", "env", [1]]\n'),
    ({"subcommand"}, 'x = ["--format", "json", "env", y[0]]\n'),
    ({"subcommand"}, 'a = ["--format", "json"]\na.append("env")\n'),
    ({"subcommand"}, 'a = ["--format", "json"]\na.extend(["env"])\n'),
    ({"subcommand"}, 'run_ocx(ctx, "env", "--pinned")\n'),
    ({"subcommand"}, 'run_ocx(ctx, "/ocx", ["install", "pkg"], {}, "x", False)\n'),
    ({"subcommand"}, 'ctx.execute(["sh", "-c", "ocx env --pinned"])\n'),
    ({"subcommand"}, 'rctx.execute(["sh", "-c", "ocx --format json inspect --closure"])\n'),
    ({"subcommand"}, 'def f():\n    """doc"""\n    module_ctx.execute(["sh", """ocx env --pinned"""])\n'),
    ({"home-path"}, 'x = home + "/layers/abc"\n'),
    ({"home-path"}, 'x = "metadata.json"\n'),
    ({"home-path"}, 'x = "blobs/sha256"\n'),
    ({"home-path"}, 'x = home + "/layers"\n'),
    ({"home-path"}, 'x = home.get_child("layers")\n'),
    ({"home-path"}, 'x = home.get_child("packages")\n'),
    ({"home-path"}, 'x = ocx_home + "/packages/foo"\n'),
    ({"home-path"}, 'x = ocx_home.get_child(\n    "symlinks",\n)\n'),
    ({"home-path"}, 'a = "packages/x"; b = home.get_child("packages")\n'),
    ({"metadata"}, 'x = data["entrypoints"]\n'),
    ({"metadata"}, 'x = data.get("dependencies")\n'),
    ({"metadata"}, 'x = data["env"]\n'),
    ({"metadata"}, 'x = f(a)["env"]\n'),
    ({"metadata"}, 'x = data.get("binaries") or data["binaries"]\n'),
    ({"metadata"}, 'x = data.pop("env")\n'),
    ({"metadata"}, 'x = "entrypoints" in data\n'),
]

GREEN_EXTRA = [
    'run_ocx(ctx, "/ocx", ["--format", "json", "vendor"], {}, "x", False, hints = {1: "run ocx lock"})\n',
    'fail("run \'ocx lock\' next to x")\n',
    'x = "ocx env --pinned"\n',
    'rule(attrs = {"a": attr.string(doc = "calls ocx package exec")})\n',
    'a = "packages/x"; b = home.get_child("vendor")\n',  # the green half of the red pair above
    'x = "my-metadata.json"\n',
    'x = ["env"]\n',
    'def run_ocx(ctx, binary, args):\n    return args\n',
]


SH = "ocx/private/update.sh.tpl"
BAT = "ocx/private/update.bat.tpl"
# the two argv forms of DP-44, as the update programs write them
SH_ALLOWED = [
    'run_ocx "$d_name" "$ocx" --project "$copy/ocx.toml" update --no-pull "$@"\n',
    'run_ocx "$d_name" "$ocx" --project "$copy/ocx.toml" update --no-pull -g "$g"\n',
    'run_ocx "$d_name" "$ocx" --index "$dest" index update "$d_id"\n',
    'exec "$ocx" "$@"\n',
    '# ocx update is the command this program runs\n',
    "say 'rules_ocx: @rules_ocx//:update takes names only; pass ocx update arguments to @<name>//:update'\n",
    'ocx_dir=$(dirname "$ocx")\n',
    '"$ocx" package vendor -o out\n',
]
SH_RED = [
    '"$ocx" install x\n',
    '"$ocx" update\n',
    '"$ocx" --project "$p/ocx.toml" update\n',
    '"$ocx" --project "$p/ocx.toml" update -g x --no-pull\n',
    '"$ocx" --no-pull update\n',
    '"$ocx" index update x\n',
    '"$ocx" --index "$d" index list\n',
    '"$ocx" --index "$d" index\n',
    '"${ocx}" exec -- true\n',
    'run_ocx "$n" "$ocx" --project "$p" package exec x\n',
    'say a; "$ocx" --format json env\n',
]
BAT_ALLOWED = [
    '"%OCX%" --project "%SCRATCH%\\ocx.toml" update --no-pull %UARGS%\r\n',
    '"%OCX%" --index "%DEST%" index update "%D_ID%"\r\n',
    '"%ocx%" --project "%S%\\ocx.toml" update --no-pull\r\n',
    'rem ocx update is what this runs\r\n',
    ':: ocx install is not run\r\n',
    '>&2 echo rules_ocx: pass ocx update arguments to the hub\r\n',
    'set "OCX=C:\\x\\ocx.exe"\r\n',
]
BAT_RED = [
    '"%OCX%" install x\r\n',
    '"%OCX%" update\r\n',
    '"%OCX%" --project "%S%\\ocx.toml" update\r\n',
    '"%OCX%" index update x\r\n',
    'ocx.exe exec -- true\r\n',
    'echo x & "%OCX%" install y\r\n',
    '%OCX% --index "%D%" index list\r\n',
]


def run(files):
    """files: {relative path: source} -> (exit code, stdout, stderr)."""
    with tempfile.TemporaryDirectory() as d:
        for rel, source in files.items():
            p = pathlib.Path(d) / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(source, encoding="utf-8")
        r = subprocess.run([sys.executable, str(GUARD), d], capture_output=True, text=True, check=False)
        return r.returncode, r.stdout, r.stderr


def _readable(f):
    try:
        f.read_text(encoding="utf-8")
    except OSError:
        return False
    return True


def classes(out):
    return {line.split(": ")[1] for line in out.splitlines()}


def main():
    one = "ocx/private/x.bzl"
    code, out, _ = run({one: CLEAN})
    assert code == 0 and out == "", f"clean fixture flagged: {out}"
    for src in GREEN_EXTRA:
        code, out, _ = run({one: src})
        assert code == 0, f"{src!r} flagged: {out}"
    for want, src in RED:
        code, out, _ = run({one: src})
        assert code == 1, f"{src!r} not flagged"
        assert classes(out) == want, f"{src!r}: want {want}, got {out!r}"
        if src.count("\n") == 1:
            assert out.startswith(f"{one}:1: "), out
    # templates: scanned like .bzl, but only the two update programs may hold the two DP-44 forms
    tpl_clean = {one: "x = 1\n"}
    for rel, body in ((SH, SH_ALLOWED), (BAT, BAT_ALLOWED)):
        for src in body:
            code, out, _ = run({**tpl_clean, rel: src})
            assert code == 0, f"{rel}: {src!r} flagged: {out}"
    for rel, body in ((SH, SH_RED), (BAT, BAT_RED)):
        for src in body:
            code, out, _ = run({**tpl_clean, rel: src})
            assert code == 1 and classes(out) == {"subcommand"} and out.startswith(f"{rel}:1: "), (rel, src, code, out)
    # the allowance is by exact path: the same allowed line elsewhere is red, and a file that is no .tpl is not scanned
    for rel, src, want in (
        ("ocx/private/other.tpl", SH_ALLOWED[0], 1),
        ("ocx/private/other.tpl", SH_ALLOWED[2], 1),
        ("ocx/private/other.tpl", BAT_ALLOWED[0], 1),
        ("ocx/other/update.sh.tpl", SH_ALLOWED[0], 1),
        ("ocx/private/update.sh.tpl.bak", SH_ALLOWED[0], 0),
    ):
        code, out, _ = run({**tpl_clean, rel: src})
        assert code == want, f"{rel}: {src!r}: want {want}, got {code} {out}"
    code, out, _ = run({one: 'x = [binary, "--project", toml, "update", "--no-pull"]\n'})
    assert code == 1 and classes(out) == {"subcommand"}, out  # a .bzl keeps today's rule
    code, out, _ = run({SH: SH_ALLOWED[0]})
    assert code == 0, out  # a tree with a template and no .bzl still reads
    # class 3 is waived for the one parse surface only; classes 1 and 2 still apply there
    exempt = "ocx/private/vendor_manifest.bzl"
    line = 'x = raw.get("entrypoints", [])\n'
    code, out, _ = run({exempt: line})
    assert code == 0, f"exempt file flagged: {out}"
    code, out, _ = run({"ocx/private/other.bzl": line})
    assert code == 1 and classes(out) == {"metadata"}, out
    code, out, _ = run({exempt: line + 'y = ["--format", "json", "env"]\n' + 'z = home + "/layers"\n'})
    assert code == 1 and classes(out) == {"subcommand", "home-path"}, out
    # unbalanced brackets: a parse finding naming the opener's line
    for src, ln in (('x = ["--format", "json", "env"\n', 1), ('y = 1\nctx.execute("ocx env"\n', 2), ('x = 1)\n', 1)):
        code, out, _ = run({one: src})
        assert code == 1 and classes(out) == {"parse"} and f":{ln}: parse:" in out, (src, out)
    # one finding per (line, class)
    code, out, _ = run({one: 'x = home + "/layers/x"\n'})
    assert out.count("\n") == 1, out
    # unreadable file: exit 2, not findings (skipped as root, where chmod 000 still reads)
    with tempfile.TemporaryDirectory() as d:
        f = pathlib.Path(d) / "ocx" / "x.bzl"
        f.parent.mkdir()
        f.write_text("x = 1\n", encoding="utf-8")
        f.chmod(0)
        try:
            if not _readable(f):
                r = subprocess.run([sys.executable, str(GUARD), d], capture_output=True, text=True, check=False)
                assert r.returncode == 2 and "cannot read" in r.stderr, (r.returncode, r.stderr)
        finally:
            f.chmod(0o644)
    # exit 2: a wrong or empty root never reads as green
    for files in ({}, {"other/x.bzl": "x = 1\n"}, {"ocx/README": "x"}, {"ocx/x.tpl.txt": "x"}):
        code, out, err = run(files)
        assert code == 2 and out == "" and "wrong ROOT" in err, (files, code, err)
    code, _, err = run({one: "x = 1\n"})
    assert code == 0 and "read 1 files" in err, err
    print(f"ok: clean + {len(GREEN_EXTRA)} green + {len(RED)} red + templates ({len(SH_ALLOWED) + len(BAT_ALLOWED)} green, {len(SH_RED) + len(BAT_RED)} red) + 4 exit-2 cases")


if __name__ == "__main__":
    main()
