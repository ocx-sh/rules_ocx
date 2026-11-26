# Rig results

Measured on the rig in this directory (`compose.yaml`): nginx 1.29.8 in front of zot, Buildbarn
(`bb-*` 2026-11-02 images) and NativeLink 1.9.0. Executors have no network route. Bazel 9.2.0 with
`--ignore_all_rc_files`. Host: Linux 6.8, docker 29.10.0, compose 5.8.0.

## Remote execution works on both backends

One genrule built with `--spawn_strategy=remote --remote_local_fallback=false`, the executor printing
its hostname and `getent hosts zot`:

| Backend | Green | Red control |
|---|---|---|
| Buildbarn, `hardlinking/<silo>` | `1 remote`; output names the runner container and `no-zot` | `container-image=docker://nonexistent`: exit 34, `No workers exist for instance name prefix "hardlinking/smoke-red"` |
| Buildbarn no-shell runner (distroless) | registered: an action reaches it | genrule: exit 34, `fork/exec /bin/bash: no such file or directory` |
| NativeLink, `main` | `1 remote`; output names the worker container and `no-zot` | `--remote_instance_name=main/a`: exit 34, `Remote execution is not supported by the remote server` |

NativeLink's scheduler first declared `OSFamily` as `priority`, which matches any value: an action asking
for `OSFamily=windows` ran on the Linux worker. The rig now declares it `exact`. With `exact`, an action no
worker matches is queued, not refused, and Bazel waits without a bound. A wrong platform on NativeLink
shows up as a hang, never as an error. That is why the NativeLink red control uses an instance name the
server does not serve.

## Rig question 1: a per-test instance-name suffix on NativeLink

**No.** NativeLink serves only the instance names its config lists. `main/a` is refused at
`GetCapabilities` (exit 34, above). Buildbarn admits any `hardlinking/<suffix>`, since its worker's
`instanceNamePrefix` is a prefix .

**Fallback applied**: on NativeLink the silo is `--action_env=OCX_RIG_SILO=<test-id>`,
which changes every action key. Three fresh output bases against `main`:

| Leg | Salt | Result |
|---|---|---|
| a1 | `a` | `1 remote` (miss) |
| a2 | `a` | `1 remote cache hit` |
| b1 | `b` | `1 remote` (miss) |

The salt does not reach repository rules, so a leg that needs a cold repo contents cache runs with
`--experimental_remote_repo_contents_cache` off. `tests/conftest.py` `silo_flags()` applies both silos.

## Rig question 2: empty directories and nested BUILD files under a directory label

A scratch workspace (not committed) with `srcs = ["d"]`, where `d/` holds `f.txt`, `empty/`,
`deep/inner/x.txt` and `sub/BUILD`, the action running `find`.

| Case | Local | Buildbarn | NativeLink |
|---|---|---|---|
| nested `sub/BUILD` | error: `Directory artifact d crosses package boundary into package rooted at d/sub` | same error | same error |
| empty directory `empty/` (no BUILD below `d`) | kept | **dropped** | **dropped** |

**Neither is kept** on a remote executor. **Fallback applied**: no change to the rules.
The set repository already gives directories that hold a reserved name file labels and moves those files.
The docs state that empty directories are not visible to actions.

## Measures

Measured 2026-11-26 with `task rig:up rig:seed rig:test`, one rig per backend
(the no-shell runner is a Buildbarn worker, so one test is skipped on NativeLink). `<run-dir>/measures.json`:

| measure | buildbarn | nativelink |
|---|---|---|
| 5 actions over a one-file set, remote (s) | 0.8 | 1.0 |
| 5 actions over the 100006-file set, remote, files uploaded (s) | 58.0 | 104.5 |
| fetch of the 100006-file set (s) | 27.6 | 27.6 |
| of that, `ocx vendor` (s) | 22.2 | 22.3 |
| rule work, fetch minus `ocx vendor` (s), budget 10 | 5.4 | 5.3 |
| the same subtraction for a one-file set (s) | 0.1 | 0.1 |

The rule's `json.decode`, BUILD generation and moves cost 5.4 s and 5.3 s, inside the budget. The measure fetches a
small set first and times the big fetch alone, so it excludes a client's first fetch (Bazel's module graph, registry
files and the extension's fact runs); the bound still includes Bazel's own per-fetch work, which the one-file row puts
at 0.1 s. The 100000-file batch takes 58.0 s and 104.5 s against 0.8 s and 1.0 s for the one-file set; each test
starts on an empty instance name, so the batch includes the upload of every file.
