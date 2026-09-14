# Better Emoji — web

The landing page (nav with GitHub stars, hero with the download button) and the in-browser
picker under it. Semantic emoji search that runs entirely in the browser. Type "ship it",
"feeling great" or "we won" and get 🚀, 😀, 🏆 — no server, no API calls.

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

## The Worker (`server/`)

`wrangler.jsonc` serves `dist/` as static assets and routes just three paths to
`server/index.ts` (`run_worker_first`):

| Path | What |
|---|---|
| `/download` | 302 to the URL in `releases/latest.json`; falls back to the GitHub releases page |
| `/releases/latest.json` | The manifest `release-mirror.yml` writes to the `better-emoji` R2 bucket |
| `/releases/<version>/<zip>` | The build, streamed from R2 and cached at the edge |

`src/site.ts` reads `/releases/latest.json` for the version badge under the hero button and
`api.github.com` (client-side, cached an hour in localStorage) for the star count. Both
fail silently.

`pnpm dev:worker` builds and runs the whole thing under `wrangler dev`; the local R2 is
empty, so `/download` goes to GitHub. To try the R2 path:

```
npx wrangler r2 object put better-emoji/releases/latest.json --file latest.json --local --content-type application/json
```

## Deploying

Production deploys come from git via **Cloudflare Workers Builds**, configured on the
`better-emoji` Worker (dashboard → Workers & Pages → better-emoji → Settings → Build):

| Setting | Value |
|---|---|
| Git repository | `haxzie/better-emoji`, branch `main` |
| Root directory | `/apps/web/` |
| Build command | `pnpm run build:cf` |
| Deploy command | `npx wrangler deploy` (default) |
| Non-production branch deploy command | `npx wrangler versions upload` (default; uploads a preview, doesn't promote it) |
| Build watch paths (include) | `apps/web/*`, `packages/emoji-index/*`, `pnpm-lock.yaml`, `turbo.json` |

`build:cf` downloads the encoder first because it isn't in git, then runs the turbo build
from the workspace root. No API token is needed anywhere; `pnpm ship` still works for a
manual deploy from a logged-in wrangler.

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
| `pnpm dev:worker` | Build, then `wrangler dev` (static assets + the Worker) |
| `pnpm ship` | Build and deploy to Cloudflare Workers by hand (emoji.haxzie.com) |
| `pnpm build:cf` | What Workers Builds runs: fetch the encoder, then the turbo build from the workspace root |
| `pnpm typecheck` | `tsc` for the site and the Worker |
| `pnpm index:build` (root) | Rebuild the embedding index |
| `pnpm index:probe "query" …` (root) | Print top semantic hits from Node (no browser) |

## Notes on size

The encoder dominates the download (~23 MB for MiniLM q8, plus ~3 MB gzipped for the ONNX
runtime wasm; both cached after the first visit). The worker points ORT at the plain
`ort-wasm-simd-threaded` build rather than the default asyncify build, since the CPU backend
doesn't need it. Swapping in a Model2Vec table or a distilled student only touches
`src/worker.ts` (`embed`) and `packages/emoji-index/scripts/build-index.mjs` — the index format and UI don't change.
