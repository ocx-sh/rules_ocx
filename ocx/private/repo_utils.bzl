# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Shared plumbing for repository rules that shell out to the ocx CLI.

Everything that can be a pure function of plain values (the env table, the
policy reducer, config-path derivation) is one, so tests/ can cover it without
a repository_ctx.
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
# here ever sets or forwards, one row each, in insertion order. make_ocx_env()
# reads it, so a new ocx variable is one row plus its class.
#
# OCX_ENV — ocx's forwarded entry payload — is deliberately absent: ocx strips
# an inherited one itself on every compose, and its decoder refuses `OCX_*`
# keys outright, so there is nothing here left to close. OCX_HOME is likewise
# absent: it is always a directory inside the repository being fetched, never forwarded.
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
    # 0.6.2: extra TLS roots (a PEM path, or the PEM text) for every registry,
    # index, Sigstore and TUF client — a corporate proxy CA. Outranks every
    # config.toml tier. Opaque rather than a watched `path` row: a root decides
    # whether a fetch connects, never which bytes it gets (digests do), so an
    # edit has nothing to invalidate.
    "OCX_EXTRA_CA_CERTS": _env("site"),
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
    # `ocx pull` and `ocx exec` otherwise stamp shell-activation consent for
    # the `--project` directory, which the prompt hook then honours on every
    # `cd` (ocx-sh/ocx#400). The flags outrank it; no call here passes one.
    "OCX_NO_CONSENT": _env("pinned", value = "1"),
    # Empty is ocx's "absent": the render `ocx pull` does stays at
    # `<project>/.ocx/toolchain` instead of following an exported root into the user's home. Not a
    # repository path: ocx refuses a root outside $HOME/$OCX_HOME with exit 78
    # on *every* command, and Bazel's output base is outside $HOME on macOS.
    # A config.toml `toolchain_dir` still outranks this (env is its weakest tier).
    "OCX_TOOLCHAIN_DIR": _env("pinned", value = ""),
}

def _rows(cls):
    """The env keys of one OCX_ENV_CLASSES class, in table order.

    Args:
        cls: the class name ("site", "translucent", "explicit", "pinned").

    Returns:
        list of env var names.
    """
    return [key for key, row in OCX_ENV_CLASSES.items() if row.cls == cls]

# Every ocx command resolves its whole configuration before it does anything
# (Context::try_init), so a refused setting surfaces as 65/74/78 from *any*
# call — including the ones whose call-site hint names a single cause. These
# tails keep those overrides honest; the default hints below spell the same
# causes inline.
#
# 0.6.2: an extra CA *file* holding no certificate is 65 (unreadable: 74);
# inline PEM text that is not one is 78.
CA_FILE_TAIL = ("; if the error above names a CA file instead, it holds no valid " +
                "certificate — fix OCX_EXTRA_CA_CERTS or extra_ca_certs")

# A registry host resolving to a private/loopback/metadata address is refused
# with 78 (the fix is a trusted_hosts entry); 0.6.1 made the ocx.toml
# `activate` key and 0.6.2's config.toml `toolchain_dir` refusable too.
CONFIG_TAIL = ("; if the error above names a setting instead, ocx refused it — a registry " +
               "host resolving to a private address (allow it in " +
               "[registries.\"<ns>\"].trusted_hosts), or a config.toml / ocx.toml value")

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
    #
    # 0.6.1+: a package layer refused at extraction (a path escaping its root,
    # a symlink ladder, a hard link out) is 65, not 1 — the artifact is hostile
    # or corrupt, so it never clears on retry.
    65: ("data error — a malformed reference or digest; a package layer ocx refused to " +
         "extract (it escapes its root — a hostile or corrupt artifact, report it to the " +
         "publisher); in a project, a lockfile out of date with ocx.toml ('ocx lock', then " +
         "commit); a patch_snapshot written by an older ocx ('ocx patch freeze' again, then " +
         "commit)" + CA_FILE_TAIL),
    # 0.6.1+: a guarded registry or Sigstore host that does not resolve is 69
    # (was 78/64); 0.6.2: so is a TLS certificate refusal, never a retried 75.
    69: ("a required service or registry is unavailable — its host did not resolve, or its " +
         "TLS certificate was refused (behind an intercepting proxy, export " +
         "OCX_EXTRA_CA_CERTS or set extra_ca_certs in config.toml); check network, " +
         "OCX_MIRRORS, and registry auth"),
    74: ("io error — a local read or write failed (disk full, or a denied filesystem " +
         "operation); check disk space and permissions on OCX_HOME, and that an " +
         "OCX_EXTRA_CA_CERTS / extra_ca_certs file is readable"),
    75: ("transient registry failure — a timeout, capacity exceeded, or an incomplete " +
         "transfer; retry, or route through OCX_MIRRORS"),
    77: ("permission denied — the registry rejected the request for this repository (403), or " +
         "OCX_HOME is not writable by the current user; check registry access and OCX_HOME's " +
         "permissions"),
    # Both project-tier 78s (missing/unsupported ocx.lock) are overridden at
    # their call sites, so this shared text only ever reaches the package tier,
    # which has no lockfile — leaving the managed config and CONFIG_TAIL.
    78: ("configuration error — a required managed config has never been synced; run " +
         "'ocx config update' (no_config = True / OCX_NO_CONFIG=1 opts out of the tier)" +
         CONFIG_TAIL),
    79: ("not found — the reference, or a required patch companion composed onto it, does not " +
         "exist in the registry; check the name, or refresh the companions with 'ocx patch sync'"),
    80: "authentication required — the registry needs credentials for this reference; run 'ocx login <registry>'",
    81: ("blocked by policy — offline or frozen mode, a frozen index snapshot, or an ocx.toml " +
         "policy refused the resolution"),
    # 82 (dirty rc) has no entry: it is raised only by `ocx config setup` and
    # `ocx self setup` refusing to overwrite a hand-edited managed shell block,
    # and no repository rule ever runs either command — a hint here would be
    # dead code. 86 (0.6.1, a forge lacking a capability a write transport
    # needs) likewise: only announce/claim/cascade raise it, all publishing.
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
    still fails that check, which is why make_ocx_env passes "" instead of
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
            (the store lives inside the repo being fetched, which cannot
            be watched).

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

# The attr schema make_ocx_env() reads off ctx.attr.
# Declared once, next to the functions that consume it: a rule splatting this
# into its `attrs` is the contract, so the two cannot drift apart. Stardoc
# sorts attributes alphabetically, so splatting changes no rendered doc.
CONFIG_ATTRS = {
    "config": attr.label(
        allow_single_file = True,
        doc = "An ocx site config.toml (mirrors, registries, [patches]) layered over the " +
              "host's discovered config — not the project ocx.toml. Sets OCX_CONFIG for " +
              "every invocation, overriding an ambient one, and the file is watched. " +
              "Combine with no_config for a hermetic configuration.",
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
              "companions — without a frozen snapshot they resolve at fetch time.",
    ),
}

# The resolved-policy attr schema (C-004): splatted next to CONFIG_ATTRS by
# every repository rule that runs ocx, and by the ocx.policy() tag class in
# extensions.bzl so one wording serves both. Normally threaded from that single
# root-only tag via resolve_policy() + policy_kwargs(); set directly on the
# public rules it bypasses the root-only guard, which governs the tag alone.
POLICY_ATTRS = {
    "allow_unverified": attr.bool(
        default = False,
        doc = "When true, sets OCX_NO_VERIFY=1 for every invocation — ocx's own documented " +
              "equivalent of `--no-verify`, so no verify flag is ever put on an argv. " +
              "When false, OCX_NO_VERIFY=0 is written anyway, so an " +
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
              "`<OCX_HOME>/sigstore/trusted-root.json` rung, and the file is watched.",
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

    Splatted at every repository declaration that runs ocx, so a fourth
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

# A translucent `path` row names a file ocx opens *and* Bazel has to watch, and
# ctx.watch() takes absolute paths only. A relative ambient value would be
# forwarded and silently left unwatched, so it is refused rather than
# half-honoured — same reasoning as is_absolute_path() above. The message names
# the row's own attr: OCX_SIGSTORE_TRUSTED_ROOT's lives on ocx.policy(), not on
# the ocx.project()/ocx.package() tag the other two belong to.
RELATIVE_ENV_PATH_MSG = ("rules_ocx: {} must be an absolute path, got '{}' — a repository rule runs " +
                         "from Bazel's own working directory, so a relative value names a different " +
                         "file than it does in your shell and Bazel cannot watch it. Export an " +
                         "absolute path, or set the `{}` attr.")

def make_ocx_env(ctx, host):
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

    Returns:
        struct(env = dict for repository_ctx.execute, home = resolved OCX_HOME).
    """

    # The store always lives inside the repository being fetched: the client's
    # own OCX_HOME never reaches an ocx call, and a path under the working
    # directory is absolute by construction.
    home = str(ctx.path(".ocx_home"))

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
    # and ctx.watch() is what registers that file with Bazel — ctx.path()
    # alone watches nothing since Bazel 7.1. A surviving
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
            if row.path:
                ctx.watch(override)
                env[key] = str(ctx.path(override))
            else:
                env[key] = "1"
        elif row.path and env.get(key, ""):
            # A `file://` value on a `file_url` row still names a file: ocx
            # reads OCX_SIGSTORE_TRUSTED_ROOT through FileReference::parse,
            # which consumes a case-insensitive `file://` prefix at exactly
            # this door (ocx-sh/ocx#379). Strip the prefix to get the path
            # Bazel watches, and forward the value ocx was given verbatim.
            # Scoped to that row and that scheme because nothing else has the
            # grammar: the other two `path` rows are a plain PathBuf::from, and
            # every other scheme (`https://`, a bare `foo://`) is a literal
            # relative filename to ocx. The absoluteness test then covers both
            # spellings — a `file://x` whose remainder is relative is refused
            # like any other relative value, since ocx reads it as `x` from a
            # working directory that is not the caller's.
            watched = env[key]
            if row.file_url and watched.lower().startswith("file://"):
                watched = watched[len("file://"):]
            if not is_absolute_path(watched, host.is_windows):
                fail(RELATIVE_ENV_PATH_MSG.format(key, env[key], row.attr))
            ctx.watch(watched)

    # The weakening pair, written last and unconditionally: these two rows are
    # never read from the environment, so this is the only thing that decides
    # them — and their presence shadows whatever the CI image exported.
    env.update(policy_exports(ctx.attr.allow_unverified, ctx.attr.allow_yanked))

    if not ctx.attr.no_config and not truthy(ctx.getenv("OCX_NO_CONFIG")):
        for path in ambient_config_paths(
            host.is_windows,
            host.ocx_platform.startswith("darwin"),
            {key: ctx.getenv(key) or "" for key in _CONFIG_HOME_ENV},
            "",
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

    Watches the binary, so an `ocx.download(version = …)` change refetches
    every repo the old binary produced.

    Returns:
        path object of the executable to invoke.
    """
    ctx.watch(ctx.attr.ocx)
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

def make_isolated_ocx_env(rctx, home):
    """Environment for one ocx call run against a throwaway OCX_HOME (C-RO-16).

    `home` is a fresh directory inside the working directory that the caller
    deletes before returning. HOME and the process environment are inherited;
    no credential or secret variable is read through getenv.

    Args:
        rctx: repository_ctx.
        home: path of the fresh OCX_HOME.

    Returns:
        struct(env, home).
    """
    os_name = rctx.os.name.lower()

    # make_ocx_env keeps the client's own OCX_HOME out of
    # every read and watch; only the home path itself differs. getenv() is
    # reached for the OCX_ENV_CLASSES rows alone, none of them a credential.
    host = struct(
        is_windows = os_name.startswith("windows"),
        ocx_platform = "darwin/" if os_name.startswith("mac") else "",
    )
    env = dict(make_ocx_env(rctx, host).env)
    env["OCX_HOME"] = home
    return struct(env = env, home = home)
