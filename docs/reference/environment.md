<!-- doc_type: reference -->
# Environment variables

The environment variables that reach the rules_ocx repository rules, and the ones that do not.

## Local ocx binary

| Variable | Effect |
| --- | --- |
| `OCX_INSTALL_BINARY` | Absolute path of an `ocx` binary to use instead of the release. Needs `OCX_INSTALL_BINARY_SHA256`. |
| `OCX_INSTALL_BINARY_SHA256` | Digest of that file, 64 lowercase hex characters. A wrong digest fails the fetch, and a later edit of the file changes nothing. |

Pass both with `--repo_env` and add `--lockfile_mode=off`, because the pair is not part of the lock file.

## Mirror and transport

| Variable | Effect |
| --- | --- |
| `OCX_INSTALL_DIST_URL` | Fetch the release manifest from a mirror. A manifest named `<sha256>.json` is verified, any other name is fetched unverified. |
| `OCX_INSTALL_MIRROR_URL` | Rewrite the `ocx` binary download to `<mirror>/<tag>/<filename>`. The sha256 is enforced either way. |
| `OCX_MIRRORS` | JSON map from registry host to mirror URL. Lock file digests stay keyed to the upstream host. |
| `OCX_INSECURE_REGISTRIES` | Comma list of registries allowed over plain HTTP. |
| `OCX_AUTH_<REGISTRY>_{TYPE,USER,TOKEN}` | Registry credentials. Run `bazel fetch --force` after a change. |
| `OCX_EXTRA_CA_CERTS` | Extra TLS roots, for example a corporate proxy CA. |

## Forwarded unchanged

`OCX_INDEX`, `OCX_OFFLINE`, `OCX_FROZEN`, `OCX_REMOTE`, `OCX_JOBS`, `OCX_DEFAULT_REGISTRY`, `OCX_CONFIG`, `OCX_NO_CONFIG`, `OCX_MANAGED_CONFIG`, `OCX_PATCHES`, `OCX_PATCH_SNAPSHOT` and `OCX_SIGSTORE_TRUSTED_ROOT`.
Together with the mirror and transport variables above, this is the whole forwarded set.

`OCX_CONFIG`, `OCX_PATCH_SNAPSHOT` and `OCX_SIGSTORE_TRUSTED_ROOT` must be absolute paths.
A relative value is refused, because a repository rule runs from Bazel's own working directory and cannot watch it.
`file://` is accepted only on `OCX_SIGSTORE_TRUSTED_ROOT`, and the path behind the prefix must be absolute.

`OCX_HOME` is never forwarded. Every `ocx` run gets a fresh scratch `OCX_HOME` inside its own directory, deleted before the run returns.

## Never read from the environment

| Variable | Why |
| --- | --- |
| `OCX_NO_VERIFY`, `OCX_ALLOW_YANKED` | Written on every call. Use [`ocx.policy`](../concepts/trust-and-config.md) to change them. |
| `OCX_PROJECT`, `OCX_GLOBAL` | Project context comes from the explicit `--project` flag. |
| `OCX_QUIET` | `--quiet` would suppress the JSON reports the rules parse. |
| `OCX_NO_PROJECT` | Fixed, so a fetch cannot walk directories from Bazel's working directory. |
| `OCX_NO_CONFIG_REFRESH` | Fixed on, because the managed-config refresh needs a TTY. |
| `OCX_NO_CONSENT` | Fixed on, so no shell-activation consent stamp is written. |
| `OCX_TOOLCHAIN_DIR` | Fixed empty, which is ocx's "absent", so an exported toolchain root cannot move anything. |
