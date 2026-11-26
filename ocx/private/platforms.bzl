# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Host platform detection and ocx platform-key mappings.

Pure functions on (os name, arch) strings so they are unit-testable; the
repository rules pass `repository_ctx.os.name` / `.arch` in.
"""

visibility(["//ocx", "//ocx/tests"])

# ocx os/arch -> constraint label.
_OS_C = {
    "darwin": "@platforms//os:macos",
    "linux": "@platforms//os:linux",
    "wasip1": "@platforms//os:wasi",
    "windows": "@platforms//os:windows",
}
_CPU_C = {
    "amd64": "@platforms//cpu:x86_64",
    "arm64": "@platforms//cpu:aarch64",
    "wasm": "@platforms//cpu:wasm32",
}
_MUSL = "@rules_ocx//ocx/constraints:musl"
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

def platform_constraints(platform):
    """Bazel constraint labels of an ocx platform string.

    OS `linux`, `darwin`, `windows`, `wasip1` map to `@platforms//os:{linux,
    macos,windows,wasi}` and arch `amd64`, `arm64`, `wasm` to
    `@platforms//cpu:{x86_64,aarch64,wasm32}`. The feature `libc.musl` adds
    `@rules_ocx//ocx/constraints:musl`; `libc.glibc`, no libc feature, any
    other feature and any variant add nothing (open vocabulary: an unknown
    feature must not break a lock that a newer ocx wrote).

    Args:
        platform: an ocx platform key ('os/arch[/variant][+feature,...]').

    Returns:
        struct(constraints, error): `constraints` is [os, cpu] plus the musl
        label when the platform names it; `error` is "" on success, else
        names the platform and `constraints` is [].
    """
    parts = os_arch(platform).split("/")
    os_c = _OS_C.get(parts[0]) if len(parts) == 2 else None
    cpu_c = _CPU_C.get(parts[1]) if len(parts) == 2 else None
    if not os_c or not cpu_c:
        return struct(constraints = [], error = ("rules_ocx: cannot map platform '{}' to Bazel constraints " +
                                                 "(known os {}, arch {})").format(platform, _OS_C.keys(), _CPU_C.keys()))
    constraints = [os_c, cpu_c]
    features = platform.split("+", 1)[1].split(",") if "+" in platform else []
    if "libc.musl" in features:
        constraints.append(_MUSL)
    return struct(constraints = constraints, error = "")

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
          triples: cargo-dist target triples of the ocx release artifact, most
            preferred first (Windows: gnullvm where a release ships one, then msvc).
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
            triples = [cpu + "-unknown-linux-musl"],
            ocx_platform = "linux/" + ocx_arch,
            is_windows = False,
            exe_ext = "",
        )
    if os_name.startswith("mac") or "os x" in os_name:
        return struct(
            triples = [cpu + "-apple-darwin"],
            ocx_platform = "darwin/" + ocx_arch,
            is_windows = False,
            exe_ext = "",
        )
    if os_name.startswith("windows"):
        return struct(
            triples = [cpu + "-pc-windows-gnullvm", cpu + "-pc-windows-msvc"],
            ocx_platform = "windows/" + ocx_arch,
            is_windows = True,
            exe_ext = ".exe",
        )
    fail("rules_ocx: unsupported host OS '{}'".format(os_name))
