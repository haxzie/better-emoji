// Downloads the sentence encoder into models/ so the apps can ship it
// themselves instead of hitting huggingface.co at runtime. Skips files that
// are already present.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const meta = JSON.parse(readFileSync(path.join(root, 'dist', 'emoji-meta.json'), 'utf8'));
const model = meta.model; // e.g. "Xenova/all-MiniLM-L6-v2"

// dtype 'q8' → onnx/model_quantized.onnx
const FILES = ['config.json', 'tokenizer.json', 'tokenizer_config.json', 'onnx/model_quantized.onnx'];

for (const file of FILES) {
  const dest = path.join(root, 'models', model, file);
  if (existsSync(dest)) continue;
  const url = `https://huggingface.co/${model}/resolve/main/${file}`;
  process.stdout.write(`fetching ${file}… `);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url} → ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  mkdirSync(path.dirname(dest), { recursive: true });
  writeFileSync(dest, buf);
  console.log(`${(buf.byteLength / 1024 / 1024).toFixed(1)} MB`);
}
console.log(`model ready in models/${model}`);
