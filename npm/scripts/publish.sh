#!/bin/bash
# Publishes the staged Astfind npm packages: platform first, then the CLI.
#
#   ./npm/scripts/publish.sh              # normal (token or 2FA-exempt session)
#   ./npm/scripts/publish.sh 123456       # pass a current 6-digit OTP
#
# Requires a logged-in npm account with publish rights for @artrobin/astfind and
# @artrobin/astfind-darwin-arm64. The platform package must be published first so
# the main package's optionalDependencies can resolve it.
set -euo pipefail
cd "$(dirname "$0")/../.."

ARTIFACTS="AstfindKit/build/npm/artifacts"
VERSION="$(node -p "require('./AstfindKit/build/npm/astfind/package.json').version")"
PLATFORM="$(find "$ARTIFACTS" -maxdepth 1 -type f -name '*darwin-arm64-*.tgz' | head -1)"
MAIN="$(find "$ARTIFACTS" -maxdepth 1 -type f -name '*astfind-*.tgz' | grep -v 'darwin-arm64' | head -1)"
OTP="${1:-}"

[ -f "$PLATFORM" ] || { echo "missing $PLATFORM; run node npm/scripts/stage.mjs" >&2; exit 1; }
[ -f "$MAIN" ] || { echo "missing $MAIN; run node npm/scripts/stage.mjs" >&2; exit 1; }

publish() {
  if [ -n "$OTP" ]; then
    npm publish "$1" --access public --otp "$OTP"
  else
    npm publish "$1" --access public
  fi
}

visible() {
  npm view "$1@$VERSION" version >/dev/null 2>&1
}

wait_visible() {
  local package="$1"
  for _ in 1 2 3 4 5 6; do
    if visible "$package"; then
      npm view "$package" version
      return 0
    fi
    sleep 10
  done
  echo "warning: $package@$VERSION is not visible yet; check the npm website" >&2
  return 1
}

echo "== npm identity =="
npm whoami

echo "== publish platform package =="
if visible "@artrobin/astfind-darwin-arm64"; then
  echo "@artrobin/astfind-darwin-arm64@$VERSION already published"
else
  publish "$PLATFORM"
fi

echo "== publish CLI package =="
if visible "@artrobin/astfind"; then
  echo "@artrobin/astfind@$VERSION already published"
else
  publish "$MAIN"
fi

echo "== registry versions =="
wait_visible "@artrobin/astfind-darwin-arm64" || true
wait_visible "@artrobin/astfind" || true

echo "== install smoke test =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if npm install --prefix "$TMP" -g "@artrobin/astfind@$VERSION" >/dev/null; then
  ASTFIND_INSTALL_ROOT="$TMP/root" "$TMP/bin/astfind" --verify
  "$TMP/bin/astfind" --version 2>/dev/null || true
else
  echo "warning: skipped smoke test because @artrobin/astfind@$VERSION is not installable yet" >&2
fi

echo "npm publish complete"
