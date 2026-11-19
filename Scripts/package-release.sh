#!/bin/zsh
set -euo pipefail

VERSION="${1:-0.3.0}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/.build/release-derived"
STAGE="$ROOT/.build/release-staging"
DIST="$ROOT/.build/release-dist"
DMG_NAME="PinCite-${VERSION}-macOS-adhoc.dmg"
DMG_PATH="$DIST/$DMG_NAME"

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"

echo "== 1/5 Build macOS Release app (ad-hoc / unsigned) =="
xcodebuild \
  -project app/LiteratureSearch.xcodeproj \
  -scheme LiteratureSearch \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_SRC="$DERIVED/Build/Products/Release/LiteratureSearch.app"
if [ ! -d "$APP_SRC" ]; then
  echo "error: built app bundle not found at $APP_SRC" >&2
  exit 1
fi

echo "== 2/5 Stage app and apply ad-hoc signature =="
cp -R "$APP_SRC" "$STAGE/LiteratureSearch.app"
codesign --force --deep --sign - "$STAGE/LiteratureSearch.app"
ln -s /Applications "$STAGE/Applications"

echo "== 3/5 Build CLI and generate synthetic QuickStart PDF =="
swift build -c release --product literaturesearch-cli
CLI_BIN="$(swift build -c release --show-bin-path)/literaturesearch-cli"
"$CLI_BIN" genpdf \
  --out "$STAGE/PinCite-QuickStart.pdf" \
  --page "PinCite Quick Start (Page 1): Local-first archival search without cloud uploads." \
  --page "PinCite Quick Start (Page 2): pinpoint citation anchor and 页码三分离 verification." \
  --page "PinCite Quick Start (Page 3): 21 citation formats, highlights stay in your own DB."

cat > "$STAGE/FIRST-RUN.txt" <<EOF
PinCite v${VERSION} — Ad-hoc Preview Build
===========================================

1. Drag LiteratureSearch.app (displayed as PinCite) to Applications.
2. This release uses ad-hoc signing without Apple notarization. Before opening
   from Finder for the first time, either Control-click -> Open or run:

     xattr -cr /Applications/LiteratureSearch.app

3. Quick test with zero real books needed:
   Copy PinCite-QuickStart.pdf into a folder, select that folder inside PinCite,
   click Index, and search for "pinpoint" or "页码三分离" to verify page-2 jump-back.
EOF

echo "== 4/5 Create DMG =="
rm -f "$DMG_PATH"
hdiutil create \
  -volname "PinCite ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "== 5/5 Write SHA-256 checksums =="
(
  cd "$DIST"
  shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt
)

rm -rf "$STAGE"
echo "Packaged: $DMG_PATH"
cat "$DIST/SHA256SUMS.txt"
