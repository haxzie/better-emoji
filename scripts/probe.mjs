// Print the top semantic hits for one or more queries without a browser.
//   npm run probe -- "ship it" "feeling great"
import { readFileSync } from 'node:fs';
import { pipeline } from '@huggingface/transformers';

const meta = JSON.parse(readFileSync('public/emoji-meta.json', 'utf8'));
const buf = readFileSync('public/emoji-index.bin');
const scales = new Float32Array(buf.buffer, buf.byteOffset, meta.count);
const vecs = new Int8Array(buf.buffer, buf.byteOffset + meta.count * 4, meta.count * meta.dim);
const encode = await pipeline('feature-extraction', meta.model, { dtype: 'q8' });

for (const query of process.argv.slice(2)) {
  const q = (await encode(query, { pooling: 'mean', normalize: true })).data;
  const t = performance.now();
  const hits = [];
  for (let i = 0; i < meta.count; i++) {
    let s = 0;
    const off = i * meta.dim;
    for (let d = 0; d < meta.dim; d++) s += q[d] * vecs[off + d];
    hits.push([s * scales[i], i]);
  }
  hits.sort((a, b) => b[0] - a[0]);
  const top = hits.slice(0, 10).map(([s, i]) => `${meta.emoji[i].c} ${s.toFixed(2)}`).join('  ');
  console.log(`${query.padEnd(24)} ${(performance.now() - t).toFixed(1).padStart(5)}ms  ${top}`);
}
