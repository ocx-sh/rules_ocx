#!/usr/bin/env node
// `pnpm run lighthouse`: build, serve with `astro preview` under the base path, then run lhci
// (mobile preset) on every built HTML page. One run per page; a failing page gets 3 runs and is
// judged on the median run. Asserts 100 in all four categories plus lighthouse.budgets.mjs.
// Flags: --dry-run (print pages and config, build and run nothing), --no-build (reuse dist/).
// Trimmed from ocx-sh/website scripts/lighthouse.mjs: sequential, no lanes, no cache.
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { BASE, assertions, oversizedHtml, pages, pathOf } from '../lighthouse.budgets.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const DIST = `${ROOT}dist`;
const OUT = `${ROOT}.lighthouseci`;
const PORT = process.env.LH_PORT || '4322';
const [dry, noBuild] = ['--dry-run', '--no-build'].map((f) => process.argv.includes(f));

const NO_WSL = { NODE_OPTIONS: `${process.env.NODE_OPTIONS ?? ''} --require ${ROOT}scripts/no-wsl.cjs` };
const run = (cmd, args, env = {}) =>
  spawnSync(cmd, args, { cwd: ROOT, stdio: 'inherit', env: { ...process.env, ...env } }).status === 0;

async function chromePath() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  return (await import('playwright-core')).chromium.executablePath();
}

async function waitFor(url) {
  for (let i = 0; i < 60; i++) {
    if (await fetch(url).then((r) => r.ok, () => false)) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`preview did not come up at ${url}`);
}

/** lhci collect + assert for one URL; true when every assertion passes. */
async function audit(url, runs, chrome) {
  rmSync(OUT, { recursive: true, force: true });
  mkdirSync(OUT, { recursive: true });
  const rc = `${OUT}/rc.json`;
  writeFileSync(rc, JSON.stringify({
    ci: {
      collect: { url: [url], numberOfRuns: runs, chromePath: chrome,
        settings: { chromeFlags: '--headless=new --no-sandbox', disableFullPageScreenshot: true } },
      assert: { assertions: assertions() },
    },
  }));
  const lhci = (cmd) => run('pnpm', ['exec', 'lhci', cmd, `--config=${rc}`], NO_WSL);
  return lhci('collect') && lhci('assert');
}

const bad = [];
if (!dry && !noBuild && !run('pnpm', ['run', 'build'])) process.exit(1);
if (dry && !noBuild) console.log('dry run: skipping build, using existing dist/');
const routes = pages(DIST);
const big = oversizedHtml(DIST, routes);
if (big.length) { console.error(`HTML over budget:\n${big.join('\n')}`); bad.push(...big); }
console.log(`${routes.length} pages under ${BASE}`);
if (dry) {
  routes.forEach((r) => console.log(`http://localhost:${PORT}${pathOf(r)}`));
  console.log(JSON.stringify(assertions(), null, 2));
  process.exit(bad.length ? 1 : 0);
}

const chrome = await chromePath();
const server = spawn('pnpm', ['exec', 'astro', 'preview', '--port', PORT], { cwd: ROOT, stdio: 'ignore' });
try {
  await waitFor(`http://localhost:${PORT}${BASE}`);
  for (const r of routes) {
    const url = `http://localhost:${PORT}${pathOf(r)}`;
    if (!(await audit(url, 1, chrome)) && !(await audit(url, 3, chrome))) bad.push(`${r}: Lighthouse failed`);
  }
} finally {
  server.kill();
}
if (bad.length) { console.error(`\nFAILED:\n${bad.join('\n')}`); process.exit(1); }
console.log('Lighthouse: all pages green');
