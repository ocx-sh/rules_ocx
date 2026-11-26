# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Registry-facing rows and measures: V-10, V-15, V-25, V-57, V-71 (isolated-home half), V-31, V-65.
V-31 and V-65 write `<run-dir>/measures.json`, which R8 folds into RESULTS.md."""

from __future__ import annotations

import base64
import json
import re
from pathlib import Path

from conftest import BACKEND, REGISTRY, RUN, Workspace, assert_ok, credentials, ocx, output

CONFIG = BACKEND
MEASURES = RUN / "measures.json"


def _record(key: str, value) -> None:
    data = json.loads(MEASURES.read_text()) if MEASURES.exists() else {}
    data.setdefault(BACKEND, {})[key] = value
    MEASURES.write_text(json.dumps(data, indent=2, sort_keys=True))


def _files_holding(root: Path, needles: list[bytes]) -> list[str]:
    hits = []
    for p in root.rglob("*"):
        if p.is_file() and not p.is_symlink():
            try:
                data = p.read_bytes()
            except OSError:
                continue
            if any(n in data for n in needles):
                hits.append(str(p))
    return hits


def test_v10_private_fetch_leaves_no_secret(workspace: Workspace) -> None:
    creds = credentials()
    needles = [creds["password"].encode(), base64.b64encode(f"{creds['user']}:{creds['password']}".encode())]
    c = workspace.client("a")
    res = c.run("build", "@private//:secret", config=CONFIG, lockfile="update")
    assert_ok(res, "build the private tool")
    # Control: the scan does find the token where the harness put it (the client's docker config).
    assert _files_holding(c.home, needles), "the scan cannot see the token at all"
    places = [workspace.path / "MODULE.bazel.lock", *c.external("private_linux_amd64").parent.glob("*.marker"),
              c.external("private_linux_amd64"), c.external("private"), res.exec_log]  # fmt: skip
    hits = []
    for place in places:
        hits += _files_holding(place, needles) if place.is_dir() else ([str(place)] if any(n in place.read_bytes() for n in needles) else [])
    assert hits == []


def _is_tag_lookup(row: dict) -> bool:
    return "/manifests/1.0.0" in row["uri"] or "/tags/list" in row["uri"]


def test_v15_floating_tag_resolves_from_the_index(workspace: Workspace, log) -> None:
    index = workspace.path / "index"
    ocx(workspace.path.parent / f"{workspace.test_id}-indexhome", "--index", str(index), "index", "update", f"{REGISTRY}/rig/tool")
    (workspace.path / "BUILD.bazel").write_text((workspace.path / "BUILD.bazel").read_text() + '\nexports_files(["index"])\n')
    module = workspace.path / "MODULE.bazel"
    base = module.read_text()
    tag = f"{REGISTRY}/rig/tool:1.0.0"
    floating = f'\nocx.package(name = "floating", package = "{tag}", platforms = ["linux/amd64+libc.glibc"]{{}})\n'
    module.write_text(base + floating.format(""))
    # Controls, no index. Offline, ocx refuses the unpinned reference and names it (exit 81). Online it resolves the
    # tag from the registry, and the log shows that lookup: the witness below can see a lookup when there is one.
    offline = workspace.client("control-offline").run("query", "@@rules_ocx++ocx+floating//:all", "--repo_env=OCX_OFFLINE=1")
    assert offline.rc != 0 and "rig/tool:1.0.0" in offline.out, offline.out[-2000:]
    log.mark()
    online = workspace.client("control-online").run("query", "@@rules_ocx++ocx+floating//:all")
    assert_ok(online, "floating tag without an index, online")
    assert [r for r in log.registry() if _is_tag_lookup(r)], "control: the online resolution made no tag lookup"
    module.write_text(base + floating.format(', index = "//:index"'))
    log.mark()
    res = workspace.client("a").run("query", "@@rules_ocx++ocx+floating//:all")
    assert_ok(res, "floating tag with an index")
    assert [r["uri"] for r in log.registry() if _is_tag_lookup(r)] == []


def test_v25_no_author_env_syntax_reaches_the_rules(workspace: Workspace) -> None:
    c = workspace.client("a")
    res = c.run("build", "//:envtpl_run", config=CONFIG)
    assert_ok(res, "envtpl_run")
    assert output(c, "envtpl_run.txt").strip() == "envtpl"
    text = (c.external("envtpl_linux_amd64") / "manifest.json").read_text()
    values = re.findall(r'"value":\s*"([^"]*)"', text)
    assert [v for v in values if "@VENDOR_DIR@" in v], "control: the manifest holds no tokenised env value at all"
    assert [v for v in values if "${" in v] == []


def test_v57_set_with_no_linux_leaf_from_a_linux_client(workspace: Workspace) -> None:
    out = workspace.path / ".winonly-out"
    control = ocx(workspace.path.parent / f"{workspace.test_id}-vhome", "vendor", "-o", str(out), "-g", "winonly",
                  cwd=workspace.path / "winonly", check=False)  # fmt: skip
    assert control.returncode == 78 and "winonly" in control.stderr, (control.returncode, control.stderr[-1000:])
    res = workspace.client("a").run("query", "@winonly//:all", lockfile="update")
    assert_ok(res, "winonly hub")
    assert "windows_amd64" in res.out
    assert '"project|winonly|' in (workspace.path / "MODULE.bazel.lock").read_text()


def test_v71_isolated_home_ignores_a_tampered_client_home(workspace: Workspace) -> None:
    home = workspace.path.parent / f"{workspace.test_id}-clienthome"
    ocx(home, "package", "pull", "-p", "linux/amd64+libc.glibc", f"{REGISTRY}/rig/tool:1.0.0", check=True)
    tools = [p for p in (home / "home").rglob("bin/tool") if p.is_file()]
    assert tools, "no pulled tool to tamper with"
    for p in tools:
        p.chmod(0o755)
        p.write_bytes(b"#!/bin/sh\necho tampered\n")
    c = workspace.client("a")
    res = c.run("build", "//:tool_run", f"--repo_env=OCX_HOME={home / 'home'}", config=CONFIG)
    assert_ok(res, "tool_run with a tampered client home in the environment")
    assert output(c, "tool_run.txt").strip() == "tool platform=linux/amd64 libc=glibc"


def _ocx_spans(ws: Workspace, since: int) -> list[float]:
    spans, start = [], None
    for line in ws.ocx_calls()[since:]:
        kind, ts = line.split()[:2]
        if kind == "start":
            start = float(ts)
        elif start is not None:
            spans.append(float(ts) - start)
            start = None
    return spans


def test_v31_v65_measures(workspace: Workspace) -> None:
    c = workspace.client("a")
    # Priming fetch of a one-file set: it pays Bazel's startup, the module graph and Bazel registry files, the
    # extension's fact runs and `@ocx_tool`. None of that is the set rule's work, and none of it is in the next fetch.
    assert_ok(c.run("fetch", "--repo=@tools_linux_amd64_libc_musl"), "priming fetch of a small set")
    n = len(workspace.ocx_calls())
    small = c.run("fetch", "--repo=@tools_linux_amd64_libc_glibc")
    assert_ok(small, "fetch of a second small set")
    floor = small.seconds - sum(_ocx_spans(workspace, n))
    n = len(workspace.ocx_calls())
    fetch = c.run("fetch", "--repo=@big_linux_amd64")
    assert_ok(fetch, "fetch the 100000-file set")
    ocx_seconds = sum(_ocx_spans(workspace, n))
    files = sum(1 for p in c.external("big_linux_amd64").rglob("*") if p.is_file() or p.is_symlink())
    # V-65: the rule's own work (decode + BUILD generation + moves) is the second fetch minus its `ocx vendor` run.
    # What stays is Bazel's per-fetch cost for any set; the small set's own remainder is recorded as `floor_seconds`.
    _record("v65_big_set", {"files": files, "fetch_seconds": round(fetch.seconds, 1), "ocx_seconds": round(ocx_seconds, 1),
                            "rule_seconds": round(fetch.seconds - ocx_seconds, 1),
                            "floor_seconds": round(floor, 1)})  # fmt: skip
    batches = {}
    for kind in ("small", "big"):
        res = c.run("build", *[f"//:batch_{kind}_{i}" for i in range(5)], config=CONFIG)
        assert_ok(res, f"batch {kind}")
        batches[kind] = {"seconds": round(res.seconds, 1), "processes": res.processes()}
    _record("v31_batches", batches)
    assert files >= 100_000
