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
# exit 0). Empty = unset.
_OCX_NEUTRALIZED_ENV = ["OCX_PROJECT", "OCX_GLOBAL", "OCX_QUIET"]

_SYSEXIT_HINTS = {
    64: "usage error — the pinned ocx version and rules_ocx disagree on the CLI surface; check DEFAULT_OCX_VERSION",
    65: "stale data — the lockfile does not match its declaration; run 'ocx lock' and commit the result",
    69: "a required service or registry is unavailable — check network, OCX_MIRRORS, and registry auth",
    75: "transient failure — a rate limit, a short layer blob, or another ocx process holding the project lock; retry",
    78: ("configuration error — a declared ocx.toml/ocx.lock is missing or its lock_version " +
         "is unsupported, or a required managed config has never been synced (run " +
         "'ocx config update'; no_config = True / OCX_NO_CONFIG=1 opts out of the tier)"),
    79: ("not found — the reference, or a required patch companion composed onto it, does not " +
         "exist in the registry; check the name, or refresh the companions with 'ocx patch sync'"),
    81: ("blocked by policy — offline or frozen mode, a frozen index snapshot, or an ocx.toml " +
         "policy refused the resolution"),
}

# Extra attempts granted to a sysexit 75 even when the caller asked for none.
_TRANSIENT_RETRIES = 2

# Env vars consulted to locate the platform user-config directory.
_CONFIG_HOME_ENV = ["XDG_CONFIG_HOME", "HOME", "APPDATA"]

# ocx's BooleanString set, case-insensitive.
_TRUTHY = ["1", "y", "yes", "on", "true"]

def _truthy(value):
    return value != None and value.lower() in _TRUTHY

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
    for key in _OCX_NEUTRALIZED_ENV:
        env[key] = ""
    for key in OCX_PASSTHROUGH_ENV:
        value = ctx.getenv(key)
        if value != None:
            env[key] = value

    # Attrs beat the ambient environment.
    if ctx.attr.no_config:
        env["OCX_NO_CONFIG"] = "1"
    if ctx.attr.config:
        env["OCX_CONFIG"] = str(ctx.path(ctx.attr.config))
    if ctx.attr.patch_snapshot:
        env["OCX_PATCH_SNAPSHOT"] = str(ctx.path(ctx.attr.patch_snapshot))

    if not ctx.attr.no_config and not _truthy(ctx.getenv("OCX_NO_CONFIG")):
        for path in ambient_config_paths(
            host.is_windows,
            host.ocx_platform.startswith("darwin"),
            {key: ctx.getenv(key) or "" for key in _CONFIG_HOME_ENV},
            "" if isolated_home else home,
        ):
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

def run_ocx(ctx, binary, args, env, what, hints = {}, retries = 0):
    """Runs the ocx CLI, mapping failures to actionable messages.

    Args:
        ctx: repository_ctx.
        binary: path of the ocx executable.
        args: argv after the binary.
        env: environment dict (from make_ocx_env().env).
        what: short human description used in error messages.
        hints: {exit_code: extra hint} overriding the sysexits defaults.
        retries: extra attempts after a failure. Repo rules fetch in
            parallel, and concurrent `ocx package install` calls of the same
            package can race on store symlink creation (ocx TOCTOU); the
            store is idempotent, so a retry converges. A sysexit 75 is
            retried regardless — it is ocx's own "transient, retry me",
            raised among other things when a sibling repo rule holds the
            project lock on the shared ocx.toml.

    Returns:
        stdout string.
    """
    result = None
    for attempt in range(max(retries, _TRANSIENT_RETRIES) + 1):
        result = ctx.execute([str(binary)] + args, environment = env, timeout = 600)
        if result.return_code == 0:
            return result.stdout
        if attempt >= retries and result.return_code != 75:
            break
    hint = hints.get(result.return_code) or _SYSEXIT_HINTS.get(result.return_code, "")
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

def resolve_bins(ctx, names, entries, is_windows):
    """Locates each declared executable among the `path`-typed env entries.

    A declared binary is a name, not a path, so the concrete file is found the
    way a shell would: first `path` entry holding it wins. A claimed name that
    no entry holds is dropped — the claim is publisher-declared and unverified.

    Args:
        ctx: repository_ctx.
        names: declared executable names, in PATH-precedence order.
        entries: env entries [{"key", "value", "type"}, ...] from `ocx env`.
        is_windows: host flag; Windows executables carry an extension.

    Returns:
        list of struct(name, target) where target is the absolute path.
    """
    exts = [".exe", ".bat", ".cmd"] if is_windows else [""]
    dirs = [e["value"] for e in entries if e["type"] == "path"]
    bins = []
    for name in names:
        target = ""
        for directory in dirs:
            for ext in exts:
                candidate = directory + "/" + name + ext
                if ctx.path(candidate).exists:
                    target = candidate
                    break
            if target:
                break
        if target:
            bins.append(struct(name = name, target = target))
    return bins

def discover_bins(ctx, stdout, entries, is_windows):
    """Runnable tools for a fetched repo: the declared surface, else a PATH scan.

    Args:
        ctx: repository_ctx.
        stdout: raw `inspect --closure` JSON.
        entries: env entries from `ocx env`.
        is_windows: host flag.

    Returns:
        list of struct(name, target).
    """
    surface = declared_bins(decode_json(stdout, "ocx inspect --closure")["packages"])
    if not surface.incomplete:
        return resolve_bins(ctx, surface.names, entries, is_windows)

    # buildifier: disable=print
    print(("rules_ocx: no complete `binaries` metadata for {} — falling back to " +
           "scanning the composed PATH, which also exposes private " +
           "executables").format(", ".join(surface.incomplete)))
    return scan_bins(ctx, entries, is_windows)

def scan_bins(ctx, entries, is_windows):
    """Discovers runnable tools by scanning the `path`-typed env entries.

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
    for entry in entries:
        if entry["type"] != "path":
            continue
        for basename in list_executables(ctx, entry["value"], is_windows):
            name = basename
            if is_windows and "." in basename:
                name = basename[:basename.rfind(".")]
            if name in seen:
                continue
            seen[name] = True
            bins.append(struct(name = name, target = entry["value"] + "/" + basename))
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
    for label, name, var in [
        (ctx.attr.config, "config.toml", "OCX_CONFIG"),
        (ctx.attr.patch_snapshot, "patches.snapshot.json", "OCX_PATCH_SNAPSHOT"),
    ]:
        if not label:
            continue
        ctx.file(name, ctx.read(label))
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
        ]
        lines += ['set "{}={}"'.format(key, value) for key, value in exports.items()]
        lines.append("{} %*".format(" ".join(command)))
        return "\r\n".join(lines) + "\r\n"
    lines = [
        "#!/usr/bin/env bash",
        "# Generated by rules_ocx — do not edit.",
        _RUNFILES_PREAMBLE,
        'export OCX_PROJECT=""',
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

def render_env_bzl(entries, home):
    """Renders the generated repo's env.bzl.

    JSON round-trip keeps escaping correct for arbitrary values.

    Args:
        entries: env entries from `ocx env`.
        home: resolved OCX_HOME.

    Returns:
        env.bzl content string.
    """
    payload = json.encode({"entries": entries, "home": home})
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
