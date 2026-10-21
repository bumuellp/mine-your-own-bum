#!/usr/bin/env bash
# ==============================================================================
# Helper script to sync downstream instances with upstream mine-your-own-bum
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

UPSTREAM_REPO="https://github.com/bumuellp/mine-your-own-bum.git"
UPSTREAM_REMOTE="upstream-template"

echo "Checking upstream remote configuration..."
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
	echo "Adding remote '${UPSTREAM_REMOTE}' -> ${UPSTREAM_REPO}..."
	git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_REPO"
fi

echo "Fetching upstream template changes..."
git fetch "$UPSTREAM_REMOTE" main

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "Merging upstream changes into '${CURRENT_BRANCH}'..."
git merge "${UPSTREAM_REMOTE}/main" --allow-unrelated-histories -m "chore(sync): merge upstream template updates"

echo "Template sync completed successfully."
