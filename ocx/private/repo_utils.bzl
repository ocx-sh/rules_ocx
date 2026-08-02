# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Shared plumbing for repository rules that shell out to the ocx CLI.

Everything that can be a pure function of plain values (launcher rendering,
env-file rendering) is one, so tests/ can cover it without a repository_ctx.
"""

# Env vars forwarded verbatim to every ocx invocation. getenv() registers
# them with Bazel, so changing one invalidates the fetched repos.
# OCX_AUTH_<REGISTRY>_* cannot be enumerated here — document `bazel fetch
# --force` after credential changes.
OCX_PASSTHROUGH_ENV = [
    "OCX_MIRRORS",
    "OCX_INSECURE_REGISTRIES",
    "OCX_OFFLINE",
    "OCX_FROZEN",
    "OCX_REMOTE",
    "OCX_JOBS",
    "OCX_INDEX",
    "OCX_DEFAULT_REGISTRY",
    "OCX_CONFIG",
    "OCX_NO_CONFIG",
    "OCX_MANAGED_CONFIG",
    "OCX_ALLOW_YANKED",
    "OCX_PATCHES",
    "OCX_PATCH_SNAPSHOT",
]

# Ambient values that would break an invocation rather than steer it: --global
# refuses to combine with the explicit --project every call here passes, and
# --quiet suppresses the very JSON report the parse surface reads (empty stdout,
# exit 0). OCX_PROJECT is a path, and empty is its documented "unset"; the other
# two are BooleanStrings, which have no empty spelling — "0" neutralizes them
# without the "invalid boolean value" warning "" logs on every invocation.
_OCX_NEUTRALIZED_ENV = {"OCX_PROJECT": "", "OCX_GLOBAL": "0", "OCX_QUIET": "0"}

SYSEXIT_HINTS = {
    64: ("usage error — the pinned ocx CLI and rules_ocx disagree on the command surface; " +
         "pin an ocx release this rules_ocx supports with ocx.download(version = '…') in " +
         "MODULE.bazel, or upgrade rules_ocx"),
    # Tier-neutral: the package tier has no lockfile, so a malformed reference
    # or digest is named first and 'ocx lock' offered as the project-tier case.
    65: ("data error — a malformed reference or digest; in a project, a lockfile out of date " +
         "with ocx.toml ('ocx lock', then commit)"),
    69: "a required service or registry is unavailable — check network, OCX_MIRRORS, and registry auth",
    74: ("io error — a local read or write failed (disk full, or a denied filesystem " +
         "operation); check disk space and permissions on OCX_HOME"),
    75: ("transient registry failure — a timeout, capacity exceeded, or an incomplete " +
         "transfer; retry, or route through OCX_MIRRORS"),
    77: ("permission denied — the registry rejected the request for this repository (403), or " +
         "OCX_HOME is not writable by the current user; check registry access and OCX_HOME's " +
         "permissions"),
    # Both project-tier 78s (missing/unsupported ocx.lock) are overridden at
    # their call sites, so this shared text only ever reaches the package tier,
    # which has no lockfile at all — leaving one cause to name.
    78: ("configuration error — a required managed config has never been synced; run " +
         "'ocx config update' (no_config = True / OCX_NO_CONFIG=1 opts out of the tier)"),
    79: ("not found — the reference, or a required patch companion composed onto it, does not " +
         "exist in the registry; check the name, or refresh the companions with 'ocx patch sync'"),
    80: "authentication required — the registry needs credentials for this reference; run 'ocx login <registry>'",
    81: ("blocked by policy — offline or frozen mode, a frozen index snapshot, or an ocx.toml " +
         "policy refused the resolution"),
    # 82 (dirty rc) has no entry: it is raised only by `ocx config setup` and
    # `ocx self setup` refusing to overwrite a hand-edited managed shell block,
    # and no repository rule ever runs either command — a hint here would be
    # dead code.
}

# Extra attempts granted to a sysexit 75 even when the caller asked for none.
_TRANSIENT_RETRIES = 2

# Env vars consulted to locate the platform user-config directory.
_CONFIG_HOME_ENV = ["XDG_CONFIG_HOME", "HOME", "APPDATA"]

# ocx's BooleanString set, case-insensitive.
_TRUTHY = ["1", "y", "yes", "on", "true"]

# Windows drive letters, for is_absolute_path — Bazel's Starlark has no
# per-character alpha predicate.
_DRIVE_LETTERS = "abcdefghijklmnopqrstuvwxyz"

def truthy(value):
    """Whether an ocx-style boolean string env value is true.

    Mirrors ocx's `BooleanString` set, case-insensitively; `None` (unset) is
    false. An unrecognized value (neither the truthy set nor one of ocx's
    falsy strings) makes ocx itself fail with `InvalidBooleanString` (exit
    65); `truthy` has no such error path and just returns False for it — a
    harmless divergence, since the raw value still reaches the real `ocx`
    invocation for its own enforcement.

    Args:
        value: string env value, or None.

    Returns:
        bool.
    """
    return value != None and value.lower() in _TRUTHY

def is_absolute_path(path, is_windows):
    """Whether `path` is absolute for the given host.

    POSIX: a leading `/`. Windows: two leading separators (`\\\\server\\share`
    or its forward-slash spelling `//server/share`, both UNC), or a drive
    letter followed by `:` and a slash or backslash — a single leading
    backslash alone is drive-relative, not absolute. Pure function of plain
    values, so tests can cover it without a repository_ctx.

    Closes only the relative-path case: `repository_ctx.watch()` also
    rejects the broader class "path under the working directory", which this
    predicate does not detect — an absolute OCX_HOME inside the workspace
    still fails that check, which is why isolated_home passes "" instead of
    a path rather than leaning on this predicate.

    Args:
        path: path string to test.
        is_windows: host flag.

    Returns:
        bool.
    """
    if not is_windows:
        return path.startswith("/")
    if path.startswith("\\\\") or path.startswith("//"):
        return True
    return (len(path) > 2 and path[1] == ":" and path[2] in "/\\" and
            path[0].lower() in _DRIVE_LETTERS)

def ambient_config_paths(is_windows, is_macos, env, home):
    """The host config files ocx would load, in ocx precedence order.

    Bazel cannot invalidate on a file it never reads, so the repository rules
    watch every tier — including the ones that do not exist yet, since
    `repository_ctx.watch()` registers absence too and creating the file
    refetches. Pure function of plain values so tests can cover it.

    Args:
        is_windows: host flag.
        is_macos: host flag (different user-config directory).
        env: {var: value} for XDG_CONFIG_HOME, HOME and APPDATA; "" when unset.
        home: the resolved OCX_HOME, or "" to drop the OCX_HOME-rooted tiers
            (isolated_home puts them inside the repo being fetched, which
            cannot be watched).

    Returns:
        list of absolute path strings, lowest precedence first.
    """
    sep = "\\" if is_windows else "/"
    paths = []
    if not is_windows:
        # ponytail: ocx reads the literal /etc/ocx/config.toml on every OS, but
        # a Windows host has no /etc — skip the tier instead of watching a path
        # that can never exist there.
        paths.append("/etc/ocx/config.toml")

    config_home = ""
    if is_windows:
        config_home = env.get("APPDATA", "")
    elif is_macos:
        base = env.get("HOME", "")
        config_home = base + "/Library/Application Support" if base else ""
    else:
        # A relative XDG_CONFIG_HOME is ignored, per the XDG spec and dirs-rs.
        xdg = env.get("XDG_CONFIG_HOME", "")
        if xdg.startswith("/"):
            config_home = xdg
        else:
            base = env.get("HOME", "")
            config_home = base + "/.config" if base else ""
    if config_home:
        paths.append(sep.join([config_home, "ocx", "config.toml"]))

    if home:
        paths.append(sep.join([home, "config.toml"]))
        paths.append(sep.join([home, "state", "managed-config", "snapshot.json"]))
        paths.append(sep.join([home, "state", "managed-config", "config.toml"]))
    return paths

def make_ocx_env(ctx, host, isolated_home):
    """Assembles the environment for ocx invocations from this repo rule.

    Also registers the host's ambient config tiers as watched inputs, so a
    site config edit — including an `ocx config update` refreshing the managed
    snapshot — refetches the repos that consumed it.

    Args:
        ctx: repository_ctx with `config`, `no_config` and `patch_snapshot` attrs.
        host: host_info() struct.
        isolated_home: if True, keep the ocx store inside this repository
            instead of the shared user OCX_HOME.

    Returns:
        struct(env = dict for repository_ctx.execute, home = resolved OCX_HOME).
    """
    if isolated_home:
        home = str(ctx.path(".ocx_home"))
    else:
        home = ctx.getenv("OCX_HOME")
        if not home:
            base = ctx.getenv("USERPROFILE") if host.is_windows else ctx.getenv("HOME")
            if not base:
                fail("rules_ocx: cannot resolve the default OCX_HOME — neither OCX_HOME nor HOME/USERPROFILE is set")
            home = base + ("\\.ocx" if host.is_windows else "/.ocx")

    # Caught here rather than at the first ctx.watch(), which rejects a
    # relative path with a raw Starlark traceback naming neither the variable
    # nor the fix.
    if not is_absolute_path(home, host.is_windows):
        fail(("rules_ocx: OCX_HOME must be absolute, got '{}' — a repository rule runs from " +
              "Bazel's own working directory and neither expands '~' nor resolves a relative " +
              "store. Export an expanded path (OCX_HOME=\"$HOME/.ocx\", not OCX_HOME='~/.ocx'), " +
              "or set isolated_home = True to keep the store inside the repository.").format(home))

    # `ocx run` exports OCX_PROJECT (possibly relative) into child processes;
    # a bazel invoked that way would leak it into every repo-rule ocx call,
    # which runs from a different cwd. Project context only ever comes from
    # explicit --project flags here, so neutralize it — along with the other
    # ambient knobs that break rather than steer an invocation.
    #
    # OCX_NO_CONFIG_REFRESH: the background managed-config refresh wants a TTY
    # no repo rule ever has. Pinned off explicitly rather than trusting ocx's
    # TTY probe — the CLI is version-unstable (invariant 2).
    env = {"OCX_HOME": home, "OCX_NO_CONFIG_REFRESH": "1"}
    env.update(_OCX_NEUTRALIZED_ENV)
    for key in OCX_PASSTHROUGH_ENV:
        value = ctx.getenv(key)
        if value != None:
            env[key] = value

    # These name files ocx reads that Bazel would otherwise never see, so
    # editing an ambient site config would not refetch. Watched only where the
    # ambient value survives: an attr override replaces it (and ctx.path()
    # registers that file below), and no_config blanks both. OCX_PATCHES is
    # deliberately absent: it carries a JSON `[patches]` envelope, not a path.
    for key, override in [("OCX_CONFIG", ctx.attr.config), ("OCX_PATCH_SNAPSHOT", ctx.attr.patch_snapshot)]:
        value = env.get(key, "")
        if override or ctx.attr.no_config or not value:
            continue
        if is_absolute_path(value, host.is_windows):
            ctx.watch(value)

    # Attrs beat the ambient environment.
    if ctx.attr.no_config:
        env["OCX_NO_CONFIG"] = "1"

        # OCX_NO_CONFIG only prunes the *discovered* tiers: ocx loads an
        # explicit OCX_CONFIG regardless, and with the config tier gone an
        # ambient OCX_PATCHES becomes the *only* patch source — attacker-chosen
        # companions composed into a build that asked for hermeticity. Empty is
        # ocx's documented "treat as unset" for all three; the attrs below then
        # reinstate whatever the caller did ask for.
        for key in ["OCX_CONFIG", "OCX_PATCHES", "OCX_PATCH_SNAPSHOT"]:
            env[key] = ""
    if ctx.attr.config:
        env["OCX_CONFIG"] = str(ctx.path(ctx.attr.config))
    if ctx.attr.patch_snapshot:
        env["OCX_PATCH_SNAPSHOT"] = str(ctx.path(ctx.attr.patch_snapshot))

    if not ctx.attr.no_config and not truthy(ctx.getenv("OCX_NO_CONFIG")):
        for path in ambient_config_paths(
            host.is_windows,
            host.ocx_platform.startswith("darwin"),
            {key: ctx.getenv(key) or "" for key in _CONFIG_HOME_ENV},
            "" if isolated_home else home,
        ):
            # ambient_config_paths() derives its user tier from HOME/APPDATA,
            # neither of which it tests for absoluteness — a relative one would
            # crash ctx.watch(). Skip the tier instead.
            if is_absolute_path(path, host.is_windows):
                ctx.watch(path)
    return struct(env = env, home = home)

def ocx_bin(ctx):
    """Resolves the ocx binary path from the rule's `ocx` label attribute.

    On Windows the executable lives next to the stable `ocx` file as
    `ocx.exe`; prefer it when present.

    Args:
        ctx: repository_ctx with an `ocx` label attr.

    Returns:
        path object of the executable to invoke.
    """
    stable = ctx.path(ctx.attr.ocx)
    exe = stable.dirname.get_child(stable.basename + ".exe")
    return exe if exe.exists else stable

def run_ocx(ctx, binary, args, env, what, is_windows, hints = {}, retries = 0):
    """Runs the ocx CLI, mapping failures to actionable messages.

    Args:
        ctx: repository_ctx.
        binary: path of the ocx executable.
        args: argv after the binary.
        env: environment dict (from make_ocx_env().env).
        what: short human description used in error messages.
        is_windows: host flag (from host_info()); Windows has no `sleep`.
        hints: {exit_code: extra hint} overriding the sysexits defaults.
        retries: extra attempts after a failure. Repo rules fetch in
            parallel, and concurrent `ocx package install` calls of the same
            package can race on store symlink creation (ocx TOCTOU); the
            store is idempotent, so a retry converges. A sysexit 75 is
            retried regardless — it is ocx's own "transient, retry me",
            raised when the registry times out or reports capacity exceeded.
            Attempts are spaced by a linear backoff.

    Returns:
        stdout string.
    """
    result = None
    attempts = max(retries, _TRANSIENT_RETRIES) + 1
    for attempt in range(attempts):
        result = ctx.execute([str(binary)] + args, environment = env, timeout = 600)
        if result.return_code == 0:
            return result.stdout
        if attempt >= retries and result.return_code != 75:
            break

        # ponytail: linear 1s, 2s, … — back-to-back execs span microseconds
        # while a registry rate-limit window spans seconds. The right ceiling
        # is a registry-policy question; make the schedule an attribute once a
        # real registry's limits are known. No Batch `sleep`, so Windows keeps
        # retrying immediately. `sleep` runs through an absolute /bin/sh: a
        # bare argv resolves against the ambient PATH, which would let anything
        # named `sleep` execute inside the repository rule.
        if not is_windows and attempt + 1 < attempts:
            ctx.execute(["/bin/sh", "-c", 'sleep "$0"', str(attempt + 1)])
    hint = hints.get(result.return_code) or SYSEXIT_HINTS.get(result.return_code, "")
    fail("rules_ocx: {} failed (exit {}): ocx {}\n{}{}".format(
        what,
        result.return_code,
        " ".join([str(a) for a in args]),
        result.stderr.strip(),
        "\nhint: " + hint if hint else "",
    ))

def decode_json(stdout, what):
    """json.decode with an error message naming the failing command."""
    if not stdout.strip():
        fail("rules_ocx: {} produced no output — expected JSON".format(what))
    return json.decode(stdout)

def closure_packages(stdout, what):
    """Validates and returns the `packages` list of an `inspect --closure` report.

    Decodes `stdout` itself via decode_json(stdout, what), then validates the
    result — one error vocabulary for the one command that produced it,
    whether it failed by not being JSON or by being JSON of the wrong shape.

    `InspectReport` always serializes its top-level `packages` key, so
    guarding that key fixes nothing. What ocx omits conditionally is each
    entry's `closure`: `--closure` walks the closure only for a resolved
    (`Manifest`/`Resolved`) body, so a binding that came back as unresolved
    `candidates` — an ambiguous tag, or an `ocx inspect` binding projected
    straight off ocx.lock with no single artifact to walk — carries no
    `closure` at all. This guards each entry instead: failing when one has
    no `identifier`, no `closure`, or a `closure` whose `surface.interface`
    lacks `binaries_complete` or carries a non-list `binaries` — every key
    declared_bins() indexes unguarded, in the type it indexes it as. The
    fail() names DEFAULT_OCX_VERSION per invariant 4:
    this is a shape drift between the pinned ocx and what rules_ocx parses,
    not a mapped sysexit.

    `install`/`which` reports never reach this function — their top-level
    shape is `{"<raw>": {...}}`, not this report's `{"packages": [...],
    ...}` — so they play no part in the drift this guards against.

    Args:
        stdout: raw stdout of an `ocx [package] inspect --closure` invocation.
        what: the command string (e.g. "ocx inspect --closure"), passed to
            decode_json() and reused in the fail() message — the same
            convention decode_json() and project.bzl already use. Not
            run_ocx()'s `what` (a human description like "reading the
            declared tool surface of …"), which never reaches this function.

    Returns:
        the validated `packages` list.
    """
    packages = decode_json(stdout, what)["packages"]
    for pkg in packages:
        interface = pkg.get("closure", {}).get("surface", {}).get("interface", {})
        if (type(interface.get("binaries")) != "list" or
            "binaries_complete" not in interface or
            "identifier" not in pkg):
            fail(("rules_ocx: {} reported '{}' with no closure surface — the pinned ocx CLI " +
                  "and rules_ocx disagree on the report shape. Move DEFAULT_OCX_VERSION " +
                  "(ocx/private/versions.bzl) to an ocx release this rules_ocx parses, or " +
                  "upgrade rules_ocx.").format(what, pkg.get("identifier", "<unnamed package>")))
    return packages

def list_executables(ctx, directory, is_windows):
    """Lists executable file names in a directory (non-recursive).

    Args:
        ctx: repository_ctx.
        directory: absolute directory path string.
        is_windows: host flag; on Windows executables are picked by extension,
            elsewhere by the executable bit.

    Returns:
        list of basenames, directory order.
    """
    path = ctx.path(directory)
    if not path.exists:
        return []
    if is_windows:
        names = []
        for child in path.readdir():
            lower = child.basename.lower()
            if lower.endswith(".exe") or lower.endswith(".bat") or lower.endswith(".cmd"):
                names.append(child.basename)
        return names
    result = ctx.execute([
        "/bin/sh",
        "-c",
        'for f in "$0"/* ; do if [ -f "$f" ] && [ -x "$f" ]; then printf "%s\\n" "${f##*/}"; fi; done',
        directory,
    ])
    if result.return_code != 0:
        return []
    return [name for name in result.stdout.splitlines() if name]

def declared_bins(packages):
    """The public executable names an `inspect --closure` report claims.

    `interface` is the surface a consumer sees on PATH; `private` holds the
    package's internal executables, which never become targets.

    Args:
        packages: the `packages` list of an `ocx [package] inspect --closure`
            report.

    Returns:
        struct(names, incomplete): `names` in declaration order with the first
        occurrence of a name winning (ocx PATH semantics), `incomplete` the
        identifiers of packages whose `binaries` claim is not complete. A
        non-empty `incomplete` makes `names` a subset of what is really on
        PATH, so the caller must fall back to scan_bins().
    """
    seen = {}
    names = []
    incomplete = []
    for pkg in packages:
        interface = pkg["closure"]["surface"]["interface"]
        if not interface["binaries_complete"]:
            incomplete.append(pkg["identifier"])
        for binary in interface["binaries"]:
            if binary["name"] in seen:
                continue
            seen[binary["name"]] = True
            names.append(binary["name"])
    return struct(names = names, incomplete = incomplete)

def path_dirs(entries):
    """The executable search path an `ocx env` report composes.

    `path`-typed entries carry every colon-list a package contributes, not
    just PATH: LD_LIBRARY_PATH, MANPATH and PKG_CONFIG_PATH have the same
    type and name directories holding libraries and man pages, so searching
    them for tools invents targets from whatever happens to be executable
    there. Only PATH answers "where do this environment's commands live".

    The key is compared case-insensitively: ocx serializes it verbatim from
    package metadata, and a package declaring `Path` would otherwise
    contribute nothing and silently yield zero discovered bins.

    Args:
        entries: env entries [{"key", "value", "type"}, ...] from `ocx env`.

    Returns:
        list of directory path strings, in declaration order.
    """
    return [e["value"] for e in entries if e["type"] == "path" and e["key"].upper() == "PATH"]

def resolve_bins(ctx, names, entries, is_windows):
    """Locates each declared executable on the composed PATH.

    A declared binary is a name, not a path, so the concrete file is found the
    way a shell would: first PATH directory holding it wins. A claimed name
    that no directory holds is dropped — the claim is publisher-declared and
    unverified.

    Args:
        ctx: repository_ctx.
        names: declared executable names, in PATH-precedence order.
        entries: env entries [{"key", "value", "type"}, ...] from `ocx env`.
        is_windows: host flag; Windows executables carry an extension.

    Returns:
        list of struct(name, target) where target is the absolute path.
    """
    exts = [".exe", ".bat", ".cmd"] if is_windows else [""]
    dirs = path_dirs(entries)
    bins = []
    for name in names:
        target = ""
        for directory in dirs:
            for ext in exts:
                candidate = directory + "/" + name + ext

                # `exists` is true for a directory too, and a launcher exec-ing
                # one dies at action time with a bare "Permission denied". A
                # non-executable regular file dies the same way and is not
                # caught: `is_dir` is free, an exec-bit test would cost a
                # ctx.execute per candidate.
                path = ctx.path(candidate)
                if path.exists and not path.is_dir:
                    target = candidate
                    break
            if target:
                break
        if target:
            bins.append(struct(name = name, target = target))
    return bins

def discover_bins(ctx, stdout, what, entries, is_windows):
    """Runnable tools for a fetched repo: the declared surface, else a PATH scan.

    The fallback is not warned about per fetch — the metadata belongs to a
    third-party package, so per-fetch noise is unactionable. It is recorded
    instead: `scanned` names the packages that forced it, and the caller
    renders it into the repo's env.bzl, where it stays inspectable.

    Args:
        ctx: repository_ctx.
        stdout: raw `inspect --closure` JSON.
        what: the command that produced `stdout` — 'ocx inspect --closure' at
            the project tier, 'ocx package inspect --closure' at the package
            tier — reused verbatim in the shape-drift fail().
        entries: env entries from `ocx env`.
        is_windows: host flag.

    Returns:
        struct(bins = [struct(name, target)], scanned = identifiers of the
        packages whose incomplete metadata forced the PATH scan).
    """
    surface = declared_bins(closure_packages(stdout, what))
    if not surface.incomplete:
        return struct(bins = resolve_bins(ctx, surface.names, entries, is_windows), scanned = [])
    return struct(bins = scan_bins(ctx, entries, is_windows), scanned = surface.incomplete)

def scan_bins(ctx, entries, is_windows):
    """Discovers runnable tools by scanning the composed PATH.

    The fallback for packages that declare no complete `binaries` metadata.
    Mirrors ocx PATH semantics: entries in declaration order, first name
    wins. Windows binaries are keyed by their extension-less name.

    Args:
        ctx: repository_ctx.
        entries: env entries [{"key", "value", "type"}, ...] from `ocx env`.
        is_windows: host flag.

    Returns:
        list of struct(name, target) in discovery order, where target is the
        absolute path of the real executable.
    """
    seen = {}
    bins = []
    for directory in path_dirs(entries):
        for basename in list_executables(ctx, directory, is_windows):
            name = basename
            if is_windows and "." in basename:
                name = basename[:basename.rfind(".")]
            if name in seen:
                continue
            seen[name] = True
            bins.append(struct(name = name, target = directory + "/" + basename))
    return bins

def rlocation_path(label):
    """Runfiles-lookup key ('<canonical repo>/<package>/<name>') for a label.

    Args:
        label: a resolved Label (e.g. the value of a label attribute).

    Returns:
        the key accepted by the Bash runfiles library's `rlocation`.
    """
    prefix = label.package + "/" if label.package else ""
    return label.workspace_name + "/" + prefix + label.name

def stage_lazy_config(ctx, is_windows):
    """Stages the config attrs into the repo for lazy launchers to re-export.

    A lazy launcher re-enters ocx at action time with ambient environment
    only, so fetch-time configuration would never reach it. Copying the files
    into the repo makes them runfiles — action inputs, so an edit re-keys the
    actions — and `ctx.read` registers the watch that refetches the repo.

    Args:
        ctx: repository_ctx with `config`, `no_config` and `patch_snapshot` attrs.
        is_windows: host flag; Windows launchers bake absolute paths, POSIX
            ones resolve through runfiles.

    Returns:
        struct(exports = {env var: value} for render_lazy_launcher,
        data = label strings to attach to every launcher).
    """
    exports = {}
    data = []
    if ctx.attr.no_config:
        exports["OCX_NO_CONFIG"] = "1"

        # OCX_NO_CONFIG prunes only the discovered tiers — the same ambient
        # OCX_CONFIG / OCX_PATCHES / OCX_PATCH_SNAPSHOT that make_ocx_env()
        # blanks at fetch time would otherwise be inherited from the action's
        # environment here. Empty is ocx's "treat as unset"; a set attr
        # overwrites the entry below.
        for var in ["OCX_CONFIG", "OCX_PATCHES", "OCX_PATCH_SNAPSHOT"]:
            exports[var] = ""
    for label, name, var in [
        (ctx.attr.config, "config.toml", "OCX_CONFIG"),
        (ctx.attr.patch_snapshot, "patches.snapshot.json", "OCX_PATCH_SNAPSHOT"),
    ]:
        if not label:
            continue

        # Not executable: it lands 0644 in the output base — Bazel has no API
        # to write a repo file 0600, so a config the operator set 0600 becomes
        # world-readable there, and being a runfile it is uploaded as an action
        # input with every action. Both attr docs say so.
        ctx.file(name, ctx.read(label), executable = False)
        exports[var] = str(ctx.path(name)) if is_windows else "$(rlocation {}/{})".format(ctx.name, name)
        data.append(":" + name)
    return struct(exports = exports, data = data)

# The canonical Bash runfiles library bootstrap (v3): resolves the runfiles
# tree or manifest wherever the launcher executes, keeping the script text
# free of machine-specific absolute paths.
_RUNFILES_PREAMBLE = """# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \\
  source "$0.runfiles/$f" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \\
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \\
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---"""

def render_lazy_launcher(command, is_windows, exports = {}):
    """Renders a lazy launcher: ocx is re-entered at execution time.

    No store paths are baked in — the wrapped ocx command auto-installs
    missing content on first use, so the action key is the script text plus
    its runfiles, never the tool content itself. POSIX scripts locate their
    inputs through the runfiles library, keeping the text identical across
    machines (portable remote-cache keys).

    OCX_PROJECT and OCX_GLOBAL are neutralized first: every command rendered
    here passes an explicit `--project` (or a digest-pinned reference), and
    ocx refuses to combine either ambient value with one — so an inherited
    OCX_GLOBAL would fail the action with a raw ocx usage error. The fetch
    path neutralizes the same pair via _OCX_NEUTRALIZED_ENV, with the same
    values: OCX_GLOBAL is a BooleanString, so "0" and not "" (which ocx logs
    as an invalid boolean on every launcher-run tool).

    Args:
        command: pre-quoted argv fragments; POSIX fragments may use
            `$(rlocation …)` — the preamble provides it.
        is_windows: render .bat instead of POSIX sh. Windows launchers bake
            absolute paths (no Batch runfiles library), so their action keys
            are machine-local.
        exports: env vars set before the command, in insertion order (stable
            action keys). POSIX values may use `$(rlocation …)` too — the
            template quotes them.

    Returns:
        script content string.
    """
    if is_windows:
        # ponytail: absolute paths — portable keys need a Batch runfiles
        # lookup; add one if Windows remote caching ever matters.
        lines = [
            "@echo off",
            "rem Generated by rules_ocx - do not edit.",
            'set "OCX_PROJECT="',
            'set "OCX_GLOBAL=0"',
        ]
        lines += ['set "{}={}"'.format(key, value) for key, value in exports.items()]
        lines.append("{} %*".format(" ".join(command)))
        return "\r\n".join(lines) + "\r\n"
    lines = [
        "#!/usr/bin/env bash",
        "# Generated by rules_ocx — do not edit.",
        _RUNFILES_PREAMBLE,
        'export OCX_PROJECT=""',
        'export OCX_GLOBAL="0"',
    ]
    lines += ['export {}="{}"'.format(key, value) for key, value in exports.items()]
    lines.append('exec {} "$@"'.format(" ".join(command)))
    return "\n".join(lines) + "\n"

def render_launcher(entries, target, home, ocx, is_windows):
    """Renders a launcher script applying the ocx env and exec-ing a tool.

    `path` entries prepend to the invoking environment; `constant` entries
    replace. OCX_HOME and OCX_BINARY_PIN are baked so ocx entrypoint
    launchers re-enter the pinned ocx against the right store.

    Args:
        entries: env entries [{"key", "value", "type"}, ...].
        target: absolute path of the executable to exec.
        home: resolved OCX_HOME.
        ocx: absolute path of the pinned ocx binary.
        is_windows: render .bat instead of POSIX sh.

    Returns:
        script content string.
    """
    path_values = {}  # key -> [values] in declaration order
    constants = []  # (key, value)
    for entry in entries:
        if entry["type"] == "path":
            path_values.setdefault(entry["key"], []).append(entry["value"])
        else:
            constants.append((entry["key"], entry["value"]))

    if is_windows:
        lines = ["@echo off", "rem Generated by rules_ocx - do not edit."]
        lines.append('set "OCX_HOME={}"'.format(home))
        lines.append('set "OCX_BINARY_PIN={}"'.format(ocx))
        for key, value in constants:
            lines.append('set "{}={}"'.format(key, value))
        for key, values in path_values.items():
            lines.append('set "{}={};%{}%"'.format(key, ";".join(values), key))
        lines.append('"{}" %*'.format(target))
        return "\r\n".join(lines) + "\r\n"

    lines = ["#!/usr/bin/env bash", "# Generated by rules_ocx — do not edit.", "set -euo pipefail"]
    lines.append('export OCX_HOME="{}"'.format(home))
    lines.append('export OCX_BINARY_PIN="{}"'.format(ocx))
    for key, value in constants:
        lines.append('export {}="{}"'.format(key, value))
    for key, values in path_values.items():
        joined = ":".join(values)
        lines.append('export {key}="{values}${{{key}:+:${{{key}}}}}"'.format(key = key, values = joined))
    lines.append('exec "{}" "$@"'.format(target))
    return "\n".join(lines) + "\n"

def render_env_bzl(entries, home, scanned = []):
    """Renders the generated repo's env.bzl.

    JSON round-trip keeps escaping correct for arbitrary values.

    Args:
        entries: env entries from `ocx env`.
        home: resolved OCX_HOME.
        scanned: identifiers of packages whose incomplete `binaries` metadata
            forced the PATH scan (discover_bins().scanned).

    Returns:
        env.bzl content string.
    """
    payload = json.encode({"entries": entries, "home": home, "scanned": scanned})
    return "\n".join([
        '"""Generated by rules_ocx — composed ocx environment."""',
        "",
        "_DATA = json.decode({})".format(repr(payload)),
        "",
        "# Ordered [{\"key\", \"value\", \"type\"}, ...]; type is \"path\" (prepend) or \"constant\" (replace).",
        'OCX_ENV = _DATA["entries"]',
        "",
        "# The OCX_HOME these paths point into.",
        'OCX_HOME = _DATA["home"]',
        "",
        "# Packages that declared no complete `binaries` surface: their launchers came",
        "# from scanning PATH, so the target names are unvalidated and include private",
        "# executables. Empty means every target came from declared metadata.",
        'OCX_SCANNED_PACKAGES = _DATA["scanned"]',
        "",
    ])

def render_launchers_build(bins, is_windows, extra = "", data = []):
    """Renders a generated BUILD file exposing one runnable target per tool.

    Args:
        bins: list of struct(name, target) from scan_bins().
        is_windows: host flag (launcher extension and native_binary out name).
        extra: additional BUILD content appended verbatim.
        data: label strings attached as runfiles to every launcher (lazy
            launchers carry the ocx binary and project files this way, making
            them action inputs).

    Returns:
        BUILD file content string.
    """
    ext = ".bat" if is_windows else ".sh"
    parts = [
        'load("@bazel_skylib//rules:native_binary.bzl", "native_binary")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
    ]
    for b in bins:
        parts.append("native_binary(")
        parts.append('    name = "{}",'.format(b.name))
        parts.append('    src = "launchers/{}{}",'.format(b.name, ext))
        if data:
            parts.append("    data = [")
            for label in data:
                parts.append('        "{}",'.format(label))
            parts.append("    ],")
        if is_windows:
            parts.append('    out = "{}.bat",'.format(b.name))
        parts.append(")")
        parts.append("")
    if extra:
        parts.append(extra)
    return "\n".join(parts)

def write_launchers(ctx, bins, entries, home, ocx, is_windows):
    """Writes launcher scripts for all discovered tools.

    Args:
        ctx: repository_ctx.
        bins: list of struct(name, target) from scan_bins().
        entries: env entries applied by every launcher.
        home: resolved OCX_HOME.
        ocx: absolute path string of the pinned ocx binary.
        is_windows: host flag.
    """
    ext = ".bat" if is_windows else ".sh"
    for b in bins:
        ctx.file(
            "launchers/" + b.name + ext,
            render_launcher(entries, b.target, home, ocx, is_windows),
            executable = True,
        )
