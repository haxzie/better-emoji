# Emoji Search

Semantic emoji search that runs entirely on-device. Type "ship it", "feeling great" or
"we won" and get 🚀, 😀, 🏆 — no server, no API calls.

- **Web:** https://emoji.haxzie.com
- **macOS:** a menu bar picker that looks and behaves like the system emoji popup
  (⌃⌥Space), with the same semantic ranking.

## Layout

pnpm workspace:

| Package | What |
|---|---|
| [`packages/emoji-index`](packages/emoji-index) | Offline pipeline: CLDR names + keywords + phrasings → `all-MiniLM-L6-v2` embeddings → int8 `emoji-index.bin` (725 KB) + `emoji-meta.json`. Also downloads the encoder the apps ship. |
| [`apps/web`](apps/web) | Vite + TypeScript picker. Transformers.js in a Web Worker, deployed to Cloudflare Workers. |
| [`apps/mac`](apps/mac) | SwiftUI/AppKit menu bar app. ONNX Runtime + a Swift WordPiece tokenizer run the *same* model against the *same* index, so rankings match the web exactly. |

## Getting started

```
pnpm install
pnpm index:fetch-model      # one-time, ~23 MB encoder into packages/emoji-index/models
pnpm dev                    # web app on http://localhost:5173
pnpm mac:run                # build + open the macOS app
```

The index itself (`packages/emoji-index/dist`) is committed, so you only need
`pnpm index:build` after changing phrasings or the model (~10 s).

## Scripts (root)

| Script | What |
|---|---|
| `pnpm dev` / `pnpm build` / `pnpm deploy` | Web app |
| `pnpm index:build` | Rebuild the embedding index |
| `pnpm index:fetch-model` | Download the encoder files |
| `pnpm index:probe "query" …` | Print top semantic hits from Node |
| `pnpm mac:build` / `pnpm mac:run` | Assemble / open `apps/mac/build/Emoji Search.app` |
| `pnpm typecheck` | `tsc` across packages |

## How search works

Both apps use the same two-stage approach:

1. **Keyword prefix search** over names + keywords runs synchronously on every keystroke
   (`"cele"` → 🎉). Works before the model has loaded.
2. **Semantic search**: the query is embedded with MiniLM (q8, ~5–20 ms in the browser,
   ~1 ms native), dotted against all 1,914 int8 vectors (<1 ms), and merged in after an
   80 ms debounce: `score = semantic + 0.5 × keyword`.

See each package's README for details.
