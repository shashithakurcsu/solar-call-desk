#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/swift-module-cache"
mkdir -p "$PROJECT_DIR/.build/self-checks"
xcrun swiftc -parse-as-library Sources/CallCore/*.swift scripts/CoreSelfCheck.swift -o .build/self-checks/CoreSelfCheck
.build/self-checks/CoreSelfCheck
"$PROJECT_DIR/scripts/voice-self-check.sh"

"$PROJECT_DIR/scripts/sambha-self-check.sh"

"$PROJECT_DIR/scripts/persistence-self-check.sh"
