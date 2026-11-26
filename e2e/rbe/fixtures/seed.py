# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Builds and pushes the rig's fixture packages into the rig registry with a given `ocx`.

Usage: seed.py --ocx <path> --registry 127.0.0.1:<port> --run-dir <dir>

Reads <run-dir>/state/credentials.json (written by gen_htpasswd.py), uses a scratch OCX_HOME under
<run-dir>/seed-home, and writes <run-dir>/fixtures.json: repository -> tag -> platform -> manifest digest.
Repositories under `rig/` allow anonymous pulls; `rig-private/` needs the login. Tools are static
binaries (built with the host gcc) or text files, so they run on an executor with no shell and no libc.
Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

# platform -> value of the tool's self-reported libc, for the glibc-vs-musl leaf witness. The binaries are
# all static builds of the host libc: the label is what the leaf declares, not what the bytes link.
TOOL_LEAVES = [
    "linux/amd64+libc.glibc",
    "linux/amd64+libc.musl",
    "linux/arm64+libc.glibc",
    "linux/arm64+libc.musl",
    "darwin/arm64",
    "windows/amd64",
]
BIG_FILES = 100_000
HELLO_C = '#include <stdio.h>\nint main(int c,char**v){puts(REPORT);return 0;}\n'

Build = Callable[[Path], None]


class Seeder:
    def __init__(self, ocx: str, registry: str, run_dir: Path) -> None:
        self.ocx, self.registry, self.run_dir = ocx, registry, run_dir
        self.home = run_dir / "seed-home"
        self.work = Path(tempfile.mkdtemp(prefix="seed-", dir=run_dir))
        self.digests: dict[str, dict[str, dict[str, str]]] = {}
        self._bins: dict[str, Path] = {}
        creds = json.loads((run_dir / "state" / "credentials.json").read_text(encoding="utf-8"))
        key = "OCX_AUTH_" + "".join(c if c.isalnum() else "_" for c in registry)
        shutil.rmtree(self.home, ignore_errors=True)
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(run_dir / "seed-user"),
            "OCX_HOME": str(self.home),
            "OCX_NO_CONFIG": "1",
            "OCX_INSECURE_REGISTRIES": registry,
            f"{key}_TYPE": "basic",
            f"{key}_USER": creds["user"],
            f"{key}_TOKEN": creds["password"],
        }
        Path(self.env["HOME"]).mkdir(parents=True, exist_ok=True)

    def run(self, *args: str) -> str:
        proc = subprocess.run(
            [self.ocx, *args], env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=900
        )
        if proc.returncode != 0:
            # argv carries no secret (credentials ride the environment), stderr is ocx's own message.
            raise SystemExit(f"ocx {' '.join(args)} exited {proc.returncode}: {proc.stderr.strip()}")
        return proc.stdout

    def static_bin(self, report: str) -> Path:
        """A static executable that prints `report`; cached per report string."""
        if report not in self._bins:
            src = self.work / "hello.c"
            src.write_text(HELLO_C, encoding="utf-8")
            out = self.work / f"bin{len(self._bins)}"
            proc = subprocess.run(
                ["gcc", "-static", "-Os", "-s", f"-DREPORT={json.dumps(report)}", str(src), "-o", str(out)],
                capture_output=True, text=True, encoding="utf-8", timeout=120,
            )  # fmt: skip
            if proc.returncode:
                raise SystemExit(f"gcc exited {proc.returncode}: {proc.stderr.strip()}")
            self._bins[report] = out
        return self._bins[report]

    def exe(self, dest: Path, report: str) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.static_bin(report), dest)
        dest.chmod(0o755)

    def publish(
        self,
        repo: str,
        tag: str,
        platform: str,
        build: Build,
        meta: dict,
        *,
        no_bin_scan: bool = False,
        compression: str = "default",
    ) -> None:
        slug = f"{repo.replace('/', '_')}-{tag}-{platform.replace('/', '_').replace('+', '_')}"
        pkg = self.work / f"pkg-{slug}"
        pkg.mkdir(parents=True)
        build(pkg)
        meta_in = self.work / f"meta-{slug}.json"
        meta_in.write_text(json.dumps({"type": "bundle", "version": 1, **meta}), encoding="utf-8")
        bundle = self.work / f"bundle-{slug}.tar.gz"
        scan = ["--no-bin-scan"] if no_bin_scan else []
        self.run(
            "--remote", "package", "create", "-m", str(meta_in), "-o", str(bundle), "-p", platform,
            "--compression-level", compression, *scan, str(pkg),
        )  # fmt: skip
        resolved = self.work / f"bundle-{slug}-metadata.json"
        if not resolved.exists():
            raise SystemExit(f"create wrote no sidecar next to {bundle}")
        out = self.run(
            "--format", "json", "package", "push", "-p", platform, "-m", str(resolved),
            "-i", f"{self.registry}/{repo}:{tag}", str(bundle),
        )  # fmt: skip
        report = json.loads(out)
        digests = report.get("platform_digests") or (
            {platform: report["manifest_digest"]} if "manifest_digest" in report else None
        )
        if not digests:
            raise SystemExit(f"push of {repo}:{tag} reported no digest: {out.strip()}")
        self.digests.setdefault(repo, {}).setdefault(tag, {}).update(digests)
        shutil.rmtree(pkg)
        bundle.unlink()
        print(f"pushed {repo}:{tag} {platform}", file=sys.stderr)

    def seed(self) -> None:
        path_env = {"key": "PATH", "type": "path", "value": "${installPath}/bin", "visibility": "public"}
        linux = "linux/amd64"

        # Multi-platform tool: the leaf's binary reports its own libc and platform (V-13).
        for plat in TOOL_LEAVES:
            libc = plat.partition("+libc.")[2] or "none"

            def tool(pkg: Path, plat: str = plat, libc: str = libc) -> None:
                report = f"tool platform={plat.partition('+')[0]} libc={libc}"
                if plat.startswith("windows"):
                    (pkg / "bin").mkdir()
                    (pkg / "bin" / "tool.cmd").write_text(f"@echo {report}\r\n", encoding="utf-8")
                elif plat.startswith("darwin"):
                    (pkg / "bin").mkdir()
                    (pkg / "bin" / "tool").write_text(f"#!/bin/sh\necho {report}\n", encoding="utf-8")
                    (pkg / "bin" / "tool").chmod(0o755)
                else:
                    self.exe(pkg / "bin" / "tool", report)

            self.publish("rig/tool", "1.0.0", plat, tool, {"env": [path_env]})

        # Same tool names, other bytes: a lock edit that keeps every tool name (V-55).
        for plat in TOOL_LEAVES[:2]:
            report = f"tool 1.0.1 platform={plat.partition('+')[0]} libc={plat.partition('+libc.')[2]}"
            self.publish("rig/tool", "1.0.1", plat, lambda p, r=report: self.exe(p / "bin" / "tool", r), {"env": [path_env]})

        # cmake and ccache are unrelated packages: only the workspace's group puts them together (V-41).
        self.publish("rig/ccache", "1.0.0", linux, lambda p: self.exe(p / "bin" / "ccache", "ccache"), {"env": [path_env]})
        self.publish("rig/cmake", "1.0.0", linux, lambda p: self.exe(p / "bin" / "cmake", "cmake"), {"env": [path_env]})

        def links(pkg: Path) -> None:
            self.exe(pkg / "bin" / "tool", "links")
            (pkg / "bin" / "tool-alias").symlink_to("tool")  # relative file link
            (pkg / "lib").mkdir()
            (pkg / "lib" / "libx.so.1").write_text("lib\n", encoding="utf-8")
            (pkg / "lib" / "libx.so").symlink_to("libx.so.1")
            (pkg / "data").mkdir()
            (pkg / "data" / "info.txt").write_text("info\n", encoding="utf-8")
            (pkg / "share").symlink_to("data")  # relative link to a directory

        self.publish("rig/links", "1.0.0", linux, links, {"env": [path_env]})

        self.publish(
            "rig-private/secret", "1.0.0", linux, lambda p: self.exe(p / "bin" / "secret", "secret"), {"env": [path_env]}
        )  # fmt: skip

        def envtpl(pkg: Path) -> None:
            self.exe(pkg / "bin" / "envtpl", "envtpl")
            (pkg / "etc").mkdir()
            (pkg / "etc" / "conf").write_text("conf\n", encoding="utf-8")

        self.publish(
            "rig/envtpl", "1.0.0", linux, envtpl,
            {"env": [path_env,
                     {"key": "ENVTPL_HOME", "type": "constant", "value": "${installPath}", "visibility": "public"},
                     {"key": "ENVTPL_CONF", "type": "constant", "value": "${installPath}/etc/conf", "visibility": "public"}]},
        )  # fmt: skip

        # Entry points; the Windows leaf is a `.cmd`.
        self.publish(
            "rig/entry", "1.0.0", linux, lambda p: self.exe(p / "bin" / "hello", "entry hello"),
            {"env": [path_env], "entrypoints": {"entry-hello": {"command": "hello"}}},
        )  # fmt: skip

        def entry_cmd(pkg: Path) -> None:
            (pkg / "bin").mkdir()
            (pkg / "bin" / "hello.cmd").write_text("@echo entry hello\r\n", encoding="utf-8")

        self.publish(
            "rig/entry", "1.0.0", "windows/amd64", entry_cmd,
            {"env": [path_env], "entrypoints": {"entry-hello": {"command": "hello"}}},
        )  # fmt: skip

        def buildfiles(pkg: Path) -> None:
            self.exe(pkg / "bin" / "tool", "buildfiles")
            (pkg / "BUILD.bazel").write_text("# fixture\n", encoding="utf-8")
            (pkg / "build").write_text("case variant\n", encoding="utf-8")
            (pkg / "sub").mkdir()
            (pkg / "sub" / "BUILD").write_text("# nested\n", encoding="utf-8")

        self.publish("rig/buildfiles", "1.0.0", linux, buildfiles, {"env": [path_env]})

        def emptydir(pkg: Path) -> None:
            self.exe(pkg / "bin" / "tool", "emptydir")
            (pkg / "empty").mkdir()

        self.publish("rig/emptydir", "1.0.0", linux, emptydir, {"env": [path_env]})

        def wasm(pkg: Path) -> None:
            (pkg / "module.wasm").write_bytes(b"\x00asm\x01\x00\x00\x00")

        self.publish(
            "rig/wasm", "1.0.0", "wasip1/wasm", wasm,
            {"env": [{"key": "WASM_MODULE", "type": "constant", "value": "${installPath}/module.wasm", "visibility": "public"}]},
            no_bin_scan=True,
        )  # fmt: skip

        def winonly(pkg: Path) -> None:
            (pkg / "bin").mkdir()
            (pkg / "bin" / "winonly.cmd").write_text("@echo winonly\r\n", encoding="utf-8")

        self.publish("rig/winonly", "1.0.0", "windows/amd64", winonly, {"env": [path_env]})

        # Neither `binaries` nor `entrypoints`: env-only package, no scan.
        def bare(pkg: Path) -> None:
            (pkg / "data").mkdir()
            (pkg / "data" / "x.txt").write_text("x\n", encoding="utf-8")

        self.publish(
            "rig/bare", "1.0.0", linux, bare,
            {"env": [{"key": "BARE_DATA", "type": "constant", "value": "${installPath}/data", "visibility": "public"}]},
            no_bin_scan=True,
        )  # fmt: skip

        def big(pkg: Path) -> None:
            self.exe(pkg / "bin" / "tool", "big")
            for k in range(100):
                (pkg / "data" / f"{k:02d}").mkdir(parents=True)
            for i in range(BIG_FILES):
                (pkg / "data" / f"{i % 100:02d}" / f"f{i}.txt").write_text(f"{i}\n", encoding="utf-8")

        self.publish("rig/big", "1.0.0", linux, big, {"env": [path_env]}, compression="fast")

        out = self.run_dir / "fixtures.json"
        out.write_text(json.dumps(self.digests, indent=2, sort_keys=True), encoding="utf-8")
        print(f"wrote {out}", file=sys.stderr)

    def close(self) -> None:
        shutil.rmtree(self.work, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ocx", required=True)
    ap.add_argument("--registry", required=True)
    ap.add_argument("--run-dir", required=True)
    args = ap.parse_args()
    run_dir = Path(args.run_dir).resolve()
    seeder = Seeder(args.ocx, args.registry, run_dir)
    try:
        seeder.seed()
    finally:
        seeder.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
