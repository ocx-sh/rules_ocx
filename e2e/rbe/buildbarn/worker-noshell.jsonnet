// Copyright 2026 The OCX Authors
// SPDX-License-Identifier: Apache-2.0
local worker = import 'worker.libsonnet';
worker('docker://gcr.io/distroless/static@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5#noshell', '2')
