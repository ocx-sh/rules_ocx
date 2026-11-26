#!/usr/bin/env bash
set -euo pipefail

# The launcher, started by an action of the same build, finds its files and
# prints its version. On Windows Bazel builds the runfiles tree it looks in
# only with `--enable_runfiles`, which this example's .bazelrc sets.
cat "$WITH_RUNFILES"
grep -q "^jq-" "$WITH_RUNFILES"
grep -q "^exit=0$" "$WITH_RUNFILES"
echo "launcher with a runfiles tree OK"
