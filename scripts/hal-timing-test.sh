#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/swift-module-cache"
MODE="${1:---build-only}"
if [[ "$MODE" != --build-only && "$MODE" != --run-reviewed-timing-test ]]; then
  print -u2 "Use --build-only or the separately authorized --run-reviewed-timing-test."
  exit 2
fi
mkdir -p .build/hal-timing-test
xcrun clang -std=c11 -target arm64-apple-macos14.0 -O2 -Wall -Wextra -Werror \
  -I Sources/HALAudioCore/include -c Sources/HALAudioCore/HALAudioCore.c -o .build/hal-timing-test/HALAudioCore.o
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx14.0 -parse-as-library \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" -I Sources/HALAudioCore/include \
  Sources/VoiceBridge/*.swift scripts/RunHALTimingTest.swift .build/hal-timing-test/HALAudioCore.o \
  -o .build/hal-timing-test/RunHALTimingTest
if [[ "$MODE" == --build-only ]]; then
  print "Built without audio I/O: $PROJECT_DIR/.build/hal-timing-test/RunHALTimingTest"
  exit 0
fi
# Only the owned diagnostic child is stopped by this 100-second deadline.
python3 - "$PROJECT_DIR/.build/hal-timing-test/RunHALTimingTest" <<'PY'
import subprocess, sys
child = subprocess.Popen([sys.argv[1], "--run-reviewed-timing-test"])
try:
    code = child.wait(timeout=100)
except (subprocess.TimeoutExpired, KeyboardInterrupt):
    child.terminate()
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=1)
    print("FAILURE: timing probe watchdog stopped its owned child.", file=sys.stderr)
    code = 1
sys.exit(code)
PY
