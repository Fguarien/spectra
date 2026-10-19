#!/usr/bin/env bash
# make-app.sh — build Spectra and assemble a runnable Spectra.app bundle.
# Reproducible from source: SwiftPM build + bundle layout, no .xcodeproj.
# Usage: ./make-app.sh [debug|release] [--install]
#   --install  also copy the built app into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
INSTALL=0
for a in "$@"; do
  case "$a" in
    debug|release) CONFIG="$a" ;;
    --install) INSTALL=1 ;;
  esac
done

APP="Spectra.app"
BUILD_DIR=".build/${CONFIG}"
ICNS="Resources/AppIcon.icns"

echo "▸ swift build (${CONFIG})"
swift build -c "${CONFIG}"

BIN="${BUILD_DIR}/Spectra"
[ -x "${BIN}" ] || { echo "build produced no executable at ${BIN}"; exit 1; }

# App icon — generate once from the reproducible CoreGraphics generator.
if [ ! -f "${ICNS}" ]; then
  echo "▸ generating app icon"
  ISET="$(mktemp -d)/Spectra.iconset"
  swift Tools/make-icon.swift "${ISET}" >/dev/null
  iconutil -c icns "${ISET}" -o "${ICNS}"
fi

echo "▸ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Spectra"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
[ -f "${ICNS}" ] && cp "${ICNS}" "${APP}/Contents/Resources/AppIcon.icns"
# Bundle the GRDB resource bundle if SwiftPM produced one.
for b in "${BUILD_DIR}"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "${APP}/Contents/Resources/" || true
done

echo "▸ ad-hoc codesign (local run: Keychain + network)"
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || echo "  (codesign skipped)"

if [ "${INSTALL}" -eq 1 ]; then
  echo "▸ installing to /Applications"
  rm -rf "/Applications/${APP}"
  cp -R "${APP}" "/Applications/${APP}"
  echo "✓ installed /Applications/${APP}"
fi

echo "✓ ${APP} ready — open with: open ${APP}"
