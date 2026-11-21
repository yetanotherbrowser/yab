#!/bin/bash
# Compile proof can run in a non-display lane while pixel acceptance waits.
set -euo pipefail
cd "$(dirname "$0")/../.."
bash YabCore/build.sh 2>&1 | tee "$YAB_FARM_OUT/build.log"
lockf -k -s "${YAB_BUILD_LOCK:-/tmp/yab-build.lock}" clang++ -std=c++20 -fobjc-arc -framework Cocoa -framework QuartzCore \
  YabCore/tests/layer_host.mm -o "$YAB_FARM_OUT/layer-host"
swift test --package-path YabCore/Client --scratch-path "$YAB_FARM_OUT/swift" 2>&1 | tee "$YAB_FARM_OUT/swift-tests.log"
clang++ -std=c++20 -O1 YabCore/tests/shield_engine_test.cc -o "$YAB_FARM_OUT/shield-engine-test"
"$YAB_FARM_OUT/shield-engine-test"
clang++ -std=c++20 -O1 -IYabCore/src YabCore/tests/touch_line_test.cc -o "$YAB_FARM_OUT/touch-line-test"
"$YAB_FARM_OUT/touch-line-test"
