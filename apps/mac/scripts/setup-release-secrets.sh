#!/usr/bin/env bash
# One-time setup: pushes the signing + notarization secrets that
# .github/workflows/release.yml needs to the GitHub repo.
#
# Reads from ~/keys (override with KEYS_DIR):
#   DeveloperId.p12        Developer ID Application cert + private key
#   AuthKey_<KEYID>.p8     App Store Connect API key
# Prompts for the two things that aren't on disk: the .p12 password and the
# API key's Issuer ID. Both are verified against Apple before anything is
# uploaded. Values are piped to `gh secret set` on stdin, never as arguments.
set -euo pipefail

KEYS="${KEYS_DIR:-$HOME/keys}"
P12="$KEYS/DeveloperId.p12"
P8=$(ls "$KEYS"/AuthKey_*.p8 2>/dev/null | head -1 || true)
[ -f "$P12" ] || { echo "missing $P12" >&2; exit 1; }
[ -n "$P8" ]  || { echo "missing $KEYS/AuthKey_*.p8" >&2; exit 1; }
KEY_ID=$(basename "$P8" .p8); KEY_ID=${KEY_ID#AuthKey_}

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "Repo:         $REPO"
echo "Certificate:  $P12"
echo "API key:      $P8 (key ID $KEY_ID)"
echo

# ── .p12 password ────────────────────────────────────────────────────────────
read -rsp "Password for DeveloperId.p12: " P12_PASSWORD; echo
if ! openssl pkcs12 -in "$P12" -nokeys -passin "pass:$P12_PASSWORD" >/dev/null 2>&1 \
   && ! openssl pkcs12 -in "$P12" -nokeys -passin "pass:$P12_PASSWORD" -legacy >/dev/null 2>&1; then
  echo "✗ wrong password (couldn't open the .p12)" >&2; exit 1
fi
echo "✓ .p12 opens"

# ── Issuer ID ────────────────────────────────────────────────────────────────
echo "Issuer ID is the UUID shown at the top of"
echo "https://appstoreconnect.apple.com/access/integrations/api"
read -rp "App Store Connect Issuer ID: " ISSUER_ID
[[ "$ISSUER_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "✗ that doesn't look like a UUID" >&2; exit 1; }
if ! xcrun notarytool history --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER_ID" >/dev/null 2>&1; then
  echo "✗ Apple rejected the API key / issuer ID combination" >&2; exit 1
fi
echo "✓ notarytool accepts the API key"
echo

# ── Upload ───────────────────────────────────────────────────────────────────
base64 -i "$P12"           | gh secret set MACOS_CERT_P12_BASE64 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERT_PASSWORD   --repo "$REPO"
gh secret set APPLE_API_KEY_P8 --repo "$REPO" < "$P8"
printf '%s' "$KEY_ID"      | gh secret set APPLE_API_KEY_ID      --repo "$REPO"
printf '%s' "$ISSUER_ID"   | gh secret set APPLE_API_ISSUER_ID   --repo "$REPO"

echo
gh secret list --repo "$REPO"
echo
echo "Done. Cut a release with:  git tag v0.2.0 && git push origin v0.2.0"
