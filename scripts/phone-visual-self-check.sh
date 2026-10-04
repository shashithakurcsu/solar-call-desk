#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/swift-module-cache"
for MODE in debug release; do
  BUILD_DIR="$PROJECT_DIR/.build/self-checks/phone-visual-$MODE"
  mkdir -p "$BUILD_DIR"
  if [[ "$MODE" == debug ]]; then OPTIMIZATION=(-Onone -g); else OPTIMIZATION=(-O); fi
  FLAGS=(-swift-version 6 -target arm64-apple-macosx14.0 -parse-as-library "${OPTIMIZATION[@]}" -module-cache-path "$SWIFT_MODULECACHE_PATH")
  xcrun swiftc "${FLAGS[@]}" -emit-library -emit-module -module-name CallCore \
    Sources/CallCore/*.swift -o "$BUILD_DIR/libCallCore.dylib" -emit-module-path "$BUILD_DIR/CallCore.swiftmodule"
  xcrun swiftc "${FLAGS[@]}" -enable-testing -emit-library -emit-module -module-name PhoneControl \
    -I "$BUILD_DIR" -L "$BUILD_DIR" -lCallCore Sources/PhoneControl/*.swift \
    -o "$BUILD_DIR/libPhoneControl.dylib" -emit-module-path "$BUILD_DIR/PhoneControl.swiftmodule"
  xcrun swiftc "${FLAGS[@]}" -I "$BUILD_DIR" -L "$BUILD_DIR" -lCallCore -lPhoneControl \
    -Xlinker -rpath -Xlinker "$BUILD_DIR" scripts/PhoneVisualSelfCheck.swift \
    -o "$BUILD_DIR/PhoneVisualSelfCheck"
  print "Phone visual offline checks ($MODE):"
  "$BUILD_DIR/PhoneVisualSelfCheck" "$@"
done
