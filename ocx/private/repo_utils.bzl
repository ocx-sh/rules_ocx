# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Shared plumbing for repository rules that shell out to the ocx CLI.

Everything that can be a pure function of plain values (launcher rendering,
env-file rendering) is one, so tests/ can cover it without a repository_ctx.
"""

visibility(["//ocx", "//ocx/tests"])

def _env(cls, attr = "", path = False, value = "", hermetic = False, file_url = False):
    """One row of OCX_ENV_CLASSES.

    Args:
        cls: "site" (ambient, forwarded verbatim) | "translucent" (ambient,
            overridable by `attr`) | "explicit" (never ambient — only ever
            set from a resolved ocx.policy() attr) | "pinned" (fixed `value`
            on every invocation, never read from the ambient environment).
        attr: the CONFIG_ATTRS/POLICY_ATTRS name that overrides this key, if any.
        path: whether the row is a filesystem path — only a "translucent" row
            may set this, and it is what tells make_ocx_env() to ctx.watch() it.
        value: the fixed value of a "pinned" row.
        hermetic: whether no_config blanks this key when its ambient value
            would otherwise survive.
        file_url: whether ocx parses this row's value as a file reference, so a
            `file://` spelling is a path to it — only a `path` row may set this.

    Returns:
        struct(cls, attr, path, value, hermetic, file_url).
    """
    return struct(cls = cls, attr = attr, path = path, value = value, hermetic = hermetic, file_url = file_url)

# The classified env-var table (C-001): every OCX_* key any repository rule
# here ever sets or forwards, one row each, in insertion order. make_ocx_env(),
# stage_lazy_config() and render_lazy_launcher() all read it, so a new ocx
# variable is one row plus its class rather than three places that can
# disagree. One exception: stage_lazy_config() still hand-writes the staged
# filename of each `path` row, so a fourth staged file is two edits.
#
# OCX_ENV — ocx's forwarded entry payload — is deliberately absent: ocx strips
# an inherited one itself on every compose, and its decoder refuses `OCX_*`
# keys outright, so there is nothing here left to close. OCX_HOME is likewise
# absent: it is resolved from the host and `isolated_home`, never forwarded.
OCX_ENV_CLASSES = {
    # site: forwarded verbatim from the ambient environment. getenv() is what
    # registers them with Bazel, so changing one invalidates the fetched repos.
    # OCX_AUTH_<REGISTRY>_* cannot be enumerated here — document `bazel fetch
    # --force` after credential changes.
    "OCX_MIRRORS": _env("site"),
    "OCX_INSECURE_REGISTRIES": _env("site"),
    "OCX_OFFLINE": _env("site"),
    "OCX_FROZEN": _env("site"),
    "OCX_REMOTE": _env("site"),
    "OCX_JOBS": _env("site"),
    "OCX_INDEX": _env("site"),
    "OCX_DEFAULT_REGISTRY": _env("site"),
    "OCX_MANAGED_CONFIG": _env("site"),
    "OCX_PATCHES": _env("site", hermetic = True),
    # translucent: ambient value forwarded, but a rule attr overrides it and
    # no_config blanks the hermetic ones.
    "OCX_CONFIG": _env("translucent", attr = "config", path = True, hermetic = True),
    "OCX_PATCH_SNAPSHOT": _env("translucent", attr = "patch_snapshot", path = True, hermetic = True),
    "OCX_SIGSTORE_TRUSTED_ROOT": _env("translucent", attr = "sigstore_trusted_root", path = True, file_url = True),
    "OCX_NO_CONFIG": _env("translucent", attr = "no_config"),
    # explicit: the build's weakening posture — never read from the ambient
    # environment (an inherited OCX_NO_VERIFY/OCX_ALLOW_YANKED must not
    # silently weaken a build), only ever set from a resolved ocx.policy() tag.
    "OCX_NO_VERIFY": _env("explicit", attr = "allow_unverified"),
    "OCX_ALLOW_YANKED": _env("explicit", attr = "allow_yanked"),
    # pinned: a fixed value on every invocation. --global refuses to combine
    # with the explicit --project every call here passes, and --quiet
    # suppresses the very JSON report the parse surface reads (empty stdout,
    # exit 0). OCX_PROJECT is a path, and empty is its documented "unset"; the
    # BooleanStrings have no empty spelling — "0"/"1" neutralize them without
    # the "invalid boolean value" warning "" logs on every invocation.
    "OCX_PROJECT": _env("pinned", value = ""),
    "OCX_GLOBAL": _env("pinned", value = "0"),
    "OCX_QUIET": _env("pinned", value = "0"),
    "OCX_NO_PROJECT": _env("pinned", value = "1"),
    "OCX_NO_CONFIG_REFRESH": _env("pinned", value = "1"),
}

# The one pinned row a lazy launcher does not re-export (C-011).
_LAZY_UNPINNED = "OCX_QUIET"

def _rows(cls):
    """The env keys of one OCX_ENV_CLASSES class, in table order.

    Args:
        cls: the class name ("site", "translucent", "explicit", "pinned").

    Returns:
        list of env var names.
    """
    return [key for key, row in OCX_ENV_CLASSES.items() if row.cls == cls]

# Refuses ocx's own lazy composition on every eager code path. `ocx pull` writes
# a shim tree instead of content when the lazy ladder resolves to `always`, and
# a following `env`/`which` then reports that shim directory — so a rendered
# launcher would exec a script that downloads its tool inside a Bazel action
# (no declared input, and no network in a sandbox), and the package tier's
# `<root>/content` symlink would have nothing to point at.
#
# The flag, not OCX_LAZY_MODE. The ladder is
# `--lazy-mode ▸ [package."<id>"] ▸ [group.<g>] ▸ toolchain ▸ OCX_LAZY_MODE ▸
# never`, so the environment tier sits one rung above a floor that is already
# `never`: setting it there changes nothing, and a project's own ocx.toml
# outranks it. Only the CLI tier wins.
#
# Accepted by exactly the seven composing commands — `env`, `exec`, `pull`,
# `direnv export`, `package env`, `package exec`, `package which`. `package
# install` and `package select` always materialize and *reject* it (exit 64),
# and `inspect --closure` never composes, so none of the three takes it.
#
# The lazy `bins` tiers need it nowhere: their launchers re-enter `ocx exec` /
# `ocx package exec` at execution time, which is where deferring content is
# the whole point.
EAGER_LAZY_MODE = ["--lazy-mode", "never"]

SYSEXIT_HINTS = {
    64: ("usage error — the pinned ocx CLI and rules_ocx disagree on the command surface; " +
         "pin an ocx release this rules_ocx supports with ocx.download(version = '…') in " +
         "MODULE.bazel, or upgrade rules_ocx"),
    # Tier-neutral: the package tier has no lockfile, so a malformed reference
    # or digest is named first and 'ocx lock' offered as the project-tier case.
    # The patch_snapshot clause is not hypothetical: ocx 0.5.6 bumped the
    # snapshot to V2 (companions keyed by tag) and dropped V1 entirely, so a
    # file frozen by an older ocx and committed lands here — a shape this
    # rules_ocx's own pin bump is what starts refusing.
    65: ("data error — a malformed reference or digest; in a project, a lockfile out of date " +
         "with ocx.toml ('ocx lock', then commit); or a patch_snapshot written by an older " +
         "ocx ('ocx patch freeze' again, then commit)"),
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
    #
    # 83/85 (0.6.0): raised only inside `maybe_auto_verify`, the gate an
    # operator [[trust.policy]] attaches to a materializing fetch. Its one
    # production caller is `setup_impl` (ocx pull.rs), so of the eight commands
    # these rules run it is reachable from the project tier's `pull` and `env`
    # and from `package install` and `package env` — never from `lock --check`,
    # `package which` or either `inspect --closure`, none of which materializes.
    #
    # 84 is mapped for the contract, not because 0.6.0 can raise it here: the
    # verify path folds ClientError::ReferrersUnsupported into
    # NoSignaturesFound (79) and ocx's own comment calls 84 "write-path only",
    # which no repo rule reaches. Kept so a future ocx that classifies it on a
    # read fails with a route rather than a bare exit code.
    #
    # None of the three is retried — a transparency log that is down stays down
    # for longer than three registry round-trips (S-006), and 85 is
    # deterministic; revisit after the first flaky-CI report.
    83: ("the transparency log is unreachable — a signature could not be verified against " +
         "Rekor; retry once it is back, check network access to the log, or accept " +
         "unverified content with ocx.policy(allow_unverified = True) in MODULE.bazel"),
    84: ("the registry does not support the OCI Referrers API, so ocx cannot discover the " +
         "signatures the operator's [[trust.policy]] requires — publish through a registry " +
         "that implements it, route around it with OCX_MIRRORS, or opt out with " +
         "ocx.policy(allow_unverified = True) in MODULE.bazel"),
    85: ("unsupported signing key backend — the key reference in the operator's [trust] " +
         "configuration names a backend this ocx recognizes but does not implement " +
         "(awskms:// and the like); it never clears on retry — point that configuration at " +
         "a backend this ocx implements, or upgrade rules_ocx (it pins the ocx version) to " +
         "one pinning an ocx that implements it"),
}

# Extra attempts granted to a sysexit 75 even when the caller asked for none.
_TRANSIENT_RETRIES = 2

# The only sysexits another attempt can change: 69 a registry that may come
# back, 74 the store-symlink TOCTOU two parallel fetches race on, 75 ocx's own
# "transient, retry me". Everything else is settled on the first answer — a
# typo'd reference (79), expired credentials (80) or a policy block (81) would
# otherwise burn three registry round-trips and the backoff between them,
# multiplied by the platform count on a hub.
_RETRYABLE = [69, 74, 75]

# Env vars consulted to locate the platform user-config directory.
_CONFIG_HOME_ENV = ["XDG_CONFIG_HOME", "HOME", "APPDATA"]

# ocx's BooleanString set, case-insensitive.
_TRUTHY = ["1", "y", "yes", "on", "true"]

# Windows drive letters, for is_absolute_path — Bazel's Starlark has no
# per-character alpha predicate.
_DRIVE_LETTERS = "abcdefghijklmnopqrstuvwxyz"

_ALPHA = _DRIVE_LETTERS + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
_DIGITS = "0123456789"

# Characters a discovered tool name may contain. ocx's `BinaryName` grammar
# forbids only `/ \ < > : " | ? *` and non-graphic ASCII, so it admits `$ ( )
# ; ' ` and space — publisher-controlled metadata that becomes a shell word, a
# Starlark string literal in a generated BUILD file and a file name. Wide
# enough for the shapes real tools ship (git-lfs, python3.11, clang++,
# x86_64-linux-gnu-gcc) and nothing that carries meaning in any of the three.
_BIN_NAME_CHARS = _ALPHA + _DIGITS + "._+-"

# POSIX portable environment variable names: a letter or underscore, then
# letters, digits and underscores.
_ENV_KEY_CHARS = _ALPHA + _DIGITS + "_"

def valid_bin_name(name):
    """Whether a discovered tool name is safe to render verbatim.

    The name reaches three sinks unescaped — `native_binary(name = "…")` in a
    generated BUILD file, a launcher's shell text, and the `launchers/<name>`
    path written for it — so one charset covers all three. A leading `-` is
    refused because the name is also passed as an argv word (`ocx exec -- …`),
    and `.`/`..` because it is a path component, though both are made of
    admitted characters.

    Args:
        name: the declared or scanned executable name.

    Returns:
        bool.
    """
    if not name or name.startswith("-") or name == "." or name == "..":
        return False
    for c in name.elems():
        if c not in _BIN_NAME_CHARS:
            return False
    return True

def check_bin_names(names):
    """fail()s on a declared `bins` entry that cannot be rendered safely.

    The lazy tiers render launchers straight from the `bins` attr, never
    through discover_bins() — so the charset guard has to be applied here too.
    A discovered name is dropped and recorded, but a name written into
    `bins = [...]` was asked for by an ocx.package()/ocx.project() caller (any
    module in the graph, not only the root), so dropping it would silently
    produce a missing target instead of an answer.

    Args:
        names: the `bins` attr value.
    """
    for name in names:
        if not valid_bin_name(name):
            fail(("rules_ocx: bins entry '{}' cannot be a launcher — the name becomes a " +
                  "BUILD target, a shell word and a file name, so it is limited to " +
                  "letters, digits and '. _ + -' (and may not lead with '-')").format(name))

def valid_env_key(key):
    """Whether an `ocx env` entry key is a usable environment variable name.

    `ocx` serializes the key verbatim from package metadata; anything outside
    the POSIX portable set has no safe `export`/`set` spelling at all.

    Args:
        key: the entry's `key`.

    Returns:
        bool.
    """
    if not key or key[0] in _DIGITS:
        return False
    for c in key.elems():
        if c not in _ENV_KEY_CHARS:
            return False
    return True

def sh_quote(value):
    """A POSIX shell word that expands to exactly `value`.

    Single quotes suppress every expansion; the only character they cannot
    carry is `'` itself, spelled by closing, escaping and reopening.

    Args:
        value: arbitrary string.

    Returns:
        the quoted word, including its quotes.
    """
    return "'" + value.replace("'", "'\\''") + "'"

def bat_value(value):
    """A value safe inside a Batch `set "KEY=VALUE"`, or None if there is none.

    `%` opens a variable expansion and `%%` is its literal spelling in a batch
    file. A literal `"` closes the quoted region and has no in-place escape,
    so such a value cannot be rendered at all.

    Args:
        value: arbitrary string.

    Returns:
        the escaped value, or None when it cannot be rendered safely.
    """

    # ponytail: dropped, not escaped — `set K="a""b"` behaviour differs across
    # cmd.exe versions, and a store path cannot hold `"` on Windows anyway.
    if "\"" in value:
        return None
    return value.replace("%", "%%")

def truthy(value):
    """Whether an ocx-style boolean string env value is true.

    Mirrors ocx's `BooleanString` set, case-insensitively; `None` (unset) is
    false. An unrecognized value (neither the truthy set nor one of ocx's
    falsy strings) is not an error on this path: `env::flag()` logs "has
    invalid boolean value" and falls back to the flag's default, which is
    false for every flag read here — the same warning the pinned rows of
    OCX_ENV_CLASSES avoid by carrying "0" rather than "". Returning False
    therefore matches what ocx itself does with the value, which still reaches
    the real invocation. (`InvalidBooleanString` (exit 65) is the config-file path,
    not the env one.)

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
        # ponytail: ocx reads the literal /etc/ocx/config.toml on every OS —
        # Rust resolves it drive-relative on Windows, so C:\etc\ocx\config.toml
        # is a real (system-locked, non-overridable) tier there. It is skipped
        # anyway: "/etc/..." is not absolute for a Windows host, so ctx.watch()
        # cannot take it as spelled, and the drive it lands on is not knowable
        # here. Documented gap — on Windows, editing that file does not refetch.
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

# The attr schema make_ocx_env() and stage_lazy_config() read off ctx.attr.
# Declared once, next to the functions that consume it: a rule splatting this
# into its `attrs` is the contract, so the two cannot drift apart. Stardoc
# sorts attributes alphabetically, so splatting changes no rendered doc.
CONFIG_ATTRS = {
    "config": attr.label(
        allow_single_file = True,
        doc = "An ocx site config.toml (mirrors, registries, [patches]) layered over the " +
              "host's discovered config — not the project ocx.toml. Sets OCX_CONFIG for " +
              "every invocation, overriding an ambient one, and the file is watched. " +
              "Combine with no_config for a hermetic configuration. With `bins` it is " +
              "copied into the repository and uploaded as an input with every action — " +
              "keep credentials out of it.",
    ),
    "no_config": attr.bool(
        default = False,
        doc = "Ignore the host's discovered config tiers (/etc, the user config, " +
              "$OCX_HOME/config.toml) and the managed-config snapshot — sets OCX_NO_CONFIG=1, " +
              "and blanks an ambient OCX_CONFIG, OCX_PATCHES and OCX_PATCH_SNAPSHOT, which " +
              "OCX_NO_CONFIG alone does not prune. The `config` and `patch_snapshot` attrs " +
              "still apply. Use this when a corporate managed config must not reach the " +
              "build; it also opts out of the exit-78 gate a required-but-unsynced managed " +
              "config raises.",
    ),
    "patch_snapshot": attr.label(
        allow_single_file = True,
        doc = "A committed patches.snapshot.json (written by `ocx patch freeze` next to " +
              "ocx.lock) freezing the digests of the patch companions composed onto this " +
              "environment. Sets OCX_PATCH_SNAPSHOT. `ocx lock --check` does not cover " +
              "companions — without a frozen snapshot they resolve at fetch time. With " +
              "`bins` it is copied into the repository and uploaded as an input with every " +
              "action — keep credentials out of it.",
    ),
}

# The resolved-policy attr schema (C-004): splatted next to CONFIG_ATTRS by
# every ocx_project_repo/ocx_package_repo, and by the ocx.policy() tag class in
# extensions.bzl so one wording serves both. Normally threaded from that single
# root-only tag via resolve_policy() + policy_kwargs(); set directly on the
# public rules it bypasses the root-only guard, which governs the tag alone.
POLICY_ATTRS = {
    "allow_unverified": attr.bool(
        default = False,
        doc = "When true, sets OCX_NO_VERIFY=1 for every invocation and passes `--no-verify` " +
              "to `ocx package install`. When false, OCX_NO_VERIFY=0 is written anyway, so an " +
              "ambient value cannot switch verification off. It cannot switch verification " +
              "*on*: ocx attaches that only under an operator-configured `[[trust.policy]]`, " +
              "so this attr can only decline to disable it — and `no_config = True` prunes " +
              "the discovered tiers that policy lives in, so there is then nothing to " +
              "decline and verification is off either way.",
    ),
    "allow_yanked": attr.bool(
        default = False,
        doc = "Whether resolution may fall back to a yanked release — sets " +
              "OCX_ALLOW_YANKED for every invocation.",
    ),
    "sigstore_trusted_root": attr.label(
        allow_single_file = True,
        doc = "A sigstore trusted-root.json pinned in-tree. Sets OCX_SIGSTORE_TRUSTED_ROOT " +
              "for every invocation, overriding the ambient " +
              "`<OCX_HOME>/sigstore/trusted-root.json` rung, and the file is watched. Under " +
              "lazy provisioning (`bins` on `ocx.project`/`ocx.package`) it is copied into " +
              "the repository and uploaded as an input with every action.",
    ),
}

# resolve_policy() errors (C-005). Held in constants so a guard test can
# assert on the fragment without spelling it at its own call site
# (.claude/rules/starlark.md).
POLICY_NON_ROOT_MSG = "rules_ocx: ocx.policy() may only be used by the root module (used by '{}')"
POLICY_DUPLICATE_MSG = "rules_ocx: at most one ocx.policy() tag is allowed"

# What every resolve_policy() answer carries when no tag decided it: the
# no-tag case and both error cases. Spelled once so a fourth policy attr is
# one edit rather than three that can disagree.
_NO_POLICY = {"allow_unverified": False, "allow_yanked": False, "sigstore_trusted_root": None}

def resolve_policy(instances):
    """Reduces every ocx.policy() tag instance in the module graph to one triple.

    Root-only and at most one: a dependency that loosened the graph's trust
    posture would decide what the *workspace* installs, and a second tag is two
    answers to a one-answer question. Both are reported rather than silently
    dropped — the ecosystem majority ignores a non-root customization tag, but
    for a security surface a loud stop beats a quiet drop (ADR 0001), and it
    matches the sibling `download`/`project` tags in this same extension.

    Pure, like resolve_platforms(): the error is returned, not raised, so the
    extension impl fail()s at one place before declaring any repository.

    Args:
        instances: list of struct(module, is_root, allow_unverified, allow_yanked,
            sigstore_trusted_root) — one per `ocx.policy()` tag over every module.

    Returns:
        struct(error, allow_unverified, allow_yanked, sigstore_trusted_root).
        A non-empty `error` (POLICY_NON_ROOT_MSG or POLICY_DUPLICATE_MSG) means
        the caller must fail() before declaring any repo.
    """
    resolved = struct(error = "", **_NO_POLICY)
    for i, tag in enumerate(instances):
        if not tag.is_root:
            return struct(error = POLICY_NON_ROOT_MSG.format(tag.module), **_NO_POLICY)
        if i > 0:
            return struct(error = POLICY_DUPLICATE_MSG, **_NO_POLICY)
        resolved = struct(
            error = "",
            allow_unverified = tag.allow_unverified,
            allow_yanked = tag.allow_yanked,
            sigstore_trusted_root = tag.sigstore_trusted_root,
        )
    return resolved

def policy_kwargs(policy):
    """The resolved policy as the POLICY_ATTRS kwargs a repo rule declares.

    Splatted at every ocx_project_repo/ocx_package_repo call site, so a fourth
    policy attr is one row in POLICY_ATTRS plus one field here rather than
    three hand-written kwarg lists that can disagree — and a dropped kwarg
    would fall back to the same `False` the default carries, i.e. be invisible.

    Args:
        policy: the resolve_policy() struct.

    Returns:
        {POLICY_ATTRS key: resolved value}.
    """
    return {key: getattr(policy, key) for key in POLICY_ATTRS}

def policy_exports(allow_unverified, allow_yanked):
    """The OCX_NO_VERIFY/OCX_ALLOW_YANKED pair a resolved policy exports.

    Both keys are always present, and that presence is the neutralization: the
    two variables are `explicit` rows, never read from the ambient environment,
    so writing "0" is what shadows an OCX_NO_VERIFY exported three layers up in
    a CI image.

    Args:
        allow_unverified: resolved ocx.policy() `allow_unverified`.
        allow_yanked: resolved ocx.policy() `allow_yanked`.

    Returns:
        {"OCX_NO_VERIFY": "0"|"1", "OCX_ALLOW_YANKED": "0"|"1"} — both keys
        always present, which is the neutralization of any ambient value.
    """
    return {
        "OCX_NO_VERIFY": "1" if allow_unverified else "0",
        "OCX_ALLOW_YANKED": "1" if allow_yanked else "0",
    }

def sigstore_trust_root_path(home, is_windows):
    """The ambient sigstore trusted-root path under a resolved OCX_HOME.

    ocx's rung-4 convention in its trusted-root ladder, watched so that
    dropping a root in (or editing one) refetches the repos that verified
    against it. Hand-constructed like ambient_config_paths(): ocx has no
    read-only command reporting the path, so the layout is hard-coded and the
    watch fails *open* — relocate the directory upstream and it silently covers
    nothing. Re-verified on every ocx bump (the `update-dist` skill).

    Args:
        home: the resolved OCX_HOME, or "" (isolated_home drops this tier).
        is_windows: host flag (path separator).

    Returns:
        the absolute path string, or None when `home` is falsy.
    """
    if not home:
        return None
    return ("\\" if is_windows else "/").join([home, "sigstore", "trusted-root.json"])

# A translucent `path` row names a file ocx opens *and* Bazel has to watch, and
# ctx.watch() takes absolute paths only. A relative ambient value would be
# forwarded and silently left unwatched, so it is refused rather than
# half-honoured — same reasoning as the OCX_HOME guard below. The message names
# the row's own attr: OCX_SIGSTORE_TRUSTED_ROOT's lives on ocx.policy(), not on
# the ocx.project()/ocx.package() tag the other two belong to.
RELATIVE_ENV_PATH_MSG = ("rules_ocx: {} must be an absolute path, got '{}' — a repository rule runs " +
                         "from Bazel's own working directory, so a relative value names a different " +
                         "file than it does in your shell and Bazel cannot watch it. Export an " +
                         "absolute path, or set the `{}` attr.")

def make_ocx_env(ctx, host, isolated_home):
    """Assembles the environment for ocx invocations from this repo rule.

    Also registers the host's ambient config tiers as watched inputs, so a
    site config edit — including an `ocx config update` refreshing the managed
    snapshot — refetches the repos that consumed it.

    Every key comes from OCX_ENV_CLASSES: `pinned` rows are written first,
    `site` and `translucent` rows are read with ctx.getenv() (which is what
    registers them with Bazel), `translucent` rows are then overridden by their
    attr, and the `explicit` pair is written last from the resolved
    ocx.policy(). The weakening knobs are never read from the environment at
    all — an exported OCX_NO_VERIFY must not decide what this build verifies.

    Args:
        ctx: repository_ctx with the CONFIG_ATTRS and POLICY_ATTRS attrs.
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

    # `ocx exec` exports OCX_PROJECT (possibly relative) into child processes;
    # a bazel invoked that way would leak it into every repo-rule ocx call,
    # which runs from a different cwd. Project context only ever comes from
    # explicit --project flags here, so neutralize it — along with the other
    # ambient knobs that break rather than steer an invocation.
    #
    # OCX_NO_CONFIG_REFRESH: the background managed-config refresh wants a TTY
    # no repo rule ever has. Pinned off explicitly rather than trusting ocx's
    # TTY probe — the CLI is version-unstable (invariant 2).
    env = {"OCX_HOME": home}
    for key in _rows("pinned"):
        env[key] = OCX_ENV_CLASSES[key].value
    for key in _rows("site") + _rows("translucent"):
        value = ctx.getenv(key)
        if value != None:
            env[key] = value

    # OCX_NO_CONFIG only prunes the *discovered* tiers: ocx loads an explicit
    # OCX_CONFIG regardless, and with the config tier gone an ambient
    # OCX_PATCHES becomes the *only* patch source — attacker-chosen companions
    # composed into a build that asked for hermeticity. Empty is ocx's
    # documented "treat as unset" for all three; the attrs below then reinstate
    # whatever the caller did ask for. A trusted root is not a config tier, so
    # it carries no `hermetic` flag and survives.
    if ctx.attr.no_config:
        for key, row in OCX_ENV_CLASSES.items():
            if row.hermetic:
                env[key] = ""

    # Attrs beat the ambient environment: a bool row is only ever turned on
    # (its "off" is the ambient answer), a path row becomes the resolved file,
    # and ctx.path() is what registers that file with Bazel. A surviving
    # ambient path row is watched instead — it names a file ocx reads that
    # Bazel would otherwise never see, so editing an ambient site config would
    # not refetch, and a relative one that cannot be watched is refused rather
    # than forwarded unwatched. A row the block above blanked is "" and is
    # skipped by the emptiness test, which is the whole of the no_config case.
    # OCX_PATCHES is deliberately not a path row: it carries a JSON
    # `[patches]` envelope, not a filename.
    for key in _rows("translucent"):
        row = OCX_ENV_CLASSES[key]
        override = getattr(ctx.attr, row.attr)
        if override:
            env[key] = str(ctx.path(override)) if row.path else "1"
        elif row.path and env.get(key, ""):
            # A `file://` value on a `file_url` row is not a path to test or
            # watch: ocx reads OCX_SIGSTORE_TRUSTED_ROOT through
            # FileReference::parse, which consumes a case-insensitive `file://`
            # prefix at exactly this door (ocx-sh/ocx#379). Forwarded verbatim
            # and left unwatched — the watch fails open there, which beats
            # refusing a value ocx honours. Scoped to that row and that scheme
            # because nothing else has the grammar: the other two `path` rows
            # are a plain PathBuf::from, and every other scheme (`https://`, a
            # bare `foo://`) is a literal relative filename to ocx — those keep
            # the refusal below and fail closed. A relative `file://x` is the
            # one value still forwarded unwatched; ocx reads it as `x` and
            # errors loudly (exit 74) when it is not there.
            if not (row.file_url and env[key].lower().startswith("file://")):
                if not is_absolute_path(env[key], host.is_windows):
                    fail(RELATIVE_ENV_PATH_MSG.format(key, env[key], row.attr))
                ctx.watch(env[key])

    # The weakening pair, written last and unconditionally: these two rows are
    # never read from the environment, so this is the only thing that decides
    # them — and their presence shadows whatever the CI image exported.
    env.update(policy_exports(ctx.attr.allow_unverified, ctx.attr.allow_yanked))

    # Outside the no_config gate: with no_config plus a `config` label carrying
    # [[trust.policy]], ocx still reads the OCX_HOME trusted-root rung, so
    # Bazel has to invalidate on it. isolated_home drops the tier the same way
    # it drops the OCX_HOME config tiers — the store lives inside the
    # repository being fetched, which cannot be watched.
    trust_root = sigstore_trust_root_path("" if isolated_home else home, host.is_windows)
    if trust_root:
        ctx.watch(trust_root)

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
        retries: extra attempts after a *transient* failure (_RETRYABLE — any
            other sysexit is settled on the first answer and fails at once).
            Repo rules fetch in parallel, and concurrent `ocx package install`
            calls of the same package can race on store symlink creation (ocx
            TOCTOU); the store is idempotent, so a retry converges. A sysexit
            75 is retried regardless — it is ocx's own "transient, retry me",
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
        if result.return_code not in _RETRYABLE:
            break
        if attempt >= retries and result.return_code != 75:
            break

        # ponytail: linear 1s, 2s, … — back-to-back execs span microseconds
        # while a registry rate-limit window spans seconds. The right ceiling
        # is a registry-policy question; make the schedule an attribute once a
        # real registry's limits are known. No Batch `sleep`, so Windows keeps
        # retrying immediately. `sleep` runs through an absolute /bin/sh, with
        # an explicit PATH: the bare `sleep` argv would otherwise resolve
        # against whatever PATH the repository rule inherited (CWE-426).
        if not is_windows and attempt + 1 < attempts:
            ctx.execute(
                ["/bin/sh", "-c", 'sleep "$0"', str(attempt + 1)],
                environment = {"PATH": "/usr/bin:/bin"},
            )
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

# `value` if it is a JSON object, else an empty one — so a chained .get() over
# a drifted report yields a missing key instead of a Starlark type error, and
# the one fail() below stays the only way out of closure_packages().
def _as_dict(value):
    return value if type(value) == "dict" else {}

def closure_packages(stdout, what):
    """Validates and returns the `packages` list of an `inspect --closure` report.

    Decodes `stdout` itself via decode_json(stdout, what), then validates the
    result — one error vocabulary for the one command that produced it,
    whether it failed by not being JSON or by being JSON of the wrong shape.

    `InspectReport` always serializes its top-level `packages` key, and it is
    an array — but a guard that only holds for today's shape is not a guard,
    so the container is checked too: a report that is not an object, has no
    `packages`, or whose `packages` is anything but a list fails here rather
    than tracebacking out of a raw index (iterating an object would walk its
    *keys*, and a string entry then has no `.get`).

    What ocx omits conditionally is each entry's `closure`: `--closure` walks
    the closure only for a resolved (`Manifest`/`Resolved`) body, so a binding
    that came back as unresolved `candidates` — an ambiguous tag, or an
    `ocx inspect` binding projected straight off ocx.lock with no single
    artifact to walk — carries no `closure` at all. Each entry is therefore
    checked too: it must be an object with an `identifier`, and its
    `closure.surface.interface` must carry `binaries_complete` and the two
    lists `binaries` and `entrypoints` — every key declared_bins() indexes
    off a *package* entry, in the type it indexes it as. `SurfaceOut` always
    serializes both arrays, so a missing `entrypoints` is shape drift, not an
    empty claim. What is not guarded is `name` inside their elements: both
    are `BinaryAttribution`, whose `name` is a non-`Option` `String`, so it
    is always serialized, and a drift there would still traceback.
    The fail() names the pin to move per invariant 4: this is a shape drift
    between the pinned ocx and what rules_ocx parses, not a mapped sysexit.
    It says so in the consumer's terms — rules_ocx is what pins ocx, so a
    consumer upgrades the ruleset or pins ocx.download(version = …), never the
    private DEFAULT_OCX_VERSION.

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
    packages = _as_dict(decode_json(stdout, what)).get("packages")
    drift = ""
    if type(packages) != "list":
        drift = "no 'packages' list (got {})".format(type(packages))
    for pkg in packages if type(packages) == "list" else []:
        if type(pkg) != "dict":
            drift = "a 'packages' entry that is not an object (got {})".format(type(pkg))
            break
        interface = _as_dict(_as_dict(_as_dict(pkg.get("closure")).get("surface")).get("interface"))
        if (type(interface.get("binaries")) != "list" or
            type(interface.get("entrypoints")) != "list" or
            type(interface.get("binaries_complete")) != "bool" or
            "identifier" not in pkg):
            drift = "'{}' with no closure surface".format(pkg.get("identifier", "<unnamed package>"))
            break
    if drift:
        fail(("rules_ocx: {} reported {} — the pinned ocx CLI and rules_ocx disagree on the " +
              "report shape. Upgrade rules_ocx (it pins the ocx version), or pin an ocx " +
              "release this rules_ocx parses with ocx.download(version = '…') in " +
              "MODULE.bazel.").format(what, drift))
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
            if not lower.endswith(".exe") and not lower.endswith(".bat") and not lower.endswith(".cmd"):
                continue

            # A directory named `foo.exe` is not a tool, and a launcher exec-ing
            # one dies at action time — the same rejection resolve_bins() makes
            # on the declared path.
            if not child.is_dir:
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

    A package's command surface is the *union* of `entrypoints` and
    `binaries` — two parallel `BinaryAttribution` arrays that may claim the
    same name (that overlap is the point: the generated `entrypoints/`
    launcher shadows the raw `bin/` file). The union is deduped by name;
    order here only sets target declaration order. *Which file* a name
    resolves to is decided entirely by path_dirs()' search precedence in
    resolve_bins() — the closure-wide surface flattens every admitted node,
    so no concatenation order could mirror the composed PATH anyway.

    `incomplete` is driven by `binaries_complete` alone: the flag covers only
    `binaries`, and there is no entrypoints equivalent because the entrypoint
    map keys are always authoritative.

    Args:
        packages: the `packages` list of an `ocx [package] inspect --closure`
            report.

    Returns:
        struct(names, incomplete): `names` in declaration order, deduped on
        first occurrence (a name is one target however many surface entries
        claim it — this picks a name string, not a PATH slot), `incomplete` the
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
        for binary in interface["entrypoints"] + interface["binaries"]:
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

    The result is **reversed**: an ocx consumer applies entries by prepending
    each one in list order (move-to-front), so the last declared PATH entry
    ends up first in the resolved PATH. Reversing here, combined with the
    first-hit-wins scans in resolve_bins()/scan_bins(), reproduces
    move-to-front exactly. Forward order would let `bin/` shadow the
    `entrypoints/` entry ocx deliberately pushes last.

    An empty value is dropped, as ocx's move_to_front drops it — joined
    verbatim it would probe `"/" + name` here and put an empty PATH element
    (the action's CWD) into launchers.

    Args:
        entries: env entries [{"key", "value", "type"}, ...] from `ocx env`.

    Returns:
        list of directory path strings, in search-precedence order (the
        reverse of declaration order).
    """
    return reversed([e["value"] for e in entries if e["type"] == "path" and e["key"].upper() == "PATH" and e["value"]])

def resolve_bins(ctx, names, entries, is_windows):
    """Locates each declared executable on the composed PATH.

    A declared binary is a name, not a path, so the concrete file is found the
    way a shell would: first PATH directory holding it wins. A claimed name
    that no directory holds is dropped — the claim is publisher-declared and
    unverified.

    Args:
        ctx: repository_ctx.
        names: declared executable names; order only orders the result —
            resolution precedence comes from path_dirs().
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

    Both discovery paths converge here, so this is also where names are
    checked against valid_bin_name() — one guard covering every renderer
    downstream. A rejected name is dropped rather than fatal: failing the
    fetch would let one third-party package's metadata break an unrelated
    consumer's build. It is recorded the same way `scanned` is.

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
        packages whose incomplete metadata forced the PATH scan, rejected =
        names dropped as unrenderable).
    """
    surface = declared_bins(closure_packages(stdout, what))
    if not surface.incomplete:
        found = resolve_bins(ctx, surface.names, entries, is_windows)
        scanned = []
    else:
        found = scan_bins(ctx, entries, is_windows)
        scanned = surface.incomplete

    bins = []
    rejected = []
    for b in found:
        if valid_bin_name(b.name):
            bins.append(b)
        else:
            rejected.append(b.name)
    return struct(bins = bins, scanned = scanned, rejected = rejected)

def scan_bins(ctx, entries, is_windows):
    """Discovers runnable tools by scanning the composed PATH.

    The fallback for packages that declare no complete `binaries` metadata.
    Mirrors ocx PATH semantics: path_dirs() hands back search-precedence
    order (declaration order reversed, because ocx prepends each entry), and
    the first name found wins. Windows binaries are keyed by their
    extension-less name.

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

    The weakening pair is exported unconditionally: the action environment is
    the executor's, so an OCX_NO_VERIFY set there would otherwise decide what
    the deferred fetch verifies — the same hole the fetch path closes, one
    process later. A *translucent* row with no attr is deliberately not
    exported, so the executor's own site environment stays authoritative;
    baking this machine's ambient answer into every action key would be the
    opposite of what host-authoritative config means.

    Args:
        ctx: repository_ctx with the CONFIG_ATTRS and POLICY_ATTRS attrs.
        is_windows: host flag; Windows launchers bake absolute paths, POSIX
            ones resolve through runfiles.

    Returns:
        struct(exports = {env var: value} for render_lazy_launcher,
        data = label strings to attach to every launcher).
    """
    exports = policy_exports(ctx.attr.allow_unverified, ctx.attr.allow_yanked)
    data = []
    if ctx.attr.no_config:
        exports["OCX_NO_CONFIG"] = "1"

        # OCX_NO_CONFIG prunes only the discovered tiers — the same ambient
        # hermetic rows that make_ocx_env() blanks at fetch time would
        # otherwise be inherited from the action's environment here. Empty is
        # ocx's "treat as unset"; a set attr overwrites the entry below. The
        # trusted root carries no `hermetic` flag and is not blanked: it is
        # not a config tier.
        for var, row in OCX_ENV_CLASSES.items():
            if row.hermetic:
                exports[var] = ""
    for label, name, var in [
        (ctx.attr.config, "config.toml", "OCX_CONFIG"),
        (ctx.attr.patch_snapshot, "patches.snapshot.json", "OCX_PATCH_SNAPSHOT"),
        (ctx.attr.sigstore_trusted_root, "trusted-root.json", "OCX_SIGSTORE_TRUSTED_ROOT"),
    ]:
        if not label:
            continue

        # Not executable: it lands 0644 in the output base — Bazel has no API
        # to write a repo file 0600, so a config the operator set 0600 becomes
        # world-readable there, and being a runfile it is uploaded as an action
        # input with every action. Every one of the three attr docs says so.
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

# rlocation's exit status is not a miss detector. runfiles.bash carries its own
# FIXME on this: "If the runfiles lookup fails, the exit code of this function
# is 0 if and only if the runfiles manifest exists" — a manifest-only execution
# (the common sandboxed and remote case) answers a miss with exit 0 and empty
# output, and only a lookup with neither manifest nor runfiles directory
# returns 1. So the split assignment below covers the second case under
# `set -e` and this guard covers the first: an empty OCX_CONFIG or
# OCX_PATCH_SNAPSHOT is ocx's documented "treat as unset", which would drop the
# staged file silently and leave a green build with less configuration than it
# asked for. 74 is the io sysexit SYSEXIT_HINTS already maps.
#
# `${k}` is a Starlark format field inside a shell `$`, not a `${…}` brace
# expansion: it renders as `"$OCX_CONFIG"`.
_RLOCATION_GUARD = '[ -n "${k}" ] || {{ echo "rules_ocx: {k} runfile missing" >&2; exit 74; }}'

def render_lazy_launcher(command, is_windows, exports = {}):
    """Renders a lazy launcher: ocx is re-entered at execution time.

    No store paths are baked in — the wrapped ocx command auto-installs
    missing content on first use, so the action key is the script text plus
    its runfiles, never the tool content itself. POSIX scripts locate their
    inputs through the runfiles library, keeping the text identical across
    machines (portable remote-cache keys).

    Every `pinned` row of OCX_ENV_CLASSES except OCX_QUIET is re-exported
    first, in table order, ahead of the caller's own exports. They are pinned
    for the same reasons the fetch path pins them: each rendered command
    passes an explicit `--project` (or a digest-pinned reference) and ocx
    refuses to combine an ambient OCX_PROJECT/OCX_GLOBAL with one, and
    OCX_NO_PROJECT closes the CWD walk an action would otherwise run from its
    execroot. OCX_GLOBAL is a BooleanString, so "0" and not "" (which ocx logs
    as an invalid boolean on every launcher-run tool). OCX_QUIET is the one
    skip: no JSON report is parsed at action time, so a launcher-run tool's
    verbosity stays the user's to set.

    Every POSIX row is assigned and *then* exported, never
    `export K="$(rlocation …)"`: a command substitution inside a declaration
    builtin does not propagate its exit status, so `set -e` would not fire on
    a failed lookup. A value resolved through runfiles carries
    _RLOCATION_GUARD as well, for the miss that answers 0 with an empty
    string. Windows values go through bat_value() like every other rendered
    Batch value, and an unrenderable one is dropped rather than mangled.

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
    pinned = [(key, OCX_ENV_CLASSES[key].value) for key in _rows("pinned") if key != _LAZY_UNPINNED]
    if is_windows:
        # ponytail: absolute paths — portable keys need a Batch runfiles
        # lookup; add one if Windows remote caching ever matters.
        lines = ["@echo off", "rem Generated by rules_ocx - do not edit."]
        for key, value in pinned + exports.items():
            safe = bat_value(value)
            if safe != None:
                lines.append('set "{}={}"'.format(key, safe))
        lines.append("{} %*".format(" ".join(command)))
        return "\r\n".join(lines) + "\r\n"
    lines = [
        "#!/usr/bin/env bash",
        "# Generated by rules_ocx — do not edit.",
        _RUNFILES_PREAMBLE,
    ]
    for key, value in pinned + exports.items():
        lines.append('{}="{}"'.format(key, value))
        lines.append("export " + key)
        if "$(rlocation " in value:
            lines.append(_RLOCATION_GUARD.format(k = key))
    lines.append('exec {} "$@"'.format(" ".join(command)))
    return "\n".join(lines) + "\n"

# Shape drift on the env report's modifier kind, per invariant 4: a `type`
# outside ocx's three `ModifierKind`s is a disagreement between the pinned CLI
# and what rules_ocx parses, not a mapped sysexit.
#
# Held in a constant so the guard test can assert on it without spelling the
# text at its own call site: a Starlark failure echoes each frame's source
# line, so a fragment the call site also spells matches the echo and passes
# vacuously (.claude/rules/starlark.md).
UNKNOWN_MODIFIER_MSG = ("rules_ocx: ocx env reported modifier type '{}' for '{}' — the pinned ocx " +
                        "CLI and rules_ocx disagree on the report shape. Upgrade rules_ocx (it " +
                        "pins the ocx version), or pin an ocx release this rules_ocx parses with " +
                        "ocx.download(version = '…') in MODULE.bazel.")

# ocx's `package::metadata::env::list::DEFAULT_SEPARATOR`. An entry that
# reaches the report with no `separator` is one where no contributor to the key
# declared one (ocx reconciles them at compose time), so the fold falls back to
# a space rather than guessing over somebody's explicit choice.
_LIST_DEFAULT_SEPARATOR = " "

def append_unique(existing, value, separator):
    """`existing` with `value` folded onto the back, deduped on the separator.

    Replays ocx's `utility::list::append_unique`: wrap `existing` in the
    separator, delete every `separator + value + separator` occurrence to a
    fixpoint, strip the wrapper, then append `value` at the back. Removing
    *every* occurrence rather than the first is what keeps the fold idempotent
    when the value already appears twice.

    An empty `value` is a no-op — on an empty `existing` too, which is where a
    list entry deliberately differs from a path one: appending nothing must not
    bring the variable into existence.

    Elements are opaque. Nothing is tokenized or trimmed: list element grammar
    belongs to the consuming tool, never to ocx and never to rules_ocx.

    Args:
        existing: the value folded so far; "" when nothing is.
        value: the contribution to append.
        separator: the fold separator, never empty.

    Returns:
        the folded string.
    """
    if not value:
        return existing
    wrapped = separator + existing + separator
    occurrence = separator + value + separator

    # Starlark has no `while`, and this is the same fixpoint: every pass that
    # finds an occurrence removes at least one, so the occurrence count bounds
    # the passes.
    for _ in range(len(wrapped)):
        if occurrence not in wrapped:
            break
        wrapped = wrapped.replace(occurrence, separator)

    # Each replacement leaves a separator where a separator-flanked match
    # stood, so the wrapper survives — except when everything between collapsed
    # and the two ends fused into the single separator left behind.
    survivors = ""
    if wrapped.startswith(separator):
        inner = wrapped[len(separator):]
        if inner.endswith(separator):
            survivors = inner[:len(inner) - len(separator)]
    if not survivors:
        return value
    return survivors + separator + value

def fold_lists(entries):
    """Folds the `list` entries of one env report into one value per key.

    Args:
        entries: env entries [{"key", "value", "type", "separator"?}, ...] that
            already passed valid_env_key(), in declaration order.

    Returns:
        {key: struct(value, separator)} in first-declaration order, keys whose
        fold came out empty omitted.
    """
    grouped = {}
    for entry in entries:
        grouped.setdefault(entry["key"], []).append(entry)

    folded = {}
    for key, items in grouped.items():
        # ocx's `reconcile_list_separators` makes every contributor to a key
        # agree before the report is serialized, so the first entry's
        # separator is the key's separator.
        separator = items[0].get("separator") or _LIST_DEFAULT_SEPARATOR
        value = ""
        for item in items:
            value = append_unique(value, item["value"], separator)
        if value:
            folded[key] = struct(value = value, separator = separator)
    return folded

def render_launcher(entries, target, home, ocx, is_windows):
    """Renders a launcher script applying the ocx env and exec-ing a tool.

    `path` entries prepend to the invoking environment, `constant` entries
    replace, and `list` entries append behind it — the three `ModifierKind`s
    ocx serializes. An unrecognized `type` is shape drift and fails: folding it
    into a constant would silently *replace* an environment ocx would have
    extended. OCX_HOME and OCX_BINARY_PIN are baked so ocx entrypoint
    launchers re-enter the pinned ocx against the right store.

    A `list` key is emitted as a conditional: ocx's fold appends behind the
    ambient value and yields the bare value when there is none, so a launcher
    that always joined would leave a leading separator on an unset key. The
    declared contributions are folded against each other here; the ambient
    value is not deduped against them, exactly as the `path` line does not
    dedupe against the invoking `PATH`.

    An ocx consumer applies each `path` entry by prepending it with
    move-to-front dedup, so the *last* entry for a key ends up first. The
    single value baked here is therefore the reverse of declaration order,
    deduped keeping the first occurrence in that reversed order, empty
    values dropped — the same string move-to-front produces for the
    one-directory-per-entry values ocx emits (an empty value joined verbatim
    would be an empty PATH element: the action's CWD).

    Every value here is publisher-controlled: `ocx env` serializes keys and
    values straight out of package metadata, and even the exec target is a
    declared name joined onto a PATH directory that same metadata contributed.
    So keys are validated and dropped when unusable, and values are quoted —
    losslessly on POSIX, and on Windows by the one escape `set "K=V"` has.

    Args:
        entries: env entries [{"key", "value", "type", "separator"?}, ...].
        target: absolute path of the executable to exec.
        home: resolved OCX_HOME.
        ocx: absolute path of the pinned ocx binary.
        is_windows: render .bat instead of POSIX sh.

    Returns:
        script content string.
    """
    declared = {}  # key -> [values] in declaration order
    listed = []  # `list` entries, in declaration order
    constants = []  # (key, value)
    for entry in entries:
        if not valid_env_key(entry["key"]):
            continue
        if entry["type"] == "path":
            declared.setdefault(entry["key"], []).append(entry["value"])
        elif entry["type"] == "constant":
            constants.append((entry["key"], entry["value"]))
        elif entry["type"] == "list":
            listed.append(entry)
        else:
            fail(UNKNOWN_MODIFIER_MSG.format(entry["type"], entry["key"]))
    list_values = fold_lists(listed)

    # Reverse + first-wins == ocx's prepend-with-move-to-front, replayed once.
    path_values = {}  # key -> [values] in search-precedence order
    for key, values in declared.items():
        seen = {}
        ordered = []
        for value in reversed(values):
            if not value or value in seen:
                continue
            seen[value] = True
            ordered.append(value)
        if ordered:
            path_values[key] = ordered

    if is_windows:
        exe = bat_value(target)
        if exe == None:
            fail(("rules_ocx: refusing to render a launcher for '{}' — a literal quote in the " +
                  "path has no escape inside a batch file").format(target))
        lines = ["@echo off", "rem Generated by rules_ocx - do not edit."]
        for key, value in [("OCX_HOME", home), ("OCX_BINARY_PIN", ocx)] + constants:
            safe = bat_value(value)
            if safe != None:
                lines.append('set "{}={}"'.format(key, safe))
        for key, values in path_values.items():
            safe = bat_value(";".join(values))
            if safe != None:
                lines.append('set "{}={};%{}%"'.format(key, safe, key))
        for key, folded in list_values.items():
            safe = bat_value(folded.separator + folded.value)
            bare = bat_value(folded.value)
            if safe != None and bare != None:
                # `%KEY%` expands when cmd parses the whole `if`, and in the
                # taken branch the variable is defined by definition of the
                # test — so the one-line form needs no delayed expansion.
                lines.append('if defined {key} (set "{key}=%{key}%{safe}") else (set "{key}={bare}")'.format(
                    key = key,
                    safe = safe,
                    bare = bare,
                ))
        lines.append('"{}" %*'.format(exe))
        return "\r\n".join(lines) + "\r\n"

    lines = ["#!/usr/bin/env bash", "# Generated by rules_ocx — do not edit.", "set -euo pipefail"]
    for key, value in [("OCX_HOME", home), ("OCX_BINARY_PIN", ocx)] + constants:
        lines.append("export {}={}".format(key, sh_quote(value)))
    for key, values in path_values.items():
        # The value is inert, the `${KEY:+…}` suffix appending the invoking
        # environment's own value is not — so they are quoted separately.
        lines.append('export {key}={values}"${{{key}:+:${{{key}}}}}"'.format(
            key = key,
            values = sh_quote(":".join(values)),
        ))
    for key, folded in list_values.items():
        # An `if` rather than the `${KEY:+…}` one-liner the path arm uses: both
        # the separator and the folded value are publisher-controlled, and
        # neither can be carried into the *word* half of a parameter expansion
        # without reopening the quoting this whole function exists to close.
        lines.append('if [ -n "${{{key}:-}}" ]; then export {key}="${{{key}}}"{sep}{value}; else export {key}={value}; fi'.format(
            key = key,
            sep = sh_quote(folded.separator),
            value = sh_quote(folded.value),
        ))
    lines.append('exec {} "$@"'.format(sh_quote(target)))
    return "\n".join(lines) + "\n"

def render_env_bzl(entries, home, scanned = [], rejected = []):
    """Renders the generated repo's env.bzl.

    JSON round-trip keeps escaping correct for arbitrary values.

    Args:
        entries: env entries from `ocx env`.
        home: resolved OCX_HOME.
        scanned: identifiers of packages whose incomplete `binaries` metadata
            forced the PATH scan (discover_bins().scanned).
        rejected: tool names dropped as unrenderable (discover_bins().rejected).

    Returns:
        env.bzl content string.
    """
    payload = json.encode({
        "entries": entries,
        "home": home,
        "scanned": scanned,
        "rejected": rejected,
    })
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
        "# Tool names dropped because they cannot be rendered into a BUILD target, a",
        "# shell launcher and a file name unescaped. Empty means nothing was dropped.",
        'OCX_REJECTED_BINS = _DATA["rejected"]',
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
