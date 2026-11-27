#!/usr/bin/env bash
# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
# Creates the run tree the compose bind mounts expect (containers run as users that cannot create it).
# Usage: prepare_run_dir.sh <run-dir>
set -euo pipefail

run="${1:?usage: prepare_run_dir.sh <run-dir>}"
mkdir -p "$run"
run="$(cd "$run" && pwd)"

for d in logs state zot bb nativelink nativelink-worker \
  worker-ubuntu/build worker-ubuntu/cache worker-ubuntu/cs/persistent_state \
  worker-noshell/build worker-noshell/cache worker-noshell/cs/persistent_state; do
  mkdir -p "$run/$d"
done
for s in 0 1; do
  for k in ac cs cms fsac; do
    mkdir -p "$run/storage-$s/$k/persistent_state"
  done
done
# The unprivileged images write here; the worker cache dirs stay 0700 like upstream's run.sh.
# Only directories this user owns: on a second `rig:up` the containers own what they wrote, need no change, and
# some are unreadable to this user (find says so and exits 1).
find "$run" -type d -user "$(id -u)" ! -name cache -exec chmod 0777 {} + 2>/dev/null || true
chmod 0700 "$run/worker-ubuntu/cache" "$run/worker-noshell/cache"
