import { defineConfig, type Plugin } from 'vite';

// onnxruntime-web references its .wasm via import.meta.url, so Vite copies a
// 23 MB binary into dist. At runtime Transformers.js loads the wasm from
// jsDelivr instead (see @huggingface/transformers/src/backends/onnx.js), so the
// bundled copy is never fetched. Drop it.
const dropOrtWasm = (): Plugin => ({
  name: 'drop-ort-wasm',
  generateBundle(_, bundle) {
    for (const file of Object.keys(bundle)) {
      if (file.endsWith('.wasm')) delete bundle[file];
    }
  },
});

export default defineConfig({
  plugins: [dropOrtWasm()],
  optimizeDeps: {
    // Transformers.js ships prebuilt bundles + wasm; pre-bundling breaks worker loading.
    exclude: ['@huggingface/transformers'],
  },
  worker: {
    format: 'es',
    plugins: () => [dropOrtWasm()],
  },
  build: {
    target: 'esnext',
  },
});
