# Handover: publish the docs on the shared ocx.sh site

For an agent working in `rules_ocx`. Read this before touching docs, CI or `ocx.toml`.
Plan: [plan_phase3-pilots.md](https://github.com/ocx-sh/website/blob/main/.agents/plans/plan_phase3-pilots.md) (WP R1 to R4).

## What the shared site is

`ocx.sh` is one namespace served by Bunny from many repos. Each repo owns a path claimed in
`nav.json` of `ocx-sh/website`. This repo owns `/integrations/bazel/`. It builds a Starlight site
with the shared theme `@ocx-sh/theme` and deploys it to its own Bunny storage zone
(`sh-ocx-rules-ocx`). Edge rules route the claim path to that zone. `rules_ocx` is the reference
consumer: the first repo to do this end to end.

Today `/integrations/bazel/` redirects (302) to `https://ocx-sh.github.io/rules_ocx/`. That
stays until the website repo removes the legacy entry.

## Steps this repo owns

Work on a branch. Do not push, tag or merge: the owner lands it (AGENTS.md rules apply).

1. `ocx.toml`: add `node = "ocx.sh/nodejs/node:24"` and `pnpm = "ocx.sh/pnpm/pnpm:11"`, run `ocx lock`.
   `ocx.lock` is `merge=union`; check the diff is only the new tools.
2. `site/`: a Starlight project. Required settings:
   `base: '/integrations/bazel/'`, `trailingSlash: 'always'`, `plugins: [ocxTheme()]`, no `site`.
   Install `@ocx-sh/theme` at exactly `0.2.0` (no `^`), commit `pnpm-lock.yaml`, CI installs with `--frozen-lockfile`.
   Block until the plan's `ACTION_SHA` fill-in line holds a real SHA (P0.2); do not guess it.
   Follow the [setup skill](https://github.com/ocx-sh/website/blob/main/skills/ocx-theme-setup/SKILL.md).
3. Content port. A small script reads the committed `docs/defs.md` and `docs/extensions.md` and
   writes `.md` pages (not `.mdx`) with frontmatter. It strips the first-line Stardoc HTML comment.
   Never edit `docs/*.md`: `bazel run //docs:update` owns them and `diff_test` compares them.
   `docs/index.md` becomes the section index.
4. Check the port. Stardoc output has raw HTML (75 `<a id=...>` anchors, 43 in `defs.md` and 32 in `extensions.md`, 6 `<pre>` blocks) and braces in
   prose (`extensions.md:68`). Every `#ocx.*` anchor must resolve in the built site (check: the 75 ids in `dist` match the 75 in `docs/`).
5. `README.md` "API docs" (lines 285-288): link `https://ocx.sh/integrations/bazel/`.
6. CI. Add a build job (build, then `npx ocx-site check --dist dist`) and a `deploy.yml` from the
   [deploy skill](https://github.com/ocx-sh/website/blob/main/skills/ocx-theme-deploy/SKILL.md).
   Triggers: push to `main`, daily schedule, dispatch. Pin every `uses:` by full SHA with a
   `# vX.Y.Z` comment, including the
   [deploy action](https://github.com/ocx-sh/website/tree/main/.github/actions/deploy).
   Pin `ocx-sh/website/.github/actions/deploy@<40-hex> # v0.2.0` using the plan's `ACTION_SHA`.
   Required check names: none to add (ruleset enforces only deletion/non-fast-forward). The schedule trigger runs only from the default branch.
7. Dependency updates: this repo uses Renovate. Extend `renovate.json` with an npm rule grouping `@ocx-sh/theme`; the deploy-action SHA in `deploy.yml` stays Renovate-managed (`github-actions` group, `pinDigests`). Do NOT create `.github/dependabot.yml`. Bump theme and action SHA together: the action aborts when its Pagefind version differs from the theme's.
7b. Repo plumbing: add `site/node_modules` and `site/dist` to `.gitignore` and `.bazelignore`; decide hawkeye headers and lychee scope for `site/*` (exclude or add headers); add `site:build` / `site:check` tasks (`pnpm install --frozen-lockfile`, `astro build`, `ocx-site check --dist dist`) and wire them into `verify` or `ci.yml`.
8. Last, after the owner confirms verification: first one final Pages build that publishes meta-refresh stubs for `index.html`, `defs.html`, `extensions.html` pointing at `https://ocx.sh/integrations/bazel/`, `/defs/`, `/extensions/` (owner then disables Pages); only then delete `.github/workflows/pages.yml` and
   `docs/_config.yml`. Keep `docs/index.md` content only as the new section index.
9. Run `task verify` (lint + test + examples; `ocx exec -- bazelisk` is the repo's Bazel) and `task site:check` before handing over. Run lhci (mobile preset, per the `ocx-theme-quality` skill) against `astro preview`; every page must be 100x4. Commits: Conventional Commits.

## What the website repo does

- Owner creates the GitHub environment `ocx.sh` here (policy: `main` only).
- `task bunny:onboard -- ocx-sh/rules_ocx` creates the zone and sets the secret
  `BUNNY_STORAGE_KEY` in that environment.
- One website PR removes `legacy-rules-ocx` from `infra/bunny/legacy.json`. It lands LAST: after your first deploy has filled the zone and the website agent has verified it via the storage listing and preview zone. Then the dev zone and the prod zone get the rules, in that order.

You never hold the Bunny account key. It must not enter a workflow, a secret or a file here.

## Verify (the website agent runs these; check the results)

- The `deploy` job is green and reports uploaded files.
- `https://sh-ocx-dev.b-cdn.net/integrations/bazel/` and `https://next.ocx.sh/integrations/bazel/`
  return 200 without a redirect.
- `/` and `/integrations/` link to the Bazel page, and the Bazel page links back.
- Header nav shows the section. Search finds Bazel terms from `/` and `/` terms from Bazel.
- Lighthouse scores 100 in all four categories on the Bazel page (mobile).
- `grep -rE '(href|src)="/(_astro|pagefind)/' site/dist` returns nothing; `curl -i /integrations/bazel/does-not-exist/` returns 404 with the themed page, and its home/search links work under the base.

## Do not

- Do not edit the generated `docs/*.md`, or make the site read anything else.
- Do not set `site`, change `base`, or add a top-level path outside `/integrations/bazel/`.
- Do not disable GitHub Pages or delete `pages.yml` before verification.
- Do not touch other repos, `ocx.sh` DNS or Bunny settings.
- Do not float an action pin (`@v1`) or add a `pull_request` or tag trigger to `deploy.yml`.

## Rollback

Website side: restore the legacy entry, re-apply rules, then `task bunny:purge /integrations/bazel/` and check `curl -sI` shows 302. A bad deployed site is fixed by redeploying a good commit, not via Bunny. Keep Pages
enabled until prod has run clean for 48 h; re-enabling Pages after the owner disabled it needs re-running `pages.yml`.

## Open questions

- Q1 Theme `0.2.0` and the action SHA come from the plan's `ACTION_SHA` line (plan Q1).
- Q4 Resolved by default (plan D6): stubs on a last Pages build; override via the owner.
- Q6 Answered: the `default branch` ruleset enforces only deletion and non-fast-forward (no required checks, no signed commits).

## Links

- [Plan](https://github.com/ocx-sh/website/blob/main/.agents/plans/plan_phase3-pilots.md)
- [ocx-theme-setup](https://github.com/ocx-sh/website/blob/main/skills/ocx-theme-setup/SKILL.md)
- [ocx-theme-deploy](https://github.com/ocx-sh/website/blob/main/skills/ocx-theme-deploy/SKILL.md)
- [Deploy action](https://github.com/ocx-sh/website/tree/main/.github/actions/deploy)
