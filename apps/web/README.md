# Emoji Search

Semantic emoji search that runs entirely in the browser. Type "ship it", "feeling great" or
"we won" and get 🚀, 😀, 🏆 — no server, no API calls.

```
pnpm install && pnpm index:fetch-model   # from the workspace root
pnpm dev
```

The index and encoder come from [`packages/emoji-index`](../../packages/emoji-index);
`scripts/sync-assets.mjs` copies them into `public/` before `dev`/`build`.

## How it works

**Offline** (`pnpm index:build`, ~10 s on a laptop):

1. For each of the 1,914 emoji in [emojibase](https://emojibase.dev/) (skin-tone variants
   collapsed into their base), build a few text blobs: the CLDR name, the name + keywords, and
   any natural-language phrasings from `packages/emoji-index/scripts/phrasings.json`.
2. Embed each blob with `all-MiniLM-L6-v2`, average, L2-normalize.
3. Quantize to int8 (per-vector scale) and write `emoji-index.bin` (725 KB, ~200 KB
   gzipped) plus `emoji-meta.json` (names, keywords, groups, skin tones).

**In the browser:**

- `src/worker.ts` — a Web Worker loads the q8 MiniLM encoder via Transformers.js (~23 MB,
  cached by the Cache API after first visit) and the int8 index. It embeds the query, dots it
  against every emoji (<1 ms), and returns the top hits. Query vectors are memoized.
- `src/keyword.ts` — a sorted-token prefix index over names + keywords. Synchronous, runs on
  every keystroke, and catches what embeddings miss ("cele" → 🎉).
- `src/main.ts` — renders keyword hits immediately, debounces 80 ms, then merges in semantic
  hits when they arrive: `score = semantic + 0.5 × keyword`. Until the model is ready the
  picker is keyword-only, and upgrades in place once loading finishes.

## Phrasings

`packages/emoji-index/scripts/phrasings.json` maps emojibase hexcodes to the things people actually type
("lol", "wfh", "mind blown"). About 1,000 emoji are hand-seeded. To fill in the rest with
Claude:

```
export ANTHROPIC_API_KEY=…   # or `ant auth login`
pnpm --filter @emoji-search/index gen-phrasings   # only emoji without phrasings; --all to regenerate
pnpm index:build
```

## Keyboard

| Key | Action |
|---|---|
| `↵` | Copy the top result |
| `↓` then arrows | Move around the grid |
| `Esc` | Clear search / back to the search box |
| `/` or `⌘K` | Focus the search box |
| Right-click / long-press | Skin-tone variants |

## Scripts

| Script | What |
|---|---|
| `pnpm dev` | Vite dev server |
| `pnpm build` | Production build to `dist/` |
| `pnpm deploy` | Build and deploy to Cloudflare Workers (emoji.haxzie.com) |
| `pnpm typecheck` | `tsc` |
| `pnpm index:build` (root) | Rebuild the embedding index |
| `pnpm index:probe "query" …` (root) | Print top semantic hits from Node (no browser) |

## Notes on size

The encoder dominates the download (~23 MB for MiniLM q8, plus ~3 MB gzipped for the ONNX
runtime wasm; both cached after the first visit). The worker points ORT at the plain
`ort-wasm-simd-threaded` build rather than the default asyncify build, since the CPU backend
doesn't need it. Swapping in a Model2Vec table or a distilled student only touches
`src/worker.ts` (`embed`) and `packages/emoji-index/scripts/build-index.mjs` — the index format and UI don't change.
