# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Public API of rules_ocx.

Most consumers only need the `ocx` module extension
(`@rules_ocx//ocx:extensions.bzl`). The repository rules are re-exported
here for power users composing their own extensions on top of the same
CLI-backed provisioning.
"""

load("//ocx/private:download.bzl", _ocx_download = "ocx_download")
load("//ocx/private:package.bzl", _ocx_package_hub = "ocx_package_hub", _ocx_package_repo = "ocx_package_repo")
load("//ocx/private:platforms.bzl", _OCX_PLATFORMS = "OCX_PLATFORMS")
load("//ocx/private:project.bzl", _ocx_project_repo = "ocx_project_repo")

ocx_download = _ocx_download
ocx_project_repo = _ocx_project_repo
ocx_package_repo = _ocx_package_repo
ocx_package_hub = _ocx_package_hub

# ocx platform key ("os/arch") -> Bazel constraint labels.
OCX_PLATFORMS = _OCX_PLATFORMS
