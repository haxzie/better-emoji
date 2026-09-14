#!/usr/bin/env bash
# Builds the installer disk image: make-dmg.sh "<path to Better Emoji.app>" "<out.dmg>"
# Layout lives in dmg/settings.py; the background in dmg/render-background.swift.
# Needs dmgbuild (pip install dmgbuild) — it writes the Finder layout straight
# into .DS_Store, so no Finder scripting and it works headless on CI.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"; OUT="$2"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
if command -v dmgbuild >/dev/null; then DMGBUILD=dmgbuild
elif python3 -c 'import dmgbuild' 2>/dev/null; then DMGBUILD="python3 -m dmgbuild"
else echo "dmgbuild not found — pip3 install dmgbuild" >&2; exit 1; fi

# Regenerate the background if the renderer is newer than the PNGs, then pack
# 1x + 2x into one TIFF so the window is crisp on Retina.
if [ ! -f dmg/background@2x.png ] || [ dmg/render-background.swift -nt dmg/background@2x.png ]; then
  swift dmg/render-background.swift
fi
tiffutil -cathidpicheck dmg/background.png dmg/background@2x.png -out dmg/background.tiff >/dev/null

rm -f "$OUT"
$DMGBUILD -s dmg/settings.py -D app="$APP" -D here="$PWD/dmg" "Better Emoji" "$OUT"
rm -f dmg/background.tiff
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
