// Derived from buildbarn/bb-deployments docker-compose/config (Apache-2.0).
// Copyright The Buildbarn Authors. Modified for the rules_ocx rig: two storage shards, no portal, no FUSE worker.
local common = import 'common.libsonnet';

{
  buildDirectoryPath: '/worker/build',
  global: common.global,
  grpcServers: [{
    listenPaths: ['/worker/runner'],
    authenticationPolicy: { allow: {} },
  }],
}
