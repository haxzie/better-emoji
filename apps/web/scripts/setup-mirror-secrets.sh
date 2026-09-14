#!/usr/bin/env bash
# One-time setup: pushes the R2 secrets release-mirror.yml needs to the GitHub
# repo. (Site deploys don't need a secret — Workers Builds deploys from git;
# see apps/web/README.md.)
#
#   R2_ACCOUNT_ID           Cloudflare dashboard → R2 → Account details
#   R2_ACCESS_KEY_ID        R2 → Manage API tokens → Object Read & Write
#   R2_SECRET_ACCESS_KEY
#
# The keys are the same account-wide pair prequel uses; pass
# PREQUEL_ENV=~/Projects/prequel/apps/api/.dev.vars to read them from there
# instead of being prompted. They're verified against the bucket before upload
# and piped to `gh secret set` on stdin, never as arguments.
set -euo pipefail

BUCKET=better-emoji
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "Repo: $REPO"

if [ -f "${PREQUEL_ENV:-}" ]; then
  ACCOUNT_ID=$(sed -n 's/^R2_ACCOUNT_ID=//p' "$PREQUEL_ENV")
  R2_KEY=$(sed -n 's/^R2_ACCESS_KEY_ID=//p' "$PREQUEL_ENV")
  R2_SECRET=$(sed -n 's/^R2_SECRET_ACCESS_KEY=//p' "$PREQUEL_ENV")
  echo "R2 keys read from $PREQUEL_ENV"
else
  read -rp  "R2_ACCOUNT_ID: " ACCOUNT_ID
  read -rp  "R2_ACCESS_KEY_ID: " R2_KEY
  read -rsp "R2_SECRET_ACCESS_KEY: " R2_SECRET; echo
fi
[[ "$ACCOUNT_ID" =~ ^[0-9a-f]{32}$ ]] || { echo "✗ that doesn't look like an account id" >&2; exit 1; }

R2_ACCOUNT_ID="$ACCOUNT_ID" R2_ACCESS_KEY_ID="$R2_KEY" R2_SECRET_ACCESS_KEY="$R2_SECRET" \
  node "$(dirname "$0")/r2-check.mjs" "$BUCKET"

printf '%s' "$ACCOUNT_ID" | gh secret set R2_ACCOUNT_ID        --repo "$REPO"
printf '%s' "$R2_KEY"     | gh secret set R2_ACCESS_KEY_ID     --repo "$REPO"
printf '%s' "$R2_SECRET"  | gh secret set R2_SECRET_ACCESS_KEY --repo "$REPO"

echo
gh secret list --repo "$REPO"
echo
echo "Done. Tagging a release mirrors it to R2."
echo "To backfill an existing release:  gh workflow run release-mirror.yml -f tag=v0.1.0"
