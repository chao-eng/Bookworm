#!/usr/bin/env bash
# Build a distributable Bookworm-<version>.dmg.
#
# Reads the version from build/Bookworm.app/Contents/Info.plist
# (CFBundleShortVersionString). Stages the .app next to a symlink to
# /Applications so the standard "drag this icon to that icon" install gesture
# works, then wraps the staging folder with hdiutil.
#
# Usage:
#   ./scripts/build-app.sh      # build the .app first
#   ./scripts/make-dmg.sh       # then this

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Bookworm"
APP_PATH="build/${APP_NAME}.app"
DMG_DIR="build"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "build/${APP_NAME}.app not found — run ./scripts/build-app.sh first." >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
DMG_PATH="${DMG_DIR}/${APP_NAME}-${VERSION}.dmg"
VOL_NAME="${APP_NAME} ${VERSION}"

# Stage the contents of the volume in a clean temp dir so hdiutil only sees
# what we want shipped (the .app + an Applications shortcut).
STAGE=$(mktemp -d -t bookworm-dmg)
trap "rm -rf '${STAGE}'" EXIT

cp -R "${APP_PATH}" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"

# Re-sign the .app (ad-hoc) after the copy so the embedded frameworks keep
# their signature inside the DMG.
codesign --force --deep --sign - "${STAGE}/${APP_NAME}.app" 2>/dev/null || true

rm -f "${DMG_PATH}"
echo "Building ${DMG_PATH}…"
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "${DMG_PATH}" >/dev/null

# Sign the DMG itself ad-hoc so Gatekeeper at least knows it hasn't been
# tampered with after creation. Notarisation still has to be done separately
# if you want zero quarantine prompts.
codesign --force --sign - "${DMG_PATH}" 2>/dev/null || true

SIZE=$(du -h "${DMG_PATH}" | cut -f1)
echo "Wrote ${DMG_PATH} (${SIZE})"
