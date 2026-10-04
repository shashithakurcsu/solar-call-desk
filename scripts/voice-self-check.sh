#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/swift-module-cache"
mkdir -p "$PROJECT_DIR/.build/self-checks"
for MODE in debug release; do
  if [[ "$MODE" == debug ]]; then
    OPTIMIZATION=(-Onone -g)
    C_OPTIMIZATION=(-O0 -g)
  else
    OPTIMIZATION=(-O)
    C_OPTIMIZATION=(-O2)
  fi
  xcrun clang -std=c11 -target arm64-apple-macos14.0 "${C_OPTIMIZATION[@]}" -Wall -Wextra -Werror -I Sources/HALAudioCore/include \
    -c Sources/HALAudioCore/HALAudioCore.c -o "$PROJECT_DIR/.build/self-checks/HALAudioCore-$MODE.o"
  xcrun clang -std=c11 -target arm64-apple-macos14.0 "${C_OPTIMIZATION[@]}" -Wall -Wextra -Werror -DSB_HAL_TEST \
    -I Sources/HALAudioCore/include Sources/HALAudioCore/HALAudioCore.c scripts/HALAudioCoreSelfCheck.c \
    -framework AudioToolbox -o "$PROJECT_DIR/.build/self-checks/HALCoreSelfCheck-$MODE"
  "$PROJECT_DIR/.build/self-checks/HALCoreSelfCheck-$MODE"
  xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 -D VOICE_SELF_CHECK -parse-as-library \
    "${OPTIMIZATION[@]}" -module-cache-path "$PROJECT_DIR/.build/swift-module-cache" \
    -I Sources/HALAudioCore/include "$PROJECT_DIR/.build/self-checks/HALAudioCore-$MODE.o" \
    Sources/VoiceBridge/*.swift Tests/VoiceBridgeTests/VoiceBridgeTests.swift \
    -o "$PROJECT_DIR/.build/self-checks/VoiceSelfCheck-$MODE"
  print "VoiceBridge offline checks ($MODE):"
  "$PROJECT_DIR/.build/self-checks/VoiceSelfCheck-$MODE"
done
