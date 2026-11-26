#!/bin/bash
# The iPhone's sync code, checked on a Mac with Xcode (adhd), through the farm:
#
#   ./farm exec --host adhd --estimate 300 -- Phone/SyncCheck/run.sh [ios] [live]
#
#   ios      SyncKit and Phone/Sources/Sync's engine compiled for
#            arm64-apple-ios26.0-simulator against the iPhone simulator SDK,
#            in the language modes an app target may use.
#   live     a local sync server (npx wrangler dev on sync-server/), a "Mac"
#            and the iPhone engine on one account (main.swift live).
#
# The records themselves aren't compared any more: the Mac and the iPhone
# share SyncKit's (Shapes.swift), and SyncWireTests holds the Mac's to their
# bytes. With no step named, both. Exit 1 if any failed.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/yab-sync-check.XXXXXX")
STEPS=" ${*:-ios live} "
FAILED=()
WRANGLER=""

cleanup() {
    if [ -n "$WRANGLER" ]; then
        pkill -P "$WRANGLER" 2>/dev/null
        kill "$WRANGLER" 2>/dev/null
    fi
    rm -rf "$OUT"
}
trap cleanup EXIT

wants() { [[ "$STEPS" == *" $1 "* ]]; }
step() { echo; echo "=== $*"; }
# Runs a command; its output stays in the log, its failure is counted.
run() {
    local name="$1"; shift
    local start=$SECONDS
    "$@" 2>&1
    local status=$?
    if [ "$status" -ne 0 ]; then FAILED+=("$name"); echo "--- $name: FAILED ($status) in $((SECONDS - start)) s"; else echo "--- $name: ok in $((SECONDS - start)) s"; fi
    return "$status"
}

xcrun swiftc --version 2>&1 | head -1
# The engine alone: Phone/Sources/Sync also holds the app's side of sync
# (SyncBridge, SyncMapping, SyncMarks, SyncProbe, SyncMirror), built on the
# app's own types; those are checked by the app's tests and sync-e2e.
ENGINE="Phone/Sources/Sync/PhoneSync.swift Phone/Sources/Sync/SyncKeychain.swift Phone/Sources/Sync/PhonePairing.swift Phone/Sources/Design/DeviceWord.swift"

if wants ios; then
    SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
    echo "iPhone simulator SDK: $SDK"
    ios() { xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -sdk "$SDK" "$@"; }
    mkdir -p "$OUT/ios5" "$OUT/ios6"

    step "1. SyncKit for iOS, Swift 5 mode (as Package.swift builds it), a module and a static library"
    run "SyncKit iOS swift5" ios -swift-version 5 -parse-as-library -module-name SyncKit -emit-module \
        -emit-module-path "$OUT/ios5/SyncKit.swiftmodule" -emit-library -static -o "$OUT/ios5/libSyncKit.a" Sources/SyncKit/*.swift
    ls -la "$OUT/ios5" | sed 's/^/    /'

    step "1b. SyncKit for iOS, Swift 6 language mode (strict concurrency)"
    run "SyncKit iOS swift6" ios -swift-version 6 -parse-as-library -module-name SyncKit -emit-module \
        -emit-module-path "$OUT/ios6/SyncKit.swiftmodule" -emit-library -static -o "$OUT/ios6/libSyncKit.a" Sources/SyncKit/*.swift

    step "3. Phone/Sources/Sync on SyncKit (a module of its own), Swift 6 mode"
    run "PhoneSync iOS swift6" ios -swift-version 6 -parse-as-library -module-name PhoneSyncKit -I "$OUT/ios5" -L "$OUT/ios5" -emit-module \
        -emit-module-path "$OUT/ios6/PhoneSyncKit.swiftmodule" -emit-library -static -o "$OUT/ios6/libPhoneSyncKit.a" $ENGINE

    step "3b. Phone/Sources/Sync, Swift 6 mode, MainActor by default (an app target with Xcode 26's default isolation)"
    run "PhoneSync iOS swift6 MainActor" ios -swift-version 6 -parse-as-library -module-name PhoneSyncMain -I "$OUT/ios5" \
        -default-isolation MainActor -typecheck $ENGINE

    step "3c. Phone/Sources/Sync and SyncKit in one module (no import), Swift 5 mode"
    run "PhoneSync+SyncKit one module" ios -swift-version 5 -parse-as-library -module-name YabPhoneSync -typecheck \
        Sources/SyncKit/*.swift $ENGINE

    step "3d. Phone/Sources/Sync, Swift 5 mode"
    run "PhoneSync iOS swift5" ios -swift-version 5 -parse-as-library -module-name PhoneSyncKit5 -I "$OUT/ios5" -typecheck $ENGINE
fi

if wants live; then
    step "Building the check (macOS): SyncKit, the Mac's SyncShapes.swift, SyncChats, Address.swift, Phone/Sources/Sync"
    mkdir -p "$OUT/mac" "$OUT/macsrc"
    python3 Phone/SyncCheck/extract.py Sources/Fast "$OUT/macsrc"
    run "SyncKit macOS" xcrun swiftc -swift-version 5 -parse-as-library -module-name SyncKit -emit-module \
        -emit-module-path "$OUT/mac/SyncKit.swiftmodule" -emit-library -static -o "$OUT/mac/libSyncKit.a" Sources/SyncKit/*.swift
    run "synccheck build" xcrun swiftc -swift-version 5 -module-name SyncCheck -I "$OUT/mac" -L "$OUT/mac" -lSyncKit -lsqlite3 \
        Sources/Fast/SyncShapes.swift Sources/Fast/Address.swift "$OUT/macsrc/SessionTypes.swift" "$OUT/macsrc/SyncChatsCore.swift" \
        Phone/SyncCheck/MacStubs.swift $ENGINE Phone/SyncCheck/main.swift -o "$OUT/synccheck"
fi

if wants live && [ -x "$OUT/synccheck" ]; then
    step "live: a local sync server, a Mac and the iPhone engine"
    echo "node $(node --version), npm $(npm --version)"
    mkdir -p "$OUT/server"
    (cd sync-server && tar cf - --exclude node_modules --exclude .wrangler .) | (cd "$OUT/server" && tar xf -)
    start=$SECONDS
    if (cd "$OUT/server" && npm ci --no-audit --no-fund --loglevel=error > "$OUT/npm.log" 2>&1); then
        echo "npm ci: $((SECONDS - start)) s"
        PORT=$((18700 + RANDOM % 900))
        (cd "$OUT/server" && CI=1 WRANGLER_SEND_METRICS=false exec npx wrangler dev --port "$PORT" --ip 127.0.0.1 \
            --persist-to "$OUT/state" > "$OUT/wrangler.log" 2>&1) &
        WRANGLER=$!
        up=""
        for _ in $(seq 1 120); do
            if curl -sf "http://127.0.0.1:$PORT/v1/health" > /dev/null 2>&1; then up=1; break; fi
            sleep 0.5
        done
        if [ -n "$up" ]; then
            echo "wrangler dev up on :$PORT in $((SECONDS - start)) s: $(curl -s "http://127.0.0.1:$PORT/v1/health")"
            run "live" "$OUT/synccheck" live "http://127.0.0.1:$PORT"
        else
            FAILED+=("wrangler dev")
            echo "--- wrangler dev did not come up; its log:"; tail -40 "$OUT/wrangler.log"
        fi
    else
        FAILED+=("npm ci"); echo "--- npm ci failed:"; tail -30 "$OUT/npm.log"
    fi
fi

echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "SYNC CHECK: all passed"; exit 0; fi
echo "SYNC CHECK: failed: ${FAILED[*]}"
exit 1
