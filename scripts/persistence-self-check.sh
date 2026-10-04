#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/swift-module-cache"
mkdir -p "$PROJECT_DIR/.build/self-checks"
for MODE in debug release; do
  if [[ "$MODE" == debug ]]; then OPTIMIZATION=(-Onone -g); else OPTIMIZATION=(-O); fi
  xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 -parse-as-library \
    "${OPTIMIZATION[@]}" -module-cache-path "$SWIFT_MODULECACHE_PATH" \
    Sources/VoiceBridge/VoiceTypes.swift Sources/VoiceBridge/VoiceSettingsPersistence.swift \
    Sources/VoiceBridge/LocalKeychainCredentialStore.swift scripts/VoicePersistenceSelfCheck.swift \
    -o "$PROJECT_DIR/.build/self-checks/VoicePersistenceSelfCheck-$MODE"
  print "Persistence offline checks ($MODE):"
  "$PROJECT_DIR/.build/self-checks/VoicePersistenceSelfCheck-$MODE"
done
