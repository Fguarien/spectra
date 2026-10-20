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

# Signature. Ad hoc, the designated requirement is the cdhash, which changes
# on every build, so the Keychain asks again for every stored secret after
# each install. A stable identity avoids that:
#   - SPECTRA_SIGN_ID=<identity> uses any code-signing identity you have;
#   - otherwise, if ~/Library/Keychains/spectra-signing.keychain-db exists
#     (see Tools/make-signing-keychain.sh), its « Spectra Local Signing »
#     certificate is used — that keychain unlocks without interaction, so it
#     also works over SSH, where the login keychain's keys are out of reach;
#   - otherwise ad hoc.
SIGN_KC="${HOME}/Library/Keychains/spectra-signing.keychain-db"
SIGN_ID="${SPECTRA_SIGN_ID:-}"
KC_ARGS=()
if [ -z "${SIGN_ID}" ] && [ -f "${SIGN_KC}" ]; then
  security unlock-keychain -p "" "${SIGN_KC}" 2>/dev/null || true
  SIGN_ID="$(security find-identity -p codesigning "${SIGN_KC}" 2>/dev/null | awk '/Spectra Local Signing/ {print $2; exit}')"
  [ -n "${SIGN_ID}" ] && KC_ARGS=(--keychain "${SIGN_KC}")
fi
if [ -n "${SIGN_ID}" ] && codesign --force --deep ${KC_ARGS[@]+"${KC_ARGS[@]}"} --sign "${SIGN_ID}" "${APP}" >/dev/null 2>&1; then
  echo "▸ codesigned (stable identity ${SIGN_ID})"
else
  echo "▸ ad-hoc codesign — the Keychain will ask again after each build"
  codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || echo "  (codesign skipped)"
fi

if [ "${INSTALL}" -eq 1 ]; then
  echo "▸ installing to /Applications"
  rm -rf "/Applications/${APP}"
  cp -R "${APP}" "/Applications/${APP}"
  echo "✓ installed /Applications/${APP}"
fi

echo "✓ ${APP} ready — open with: open ${APP}"
