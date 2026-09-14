// (Re)builds the search API's index: sends every emoji with its text blobs to
// POST /api/v1/admin/reindex, which embeds them with Workers AI and stores the
// vectors in D1. Same blobs as packages/emoji-index/scripts/build-index.mjs, so
// the API ranks like the app (modulo the model).
//
//   ADMIN_TOKEN=… node scripts/seed-api.mjs [https://emoji.haxzie.com]
//
// Chunked to stay under the Worker's per-request subrequest limit.

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const indexPkg = path.join(here, '..', '..', '..', 'packages', 'emoji-index');
const compact = require(path.join(indexPkg, 'node_modules/emojibase-data/en/compact.json'));
const groupMeta = require(path.join(indexPkg, 'node_modules/emojibase-data/meta/groups.json'));
const phrasings = JSON.parse(readFileSync(path.join(indexPkg, 'scripts', 'phrasings.json'), 'utf8'));
delete phrasings._comment;

const origin = process.argv[2] ?? 'https://emoji.haxzie.com';
const token = process.env.ADMIN_TOKEN;
if (!token) { console.error('ADMIN_TOKEN is required'); process.exit(1); }

const COMPONENT_GROUP = 2;
const emoji = compact.filter((e) => e.group !== undefined && e.group !== COMPONENT_GROUP);

const items = emoji.map((e, id) => {
  const tags = e.tags ?? [];
  const blobs = [e.label];
  if (tags.length) blobs.push(`${e.label}: ${tags.join(', ')}`);
  for (const p of phrasings[e.hexcode] ?? []) blobs.push(p);
  return { id, char: e.unicode, name: e.label, group: e.group, tags, ...(e.skins ? { skins: e.skins.map((s) => s.unicode) } : {}), blobs };
});
console.log(`${items.length} emoji, ${items.reduce((n, i) => n + i.blobs.length, 0)} blobs → ${origin}`);

const CHUNK = 50;
let embedded = 0;
const t0 = Date.now();
for (let i = 0; i < items.length; i += CHUNK) {
  const chunk = items.slice(i, i + CHUNK);
  const body = { items: chunk, ...(i === 0 ? { reset: true, groups: groupMeta.groups } : {}) };
  const res = await fetch(`${origin}/api/v1/admin/reindex`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) { console.error(`\nchunk ${i}: ${res.status} ${await res.text()}`); process.exit(1); }
  const r = await res.json();
  embedded += r.embedded;
  process.stdout.write(`\r  ${Math.min(i + CHUNK, items.length)}/${items.length} emoji, ${embedded} blobs`);
}
console.log(`\ndone in ${((Date.now() - t0) / 1000).toFixed(1)}s`);

const status = await fetch(`${origin}/api/v1/status`).then((r) => r.json());
console.log(status);
