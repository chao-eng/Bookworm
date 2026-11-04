#!/usr/bin/env bash
# Build Bookworm.app — wraps the SwiftPM executable in a proper macOS bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
# 默认产出 Universal 二进制，Apple Silicon 与 Intel Mac 都能直接运行。
# 可传入单个架构（如 ARCHS=arm64）以加快本地调试构建。
ARCHS="${ARCHS:-arm64 x86_64}"
APP_NAME="Bookworm"
BUNDLE_DIR="build/${APP_NAME}.app"
EXE_NAME="${APP_NAME}"   # 包内可执行文件名，须与 Info.plist 的 CFBundleExecutable 一致
INFO_PLIST="Resources/Info.plist"

ARCH_FLAGS=()
for arch in ${ARCHS}; do
  ARCH_FLAGS+=(--arch "${arch}")
done

echo "Building (${CONFIG}, ${ARCHS})…"
swift build -c "${CONFIG}" --disable-sandbox "${ARCH_FLAGS[@]}"

BIN_PATH="$(swift build -c "${CONFIG}" --disable-sandbox "${ARCH_FLAGS[@]}" --show-bin-path)"
EXE_PATH="${BIN_PATH}/${EXE_NAME}"

if [[ ! -f "${EXE_PATH}" ]]; then
  echo "Built executable not found at ${EXE_PATH}" >&2
  exit 1
fi

echo "Assembling ${BUNDLE_DIR}…"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${EXE_PATH}" "${BUNDLE_DIR}/Contents/MacOS/${EXE_NAME}"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/${EXE_NAME}"
cp "${INFO_PLIST}" "${BUNDLE_DIR}/Contents/Info.plist"

# Sparkle — SPM links against @rpath/Sparkle.framework. Embed the actual
# framework so the .app is self-contained, then add @executable_path/../
# Frameworks to the binary's rpath.
SPARKLE_FRAMEWORK="${BIN_PATH}/Sparkle.framework"
if [[ -d "${SPARKLE_FRAMEWORK}" ]]; then
  mkdir -p "${BUNDLE_DIR}/Contents/Frameworks"
  cp -R "${SPARKLE_FRAMEWORK}" "${BUNDLE_DIR}/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${BUNDLE_DIR}/Contents/MacOS/${EXE_NAME}" 2>/dev/null || true
fi

# App icon. CFBundleIconFile in Info.plist references "AppIcon", which the
# macOS Dock / Finder look up as AppIcon.icns in the bundle's Resources.
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
fi

# Copy SwiftPM-generated resource bundle if present.
RES_BUNDLE="${BIN_PATH}/Bookworm_Bookworm.bundle"
if [[ -d "${RES_BUNDLE}" ]]; then
  cp -R "${RES_BUNDLE}" "${BUNDLE_DIR}/Contents/Resources/"
fi

# Also copy the resources flat into Contents/Resources/ so Bundle.main can
# find them directly. This lets the hero view skip Bundle.module
# (whose initializer calls `fatalError` if the SPM bundle is missing from
# disk, which has been observed to SIGTRAP packaged .apps on some macOS
# versions). Copying twice costs a few hundred KB.
for r in Sources/Bookworm/Resources/*; do
  [[ -e "$r" ]] || continue
  cp -R "$r" "${BUNDLE_DIR}/Contents/Resources/"
done

# Ad-hoc codesign so Gatekeeper lets it run locally.
codesign --force --deep --sign - "${BUNDLE_DIR}" 2>/dev/null || true

echo "Done: ${BUNDLE_DIR}"
echo "Architectures: $(lipo -archs "${BUNDLE_DIR}/Contents/MacOS/${EXE_NAME}")"
echo "Run with: open ${BUNDLE_DIR}"
