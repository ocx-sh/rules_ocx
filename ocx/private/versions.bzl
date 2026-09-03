# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Pinned default ocx CLI version.

The ocx CLI declares no stability for its command-line surface across
versions; rules_ocx therefore pins an exact version and is tested against
exactly that version. Bump deliberately, together with dist/dist.json.
"""

load("@bazel_skylib//lib:versions.bzl", "versions")

visibility(["//ocx", "//ocx/tests"])

DEFAULT_OCX_VERSION = "0.6.0"

# Floor checked by _ocx_download_impl before any download (min_version_error).
MIN_OCX_VERSION = "0.6.0"

MIN_OCX_VERSION_MSG = (
    "rules_ocx: ocx.download(version = \"{version}\") " +
    "requires ocx {min} or newer" +
    " — rules_ocx drives `ocx exec` and pins `OCX_NO_VERIFY`, " +
    "neither of which exists on {version}. Fix: version = \"{min}\" or newer " +
    "(rules_ocx 0.3.0 is the last release supporting ocx 0.5.8)."
)

# A version that is not dotted numerals never reaches the floor comparison:
# skylib reads a non-numeric leader as a dev build (above every release) and
# crashes on an empty component, and the floor message would misdiagnose a
# spelling problem as an out-of-date pin.
MALFORMED_OCX_VERSION_MSG = (
    "rules_ocx: ocx.download(version = \"{version}\") is not a dotted-numeric " +
    "version like \"{min}\" — no `v` prefix, no pre-release suffix."
)

def min_version_error(version):
    """Checks a requested ocx version against MIN_OCX_VERSION.

    Args:
        version: exact ocx version requested via ocx.download(version = …).

    Returns:
        "" when version satisfies the floor, else MALFORMED_OCX_VERSION_MSG
        (not dotted numerals) or MIN_OCX_VERSION_MSG, formatted with the
        requested version.
    """
    if not all([part.isdigit() for part in version.split(".")]):
        return MALFORMED_OCX_VERSION_MSG.format(version = version, min = MIN_OCX_VERSION)
    if versions.is_at_least(MIN_OCX_VERSION, version):
        return ""
    return MIN_OCX_VERSION_MSG.format(version = version, min = MIN_OCX_VERSION)
