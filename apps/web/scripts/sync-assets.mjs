// Copies the shared index + encoder from packages/emoji-index into public/
// so Vite serves them as static assets. Runs before `dev` and `build`.

import { cpSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const indexPkg = path.dirname(require.resolve('@emoji-search/index/package.json'));
const publicDir = new URL('../public/', import.meta.url).pathname;

for (const [from, to] of [
  ['dist/emoji-index.bin', 'emoji-index.bin'],
  ['dist/emoji-meta.json', 'emoji-meta.json'],
  ['models', 'models'],
]) {
  const src = path.join(indexPkg, from);
  if (!existsSync(src)) {
    throw new Error(`${src} is missing — run \`pnpm index:fetch-model\` (models) or \`pnpm index:build\` (index) first`);
  }
  cpSync(src, path.join(publicDir, to), { recursive: true });
}
console.log('synced index + model into public/');
