// Every `<a id>` anchor Stardoc wrote into ../docs must exist as an id in the built site, and no id may repeat
// within a page. `defs` is split into one page per rule (port-docs.mjs): its anchors may live on any of them.
import { readFileSync, readdirSync } from 'node:fs';

const idList = (file, re) => [...readFileSync(file, 'utf8').matchAll(re)].map((m) => m[1]);
let missing = 0;
for (const page of ['defs', 'extensions']) {
  const dir = new URL(`../dist/${page}/`, import.meta.url);
  const built = new Set();
  for (const f of readdirSync(dir, { recursive: true, encoding: 'utf8' }).filter((f) => f.endsWith('.html'))) {
    const all = idList(new URL(f, dir), /\sid="([^"]+)"/g);
    for (const id of new Set(all)) if (all.filter((i) => i === id).length > 1) (missing++, console.error(`${page}/${f}: id ${id} appears twice`));
    all.forEach((i) => built.add(i));
  }
  const source = new Set(idList(new URL(`../../docs/${page}.md`, import.meta.url), /<a id="([^"]+)"/g));
  for (const id of source) if (!built.has(id)) (missing++, console.error(`${page}: anchor #${id} missing from dist`));
  console.log(`${page}: ${source.size} anchors in docs, ${[...source].filter((i) => built.has(i)).length} in dist`);
}
process.exit(missing ? 1 : 0);
