// Derived from buildbarn/bb-deployments docker-compose/config/worker-hardlinking-ubuntu22-04.jsonnet (Apache-2.0).
// Copyright The Buildbarn Authors. Modified for the rules_ocx rig: the runner platform is a parameter, so the
// ubuntu worker and the no-shell worker differ only in `containerImage` and `slot`.
local common = import 'common.libsonnet';
local topology = import 'topology.libsonnet';

function(containerImage, slot) {
  blobstore: {
    actionCache: topology.actionCache,
    contentAddressableStorage: {
      chunkStorage: topology.chunkStorage,
      chunkMappingStorage: topology.chunkMappingStorage,
      cdcParameterCache: topology.cdcParameterCache,
    },
  },
  portalUrl: common.portalUrl,
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  scheduler: { address: 'scheduler:8983' },
  global: common.global,
  buildDirectories: [{
    native: {
      buildDirectoryPath: '/worker/build',
      cacheDirectoryPath: '/worker/cache',
      maximumCacheFileCount: 10000,
      maximumCacheSizeBytes: 1024 * 1024 * 1024,
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
    },
    runners: [{
      endpoint: { address: 'unix:///worker/runner' },
      concurrency: 8,
      // The instance name prefix is the per-test cache silo: `hardlinking/<test-id>`.
      instanceNamePrefix: 'hardlinking',
      platform: {
        properties: [
          { name: 'OSFamily', value: 'linux' },
          { name: 'container-image', value: containerImage },
        ],
      },
      workerId: { datacenter: 'rig', rack: '1', slot: slot, hostname: 'rig-worker-' + slot },
    }],
  }],
  inputDownloadConcurrency: 10,
  outputUploadConcurrency: 11,
  directoryCache: {
    maximumCount: 1000,
    maximumSizeBytes: 1000 * 1024,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },
}
