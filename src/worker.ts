/// <reference lib="webworker" />
// Owns the sentence encoder and the int8 emoji index so the main thread
// never blocks on inference. Scoring lives here too: it's <1ms and keeps
// the 730 KB index out of the main thread entirely.

import { env, pipeline, type FeatureExtractionPipeline } from '@huggingface/transformers';
import type { Hit, WorkerRequest, WorkerResponse } from './types';

// Transformers.js defaults to the "asyncify" ORT build (needed for WebGPU).
// We only use the wasm CPU backend, so the plain build works and is ~2 MB
// smaller gzipped. Same CDN transformers.js already uses, same pinned version.
{
  const ort = env.backends.onnx!;
  const base = `https://cdn.jsdelivr.net/npm/onnxruntime-web@${ort.versions!.web}/dist/`;
  ort.wasm!.wasmPaths = { mjs: `${base}ort-wasm-simd-threaded.mjs`, wasm: `${base}ort-wasm-simd-threaded.wasm` };
}

// The model is served by us (see scripts/fetch-model.mjs), not huggingface.co:
// no third-party dependency at runtime and it rides the same CDN as the index.
env.allowLocalModels = true;
env.allowRemoteModels = false;
env.localModelPath = '/models/';

let encode: FeatureExtractionPipeline | null = null;
let dim = 0;
let count = 0;
let scales: Float32Array = new Float32Array(0);
let vecs: Int8Array = new Int8Array(0);

// People retype the same things; a query vector is 1.5 KB so keep plenty.
const queryCache = new Map<string, Float32Array>();
const CACHE_LIMIT = 500;

const post = (msg: WorkerResponse) => self.postMessage(msg);

async function init(req: Extract<WorkerRequest, { type: 'init' }>) {
  dim = req.dim;
  count = req.count;
  try {
    const [buf, pipe] = await Promise.all([
      fetch(req.indexUrl).then((r) => {
        if (!r.ok) throw new Error(`index fetch failed: ${r.status}`);
        return r.arrayBuffer();
      }),
      pipeline('feature-extraction', req.model, {
        dtype: 'q8', // CPU: WebGPU dispatch overhead exceeds compute for a 6-layer model
        progress_callback: (info) => {
          if (info.status === 'progress_total') {
            post({ type: 'status', state: 'loading', progress: info.progress });
          }
        },
      }),
    ]);
    scales = new Float32Array(buf, 0, count);
    vecs = new Int8Array(buf, count * 4, count * dim);
    encode = pipe;
    // Warm the graph so the first real keystroke isn't the slow one.
    await embed('hello');
    post({ type: 'status', state: 'ready' });
  } catch (err) {
    post({ type: 'status', state: 'error', message: err instanceof Error ? err.message : String(err) });
  }
}

async function embed(query: string): Promise<Float32Array> {
  const cached = queryCache.get(query);
  if (cached) return cached;
  const out = await encode!(query, { pooling: 'mean', normalize: true });
  const vec = new Float32Array(out.data as Float32Array);
  if (queryCache.size >= CACHE_LIMIT) {
    queryCache.delete(queryCache.keys().next().value!);
  }
  queryCache.set(query, vec);
  return vec;
}

function score(q: Float32Array, limit: number): Hit[] {
  const hits: Hit[] = new Array(count);
  for (let i = 0; i < count; i++) {
    const off = i * dim;
    let s = 0;
    for (let d = 0; d < dim; d++) s += q[d] * vecs[off + d];
    hits[i] = [i, s * scales[i]];
  }
  hits.sort((a, b) => b[1] - a[1]);
  return hits.slice(0, limit);
}

self.onmessage = async (e: MessageEvent<WorkerRequest>) => {
  const req = e.data;
  if (req.type === 'init') return init(req);
  if (req.type === 'search') {
    if (!encode) return;
    const t0 = performance.now();
    const q = await embed(req.query);
    const hits = score(q, req.limit);
    post({ type: 'result', id: req.id, query: req.query, hits, ms: performance.now() - t0 });
  }
};
