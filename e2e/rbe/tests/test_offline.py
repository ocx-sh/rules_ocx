# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Network blocked: a build from `bazel vendor`, an exported directory as blob_dirs, a blob cache as blob_dirs.

The offline leg runs Bazel in the compose `client` service (`network_mode: none`), with the run tree and the
checkout mounted at their host paths and the host's uid, so the same paths and files serve both sides."""

from __future__ import annotations

import os
import re
import shutil
import subprocess

import pytest
from conftest import OCX, OUTPUT_ROOT, RBE, REGISTRY, ROOT, RUN, Client, Workspace, assert_ok, container_bazel, ocx, sha256

PROJECT = os.environ.get("RIG_PROJECT", "rules-ocx-rig")


def offline(client: Client, host: Client, *args: str, timeout: int = 900) -> subprocess.CompletedProcess:
    """`bazel build` inside the network-less client container: local strategy, no remote, the same flags.

    It shares `host`'s repository cache, which holds the Bazel registry files and archives the host fetched
    (the container cannot reach bcr.bazel.build either), with the repo contents cache off: no set repository
    may come from a cache, only from the vendor directory or the blob directories under test.
    """
    client.repo_cache = host.repo_cache
    real_ocx = shutil.which(OCX) or OCX  # the counting wrapper execs it by its host path
    bazel_bin = container_bazel()
    mounts = {str(RUN), str(ROOT), str(OUTPUT_ROOT), os.path.dirname(bazel_bin),
              os.path.dirname(os.path.realpath(real_ocx))}  # fmt: skip
    argv = ["docker", "compose", "-f", str(RBE / "compose.yaml"), "-p", PROJECT, "--profile", "client", "run", "--rm",
            "--no-deps", "--user", f"{os.getuid()}:{os.getgid()}", "-w", str(client.ws.path)]  # fmt: skip
    for m in sorted(mounts):
        argv += ["-v", f"{m}:{m}"]
    for k, v in client.env().items():
        argv += ["-e", f"{k}={v}"]
    bazel = [bazel_bin, *client.startup()[1:], "build", f"--repository_cache={client.repo_cache}", "--repo_contents_cache=",
             "--lockfile_mode=update",
             f"--repo_env=OCX_INSTALL_BINARY={client.ws.ocx_binary}",
             f"--repo_env=OCX_INSTALL_BINARY_SHA256={sha256(client.ws.ocx_binary)}",
             f"--repo_env=OCX_INSECURE_REGISTRIES={REGISTRY}", "--repo_env=OCX_NO_CONFIG=1",
             "--spawn_strategy=local", "--disk_cache=", "--color=no", "--curses=no",
             "--extra_execution_platforms=//platforms:exec_glibc", *args]  # fmt: skip
    proc = subprocess.run([*argv, "client", *bazel], capture_output=True, text=True, timeout=timeout)
    subprocess.run([*argv, "client", bazel_bin, *client.startup()[1:], "shutdown"], capture_output=True, text=True, timeout=180)
    return proc


def _out(proc: subprocess.CompletedProcess) -> str:
    return "\n".join((proc.stdout + proc.stderr).splitlines()[-40:])


def test_build_from_bazel_vendor_with_network_blocked(workspace: Workspace) -> None:
    host = workspace.client("host")
    vendor = workspace.path / "vendor"
    assert_ok(host.run("vendor", f"--vendor_dir={vendor}", "//:tool_run", lockfile="update"), "bazel vendor")
    control = offline(workspace.client("offline-control"), host, "//:tool_run")
    out = control.stdout + control.stderr
    # Same signature as the blob_dirs control: the set fetch reached `ocx vendor` and the registry had no route.
    # Any other failure (docker, Bazel, the module registry) is not a control.
    assert control.returncode != 0 and "bcr.bazel.build" not in out and re.search(r"\(exit (69|75|81)\)", out), (
        "control: the network-less client must fail at the set fetch: " + _out(control)
    )
    res = offline(workspace.client("offline"), host, f"--vendor_dir={vendor}", "//:tool_run")
    assert res.returncode == 0, _out(res)


def _export_dir(ws: Workspace) -> str:
    # `--blob-dir` reads the export's `blobs/`; its root (`blobs/` + ocx-export.json) finds nothing (exit 79).
    ocx(ws.path.parent / f"{ws.test_id}-exphome", "export", "-o", str(ws.path / "export"), cwd=ws.path, auth=True)
    return "export/blobs"


def _blob_cache_dir(ws: Workspace) -> str:
    out = ws.path / ".probe"
    ocx(ws.path.parent / f"{ws.test_id}-cachehome", "--blob-cache-dir", str(ws.path / "blobs"), "vendor", "-o", str(out),
        "-p", "linux/amd64+libc.glibc", cwd=ws.path, auth=True)  # fmt: skip
    return "blobs"


@pytest.mark.parametrize("make", [_export_dir, _blob_cache_dir], ids=["v05-export", "v32-blob-cache"])
def test_blob_dirs_with_network_blocked(workspace: Workspace, make) -> None:
    name = make(workspace)
    (workspace.path / "BUILD.bazel").write_text((workspace.path / "BUILD.bazel").read_text() + f'\nexports_files(["{name}"])\n')
    module = workspace.path / "MODULE.bazel"
    # Facts of every tag recorded online first: the extension evaluates all tags, the offline leg tests the fetch.
    # Its repository cache also gives the container the Bazel registry files it cannot fetch.
    host = workspace.client("host")
    assert_ok(host.run("build", "--nobuild", "//:tool_run", lockfile="update"), "facts and modules on the host")
    control = offline(workspace.client("offline-control"), host, "//:tool_run")
    out = control.stdout + control.stderr
    # run_ocx reports `failed (exit N)`: a registry miss, not a setup failure such as 127. The design names 69/81;
    # the ocx under test exits 75 (temporary failure) when the registry has no route, so 75 counts too.
    assert control.returncode != 0 and "bcr.bazel.build" not in out and re.search(r"\(exit (69|75|81)\)", out), _out(control)
    text = module.read_text()
    anchor = '    name = "tools",\n'
    assert anchor in text
    module.write_text(text.replace(anchor, anchor + f'    blob_dirs = ["//:{name}"],\n', 1))
    res = offline(workspace.client("offline"), host, "//:tool_run")
    assert res.returncode == 0, _out(res)
