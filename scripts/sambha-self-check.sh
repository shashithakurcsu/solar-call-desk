#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/swift-module-cache"
for MODE in debug release; do
  if [[ "$MODE" == debug ]]; then OPT=(-Onone -g); else OPT=(-O); fi
  CHECK_DIR="$PROJECT_DIR/.build/sambha-check-$MODE"
  mkdir -p "$CHECK_DIR"
  xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 "${OPT[@]}" -parse-as-library -whole-module-optimization \
    -module-name CallCore -emit-module -emit-module-path "$CHECK_DIR/CallCore.swiftmodule" -emit-object Sources/CallCore/*.swift -o "$CHECK_DIR/CallCore.o"
  xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 "${OPT[@]}" -parse-as-library -whole-module-optimization -I "$CHECK_DIR" \
    -module-name CallAutomation -emit-module -emit-module-path "$CHECK_DIR/CallAutomation.swiftmodule" -emit-object Sources/CallAutomation/*.swift -o "$CHECK_DIR/CallAutomation.o"
  xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 "${OPT[@]}" -parse-as-library -I "$CHECK_DIR" \
    "$CHECK_DIR/CallCore.o" "$CHECK_DIR/CallAutomation.o" scripts/SambhaSelfCheck.swift -o "$CHECK_DIR/SambhaSelfCheck"
  "$CHECK_DIR/SambhaSelfCheck"
done
