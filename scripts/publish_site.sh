#!/bin/sh
# Publish site/ to the gh-pages branch (GitHub Pages serves it at https://bumpcast.app).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
# The Learn pages are built from the app's explainers; stop if they are out of date.
python3 "$root/scripts/build_learn.py" --check
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$root" fetch -q origin gh-pages
git -C "$root" worktree add -q "$tmp/pages" origin/gh-pages --detach
rsync -a --delete --exclude README.md --exclude .git "$root/site/" "$tmp/pages/"
cd "$tmp/pages"
git add -A
if git diff --cached --quiet; then echo "Nothing to publish."; else
  git commit -qm "Publish site $(date +%Y-%m-%d)"
  git push -q origin HEAD:gh-pages
  echo "Published. Live in about a minute at https://bumpcast.app"
fi
cd "$root"; git worktree remove --force "$tmp/pages"
