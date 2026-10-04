#!/bin/zsh
# Republish the Homebrew cask artifact for the CURRENT version —
# Matthew's standing rule: every s1 update ships a fresh tap zip.
#
#   ./scripts/republish-tap.sh [--no-build] [--dry-run]
#
# Flow:
#   1. Rebuild dist/S1.app (scripts/make-app.sh release) unless --no-build
#   2. Re-zip → sha256
#   3. Push the zip into the tap's releases/v<version>/ and commit FIRST —
#      the cask url pins to that artifact commit (raw.githubusercontent
#      edge-caches paths like main/…, a commit sha can never go stale)
#   4. Rewrite sha256 + the pinned commit inside Casks/s1.rb, commit, push
#
# Version comes from the built app's Info.plist (source of truth:
# S1Info.version). TAP_DIR points at a local tap checkout when set —
# otherwise the tap is cloned fresh into a temp dir (no stale state).
# Override the repo:  TAP_REPO=you/homebrew-tap ./scripts/republish-tap.sh
set -euo pipefail
cd "$(dirname "$0")/.."
TAP_REPO="${TAP_REPO:-Matthew-Eucaristo/homebrew-tap}"
BUILD=1
DRY=0
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        --dry-run)  DRY=1 ;;
        *) echo "usage: $0 [--no-build] [--dry-run]"; exit 2 ;;
    esac
done

# -- 1. build + zip --------------------------------------------------------------
if [[ $BUILD == 1 ]]; then
    ./scripts/make-app.sh release >/dev/null
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/S1.app/Contents/Info.plist)
ZIP="S1-${VERSION}-app.zip"
ditto -c -k --sequesterRsrc --keepParent dist/S1.app "dist/$ZIP"
ZIP_SHA=$(shasum -a 256 "dist/$ZIP" | awk '{print $1}')
HEAD=$(git rev-parse --short HEAD)
echo "s1 $VERSION @ $HEAD — zip sha256: $ZIP_SHA"
[[ $DRY == 1 ]] && { echo "[dry-run] stopping before the tap push"; exit 0; }

# -- 2. tap: artifact commit first ------------------------------------------------
TAP_DIR="${TAP_DIR:-}"
if [[ -z "$TAP_DIR" ]]; then
    TAP_DIR=$(mktemp -d)/tap
    git clone --quiet "https://github.com/$TAP_REPO" "$TAP_DIR"
fi
mkdir -p "$TAP_DIR/releases/v$VERSION"
cp "dist/$ZIP" "$TAP_DIR/releases/v$VERSION/"

cd "$TAP_DIR"
git add "releases/v$VERSION/$ZIP"
if git diff --cached --quiet; then
    ART_SHA=$(git rev-parse HEAD)
    echo "artifact unchanged — reusing pinned commit ${ART_SHA:0:7}"
else
    git commit --quiet -m "rebuild cask artifact at s1 $HEAD"
    ART_SHA=$(git rev-parse HEAD)
fi

# -- 3. cask: sha256 + url pinned to the artifact commit --------------------------
CASK="$TAP_DIR/Casks/s1.rb"
sed -i '' -E \
    -e "s|sha256 \"[a-f0-9]{64}\"|sha256 \"$ZIP_SHA\"|" \
    -e "s|$TAP_REPO/[a-f0-9]{40}|$TAP_REPO/$ART_SHA|" \
    "$CASK"
git add Casks/s1.rb
if git diff --cached --quiet; then
    echo "cask already current — nothing to publish"
else
    git commit --quiet -m "cask: s1 $VERSION @$HEAD — sha ${ZIP_SHA:0:8}, url pinned to ${ART_SHA:0:7}"
    git push --quiet
    echo "published $TAP_REPO — 'brew update && brew reinstall --cask s1' picks it up"
fi
