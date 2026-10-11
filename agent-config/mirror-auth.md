# Mirror downloads assume anonymous read

`ocx/private/download.bzl` honours `OCX_INSTALL_DIST_URL` /
`OCX_INSTALL_MIRROR_URL` so a corporate operator can point at an internal
mirror. Today that mirror **must allow anonymous read** — `ctx.download` and
`ctx.download_and_extract` are called with no credentials.

- Document the constraint; a mirror locked down later breaks this path
  silently, and the failure looks like a network error.
- Future support (not now): `ctx.download(auth = …)` plus `read_netrc` /
  `use_netrc` from `@bazel_tools//tools/build_defs/repo:utils.bzl`. Standard
  Bazel idiom, no new machinery.
- Same gap exists in `find_ocx` (`file(DOWNLOAD)`) and in the five installers
  in `www-setup`. Keep the knob naming aligned across all three if it lands.
- The manifest sha256 stays the security boundary either way — auth controls
  access, never trust.
- Corroborated 2026-09-02 against www-setup: the five official installers
  send no credentials on the install path either; `OCX_INSTALL_CA_BUNDLE`
  (curl `--cacert`) has no `ctx.download` equivalent and is a documented gap.
