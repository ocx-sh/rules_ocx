# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Pinned default ocx CLI version.

The ocx CLI declares no stability for its command-line surface across
versions; rules_ocx therefore pins an exact version and is tested against
exactly that version. Bump deliberately, together with dist/dist.json.
`MIN_OCX_VERSION` is the floor below which `ocx vendor` does not exist.
"""

load("@bazel_skylib//lib:versions.bzl", "versions")

visibility(["//ocx", "//ocx/tests"])

DEFAULT_OCX_VERSION = "0.6.6"

# The floor: the lowest ocx version that can carry `ocx vendor`, the command whose
# manifest (schema version 1) this ruleset reads. The one constant every message and
# docstring derives from. Checked by min_version_error() before any download and
# on a locally supplied binary.
MIN_OCX_VERSION = "0.6.8"

MIN_OCX_VERSION_MSG = (
    "rules_ocx: ocx.download(version = \"{version}\") " +
    "requires ocx {min} or newer" +
    " — rules_ocx reads the manifest that `ocx vendor` writes (schema version 1), " +
    "and {version} has no such command. Fix: version = \"{min}\" or newer."
)

# Appended when the failing version is the shipped default: until an ocx release
# carries `ocx vendor`, dist/dist.json lists no row and the default is below the floor.
NO_SUPPORTED_RELEASE_NOTE = (
    "\nNo ocx release at or above the floor is listed in dist/dist.json yet. " +
    "Until one is published, set OCX_INSTALL_BINARY and OCX_INSTALL_BINARY_SHA256 to a build that has `ocx vendor`."
)

LOCAL_BINARY_UNREADABLE_MSG = (
    "rules_ocx: OCX_INSTALL_BINARY did not report a version (`ocx version` exited {code}, " +
    "printed {out}); rules_ocx reads the manifest that `ocx vendor` writes (schema version 1), " +
    "which needs ocx {min} or newer."
)

LOCAL_BINARY_BELOW_FLOOR_MSG = (
    "rules_ocx: OCX_INSTALL_BINARY is ocx {version}, which has no `ocx vendor`; " +
    "rules_ocx reads the manifest that command writes (schema version 1) and needs ocx {min} or newer."
)

# A version that is not dotted numerals never reaches the floor comparison:
# skylib reads a non-numeric leader as a dev build (above every release) and
# crashes on an empty component, and the floor message would misdiagnose a
# spelling problem as an out-of-date pin.
MALFORMED_OCX_VERSION_MSG = (
    "rules_ocx: ocx.download(version = \"{version}\") is not a dotted-numeric " +
    "version like \"{min}\" — no `v` prefix."
)

def _core(version):
    """The numeric core of a version: `0.6.8` of `0.6.8-pr784+2026`, "" when malformed."""
    core = version.split("+")[0].split("-")[0]
    if not core or not all([part.isdigit() for part in core.split(".")]):
        return ""
    return core

def min_version_error(version, floor = MIN_OCX_VERSION):
    """Checks a version against MIN_OCX_VERSION on its numeric core.

    A pre-release or build suffix (`0.6.8-pr784+2026`) is ignored, so a
    pre-release of the floor version passes.

    Args:
        version: ocx version, from ocx.download(version = …) or from `ocx version`.
        floor: the lowest accepted version; tests pass their own.

    Returns:
        "" when version satisfies the floor, else MALFORMED_OCX_VERSION_MSG
        (not dotted numerals) or MIN_OCX_VERSION_MSG, formatted with the
        requested version.
    """
    core = _core(version)
    if not core:
        return MALFORMED_OCX_VERSION_MSG.format(version = version, min = floor)
    if versions.is_at_least(floor, core):
        return ""
    return MIN_OCX_VERSION_MSG.format(version = version, min = floor)

def local_binary_version_error(return_code, stdout):
    """Checks what a locally supplied binary printed for `ocx version`.

    The version is the first word that starts with dotted numerals: the bare
    `0.6.8-pr784+2026` of ocx itself, or `9.9.9-fake` after a leading name.

    Args:
        return_code: exit code of `ocx version`.
        stdout: its standard output.

    Returns:
        "" when the binary satisfies the floor, else the message to fail with.
    """
    version = ""
    for word in stdout.replace("\t", " ").replace("\r", " ").replace("\n", " ").split(" "):
        if word and _core(word):
            version = word
            break
    if return_code != 0 or not version:
        return LOCAL_BINARY_UNREADABLE_MSG.format(code = return_code, out = repr(stdout.strip()[:80]), min = MIN_OCX_VERSION)
    if versions.is_at_least(MIN_OCX_VERSION, _core(version)):
        return ""
    return LOCAL_BINARY_BELOW_FLOOR_MSG.format(version = version, min = MIN_OCX_VERSION)
