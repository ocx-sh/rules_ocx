# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Public API of rules_ocx.

Most consumers only need the `ocx` module extension
(`@rules_ocx//ocx:extensions.bzl`). The repository and build rules are
re-exported here for power users composing their own extensions on top of the
same vendored provisioning, and for the `tool.bzl` each hub generates.
"""

load("//ocx/private:download.bzl", _ocx_download = "ocx_download")
load("//ocx/private:hub.bzl", _ocx_hub_repo = "ocx_hub_repo")
load("//ocx/private:set_repo.bzl", _ocx_set_repo = "ocx_set_repo")
load("//ocx/private:set_rules.bzl", _OcxSetInfo = "OcxSetInfo", _make_ocx_tool_rule = "make_ocx_tool_rule", _ocx_set = "ocx_set", _ocx_set_toolchain = "ocx_set_toolchain")

ocx_download = _ocx_download
ocx_set_repo = _ocx_set_repo
ocx_hub_repo = _ocx_hub_repo
ocx_set = _ocx_set
ocx_set_toolchain = _ocx_set_toolchain
OcxSetInfo = _OcxSetInfo

# A rule's `toolchains = ["//:toolchain_type"]` resolves against the repository
# that defines the rule, so one `ocx_tool` in rules_ocx cannot serve many hubs.
# Each hub's generated `tool.bzl` calls this with its own `Label("//:toolchain_type")`.
make_ocx_tool_rule = _make_ocx_tool_rule
