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
`instanceNamePrefix` is a prefix (S-B spike).

**Fallback applied** (plan R1 step 2): on NativeLink the silo is `--action_env=OCX_RIG_SILO=<test-id>`,
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

**Neither is kept** on a remote executor. **Fallback applied** (plan R1 step 3): no change to the rules.
C-RO-04 already gives directories that hold a reserved name file labels, and C-RO-05 moves the files.
The docs sentence "empty directories are not visible to actions" stays in R9's list.

## Baseline: rules_ocx 0.5.1

`task rig:baseline` (`baseline/run_baseline.py`). 0.5.1 from its release archive. Eager tags with
`isolated_home`, one per platform. A lazy `bins` tag for the network-less leg. Registry numbers are the
nginx `/v2/` lines of each leg. Each client has its own output base, repository cache and `OCX_HOME`.

<!-- baseline:begin -->
| measure | buildbarn | nativelink |
|---|---|---|
| ocx bootstrap download, @ocx_tool (s) | 8.1 | 6.7 |
| cold client fetch, all six platforms (s) | 1.3 | 1.3 |
| registry requests / bytes, linux/amd64+libc.glibc | 6 / 330471 | 6 / 330471 |
| registry requests / bytes, linux/amd64+libc.musl | 6 / 330463 | 6 / 330463 |
| registry requests / bytes, linux/arm64+libc.glibc | 6 / 330473 | 6 / 330473 |
| registry requests / bytes, linux/arm64+libc.musl | 6 / 330463 | 6 / 330463 |
| registry requests / bytes, darwin/arm64 | 6 / 5555 | 6 / 5555 |
| registry requests / bytes, windows/amd64 | 6 / 5563 | 6 / 5563 |
| second fresh client: registry requests / bytes | 6 / 330471 | 6 / 330471 |
| second fresh client: processes | {'total': 2, 'remote': 0, 'remote_cache_hit': 1} | {'total': 2, 'remote': 0, 'remote_cache_hit': 1} |
| builds on network-less executors | FAIL: warning: Could not fetch '127.0.0.1:18600/rig/tool:1.0.0@sha256:79a98505a6de92d42ee989a2ad42b03b708db6d325806355f0127d75467b3196' from chained source: transient registry failure: error sending request for url (http://127.0.0.1:18600/v2/) | FAIL: warning: Could not fetch '127.0.0.1:18600/rig/tool:1.0.0@sha256:79a98505a6de92d42ee989a2ad42b03b708db6d325806355f0127d75467b3196' from chained source: transient registry failure: error sending request for url (http://127.0.0.1:18600/v2/) |
<!-- baseline:end -->

The lazy launcher builds locally (client with a route) on both backends. On the executors it fails as
shown: 0.5.1 ships `ocx` as an action input and the launcher re-enters it, and the registry is out of
reach. That run is V-01's red. Every second fresh client pulled the set again: 6 requests, the same
bytes. The repository rule ran once per client.

## New rules (R8)

V-31 and V-65 numbers go here from `<run-dir>/measures.json`, beside the baseline above.
