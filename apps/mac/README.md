# Emoji Search for macOS

A menu bar emoji picker modelled on the system one (⌃⌘Space), with on-device semantic
search. Press **⌃⌥Space** anywhere to open it.

- Floating, non-activating panel near the cursor — the app you were typing in keeps focus
- Search field on top; keyword hits appear instantly, semantic hits merge in ~80 ms later
- Category tabs at the bottom (Frequently Used, Smileys, People, Animals, …) with sticky
  section headers while browsing
- Click or press ↵ to insert. Arrow keys move the selection, Esc clears/closes
- Right-click an emoji for skin-tone variants
- Menu bar icon: left-click opens the picker, right-click for the menu

**Inserting vs. copying:** without Accessibility permission the emoji is copied to the
clipboard. Grant it (menu → *Enable Paste into Active App…*) and the picker pastes straight
into the frontmost app and restores your previous clipboard.

## Build

```
pnpm index:fetch-model     # once, from the workspace root
pnpm mac:run               # → apps/mac/build/Emoji Search.app
```

`scripts/bundle.sh` runs `swift build -c release`, assembles the `.app`, copies the index
and encoder in from `packages/emoji-index`, and ad-hoc signs it. Requires macOS 14+ and
Xcode 15+. No Xcode project — it's a plain SwiftPM package.

## Release

`.github/workflows/release.yml` builds, signs (Developer ID + hardened runtime), notarizes,
staples and publishes `Emoji-Search-macOS-v<version>.zip` as a GitHub release. The in-app
updater (Settings → Updates) looks for exactly that asset on the latest release.

```
git tag v0.2.0 && git push origin v0.2.0      # or run the workflow manually with a version
```

One-time setup — pushes the cert + notarization key from `~/keys` to the repo's secrets:

```
apps/mac/scripts/setup-release-secrets.sh
```

To produce a signed build locally:

```
VERSION=0.2.0 SIGN_IDENTITY="Developer ID Application: …" bash scripts/bundle.sh
```

## How it runs the model

`Embedder.swift` loads `model_quantized.onnx` with
[onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager)
and `WordPieceTokenizer.swift` implements the BERT uncased tokenizer from `tokenizer.json`
(lowercase, accent stripping, punctuation/CJK splitting, greedy WordPiece). Mean-pool,
L2-normalize, dot against the int8 index. Verified identical to the Transformers.js path:

```
.build/release/EmojiSearch --probe "ship it" "feeling great"
pnpm index:probe "ship it" "feeling great"     # same numbers
```

Dev flags: `--show` opens the panel on launch; `--snapshot out.png ["query"]` renders the
panel to a PNG headlessly.
