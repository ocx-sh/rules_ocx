#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
set -euo pipefail

version="$("$OCX_BIN" version)"
echo "ocx version: $version"
case "$version" in
    [0-9]*.[0-9]*) ;;
    *)
        echo "unexpected 'ocx version' output" >&2
        exit 1
        ;;
esac
