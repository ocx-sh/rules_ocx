# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Unit tests for the pure helpers in ocx/private/repo_utils.bzl."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//ocx/private:platforms.bzl", "host_info")
load(
    "//ocx/private:repo_utils.bzl",
    "OCX_ENV_CLASSES",
    "SYSEXIT_HINTS",
    "ambient_config_paths",
    "is_absolute_path",
    "make_ocx_env",
    "run_ocx",
    "truthy",
)

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
        allow_unverified = False,
        allow_yanked = False,
        sigstore_trusted_root = None):
    """A repository_ctx stand-in for make_ocx_env().

    `path` returns the string it was given, resolved against a fixed repo root
    when it is a bare name (which is how the isolated OCX_HOME is built): these two
    only ever str() the result, and the fetched-file semantics play no part in
    what is asserted. Every ctx.watch() lands in the returned struct's
    `watched` list — the watch set is a contract of its own, since Bazel
    cannot invalidate on a file no rule ever declared reading.

    Args:
        env: the ambient environment ctx.getenv() reads.
        no_config: the `no_config` attr.
        config: the `config` attr (a path string stands in for the label).
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

    ambient = make_ocx_env(_env_ctx(env = _AMBIENT), host).env
    asserts.equals(env, "/repo/.ocx_home", ambient["OCX_HOME"])
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
    ).env
    asserts.equals(env, "1", loose.get("OCX_NO_VERIFY", "<absent>"))
    asserts.equals(env, "1", loose.get("OCX_ALLOW_YANKED", "<absent>"))

    # no_config: OCX_NO_CONFIG prunes only the *discovered* tiers, so an
    # ambient OCX_CONFIG is blanked as well.
    hermetic = _env_ctx(env = _AMBIENT, no_config = True)
    blanked = make_ocx_env(hermetic, host).env
    asserts.equals(env, "1", blanked["OCX_NO_CONFIG"])
    asserts.equals(env, "", blanked["OCX_CONFIG"], "OCX_CONFIG survived no_config")

    # C-003: a trust root is not a config tier, so no_config leaves it alone —
    # with no_config plus a `config` label carrying [[trust.policy]], ocx still
    # reads the env rung. It is watched outside the gate, or an edit would not
    # refetch.
    asserts.equals(env, "/site/trusted-root.json", blanked.get("OCX_SIGSTORE_TRUSTED_ROOT", "<absent>"))
    asserts.true(
        env,
        "/site/trusted-root.json" in hermetic.watched,
        "the surviving ambient trust root is not watched",
    )

    # The attrs are what the caller did ask for, so they are reinstated over
    # the blanks.
    attrs = make_ocx_env(
        _env_ctx(
            env = _AMBIENT,
            no_config = True,
            config = "/w/cfg.toml",
        ),
        host,
    ).env
    asserts.equals(env, "/w/cfg.toml", attrs["OCX_CONFIG"])

    # A translucent label attr replaces the ambient value and is watched —
    # ctx.path() alone registers nothing; the shadowed ambient
    # file is not, since nothing reads it any more.
    pinned = _env_ctx(env = _AMBIENT, sigstore_trusted_root = "/w/trusted-root.json")
    asserts.equals(
        env,
        "/w/trusted-root.json",
        make_ocx_env(pinned, host).env.get("OCX_SIGSTORE_TRUSTED_ROOT", "<absent>"),
    )
    asserts.true(env, "/w/trusted-root.json" in pinned.watched, "the attr trust root is not watched")
    asserts.false(
        env,
        "/site/trusted-root.json" in pinned.watched,
        "the shadowed ambient trust root is still watched",
    )

    # A `file://` trust root is a spelling ocx accepts at exactly this door
    # (FileReference::parse, ocx-sh/ocx#379), so it is forwarded verbatim —
    # and watched at the path behind the prefix, so editing the trust anchor
    # refetches. Case-insensitive, matching the prefix ocx consumes; the guard
    # cases pin the other half — no other row and no other scheme takes this
    # branch, and a `file://` whose remainder is relative is refused like any
    # other relative value.
    for spelling in ["FILE:///opt/trusted-root.json", "file:///opt/trusted-root.json"]:
        url = _env_ctx(env = dict(_AMBIENT, OCX_SIGSTORE_TRUSTED_ROOT = spelling))
        asserts.equals(
            env,
            spelling,
            make_ocx_env(url, host).env.get("OCX_SIGSTORE_TRUSTED_ROOT", "<absent>"),
        )
        asserts.true(
            env,
            "/opt/trusted-root.json" in url.watched,
            spelling + " was not watched at the path behind the prefix",
        )
        asserts.false(
            env,
            spelling in url.watched,
            "the URL spelling itself was handed to ctx.watch()",
        )

    # The store lives inside the repository being fetched, which cannot be
    # watched — so ocx's ~/.ocx rung is dropped rather than pointed at a path
    # that will not exist on the next machine, and the client's own OCX_HOME
    # (an ambient /home/u/.ocx here) never reaches the call.
    isolated = _env_ctx(env = _AMBIENT)
    asserts.equals(env, "/repo/.ocx_home", make_ocx_env(isolated, host).env["OCX_HOME"])
    asserts.false(
        env,
        "/repo/.ocx_home/sigstore/trusted-root.json" in isolated.watched,
        "an in-repository trust root is watched",
    )
    asserts.false(
        env,
        "/home/u/.ocx/sigstore/trusted-root.json" in isolated.watched,
        "the client's OCX_HOME trust-root rung is watched",
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
    "OCX_EXTRA_CA_CERTS",
    "OCX_CONFIG",
    "OCX_SIGSTORE_TRUSTED_ROOT",
    "OCX_NO_CONFIG",
]

def _passthrough_env_test_impl(ctx):
    """W17/F5: all 13 forwarded env vars, and nothing else."""
    env = unittest.begin(ctx)
    forwarded = [key for key, row in OCX_ENV_CLASSES.items() if row.cls in ["site", "translucent"]]
    asserts.equals(env, _PASSTHROUGH_ENV, forwarded)
    asserts.equals(env, 13, len(forwarded))

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

def _run_ocx_retry_test_impl(ctx):
    """F2: only a transient sysexit buys another registry round-trip."""
    env = unittest.begin(ctx)

    # 75 is ocx's own "transient, retry me": retried twice, with a backoff.
    calls = []
    sleeps = []
    asserts.equals(env, "out0", _run_ocx(_replay_ctx([75, 75, 0], calls, sleeps)))
    asserts.equals(env, 3, len(calls))

    # The backoff shells out to an absolute /bin/sh, but the bare `sleep` in
    # it would resolve against whatever PATH the repository rule inherited
    # (CWE-426) — so the exec carries its own.
    asserts.equals(env, 2, len(sleeps))
    asserts.equals(env, {"PATH": "/usr/bin:/bin"}, sleeps[0])

    # A first-attempt success costs exactly one call.
    calls = []
    asserts.equals(env, "out0", _run_ocx(_replay_ctx([0], calls)))
    asserts.equals(env, 1, len(calls))
    return unittest.end(env)

def _run_ocx(fake):
    """run_ocx() against a fake ctx, with the arguments a test does not vary."""
    return run_ocx(fake, "/fake/ocx", ["vendor", "pkg"], {}, "vendoring pkg", False)

# Guards whose whole point is a fail(), which a unittest impl cannot catch:
# {case: fragment the message must carry}. Every case is exercised through a
# target whose analysis is expected to fail — a case that *succeeds* returns
# normally from _guard_impl and the analysistest reports it as a miss.
_GUARD_CASES = {
    # F2: a permanent sysexit must not buy a second registry round-trip. The
    # scripted 0 behind it succeeds if — and only if — the code was retried.
    "retry_69": "exit 69",
    "retry_74": "exit 74",
    "retry_79": "exit 79",
    "retry_80": "exit 80",
    "retry_81": "exit 81",
    "retry_65": "exit 65",
    # C-003: a relative ambient translucent `path` row is forwarded to ocx but
    # unwatchable, so it is refused rather than silently left unwatched. The
    # `file://` carve-out is scoped to the one row ocx parses as a file
    # reference and to that one scheme: on any other row (`OCX_CONFIG`, whose
    # value is a plain PathBuf::from) and under any other scheme the string is
    # a relative path to ocx, so the same refusal stands — and so does it on
    # that row when the path behind the prefix is itself relative.
    "relative_translucent_path": "must be an absolute path",
    "file_url_wrong_row": "must be an absolute path",
    "file_url_relative": "must be an absolute path",
    "url_wrong_scheme": "must be an absolute path",
    # The three sysexits the verifying fetch path raises. Each case scripts a
    # trailing 0 that is reached only on a retry, so the same target proves the
    # hint text *and* that _RETRYABLE did not grow: auto-retrying 83 would cost
    # three round-trips on a settled transparency-log outage.
    "sysexit_83": "transparency log is unreachable",
    "sysexit_84": "does not support the OCI Referrers API",
    "sysexit_85": "signing key backend",
}

def _guard_impl(ctx):
    case = ctx.attr.case
    if case.startswith("retry_") or case.startswith("sysexit_"):
        # The trailing 0 is reached only when the leading code was retried.
        code = case.split("_")[1]
        _run_ocx(_replay_ctx([int(code), 0], []))
    elif case == "relative_translucent_path":
        make_ocx_env(
            _env_ctx(env = {"OCX_HOME": "/home/u/.ocx", "OCX_CONFIG": "./site.toml"}),
            host_info("linux", "amd64"),
        )
    elif case == "file_url_wrong_row":
        make_ocx_env(
            _env_ctx(env = {"OCX_HOME": "/home/u/.ocx", "OCX_CONFIG": "file:///etc/ocx/config.toml"}),
            host_info("linux", "amd64"),
        )
    elif case == "file_url_relative":
        make_ocx_env(
            _env_ctx(env = {
                "OCX_HOME": "/home/u/.ocx",
                "OCX_SIGSTORE_TRUSTED_ROOT": "file://trusted-root.json",
            }),
            host_info("linux", "amd64"),
        )
    elif case == "url_wrong_scheme":
        make_ocx_env(
            _env_ctx(env = {
                "OCX_HOME": "/home/u/.ocx",
                "OCX_SIGSTORE_TRUSTED_ROOT": "https://corp/trusted-root.json",
            }),
            host_info("linux", "amd64"),
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

    # Linux: /etc tier, then the XDG user config.
    asserts.equals(env, [
        "/etc/ocx/config.toml",
        "/x/cfg/ocx/config.toml",
    ], ambient_config_paths(False, False, posix_env))

    # Unset XDG_CONFIG_HOME falls back to ~/.config; so does a relative one.
    for xdg in ["", "cfg"]:
        paths = ambient_config_paths(
            False,
            False,
            {"XDG_CONFIG_HOME": xdg, "HOME": "/home/u"},
        )
        asserts.equals(env, ["/etc/ocx/config.toml", "/home/u/.config/ocx/config.toml"], paths)

    # macOS ignores XDG entirely.
    asserts.equals(env, [
        "/etc/ocx/config.toml",
        "/home/u/Library/Application Support/ocx/config.toml",
    ], ambient_config_paths(False, True, posix_env))

    # Windows: APPDATA, backslashes, no /etc tier.
    asserts.equals(env, [
        "C:\\Users\\u\\AppData\\Roaming\\ocx\\config.toml",
    ], ambient_config_paths(
        True,
        False,
        {"APPDATA": "C:\\Users\\u\\AppData\\Roaming", "HOME": "", "XDG_CONFIG_HOME": ""},
    ))

    # Windows without APPDATA: no /etc tier and no user tier.
    asserts.equals(env, [], ambient_config_paths(
        True,
        False,
        {"APPDATA": "", "HOME": "/home/u", "XDG_CONFIG_HOME": "/x/cfg"},
    ))

    # macOS without HOME: no Application Support tier to derive, and XDG stays
    # ignored even though it is the only thing set.
    asserts.equals(env, ["/etc/ocx/config.toml"], ambient_config_paths(
        False,
        True,
        {"HOME": "", "XDG_CONFIG_HOME": "/x/cfg", "APPDATA": "C:\\Users\\u\\AppData\\Roaming"},
    ))

    # Nothing to discover: no env at all.
    asserts.equals(env, ["/etc/ocx/config.toml"], ambient_config_paths(False, False, {}))
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

# W17: every sysexit AGENTS.md documents as reachable from a repository rule.
# 83/84/85 are what signature verification raises on the fetch path.
_DOCUMENTED_SYSEXITS = [64, 65, 69, 74, 75, 77, 78, 79, 80, 81, 83, 84, 85]

# (code, fragment): the cause each hint must name.
_HINT_CAUSES = [
    (65, "refused to extract"),
    (65, "OCX_EXTRA_CA_CERTS"),
    (69, "did not resolve"),
    (69, "OCX_EXTRA_CA_CERTS"),
    (74, "OCX_EXTRA_CA_CERTS"),
    (78, "trusted_hosts"),
]

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
    asserts.false(env, 86 in SYSEXIT_HINTS, "sysexit 86 is unreachable from a repository rule")

    # Causes land on 65, 69 and 78 (and a CA file on 74);
    # each hint must name what now lands there, or it misdirects the fix.
    for code, fragment in _HINT_CAUSES:
        asserts.true(env, fragment in SYSEXIT_HINTS[code], "sysexit {} hint omits '{}'".format(code, fragment))
    return unittest.end(env)

run_ocx_retry_test = unittest.make(_run_ocx_retry_test_impl)
make_ocx_env_test = unittest.make(_make_ocx_env_test_impl)
passthrough_env_test = unittest.make(_passthrough_env_test_impl)
ambient_config_paths_test = unittest.make(_ambient_config_paths_test_impl)
is_absolute_path_test = unittest.make(_is_absolute_path_test_impl)
truthy_test = unittest.make(_truthy_test_impl)
sysexit_hints_test = unittest.make(_sysexit_hints_test_impl)

def repo_utils_test_suite(name):
    """Instantiates the repo_utils pure-helper test suite.

    Args:
        name: name of the test suite target.
    """
    guards = []
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
        run_ocx_retry_test,
        make_ocx_env_test,
        passthrough_env_test,
        ambient_config_paths_test,
        is_absolute_path_test,
        truthy_test,
        sysexit_hints_test,
        *guards
    )
