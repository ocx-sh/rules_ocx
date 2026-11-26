#!/usr/bin/env bash
set -euo pipefail

# Windows builds a runfiles tree only with `--enable_runfiles`. An action of a
# configuration without it starts the launcher with no tree and no symlink to
# follow: the launcher refuses with exit 78 and says it found no root.
cat "$WITHOUT_RUNFILES"
grep -q "^exit=78$" "$WITHOUT_RUNFILES"
grep -q "no vendored root found" "$WITHOUT_RUNFILES"
echo "launcher without a runfiles tree exits 78 OK"
