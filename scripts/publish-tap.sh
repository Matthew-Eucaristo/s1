#!/bin/zsh
# One-command Homebrew tap publish:
#   ./scripts/publish-tap.sh 0.2.0
#
# What it does, in order:
#   1. Builds and signs the release artifact locally (scripts/make-app.sh;
#      refuses ad-hoc so TCC grants survive upgrades): S1.app zip —
#      the bundle carries BOTH the GUI (Contents/MacOS/S1) and the CLI
#      (Contents/Resources/s1) that the cask links onto PATH.
#   2. Uploads the zip to GitHub Release v<version> (creates it if missing);
#      without `gh` auth it rides inside the tap repo under releases/.
#   3. Clones the tap repo, writes Casks/s1.rb with the real version +
#      sha256, commits and pushes.
#
# Prerequisites (one-time):
#   - git tag pushed:   git tag v0.2.0 && git push origin v0.2.0
#   - tap repo exists:  github.com/Matthew-Eucaristo/homebrew-tap
#
# Override the tap location:  TAP_REPO=you/homebrew-tap ./scripts/publish-tap.sh 0.2.0
set -euo pipefail
VERSION="${1:?usage: ./scripts/publish-tap.sh <version>  e.g. 0.2.0}"
cd "$(dirname "$0")/.."
REPO="Matthew-Eucaristo/s1"
TAP_REPO="${TAP_REPO:-Matthew-Eucaristo/homebrew-tap}"
TAG="v${VERSION}"

ZIP="S1-${VERSION}-app.zip"

# -- 0. what gets published is exactly the tagged, versioned source --------------
if [[ -n "$(git status --porcelain)" ]]; then
    echo "!! the working tree has changes — publish from a clean checkout of $TAG" >&2
    exit 1
fi
if [[ "$(git describe --exact-match --tags HEAD 2>/dev/null)" != "$TAG" ]]; then
    echo "!! HEAD isn't tagged $TAG — check out the tag (or tag this commit) first" >&2
    exit 1
fi
CODE_VERSION=$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/S1Core/S1.swift)
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Sources/S1App/Info.plist)
if [[ "$CODE_VERSION" != "$VERSION" || "$PLIST_VERSION" != "$VERSION" ]]; then
    echo "!! version mismatch: S1Info.version=$CODE_VERSION, Info.plist=$PLIST_VERSION, asked $VERSION" >&2
    exit 1
fi

# -- 1. artifact ---------------------------------------------------------------
# Always build and sign locally: CI's zip is ad-hoc signed, and macOS keys
# Screen Recording/Accessibility grants to the signature — shipping it would
# make every upgrade ask for permissions again. This zip replaces CI's.
./scripts/make-app.sh release
# Captured first, matched after: `codesign | grep -q` can lose the match to
# SIGPIPE under pipefail and let an ad-hoc build through.
SIG=$(codesign -dvv dist/S1.app 2>&1 || true)
if [[ "$SIG" == *"Signature=adhoc"* || "$SIG" != *"Authority="* ]]; then
    echo "!! dist/S1.app is ad-hoc signed — set S1_SIGN_IDENTITY to a real identity" >&2
    exit 1
fi
rm -f "dist/$ZIP" "dist/$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent dist/S1.app "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > "$ZIP.sha256")
ZIP_SHA=$(awk '{print $1}' "dist/$ZIP.sha256")
echo "app zip sha256: $ZIP_SHA"

# -- 2. artifact hosting --------------------------------------------------------
RELEASE_URLS=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    RELEASE_URLS=1
    # CI's release job uploads its own (ad-hoc) zip under the same name —
    # let it finish first, or it overwrites this upload after the cask
    # already carries this zip's sha.
    RUN_ID=""
    for _ in 1 2 3 4 5 6; do
        RUN_ID=$(gh run list --repo "$REPO" --workflow release.yml --branch "$TAG" --limit 1 \
            --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
        [[ -n "$RUN_ID" ]] && break
        sleep 10
    done
    if [[ -n "$RUN_ID" ]]; then
        echo "waiting for CI's release run $RUN_ID to finish…"
        gh run watch "$RUN_ID" --repo "$REPO" --exit-status >/dev/null \
            || echo "!! CI's release run didn't succeed — this upload is the release asset now"
    else
        echo "!! no CI release run found for $TAG — uploading anyway"
    fi
    PRERELEASE=()
    [[ "$VERSION" == 0.* ]] && PRERELEASE=(--prerelease)   # same rule as CI: v0.x is beta
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        gh release upload "$TAG" "dist/$ZIP" "dist/$ZIP.sha256" --repo "$REPO" --clobber
        echo "uploaded to existing release $TAG"
    else
        gh release create "$TAG" "dist/$ZIP" "dist/$ZIP.sha256" --repo "$REPO" \
            --title "s1 $VERSION" --generate-notes "${PRERELEASE[@]}"
        echo "created release $TAG"
    fi
else
    echo "!! gh not authenticated — artifact goes into the tap repo instead"
fi

# -- 3. tap repo ---------------------------------------------------------------
TAP_DIR=$(mktemp -d)/tap
git clone "https://github.com/$TAP_REPO" "$TAP_DIR"
mkdir -p "$TAP_DIR/Casks" "$TAP_DIR/releases/$TAG"

if [[ $RELEASE_URLS == 1 ]]; then
    ZIP_URL="https://github.com/$REPO/releases/download/$TAG/S1-#{version}-app.zip"
else
    cp "dist/$ZIP" "$TAP_DIR/releases/$TAG/"
    # Commit the artifact FIRST so the cask URL can pin to the commit sha —
    # raw.githubusercontent.com/.../main/... edge-caches large files and
    # keeps serving the previous zip long after push.
    cd "$TAP_DIR"
    git add "releases/$TAG"
    git diff --cached --quiet || git commit -m "s1 $VERSION artifact"
    ART_SHA=$(git rev-parse HEAD)
    cd - >/dev/null
    ZIP_URL="https://raw.githubusercontent.com/$TAP_REPO/$ART_SHA/releases/$TAG/S1-#{version}-app.zip"
fi

cat > "$TAP_DIR/Casks/s1.rb" <<EOF
# Generated by s1's scripts/publish-tap.sh — regenerate, don't hand-edit.
cask "s1" do
  version "$VERSION"
  sha256 "$ZIP_SHA"

  url "$ZIP_URL"
  name "s1"
  desc "Voice-first agent — menu-bar companion (System 1 + System 2), CLI included"
  homepage "https://github.com/$REPO"

  depends_on macos: :tahoe

  app "S1.app"
  # The CLI ships inside the bundle (Contents/Resources/s1) — brew links it
  # into HOMEBREW_PREFIX/bin so \`s1\` works on PATH from the same install.
  binary "#{appdir}/S1.app/Contents/Resources/s1"

  # No \`launchctl:\` here: brew checks every listed label in the system
  # domain with sudo (a password prompt on each upgrade), and s1's optional
  # listener is a per-user agent. Upgrades must leave it running; --zap
  # boots it out as the user, no sudo.
  uninstall quit: ["com.mattheweuc.s1", "com.matthew.s1.app"]

  zap script: {
        executable:   "/bin/launchctl",
        args:         ["bootout", "gui/#{Process.uid}/com.matthew.s1.serve"],
        must_succeed: false,
        print_stderr: false,
      },
      trash:  [
        "~/.s1",
        "~/Library/Application Scripts/com.matthew.s1.app",
        "~/Library/Application Scripts/com.mattheweuc.s1",
        "~/Library/Containers/com.matthew.s1.app",
        "~/Library/Containers/com.mattheweuc.s1",
        "~/Library/HTTPStorages/com.matthew.s1.app",
        "~/Library/HTTPStorages/com.mattheweuc.s1",
        "~/Library/LaunchAgents/com.matthew.s1.serve.plist",
        "~/Library/LaunchAgents/sh.brew.s1.plist",
        "~/Library/Preferences/com.matthew.s1.app.plist",
        "~/Library/Preferences/com.mattheweuc.s1.plist",
        "~/Library/Saved Application State/com.matthew.s1.app.savedState",
        "~/Library/Saved Application State/com.mattheweuc.s1.savedState",
      ]

  caveats <<~EOS
    Developer-signed but not notarized, so macOS blocks the first open.
    Install with \`brew install --cask --no-quarantine s1\`, or once:
      xattr -dr com.apple.quarantine /Applications/S1.app
    Then open S1: setup asks for Accessibility (required) and, if you want
    them, Microphone, Input Monitoring and Screen Recording.
    S1 lives in the menu bar; ⇧⇧ works anywhere while it runs
    (Settings → General → Open s1 at login).

      Terminal only, no app:   s1 serve --install   (a per-user launchd listener)
      Full reset:              brew uninstall --cask s1 --zap
  EOS
end
EOF

cd "$TAP_DIR"
git add Casks/s1.rb
if git diff --cached --quiet; then
    echo "tap already at $VERSION — nothing to publish"
else
    git commit -m "s1 $VERSION"
    git push
    echo "published $TAP_REPO @ $VERSION"
fi

cat <<MSG

Done. Users install with:
  brew tap ${TAP_REPO/homebrew-/}
  brew install --cask s1      # GUI + \`s1\` CLI (linked from inside the app)

Clean removal:
  brew uninstall --cask s1            # quits + removes /Applications/S1.app
  brew uninstall --cask s1 --zap      # + wipes ~/.s1 and Library traces
MSG
