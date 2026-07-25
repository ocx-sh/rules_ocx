# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.3] - 2026-07-25

### Added

- Add platform_aliases to ocx.package *(package)*

## [0.1.2] - 2026-07-07

### Fixed

- Derive archive type from manifest filename *(download)*

## [0.1.1] - 2026-07-03

### Fixed

- Darwin/amd64 pin + Bazel 9 & Rosetta-Intel CI coverage (#3) *(bcr)*

## [0.1.0] - 2026-07-02

### Added

- Ocx module extension with bootstrap, project and package tiers
- Per-platform manifest pins via ocx.package(pins = ...) *(package)*
- Freeze tag resolution to a committed index snapshot *(package)*
- Lazy provisioning via bins — no pull until first execution
- Bump ocx to 0.3.11 — group-scoped env composition
- Cross-platform project tier via env/pull --platform

### Documentation

- Stardoc API reference with freshness diff_tests

### Fixed

- Neutralize leaked OCX_PROJECT and retry racy package installs
- Unbreak Windows — LF scripts, runfiles tree, no stardoc under MSVC *(ci)*
[0.1.3]: https://github.com/ocx-sh/ocx/compare/v0.1.2..v0.1.3
[0.1.2]: https://github.com/ocx-sh/ocx/compare/v0.1.1..v0.1.2
[0.1.1]: https://github.com/ocx-sh/ocx/compare/v0.1.0..v0.1.1
[0.1.0]: https://github.com/ocx-sh/ocx/tree/v0.1.0

