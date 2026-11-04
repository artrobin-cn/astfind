#!/bin/bash
# Deploys the public site to Cloudflare Pages.
#
#   ./AstfindKit/scripts/deploy-site.sh              # site only
#   ./AstfindKit/scripts/deploy-site.sh 0.4.1        # site + update manifest/zip
#
# With a version, the script copies AstfindKit/build/Astfind-<version>.zip and
# AstfindKit/build/latest.json into docs/updates/ before uploading. The update
# manifest and archive must live on the same HTTPS host as the feed URL baked
# into the app (https://astfind.robyn.top/updates/latest.json).
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:-}"
if [ -n "$VERSION" ]; then
  ZIP="AstfindKit/build/Astfind-${VERSION}.zip"
  DMG="AstfindKit/build/Astfind-${VERSION}.dmg"
  DMG_SHA="${DMG}.sha256"
  MANIFEST="AstfindKit/build/latest.json"
  [ -f "$ZIP" ] || { echo "missing $ZIP" >&2; exit 1; }
  [ -f "$DMG" ] || { echo "missing $DMG" >&2; exit 1; }
  [ -f "$DMG_SHA" ] || { echo "missing $DMG_SHA" >&2; exit 1; }
  [ -f "$MANIFEST" ] || { echo "missing $MANIFEST" >&2; exit 1; }
  mkdir -p docs/updates docs/downloads
  cp "$ZIP" docs/updates/
  cp "$MANIFEST" docs/updates/latest.json
  cp "$DMG" "$DMG_SHA" docs/downloads/
  echo "staged $DMG + $ZIP + latest.json"
fi

npx --yes wrangler pages deploy docs --project-name astfind --branch main
