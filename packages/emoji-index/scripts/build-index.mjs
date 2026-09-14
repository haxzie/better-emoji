// Offline index builder.
//
//   1. For each emoji, build text blobs from the CLDR name + keywords + phrasings
//   2. Embed each blob with all-MiniLM-L6-v2, average, L2-normalize
//   3. Quantize to int8 and write dist/emoji-index.bin + dist/emoji-meta.json
//
// Run with: pnpm index:build (from the workspace root)

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { pipeline } from '@huggingface/transformers';
import compact from 'emojibase-data/en/compact.json' with { type: 'json' };
import groupMeta from 'emojibase-data/meta/groups.json' with { type: 'json' };

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, '..', 'dist');
const MODEL = 'Xenova/all-MiniLM-L6-v2';
const DIM = 384;
const BATCH = 64;

const phrasings = JSON.parse(readFileSync(path.join(here, 'phrasings.json'), 'utf8'));
delete phrasings._comment;

// Drop skin-tone / hair components (group 2) and anything without a group
// (regional indicator letters). Skin-tone variants stay nested in `skins`.
const COMPONENT_GROUP = 2;
const emoji = compact.filter((e) => e.group !== undefined && e.group !== COMPONENT_GROUP);
console.log(`${emoji.length} emoji`);

// One blob per "view" of the emoji. Averaging views gives a vector that sits
// between the literal name and the way people actually describe it.
function blobsFor(e) {
  const tags = e.tags ?? [];
  const blobs = [e.label];
  if (tags.length) blobs.push(`${e.label}: ${tags.join(', ')}`);
  for (const p of phrasings[e.hexcode] ?? []) blobs.push(p);
  return blobs;
}

const encode = await pipeline('feature-extraction', MODEL, { dtype: 'fp32' });

// Flatten all blobs so we can batch across emoji, then regroup.
const texts = [];
const owner = [];
emoji.forEach((e, i) => {
  for (const b of blobsFor(e)) {
    texts.push(b);
    owner.push(i);
  }
});
console.log(`${texts.length} blobs to embed`);

const sums = new Float32Array(emoji.length * DIM);
const t0 = Date.now();
for (let start = 0; start < texts.length; start += BATCH) {
  const batch = texts.slice(start, start + BATCH);
  const out = await encode(batch, { pooling: 'mean', normalize: true });
  const data = out.data;
  for (let b = 0; b < batch.length; b++) {
    const dst = owner[start + b] * DIM;
    const src = b * DIM;
    for (let d = 0; d < DIM; d++) sums[dst + d] += data[src + d];
  }
  if ((start / BATCH) % 10 === 0) {
    process.stdout.write(`\r  ${Math.min(start + BATCH, texts.length)}/${texts.length}`);
  }
}
console.log(`\nembedded in ${((Date.now() - t0) / 1000).toFixed(1)}s`);

// Average (sum / n has the same direction, so just normalize) and quantize.
// Each vector gets its own scale so we don't waste int8 range on outliers.
const scales = new Float32Array(emoji.length);
const q = new Int8Array(emoji.length * DIM);
for (let i = 0; i < emoji.length; i++) {
  const off = i * DIM;
  let norm = 0;
  for (let d = 0; d < DIM; d++) norm += sums[off + d] ** 2;
  norm = Math.sqrt(norm) || 1;
  let maxAbs = 0;
  for (let d = 0; d < DIM; d++) {
    sums[off + d] /= norm;
    maxAbs = Math.max(maxAbs, Math.abs(sums[off + d]));
  }
  const scale = maxAbs / 127 || 1;
  scales[i] = scale;
  for (let d = 0; d < DIM; d++) q[off + d] = Math.round(sums[off + d] / scale);
}

// Binary layout: Float32 scales[count] then Int8 vectors[count * DIM].
const bin = new Uint8Array(scales.byteLength + q.byteLength);
bin.set(new Uint8Array(scales.buffer), 0);
bin.set(new Uint8Array(q.buffer), scales.byteLength);

const meta = {
  model: MODEL,
  dim: DIM,
  count: emoji.length,
  groups: groupMeta.groups,
  emoji: emoji.map((e) => ({
    c: e.unicode,
    n: e.label,
    t: e.tags ?? [],
    g: e.group,
    ...(e.skins ? { s: e.skins.map((s) => s.unicode) } : {}),
  })),
};

mkdirSync(outDir, { recursive: true });
writeFileSync(path.join(outDir, 'emoji-index.bin'), bin);
writeFileSync(path.join(outDir, 'emoji-meta.json'), JSON.stringify(meta));
console.log(`wrote emoji-index.bin (${(bin.byteLength / 1024).toFixed(0)} KB)`);
console.log(`wrote emoji-meta.json (${(JSON.stringify(meta).length / 1024).toFixed(0)} KB)`);
