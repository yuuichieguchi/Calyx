#!/bin/bash
set -euo pipefail

VERSION=$(grep 'MARKETING_VERSION' project.yml | grep -v '\$(' | sed 's/.*"\(.*\)"/\1/')
APP_PATH="/tmp/CalyxRelease/Build/Products/Release/Calyx.app"
ZIP_PATH="/tmp/Calyx.zip"

echo "=== Calyx Release v$VERSION ==="

# 1. Check required env vars
echo "Checking required environment variables..."
: "${APPLE_API_KEY:?APPLE_API_KEY is not set}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is not set}"
: "${APPLE_API_ISSUER:?APPLE_API_ISSUER is not set}"
echo "All required environment variables are set."

# 2. Generate Xcode project
echo "Generating Xcode project..."
xcodegen generate
echo "Xcode project generated."

# 3. Build
echo "Building Calyx (Release)..."
xcodebuild \
  -project Calyx.xcodeproj \
  -scheme Calyx \
  -configuration Release \
  CODE_SIGN_IDENTITY="Developer ID Application: Yuuichi Eguchi (PQQBSRKD72)" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=PQQBSRKD72 \
  -derivedDataPath /tmp/CalyxRelease \
  clean build
echo "Build succeeded."

# 4. Zip for notarization
echo "Creating zip for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "Zip created at $ZIP_PATH."

# 5. Submit for notarization
echo "Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
  --key "$APPLE_API_KEY" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER" \
  --wait
echo "Notarization complete."

# 6. Staple
echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
echo "Stapling complete."

# 7. Re-zip with staple
echo "Creating final zip with stapled ticket..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "Final zip created at $ZIP_PATH."

# 7.5. Sparkle EdDSA signing (must be AFTER re-zip so signature matches the final artifact)
echo "Signing final zip with Sparkle EdDSA..."
SPARKLE_SIGN=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/Sparkle/bin/*" 2>/dev/null | head -1)
if [ -z "$SPARKLE_SIGN" ]; then
  echo "ERROR: sign_update not found. Cannot sign for Sparkle."
  echo "Build Sparkle tools first: swift build -c release --package-path path/to/Sparkle"
  exit 1
fi
SPARKLE_SIG=$("$SPARKLE_SIGN" "$ZIP_PATH")
echo "Sparkle signature: $SPARKLE_SIG"

# 8. Push to remote
echo "Pushing to origin main..."
git push origin main
echo "Push complete."

# 9. Create GitHub release
echo "Creating GitHub release v$VERSION..."
git fetch --tags --force
PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")
if [ -n "$PREV_TAG" ]; then
  NOTES=$(git log --pretty=format:"- %s" "$PREV_TAG"..HEAD)
else
  NOTES=$(git log --pretty=format:"- %s")
fi
RELEASE_BODY="## What's Changed
$NOTES"
gh release create "v$VERSION" "$ZIP_PATH" \
  --title "Calyx v$VERSION" \
  --notes "$RELEASE_BODY"
echo "GitHub release v$VERSION created."

# 10. Generate and push appcast
echo "Generating appcast..."
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" -path "*/Sparkle/bin/*" 2>/dev/null | head -1)
if [ -n "$GENERATE_APPCAST" ]; then
  APPCAST_DIR="/tmp/CalyxAppcast"
  mkdir -p "$APPCAST_DIR"
  cp "$ZIP_PATH" "$APPCAST_DIR/"
  "$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/yuuichieguchi/Calyx/releases/download/v$VERSION/" \
    "$APPCAST_DIR"

  # Push appcast to gh-pages
  if [ -f "$APPCAST_DIR/appcast.xml" ]; then
    REPO_DIR=$(pwd)
    TMPDIR=$(mktemp -d)
    git clone --branch gh-pages --single-branch "$(git remote get-url origin)" "$TMPDIR" 2>/dev/null || {
      git clone "$(git remote get-url origin)" "$TMPDIR"
      cd "$TMPDIR"
      git checkout --orphan gh-pages
      git rm -rf . 2>/dev/null || true
      cd "$REPO_DIR"
    }
    cp "$APPCAST_DIR/appcast.xml" "$TMPDIR/appcast.xml"
    cd "$TMPDIR"
    git add appcast.xml
    git commit -m "Update appcast for v$VERSION" || true
    git push origin gh-pages || echo "Warning: Failed to push appcast. Push manually."
    cd "$REPO_DIR"
    rm -rf "$TMPDIR"
  fi
  rm -rf "$APPCAST_DIR"
else
  echo "ERROR: generate_appcast not found. Cannot generate appcast."
  echo "Build Sparkle tools first: swift build -c release --package-path path/to/Sparkle"
  exit 1
fi

echo "=== Release v$VERSION complete ==="
