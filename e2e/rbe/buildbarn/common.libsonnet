// Derived from buildbarn/bb-deployments docker-compose/config (Apache-2.0).
// Copyright The Buildbarn Authors. Modified for the rules_ocx rig: two storage shards, no portal, no FUSE worker.
{
  portalUrl: 'http://localhost/unused',
  maximumMessageSizeBytes: 2 * 1024 * 1024,
  global: {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [':80'],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: true,
      enableActiveSpans: true,
    },
  },
}
