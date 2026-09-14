#!/usr/bin/env bash
# Builds the release binary and assembles build/Emoji Search.app with the
# index + encoder copied in from packages/emoji-index.
set -euo pipefail
cd "$(dirname "$0")/.."

INDEX_PKG="../../packages/emoji-index"
MODEL_DIR="$INDEX_PKG/models/Xenova/all-MiniLM-L6-v2"
APP="build/Emoji Search.app"

for f in "$INDEX_PKG/dist/emoji-index.bin" "$INDEX_PKG/dist/emoji-meta.json" \
         "$MODEL_DIR/onnx/model_quantized.onnx" "$MODEL_DIR/tokenizer.json"; do
  [ -f "$f" ] || { echo "missing $f — run \`pnpm index:fetch-model\` from the workspace root" >&2; exit 1; }
done

swift build -c release 2>&1 | grep -E "error|warning: unused|Build complete" || true
[ -x .build/release/EmojiSearch ] || { echo "build failed" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EmojiSearch "$APP/Contents/MacOS/EmojiSearch"
cp Info.plist "$APP/Contents/"
cp "$INDEX_PKG/dist/emoji-index.bin" "$INDEX_PKG/dist/emoji-meta.json" "$APP/Contents/Resources/"
cp "$MODEL_DIR/onnx/model_quantized.onnx" "$MODEL_DIR/tokenizer.json" "$APP/Contents/Resources/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - "$APP" 2>/dev/null
echo "built $APP ($(du -sh "$APP" | cut -f1))"
