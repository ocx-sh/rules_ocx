# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Measures rules_ocx 0.5.1 against the seeded rig and writes a JSON record.

Usage: run_baseline.py --ocx <path> --port <p> --port-nl <p> --run-dir <dir> --output-root <dir> --results <json>
                       [--bazel <path>] [--backend buildbarn|nativelink ...]

Renders the template workspace into <run-dir>/baseline-ws, then per backend: a cold per-platform fetch
(wall time, registry requests and bytes from the nginx JSON log), a first client building an eager target
remotely, a second fresh client (new output base, new OCX_HOME) building it again, and a lazy-launcher
build on executors with no route to the registry. `--ocx` is accepted for the task interface; 0.5.1
bootstraps its own ocx. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
RBE = HERE.parent
BAZEL_VERSION = (RBE.parent.parent / ".bazelversion").read_text(encoding="utf-8")
EAGER = {  # tag name -> platform
    "eager_lg": "linux/amd64+libc.glibc",
    "eager_lm": "linux/amd64+libc.musl",
    "eager_ag": "linux/arm64+libc.glibc",
    "eager_am": "linux/arm64+libc.musl",
    "eager_da": "darwin/arm64",
    "eager_wa": "windows/amd64",
}


def slug(platform: str) -> str:
    return "_".join(p for p in re.sub(r"[^a-z0-9]", "_", platform.lower()).split("_") if p)


def render_workspace(ws: Path, registry: str, pin_glibc: str) -> None:
    shutil.rmtree(ws, ignore_errors=True)
    ws.mkdir(parents=True)
    tags, repos = [], []
    for name, plat in EAGER.items():
        tags.append(
            f'ocx.package(\n    name = "{name}",\n    package = "{registry}/rig/tool:1.0.0",\n'
            f'    isolated_home = True,\n    platforms = ["{plat}"],\n)'
        )
        repos += [f'"{name}"', f'"{name}_{slug(plat)}"']
    text = (HERE / "MODULE.bazel.tmpl").read_text(encoding="utf-8")
    for key, val in {
        "@EAGER_TAGS@": "\n".join(tags),
        "@EAGER_REPOS@": ", ".join(repos),
        "@REGISTRY@": registry,
        "@PIN_GLIBC@": pin_glibc,
    }.items():
        text = text.replace(key, val)
    (ws / "MODULE.bazel").write_text(text, encoding="utf-8")
    shutil.copy2(HERE / "BUILD.bazel", ws / "BUILD.bazel")
    (ws / ".bazelversion").write_text(BAZEL_VERSION, encoding="utf-8")


class Log:
    """Registry traffic as seen by nginx: `/v2/` requests since the last mark, counted by line."""

    def __init__(self, path: Path, port: int) -> None:
        self.path, self.port, self.lines = path, str(port), 0
        self.mark()

    def _read(self) -> list[str]:
        if not self.path.exists():
            return []
        text = self.path.read_text(encoding="utf-8", errors="replace")
        lines = text.split("\n")
        return lines[:-1]  # the last element is a partial line, or empty: left for the next read

    def mark(self) -> None:
        self.lines = len(self._read())

    def slice(self) -> dict[str, int]:
        time.sleep(1.0)  # nginx writes the log after the response; let the last lines land
        lines = self._read()
        reqs = sent = 0
        for line in lines[self.lines :]:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            # server_port is the container's port (80 or 82), not the published one.
            if rec.get("uri", "").startswith("/v2/"):
                reqs += 1
                sent += int(rec.get("sent_bytes", 0))
        self.lines = len(lines)
        return {"registry_requests": reqs, "registry_bytes": sent}


class Client:
    """One Bazel client: its own output base, repository cache and OCX_HOME, so it starts cold.

    Every client shares one --output_user_root (the install base); a shared repository cache would hand the
    second client the first one's repo contents, so each client gets its own.
    """

    user_root = ""  # set once from --output-root

    def __init__(self, bazel: str, ws: Path, root: Path, registry: str) -> None:
        self.bazel, self.ws, self.root = bazel, ws, root
        shutil.rmtree(root, ignore_errors=True)
        (root / "user").mkdir(parents=True)
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(root / "user"),
            "OCX_HOME": str(root / "home"),
            "OCX_NO_CONFIG": "1",
            "OCX_INSECURE_REGISTRIES": registry,
            "USE_BAZEL_VERSION": BAZEL_VERSION.strip(),
        }

    def startup(self) -> list[str]:
        return [
            self.bazel, "--ignore_all_rc_files", f"--output_user_root={self.user_root}",
            f"--output_base={self.root / 'ob'}",
        ]  # fmt: skip

    def bazel_cmd(self, cmd: str, *flags: str, timeout: int = 1500) -> tuple[int, str, float]:
        argv = [
            *self.startup(), cmd,
            "--curses=no", "--color=no", "--announce_rc=no", "--disk_cache=",
            f"--repository_cache={self.root / 'repocache'}",
            *(f"--repo_env={k}={v}" for k, v in self.env.items() if k.startswith("OCX_")),
            *flags,
        ]  # fmt: skip
        t0 = time.monotonic()
        try:
            proc = subprocess.run(
                argv, cwd=self.ws, env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=timeout
            )
            out, rc = proc.stdout + proc.stderr, proc.returncode
        except subprocess.TimeoutExpired as exc:
            err = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
            out, rc = f"timeout after {timeout}s\n{err}", 124
        return rc, out, time.monotonic() - t0

    def shutdown(self) -> None:
        try:
            subprocess.run(
                [*self.startup(), "shutdown"],
                cwd=self.ws, env=self.env, capture_output=True, timeout=120, check=False,
            )  # fmt: skip
        except subprocess.TimeoutExpired:
            print(f"warning: bazel shutdown timed out for {self.root}", file=sys.stderr)


def processes(out: str) -> dict[str, int] | None:
    """`INFO: 3 processes: 1 internal, 2 remote.` -> counts; None when the line is absent."""
    m = re.search(r"INFO: (\d+) processes?: ([^\n]*?)\.\n", out)
    if not m:
        return None
    counts = {"total": int(m.group(1)), "remote": 0, "remote_cache_hit": 0}
    for num, kind in re.findall(r"(\d+) ([a-z ]+?)(?:,|$)", m.group(2)):
        if kind.strip() in ("remote", "remote cache hit"):
            counts[kind.strip().replace(" ", "_")] = int(num)
    return counts


def exec_image() -> str:
    text = (RBE / "buildbarn" / "worker-ubuntu.jsonnet").read_text(encoding="utf-8")
    m = re.search(r"docker://[^'\"]+", text)
    if not m:
        raise SystemExit("no executor image in buildbarn/worker-ubuntu.jsonnet")
    return m.group(0)


def failing_line(out: str) -> str:
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    # The Bazel `ERROR:` header only names the action; the decisive line is what the launcher printed after it.
    body = [ln for ln in lines if not ln.startswith(("ERROR:", "INFO:", "Use --"))]
    for ln in body:
        if re.search(r"error|failed|unreach|refused|connect|resolve|No such|not found", ln, re.I):
            return ln[:400]
    return (body or lines or [""])[-1][:400]


def measure(backend: str, port: int, args: argparse.Namespace, registry: str, ws: Path) -> dict:
    clients: list[Client] = []
    try:
        return _measure(backend, port, args, registry, ws, clients)
    finally:
        for client in clients:
            client.shutdown()


def _measure(backend: str, port: int, args: argparse.Namespace, registry: str, ws: Path, clients: list[Client]) -> dict:
    run_dir = Path(args.run_dir)
    log = Log(run_dir / "logs" / "access.json", args.port)
    silo = f"baseline-{uuid.uuid4().hex[:8]}"
    if backend == "buildbarn":
        remote = [
            f"--remote_executor=grpc://127.0.0.1:{port}", f"--remote_cache=grpc://127.0.0.1:{port}",
            f"--remote_instance_name=hardlinking/{silo}", "--remote_default_exec_properties=OSFamily=linux",
            f"--remote_default_exec_properties=container-image={exec_image()}",
        ]  # fmt: skip
    else:
        remote = [
            f"--remote_executor=grpc://127.0.0.1:{port}", f"--remote_cache=grpc://127.0.0.1:{port}",
            "--remote_instance_name=main", "--remote_default_exec_properties=OSFamily=linux",
            f"--action_env=OCX_RIG_SILO={silo}",
        ]  # fmt: skip
    res: dict = {"silo": silo}
    root = Path(args.output_root)

    a = Client(args.bazel, ws, root / f"{backend}-a", registry)
    clients.append(a)
    log.mark()
    rc, out, secs = a.bazel_cmd("fetch", "--repo=@ocx_tool")
    res["ocx_tool_fetch"] = {"rc": rc, "seconds": round(secs, 1), **log.slice()}
    if rc:
        res["ocx_tool_fetch"]["error"] = failing_line(out)
    per, total = {}, 0.0
    for name, plat in EAGER.items():
        rc, out, secs = a.bazel_cmd("fetch", f"--repo=@{name}_{slug(plat)}")
        per[plat] = {"rc": rc, "seconds": round(secs, 1), **log.slice()}
        if rc:
            per[plat]["error"] = failing_line(out)
        total += secs
    res["cold_fetch"] = {"per_platform": per, "total_seconds": round(total, 1)}

    rc, out, secs = a.bazel_cmd("build", "//:eager", *remote)
    res["client_a_build"] = {"rc": rc, "seconds": round(secs, 1), "processes": processes(out), **log.slice()}
    if rc:
        res["client_a_build"]["error"] = failing_line(out)

    b = Client(args.bazel, ws, root / f"{backend}-b", registry)
    clients.append(b)
    log.mark()
    rc, out, secs = b.bazel_cmd("build", "//:eager", *remote)
    res["client_b_build"] = {"rc": rc, "seconds": round(secs, 1), "processes": processes(out), **log.slice()}
    if rc:
        res["client_b_build"]["error"] = failing_line(out)

    # Lazy launcher, once local (what the client machine sees) and once on an executor with no route out.
    c = Client(args.bazel, ws, root / f"{backend}-c", registry)
    clients.append(c)
    # An action sees no OCX_* variable unless it is passed; the executor's home is a path it can write.
    def act(home: str) -> list[str]:
        return [f"--action_env=OCX_HOME={home}", "--action_env=OCX_NO_CONFIG=1", f"--action_env=OCX_INSECURE_REGISTRIES={registry}"]

    rc_l, out_l, _ = c.bazel_cmd("build", "//:lazy", "--spawn_strategy=local", *act(str(c.root / "action-home")))
    rc_r, out_r, secs = c.bazel_cmd("build", "//:lazy", *remote, *act("/tmp/ocx-home"))
    res["network_less"] = {
        "local_pass": rc_l == 0,
        "remote_pass": rc_r == 0,
        "failing_line": "" if rc_r == 0 else failing_line(out_r),
        "excerpt": [] if rc_r == 0 else [ln[:300] for ln in out_r.splitlines() if ln.strip()][-12:],
        "local_failing_line": "" if rc_l == 0 else failing_line(out_l),
        "seconds": round(secs, 1),
        # No control with a networked executor is needed: the 0.5.1 launcher runs `ocx package exec`, which
        # needs an ocx binary and a reachable registry at action time, and the rig executors have neither
        # route nor store. That is V-01's red.
        "diagnosis": "0.5.1 lazy launcher needs ocx plus a reachable registry at action time; rig executors have no route",
    }
    return res


def failed_legs(results: dict) -> list[str]:
    """Every leg that went red except the expected network-less remote build."""
    bad = []
    for backend, r in results["backends"].items():
        if r["ocx_tool_fetch"]["rc"]:
            bad.append(f"{backend}: ocx_tool_fetch")
        bad += [f"{backend}: fetch {p}" for p, v in r["cold_fetch"]["per_platform"].items() if v["rc"]]
        bad += [f"{backend}: {k}" for k in ("client_a_build", "client_b_build") if r[k]["rc"]]
        if not r["network_less"]["local_pass"]:
            bad.append(f"{backend}: lazy launcher fails locally too")
        if r["network_less"]["remote_pass"]:
            bad.append(f"{backend}: lazy launcher unexpectedly passes on network-less executors")
    return bad


def markdown(results: dict) -> str:
    rows = ["| measure | " + " | ".join(results["backends"]) + " |", "|---|" + "---|" * len(results["backends"])]

    def row(label: str, fn) -> None:
        rows.append(f"| {label} | " + " | ".join(str(fn(r)) for r in results["backends"].values()) + " |")

    row("ocx bootstrap download, @ocx_tool (s)", lambda r: r["ocx_tool_fetch"]["seconds"])
    row("cold client fetch, all six platforms (s)", lambda r: r["cold_fetch"]["total_seconds"])
    for plat in EAGER.values():
        row(f"registry requests / bytes, {plat}", lambda r, p=plat: "{registry_requests} / {registry_bytes}".format(**r["cold_fetch"]["per_platform"][p]))
    row("second fresh client: registry requests / bytes", lambda r: "{registry_requests} / {registry_bytes}".format(**r["client_b_build"]))
    row("second fresh client: processes", lambda r: r["client_b_build"]["processes"] or "unknown")
    row("builds on network-less executors", lambda r: "pass" if r["network_less"]["remote_pass"] else "FAIL: " + r["network_less"]["failing_line"])
    return "\n".join(rows) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ocx", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--port-nl", type=int, required=True)
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--output-root", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--bazel", default=os.environ.get("BAZEL", "bazel"))
    ap.add_argument("--backend", action="append", choices=["buildbarn", "nativelink"])
    args = ap.parse_args()
    run_dir = Path(args.run_dir).resolve()
    args.run_dir = str(run_dir)
    Client.user_root = str(Path(args.output_root).resolve())
    registry = f"127.0.0.1:{args.port}"
    fixtures = json.loads((run_dir / "fixtures.json").read_text(encoding="utf-8"))
    pin = fixtures["rig/tool"]["1.0.0"]["linux/amd64+libc.glibc"]
    ws = run_dir / "baseline-ws"
    render_workspace(ws, registry, pin)
    ports = {"buildbarn": args.port, "nativelink": args.port_nl}
    results = {"rules_ocx": "0.5.1", "backends": {}}
    for backend in args.backend or ["buildbarn"]:
        results["backends"][backend] = measure(backend, ports[backend], args, registry, ws)
    out = Path(args.results)
    out.write_text(json.dumps(results, indent=2), encoding="utf-8")
    out.with_suffix(".md").write_text(markdown(results), encoding="utf-8")
    print(markdown(results))
    failed = failed_legs(results)
    for leg in failed:
        print(f"leg failed: {leg}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
