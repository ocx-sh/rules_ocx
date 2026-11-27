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
import sys
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
        self.extra_env: dict[str, str] = {}  # reaches the client process, so also a `bazel run` program

    def env(self) -> dict[str, str]:
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home), "OCX_NO_CONFIG": "1"}
        if self.tz:
            env["TZ"] = self.tz
        return env | self.extra_env

    def startup(self, *extra: str) -> list[str]:
        return [BAZEL, "--ignore_all_rc_files", f"--output_user_root={OUTPUT_ROOT}", f"--output_base={self.output_base}", *extra]

    def _argv(self, cmd: str, args: tuple[str, ...], config: str, startup: tuple[str, ...], lockfile: str) -> tuple[list[str], Path]:
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
        return [*self.startup(*startup), cmd, *flags, *args], exec_log

    def run(self, cmd: str, *args: str, config: str = "", startup: tuple[str, ...] = (), lockfile: str = "off",
            timeout: int = BAZEL_TIMEOUT) -> Result:  # fmt: skip
        argv, exec_log = self._argv(cmd, args, config, startup, lockfile)
        t0 = time.monotonic()
        preexec = (lambda: os.umask(self.umask)) if self.umask is not None else None
        try:
            proc = subprocess.run(argv, cwd=self.ws.path, env=self.env(), capture_output=True, text=True,
                                  timeout=timeout, preexec_fn=preexec)  # fmt: skip
            rc, out = proc.returncode, proc.stdout + proc.stderr
        except subprocess.TimeoutExpired as exc:
            rc, out = 124, f"timeout after {timeout}s\n" + str(exc.stderr or "")
        return Result(rc, out, time.monotonic() - t0, exec_log if exec_log.exists() else None)

    def start(self, cmd: str, *args: str, config: str = "", startup: tuple[str, ...] = (), lockfile: str = "off") -> subprocess.Popen:
        """The same call as `run`, left running: the caller terminates it."""
        argv, _ = self._argv(cmd, args, config, startup, lockfile)
        return subprocess.Popen(argv, cwd=self.ws.path, env=self.env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def external(self, repo: str) -> Path:
        """The fetched directory of an extension repository (`rules_ocx++ocx+<name>`)."""
        return self.output_base / "external" / f"rules_ocx++ocx+{repo}"

    def shutdown(self) -> None:
        try:
            subprocess.run([*self.startup(), "shutdown"], cwd=self.ws.path, env=self.env(), capture_output=True, timeout=120)
        except subprocess.TimeoutExpired:
            pass


# After a successful `--manifest-only` resolve, rewrites its manifest.json: the planted faults of `lock_workspace`.
_FAULT_PY = """\
import hashlib, json, sys
fault, args = sys.argv[1], sys.argv[2:]
if "--manifest-only" in args:
    out, platform = args[args.index("-o") + 1], args[args.index("-p") + 1]
    path = out + "/manifest.json"
    m = json.load(open(path))
    if fault == "two_roots":
        m["selections"][0]["roots"].append("sha256:" + "b" * 64)
    elif fault == "index_digest":  # one image index per platform: the tag "moved" between two platforms
        root = m["selections"][0]["roots"][0]
        for p in m["packages"]:
            if p["digest"] == root:
                p["index_digest"] = "sha256:" + hashlib.sha256(platform.encode()).hexdigest()
    json.dump(m, open(path, "w"))
"""


def _counting_wrapper(dest: Path, counter: Path, fault: str | None = None) -> Path:
    """An `ocx` that logs each call (start/end time and argv) and runs the ocx under test.

    `fault` (`two_roots`, `index_digest`) makes it rewrite the manifest of every successful `--manifest-only` run.

    The harness's witness of "rule runs", never rules_ocx's: rules_ocx copies this file as @ocx_tool.
    The argv holds paths and flags only; credentials reach ocx through its environment and HOME.
    """
    real = shutil.which(OCX) or OCX
    hook = ""
    if fault:
        script = dest.parent / f"{dest.name}-fault.py"
        script.write_text(_FAULT_PY, encoding="utf-8")
        hook = f'if [ "$rc" -eq 0 ]; then "{sys.executable}" "{script}" {fault} "$@"; fi\n'
    dest.write_text(
        "#!/bin/sh\n"
        f'printf "start %s %s\\n" "$(date +%s.%N)" "$*" >> "{counter}"\n'
        f'"{real}" "$@"\nrc=$?\n' + hook +
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


# ---- Package locking (ADR 0003): a registry repository and a minimal workspace of its own per test.

LOCK_P = "linux/amd64+libc.glibc"
LOCK_MUSL = "linux/amd64+libc.musl"
LOCK_HUB = "lk"
_PATH_ENV = {"key": "PATH", "type": "path", "value": "${installPath}/bin", "visibility": "public"}


def platform_slug(platform: str) -> str:
    """`linux/amd64+libc.glibc` -> `linux_amd64_libc_glibc`, as the set repository names carry it."""
    return "_".join(p for p in re.sub(r"[^a-z0-9]+", "_", platform.lower()).split("_") if p)


def pkg_decl(name: str, package: str, platforms=(LOCK_P,), **extra: str) -> str:
    """One `ocx.package(...)` line; `extra` values are Starlark source (`index = '"//:index"'`)."""
    plats = ", ".join(json.dumps(p) for p in platforms)
    more = "".join(f", {k} = {v}" for k, v in extra.items())
    return f'ocx.package(name = "{name}", package = "{package}", platforms = [{plats}]{more})\n'


def lock_facts(ws: Workspace) -> dict[str, dict]:
    """The facts of `MODULE.bazel.lock`, decoded: `{"package|<name>": {...}}`."""
    found: dict = {}

    def walk(node) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "facts" and isinstance(value, dict):
                    found.update(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(json.loads((ws.path / "MODULE.bazel.lock").read_text(encoding="utf-8")).get("moduleExtensions", {}))
    return {k: json.loads(v) if isinstance(v, str) else v for k, v in found.items()}


def _fact_tables(lock_json: dict, key: str) -> list[dict]:
    hits = []

    def walk(node) -> None:
        if isinstance(node, dict):
            if isinstance(node.get("facts"), dict) and key in node["facts"]:
                hits.append(node["facts"])
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(lock_json.get("moduleExtensions", {}))
    return hits


def plant_fact(ws: Workspace, key: str, change) -> None:
    """Replaces the stored fact `key` by `json.dumps(change(decoded))`: a planted older or damaged value."""
    path = ws.path / "MODULE.bazel.lock"
    lock_json = json.loads(path.read_text(encoding="utf-8"))
    hits = _fact_tables(lock_json, key)
    assert hits, f"no fact {key!r} in {path}"
    for facts in hits:
        facts[key] = json.dumps(change(json.loads(facts[key])))
    path.write_text(json.dumps(lock_json, indent=2), encoding="utf-8")


def drop_fact(ws: Workspace, key: str) -> None:
    """Removes the stored fact `key`: a declaration whose fact is missing."""
    path = ws.path / "MODULE.bazel.lock"
    lock_json = json.loads(path.read_text(encoding="utf-8"))
    hits = _fact_tables(lock_json, key)
    assert hits, f"no fact {key!r} in {path}"
    for facts in hits:
        del facts[key]
    path.write_text(json.dumps(lock_json, indent=2), encoding="utf-8")


def resolve_calls(ws: Workspace, since: int = 0) -> list[str]:
    """The extension's `ocx ... vendor ... --manifest-only` calls (argv text) after the first `since` log lines."""
    return [ln for ln in ws.ocx_calls()[since:] if ln.startswith("start ") and " vendor" in ln and "--manifest-only" in ln]


def set_calls(ws: Workspace, since: int = 0) -> list[str]:
    """The set repositories' full `ocx ... vendor` calls."""
    return [ln for ln in ws.ocx_calls()[since:] if ln.startswith("start ") and " vendor" in ln and "--manifest-only" not in ln]


def hub_query(client: Client, hub: str, *args: str, lockfile: str = "update") -> Result:
    """Evaluates the extension (and nothing else) by querying one hub."""
    return client.run("query", f"@@rules_ocx++ocx+{hub}//:all", *args, lockfile=lockfile)


def run_hub(client: Client, hub: str, *args: str, lockfile: str = "update") -> Result:
    """Builds `//:run_<hub>` (the hub's `tool` run through its launcher) on this host."""
    return client.run("build", f"//:run_{hub}", "--spawn_strategy=local", *args, lockfile=lockfile)


def tool_report(client: Client, hub: str) -> str:
    return output(client, f"run_{hub}.txt").strip()


def tree_bytes(root: Path) -> dict[str, str]:
    """Relative path -> SHA-256 of every file under `root`."""
    return {p.relative_to(root).as_posix(): sha256(p) for p in sorted(root.rglob("*")) if p.is_file()}


def ocx_work(ws: Workspace, since: int = 0) -> list[str]:
    """Every `ocx` call after the first `since` log lines that resolves or updates something (a vendor or an update)."""
    return [ln for ln in ws.ocx_calls()[since:] if ln.startswith("start ") and (" vendor" in ln or " update" in ln)]


def ws_bytes(ws: Workspace) -> dict[str, str]:
    """Relative path -> SHA-256 of every workspace file, but Bazel's `bazel-*` links and the harness's call log."""
    return {k: v for k, v in tree_bytes(ws.path).items() if k != ".ocx-calls.log" and not k.startswith("bazel-")}


_BAZEL_PY = """\
import os, sys
args = sys.argv[1:]
i = 0
while i < len(args) and args[i].startswith("-"):
    i += 1
startup, cmd, rest = args[:i], args[i : i + 1], args[i + 1 :]
if cmd == ["mod"] and {fail!r} is not None:
    sys.exit({fail!r})
extra = {extra!r} if cmd == ["mod"] else []
os.execv({bazel!r}, [{bazel!r}, *{base!r}, *startup, *cmd, *rest, *extra])
"""


def update_client(ws: Workspace, name: str, *, nested: Client | None = None, fail_mod: int | None = None,
                  bazel: str | None = None) -> Client:  # fmt: skip
    """A client that runs the `update` targets (ADR 0003 § The `update` targets).

    The program reads `RULES_OCX_BAZEL`, adds no startup option of its own and inherits the client's environment, so
    this sets: `RULES_OCX_BAZEL` to a wrapper that puts this harness's startup options (no rc file, the shared
    output user root, the output base of `nested`, default: this client's) before the program's and this client's
    repository flags after its `mod` command; and `OCX_INSECURE_REGISTRIES`, which ocx reads from the environment.
    `fail_mod` makes the wrapper exit with that code for `mod`; `bazel` sets `RULES_OCX_BAZEL` to that value instead.
    """
    client = ws.client(name)
    client.extra_env["OCX_INSECURE_REGISTRIES"] = REGISTRY
    if bazel is not None:
        client.extra_env["RULES_OCX_BAZEL"] = bazel
        return client
    target = nested or client
    extra = [f"--repository_cache={target.repo_cache}", f"--repo_env=OCX_INSTALL_BINARY={target.ws.ocx_binary}",
             f"--repo_env=OCX_INSTALL_BINARY_SHA256={sha256(target.ws.ocx_binary)}",
             f"--repo_env=OCX_INSECURE_REGISTRIES={REGISTRY}", "--repo_env=OCX_NO_CONFIG=1"]  # fmt: skip
    real = shutil.which(BAZEL) or BAZEL
    script = _BAZEL_PY.format(fail=fail_mod, extra=extra, bazel=real, base=target.startup()[1:])
    (client.dir / "bazel.py").write_text(script, encoding="utf-8")
    wrapper = client.dir / "bazel-wrapper"
    wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{client.dir / "bazel.py"}" "$@"\n', encoding="utf-8")
    wrapper.chmod(0o755)
    client.extra_env["RULES_OCX_BAZEL"] = str(wrapper)
    return client


def run_update(client: Client, target: str, *args: str, lockfile: str = "update", timeout: int = 600) -> Result:
    """`bazel run <target> -- ARGS`; `target` is `@<hub>//:update` or `@rules_ocx//:update`."""
    tail = ["--", *args] if args else []
    return client.run("run", target, "--spawn_strategy=local", *tail, lockfile=lockfile, timeout=timeout)


class LockRig:
    """One registry repository (`rig/<test id>`), a publisher for it and minimal workspaces over it."""

    def __init__(self, request) -> None:
        self.id = (re.sub(r"[^a-z0-9]+", "-", request.node.name.lower()).strip("-")[:50] + "-" + uuid.uuid4().hex[:6])
        self.repo = "rig/" + self.id
        self.workspaces: list[Workspace] = []
        self._seeder = None

    def ident(self, tag: str = "1.0", repo: str | None = None) -> str:
        return f"{REGISTRY}/{repo or self.repo}:{tag}"

    def push(self, tag: str, report: str, platforms=(LOCK_P,), *, repo: str | None = None, exe: str = "tool",
             meta: dict | None = None) -> dict[str, str]:  # fmt: skip
        """Publishes `bin/<exe>` (a static program that prints `report`) for each platform under `tag`.

        A second push to the same tag with another `report` moves the tag. Returns platform -> platform manifest digest.
        """
        sys.path.insert(0, str(RBE / "fixtures"))
        from seed import Seeder

        repo = repo or self.repo
        if self._seeder is None:
            self._seeder = Seeder(OCX, REGISTRY, RUN)
            self._seeder.home = RUN / "lock-seed" / self.id  # not the rig seed's home
            self._seeder.env["OCX_HOME"] = str(self._seeder.home)
        seeder = self._seeder
        try:
            for platform in platforms:
                seeder.publish(repo, tag, platform, lambda p: seeder.exe(p / "bin" / exe, report),
                               {"env": [_PATH_ENV], **(meta or {})})  # fmt: skip
        except SystemExit as exc:
            raise AssertionError(f"publishing {repo}:{tag} failed: {exc}") from exc
        got = seeder.digests[repo][tag]
        return {p: got[p] if got[p].startswith("sha256:") else "sha256:" + got[p] for p in platforms}

    def index_digest(self, tag: str = "1.0", repo: str | None = None) -> str:
        req = urllib.request.Request(f"http://{REGISTRY}/v2/{repo or self.repo}/manifests/{tag}", method="HEAD",
                                     headers={"Accept": "application/vnd.oci.image.index.v1+json"})  # fmt: skip
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.headers["Docker-Content-Digest"]

    def delete(self, *digests: str, repo: str | None = None) -> None:
        """Deletes manifests by digest through the registry API with the rig credentials, in the order given."""
        creds = credentials()
        token = base64.b64encode(f"{creds['user']}:{creds['password']}".encode()).decode()
        for digest in digests:
            req = urllib.request.Request(f"http://{REGISTRY}/v2/{repo or self.repo}/manifests/{digest}", method="DELETE",
                                         headers={"Authorization": f"Basic {token}"})  # fmt: skip
            urllib.request.urlopen(req, timeout=20).close()

    def uris(self, log: Log, repo: str | None = None) -> list[str]:
        """Registry request paths of this repository since the log's mark."""
        return [r["uri"] for r in log.registry() if f"/v2/{repo or self.repo}/" in r["uri"]]

    def refresh_index(self, ws: Workspace, repo: str | None = None) -> None:
        """`ocx index update` of the workspace's `index/` snapshot for this repository."""
        ocx(ws.path.parent / f"{ws.test_id}-indexhome", "--index", str(ws.path / "index"), "index", "update",
            f"{REGISTRY}/{repo or self.repo}")  # fmt: skip

    def workspace(self, decls: str, hubs: dict[str, list[str]], *, name: str = "", fault: str | None = None,
                  toml: str | None = None, index: bool = False, dir_name: str | None = None) -> Workspace:  # fmt: skip
        """A minimal workspace: rules_ocx, `decls` (the `ocx.package`/`ocx.project` lines), and per hub
        `//:run_<hub>` (its `tool` through the launcher) and `//:inputs_<hub>` (a count of the first set's files).

        `hubs` maps hub name -> platforms. `toml` is an `ocx.toml` text (`@REGISTRY@` filled) locked with `ocx lock`.
        `index` snapshots this repository into `index/` and exports it as `//:index`. `fault` plants a manifest fault.
        `dir_name` is the workspace directory's own name (default: the test id), e.g. one holding a space.
        """
        test_id = self.id + name
        ws_dir = RUN / "ws" / test_id / dir_name if dir_name else RUN / "ws" / test_id
        shutil.rmtree(ws_dir, ignore_errors=True)
        ws_dir.mkdir(parents=True)
        shutil.copytree(RBE / "workspace" / "platforms", ws_dir / "platforms")
        (ws_dir / ".bazelversion").write_text((ROOT / ".bazelversion").read_text())
        repos = ["ocx_tool", *hubs, *[f"{h}_{platform_slug(p)}" for h, ps in hubs.items() for p in ps]]
        (ws_dir / "MODULE.bazel").write_text(
            'module(name = "lock_ws")\nbazel_dep(name = "rules_ocx", version = "0.0.0")\n'
            'bazel_dep(name = "platforms", version = "1.0.0")\n'
            f'local_path_override(module_name = "rules_ocx", path = "{ROOT}")\n'
            'ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")\n' + decls
            + f"use_repo(ocx, {', '.join(json.dumps(r) for r in repos)})\n"
            + f"register_toolchains({', '.join(json.dumps(f'@{h}//:all') for h in hubs)})\n"
        )  # fmt: skip
        build = "".join(
            f'genrule(name = "run_{h}", outs = ["run_{h}.txt"], cmd = "$(execpath @{h}//:tool) > $@", tools = ["@{h}//:tool"])\n'
            f'genrule(name = "inputs_{h}", srcs = ["@{h}_{platform_slug(ps[0])}//:set"], outs = ["inputs_{h}.txt"], '
            'cmd = "echo $(SRCS) | wc -w > $@")\n'
            for h, ps in hubs.items()
        )
        if index:
            build += 'exports_files(["index"])\n'
        (ws_dir / "BUILD.bazel").write_text(build)
        if toml is not None:
            (ws_dir / "ocx.toml").write_text(toml.replace("@REGISTRY@", REGISTRY), encoding="utf-8")
            lock(ws_dir)
        counter = ws_dir / ".ocx-calls.log"
        ws = Workspace(ws_dir, test_id, counter, _counting_wrapper(ws_dir.parent / f"{test_id}-ocx", counter, fault))
        if index:
            self.refresh_index(ws)
        self.workspaces.append(ws)
        return ws


@pytest.fixture
def lockrig(request):
    rig = LockRig(request)
    yield rig
    for ws in rig.workspaces:
        for c in ws.clients:
            c.shutdown()
    if rig._seeder is not None:
        rig._seeder.close()
