#!/bin/bash
# Upload a new community shader seed cache to GitHub Releases and update the
# hash in portable_setup.m automatically.
#
# Usage: ./scripts/upload_seed_cache.sh
#
# Reads the live pipeline cache from the MacVolvo installation, packages it
# with package_seed_cache.py, creates a new GitHub Release, and updates the
# URL + SHA256 in portable_setup.m so the next build picks it up.
set -euo pipefail

REPO="shuwax/MacVolvo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SETUP_M="$SCRIPT_DIR/portable_setup.m"
PACKAGE_PY="$SCRIPT_DIR/package_seed_cache.py"

# --- Locate live pipeline cache ---
CACHE_DIR="$HOME/Library/Application Support/MacVolvo/cache/pipelines"
if [ ! -d "$CACHE_DIR" ]; then
    echo "Error: pipeline cache not found at:"
    echo "  $CACHE_DIR"
    echo "Launch CS2 at least once to build some recipes first."
    exit 1
fi

RECIPE_COUNT=$(find "$CACHE_DIR" -name "*.json" -path "*/recipes/*" 2>/dev/null | wc -l | tr -d ' ')
echo "Found $RECIPE_COUNT recipes in live cache."
if [ "$RECIPE_COUNT" -eq 0 ]; then
    echo "Error: no recipes found. Play CS2 first to generate shader data."
    exit 1
fi

# --- Determine next version tag ---
LATEST=$(gh release list --repo "$REPO" --limit 20 --json tagName \
    | python3 -c "
import json, sys, re
tags = [r['tagName'] for r in json.load(sys.stdin) if re.match(r'seed-cache-v\d+$', r['tagName'])]
nums = [int(re.search(r'\d+', t).group()) for t in tags]
print(max(nums) + 1 if nums else 1)
")
TAG="seed-cache-v${LATEST}"
FILENAME="seed-cache.tar.gz"
TARBALL="/tmp/${TAG}-${FILENAME}"

echo "New release tag: $TAG"

# --- Package ---
echo ""
echo "Packaging seed cache..."
python3 "$PACKAGE_PY" "$CACHE_DIR" -o "$TARBALL"

# Capture SHA256 from script output
SHA256=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
SIZE_MB=$(du -sh "$TARBALL" | awk '{print $1}')
echo "SHA256: $SHA256  ($SIZE_MB)"

# --- Confirm before uploading ---
echo ""
read -r -p "Upload as $TAG to $REPO? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- Create GitHub Release ---
echo ""
echo "Creating release $TAG..."
gh release create "$TAG" "$TARBALL" \
    --repo "$REPO" \
    --title "Shader seed cache $TAG" \
    --notes "Community shader seed cache for CS2 on macOS.

$RECIPE_COUNT pipeline recipes collected from real CS2 gameplay sessions.
MacVolvo downloads this automatically on first CS2 launch.

SHA256: $SHA256"

URL="https://github.com/$REPO/releases/download/$TAG/$FILENAME"
echo "Released: $URL"

# --- Update portable_setup.m ---
echo ""
echo "Updating portable_setup.m..."

# Replace URL line
sed -i '' \
    "s|https://github.com/$REPO/releases/download/seed-cache-v[0-9]*/seed-cache.tar.gz|$URL|g" \
    "$SETUP_M"

# Replace SHA256 line (the 64-char hex string on the line after the URL)
OLD_SHA=$(grep -A1 "seed-cache.tar.gz" "$SETUP_M" | grep -o '[a-f0-9]\{64\}' | head -1)
if [ -n "$OLD_SHA" ]; then
    sed -i '' "s/$OLD_SHA/$SHA256/g" "$SETUP_M"
    echo "Updated hash: $OLD_SHA → $SHA256"
else
    echo "Warning: could not find old SHA256 in portable_setup.m — update it manually."
fi

# --- Commit and push ---
echo ""
cd "$ROOT"
git add scripts/portable_setup.m
git commit -m "Update shader seed cache to $TAG ($RECIPE_COUNT recipes)

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
git push shuwax main

echo ""
echo "Done. Seed cache $TAG is live."
echo "Next build of MacVolvo will download it automatically."
