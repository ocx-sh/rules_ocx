# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Pinned default ocx CLI version.

The ocx CLI declares no stability for its command-line surface across
versions; rules_ocx therefore pins an exact version and is tested against
exactly that version. Bump deliberately, together with dist/dist.json.
"""

DEFAULT_OCX_VERSION = "0.3.11"
