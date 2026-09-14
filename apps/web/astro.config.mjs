import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// onnxruntime-web references its .wasm via import.meta.url, so Vite copies a
// 23 MB binary into dist. At runtime Transformers.js loads the wasm from
// jsDelivr instead, so the bundled copy is never fetched. Drop it.
const dropOrtWasm = () => ({
  name: 'drop-ort-wasm',
  generateBundle(_, bundle) {
    for (const file of Object.keys(bundle)) {
      if (file.endsWith('.wasm')) delete bundle[file];
    }
  },
});

// Static output: every page is plain HTML on Workers Static Assets (free, no
// isolate in the path). The picker is a client-side script on the home page;
// /download, /releases/* and /api/* are handled by server/index.ts.
export default defineConfig({
  site: 'https://emoji.haxzie.com',
  output: 'static',
  trailingSlash: 'never',
  build: { format: 'file' }, // /api → api.html, matching the Worker's asset routing
  integrations: [sitemap()],
  vite: {
    plugins: [dropOrtWasm()],
    optimizeDeps: {
      // Transformers.js ships prebuilt bundles + wasm; pre-bundling breaks worker loading.
      exclude: ['@huggingface/transformers'],
    },
    worker: { format: 'es', plugins: () => [dropOrtWasm()] },
    build: { target: 'esnext' },
  },
});
