#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
[ -d "$SDK" ] || { echo "iOS SDK がありません"; exit 1; }

clang -x objective-c -fobjc-arc -O2 \
  -dynamiclib -arch arm64 \
  -isysroot "$SDK" -miphoneos-version-min=14.0 \
  -install_name @executable_path/bsdodge.dylib \
  -framework Foundation -framework UIKit -framework QuartzCore \
  -o bsdodge.dylib bsdodge.m

codesign -f -s - bsdodge.dylib 2>/dev/null || ldid -S bsdodge.dylib

echo "--- OK ---"
file bsdodge.dylib
otool -L bsdodge.dylib
shasum -a 256 bsdodge.dylib
