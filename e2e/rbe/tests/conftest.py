# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Harness for the rig tests: rendered workspaces, Bazel clients, and the witnesses (nginx log, execution log).

Environment (set by `task rig:test`, defaults match `task rig:up`):
  RIG_RUN_DIR      run directory of `rig:up`/`rig:seed` (state/, logs/, fixtures.json)
  RIG_PORT         Buildbarn + registry port (18500); RIG_PORT_NL NativeLink port (18502)
  RIG_BACKEND      buildbarn | nativelink (default buildbarn)
  RIG_BAZEL        Bazel binary; RIG_OUTPUT_ROOT the one --output_user_root every call shares
  RIG_OCX          the ocx under test; its SHA-256 is computed here (OCX_INSTALL_BINARY_SHA256)

Every Bazel call starts with --ignore_all_rc_files and spells out rig.bazelrc's flags itself, so no rc file on
the host (and no shared remote cache in one) is ever read. Every ocx call gets a scratch OCX_HOME and HOME.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path

import pytest

RBE = Path(__file__).resolve().parents[1]
ROOT = RBE.parents[1]
RUN = Path(os.environ.get("RIG_RUN_DIR", RBE / ".run")).resolve()
PORT = int(os.environ.get("RIG_PORT", "18500"))
PORT_NL = int(os.environ.get("RIG_PORT_NL", "18502"))
BACKEND = os.environ.get("RIG_BACKEND", "buildbarn")
BAZEL = os.environ.get("RIG_BAZEL", "bazel")
OUTPUT_ROOT = Path(os.environ.get("RIG_OUTPUT_ROOT", RUN / "bazel")).resolve()
OCX = os.environ.get("RIG_OCX", "ocx")
REGISTRY = f"127.0.0.1:{PORT}"
BAZEL_TIMEOUT = 900


def container_bazel() -> str:
    """The real Bazel binary of `.bazelversion` that the network-less client container can exec.

    `RIG_BAZEL` may be a bare name on the host's PATH, a symlink into an ocx package or a bazelisk launcher; the
    container sees none of those. A launcher is asked once (into a scratch BAZELISK_HOME under the run
    directory) to download the pinned Bazel, whose path its metadata names. Fails early with the reason.
    """
    found = shutil.which(BAZEL)
    if found is None:
        pytest.fail(f"RIG_BAZEL={BAZEL!r} is not an executable on PATH: the offline client needs a real Bazel binary")
    real = os.path.realpath(found)
    if "bazelisk" not in os.path.basename(real).lower():
        return real
    version = (ROOT / ".bazelversion").read_text().strip()
    home = RUN / "bazelisk-home"
    proc = subprocess.run([real, "--version"], env={**os.environ, "BAZELISK_HOME": str(home)}, capture_output=True,
                          text=True, timeout=BAZEL_TIMEOUT)  # fmt: skip
    meta = sorted((home / "downloads" / "metadata" / "bazelbuild").glob(f"bazel-{version}-*"))
    binary = home / "downloads" / "sha256" / meta[0].read_text().strip() / "bin" / "bazel" if meta else None
    if binary is None or not binary.is_file():
        pytest.fail(f"bazelisk {real} did not download Bazel {version} into {home}: {proc.stdout}{proc.stderr}")
    return str(binary)


def rc_flags(config: str) -> list[str]:
    """`common`/`build` flags of rig.bazelrc plus `build:<config>`, nested --config expanded, ports rewritten."""
    rows: dict[str, list[str]] = {}
    for line in (RBE / "rig.bazelrc").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, _, flag = line.partition(" ")
            rows.setdefault(key, []).append(flag.strip())

    def expand(key: str) -> list[str]:
        out = []
        for flag in rows.get(key, []):
            out += expand("build:" + flag.split("=", 1)[1]) if flag.startswith("--config=") else [flag]
        return out

    flags = rows.get("common", []) + expand("build") + (expand("build:" + config) if config else [])
    return [f.replace("127.0.0.1:18500", f"127.0.0.1:{PORT}").replace("127.0.0.1:18502", f"127.0.0.1:{PORT_NL}") for f in flags]


def silo_flags(config: str, silo: str) -> list[str]:
    """Per-test cache silo (RESULTS.md, rig question 1): an instance-name suffix on Buildbarn, a salt on NativeLink."""
    if config.startswith("buildbarn"):
        return [f"--remote_instance_name=hardlinking/{silo}"]
    if config == "nativelink":
        return [f"--action_env=OCX_RIG_SILO={silo}"]
    return []


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def credentials() -> dict:
    return json.loads((RUN / "state" / "credentials.json").read_text(encoding="utf-8"))


def fixtures() -> dict:
    return json.loads((RUN / "fixtures.json").read_text(encoding="utf-8"))


def pin(repo: str, platform: str, tag: str = "1.0.0") -> str:
    """`repo:tag@<image index digest>`, the form a user pins; the platform must be one the fixture serves."""
    by_platform = fixtures()[repo][tag]
    assert platform in by_platform or platform.partition("+")[0] in by_platform, (repo, platform)
    req = urllib.request.Request(
        f"http://{REGISTRY}/v2/{repo}/manifests/{tag}", method="HEAD",
        headers={"Accept": "application/vnd.oci.image.index.v1+json"},
    )  # fmt: skip
    with urllib.request.urlopen(req, timeout=20) as resp:
        return f"{REGISTRY}/{repo}:{tag}@{resp.headers['Docker-Content-Digest']}"


def ocx_env(base: Path, *, auth: bool = False) -> dict[str, str]:
    (base / "user").mkdir(parents=True, exist_ok=True)
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(base / "user"),
        "OCX_HOME": str(base / "home"),
        "OCX_NO_CONFIG": "1",
        "OCX_INSECURE_REGISTRIES": REGISTRY,
    }
    if auth:
        key = "OCX_AUTH_" + re.sub(r"[^A-Za-z0-9]", "_", REGISTRY)
        creds = credentials()
        env |= {f"{key}_TYPE": "basic", f"{key}_USER": creds["user"], f"{key}_TOKEN": creds["password"]}
    return env


def ocx(base: Path, *args: str, cwd: Path | None = None, auth: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        [OCX, *args], cwd=cwd, env=ocx_env(base, auth=auth), capture_output=True, text=True, timeout=600
    )
    if check and proc.returncode:
        raise AssertionError(f"ocx {' '.join(args)} exited {proc.returncode}: {proc.stderr.strip()[-2000:]}")
    return proc


class Log:
    """nginx's JSON access log; `mark()` then `since()` gives one leg's lines and nothing else."""

    path = RUN / "logs" / "access.json"

    def __init__(self) -> None:
        self.start = 0
        self.mark()

    def _lines(self) -> list[str]:
        return self.path.read_text(encoding="utf-8", errors="replace").split("\n")[:-1] if self.path.exists() else []

    def mark(self) -> None:
        self.start = len(self._lines())

    def since(self) -> list[dict]:
        time.sleep(1.0)  # nginx logs after the response
        out = []
        for line in self._lines()[self.start :]:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    def registry(self) -> list[dict]:
        return [r for r in self.since() if r.get("uri", "").startswith("/v2/")]


@dataclass
class Result:
    rc: int
    out: str
    seconds: float
    exec_log: Path | None = None

    def processes(self) -> dict[str, int]:
        m = re.search(r"INFO: (\d+) processes?: ([^\n]*?)\.\n", self.out)
        counts = {"total": int(m.group(1)) if m else 0}
        for num, kind in re.findall(r"(\d+) ([a-z ]+?)(?:,|$)", m.group(2) if m else ""):
            counts[kind.strip().replace(" ", "_")] = int(num)
        return counts

    def spawns(self) -> list[dict]:
        """Spawns of `--execution_log_json_file` (a stream of JSON objects)."""
        text, dec, out, i = self.exec_log.read_text(encoding="utf-8"), json.JSONDecoder(), [], 0
        while True:
            while i < len(text) and text[i].isspace():
                i += 1
            if i >= len(text):
                return out
            obj, i = dec.raw_decode(text, i)
            out.append(obj)


@dataclass
class Workspace:
    """A rendered copy of e2e/rbe/workspace for one test."""

    path: Path
    test_id: str
    counter: Path
    ocx_binary: Path
    clients: list = field(default_factory=list)

    def client(self, name: str, **kw) -> Client:
        c = Client(self, name, **kw)
        self.clients.append(c)
        return c

    def ocx_calls(self) -> list[str]:
        return self.counter.read_text(encoding="utf-8").splitlines() if self.counter.exists() else []


class Client:
    """One Bazel client: its own output base, repository cache, HOME; the one shared --output_user_root."""

    def __init__(self, ws: Workspace, name: str, *, umask: int | None = None, tz: str | None = None) -> None:
        self.ws, self.name, self.umask, self.tz = ws, name, umask, tz
        self.dir = OUTPUT_ROOT / "clients" / f"{ws.test_id}-{name}"
        shutil.rmtree(self.dir, ignore_errors=True)
        self.home = self.dir / "user"
        (self.home / ".docker").mkdir(parents=True)
        creds = credentials()
        token = base64.b64encode(f"{creds['user']}:{creds['password']}".encode()).decode()
        (self.home / ".docker" / "config.json").write_text(json.dumps({"auths": {REGISTRY: {"auth": token}}}))
        self.output_base = self.dir / "ob"
        self.repo_cache = self.dir / "repocache"
        self.runs = 0

    def env(self) -> dict[str, str]:
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home), "OCX_NO_CONFIG": "1"}
        if self.tz:
            env["TZ"] = self.tz
        return env

    def startup(self, *extra: str) -> list[str]:
        return [BAZEL, "--ignore_all_rc_files", f"--output_user_root={OUTPUT_ROOT}", f"--output_base={self.output_base}", *extra]

    def run(self, cmd: str, *args: str, config: str = "", startup: tuple[str, ...] = (), lockfile: str = "off",
            timeout: int = BAZEL_TIMEOUT) -> Result:  # fmt: skip
        self.runs += 1
        exec_log = self.dir / f"exec-{self.runs}.json"
        flags = [
            "--repository_cache=" + str(self.repo_cache),
            f"--lockfile_mode={lockfile}",
            f"--repo_env=OCX_INSTALL_BINARY={self.ws.ocx_binary}",
            f"--repo_env=OCX_INSTALL_BINARY_SHA256={sha256(self.ws.ocx_binary)}",
            f"--repo_env=OCX_INSECURE_REGISTRIES={REGISTRY}",
            "--repo_env=OCX_NO_CONFIG=1",
        ]
        if cmd in ("build", "test", "run", "cquery", "aquery"):
            flags += rc_flags(config) + silo_flags(config, self.ws.test_id) + [f"--execution_log_json_file={exec_log}"]
            flags += ["--extra_execution_platforms=//platforms:exec_glibc"] if not any(
                a.startswith("--extra_execution_platforms") for a in args) else []  # fmt: skip
        elif cmd in ("fetch", "query", "mod", "vendor"):
            flags += [f for f in rc_flags("") if f.startswith(("--color", "--curses", "--noshow_progress"))]
        argv = [*self.startup(*startup), cmd, *flags, *args]
        t0 = time.monotonic()
        preexec = (lambda: os.umask(self.umask)) if self.umask is not None else None
        try:
            proc = subprocess.run(argv, cwd=self.ws.path, env=self.env(), capture_output=True, text=True,
                                  timeout=timeout, preexec_fn=preexec)  # fmt: skip
            rc, out = proc.returncode, proc.stdout + proc.stderr
        except subprocess.TimeoutExpired as exc:
            rc, out = 124, f"timeout after {timeout}s\n" + str(exc.stderr or "")
        return Result(rc, out, time.monotonic() - t0, exec_log if exec_log.exists() else None)

    def external(self, repo: str) -> Path:
        """The fetched directory of an extension repository (`rules_ocx++ocx+<name>`)."""
        return self.output_base / "external" / f"rules_ocx++ocx+{repo}"

    def shutdown(self) -> None:
        try:
            subprocess.run([*self.startup(), "shutdown"], cwd=self.ws.path, env=self.env(), capture_output=True, timeout=120)
        except subprocess.TimeoutExpired:
            pass


def _counting_wrapper(dest: Path, counter: Path) -> Path:
    """An `ocx` that logs each call (start/end time and argv) and runs the ocx under test.

    The harness's witness of "rule runs", never rules_ocx's: rules_ocx copies this file as @ocx_tool.
    The argv holds paths and flags only; credentials reach ocx through its environment and HOME.
    """
    real = shutil.which(OCX) or OCX
    dest.write_text(
        "#!/bin/sh\n"
        f'printf "start %s %s\\n" "$(date +%s.%N)" "$*" >> "{counter}"\n'
        f'"{real}" "$@"\nrc=$?\n'
        f'printf "end %s %s\\n" "$(date +%s.%N)" "$rc" >> "{counter}"\n'
        "exit $rc\n",
        encoding="utf-8",
    )
    dest.chmod(0o755)
    return dest


def _compile_capture(ws: Path) -> None:
    out = ws / "tools" / "capture.bin"
    proc = subprocess.run(["gcc", "-static", "-Os", "-s", str(ws / "tools" / "capture.c"), "-o", str(out)],
                          capture_output=True, text=True, timeout=120)  # fmt: skip
    assert proc.returncode == 0, proc.stderr


def render(dest: Path, test_id: str, *, module_extra: str = "", toml_edit=None) -> Workspace:
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(RBE / "workspace", dest, symlinks=True)
    module = (dest / "MODULE.bazel").read_text(encoding="utf-8")
    module = module.replace('path = "../../.."', f'path = "{ROOT}"').replace("@REGISTRY@", REGISTRY)
    module = re.sub(r"@PIN\(([^,<]+),([^)<]+)\)@", lambda m: pin(m.group(1), m.group(2)), module)
    (dest / "MODULE.bazel").write_text(module + module_extra, encoding="utf-8")
    for project, platform in [(dest, "linux/amd64+libc.glibc"), (dest / "winonly", "windows/amd64")]:
        toml = (project / "ocx.toml").read_text(encoding="utf-8").replace("@REGISTRY@", REGISTRY)
        (project / "ocx.toml").write_text(toml_edit(toml) if toml_edit and project == dest else toml, encoding="utf-8")
        lock(project, platform)
    _compile_capture(dest)
    counter = dest / ".ocx-calls.log"
    wrapper = _counting_wrapper(dest.parent / f"{test_id}-ocx", counter)
    return Workspace(dest, test_id, counter, wrapper)


def lock(project: Path, platform: str = "linux/amd64+libc.glibc") -> None:
    """`ocx lock` checks every binding against one platform; the lock still records every leaf."""
    ocx(RUN / "lockhome", "lock", "-p", platform, cwd=project, auth=True)


@pytest.fixture
def workspace(request):
    """A rendered workspace; parametrize indirectly with dict(module_extra=..., toml_edit=...)."""
    test_id = re.sub(r"[^A-Za-z0-9]+", "-", request.node.name).strip("-")[:60] + "-" + uuid.uuid4().hex[:6]
    ws = render(RUN / "ws" / test_id, test_id, **getattr(request, "param", {}))
    yield ws
    for c in ws.clients:
        c.shutdown()


@pytest.fixture
def log():
    return Log()


def assert_ok(res: Result, what: str) -> None:
    assert res.rc == 0, f"{what} exited {res.rc}:\n" + "\n".join(res.out.splitlines()[-40:])


def output(client: Client, target_file: str) -> str:
    return (client.output_base / "execroot" / "_main" / "bazel-out" / "k8-fastbuild" / "bin" / target_file).read_text()
