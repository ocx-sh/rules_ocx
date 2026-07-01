# Release procedure

1. `task verify` green locally; CI green on main.
2. `git-cliff --bump` decides the next version (Conventional Commits;
   pre-1.0: feat bumps minor, breaking does NOT bump major).
3. Update `version` in MODULE.bazel to match, commit `chore(release): vX.Y.Z`.
4. Tag `vX.Y.Z`, push tag. `release.yml` builds the BCR-compatible source
   archive (git archive, stable tar flags), computes the integrity hash,
   generates notes with git-cliff, publishes the GitHub release.
5. BCR submission is manual for now: `.bcr/` holds the publish-to-bcr
   templates; follow https://github.com/bazel-contrib/publish-to-bcr when
   automating.
