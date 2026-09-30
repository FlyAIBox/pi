#!/usr/bin/env bash
# Sync all tags and releases from upstream (earendil-works/pi) to fork (FlyAIBox/pi).
#
# - Tags: git fetch from upstream, force-push to origin.
# - Releases: copies title, notes, and prerelease flag via gh CLI.
#   Binary assets are NOT copied (they are large; download from upstream if needed).
#
# Requirements: git repo with 'origin' pointing at the fork, gh CLI logged in, jq.
# Idempotent: existing releases on the fork are skipped, safe to re-run.
set -euo pipefail

UPSTREAM="earendil-works/pi"
FORK="FlyAIBox/pi"

echo "=== Syncing tags from upstream ==="
if ! git remote get-url upstream &>/dev/null; then
  echo "Adding upstream remote..."
  git remote add upstream "https://github.com/${UPSTREAM}.git"
fi
git fetch upstream --tags
git push origin --tags --force
echo "Tags synced."

echo ""
echo "=== Syncing releases (metadata only, no assets) ==="

# All upstream release tags, oldest first. --limit must exceed total release count.
TAGS=$(gh release list --repo "$UPSTREAM" --limit 500 --json tagName --jq 'reverse | .[].tagName')

CREATED=0
SKIPPED=0

for tag in $TAGS; do
  if gh release view "$tag" --repo "$FORK" &>/dev/null; then
    echo "  skip   $tag"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "  create $tag ..."

  # Write JSON to a file. macOS /bin/sh echo expands \n inside the body
  # and turns valid JSON into a string with raw control characters.
  gh release view "$tag" --repo "$UPSTREAM" --json name,body,isPrerelease > /tmp/release-meta.json
  title=$(jq -r '.name' /tmp/release-meta.json)
  is_pre=$(jq -r '.isPrerelease' /tmp/release-meta.json)
  jq -r '.body' /tmp/release-meta.json > /tmp/release-notes.md

  pre_flag=""
  [ "$is_pre" = "true" ] && pre_flag="--prerelease"

  gh release create "$tag" \
    --repo "$FORK" \
    --title "$title" \
    --notes-file /tmp/release-notes.md \
    $pre_flag

  echo "  done   $tag"
  CREATED=$((CREATED + 1))
done

echo ""
echo "Done. Created: $CREATED  Skipped: $SKIPPED"
