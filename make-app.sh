#!/usr/bin/env bash
# make-app.sh — build Spectra and assemble a runnable Spectra.app bundle.
# Reproducible from source: SwiftPM build + bundle layout, no .xcodeproj.
# Usage: ./make-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Spectra.app"
BUILD_DIR=".build/${CONFIG}"

echo "▸ swift build (${CONFIG})"
swift build -c "${CONFIG}"

BIN="${BUILD_DIR}/Spectra"
[ -x "${BIN}" ] || { echo "build produced no executable at ${BIN}"; exit 1; }

echo "▸ assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Spectra"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
# Bundle the GRDB resource bundle if SwiftPM produced one.
for b in "${BUILD_DIR}"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "${APP}/Contents/Resources/" || true
done

echo "▸ ad-hoc codesign (local run: Keychain + network)"
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ ${APP} ready — open with: open ${APP}"
