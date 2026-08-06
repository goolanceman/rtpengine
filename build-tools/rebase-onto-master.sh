#!/usr/bin/env bash
# Rebase the current feature branch onto origin/master.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

BASE_REF="${BASE_REF:-origin/master}"
REMOTE="${REMOTE:-origin}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${branch}" == "HEAD" ]]; then
  echo "error: detached HEAD; checkout a branch first" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty. Commit/stash changes before rebasing." >&2
  git status -sb
  exit 1
fi

echo "==> current branch: ${branch}"
echo "==> HEAD before:    $(git rev-parse --short HEAD)"
echo "==> fetching ${REMOTE}"
git fetch "${REMOTE}"

echo "==> base: ${BASE_REF} ($(git rev-parse --short "${BASE_REF}"))"
echo "==> rebasing ${branch} onto ${BASE_REF}"
git rebase "${BASE_REF}"

echo "==> HEAD after:     $(git rev-parse --short HEAD)"
echo "==> commits not in ${BASE_REF}:"
git log --oneline "${BASE_REF}..HEAD" || true
echo "Done."
