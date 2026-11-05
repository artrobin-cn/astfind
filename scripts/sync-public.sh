#!/bin/bash
# Generates a sanitized public snapshot from the private repo HEAD.
#
#   ./scripts/sync-public.sh ../astfind-public
#   ./scripts/sync-public.sh --push ../astfind-public
#   ./scripts/sync-public.sh --dry-run ../astfind-public
#
# The private repo must be clean and committed. The public repo must have
# origin pointing at artrobin-cn/astfind (not astfind-private).
set -euo pipefail
PRIVATE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PRIVATE"

PUSH=0
DRY_RUN=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *)
      if [ -n "$TARGET" ]; then echo "only one target path is supported" >&2; exit 1; fi
      TARGET="$arg"
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "usage: $0 [--push] [--dry-run] <public-repo-path>" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "private worktree is not clean; commit first:" >&2
  git status --short >&2
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"
if ! git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not a git repository: $TARGET" >&2
  exit 1
fi

REMOTE="$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)"
case "$REMOTE" in
  *astfind-private*)
    echo "refusing to sync into the private repo: $REMOTE" >&2
    exit 1
    ;;
  *artrobin-cn/astfind*)
    ;;
  *)
    echo "unexpected public remote: ${REMOTE:-<none>}" >&2
    echo "expected origin to point at artrobin-cn/astfind" >&2
    exit 1
    ;;
esac

BRANCH="$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || true)"
if [ "$BRANCH" != "main" ]; then
  echo "public repo must be on main (currently: ${BRANCH:-detached})" >&2
  exit 1
fi

if [ -n "$(git -C "$TARGET" status --porcelain)" ]; then
  echo "public worktree is not clean; refusing to overwrite local changes:" >&2
  git -C "$TARGET" status --short >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/astfind-public-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

git archive HEAD | tar -x -C "$STAGE"
rm -rf "$STAGE/tasks" "$STAGE/docs/superpowers"
rm -f "$STAGE"/AstfindKit/docs/m06-*.md

SENSITIVE_PATTERN='20240821教师入职|BDCM|GcupNas|bandacmdata|10834874|0\.9682|0\.8992|0\.8757|李胜彬|李永峰|/Users/ailabos|202\.116\.136\.43'
if grep -RIn -E "$SENSITIVE_PATTERN" "$STAGE" \
  --exclude="sync-public.sh" >/tmp/astfind-public-sensitive.txt 2>/dev/null; then
  echo "sensitive strings found; refusing to sync:" >&2
  head -40 /tmp/astfind-public-sensitive.txt >&2
  exit 1
fi
rm -f /tmp/astfind-public-sensitive.txt

if [ "$DRY_RUN" = 1 ]; then
  echo "== dry run: $PRIVATE -> $TARGET =="
  rsync -a --delete --dry-run --itemize-changes --exclude='.git' "$STAGE/" "$TARGET/"
  exit 0
fi

rsync -a --delete --exclude='.git' "$STAGE/" "$TARGET/"

cd "$TARGET"
git add -A
if git diff --cached --quiet; then
  echo "public snapshot is already up to date"
  exit 0
fi

SNAPSHOT="$(git -C "$PRIVATE" describe --tags --always 2>/dev/null || echo snapshot)"
git -c user.name='Astfind' -c user.email='astfind@users.noreply.github.com' \
  commit -m "release: public snapshot $SNAPSHOT"
git show --stat --oneline HEAD

if [ "$PUSH" = 1 ]; then
  git push origin main
  echo "pushed public snapshot to origin/main"
else
  echo "public snapshot committed locally; run with --push to publish"
fi
