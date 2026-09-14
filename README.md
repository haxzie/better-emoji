# Emoji Search

Semantic emoji search that runs entirely on-device. Type "ship it", "feeling great" or
"we won" and get 🚀, 😀, 🏆 — no server, no API calls.

- **Web:** https://emoji.haxzie.com
- **macOS:** a menu bar picker that looks and behaves like the system emoji popup
  (⌃⌥Space), with the same semantic ranking.

## Layout

pnpm workspace, orchestrated by [Turborepo](https://turbo.build) (`turbo.json`):

| Package | What |
|---|---|
| [`packages/emoji-index`](packages/emoji-index) | Offline pipeline: CLDR names + keywords + phrasings → `all-MiniLM-L6-v2` embeddings → int8 `emoji-index.bin` (725 KB) + `emoji-meta.json`. Also downloads the encoder the apps ship. |
| [`apps/web`](apps/web) | Vite + TypeScript picker with the landing page around it. Transformers.js in a Web Worker, deployed to Cloudflare Workers; a small Worker (`server/`) serves `/download` from R2. |
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
| `pnpm dev` / `pnpm build` / `pnpm typecheck` | `turbo run …` across the JS packages (cached; `--filter=@emoji-search/web` to narrow) |
| `pnpm ship` | Build and deploy the web app to Cloudflare |
| `pnpm index:build` | Rebuild the embedding index (network + ~10 s; deliberately outside turbo — its output is committed) |
| `pnpm index:fetch-model` | Download the encoder files |
| `pnpm index:probe "query" …` | Print top semantic hits from Node |
| `pnpm mac:build` / `pnpm mac:run` | Assemble / open `apps/mac/build/Better Emoji.app` (needs Xcode; also outside turbo) |
| `pnpm clean` | Remove build output and turbo caches |

## How search works

Both apps use the same two-stage approach:

1. **Keyword prefix search** over names + keywords runs synchronously on every keystroke
   (`"cele"` → 🎉). Works before the model has loaded.
2. **Semantic search**: the query is embedded with MiniLM (q8, ~5–20 ms in the browser,
   ~1 ms native), dotted against all 1,914 int8 vectors (<1 ms), and merged in after an
   80 ms debounce: `score = semantic + 0.5 × keyword`.

See each package's README for details.

## Releasing

```
git tag v0.2.0 && git push origin v0.2.0
```

[`release.yml`](.github/workflows/release.yml) builds, signs and notarizes the Mac app and
publishes it as a GitHub release; [`release-mirror.yml`](.github/workflows/release-mirror.yml)
then copies the zip into the `better-emoji` R2 bucket and rewrites `releases/latest.json`,
which is what `emoji.haxzie.com/download` redirects to. The in-app updater keeps reading
GitHub directly. The site itself deploys from git through Cloudflare Workers Builds on
every push to `main` (settings in [`apps/web/README.md`](apps/web/README.md#deploying)).

One-time secrets: `apps/mac/scripts/setup-release-secrets.sh` (Apple) and
`apps/web/scripts/setup-mirror-secrets.sh` (R2).
