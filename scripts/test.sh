#!/bin/bash
# Runs every offline test: Swift host tests and the Python guest helper tests. No VM, network or X server needed.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
echo "== Guest helper (Python) =="
PYTHONDONTWRITEBYTECODE=1 python3 -I Tests/guest/test_helper.py -v
echo "== Host (Swift) =="
extra=()
# With only the Command Line Tools (no Xcode), Swift Testing lives outside SwiftPM's default search paths.
frameworks="$(xcode-select -p 2>/dev/null)/Library/Developer/Frameworks"
if [[ "$(xcode-select -p 2>/dev/null)" == */CommandLineTools && -d "$frameworks/Testing.framework" ]]; then
  extra=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib")
fi
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/configuration" --security-path "$PWD/.build/security" ${extra[@]+"${extra[@]}"}
