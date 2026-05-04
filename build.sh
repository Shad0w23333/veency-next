#!/bin/bash
# Veency 构建脚本(独立 clang,不依赖 theos 的 makefile)
# 使用: ./build.sh           只编译 Veency.dylib
#       ./build.sh package   编译并打包成 .deb
set -e
cd "$(dirname "$0")"

SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
TARGET_VER=6.0
ARCH=armv7

# 前置检查
for f in libvncserver.dylib libsimulatetouch.dylib theos/lib/libsubstrate.dylib SimulateTouch/SimulateTouch.h SimulateKeyboard.h SpringBoardAccess.h SpringBoardAccess.c Tweak.mm; do
    [ -e "$f" ] || { echo "[build] 缺少: $f"; exit 1; }
done
[ -d theos/include ] || { echo "[build] 请先 unzip theos_includes.zip -d theos/"; exit 1; }
command -v ldid >/dev/null || { echo "[build] 请先 brew install ldid"; exit 1; }

echo "[build] SDK: $SDK"
echo "[build] 编译 Tweak.mm → Veency.dylib  (arch=$ARCH, min iOS $TARGET_VER)..."

clang++ \
    -arch "$ARCH" \
    -isysroot "$SDK" \
    -miphoneos-version-min="$TARGET_VER" \
    -I theos/include \
    -I theos/include/_fallback \
    -I . \
    -dynamiclib \
    -fno-objc-arc \
    -fobjc-abi-version=2 \
    -fno-common \
    -O2 \
    -Wno-deprecated-declarations \
    -Wno-deprecated-objc-isa-usage \
    -Wno-objc-method-access \
    -Wno-incompatible-pointer-types \
    -Wno-format \
    -Wl,-undefined,dynamic_lookup \
    -Wl,-weak_reference_mismatches,weak \
    -L. -lvncserver -lsimulatetouch \
    -L./theos/lib -lsubstrate \
    -framework UIKit \
    -framework Foundation \
    -framework CoreFoundation \
    -framework CoreGraphics \
    -framework IOKit \
    -framework QuartzCore \
    -o Veency.dylib \
    Tweak.mm

ldid -S Veency.dylib
echo "[build] 已生成 Veency.dylib:"
file Veency.dylib | sed 's/^/    /'

if [ "$1" = "package" ]; then
    echo "[build] 打包 .deb..."
    command -v dpkg-deb >/dev/null || { echo "请先 brew install dpkg"; exit 1; }

    PKG=pkg-build
    rm -rf "$PKG"
    mkdir -p "$PKG/DEBIAN" \
             "$PKG/Library/MobileSubstrate/DynamicLibraries" \
             "$PKG/Library/PreferenceLoader/Preferences" \
             "$PKG/System/Library/CoreServices/SpringBoard.app"
    cp control "$PKG/DEBIAN/control"
    cp Veency.dylib "$PKG/Library/MobileSubstrate/DynamicLibraries/Veency.dylib"
    cp Tweak.plist  "$PKG/Library/MobileSubstrate/DynamicLibraries/Veency.plist"
    cp PreferenceLoader/Preferences/Veency.plist     "$PKG/Library/PreferenceLoader/Preferences/Veency.plist"
    cp PreferenceLoader/Preferences/VeencyIcon.png   "$PKG/Library/PreferenceLoader/Preferences/VeencyIcon.png"
    cp Default_Veency.png FSO_Veency.png             "$PKG/System/Library/CoreServices/SpringBoard.app/"

    VER=$(grep '^Version:' control | awk '{print $2}')
    OUT="veency_${VER}_iphoneos-arm.deb"
    dpkg-deb -Zgzip -b "$PKG" "$OUT"
    echo "[build] 已生成 $OUT"
fi
