# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Host platform detection and ocx platform-key mappings.

Pure functions on (os name, arch) strings so they are unit-testable; the
repository rules pass `repository_ctx.os.name` / `.arch` in.
"""

# ocx platform key ("os/arch", as used in ocx.lock and `-p`) -> Bazel constraints.
OCX_PLATFORMS = {
    "darwin/amd64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "darwin/arm64": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "linux/amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux/arm64": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "windows/amd64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
    "windows/arm64": ["@platforms//os:windows", "@platforms//cpu:aarch64"],
}

_CPUS = {
    "aarch64": "aarch64",
    "amd64": "x86_64",
    "arm64": "aarch64",
    "x86_64": "x86_64",
}

def repo_suffix(ocx_platform):
    """Converts an ocx platform key to a repository-name suffix.

    Args:
        ocx_platform: an ocx "os/arch" key, e.g. "linux/amd64".

    Returns:
        A string safe for use in repository names, e.g. "linux_amd64".
    """
    return ocx_platform.replace("/", "_")

def host_info(os_name, arch):
    """Maps a host OS name and arch to ocx release and platform identifiers.

    Linux maps to the musl triple: the ocx musl builds are static, run on any
    libc, and are the same binaries ocx's own OCI publishing uses — so no
    libc detection is needed.

    Args:
        os_name: `repository_ctx.os.name`, e.g. "linux", "mac os x", "windows 10".
        arch: `repository_ctx.os.arch`, e.g. "amd64", "aarch64".

    Returns:
        struct with fields:
          triple: cargo-dist target triple of the ocx release artifact.
          ocx_platform: ocx "os/arch" key for `-p` / ocx.lock.
          is_windows: bool.
          exe_ext: "" or ".exe".
    """
    os_name = os_name.lower()
    cpu = _CPUS.get(arch.lower())
    if not cpu:
        fail("rules_ocx: unsupported host architecture '{}'".format(arch))
    ocx_arch = "amd64" if cpu == "x86_64" else "arm64"
    if os_name.startswith("linux"):
        return struct(
            triple = cpu + "-unknown-linux-musl",
            ocx_platform = "linux/" + ocx_arch,
            is_windows = False,
            exe_ext = "",
        )
    if os_name.startswith("mac") or "os x" in os_name:
        return struct(
            triple = cpu + "-apple-darwin",
            ocx_platform = "darwin/" + ocx_arch,
            is_windows = False,
            exe_ext = "",
        )
    if os_name.startswith("windows"):
        return struct(
            triple = cpu + "-pc-windows-msvc",
            ocx_platform = "windows/" + ocx_arch,
            is_windows = True,
            exe_ext = ".exe",
        )
    fail("rules_ocx: unsupported host OS '{}'".format(os_name))
