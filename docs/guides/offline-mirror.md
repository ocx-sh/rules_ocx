<!-- doc_type: how-to -->
<!-- doc_tier: integration -->
# Build behind a corporate mirror

This guide points rules_ocx at an internal mirror, so a network without direct access to `ocx.sh` can still build.
It assumes you set Bazel flags for your CI, for example in a `.bazelrc`.

## Mirror the three sources

rules_ocx talks to three places: the release manifest, the `ocx` binary download and the package registry.
Each has one variable.

| Env var | Effect |
| --- | --- |
| `OCX_INSTALL_DIST_URL` | Fetch the release manifest from your mirror instead of the vendored snapshot. |
| `OCX_INSTALL_MIRROR_URL` | Rewrite the `ocx` download to `<mirror>/<tag>/<filename>`. |
| `OCX_MIRRORS` | JSON map such as `{"ocx.sh": "https://mirror.corp/ocx"}`. Package pulls go to the mirror. |

A mirror can move bytes but not change them.
rules_ocx enforces the artifact sha256 either way.
The `ocx.lock` digests stay keyed to the upstream host, so lock files stay portable.

## Pass the variables to Bazel

Export the variables in the CI environment, or forward them with `--repo_env`.

```console
$ export OCX_MIRRORS='{"ocx.sh": "https://mirror.corp/ocx"}'
$ bazel fetch //...
```

## Handle plain HTTP, proxies and credentials

- `OCX_INSECURE_REGISTRIES` allows plain-HTTP mirrors. It takes a comma list.
- `OCX_EXTRA_CA_CERTS` adds TLS roots, for example a corporate proxy CA.
- `OCX_AUTH_<REGISTRY>_{TYPE,USER,TOKEN}` sets registry credentials. Bazel cannot enumerate these, so run `bazel fetch --force` after changing auth.

## Fetch without a network

Give a tag `blob_dirs`, a list of directories of pre-fetched blobs.
Each one is passed to `ocx` as `--blob-dir`, so the vendor runs offline.

```starlark
ocx.project(
    name = "tools",
    blob_dirs = ["//third_party:ocx_blobs"],
    ocx_lock = "//:ocx.lock",
    ocx_toml = "//:ocx.toml",
    platforms = ["linux/amd64"],
)
```

## Use a local ocx binary

To run an `ocx` that is not a release, set `OCX_INSTALL_BINARY` to its absolute path and `OCX_INSTALL_BINARY_SHA256` to its digest.
Both are required together.
Bazel copies the file through its downloader, so a wrong digest fails the fetch and a later edit of the file changes nothing.
Pass both with `--repo_env`, and add `--lockfile_mode=off`, because the pair is not part of the lock file.

## Keep the mirror readable without credentials

The mirror for the `ocx` binary and the manifest must allow anonymous read.
rules_ocx downloads them without credentials, and the sha256 stays the security boundary.
If you lock the mirror down later, the failure looks like a network error.

## Check the result

Run `bazel fetch //...` on a machine that cannot reach `ocx.sh`.
The fetch completes, and requests appear in the mirror's access log.

The full list of forwarded variables is in the [environment reference](../reference/environment.md).
