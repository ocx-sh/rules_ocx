# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Host platform detection and ocx platform-key mappings.

Pure functions on (os name, arch) strings so they are unit-testable; the
repository rules pass `repository_ctx.os.name` / `.arch` in.
"""

# os/arch prefix of an ocx platform key -> Bazel constraint labels.
_OS = {
    "linux": "@platforms//os:linux",
    "darwin": "@platforms//os:osx",
    "windows": "@platforms//os:windows",
}
_CPU = {
    "amd64": "@platforms//cpu:x86_64",
    "arm64": "@platforms//cpu:aarch64",
}
_SLUG_OK = "abcdefghijklmnopqrstuvwxyz0123456789"

_CPUS = {
    "aarch64": "aarch64",
    "amd64": "x86_64",
    "arm64": "aarch64",
    "x86_64": "x86_64",
}

def slug(platform):
    """Bazel-name-safe slug of an ocx platform key.

    Lowercases, maps every non-[a-z0-9] run to a single '_', strips leading/
    trailing '_'. 'linux/arm64+libc.musl' -> 'linux_arm64_libc_musl'.
    """
    keep = "".join([c if c in _SLUG_OK else "_" for c in platform.lower().elems()])
    return "_".join([p for p in keep.split("_") if p])

def os_arch(platform):
    """The 'os/arch' prefix of a platform key (drops '/variant' and '+features')."""
    return "/".join(platform.split("+")[0].split("/")[:2])

def ocx_platform_constraints(platform):
    """Bazel constraint labels for the os/arch prefix of an ocx platform key.

    'linux/arm64+libc.musl' -> ['@platforms//os:linux', '@platforms//cpu:aarch64'].
    For toolchain authors composing exec_compatible_with; also the hub's source
    of config_setting constraint_values. Fails on an unmappable os/arch.

    Args:
        platform: an ocx platform key ('os/arch[/variant][+feature,...]').

    Returns:
        [os_constraint_label, cpu_constraint_label].
    """
    parts = os_arch(platform).split("/")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        fail("rules_ocx: platform '{}' is not 'os/arch[...]' — cannot derive constraints".format(platform))
    os_c = _OS.get(parts[0])
    cpu_c = _CPU.get(parts[1])
    if not os_c or not cpu_c:
        fail(("rules_ocx: cannot map platform '{}' to Bazel constraints " +
              "(unknown os '{}' or arch '{}'; known os {}, arch {})").format(
            platform,
            parts[0],
            parts[1],
            _OS.keys(),
            _CPU.keys(),
        ))
    return [os_c, cpu_c]

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
