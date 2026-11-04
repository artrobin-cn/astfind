#!/bin/bash
# Publishes the staged Astfind npm packages: platform first, then the CLI.
#
#   ./npm/scripts/publish.sh              # normal (token or 2FA-exempt session)
#   ./npm/scripts/publish.sh 123456       # pass a current 6-digit OTP
#
# Requires a logged-in npm account with publish rights for astfind and
# @astfind/darwin-arm64. The platform package must be published first so the
# main package's optionalDependencies can resolve it.
set -euo pipefail
cd "$(dirname "$0")/../.."

ARTIFACTS="AstfindKit/build/npm/artifacts"
VERSION="$(node -p "require('./AstfindKit/build/npm/astfind/package.json').version")"
PLATFORM="$ARTIFACTS/astfind-darwin-arm64-$VERSION.tgz"
MAIN="$ARTIFACTS/astfind-$VERSION.tgz"
OTP=()
if [ "$#" -ge 1 ] && [ -n "$1" ]; then OTP=(--otp "$1"); fi

[ -f "$PLATFORM" ] || { echo "missing $PLATFORM; run node npm/scripts/stage.mjs" >&2; exit 1; }
[ -f "$MAIN" ] || { echo "missing $MAIN; run node npm/scripts/stage.mjs" >&2; exit 1; }

echo "== npm identity =="
npm whoami

echo "== publish platform package =="
npm publish "$PLATFORM" --access public "${OTP[@]}"

echo "== publish CLI package =="
npm publish "$MAIN" --access public "${OTP[@]}"

echo "== registry versions =="
npm view @astfind/darwin-arm64 version
npm view astfind version

echo "== install smoke test =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ASTFIND_INSTALL_ROOT="$TMP/root" npm install --prefix "$TMP" -g astfind >/dev/null
ASTFIND_INSTALL_ROOT="$TMP/root" "$TMP/bin/astfind" --verify
"$TMP/bin/astfind" --version 2>/dev/null || true

echo "npm publish complete"
