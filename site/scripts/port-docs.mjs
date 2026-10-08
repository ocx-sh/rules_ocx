// Writes the Starlight pages from the committed Stardoc output in ../docs (never edited here).
// Run by `pnpm run build`/`dev`; the output under src/content/docs is gitignored.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { posix } from 'node:path';

const SRC = new URL('../../docs/', import.meta.url);
const OUT = new URL('../src/content/docs/', import.meta.url);
const SOURCE = 'https://github.com/ocx-sh/rules_ocx/blob/main/';

const BASE = '/integrations/bazel/';
const hand = (from, title, description) => ({ from, to: from, title, description, editUrl: `${SOURCE}docs/${from}` });
const generated = (from, title, description, editUrl) => ({ from, to: from, title, description, editUrl, declare: 'reference' });

const PAGES = [
  hand('index.md', 'rules_ocx', 'Provision development tools in Bazel through the OCX package manager.'),
  hand('tutorial.md', 'Run shellcheck in a Bazel test without installing it', 'Add rules_ocx to a workspace and run a pinned shellcheck in an sh_test.'),
  hand('guides/pin-toolchain.md', 'Share one toolchain between Bazel and developers', 'Use one ocx.toml and ocx.lock for Bazel targets and the developer shell.'),
  hand('guides/ci-reproducible.md', 'Fail CI on a stale lock', 'Make a stale pin fail the build and freeze ad-hoc packages and site patches.'),
  hand('guides/offline-mirror.md', 'Build behind a corporate mirror', 'Point rules_ocx at an internal mirror, proxy CA and registry credentials.'),
  hand('guides/cross-platform.md', 'Use per-platform tools with transitions', 'Build tools for a platform other than the host with a transition.'),
  hand('guides/remote-cache.md', 'Keep tool bytes out of remote-cached actions', 'Use lazy provisioning so a remote-cached build downloads no tool content.'),
  hand('concepts/how-it-works.md', 'How rules_ocx works', 'Why rules_ocx shells out to ocx, and what is shared between Bazel and the shell.'),
  hand('concepts/trust-and-config.md', 'Trust, config and patches', 'How verification posture, host config and patches reach a fetch.'),
  hand('reference/environment.md', 'Environment variables', 'Which OCX environment variables reach the repository rules and which never do.'),
  generated('extensions.md', 'Module extension', 'API reference for the ocx module extension and its tag classes.', `${SOURCE}ocx/extensions.bzl`),
];

// Source links are relative `.md` paths, which also work on GitHub. Turn them into site URLs under the base.
const siteUrl = (from, target) => {
  const path = posix.normalize(posix.join(posix.dirname(from), target)).replace(/\.md$/, '');
  return path === 'index' ? BASE : `${BASE}${path}/`;
};
const rewriteLinks = (from, text) => text.replace(/\]\(([^)#:]+\.md)(#[^)]*)?\)/g, (_m, target, hash = '') => `](${siteUrl(from, target)}${hash})`);

// A bare `<digest>` outside a code span is read as an HTML tag and vanishes. Stardoc's own markup
// (`<a>`, `<pre>`) stays.
const KEEP = new Set(['a', 'pre']);
const escapeBareTags = (line) =>
  line
    .split(/(`[^`]*`)/)
    .map((part, i) =>
      i % 2 ? part : part.replace(/<(\/?)([A-Za-z_][\w-]*)>/g, (m, _s, name) => (KEEP.has(name) ? m : m.replace('<', '&lt;').replace('>', '&gt;'))),
    )
    .join('');

// Stardoc writes `<a id="X"></a>` above `## X`; the heading already carries id X, and a second
// element with the same id is invalid HTML. Anchors whose id differs from the heading stay.
const dropDuplicateAnchors = (text) => text.replace(/^<a id="([^"]+)"><\/a>\n+(?=#+ \1$)/gm, '');

export function port(page, text) {
  // Hand-written sources keep their H1 for GitHub; the front matter title renders it on the site.
  const dropH1 = (s) => (page.declare ? s : s.replace(/^# .*\n+/m, ''));
  const body = dropH1(rewriteLinks(
    page.from,
    dropDuplicateAnchors(text)
      .replace(/^<!--.*Stardoc.*-->\n+/, '')
      // Shiki has no Starlark grammar (blocks render unthemed, #bbb on white); Starlark is a Python subset.
      .replace(/^(\s*```)starlark$/gm, '$1python')
      // Stardoc links every type name to bazel.build; those bytes push /extensions/ over the weight budget.
      // Same for the signature's per-parameter anchors: the attribute tables below carry them.
      .replace(/<pre>[\s\S]*?<\/pre>/g, (pre) => pre.replace(/<a href="#[^"]*">([^<]*)<\/a>/g, '$1'))
      .replace(/<a href="https:\/\/bazel\.build\/[^"]*">([^<]*)<\/a>/g, '$1')
      .split('\n')
      .map(escapeBareTags)
      .join('\n'),
  ));
  const front = ['---', `title: ${JSON.stringify(page.title)}`, `description: ${JSON.stringify(page.description)}`, `editUrl: ${page.editUrl}`, '---'];
  const declaration = page.declare ? [`<!-- doc_type: ${page.declare} -->`, ''] : [];
  return `${[...front, ...declaration].join('\n')}\n${body}`;
}

// defs.md is one Stardoc page of ~75 anchors, too big for the first-RTT HTML budget. Split it: an index
// (the intro plus a rule list) and one page per rule, with cross-page `#anchor` links pointing at the right page.
const DEFS_EDIT = `${SOURCE}ocx/defs.bzl`;
export function splitDefs(text) {
  const [intro, ...rules] = text.split(/^(?=<a id="[^"]+"><\/a>\n+## )/m);
  const parts = rules.map((body) => {
    const name = body.match(/^## (.+)$/m)[1];
    const lead = body.split('</pre>')[1]?.trim().split('\n')[0].replace(/[`*]/g, '').trim() || `Reference for ${name}.`;
    return { name, body, lead };
  });
  const home = new Map(); // anchor id -> page slug
  for (const { name, body } of parts) for (const [, id] of body.matchAll(/<a id="([^"]+)"/g)) home.set(id, name);
  const fix = (slug, body) => body.replace(/(href="|\]\()#([^"')]+)/g, (m, pre, id) => (home.get(id) && home.get(id) !== slug ? `${pre}${BASE}defs/${home.get(id)}/#${id}` : m));
  const list = parts.map(({ name, lead }) => `- [\`${name}\`](${BASE}defs/${name}/): ${lead}`).join('\n');
  return [
    { to: 'defs/index.md', title: 'Rules and macros', description: 'API reference for defs.bzl: the public repository rules and macros of rules_ocx.', text: `${intro.trimEnd()}\n\n${list}\n` },
    ...parts.map(({ name, body, lead }) => ({ to: `defs/${name}.md`, title: name, description: lead.slice(0, 160), text: fix(name, body) })),
  ];
}

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
for (const page of PAGES) {
  const out = new URL(page.to, OUT);
  mkdirSync(new URL('.', out), { recursive: true });
  writeFileSync(out, port(page, readFileSync(new URL(page.from, SRC), 'utf8')));
}
for (const d of splitDefs(readFileSync(new URL('defs.md', SRC), 'utf8'))) {
  const out = new URL(d.to, OUT);
  mkdirSync(new URL('.', out), { recursive: true });
  writeFileSync(out, port({ from: 'defs.md', title: d.title, description: d.description, editUrl: DEFS_EDIT, declare: 'reference' }, d.text));
}
