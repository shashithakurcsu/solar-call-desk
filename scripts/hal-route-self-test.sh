#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/swift-module-cache"
MODE="${1:---build-only}"
if [[ "$MODE" != --build-only && "$MODE" != --run-reviewed-local-hal-test ]]; then
  print -u2 "Use --build-only, or the separately authorized --run-reviewed-local-hal-test."
  exit 2
fi
mkdir -p .build/hal-route-test
xcrun clang -std=c11 -target arm64-apple-macos14.0 -O2 -Wall -Wextra -Werror \
  -I Sources/HALAudioCore/include -c Sources/HALAudioCore/HALAudioCore.c -o .build/hal-route-test/HALAudioCore.o
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx14.0 -parse-as-library \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" -I Sources/HALAudioCore/include \
  Sources/VoiceBridge/*.swift scripts/RunHALRouteTest.swift .build/hal-route-test/HALAudioCore.o \
  -o .build/hal-route-test/RunHALRouteTest
RUNNER="$PROJECT_DIR/.build/hal-route-test/RunHALRouteTest"
if [[ "$MODE" == --build-only ]]; then
  print "Built without audio I/O: $RUNNER"
  exit 0
fi
# The parent watchdog owns only this child. A hung child is terminated at 35s;
# process teardown releases its HAL clients. No unrelated app or process is touched.
python3 - "$RUNNER" <<'PY'
import subprocess, sys
child = subprocess.Popen([sys.argv[1], "--run-reviewed-local-hal-test"])
try:
    code = child.wait(timeout=35)
except (subprocess.TimeoutExpired, KeyboardInterrupt):
    child.terminate()
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=1)
    print("FAILURE: local HAL runner watchdog stopped its owned child.", file=sys.stderr)
    code = 1
sys.exit(code)
PY
