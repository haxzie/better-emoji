---
name: release
description: Cut, verify, or debug a Better Emoji macOS release — version bump → tag → CI sign/notarize (app + DMG) → GitHub release → R2 mirror → latest.json → site /download and the in-app updater. Use when asked to release, ship, tag, bump the version, backfill/rerun the mirror, check what /download serves, or fix notarization, update-check, signing or TCC problems.
---

# Releasing Better Emoji (macOS)

> **Never tag or push a tag without the user's explicit go-ahead for *this* release.**
> Tagging publishes a public GitHub release, rewrites `latest.json`, and pushes an
> update to every installed copy. Approval for an earlier release does not carry over.
> Commit and push the fix, then ask: "Want me to cut vX.Y.Z?" — and wait.

## The pipeline in one picture

```
apps/mac/Info.plist (CFBundleShortVersionString = X.Y.Z)
        │  git tag vX.Y.Z && git push origin vX.Y.Z
        ▼
.github/workflows/release.yml            (runs-on: macos-26 — needs the macOS 26 SDK for .glassEffect)
  ├─ pnpm index:build + index:fetch-model   (cached on scripts+lockfile hash)
  ├─ apps/mac/scripts/bundle.sh             VERSION=X.Y.Z BUILD_NUMBER=<run#>, Developer ID + hardened runtime
  ├─ notarize app (zip) → staple
  ├─ apps/mac/scripts/make-dmg.sh           dmgbuild + dmg/settings.py → installer window
  ├─ sign DMG → notarize → staple
  ├─ gh release create vX.Y.Z              Better-Emoji-macOS-vX.Y.Z.{dmg,zip} + .sha256 each
  └─ job "mirror" → .github/workflows/release-mirror.yml   (secrets: inherit)
        ├─ upload zip + dmg to R2 bucket `better-emoji` under releases/X.Y.Z/
        ├─ write releases/latest.json
        └─ verify latest.json (polls ≤90 s for the edge cache), both files 200, /download redirect
        ▼
https://emoji.haxzie.com  (Worker: apps/web/server/index.ts, R2 binding RELEASES)
  ├─ /download                  302 → dmg.url from latest.json (zip if no dmg)
  ├─ /releases/latest.json      the manifest (edge-cached 60 s)
  └─ /releases/<v>/<file>       the artefacts (immutable, edge-cached)
        ▼
Consumers
  ├─ site hero button (apps/web/src/site.ts fetchLatestRelease → shows DMG version/size)
  └─ in-app updater (apps/mac/Sources/EmojiSearch/UpdateChecker.swift)
        reads latest.json, downloads `url` (the ZIP), verifies sha256, unzips, replaces, relaunches
```

GitHub is the source of truth for artefacts; R2 is the delivery path. Nothing user-facing reads the GitHub API.

## Cutting a release — the exact steps

1. Everything you want in the release must be on `main` (the tag points at HEAD; the workflow checks out the tagged commit).
2. Bump the version — the tag and Info.plist must agree, since local builds read Info.plist and CI stamps from the tag:
   ```bash
   sed -i '' 's|<string>OLD</string>|<string>NEW</string>|' apps/mac/Info.plist
   git add -A && git commit -m "Bump to NEW"
   git push origin HEAD:main            # branch → main is fast-forward in this repo
   ```
3. Tag and push the tag (this is the trigger; `workflow_dispatch` with a version also works from the Actions tab):
   ```bash
   git tag -a vNEW -m "Better Emoji NEW — <one line>"
   git push origin vNEW
   ```
4. Watch it (~3–5 min; two notarization round-trips):
   ```bash
   ID=$(gh run list --repo haxzie/better-emoji --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')
   gh run watch "$ID" --repo haxzie/better-emoji --exit-status --interval 15
   gh run view "$ID" --repo haxzie/better-emoji --json jobs -q '.jobs[] | "\(.name): \(.conclusion)"'
   ```
5. Verify what the world sees (see checklist below).

Version scheme: semver, tag = `v` + Info.plist version. Patch for fixes (0.3.1 → 0.3.2), minor for features.

## Verification checklist

```bash
curl -s https://emoji.haxzie.com/releases/latest.json                # version, url (zip), sha256, dmg{}
curl -sI -o /dev/null -w '%{redirect_url}\n' https://emoji.haxzie.com/download   # → the DMG
gh release view vX.Y.Z --repo haxzie/better-emoji --json assets -q '.assets[].name'  # 4 assets

# The DMG as a visitor gets it: hash matches manifest, Gatekeeper accepts DMG and app, stapled
cd /tmp && curl -sL -o be.dmg https://emoji.haxzie.com/download
shasum -a 256 be.dmg
xattr -w com.apple.quarantine "0083;$(printf '%x' $(date +%s));curl;" be.dmg
spctl --assess --type open --context context:primary-signature -v be.dmg     # accepted, Notarized Developer ID
xcrun stapler validate be.dmg
hdiutil attach -quiet -nobrowse -mountpoint /tmp/bemnt be.dmg
spctl --assess --type execute -v "/tmp/bemnt/Better Emoji.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/tmp/bemnt/Better Emoji.app/Contents/Info.plist"
hdiutil detach -quiet /tmp/bemnt; rm be.dmg
```

**Always eject test DMGs and never leave one open in Finder.** A stale mounted volume once got run by the user instead of the installed app ("I'm on 0.1.0?!"). Also delete `apps/mac/build/` when it's stale — `make-dmg.sh` packages whatever is there.

## latest.json (written by release-mirror.yml)

```json
{
  "version": "0.3.3", "tag": "v0.3.3", "publishedAt": "…", "platform": "darwin-arm64",
  "filename": "Better-Emoji-macOS-v0.3.3.zip",
  "url":  "https://emoji.haxzie.com/releases/0.3.3/Better-Emoji-macOS-v0.3.3.zip",   // ← updater
  "size": 26629155, "sha256": "…",
  "dmg": { "filename": "…dmg", "url": "…/releases/0.3.3/…dmg", "size": 27711323, "sha256": "…" }  // ← /download
}
```

Top-level `url/size/sha256` are the **zip** (the updater unpacks it in place). `dmg` is what people download; absent on releases ≤ 0.2.0, and the Worker falls back to `url`. Don't rename these fields without updating `UpdateChecker.swift` (`Manifest`), `server/index.ts` (`Manifest`) and `site.ts` (`fetchLatestRelease`).

## Secrets (`gh secret list --repo haxzie/better-emoji`)

| Secret | What | Where it came from |
|---|---|---|
| `MACOS_CERT_P12_BASE64` | Developer ID Application cert+key, base64 .p12 | `~/keys/DeveloperId.p12` |
| `MACOS_CERT_PASSWORD` | password for that .p12 | user-entered (not on disk anywhere) |
| `APPLE_API_KEY_P8` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID` | App Store Connect API key for `notarytool` | `~/keys/AuthKey_6K8NG3SPAG.p8`; issuer from `~/Projects/prequel/.env` |
| `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | R2 S3 API for the mirror | prequel's account-wide keys |
| `CLOUDFLARE_ACCOUNT_ID` | — | (site deploys need no secret: Workers Builds deploys from git) |

Team ID `2WH7TUH8N5`, identity `Developer ID Application: Musthaq Ahamad (2WH7TUH8N5)` (hard-coded in release.yml `SIGN_IDENTITY`). Cert expires **Feb 2027**.
Re-run `apps/mac/scripts/setup-release-secrets.sh` (Apple) or `apps/web/scripts/setup-mirror-secrets.sh` (R2) to rotate; both pipe values on stdin, never as args.

## Site deploys

Push to `main` → Cloudflare Workers Builds deploys the site + Worker. `pnpm ship` (`apps/web`: `vite build && wrangler deploy`) does the same from a machine with wrangler login. **If `server/index.ts` changes, the Worker must be deployed before the mirror's `/download` check will pass** (it verifies the redirect target).

## Local builds vs release builds

- `apps/mac/scripts/bundle.sh` → `apps/mac/build/Better Emoji.app`. Signs with the Developer ID cert if it's in the keychain (it is on the user's Mac), else ad-hoc. **Ad-hoc signatures change every build and macOS silently drops the Accessibility grant each time** — that's why local builds use the real identity. Local builds are not notarized.
- Stamp a version to test the updater: `VERSION=0.1.0 bash scripts/bundle.sh` → the app will see the live release as an update.
- `open` on a second copy with the same bundle id just activates the running one — `pkill -x EmojiSearch` first.
- To install a release build locally: download from `/download`, `ditto` the app into `/Applications` (do not `cp -R` a running app over itself).
- The executable/module is still `EmojiSearch`; the product/bundle is `Better Emoji` / `com.haxzie.better-emoji`.

## Debug switches in the binary

```bash
.build/release/EmojiSearch --probe "ship it" "party"          # ranking check, prints top hits
.build/release/EmojiSearch --snapshot out.png "party^ax"       # composited window PNG (^x=⌃x, %x=⌘x, \r=⏎)
open -a "Better Emoji" --args --anchor /tmp/a.txt              # AX trust + caret rect (kill the app first)
/usr/bin/log show --info --last 5m --predicate 'subsystem == "com.haxzie.better-emoji"'   # categories: anchor, updates
```
`log` is a zsh builtin — use `/usr/bin/log`. `--snapshot` skips the Accessibility prompt (it would steal key and hide the panel).

## Troubleshooting

**Mirror job failed but the release succeeded.** Rerun it alone; it's idempotent:
`gh workflow run release-mirror.yml --repo haxzie/better-emoji --ref main -f tag=vX.Y.Z`.
Causes seen: `/download` still pointing at the previous artefact because the Worker wasn't redeployed; the DMG 404 because a step didn't receive the `DMG` env; the `latest.json` check reading the 60 s-cached previous manifest (now polled). Read the failing step with `gh run view <id> --log | grep "mirror"`.

**Release job failed at notarization.** The step prints `notarytool log`; usual suspects are an unsigned nested item or a missing timestamp. ONNX Runtime is linked statically, so the only signed things are the app bundle and the DMG.

**App crashes on launch from a release build but not locally.** Never use `Bundle.module`: SwiftPM's accessor bakes in the *build machine's* `.build` path. Resources go in `Contents/Resources` via `bundle.sh` and are loaded through `Resources.url`. (This shipped as the 0.2.0/0.3.0 crash; fixed in 0.3.1.)

**"Check for Updates" says up to date / no update badge.** Check `curl …/releases/latest.json` version vs `CFBundleShortVersionString` in the installed app (`PlistBuddy`). Comparison is numeric (`compare(options: .numeric)`). The background check runs 20 s after launch and every 6 h, and skips while a download is in progress or an update is already known. Notifications are provisional (no prompt); if denied, the tray dot + "Update to vX…" menu item are the signal.

**Caret anchoring / paste not working.** `AXIsProcessTrusted()` must be true: System Settings → Privacy & Security → Accessibility → Better Emoji. `tccutil reset Accessibility com.haxzie.better-emoji` forces a fresh prompt. Changing the bundle id or signing identity makes it a new app to TCC.

**Rolling back.** `latest.json` is what users see: rerun the mirror with the older tag (`-f tag=vOLD`). The mirror refuses to go backwards by default — that check is the "Refuse to go backwards" step; remove or bypass it deliberately if you truly need to roll back. Release assets on GitHub are never deleted by the workflows.
