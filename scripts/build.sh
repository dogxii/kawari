#!/bin/bash
# 构建 build/kawari.app（默认 Apple Silicon）
#   --universal  同时编译 arm64 与 x86_64（Intel）
#   --dmg        额外生成 build/kawari-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64)
DMG=0
for arg in "$@"; do
    case "$arg" in
        --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
        --dmg) DMG=1 ;;
        *) echo "未知参数：$arg" >&2; exit 1 ;;
    esac
done

# -Osize 配合链接时优化（LTO）可省约 9% 代码；不需要调试信息
FLAGS=(-c release --experimental-lto-mode=full -Xswiftc -Osize -Xswiftc -gnone "${ARCHS[@]}")
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/Kawari"

APP=build/kawari.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kawari"
strip -x "$APP/Contents/MacOS/Kawari"
cp Support/Info.plist "$APP/Contents/"
cp Support/AppIcon.icns "$APP/Contents/Resources/"
cp -R Support/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP" 2>/dev/null
codesign --verify --strict "$APP"

echo "$APP  $(du -sh "$APP" | cut -f1)  [$(lipo -archs "$APP/Contents/MacOS/Kawari")]"

if [[ $DMG == 1 ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    # HFS+：体积稳定且最小（APFS 会随机多出约 160 KB）
    hdiutil create -quiet -volname kawari -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "build/kawari-$VERSION.dmg"
    rm -rf "$STAGE"
    echo "build/kawari-$VERSION.dmg  $(( $(stat -f%z "build/kawari-$VERSION.dmg") / 1024 ))K"
fi
