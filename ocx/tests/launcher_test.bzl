# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for the pure helpers in ocx/private/repo_utils.bzl."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//ocx/private:platforms.bzl", "host_info")
load("//ocx/private:project.bzl", "lazy_project_command")
load(
    "//ocx/private:repo_utils.bzl",
    "OCX_ENV_CLASSES",
    "SYSEXIT_HINTS",
    "ambient_config_paths",
    "bat_value",
    "check_bin_names",
    "closure_packages",
    "declared_bins",
    "decode_json",
    "discover_bins",
    "is_absolute_path",
    "make_ocx_env",
    "path_dirs",
    "render_env_bzl",
    "render_launcher",
    "render_launchers_build",
    "render_lazy_launcher",
    "run_ocx",
    "sigstore_trust_root_path",
    "stage_lazy_config",
    "truthy",
)

_ENTRIES = [
    {"key": "PATH", "value": "/store/aa/content/bin", "type": "path"},
    {"key": "PATH", "value": "/store/bb/content", "type": "path"},
    {"key": "JAVA_HOME", "value": "/store/cc/content", "type": "constant"},
]

def _fs_ctx(files = [], dirs = [], listing = {}):
    """A repository_ctx stand-in exposing a canned filesystem.

    Covers everything the discovery helpers touch: `ctx.path().exists/is_dir`,
    `readdir()` (the Windows scan) and the one `ctx.execute` the POSIX scan
    shells out to.

    Args:
        files: absolute paths that exist as executable regular files.
        dirs: absolute paths that exist as directories.
        listing: {directory: [basename, ...]} returned by a scan of it.

    Returns:
        the fake ctx struct.
    """

    def path(p):
        p = str(p)

        def readdir():
            return [
                struct(basename = n, is_dir = (p + "/" + n) in dirs)
                for n in listing.get(p, [])
            ]

        return struct(
            exists = p in files or p in dirs or p in listing,
            is_dir = p in dirs or p in listing,
            readdir = readdir,
        )

    # The keyword names are repository_ctx's, so they cannot be renamed away.
    # buildifier: disable=unused-variable
    def execute(argv, environment = None, timeout = None):
        # list_executables' POSIX branch passes the directory last.
        directory = argv[-1]
        found = [n for n in listing.get(directory, []) if directory + "/" + n in files]
        return struct(
            return_code = 0,
            stdout = "".join([n + "\n" for n in found]),
            stderr = "",
        )

    return struct(path = path, execute = execute)

def _replay_ctx(codes, calls, sleeps = None):
    """A repository_ctx stand-in replaying a scripted sequence of exit codes.

    Args:
        codes: return codes to hand back, one per ocx invocation; the last is
            repeated once exhausted.
        calls: mutable list every ocx argv is appended to, so a test can count
            the attempts run_ocx() actually made.
        sleeps: mutable list every backoff exec's environment is appended to,
            or None to ignore them.

    Returns:
        the fake ctx struct.
    """

    # buildifier: disable=unused-variable
    def execute(argv, environment = None, timeout = None):
        # The backoff sleep is not an attempt.
        if argv[0] == "/bin/sh":
            if sleeps != None:
                sleeps.append(environment)
            return struct(return_code = 0, stdout = "", stderr = "")
        calls.append(argv)
        code = codes[min(len(calls), len(codes)) - 1]
        return struct(return_code = code, stdout = "out{}".format(code), stderr = "boom")

    return struct(execute = execute)

def _env_ctx(
        env = {},
        no_config = False,
        config = None,
        patch_snapshot = None,
        allow_unverified = False,
        allow_yanked = False,
        sigstore_trusted_root = None):
    """A repository_ctx stand-in for make_ocx_env() / stage_lazy_config().

    `path` returns the string it was given, resolved against a fixed repo root
    when it is a bare name (which is what `isolated_home` relies on): these two
    only ever str() the result, and the fetched-file semantics play no part in
    what is asserted. Every ctx.watch() lands in the returned struct's
    `watched` list — the watch set is a contract of its own, since Bazel
    cannot invalidate on a file no rule ever declared reading.

    Args:
        env: the ambient environment ctx.getenv() reads.
        no_config: the `no_config` attr.
        config: the `config` attr (a path string stands in for the label).
        patch_snapshot: the `patch_snapshot` attr.
        allow_unverified: the POLICY_ATTRS `allow_unverified` attr.
        allow_yanked: the POLICY_ATTRS `allow_yanked` attr.
        sigstore_trusted_root: the POLICY_ATTRS `sigstore_trusted_root` attr
            (a path string stands in for the label).

    Returns:
        the fake ctx struct.
    """

    watched = []

    def getenv(key):
        return env.get(key)

    def path(p):
        return p if is_absolute_path(p, False) else "/repo/" + p

    def watch(p):
        watched.append(p)
        return None

    def read(label):
        return "# staged from {}\n".format(label)

    # buildifier: disable=unused-variable
    def file(name, content, executable = False):
        return None

    return struct(
        getenv = getenv,
        path = path,
        watch = watch,
        watched = watched,
        read = read,
        file = file,
        name = "test_repo",
        attr = struct(
            no_config = no_config,
            config = config,
            patch_snapshot = patch_snapshot,
            allow_unverified = allow_unverified,
            allow_yanked = allow_yanked,
            sigstore_trusted_root = sigstore_trusted_root,
        ),
    )

# The ambient environment the config tests steer: every channel `no_config`
# has to close, plus one it must leave alone — and the hostile CI image an
# ocx.policy() build has to be immune to (S-005).
_AMBIENT = {
    "OCX_HOME": "/home/u/.ocx",
    "OCX_CONFIG": "/site/config.toml",
    "OCX_PATCHES": "{\"patches\":{\"ocx.sh/evil\":\"latest\"}}",
    "OCX_PATCH_SNAPSHOT": "/site/patches.snapshot.json",
    "OCX_MIRRORS": "https://mirror.example",
    "OCX_SIGSTORE_TRUSTED_ROOT": "/site/trusted-root.json",
    # The two weakening knobs, exported three layers up in a CI image, and the
    # project-walk selector a parent `ocx exec` leaks into its children.
    "OCX_NO_VERIFY": "1",
    "OCX_ALLOW_YANKED": "1",
    "OCX_NO_PROJECT": "0",
}

def _make_ocx_env_test_impl(ctx):
    """F4/F5: what the fetch-time environment blanks, neutralizes and forwards."""
    env = unittest.begin(ctx)
    host = host_info("linux", "amd64")

    ambient = make_ocx_env(_env_ctx(env = _AMBIENT), host, False).env
    asserts.equals(env, "/home/u/.ocx", ambient["OCX_HOME"])
    asserts.equals(env, "/site/config.toml", ambient["OCX_CONFIG"])
    asserts.equals(env, "https://mirror.example", ambient["OCX_MIRRORS"])

    # Knobs that break rather than steer an invocation. OCX_GLOBAL and
    # OCX_QUIET are BooleanStrings with no empty spelling, so "0" and not ""
    # — which ocx logs as an invalid boolean on every single invocation.
    asserts.equals(env, "", ambient["OCX_PROJECT"])
    asserts.equals(env, "0", ambient["OCX_GLOBAL"])
    asserts.equals(env, "0", ambient["OCX_QUIET"])
    asserts.equals(env, "1", ambient["OCX_NO_CONFIG_REFRESH"])

    # OCX_NO_PROJECT is pinned on, closing the CWD walk the package tier would
    # otherwise run from the fetch directory. An ambient "0" reopens it.
    asserts.equals(env, "1", ambient["OCX_NO_PROJECT"])

    # S-005: the weakening knobs are explicit-only. An OCX_NO_VERIFY exported
    # by whatever shell or CI image started Bazel must not decide what this
    # build verifies — with no ocx.policy() tag both read "0", and their
    # presence is what shadows the inherited "1".
    asserts.equals(env, "0", ambient.get("OCX_NO_VERIFY", "<absent>"))
    asserts.equals(env, "0", ambient.get("OCX_ALLOW_YANKED", "<absent>"))

    # S-002: the resolved policy is the only thing that can loosen either.
    loose = make_ocx_env(
        _env_ctx(env = _AMBIENT, allow_unverified = True, allow_yanked = True),
        host,
        False,
    ).env
    asserts.equals(env, "1", loose.get("OCX_NO_VERIFY", "<absent>"))
    asserts.equals(env, "1", loose.get("OCX_ALLOW_YANKED", "<absent>"))

    # no_config: OCX_NO_CONFIG prunes only the *discovered* tiers. Without
    # these three blanks an ambient OCX_PATCHES becomes the only patch source
    # left in a build that asked for hermeticity.
    hermetic = _env_ctx(env = _AMBIENT, no_config = True)
    blanked = make_ocx_env(hermetic, host, False).env
    asserts.equals(env, "1", blanked["OCX_NO_CONFIG"])
    for key in ["OCX_CONFIG", "OCX_PATCHES", "OCX_PATCH_SNAPSHOT"]:
        asserts.equals(env, "", blanked[key], key + " survived no_config")

    # C-003/C-009: a trust root is not a config tier, so no_config leaves it
    # alone — with no_config plus a `config` label carrying [[trust.policy]],
    # ocx still reads the env rung and then the OCX_HOME one. Both are watched
    # outside the gate, or an edit to either would not refetch.
    asserts.equals(env, "/site/trusted-root.json", blanked.get("OCX_SIGSTORE_TRUSTED_ROOT", "<absent>"))
    asserts.true(
        env,
        "/site/trusted-root.json" in hermetic.watched,
        "the surviving ambient trust root is not watched",
    )
    asserts.true(
        env,
        "/home/u/.ocx/sigstore/trusted-root.json" in hermetic.watched,
        "the OCX_HOME trust-root rung is watched outside the no_config gate",
    )

    # The attrs are what the caller did ask for, so they are reinstated over
    # the blanks — but OCX_PATCHES has no attr and stays closed.
    attrs = make_ocx_env(
        _env_ctx(
            env = _AMBIENT,
            no_config = True,
            config = "/w/cfg.toml",
            patch_snapshot = "/w/snap.json",
        ),
        host,
        False,
    ).env
    asserts.equals(env, "/w/cfg.toml", attrs["OCX_CONFIG"])
    asserts.equals(env, "/w/snap.json", attrs["OCX_PATCH_SNAPSHOT"])
    asserts.equals(env, "", attrs["OCX_PATCHES"])

    # A translucent label attr replaces the ambient value and is watched
    # through ctx.path(); the shadowed ambient file is not, since nothing
    # reads it any more.
    pinned = _env_ctx(env = _AMBIENT, sigstore_trusted_root = "/w/trusted-root.json")
    asserts.equals(
        env,
        "/w/trusted-root.json",
        make_ocx_env(pinned, host, False).env.get("OCX_SIGSTORE_TRUSTED_ROOT", "<absent>"),
    )
    asserts.false(
        env,
        "/site/trusted-root.json" in pinned.watched,
        "the shadowed ambient trust root is still watched",
    )

    # A `file://` trust root is a spelling ocx accepts at exactly this door
    # (FileReference::parse, ocx-sh/ocx#379), so it is forwarded verbatim
    # instead of being refused as a relative path — and left unwatched, since
    # ctx.watch() has no path to take. The watch fails open there. Case-
    # insensitive, matching the prefix ocx consumes; the guard cases pin the
    # other half — no other row and no other scheme takes this branch.
    url = _env_ctx(env = dict(_AMBIENT, OCX_SIGSTORE_TRUSTED_ROOT = "FILE:///opt/trusted-root.json"))
    asserts.equals(
        env,
        "FILE:///opt/trusted-root.json",
        make_ocx_env(url, host, False).env.get("OCX_SIGSTORE_TRUSTED_ROOT", "<absent>"),
    )
    url = _env_ctx(env = dict(_AMBIENT, OCX_SIGSTORE_TRUSTED_ROOT = "file:///opt/trusted-root.json"))
    asserts.equals(
        env,
        "file:///opt/trusted-root.json",
        make_ocx_env(url, host, False).env.get("OCX_SIGSTORE_TRUSTED_ROOT", "<absent>"),
    )
    asserts.false(
        env,
        "file:///opt/trusted-root.json" in url.watched,
        "a file:// trust root was handed to ctx.watch()",
    )

    # isolated_home moves the store inside the repository being fetched, which
    # cannot be watched — so ocx's ~/.ocx rung is dropped rather than pointed
    # at a path that will not exist on the next machine.
    isolated = _env_ctx(env = _AMBIENT)
    asserts.equals(env, "/repo/.ocx_home", make_ocx_env(isolated, host, True).env["OCX_HOME"])
    asserts.false(
        env,
        "/repo/.ocx_home/sigstore/trusted-root.json" in isolated.watched,
        "isolated_home still watches an in-repository trust root",
    )
    return unittest.end(env)

def _stage_lazy_config_test_impl(ctx):
    """F4: a lazy launcher re-exports the same blanking at action time."""
    env = unittest.begin(ctx)

    # The launcher re-enters ocx with the *action's* ambient environment, so
    # the fetch-time blanks would never reach it without these exports.
    exports = stage_lazy_config(_env_ctx(no_config = True), False).exports
    asserts.equals(env, "1", exports["OCX_NO_CONFIG"])
    for key in ["OCX_CONFIG", "OCX_PATCHES", "OCX_PATCH_SNAPSHOT"]:
        asserts.equals(env, "", exports.get(key, "<not exported>"), key + " survived no_config")

    # C-010: nothing configured still exports the weakening pair. The action
    # environment is the executor's, so an ambient OCX_NO_VERIFY there would
    # otherwise decide what the deferred fetch verifies — the same hole the
    # fetch path closes, one process later.
    asserts.equals(
        env,
        {"OCX_NO_VERIFY": "0", "OCX_ALLOW_YANKED": "0"},
        stage_lazy_config(_env_ctx(), False).exports,
    )
    asserts.equals(
        env,
        {"OCX_NO_VERIFY": "1", "OCX_ALLOW_YANKED": "1"},
        stage_lazy_config(_env_ctx(allow_unverified = True, allow_yanked = True), False).exports,
    )

    # A staged file travels as a runfile and is resolved through runfiles, not
    # as the fetch-time absolute path.
    staged = stage_lazy_config(_env_ctx(no_config = True, config = "//w:cfg.toml"), False)
    asserts.equals(env, "$(rlocation test_repo/config.toml)", staged.exports["OCX_CONFIG"])
    asserts.equals(env, "", staged.exports["OCX_PATCH_SNAPSHOT"])
    asserts.equals(env, [":config.toml"], staged.data)

    # S-010: a remote executor has no OCX_HOME, so a committed trusted root
    # only reaches ocx as a runfile. no_config does not blank it — a trust
    # root is not a config tier.
    root = stage_lazy_config(
        _env_ctx(no_config = True, sigstore_trusted_root = "//w:trusted-root.json"),
        False,
    )
    asserts.equals(
        env,
        "$(rlocation test_repo/trusted-root.json)",
        root.exports.get("OCX_SIGSTORE_TRUSTED_ROOT", "<absent>"),
    )
    asserts.true(env, ":trusted-root.json" in root.data, "the trusted root is not attached as a runfile")

    # Translucent in lazy mode: with no attr the key is deliberately absent,
    # so the executor's own site environment stays authoritative. Exporting a
    # fetch-time ambient value here would bake one machine's answer into every
    # action key.
    site = stage_lazy_config(_env_ctx(env = _AMBIENT), False)
    asserts.false(
        env,
        "OCX_SIGSTORE_TRUSTED_ROOT" in site.exports,
        "an unset translucent attr must not be exported into the action environment",
    )
    return unittest.end(env)

# W17/F5: the env vars AGENTS.md pins as forwarded to every ocx invocation —
# the site and translucent rows of OCX_ENV_CLASSES, in table order. getenv()
# is what registers them with Bazel, so dropping one silently stops a build
# from re-fetching when it changes.
_PASSTHROUGH_ENV = [
    "OCX_MIRRORS",
    "OCX_INSECURE_REGISTRIES",
    "OCX_OFFLINE",
    "OCX_FROZEN",
    "OCX_REMOTE",
    "OCX_JOBS",
    "OCX_INDEX",
    "OCX_DEFAULT_REGISTRY",
    "OCX_MANAGED_CONFIG",
    "OCX_PATCHES",
    "OCX_CONFIG",
    "OCX_PATCH_SNAPSHOT",
    "OCX_SIGSTORE_TRUSTED_ROOT",
    "OCX_NO_CONFIG",
]

def _passthrough_env_test_impl(ctx):
    """W17/F5: all 14 forwarded env vars, and nothing else."""
    env = unittest.begin(ctx)
    forwarded = [key for key, row in OCX_ENV_CLASSES.items() if row.cls in ["site", "translucent"]]
    asserts.equals(env, _PASSTHROUGH_ENV, forwarded)
    asserts.equals(env, 14, len(forwarded))

    # The weakening pair is explicit-only: reading either with getenv() puts
    # an ambient value back in charge of what the build verifies and accepts,
    # which is the whole point of ocx.policy(). Tracked-and-wrong is still
    # wrong — invalidation records that the answer changed, never that it was
    # weakened.
    for key in ["OCX_NO_VERIFY", "OCX_ALLOW_YANKED"]:
        asserts.false(env, key in forwarded, key + " must never be read from the environment")

    # Resolved or pinned, never forwarded verbatim.
    for key in ["OCX_HOME", "OCX_NO_CONFIG_REFRESH", "OCX_PROJECT", "OCX_GLOBAL", "OCX_QUIET", "OCX_NO_PROJECT"]:
        asserts.false(env, key in forwarded, key + " is not a passthrough")
    return unittest.end(env)

# F1: names ocx's own `BinaryName` grammar admits

def _run_ocx_retry_test_impl(ctx):
    """F2: only a transient sysexit buys another registry round-trip."""
    env = unittest.begin(ctx)

    # 75 is ocx's own "transient, retry me" — retried even when the caller
    # asked for no retries at all.
    calls = []
    sleeps = []
    asserts.equals(env, "out0", _run_ocx(_replay_ctx([75, 75, 0], calls, sleeps), retries = 0))
    asserts.equals(env, 3, len(calls))

    # The backoff shells out to an absolute /bin/sh, but the bare `sleep` in
    # it would resolve against whatever PATH the repository rule inherited
    # (CWE-426) — so the exec carries its own.
    asserts.equals(env, 2, len(sleeps))
    asserts.equals(env, {"PATH": "/usr/bin:/bin"}, sleeps[0])

    # 74 is the store-symlink TOCTOU two parallel fetches race on: retried up
    # to the caller's budget.
    calls = []
    asserts.equals(env, "out0", _run_ocx(_replay_ctx([74, 0], calls), retries = 2))
    asserts.equals(env, 2, len(calls))

    # 69 is a registry that may simply come back.
    calls = []
    asserts.equals(env, "out0", _run_ocx(_replay_ctx([69, 0], calls), retries = 2))
    asserts.equals(env, 2, len(calls))

    # A first-attempt success costs exactly one call.
    calls = []
    asserts.equals(env, "out0", _run_ocx(_replay_ctx([0], calls), retries = 2))
    asserts.equals(env, 1, len(calls))
    return unittest.end(env)

def _run_ocx(fake, retries = 0, hints = {}):
    """run_ocx() against a fake ctx, with the arguments a test does not vary."""
    return run_ocx(fake, "/fake/ocx", ["install", "pkg"], {}, "installing pkg", False, hints = hints, retries = retries)

# F1: names ocx's own `BinaryName` grammar admits — it forbids only
# `/ \ < > : " | ? *` and non-graphic ASCII — that reach a generated BUILD
# file, a launcher script and a file name verbatim.
_HOSTILE_BIN_NAMES = [
    "$(touch PWNED)",
    "`id`",
    "semi;colon",
    "-rf",
    "..",
    "sp ace",
    "pipe|d",
]

# F1: the shapes real tools ship, which the charset must keep admitting.
_REAL_BIN_NAMES = ["jq", "git-lfs", "python3.11", "clang++", "x86_64-linux-gnu-gcc", "_hidden"]

def _bin_name_guard_test_impl(ctx):
    """F1: an injecting publisher-declared name never reaches a renderer."""
    env = unittest.begin(ctx)
    names = _REAL_BIN_NAMES + _HOSTILE_BIN_NAMES
    got = discover_bins(
        _fs_ctx(files = ["/store/aa/content/bin/" + n for n in names]),
        json.encode({"packages": [_closure_package("ocx.sh/a/a:1@sha256:aa", names)]}),
        "ocx inspect --closure",
        _ENTRIES,
        False,
    )

    # Legitimate names survive unchanged; nothing else is rendered at all.
    asserts.equals(env, _REAL_BIN_NAMES, [b.name for b in got.bins])

    # Dropped rather than fatal: one third-party package's bad metadata must
    # not break an unrelated consumer's build. Recorded so it stays visible.
    asserts.equals(env, _HOSTILE_BIN_NAMES, got.rejected)

    # Closing the loop on the sinks themselves. A name carrying `"` would end
    # the native_binary(name = "…") literal early and turn the rest of the
    # generated BUILD into attacker-authored top-level Starlark, which Bazel
    # evaluates on any build, query or test.
    build = render_launchers_build(got.bins, False)
    for hostile in _HOSTILE_BIN_NAMES:
        asserts.false(env, hostile in build, hostile + " reached the generated BUILD")
    for b in got.bins:
        script = render_launcher(_ENTRIES, b.target, "/home/u/.ocx", "/repo/ocx", False)
        asserts.true(env, script.endswith("exec '{}' \"$@\"\n".format(b.target)))
    return unittest.end(env)

def _scan_fallback_test_impl(ctx):
    """F5: an incomplete `binaries` claim scans PATH instead of trusting it."""
    env = unittest.begin(ctx)
    got = discover_bins(
        _fs_ctx(
            files = ["/store/aa/content/bin/declared", "/store/aa/content/bin/private-helper"],
            listing = {"/store/aa/content/bin": ["declared", "private-helper"]},
        ),
        json.encode({"packages": [
            _closure_package("ocx.sh/legacy:1@sha256:cc", ["declared"], complete = False),
        ]}),
        "ocx inspect --closure",
        _ENTRIES,
        False,
    )
    asserts.equals(env, ["ocx.sh/legacy:1@sha256:cc"], got.scanned)

    # The scan is what exposes the package's private executables — inverting
    # the branch yields only the declared name and an empty `scanned`.
    asserts.equals(env, ["declared", "private-helper"], [b.name for b in got.bins])

    # A complete claim takes the declared path: the private executable on the
    # same directory is not a target.
    complete = discover_bins(
        _fs_ctx(
            files = ["/store/aa/content/bin/declared", "/store/aa/content/bin/private-helper"],
            listing = {"/store/aa/content/bin": ["declared", "private-helper"]},
        ),
        json.encode({"packages": [_closure_package("ocx.sh/a/a:1@sha256:aa", ["declared"])]}),
        "ocx inspect --closure",
        _ENTRIES,
        False,
    )
    asserts.equals(env, [], complete.scanned)
    asserts.equals(env, ["declared"], [b.name for b in complete.bins])
    return unittest.end(env)

def _windows_scan_test_impl(ctx):
    """F6: a Windows PATH scan keys on the extension — and must still stat."""
    env = unittest.begin(ctx)
    got = discover_bins(
        _fs_ctx(
            files = ["C:/store/bin/jq.exe", "C:/store/bin/build.cmd"],
            dirs = ["C:/store/bin/tools.exe"],
            listing = {"C:/store/bin": ["jq.exe", "tools.exe", "build.cmd", "readme.txt"]},
        ),
        json.encode({"packages": [
            _closure_package("ocx.sh/legacy:1@sha256:cc", [], complete = False),
        ]}),
        "ocx package inspect --closure",
        [{"key": "PATH", "value": "C:/store/bin", "type": "path"}],
        True,
    )

    # A directory named `tools.exe` is not a tool — the same rejection
    # resolve_bins() makes on the declared path. `readme.txt` is not either.
    asserts.equals(env, ["jq", "build"], [b.name for b in got.bins])
    asserts.equals(env, ["C:/store/bin/jq.exe", "C:/store/bin/build.cmd"], [b.target for b in got.bins])
    return unittest.end(env)

def _resolve_bins_order_test_impl(ctx):
    """F5: first PATH directory holding a real file wins; a directory does not."""
    env = unittest.begin(ctx)

    # `exists` is true for a directory too, and a launcher exec-ing one dies at
    # action time with a bare "Permission denied" — so the first candidate in
    # search order (the LAST declared entry) must be skipped in favour of the
    # other directory's regular file.
    got = discover_bins(
        _fs_ctx(
            files = ["/store/aa/content/bin/jq"],
            dirs = ["/store/bb/content/jq"],
        ),
        json.encode({"packages": [_closure_package("ocx.sh/a/a:1@sha256:aa", ["jq"])]}),
        "ocx inspect --closure",
        _ENTRIES,
        False,
    )
    asserts.equals(env, ["/store/aa/content/bin/jq"], [b.target for b in got.bins])

    # Both real: the LAST declared PATH entry wins — an ocx consumer prepends
    # each entry in order, so effective search precedence is the reverse of the
    # declaration order.
    first = discover_bins(
        _fs_ctx(files = ["/store/aa/content/bin/jq", "/store/bb/content/jq"]),
        json.encode({"packages": [_closure_package("ocx.sh/a/a:1@sha256:aa", ["jq"])]}),
        "ocx inspect --closure",
        _ENTRIES,
        False,
    )
    asserts.equals(env, ["/store/bb/content/jq"], [b.target for b in first.bins])
    return unittest.end(env)

def _sh_launcher_quoting_test_impl(ctx):
    """F1: publisher-controlled env values and store paths render inert."""
    env = unittest.begin(ctx)
    script = render_launcher(
        [
            {"key": "GREETING", "value": "$(touch PWNED)", "type": "constant"},
            {"key": "QUOTED", "value": "it's", "type": "constant"},
            {"key": "PATH", "value": "/store/`id`/bin", "type": "path"},
            {"key": "bad key", "value": "x", "type": "constant"},
            {"key": "1BAD", "value": "x", "type": "constant"},
        ],
        # The name is charset-guarded, but the directory it is joined onto
        # comes from `ocx env` — so the exec target is publisher-controlled too.
        "/store/$(touch PWNED)/bin/jq",
        "/home/u/.ocx",
        "/repo/ocx",
        False,
    )
    asserts.true(env, "export GREETING='$(touch PWNED)'" in script)
    asserts.true(env, "export QUOTED='it'\\''s'" in script)

    # The `${PATH:+…}` suffix must stay expandable, the value must not.
    asserts.true(env, "export PATH='/store/`id`/bin'\"${PATH:+:${PATH}}\"" in script)
    asserts.true(env, script.endswith("exec '/store/$(touch PWNED)/bin/jq' \"$@\"\n"))

    # A key that is not a shell identifier has no safe `export` at all.
    asserts.false(env, "bad key" in script)
    asserts.false(env, "1BAD" in script)
    return unittest.end(env)

def _bat_launcher_quoting_test_impl(ctx):
    """F1: `set "K=V"` breaks on a literal `%` or `"` in a hostile value."""
    env = unittest.begin(ctx)
    script = render_launcher(
        [
            {"key": "PCT", "value": "100%OCX_HOME%", "type": "constant"},
            {"key": "QUOTE", "value": 'ev"il', "type": "constant"},
            {"key": "PATH", "value": "C:\\store\\bin", "type": "path"},
        ],
        "C:\\store\\bin\\jq.exe",
        "C:\\Users\\u\\.ocx",
        "C:\\repo\\ocx.exe",
        True,
    )

    # `%%` is the literal percent of a batch file; an unescaped one expands.
    asserts.true(env, 'set "PCT=100%%OCX_HOME%%"' in script)

    # A literal quote closes the quoted region and has no in-place escape, so
    # the entry is dropped rather than rendered.
    asserts.false(env, "QUOTE" in script)

    # The trailing `%PATH%` is a real expansion and must survive.
    asserts.true(env, 'set "PATH=C:\\store\\bin;%PATH%"' in script)
    return unittest.end(env)

def _sh_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    script = render_launcher(_ENTRIES, "/store/aa/content/bin/tool", "/home/u/.ocx", "/repo/ocx", False)
    asserts.true(env, script.startswith("#!/usr/bin/env bash"))
    asserts.true(env, "export OCX_HOME='/home/u/.ocx'" in script)
    asserts.true(env, "export OCX_BINARY_PIN='/repo/ocx'" in script)

    # Both path values joined in REVERSE declaration order, existing value
    # appended: ocx prepends each entry in turn, so the last one ends up first.
    asserts.true(env, "export PATH='/store/bb/content:/store/aa/content/bin'\"${PATH:+:${PATH}}\"" in script)

    # ocx's prepend is move-to-front, so a repeated value is not duplicated —
    # it keeps only its last (highest-precedence) declaration.
    deduped = render_launcher(
        _ENTRIES + [{"key": "PATH", "value": "/store/aa/content/bin", "type": "path"}],
        "/store/aa/content/bin/tool",
        "/home/u/.ocx",
        "/repo/ocx",
        False,
    )
    asserts.true(env, "export PATH='/store/aa/content/bin:/store/bb/content'\"${PATH:+:${PATH}}\"" in deduped)

    # An empty value never becomes an empty PATH element (the action's CWD);
    # a key left with nothing is omitted entirely, not exported empty.
    hardened = render_launcher(
        _ENTRIES + [
            {"key": "PATH", "value": "", "type": "path"},
            {"key": "GOPATH", "value": "", "type": "path"},
        ],
        "/store/aa/content/bin/tool",
        "/home/u/.ocx",
        "/repo/ocx",
        False,
    )
    asserts.true(env, "export PATH='/store/bb/content:/store/aa/content/bin'\"${PATH:+:${PATH}}\"" in hardened)
    asserts.false(env, "GOPATH" in hardened)

    # Constants replace.
    asserts.true(env, "export JAVA_HOME='/store/cc/content'" in script)
    asserts.true(env, script.endswith("exec '/store/aa/content/bin/tool' \"$@\"\n"))

    # Eager launchers never re-enter ocx for resolution, so the fetch-time
    # config must not leak into them.
    asserts.false(env, "OCX_CONFIG" in script)
    asserts.false(env, "OCX_PATCH_SNAPSHOT" in script)
    return unittest.end(env)

def _list_modifier_test_impl(ctx):
    env = unittest.begin(ctx)

    def sh(entries):
        return render_launcher(entries, "/store/aa/content/bin/tool", "/home/u/.ocx", "/repo/ocx", False)

    def item(value, separator = None):
        entry = {"key": "JDK_JAVA_OPTIONS", "value": value, "type": "list"}
        if separator != None:
            entry["separator"] = separator
        return entry

    # A list entry appends BEHIND the invoking value, and yields the bare value
    # when there is none — so it is a conditional, not the `${K:+…}` one-liner
    # a path entry gets, which would leave a leading separator on an unset key.
    # An absent `separator` folds with ocx's default, a space.
    asserts.true(env, (
        'if [ -n "${JDK_JAVA_OPTIONS:-}" ]; then export JDK_JAVA_OPTIONS="${JDK_JAVA_OPTIONS}"\' \'\'-ea\'; ' +
        "else export JDK_JAVA_OPTIONS='-ea'; fi"
    ) in sh([item("-ea")]))

    # Two contributions to one key fold against each other in DECLARATION
    # order — forward, unlike a path key, because ocx appends at the back.
    asserts.true(env, "export JDK_JAVA_OPTIONS=\"${JDK_JAVA_OPTIONS}\"' ''-ea -Xmx1g'" in sh([
        item("-ea"),
        item("-Xmx1g"),
    ]))

    # Re-contributing a value moves it to the back rather than duplicating it
    # (ocx's append_unique: last applier wins for a last-wins consumer).
    asserts.true(env, "export JDK_JAVA_OPTIONS=\"${JDK_JAVA_OPTIONS}\"' ''-Xmx1g -ea'" in sh([
        item("-ea"),
        item("-Xmx1g"),
        item("-ea"),
    ]))

    # An explicit separator is used for both the fold and the ambient join.
    asserts.true(env, "export GODEBUG=\"${GODEBUG}\"',''gctrace=1,madvdontneed=1'" in sh([
        {"key": "GODEBUG", "value": "gctrace=1", "type": "list", "separator": ","},
        {"key": "GODEBUG", "value": "madvdontneed=1", "type": "list", "separator": ","},
    ]))

    # An empty contribution is a no-op — on an absent key too, where a path
    # entry would still create one. Appending nothing must not export a key.
    asserts.false(env, "JDK_JAVA_OPTIONS" in sh([item("")]))

    # Windows: same fold, same append-behind, spelled with `if defined`.
    bat = render_launcher(
        [item("-ea"), item("-Xmx1g")],
        "C:\\store\\tool.exe",
        "C:\\Users\\u\\.ocx",
        "C:\\repo\\ocx.exe",
        True,
    )
    asserts.true(env, (
        'if defined JDK_JAVA_OPTIONS (set "JDK_JAVA_OPTIONS=%JDK_JAVA_OPTIONS% -ea -Xmx1g") ' +
        'else (set "JDK_JAVA_OPTIONS=-ea -Xmx1g")'
    ) in bat)

    # A list entry rides alongside the other two kinds without disturbing them.
    mixed = sh(_ENTRIES + [item("-ea")])
    asserts.true(env, "export PATH='/store/bb/content:/store/aa/content/bin'\"${PATH:+:${PATH}}\"" in mixed)
    asserts.true(env, "export JAVA_HOME='/store/cc/content'" in mixed)
    return unittest.end(env)

def _bat_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    script = render_launcher(_ENTRIES, "C:\\store\\tool.exe", "C:\\Users\\u\\.ocx", "C:\\repo\\ocx.exe", True)
    asserts.true(env, script.startswith("@echo off"))

    # Reverse declaration order here too — same prepend semantics as POSIX.
    asserts.true(env, 'set "PATH=/store/bb/content;/store/aa/content/bin;%PATH%"' in script)
    asserts.true(env, 'set "JAVA_HOME=/store/cc/content"' in script)
    asserts.true(env, '"C:\\store\\tool.exe" %*' in script)
    return unittest.end(env)

# C-011: every pinned OCX_ENV_CLASSES row except OCX_QUIET, in table order,
# as one contiguous block — order and adjacency together are what a single
# `in` check can prove. Held as a block so the per-line count assertions below
# stay the only place that could pass on a duplicated export.
# Assigned then exported, never `export K="$(…)"`: a command substitution in a
# declaration builtin does not propagate its exit status, so `set -e` would not
# fire on a failed rlocation.
_PINNED_EXPORTS_SH = "\n".join([
    'OCX_PROJECT=""',
    "export OCX_PROJECT",
    'OCX_GLOBAL="0"',
    "export OCX_GLOBAL",
    'OCX_NO_PROJECT="1"',
    "export OCX_NO_PROJECT",
    'OCX_NO_CONFIG_REFRESH="1"',
    "export OCX_NO_CONFIG_REFRESH",
])

_PINNED_EXPORTS_BAT = "\r\n".join([
    'set "OCX_PROJECT="',
    'set "OCX_GLOBAL=0"',
    'set "OCX_NO_PROJECT=1"',
    'set "OCX_NO_CONFIG_REFRESH=1"',
])

def _sh_lazy_launcher_test_impl(ctx):
    env = unittest.begin(ctx)
    script = render_lazy_launcher(
        ['"$(rlocation repo+ocx_tool/ocx)"', "package", "exec", "'ocx.sh/jq@sha256:abc'", "--", "jq"],
        False,
        exports = {
            "OCX_NO_CONFIG": "1",
            "OCX_CONFIG": "$(rlocation repo+pkg/config.toml)",
        },
    )
    asserts.true(env, script.startswith("#!/usr/bin/env bash"))

    # Machine-independent: runfiles resolution, no absolute paths, no baked store.
    asserts.true(env, "runfiles.bash initialization" in script)
    asserts.false(env, "OCX_HOME" in script)

    # C-011: the pinned rows, in table order, each exactly once, before the
    # caller's own exports. OCX_GLOBAL is a BooleanString: "0" is falsy, ""
    # is invalid and makes ocx log a warning on every launcher-run tool.
    pinned_at = script.find(_PINNED_EXPORTS_SH)
    asserts.true(env, pinned_at >= 0, "the pinned rows are missing or out of table order")
    for line in _PINNED_EXPORTS_SH.split("\n"):
        asserts.equals(env, 1, script.count(line), line + " is not emitted exactly once")
    asserts.true(
        env,
        pinned_at >= 0 and pinned_at < script.find('OCX_NO_CONFIG="1"'),
        "the pinned rows must precede the caller's own exports",
    )

    # OCX_QUIET is absent by design, though the fetch-time environment
    # neutralizes it: no JSON report is parsed at action time, so a
    # launcher-run tool's own verbosity stays the user's to set.
    asserts.false(env, "OCX_QUIET" in script)

    # Staged config travels with the launcher, resolved through runfiles.
    asserts.true(env, 'OCX_NO_CONFIG="1"' in script)
    asserts.true(env, "\nexport OCX_NO_CONFIG\n" in script)
    asserts.true(env, 'OCX_CONFIG="$(rlocation repo+pkg/config.toml)"' in script)
    asserts.true(env, "\nexport OCX_CONFIG\n" in script)
    asserts.false(env, 'OCX_CONFIG="/' in script)
    asserts.true(env, script.index('OCX_CONFIG="$(rlocation') < script.index("\nexec "))

    # A runfiles miss is not detectable from rlocation's exit status: with a
    # runfiles *manifest* present it answers 0 and an empty string, and an
    # empty OCX_CONFIG is ocx's documented "treat as unset" — the staged site
    # config would vanish into a green build. Only rlocation rows carry it.
    asserts.true(
        env,
        '[ -n "$OCX_CONFIG" ] || { echo "rules_ocx: OCX_CONFIG runfile missing" >&2; exit 74; }' in script,
        "the staged runfiles row is not guarded against an empty rlocation",
    )
    asserts.false(env, '[ -n "$OCX_PROJECT" ]' in script, "a pinned row must not carry a runfiles guard")
    asserts.true(env, script.endswith(
        "exec \"$(rlocation repo+ocx_tool/ocx)\" package exec 'ocx.sh/jq@sha256:abc' -- jq \"$@\"\n",
    ))
    return unittest.end(env)

def _bat_lazy_launcher_test_impl(ctx):
    env = unittest.begin(ctx)

    # C-015: the argv comes from the builder, so the launcher and the tests
    # cannot disagree about which ocx verb the Windows arm re-enters.
    script = render_lazy_launcher(
        lazy_project_command('"C:\\repo\\ocx.exe"', '"C:\\repo\\ocx.toml"', [], "shellcheck"),
        True,
        exports = {"OCX_CONFIG": "C:\\repo\\config.toml"},
    )
    asserts.true(env, script.startswith("@echo off"))
    asserts.true(env, _PINNED_EXPORTS_BAT in script, "the pinned rows are missing or out of table order")
    for line in _PINNED_EXPORTS_BAT.split("\r\n"):
        asserts.equals(env, 1, script.count(line), line + " is not emitted exactly once")
    asserts.false(env, "OCX_QUIET" in script)
    asserts.true(env, 'set "OCX_CONFIG=C:\\repo\\config.toml"' in script)
    asserts.true(
        env,
        '"C:\\repo\\ocx.exe" --project "C:\\repo\\ocx.toml" exec -- shellcheck %*' in script,
        "the rendered Windows launcher does not re-enter `ocx exec`",
    )

    # Every Batch value goes through bat_value(), like every other rendered
    # Batch value: a `%` in the output-base path a staged file resolves to
    # would otherwise open a variable expansion and mangle it.
    escaped = render_lazy_launcher(
        lazy_project_command('"C:\\ocx.exe"', '"C:\\t.toml"', [], "jq"),
        True,
        exports = {"OCX_CONFIG": "C:\\out%1\\config.toml"},
    )
    asserts.true(env, 'set "OCX_CONFIG=C:\\out%%1\\config.toml"' in escaped)
    return unittest.end(env)

def _env_bzl_test_impl(ctx):
    env = unittest.begin(ctx)
    content = render_env_bzl(_ENTRIES, "/home/u/.ocx")

    # Must be valid Starlark that round-trips the entries through JSON.
    asserts.true(env, "OCX_ENV = _DATA[\"entries\"]" in content)
    asserts.true(env, "OCX_HOME = _DATA[\"home\"]" in content)
    asserts.true(env, "/store/aa/content/bin" in content)

    # The unvalidated PATH-scan fallback is recorded in the generated repo:
    # empty when every target came from declared metadata, else the packages
    # that forced it.
    asserts.true(env, "OCX_SCANNED_PACKAGES = _DATA[\"scanned\"]" in content)
    asserts.false(env, "ocx.sh/legacy:latest" in content)
    asserts.true(env, "ocx.sh/legacy:latest" in render_env_bzl(
        _ENTRIES,
        "/home/u/.ocx",
        ["ocx.sh/legacy:latest@sha256:cc"],
    ))
    return unittest.end(env)

def _closure_package(identifier, binaries, complete = True, entrypoints = []):
    """A well-formed `packages` entry: both surface arrays, always serialized.

    `binaries` and `entrypoints` are parallel BinaryAttribution arrays that
    may claim the same name, and `SurfaceOut` emits both unconditionally, so
    every fixture carries both — an absent `entrypoints` is shape drift.
    """
    return {
        "identifier": identifier,
        "closure": {
            "surface": {
                "interface": {
                    "binaries": [{"name": n, "package": identifier} for n in binaries],
                    "entrypoints": [{"name": n, "package": identifier} for n in entrypoints],
                    "binaries_complete": complete,
                },
            },
        },
    }

def _declared_bins_test_impl(ctx):
    env = unittest.begin(ctx)

    surface = declared_bins([
        _closure_package("ocx.sh/a/a:latest@sha256:aa", ["shellcheck"]),
        _closure_package("ocx.sh/b/b:latest@sha256:bb", ["shfmt", "shellcheck"]),
    ])

    # Declaration order; the first claim of a name wins the dedup — one target
    # per name, whichever file it later resolves to.
    asserts.equals(env, ["shellcheck", "shfmt"], surface.names)
    asserts.equals(env, [], surface.incomplete)

    # An empty complete claim is a real answer: the package exposes nothing.
    asserts.equals(env, [], declared_bins([_closure_package("ocx.sh/c/c:latest", [])]).names)

    # The command surface is the UNION of both arrays, entrypoints first within
    # a package — ocx pushes the synthetic `entrypoints/` PATH entry last, so it
    # ends up at the front of PATH and shadows `bin/`.
    union = declared_bins([
        _closure_package(
            "ocx.sh/a/a:latest@sha256:aa",
            ["shellcheck", "shfmt"],
            entrypoints = ["wrapped", "shellcheck"],
        ),
    ])
    asserts.equals(env, ["wrapped", "shellcheck", "shfmt"], union.names)

    # An entrypoints-only package still exposes commands: `binaries_complete`
    # covers `binaries` alone, and an entrypoint claim is always authoritative.
    only = declared_bins([_closure_package("ocx.sh/e/e:latest@sha256:ee", [], entrypoints = ["ep"])])
    asserts.equals(env, ["ep"], only.names)
    asserts.equals(env, [], only.incomplete)

    # …and an incomplete `binaries` claim still poisons the batch even when the
    # entrypoints are authoritative: the union is a subset of what is on PATH.
    asserts.equals(env, ["ocx.sh/f/f:latest@sha256:ff"], declared_bins([
        _closure_package("ocx.sh/f/f:latest@sha256:ff", [], complete = False, entrypoints = ["ep"]),
    ]).incomplete)

    # One incomplete package poisons the batch — the union is now a subset of PATH.
    mixed = declared_bins([
        _closure_package("ocx.sh/a/a:latest@sha256:aa", ["shellcheck"]),
        _closure_package("ocx.sh/legacy:latest@sha256:cc", [], complete = False),
    ])
    asserts.equals(env, ["ocx.sh/legacy:latest@sha256:cc"], mixed.incomplete)

    return unittest.end(env)

# The two PATH entries a package with entrypoints contributes, in the order ocx
# composes them: declared `bin/` first, synthetic `entrypoints/` last.
_ENTRYPOINT_ENTRIES = [
    {"key": "PATH", "value": "/store/aa/content/bin", "type": "path"},
    {"key": "PATH", "value": "/store/aa/entrypoints", "type": "path"},
]

def _entrypoints_surface_test_impl(ctx):
    """An entrypoint is a target, and its launcher shadows the same-named bin/."""
    env = unittest.begin(ctx)

    # (a) Declared path, not the scan fallback: `binaries_complete` is true and
    # the only claim is an entrypoint.
    only = discover_bins(
        _fs_ctx(files = ["/store/aa/entrypoints/ep"]),
        json.encode({"packages": [
            _closure_package("ocx.sh/a/a:1@sha256:aa", [], entrypoints = ["ep"]),
        ]}),
        "ocx inspect --closure",
        _ENTRYPOINT_ENTRIES,
        False,
    )
    asserts.equals(env, [], only.scanned)
    asserts.equals(env, ["ep"], [b.name for b in only.bins])
    asserts.equals(env, ["/store/aa/entrypoints/ep"], [b.target for b in only.bins])

    # (b) A name in both arrays is one target, and it resolves to the
    # `entrypoints/` file: that entry is declared last, so ocx prepends it last
    # and it wins lookup.
    both = discover_bins(
        _fs_ctx(files = ["/store/aa/content/bin/tool", "/store/aa/entrypoints/tool"]),
        json.encode({"packages": [
            _closure_package("ocx.sh/a/a:1@sha256:aa", ["tool"], entrypoints = ["tool"]),
        ]}),
        "ocx inspect --closure",
        _ENTRYPOINT_ENTRIES,
        False,
    )
    asserts.equals(env, ["tool"], [b.name for b in both.bins])
    asserts.equals(env, ["/store/aa/entrypoints/tool"], [b.target for b in both.bins])
    return unittest.end(env)

def _closure_packages_test_impl(ctx):
    """H5: a well-formed `inspect --closure` report passes through unchanged."""
    env = unittest.begin(ctx)

    # An incomplete `binaries` claim is well-formed — declared_bins() reports
    # it — so the guard must check that the key is present, not that it is true.
    packages = [
        _closure_package("ocx.sh/a/a:latest@sha256:aa", ["shellcheck"]),
        _closure_package("ocx.sh/b/b:latest@sha256:bb", [], complete = False),
    ]
    stdout = json.encode({"packages": packages, "resolved": 2})
    asserts.equals(env, packages, closure_packages(stdout, "ocx inspect --closure"))

    # Nothing to validate is not a drift: an empty surface is a real answer.
    asserts.equals(env, [], closure_packages(
        json.encode({"packages": []}),
        "ocx inspect --closure",
    ))
    return unittest.end(env)

# H5: reports that must be rejected. `packages` is serialized unconditionally,
# but a per-entry `closure` is absent for every non-closure body — the four
# keys declared_bins() indexes are exactly what drifts.
_MALFORMED_CLOSURE_REPORTS = {
    "no_closure": [{"identifier": "ocx.sh/a/a:latest@sha256:aa"}],
    "no_interface": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {}},
    }],
    "no_binaries": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {"entrypoints": [], "binaries_complete": True}}},
    }],
    # `SurfaceOut` serializes `entrypoints` unconditionally, so its absence is
    # drift — never "this package declares none", which is an empty list.
    "no_entrypoints": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {"binaries": [], "binaries_complete": True}}},
    }],
    "no_binaries_complete": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {"binaries": [], "entrypoints": []}}},
    }],
    # Present but not a bool: declared_bins() evaluates `not "false"` to False
    # in Starlark, so a stringified flag would record no `incomplete` and the
    # caller would skip the PATH scan the flag exists to trigger — a silent
    # partial surface. A presence check alone does not catch it.
    "binaries_complete_not_a_bool": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {
            "binaries": [],
            "entrypoints": [],
            "binaries_complete": "false",
        }}},
    }],
    # Present but not iterable as declared_bins() iterates it: a key check
    # alone passes this through to a raw traceback.
    "binaries_not_a_list": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {
            "binaries": "oops",
            "entrypoints": [],
            "binaries_complete": True,
        }}},
    }],
    "entrypoints_not_a_list": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": {"surface": {"interface": {
            "binaries": [],
            "entrypoints": "oops",
            "binaries_complete": True,
        }}},
    }],
    # declared_bins() indexes `identifier` for every incomplete package.
    "no_identifier": [{
        "closure": {"surface": {"interface": {
            "binaries": [],
            "entrypoints": [],
            "binaries_complete": False,
        }}},
    }],
    # EVERY entry is validated, not just the first.
    "second_entry_bad": [
        _closure_package("ocx.sh/a/a:latest@sha256:aa", ["shellcheck"]),
        {"identifier": "ocx.sh/b/b:latest@sha256:bb"},
    ],
    # A non-object entry: iterating an object walks its *keys*, so `pkg` is a
    # string and pkg.get() is "'string' value has no field or method 'get'" —
    # a traceback where this fail() is the whole point of the function.
    "entry_not_an_object": ["ocx.sh/a/a:latest@sha256:aa"],
    "closure_not_an_object": [{
        "identifier": "ocx.sh/a/a:latest@sha256:aa",
        "closure": "ocx.sh/a/a:latest@sha256:aa",
    }],
}

# The container, not an entry: the value of the top-level `packages` key, or
# its absence. ocx's own source carries the comment that `packages` is an
# array and not an object keyed by request string — so the object shape was on
# the table, and a guard that holds only for today's shape is not a guard.
_MALFORMED_CLOSURE_CONTAINERS = {
    "no_packages_key": {"resolved": 0},
    "packages_is_an_object": {"packages": {"ocx.sh/a/a": {"identifier": "x"}}},
    "packages_is_a_string": {"packages": "ocx.sh/a/a:latest@sha256:aa"},
    "report_is_a_list": [{"identifier": "ocx.sh/a/a:latest@sha256:aa"}],
}

def _bad_closure_report_impl(ctx):
    closure_packages(ctx.attr.report, "ocx inspect --closure")
    return []

# A fail() cannot be caught from a unittest impl, so the guard is exercised
# through a target whose analysis is expected to fail.
_bad_closure_report = rule(
    implementation = _bad_closure_report_impl,
    attrs = {"report": attr.string()},
)

# A Starlark failure echoes each frame's source line, so a fragment written
# literally into the assert below would match the echo whatever the code did.
# Held in a constant the call site cannot spell (.claude/rules/starlark.md).
_DRIFT_HINT = "it pins the ocx version"

def _closure_packages_guard_test_impl(ctx):
    """H5: a malformed report fails, naming the pin that has to move.

    The fragment is a phrase only the drift message spells — neither
    _bad_closure_report_impl nor closure_packages' own call site has it, so the
    traceback's source-line echo cannot satisfy it (.claude/rules/starlark.md).
    """
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, _DRIFT_HINT)
    return analysistest.end(env)

closure_packages_guard_test = analysistest.make(
    _closure_packages_guard_test_impl,
    expect_failure = True,
)

# A Starlark failure carries the traceback, and the traceback echoes the
# *source line* of every frame — so a fragment written literally into the call
# below would match the echo whatever the code did. Held in a constant so the
# call site cannot spell it.
_CALLSITE_HINT = "the call-site hint, not the shared table"

# Guards whose whole point is a fail(), which a unittest impl cannot catch:
# {case: fragment the message must carry}. Every case is exercised through a
# target whose analysis is expected to fail — a case that *succeeds* returns
# normally from _guard_impl and the analysistest reports it as a miss.
_GUARD_CASES = {
    # F2: a permanent sysexit must not buy a second registry round-trip. The
    # scripted 0 behind it succeeds if — and only if — the code was retried.
    "retry_79": "exit 79",
    "retry_80": "exit 80",
    "retry_81": "exit 81",
    "retry_65": "exit 65",
    # F5: a call-site hint beats the shared sysexits table.
    "hint_precedence": _CALLSITE_HINT,
    # F5: decode_json's own guard — every malformed-closure fixture is valid
    # JSON, so neither branch of it was exercised. Malformed (rather than
    # absent) output raises out of json.decode itself, which names neither the
    # command nor rules_ocx — so the fragment is json.decode's own wording.
    "decode_empty": "produced no output",
    "decode_garbage": "unexpected character",
    # F5: a relative OCX_HOME is caught before ctx.watch() tracebacks on it.
    "relative_home": "OCX_HOME must be absolute",
    # C-003: a relative ambient translucent `path` row is forwarded to ocx but
    # unwatchable, so it is refused rather than silently left unwatched. The
    # `file://` carve-out is scoped to the one row ocx parses as a file
    # reference and to that one scheme: on any other row (`OCX_CONFIG`, whose
    # value is a plain PathBuf::from) and under any other scheme the string is
    # a relative path to ocx, so the same refusal stands.
    "relative_translucent_path": "must be an absolute path",
    "file_url_wrong_row": "must be an absolute path",
    "url_wrong_scheme": "must be an absolute path",
    # F1: an explicitly declared bins entry is an error, not a silent drop.
    "bad_bins_attr": "cannot be a launcher",
    # F1: a batch file has no escape for a literal quote in the exec target.
    "bat_target_quote": "no escape inside a batch file",
    # F5: a modifier kind outside ocx's three is shape drift, not a constant.
    # The fragment is a phrase only UNKNOWN_MODIFIER_MSG spells — the case
    # below has to name the drifted type, and a traceback echoes that line, so
    # asserting on the type itself would match the echo and pass vacuously.
    "unknown_modifier": "reported modifier type",
    # C-008: the three sysexits 0.6.0's verifying fetch path made reachable.
    # Each case scripts a trailing 0 that is reached only on a retry, so the
    # same target proves the hint text *and* that _RETRYABLE did not grow —
    # S-006 rules out auto-retrying 83, which would cost three round-trips on
    # a settled transparency-log outage.
    "sysexit_83": "transparency log is unreachable",
    "sysexit_84": "does not support the OCI Referrers API",
    "sysexit_85": "signing key backend",
}

def _guard_impl(ctx):
    case = ctx.attr.case
    if case.startswith("retry_") or case.startswith("sysexit_"):
        # The trailing 0 is reached only when the leading code was retried.
        code = case.split("_")[1]
        _run_ocx(_replay_ctx([int(code), 0], []), retries = 2)
    elif case == "hint_precedence":
        # 65 has a shared hint too, so only precedence decides which is shown.
        _run_ocx(_replay_ctx([65], []), hints = {65: _CALLSITE_HINT})
    elif case == "decode_empty":
        decode_json("   \n", "ocx package env")
    elif case == "decode_garbage":
        decode_json("oops", "ocx package env")
    elif case == "relative_home":
        make_ocx_env(_env_ctx(env = {"OCX_HOME": "relative/.ocx"}), host_info("linux", "amd64"), False)
    elif case == "relative_translucent_path":
        make_ocx_env(
            _env_ctx(env = {"OCX_HOME": "/home/u/.ocx", "OCX_CONFIG": "./site.toml"}),
            host_info("linux", "amd64"),
            False,
        )
    elif case == "file_url_wrong_row":
        make_ocx_env(
            _env_ctx(env = {"OCX_HOME": "/home/u/.ocx", "OCX_CONFIG": "file:///etc/ocx/config.toml"}),
            host_info("linux", "amd64"),
            False,
        )
    elif case == "url_wrong_scheme":
        make_ocx_env(
            _env_ctx(env = {
                "OCX_HOME": "/home/u/.ocx",
                "OCX_SIGSTORE_TRUSTED_ROOT": "https://corp/trusted-root.json",
            }),
            host_info("linux", "amd64"),
            False,
        )
    elif case == "bad_bins_attr":
        check_bin_names(["jq", "$(touch PWNED)"])
    elif case == "bat_target_quote":
        render_launcher([], "C:\\store\\ev\"il\\jq.exe", "C:\\Users\\u\\.ocx", "C:\\repo\\ocx.exe", True)
    elif case == "unknown_modifier":
        render_launcher(
            [{"key": "K", "value": "v", "type": "vector"}],
            "/store/aa/content/bin/tool",
            "/home/u/.ocx",
            "/repo/ocx",
            False,
        )
    else:
        fail("test bug: unknown guard case '{}'".format(case))
    return []

_guard = rule(implementation = _guard_impl, attrs = {"case": attr.string()})

def _guard_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected)
    return analysistest.end(env)

guard_test = analysistest.make(
    _guard_test_impl,
    expect_failure = True,
    attrs = {"expected": attr.string()},
)

def _ambient_config_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    posix_env = {"XDG_CONFIG_HOME": "/x/cfg", "HOME": "/home/u", "APPDATA": ""}

    # Linux: /etc tier, XDG user config, then the three OCX_HOME-rooted tiers.
    asserts.equals(env, [
        "/etc/ocx/config.toml",
        "/x/cfg/ocx/config.toml",
        "/home/u/.ocx/config.toml",
        "/home/u/.ocx/state/managed-config/snapshot.json",
        "/home/u/.ocx/state/managed-config/config.toml",
    ], ambient_config_paths(False, False, posix_env, "/home/u/.ocx"))

    # Unset XDG_CONFIG_HOME falls back to ~/.config; so does a relative one.
    for xdg in ["", "cfg"]:
        paths = ambient_config_paths(
            False,
            False,
            {"XDG_CONFIG_HOME": xdg, "HOME": "/home/u"},
            "",
        )
        asserts.equals(env, ["/etc/ocx/config.toml", "/home/u/.config/ocx/config.toml"], paths)

    # macOS ignores XDG entirely.
    asserts.equals(env, [
        "/etc/ocx/config.toml",
        "/home/u/Library/Application Support/ocx/config.toml",
    ], ambient_config_paths(False, True, posix_env, ""))

    # Windows: APPDATA, backslashes, no /etc tier.
    asserts.equals(env, [
        "C:\\Users\\u\\AppData\\Roaming\\ocx\\config.toml",
        "C:\\Users\\u\\.ocx\\config.toml",
        "C:\\Users\\u\\.ocx\\state\\managed-config\\snapshot.json",
        "C:\\Users\\u\\.ocx\\state\\managed-config\\config.toml",
    ], ambient_config_paths(
        True,
        False,
        {"APPDATA": "C:\\Users\\u\\AppData\\Roaming", "HOME": "", "XDG_CONFIG_HOME": ""},
        "C:\\Users\\u\\.ocx",
    ))

    # Windows without APPDATA: no /etc tier and no user tier — only OCX_HOME's.
    asserts.equals(env, [
        "C:\\Users\\u\\.ocx\\config.toml",
        "C:\\Users\\u\\.ocx\\state\\managed-config\\snapshot.json",
        "C:\\Users\\u\\.ocx\\state\\managed-config\\config.toml",
    ], ambient_config_paths(
        True,
        False,
        {"APPDATA": "", "HOME": "/home/u", "XDG_CONFIG_HOME": "/x/cfg"},
        "C:\\Users\\u\\.ocx",
    ))

    # macOS without HOME: no Application Support tier to derive, and XDG stays
    # ignored even though it is the only thing set.
    asserts.equals(env, [
        "/etc/ocx/config.toml",
        "/home/u/.ocx/config.toml",
        "/home/u/.ocx/state/managed-config/snapshot.json",
        "/home/u/.ocx/state/managed-config/config.toml",
    ], ambient_config_paths(
        False,
        True,
        {"HOME": "", "XDG_CONFIG_HOME": "/x/cfg", "APPDATA": "C:\\Users\\u\\AppData\\Roaming"},
        "/home/u/.ocx",
    ))

    # Nothing to discover: no home (isolated_home) and no env at all.
    asserts.equals(env, ["/etc/ocx/config.toml"], ambient_config_paths(False, False, {}, ""))
    return unittest.end(env)

def _sigstore_trust_root_path_test_impl(ctx):
    """C-009: ocx's rung-4 trusted-root convention path, hand-constructed.

    ocx has no read-only command reporting it, so the layout is hard-coded and
    the watch fails open — relocate the directory upstream and it silently
    covers nothing. Re-verified on every ocx bump (the update-dist skill).
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "/home/u/.ocx/sigstore/trusted-root.json",
        sigstore_trust_root_path("/home/u/.ocx", False),
    )
    asserts.equals(
        env,
        "C:\\Users\\u\\.ocx\\sigstore\\trusted-root.json",
        sigstore_trust_root_path("C:\\Users\\u\\.ocx", True),
    )

    # isolated_home passes "" to drop the tier: the store lives inside the
    # repository being fetched, which cannot be watched.
    asserts.equals(env, None, sigstore_trust_root_path("", False))
    asserts.equals(env, None, sigstore_trust_root_path("", True))
    return unittest.end(env)

def _is_absolute_path_test_impl(ctx):
    """B1: only a genuinely absolute path for that host is absolute."""
    env = unittest.begin(ctx)

    for path in ["/home/u/.ocx", "/"]:
        asserts.true(env, is_absolute_path(path, False), path + " is absolute on POSIX")

    # A relative OCX_HOME or HOME is what makes repository_ctx.watch() blow up
    # with a raw traceback; `~` is a shell nicety, not a path.
    for path in [".ocx", "~/.ocx", "~\\.ocx", "ocx", "home/u/.ocx", ""]:
        asserts.false(env, is_absolute_path(path, False), repr(path) + " is relative on POSIX")

    for path in [
        "C:\\Users\\u\\.ocx",
        "C:/Users/u/.ocx",
        "c:\\Users\\u\\.ocx",
        "\\\\server\\share\\ocx",
        # Forward-slash UNC, symmetric with the `C:/` spelling — Win32 accepts
        # either separator and ocx renders whatever the user exported.
        "//server/share/ocx",
    ]:
        asserts.true(env, is_absolute_path(path, True), path + " is absolute on Windows")

    # Drive-relative is not absolute: one leading backslash means "root of the
    # current drive", `C:x` means "cwd of drive C". `1:/x` and `::/x` have the
    # *shape* of a drive path but no drive letter — without the letter check
    # they read as absolute.
    for path in ["\\Windows\\System32", "C:", "C:ocx", ".ocx", "~\\.ocx", "ocx", "", "1:/x", "::/x"]:
        asserts.false(env, is_absolute_path(path, True), repr(path) + " is relative on Windows")

    # Cross-host: a POSIX root is not a Windows absolute path.
    asserts.false(env, is_absolute_path("/home/u", True), "POSIX root is not absolute on Windows")
    return unittest.end(env)

def _path_dirs_test_impl(ctx):
    """Only PATH names directories that hold executables."""
    env = unittest.begin(ctx)

    # Search-precedence order: the reverse of declaration order, because an ocx
    # consumer prepends each entry as it walks the list.
    asserts.equals(env, ["/store/bb/content", "/store/aa/content/bin"], path_dirs(_ENTRIES))

    # A package contributing other colon-lists uses the same `path` type; those
    # directories hold libraries and man pages, not tools.
    asserts.equals(env, ["/store/aa/content/bin"], path_dirs([
        {"key": "LD_LIBRARY_PATH", "value": "/store/aa/content/lib", "type": "path"},
        {"key": "PATH", "value": "/store/aa/content/bin", "type": "path"},
        {"key": "MANPATH", "value": "/store/aa/content/share/man", "type": "path"},
        {"key": "PKG_CONFIG_PATH", "value": "/store/aa/content/lib/pkgconfig", "type": "path"},
        {"key": "PATH", "value": "/store/aa/content/sbin", "type": "constant"},
    ]))

    # ocx serializes the key verbatim from package metadata — a package
    # spelling it `Path` still names the directory the tools live in.
    asserts.equals(env, ["/store/aa/content/bin"], path_dirs([
        {"key": "Path", "value": "/store/aa/content/bin", "type": "path"},
    ]))
    asserts.equals(env, [], path_dirs([]))

    # An empty value is dropped, as ocx's move_to_front drops it — it would
    # otherwise probe `/<name>` here and land the CWD on a launcher's PATH.
    asserts.equals(env, ["/store/aa/content/bin"], path_dirs([
        {"key": "PATH", "value": "", "type": "path"},
        {"key": "PATH", "value": "/store/aa/content/bin", "type": "path"},
    ]))
    return unittest.end(env)

def _truthy_test_impl(ctx):
    env = unittest.begin(ctx)
    for value in ["1", "y", "yes", "on", "true", "YES", "On", "TRUE"]:
        asserts.true(env, truthy(value), repr(value) + " is truthy")

    # ocx's falsy strings, plus unset and an unrecognized value — the latter is
    # ocx's own error to raise, not this predicate's.
    for value in ["0", "n", "no", "off", "false", "", "maybe"]:
        asserts.false(env, truthy(value), repr(value) + " is not truthy")
    asserts.false(env, truthy(None), "unset is not truthy")
    return unittest.end(env)

def _bat_value_test_impl(ctx):
    """The primitive both Batch call sites refuse on.

    A literal quote closes the quoted region with no in-place escape, and
    once it is closed cmd.exe reads `&` as a statement separator — so an
    unescaped interpolation into a `.bat` runs the tail as its own command.
    Dropping the value is the only safe answer; `%` is escapable in place.
    """
    env = unittest.begin(ctx)

    # The reference shape a lazy package launcher interpolates.
    asserts.equals(env, "ocx.sh/jqlang/jq@sha256:" + "0" * 64, bat_value("ocx.sh/jqlang/jq@sha256:" + "0" * 64))
    asserts.equals(env, "C:/store/aa/content", bat_value("C:/store/aa/content"))

    # `%` opens an expansion; `%%` is its literal spelling in a batch file.
    asserts.equals(env, "a%%b", bat_value("a%b"))
    asserts.equals(env, "%%PATH%%", bat_value("%PATH%"))

    # Anything carrying a quote is unrenderable, including the statement
    # separator that quote would expose.
    for hostile in [
        'x" & calc.exe & "@sha256:' + "0" * 64,
        'a"b',
        '"',
        'v1" | whoami & "',
    ]:
        asserts.equals(env, None, bat_value(hostile), repr(hostile) + " must be refused")
    return unittest.end(env)

# W17: every sysexit AGENTS.md documents as reachable from a repository rule.
# 83/84/85 joined in 0.6.0, when signature verification attached to the fetch
# path (C-008).
_DOCUMENTED_SYSEXITS = [64, 65, 69, 74, 75, 77, 78, 79, 80, 81, 83, 84, 85]

def _sysexit_hints_test_impl(ctx):
    """W17: the hint table covers the documented sysexits, and nothing else."""
    env = unittest.begin(ctx)

    # Both directions at once: nothing documented is missing, nothing
    # undocumented has crept in.
    asserts.equals(env, _DOCUMENTED_SYSEXITS, sorted(SYSEXIT_HINTS.keys()))
    for code in _DOCUMENTED_SYSEXITS:
        asserts.true(env, SYSEXIT_HINTS[code], "sysexit {} has an empty hint".format(code))

    # 82 (dirty rc) is deliberately absent: only `ocx config setup` / `ocx self
    # setup` raise it, and invariant 5 forbids a repo rule from running either.
    asserts.false(env, 82 in SYSEXIT_HINTS, "sysexit 82 is unreachable from a repository rule")
    return unittest.end(env)

sh_launcher_test = unittest.make(_sh_launcher_test_impl)
bat_launcher_test = unittest.make(_bat_launcher_test_impl)
list_modifier_test = unittest.make(_list_modifier_test_impl)
bin_name_guard_test = unittest.make(_bin_name_guard_test_impl)
scan_fallback_test = unittest.make(_scan_fallback_test_impl)
windows_scan_test = unittest.make(_windows_scan_test_impl)
resolve_bins_order_test = unittest.make(_resolve_bins_order_test_impl)
sh_launcher_quoting_test = unittest.make(_sh_launcher_quoting_test_impl)
bat_launcher_quoting_test = unittest.make(_bat_launcher_quoting_test_impl)
run_ocx_retry_test = unittest.make(_run_ocx_retry_test_impl)
make_ocx_env_test = unittest.make(_make_ocx_env_test_impl)
stage_lazy_config_test = unittest.make(_stage_lazy_config_test_impl)
passthrough_env_test = unittest.make(_passthrough_env_test_impl)
sh_lazy_launcher_test = unittest.make(_sh_lazy_launcher_test_impl)
bat_lazy_launcher_test = unittest.make(_bat_lazy_launcher_test_impl)
env_bzl_test = unittest.make(_env_bzl_test_impl)
declared_bins_test = unittest.make(_declared_bins_test_impl)
entrypoints_surface_test = unittest.make(_entrypoints_surface_test_impl)
closure_packages_test = unittest.make(_closure_packages_test_impl)
ambient_config_paths_test = unittest.make(_ambient_config_paths_test_impl)
sigstore_trust_root_path_test = unittest.make(_sigstore_trust_root_path_test_impl)
is_absolute_path_test = unittest.make(_is_absolute_path_test_impl)
path_dirs_test = unittest.make(_path_dirs_test_impl)
truthy_test = unittest.make(_truthy_test_impl)
bat_value_test = unittest.make(_bat_value_test_impl)
sysexit_hints_test = unittest.make(_sysexit_hints_test_impl)

def launcher_test_suite(name):
    """Instantiates the repo_utils pure-helper test suite.

    Args:
        name: name of the test suite target.
    """
    reports = {case: {"packages": packages} for case, packages in _MALFORMED_CLOSURE_REPORTS.items()}
    reports.update(_MALFORMED_CLOSURE_CONTAINERS)

    guards = []
    for case, report in reports.items():
        subject = "{}_malformed_{}".format(name, case)
        _bad_closure_report(
            name = subject,
            report = json.encode(report),
            tags = ["manual"],
        )
        guards.append(partial.make(
            closure_packages_guard_test,
            target_under_test = ":" + subject,
        ))

    for case, expected in _GUARD_CASES.items():
        subject = "{}_guard_{}".format(name, case)
        _guard(name = subject, case = case, tags = ["manual"])
        guards.append(partial.make(
            guard_test,
            target_under_test = ":" + subject,
            expected = expected,
        ))

    unittest.suite(
        name,
        sh_launcher_test,
        bat_launcher_test,
        list_modifier_test,
        bin_name_guard_test,
        scan_fallback_test,
        windows_scan_test,
        resolve_bins_order_test,
        sh_launcher_quoting_test,
        bat_launcher_quoting_test,
        run_ocx_retry_test,
        make_ocx_env_test,
        stage_lazy_config_test,
        passthrough_env_test,
        sh_lazy_launcher_test,
        bat_lazy_launcher_test,
        env_bzl_test,
        declared_bins_test,
        entrypoints_surface_test,
        closure_packages_test,
        ambient_config_paths_test,
        sigstore_trust_root_path_test,
        is_absolute_path_test,
        path_dirs_test,
        truthy_test,
        bat_value_test,
        sysexit_hints_test,
        *guards
    )
