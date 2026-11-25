#!/bin/bash
# Assembles a double-clickable .app around the SwiftPM binary, and, when
# asked, the disk image people install it from and the ZIP the updater
# fetches.
#
#   ./build.sh                 yab Dev, the development build, beside yab:
#                                its own bundle id, data and keychain items,
#                                the blueprint icon, never updated
#   ./build.sh release prod    yab itself, the app that ships, without packing it
#   ./build.sh release dmg     + build/yab.dmg, build/yab.zip and
#                                build/appcast.json, signed with Developer ID
#                                if there is one in the keychain
#   ./build.sh release ship    + both notarised, the DMG stapled
#
# Same shape as the one next door: SwiftPM builds the executable, and a macOS
# app bundle is just a folder with a plist and the binary in the right place.
#
# The three files keep the same names from release to release, so the site
# links to them once and the updater reads one address forever. ./release.sh
# is what puts a build on the site: it runs this from a clean copy of HEAD.
#
# "dmg" lays the disk image's window out with dmgbuild, installed into .build
# on first use (Python 3 and a network, once).
#
# What "ship" needs, once:
#   - a Developer ID Application certificate in the login keychain
#     (YAB_SIGN_IDENTITY names it; otherwise the first one found is used)
#   - a notarytool profile: xcrun notarytool store-credentials "yab"
#     (YAB_NOTARY_PROFILE names it; default "yab")
#   - YAB_DOWNLOAD_URL, the https folder the three files are served from.
#     It goes into the bundle as YabFeed (<folder>/appcast.json), where
#     Updater.feed looks, and into the appcast. Without it the build has no
#     feed and never checks for updates, and no appcast is written.
#
# NOTES.md, next to this script, is what's new: newest release first, each
# ended by a line of ---. A release is a headline, then ADDED, IMPROVED,
# CHANGED and FIXED, each on a line of its own, with a change a line under
# it; the site's changelog draws them so. The top one goes into the appcast.
set -euo pipefail

cd "$(dirname "$0")"
# main is the user's own Mac: switched off, it builds only in a real farm job.
FARM_RUNTIME="$HOME/.local/state/yab-farm/runtime/farm.py"
if [ -f "$FARM_RUNTIME" ]; then /usr/bin/python3 "$FARM_RUNTIME" _may_run_here || exit 1; fi
CONFIG="${1:-release}"
STEP="${2:-app}"
case "$STEP" in prod|dmg|ship) . scripts/release/xcode-env.sh ;; esac
# A disposable launch preview has its own bundle metadata and never enters
# the ordinary dev-app cache, whose key is shared with normal builds.
if [ "$STEP" = app ] && [ "${YAB_LAUNCH_PREVIEW:-}" = 1 ]; then
  export YAB_APP_CACHE=0
fi
# The yab that ships (prod, dmg, ship) is universal, arm64 and x86_64, so it
# also opens on Intel Macs; yab Dev is this Mac's architecture only, as a
# second compile doubles the build. YAB_UNIVERSAL=1 or 0 says otherwise: a
# release publishes its arm64-only build first (YAB_UNIVERSAL=0, with
# YAB_ZIP_ONLY=1 to stop after the notarized ZIP, as no disk image is made
# from it) and the universal build of the same commit and build number after.
if [ -n "${YAB_UNIVERSAL:-}" ]; then UNIVERSAL="$YAB_UNIVERSAL"
elif [ "$STEP" = "app" ]; then UNIVERSAL=0
else UNIVERSAL=1
fi
ARCH_KEY="$(uname -m)"
[ "$UNIVERSAL" != 1 ] || ARCH_KEY="universal"

# An isolated release keychain can be used without changing the login keychain.
# A Mac provisioned for releases keeps it in the search list, so every build
# finds its Developer ID there; left locked, codesign asks for it in a window
# that a headless farm Mac never answers, holding the build lock (m4,
# 2026-10-13). Use and unlock it the way scripts/release/worker.sh does.
RELEASE_PROFILE="$HOME/.config/yab-release/profile.env"
if [ -z "${YAB_SIGN_KEYCHAIN:-}" ] && [ -r "$RELEASE_PROFILE" ]; then
  RELEASE_KEYCHAIN_AUTO=1
  YAB_SIGN_KEYCHAIN="$(sed -n 's/^YAB_SIGN_KEYCHAIN=//p' "$RELEASE_PROFILE" | tr -d "\"'")"
  YAB_RELEASE_PASSWORD_FILE="${YAB_RELEASE_PASSWORD_FILE:-$(sed -n 's/^YAB_RELEASE_PASSWORD_FILE=//p' "$RELEASE_PROFILE" | tr -d "\"'")}"
  if [ ! -f "$YAB_SIGN_KEYCHAIN" ] || [ ! -r "$YAB_RELEASE_PASSWORD_FILE" ]; then
    YAB_SIGN_KEYCHAIN="" YAB_RELEASE_PASSWORD_FILE=""
  fi
fi
SIGN_KEYCHAIN_ARGS=()
IDENTITY_KEYCHAIN_ARGS=()
NOTARY_KEYCHAIN_ARGS=()
if [ -n "${YAB_SIGN_KEYCHAIN:-}" ]; then
  SIGN_KEYCHAIN_ARGS=(--keychain "$YAB_SIGN_KEYCHAIN")
  IDENTITY_KEYCHAIN_ARGS=("$YAB_SIGN_KEYCHAIN")
fi
if [ -n "${YAB_NOTARY_KEYCHAIN:-}" ]; then
  NOTARY_KEYCHAIN_ARGS=(--keychain "$YAB_NOTARY_KEYCHAIN")
fi

# The host keychain may auto-lock while Swift compiles or Apple checks a ZIP.
# Unlock only the dedicated release keychain immediately before using it.
unlock_release_keychain() {
  if [ -n "${YAB_SIGN_KEYCHAIN:-}" ] && [ -n "${YAB_RELEASE_PASSWORD_FILE:-}" ]; then
    security unlock-keychain -p "$(cat "$YAB_RELEASE_PASSWORD_FILE")" "$YAB_SIGN_KEYCHAIN"
  fi
}

# A build that only found the release keychain by itself signs ad hoc when
# it won't open, rather than leave codesign waiting on a password window.
# m4's login session once kept a replaced keychain's old passphrase.
unlock_found_keychain() {
  [ -z "${RELEASE_KEYCHAIN_AUTO:-}" ] && { unlock_release_keychain || exit 1; return 0; }
  unlock_release_keychain 2>/dev/null && return
  echo "release keychain $YAB_SIGN_KEYCHAIN won't unlock; signing ad hoc" >&2
  return 1
}

. scripts/runs/power.sh
yab_route_on_battery ./build.sh "$@"
# Hold the lock around the whole build and recheck power after queueing.
if [ -z "${YAB_BUILD_LOCK_HELD:-}" ]; then
  mkdir -p build
  # yab Dev whose inputs were already built on this Mac (scripts/runs/
  # build_cache.py app-key: sources, resources, icons, skills, the Dock tile,
  # the package, this script, Xcode, the mode) is copied from the app cache:
  # no compiler, so not the Mac-wide lock either, only this checkout's
  # build/.app.lock against another build writing the same build folder.
  # YAB_APP_CACHE=0 always compiles.
  if [ "$STEP" = "app" ] && [ "${YAB_APP_CACHE:-}" != 0 ] \
    && APP_HIT="$(python3 scripts/runs/build_cache.py app-key "$CONFIG" "$ARCH_KEY" 2>/dev/null)" \
    && python3 scripts/runs/build_cache.py app-valid "$APP_HIT"; then
    exec lockf -k build/.app.lock env YAB_BUILD_LOCK_HELD=app-cache YAB_APP_HIT="$APP_HIT" bash "$0" "$@"
  fi
  if [ -t 2 ] && ! lockf -k -s -t 0 /tmp/yab-build.lock true 2>/dev/null; then
    echo "Waiting for another yab build on this Mac…" >&2
  fi
  # This checkout's lock first, then the Mac's: the order a cache hit that
  # falls back to compiling takes them too.
  exec lockf -k build/.app.lock lockf -k -s /tmp/yab-build.lock env YAB_BUILD_LOCK_HELD=1 bash "$0" "$@"
fi
export YAB_BUILD_ACTIVE=1

# How this build ended, for ./runs: what it was, the tree, the session that
# asked and the exit code, a record in ~/Library/Caches/yab-runs/done.
RUN_ARGS="$*"
RUN_STARTED="$(date +%s)"
ran() {
  local rc=$? done="$HOME/Library/Caches/yab-runs/done" ended
  ended="$(date +%s)"
  mkdir -p "$done" 2> /dev/null || return 0
  printf 'pid=%s\nkind=build\nwhat=%s\nwmo=%s\ncwd=%s\nslot=%s\nsession=%s\nstarted=%s\nended=%s\nrc=%s\n' \
    "$$" "$RUN_ARGS" "${YAB_WMO:-}" "$PWD" "${SLOT:-}" \
    "${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-${YAB_SESSION:-}}}" "$RUN_STARTED" "$ended" "$rc" \
    > "$done/$ended-$$.run" 2> /dev/null || true
}
trap ran EXIT
# Two apps from one source, which live side by side on one Mac: yab, the
# one that ships (prod, dmg, ship), and yab Dev, what a plain ./build.sh
# makes. Each has its own bundle id, so its own settings, cookies and
# WebKit stores, and the app keeps its folder and keychain items under its
# own name (Store.name). The executable is yab in both.
NAME="yab"
if [ "$STEP" = "app" ]; then
  DISPLAY_NAME="yab Dev"
  USER_DISPLAY_NAME="Yab Dev"
  BUNDLE_ID="dev.serafim.fast.dev"
  if [ "${YAB_LAUNCH_PREVIEW:-}" = 1 ]; then
    BUNDLE_ID="dev.serafim.fast.launcharrival.dev"
  fi
else
  DISPLAY_NAME="yab"
  USER_DISPLAY_NAME="Yab"
  BUNDLE_ID="dev.serafim.fast"
fi
APP="build/$DISPLAY_NAME.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
# A build number that only ever goes up, so the updater can tell newer from
# older without parsing version strings.
# YAB_BUILD_NUMBER fixes it when two builds of one commit have to carry the
# same number (a release's arm64-only and universal halves, release.sh).
BUILD="${YAB_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
[[ "$BUILD" =~ ^[0-9]{12}$ ]] || { echo "YAB_BUILD_NUMBER ($BUILD) isn't a 12-digit build number" >&2; exit 1; }
# The oldest macOS this runs on, in the plist, and in the appcast so an
# older Mac is not handed a build it can't open.
MINIMUM="15.4"

# yab Dev uses SwiftPM's debug compilation plan with -O: optimized, but
# built a file at a time. Do not override release's whole-module plan with
# -no-whole-module-optimization: its dependency map still expects a module
# .d file, which incremental compilation doesn't produce (Swift #70995).
# The separate scratch path also leaves the old, incompatible plan alone.
# yab itself and YAB_WMO=1 ./build.sh keep the normal release/WMO build.
#
# One compile at a time on this Mac, whichever checkout or session asks:
# three at once is three dozen compilers, a machine too hot to use and each
# build slower than waiting its turn. And at most as many jobs as the Mac
# has performance cores (YAB_JOBS to choose), so the window you're in stays
# quick while it builds.
# On a Mac told to keep calm (./runs calm on), fewer: the number in
# ~/.config/yab/jobs.
JOBS="${YAB_JOBS:-$(cat "$HOME/.config/yab/jobs" 2>/dev/null || sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)}"
compile() {
  # Fewer when memory is short, decided now that this build has the lock.
  local jobs
  jobs="$(yab_memory_jobs "$JOBS")"
  [ "$jobs" = "$JOBS" ] || echo "memory short: $jobs compilers instead of $JOBS" >&2
  # Farm workers already run one heavy job per host at the host's priority.
  if [ "${YAB_FARM_URGENT:-}" = 1 ] || [ "${YAB_FARM_WORKER:-}" = 1 ]; then
    swift build -j "$jobs" "$@"
  else
    nice -n 10 swift build -j "$jobs" "$@"
  fi
}
# A cache hit (see the lock above) copies the app assembled from these exact
# inputs, before its name, debug flag and signature, and gives it this
# build's number; everything from here to the App Intents metadata is what it
# skips. A miss assembles as always and keeps the app under its key, if the
# inputs didn't change while it compiled.
if [ -n "${YAB_APP_HIT:-}" ]; then
  if ! python3 scripts/runs/build_cache.py app-restore "$YAB_APP_HIT" "$APP" --build "$BUILD"; then
    echo "app cache: ${YAB_APP_HIT:0:12} went away; compiling" >&2
    exec env -u YAB_APP_HIT YAB_APP_CACHE=0 lockf -k -s /tmp/yab-build.lock env YAB_BUILD_LOCK_HELD=1 bash "$0" "$@"
  fi
  # A dSYM left by an earlier compile here would describe another binary.
  rm -rf "$APP.dSYM"
  echo "app cache: reused the app built from these inputs (${YAB_APP_HIT:0:12})"
else
APP_KEY=""
if [ "$STEP" = "app" ] && [ "${YAB_APP_CACHE:-}" != 0 ]; then
  APP_KEY="$(python3 scripts/runs/build_cache.py app-key "$CONFIG" "$ARCH_KEY" 2>/dev/null || true)"
fi
BUILD_CONFIG="$CONFIG"
if [ "$STEP" = "app" ] && [ "$CONFIG" = "release" ] && [ "${YAB_WMO:-}" != 1 ]; then
  SCRATCH=".build/dev-optimized"
  OTHER_SCRATCH=".build/dev-optimized-other-arch"
  BUILD_CONFIG="debug"
  SWIFT_ARGS=(-Xswiftc -O)
  python3 scripts/runs/build_cache.py prepare-sources "$SCRATCH/source-inputs.json"
  compile -c "$BUILD_CONFIG" --scratch-path "$SCRATCH" "${SWIFT_ARGS[@]}"
  python3 scripts/runs/build_cache.py record-sources "$SCRATCH/source-inputs.json"
else
  SCRATCH=".build"
  OTHER_SCRATCH=".build/other-arch"
  SWIFT_ARGS=()
  SOURCE_MANIFEST="$SCRATCH/source-inputs-$CONFIG.json"
  python3 scripts/runs/build_cache.py prepare-sources "$SOURCE_MANIFEST"
  compile -c "$CONFIG"
  python3 scripts/runs/build_cache.py record-sources "$SOURCE_MANIFEST"
fi
# Swift Build and native SwiftPM use different product layouts. Ask the
# selected engine, so a stale legacy symlink cannot supply an older binary.
BINARY="$(swift build -c "$BUILD_CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/Fast"
# Universal: the other architecture compiled the same way in a scratch path
# of its own, and each executable joined from the two.
if [ "$UNIVERSAL" = 1 ]; then
  if [ "$(uname -m)" = arm64 ]; then OTHER_ARCH=x86_64; else OTHER_ARCH=arm64; fi
  compile -c "$BUILD_CONFIG" --arch "$OTHER_ARCH" --scratch-path "$OTHER_SCRATCH" ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}
  OTHER_BIN="$(swift build -c "$BUILD_CONFIG" --arch "$OTHER_ARCH" --scratch-path "$OTHER_SCRATCH" --show-bin-path)"
fi
place() { # place PRODUCT DESTINATION
  if [ "$UNIVERSAL" = 1 ]; then
    lipo -create "$(dirname "$BINARY")/$1" "$OTHER_BIN/$1" -output "$2"
  else
    cp "$(dirname "$BINARY")/$1" "$2"
  fi
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
place Fast "$APP/Contents/MacOS/$NAME"
# The agent that updates Yab while it is closed (Sources/YabUpdater), and
# what launchd needs to start it: at login and every four hours, as a
# background process. The app enrolls it with SMAppService (Updater.Agent);
# the plist's name is fixed, its label carries the bundle id, so yab and
# yab Dev each have their own.
place YabUpdater "$APP/Contents/MacOS/YabUpdater"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/YabUpdater.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID.updater</string>
  <key>BundleProgram</key><string>Contents/MacOS/YabUpdater</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$BUNDLE_ID</string></array>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>14400</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
</dict>
</plist>
PLIST

# Symbols stay out of the app. The linker leaves every function's name and a
# map back to the source in the binary, 15,000 entries, more than half of
# what the app weighed (6.5 MB of binary, 2.7 without them), and nothing the
# app reads while it runs. They are kept beside the build instead, as a dSYM
# that turns the addresses in a crash report back into names (Console, or
# atos -arch arm64 -o build/yab.app.dSYM/Contents/Resources/DWARF/yab; the
# universal app's dSYM holds both architectures).
if [ "$CONFIG" = "release" ]; then
  rm -rf "$APP.dSYM"
  dsymutil "$APP/Contents/MacOS/$NAME" -o "$APP.dSYM" 2>/dev/null || echo "no dSYM this time" >&2
  strip -x "$APP/Contents/MacOS/$NAME"
  strip -x "$APP/Contents/MacOS/YabUpdater"
fi

# Cache compiled icons by their source bytes, packaging code and Xcode/SDK.
# Build into a private folder; only complete resources become reusable.
build_icons() {
  local ICON_RESOURCES="$1"
  # The icon: Icon/yab.icon, an Icon Composer document, compiled by actool
  # into Assets.car, the layered icon macOS 26 draws light, dark, tinted or
  # clear to match the Dock, and yab.icns, the flat one macOS 15 uses.
  # Open Icon/yab.icon in Icon Composer (inside Xcode) to change it.
  # A build that isn't going out, plain ./build.sh, wears Icon/yab Dev.icon
  # instead; its name and bundle identifier distinguish the development app
  # from the yab people download. actool names the icon after its document, so
  # the one chosen is compiled under the name yab either way.
  # Absolute: actool hands the work to a daemon that reads a relative path
  # against its own folder, whichever folder started it, not this one.
  ICONS="$PWD/build/icon"
  rm -rf "$ICONS"
  mkdir -p "$ICONS"
  # YAB_BUNDLE_ICON puts another .icon on a development build, to see one of
  # the alternates as macOS draws a bundle's own: tinted and clear included.
  if [ "$STEP" = "app" ] && [ -n "${YAB_BUNDLE_ICON:-}" ]; then
    cp -R "$YAB_BUNDLE_ICON" "$ICONS/yab.icon"
  elif [ "$STEP" = "app" ]; then
    cp -R "Icon/yab Dev.icon" "$ICONS/yab.icon"
  else
    cp -R Icon/yab.icon "$ICONS/yab.icon"
  fi
  # No accent of the app's own: controls wear the person's accent color.
  xcrun actool "$ICONS/yab.icon" --compile "$ICONS" \
    --output-partial-info-plist "$ICONS/partial.plist" \
    --app-icon yab --include-all-app-icons --enable-on-demand-resources NO \
    --development-region en --target-device mac --platform macosx \
    --minimum-deployment-target "$MINIMUM" --errors --warnings > /dev/null
  cp "$ICONS/Assets.car" "$ICONS/yab.icns" "$ICON_RESOURCES/"
  # The optional Dock icons use the same Icon Composer geometry and fill
  # rules as yab. Keep light and dark .icns files in the signed bundle: AppKit
  # changes the Dock image, but does not switch an alternate Icon Composer
  # document's appearances for us.
  mkdir -p "$ICON_RESOURCES/AppIcons"
  cp -R "$ICONS/yab.icon" "$ICONS/yab-dark.icon"
  sed -E -i '' 's/"value" *: *"automatic"/"value": { "solid": "extended-srgb:0.07843,0.07843,0.07843,1.00000" }/' "$ICONS/yab-dark.icon/icon.json"
  xcrun actool "$ICONS/yab-dark.icon" --compile "$ICONS" \
    --output-partial-info-plist "$ICONS/yab-dark-partial.plist" \
    --app-icon yab-dark --include-all-app-icons --enable-on-demand-resources NO \
    --development-region en --target-device mac --platform macosx \
    --minimum-deployment-target "$MINIMUM" --errors --warnings > /dev/null
  cp "$ICONS/yab-dark.icns" "$ICON_RESOURCES/AppIcons/"
  # Dev keeps its own bundle icon, but can show yab's production
  # default beside it in Appearance. The release already has that icon.
  if [ "$STEP" = "app" ]; then
    cp -R Icon/yab.icon "$ICONS/yab-standard.icon"
    mkdir -p "$ICONS/yab-standard-build" "$ICONS/yab-standard-dark-build"
    xcrun actool "$ICONS/yab-standard.icon" --compile "$ICONS/yab-standard-build" \
      --output-partial-info-plist "$ICONS/yab-standard-build/partial.plist" \
      --app-icon yab-standard --include-all-app-icons --enable-on-demand-resources NO \
      --development-region en --target-device mac --platform macosx \
      --minimum-deployment-target "$MINIMUM" --errors --warnings > /dev/null
    cp "$ICONS/yab-standard-build/yab-standard.icns" "$ICON_RESOURCES/AppIcons/"
    cp -R "$ICONS/yab-standard.icon" "$ICONS/yab-standard-dark.icon"
    sed -E -i '' 's/"value" *: *"automatic"/"value": { "solid": "extended-srgb:0.07843,0.07843,0.07843,1.00000" }/' "$ICONS/yab-standard-dark.icon/icon.json"
    xcrun actool "$ICONS/yab-standard-dark.icon" --compile "$ICONS/yab-standard-dark-build" \
      --output-partial-info-plist "$ICONS/yab-standard-dark-build/partial.plist" \
      --app-icon yab-standard-dark --include-all-app-icons --enable-on-demand-resources NO \
      --development-region en --target-device mac --platform macosx \
      --minimum-deployment-target "$MINIMUM" --errors --warnings > /dev/null
    cp "$ICONS/yab-standard-dark-build/yab-standard-dark.icns" "$ICON_RESOURCES/AppIcons/"
  fi
  # STYLE-dark.png, when present, is the picture the dark .icns shows.
  # STYLE.icon is an Icon Composer bundle of vector layers; its dark .icns
  # is its own dark fill under the same layers.
  for artwork in Icon/Alternates/*.png Icon/Alternates/*.icon; do
    [ -e "$artwork" ] || continue
    style="$(basename "$artwork")"
    style="${style%.*}"
    case "$style" in *-dark) continue ;; esac
    # A document owns its artwork layout; a same-named PNG may stay as the
    # untouched source picture without being compiled over that document.
    if [ -f "$artwork" ] && [ -d "Icon/Alternates/$style.icon" ]; then continue; fi
    mkdir -p "$ICONS/$style-build" "$ICONS/$style-dark-build"
    if [ -d "$artwork" ]; then
      cp -R "$artwork" "$ICONS/$style.icon"
    else
      mkdir -p "$ICONS/$style.icon/Assets"
      cp Icon/yab.icon/icon.json "$ICONS/$style.icon/icon.json"
      cp "$artwork" "$ICONS/$style.icon/Assets/art.png"
    fi
    xcrun actool "$ICONS/$style.icon" --compile "$ICONS/$style-build" \
      --output-partial-info-plist "$ICONS/$style-build/partial.plist" \
      --app-icon "$style" --include-all-app-icons --enable-on-demand-resources NO \
      --development-region en --target-device mac --platform macosx \
      --minimum-deployment-target "$MINIMUM" --errors --warnings > /dev/null
    cp "$ICONS/$style-build/$style.icns" "$ICON_RESOURCES/AppIcons/"
    cp -R "$ICONS/$style.icon" "$ICONS/$style-dark.icon"
    sed -E -i '' 's/"value" *: *"automatic"/"value": { "solid": "extended-srgb:0.07843,0.07843,0.07843,1.00000" }/' "$ICONS/$style-dark.icon/icon.json"
    if [ -d "$artwork" ]; then
      python3 - "$ICONS/$style-dark.icon/icon.json" <<'PY'
import json, sys
path = sys.argv[1]
icon = json.load(open(path))
dark = [f for f in icon.get("fill-specializations", []) if f.get("appearance") == "dark"]
if dark:
    icon["fill-specializations"] = [{"value": dark[0]["value"]}]
json.dump(icon, open(path, "w"), indent=2)
PY
    elif [ -f "Icon/Alternates/$style-dark.png" ]; then
      cp "Icon/Alternates/$style-dark.png" "$ICONS/$style-dark.icon/Assets/art.png"
    fi
    xcrun actool "$ICONS/$style-dark.icon" --compile "$ICONS/$style-dark-build" \
      --output-partial-info-plist "$ICONS/$style-dark-build/partial.plist" \
      --app-icon "$style-dark" --include-all-app-icons --enable-on-demand-resources NO \
      --development-region en --target-device mac --platform macosx \
      --minimum-deployment-target "$MINIMUM" --errors --warnings > /dev/null
    cp "$ICONS/$style-dark-build/$style-dark.icns" "$ICON_RESOURCES/AppIcons/"
  done
  rm -rf "$ICONS"
# actool's ICNS previews contain PNGs. Recompress their existing scanlines
# without changing pixels, profiles, resolutions or any other icon records.
python3 - "$ICON_RESOURCES" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

def png(data):
    chunks, offset = [], 8
    while offset < len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        chunks.append((data[offset + 4:offset + 8], data[offset:offset + length + 12]))
        offset += length + 12
    original = b''.join(chunk[8:-4] for kind, chunk in chunks if kind == b'IDAT')
    scanlines = zlib.decompress(original)
    candidates = [original]
    for strategy in (zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED):
        compressor = zlib.compressobj(9, zlib.DEFLATED, 15, 9, strategy)
        candidates.append(compressor.compress(scanlines) + compressor.flush())
    compressed = min(candidates, key=len)
    assert zlib.decompress(compressed) == scanlines
    idat = b'IDAT' + compressed
    record = struct.pack('>I', len(compressed)) + idat + struct.pack('>I', zlib.crc32(idat))
    result, written = bytearray(data[:8]), False
    for kind, chunk in chunks:
        if kind != b'IDAT':
            result.extend(chunk)
        elif not written:
            result.extend(record)
            written = True
    return bytes(result) if len(result) < len(data) else data

for path in Path(sys.argv[1]).rglob('*.icns'):
    data, offset, records = path.read_bytes(), 8, []
    while offset < len(data):
        kind, length = struct.unpack_from('>4sI', data, offset)
        body = data[offset + 8:offset + length]
        if body.startswith(b'\x89PNG\r\n\x1a\n'):
            body = png(body)
        records.append(kind + struct.pack('>I', len(body) + 8) + body)
        offset += length
    content = b''.join(records)
    result = b'icns' + struct.pack('>I', len(content) + 8) + content
    if len(result) < len(data):
        path.write_bytes(result)
PY

}
ICON_CACHE="$PWD/$SCRATCH/icon-resources"
ICON_KEY="$(python3 scripts/runs/build_cache.py icon-key "$STEP" "$MINIMUM")"
if python3 scripts/runs/build_cache.py valid-icons "$ICON_CACHE" "$ICON_KEY"; then
  echo "icon cache: reused compiled resources"
else
  NEW_ICONS="$(mktemp -d "$PWD/$SCRATCH/icon-resources.XXXXXX")"
  build_icons "$NEW_ICONS"
  python3 scripts/runs/build_cache.py record-icons "$NEW_ICONS" "$ICON_KEY"
  rm -rf "$ICON_CACHE"
  mv "$NEW_ICONS" "$ICON_CACHE"
  echo "icon cache: compiled and saved resources"
fi
cp "$ICON_CACHE/Assets.car" "$ICON_CACHE/yab.icns" "$APP/Contents/Resources/"
cp -R "$ICON_CACHE/AppIcons" "$APP/Contents/Resources/"
# The mark, the picture Welcome draws (Logomark, Design.swift).
cp Icon/Mark.png "$APP/Contents/Resources/Mark.png"
# Yab for iPhone's icon, for the rows that offer it (PhoneBeta.swift).
cp Icon/iPhone.png "$APP/Contents/Resources/iPhone.png"
# The notices the licenses of code inside the app ask to travel with it.
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Acknowledgements.txt"
# The icons of the apps About › Credits thanks (CreditRow).
rm -rf "$APP/Contents/Resources/Credits"
cp -R Icon/Credits "$APP/Contents/Resources/Credits"
# Who issued a card, from its first digits (Bins.swift).
cp Resources/bins.dat "$APP/Contents/Resources/bins.dat"
# Emoji's words, from Unicode CLDR (EmojiMeaning.swift).
cp Resources/emoji.dat "$APP/Contents/Resources/emoji.dat"
# Every emoji in Unicode's order, by part, for Change Icon (IconPicker.swift).
cp Resources/emoji-groups.dat "$APP/Contents/Resources/emoji-groups.dat"
# The hand an update's note is written in (UpdateDoodle.swift).
cp Resources/Caveat.ttf "$APP/Contents/Resources/Caveat.ttf"
mkdir -p "$APP/Contents/Resources/LaunchArrival"
cp Resources/LaunchArrival/Waves.metal Resources/LaunchArrival/arrival-02.m4a "$APP/Contents/Resources/LaunchArrival/"
# The AppleScript dictionary (Scripting.swift), named in the plist below.
cp Resources/Yab.sdef "$APP/Contents/Resources/Yab.sdef"
# Offline source editor for native Developer Tools.
rm -rf "$APP/Contents/Resources/DevTools"
cp -R Resources/DevTools "$APP/Contents/Resources/DevTools"
# The scripts yab puts in pages (PageScript.swift). Without them the app
# would fall back to this checkout's copy, which only the build Mac has.
rm -rf "$APP/Contents/Resources/PageScripts"
cp -R Resources/PageScripts "$APP/Contents/Resources/PageScripts"
# Native Settings ships English only. Remove translations from older builds.
rm -rf "$APP/Contents/Resources/ja.lproj" "$APP/Contents/Resources/es.lproj"
cp -R Resources/Localization/en.lproj "$APP/Contents/Resources/"
test -s "$APP/Contents/Resources/PageScripts/extension-shims.js"
# Dark Reader's site lists for dark pages (DarkPages.swift, scripts/darkreader-update).
rm -rf "$APP/Contents/Resources/DarkReader"
cp -R Resources/DarkReader "$APP/Contents/Resources/DarkReader"
test -s "$APP/Contents/Resources/DarkReader/dynamic-theme-fixes.config"
# The best friend charm's halves, one per color (CharmDraw.swift, Invites.swift).
rm -rf "$APP/Contents/Resources/Charm"
cp -R Resources/Charm "$APP/Contents/Resources/Charm"
# Google's own marks for the welcome's Google step (WelcomeEnd.swift).
cp -R Resources/Google "$APP/Contents/Resources/Google"
# The welcome sample's sites' own favicons (WelcomeSiteMark).
cp -R Resources/Sites "$APP/Contents/Resources/Sites"
# The marks of the sites the shipped Store shelf is for (StoreCatalog.fetchIcons).
rm -rf "$APP/Contents/Resources/StoreIcons"
cp -R Resources/StoreIcons "$APP/Contents/Resources/StoreIcons"
# The bots' faces (AssistantBotIcon.swift). Cleared first: cp -R into an
# app reused from the cache would nest a second AssistantIcons in the first.
rm -rf "$APP/Contents/Resources/AssistantIcons"
cp -R Resources/AssistantIcons "$APP/Contents/Resources/AssistantIcons"
# Each password manager's own extension icon, for the ones not in Yab yet
# (PasswordManagers.swift); an installed one shows the icon it ships.
rm -rf "$APP/Contents/Resources/PasswordManagerIcons"
cp -R Resources/PasswordManagerIcons "$APP/Contents/Resources/PasswordManagerIcons"
# Each plan's app icon (AgentIcons in AgentConnect.swift), so its mark is
# the real one whether or not the app is on this Mac.
rm -rf "$APP/Contents/Resources/AgentIcons"
cp -R Resources/AgentIcons "$APP/Contents/Resources/AgentIcons"
# What agents know about sites before they get there (Skills.swift): a
# folder per skill, each a SKILL.md.
rm -rf "$APP/Contents/Resources/skills"
cp -R Skills "$APP/Contents/Resources/skills"
# The Dock's tile while yab isn't running (DockTile/DockTile.swift): it keeps
# the App Icon chosen in Appearance, which macOS forgets on quit. Both kinds
# of Mac, since it runs inside the Dock, not inside yab.
TILE="$APP/Contents/PlugIns/YabDockTile.docktileplugin"
mkdir -p "$TILE/Contents/MacOS" "$SCRATCH/docktile"
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos$MINIMUM" -module-name YabDockTile \
    -emit-library -Xlinker -bundle DockTile/*.swift Sources/Fast/CharmDraw.swift -o "$SCRATCH/docktile/YabDockTile-$ARCH"
done
lipo -create "$SCRATCH/docktile/YabDockTile-arm64" "$SCRATCH/docktile/YabDockTile-x86_64" \
  -output "$TILE/Contents/MacOS/YabDockTile"
if [ "$CONFIG" = "release" ]; then strip -x "$TILE/Contents/MacOS/YabDockTile"; fi
cat > "$TILE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>YabDockTile</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.docktile</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>NSPrincipalClass</key><string>YabDockTile</string>
</dict>
</plist>
PLIST

# Mail's Google client (docs/mail.md, Getting the Google keys), from the
# build's environment or ~/.config/yab/google-client.env, into the plist:
# an app opened from the Finder never sees a shell's variables.
if [ -z "${YAB_GOOGLE_CLIENT_ID:-}" ] && [ -f "$HOME/.config/yab/google-client.env" ]; then
  . "$HOME/.config/yab/google-client.env"
fi
GOOGLE_KEYS=""
if [ -n "${YAB_GOOGLE_CLIENT_ID:-}" ]; then
  GOOGLE_KEYS="<key>YABGoogleClientID</key><string>${YAB_GOOGLE_CLIENT_ID}</string><key>YABGoogleClientSecret</key><string>${YAB_GOOGLE_CLIENT_SECRET:-}</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$USER_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$USER_DISPLAY_NAME</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string></array>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>yab</string>
  <key>CFBundleIconName</key><string>yab</string>
  <key>NSDockTilePlugIn</key><string>YabDockTile.docktileplugin</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Serafim Korablev · Yab</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Scriptable as Arc and Chrome are: windows, tabs, spaces
       (Resources/Yab.sdef, Scripting.swift). -->
  <key>NSAppleScriptEnabled</key><true/>
  <key>OSAScriptingDefinition</key><string>Yab.sdef</string>
  <!-- Owning http and https is what lets macOS offer this app as the default
       browser, and what sends a link clicked in Mail here. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
    <!-- mailto: what lets macOS offer it as the mail app (Settings › Mail,
         Default mail app), and a mail link in another app then opens a new
         mail here (MailtoPeek.swift). -->
    <dict>
      <key>CFBundleURLName</key><string>Mail address</string>
      <key>CFBundleURLSchemes</key><array><string>mailto</string></array>
    </dict>
    <dict>
      <key>CFBundleURLName</key><string>Shared Yab Boost</string>
      <key>CFBundleURLSchemes</key><array><string>yab-boost</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>public.xhtml</string><string>com.apple.web-internet-location</string></array>
    </dict>
  </array>
  <!-- A browser goes wherever it is pointed, including at http sites and at
       whatever is running on localhost. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <!-- A site's notification can say who sent it, their face large and Yab's
       small in the corner, as Messages does: macOS shows it so for an app
       that sends messages (SiteNotices). Without the profile's entitlement
       it is an ordinary notification. -->
  <!-- The page in front, handed off to an iPhone or another Mac signed in to
       the same Apple ID (PageContinuity); the iPhone app lists the same type. -->
  <key>NSUserActivityTypes</key>
  <array><string>INSendMessageIntent</string><string>dev.serafim.fast.page</string><string>NSUserActivityTypeBrowsingWeb</string></array>
  <!-- A browser is asked for these by the pages it shows, not by itself. macOS
       still wants a sentence to put in its own prompt, and touching the APIs
       without one is a crash rather than a refusal. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>To send a message in Messages when you ask an agent to. Yab sends only what you asked for.</string>
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera. Yab asks you first, every time, for each site.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Websites you visit can ask to use your microphone. Yab asks you first, every time, for each site.</string>
  <!-- WebKit registers a .local name for a page's WebRTC connection, as X
       does on load, and macOS asks about the local network then. The name
       keeps this Mac's address from the page; the words say what it is. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>Some websites, like X and video calls, open live connections that can reach devices on your network.</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Websites you visit can ask to connect to a Bluetooth device. Yab asks you first, for each site.</string>
  <key>NSLocationUsageDescription</key>
  <string>Websites you visit can ask where you are. Yab asks you first, for each site.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Websites you visit can ask where you are. Yab asks you first, for each site.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>To show and join your next meeting, and add an event when you choose Add to calendar. Nothing leaves this Mac.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>To show and join your next meeting, and add an event when you choose Add to calendar. Nothing leaves this Mac.</string>
  <key>NSContactsUsageDescription</key>
  <string>To fill in your own address from your card in Contacts, when you ask. Yab reads only your card, and nothing leaves this Mac.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder, and an agent you ask can read files there.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>An agent you ask can read and change files in your Documents folder.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>An agent you ask can read and change files on your Desktop.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>An agent you ask can read and change files on this disk.</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>An agent you ask can read and change files on this network disk.</string>
  ${GOOGLE_KEYS}
</dict>
</plist>
PLIST

# SwiftPM builds the executable, but doesn't run Xcode's App Intents metadata
# extraction phase. Compile the small declarations file once for its constant
# values, then let Apple's processor put the actions into the app bundle.
# The temporary definitions satisfy references to the browser without building
# the entire UI a second time; the real executable was compiled above.
INTENTS="$SCRATCH/app-intents"
mkdir -p "$INTENTS"
cat > "$INTENTS/bridge.swift" <<'SWIFT'
import Foundation
struct Bookmark { static func keepable(_ url: URL) -> Bool { true } }
enum Links {
    static func take(_ url: URL) {}
    @MainActor static func requestNewTab() {}
}
enum SystemIntentsBridge {
    static var siriEnabled: Bool { true }
}
SWIFT
printf '%s\n' '["AppIntent","AppEntity","AppShortcutsProvider"]' > "$INTENTS/protocols.json"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TRIPLE="$(uname -m)-apple-macosx$MINIMUM"
xcrun swiftc -parse-as-library -whole-module-optimization -c \
  -module-name Fast -target "$TRIPLE" -sdk "$SDK" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS/protocols.json" \
  -emit-const-values-path "$INTENTS/Fast.swiftconstvalues" \
  Sources/Fast/SystemIntents.swift "$INTENTS/bridge.swift" -o "$INTENTS/Fast.o"
printf '%s\n' "$PWD/Sources/Fast/SystemIntents.swift" > "$INTENTS/sources.list"
printf '%s\n' "$PWD/$INTENTS/Fast.swiftconstvalues" > "$INTENTS/const.list"
xcrun appintentsmetadataprocessor --output "$PWD/$APP/Contents/Resources" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name Fast --sdk-root "$SDK" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target "$MINIMUM" --target-triple "$TRIPLE" \
  --source-file-list "$PWD/$INTENTS/sources.list" \
  --swift-const-vals-list "$PWD/$INTENTS/const.list" --force
test -s "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [ -n "$APP_KEY" ] && [ "$(python3 scripts/runs/build_cache.py app-key "$CONFIG" "$ARCH_KEY" 2>/dev/null || true)" = "$APP_KEY" ]; then
  python3 scripts/runs/build_cache.py app-store "$APP_KEY" "$APP" || echo "app cache: not saved" >&2
fi
fi # YAB_APP_HIT

# Where this build looks for newer ones. Left out when there is nowhere to
# look, and then the app never checks: see Updater.feed.
# yab Dev is never updated: it is whatever was last built here.
if [ -n "${YAB_DOWNLOAD_URL:-}" ] && [ "$STEP" != "app" ]; then
  /usr/libexec/PlistBuddy -c "Add :YabFeed string ${YAB_DOWNLOAD_URL%/}/appcast.json" "$APP/Contents/Info.plist"
fi

# Task release artifacts carry the job name before their final signature.
if [ -n "${YAB_TASK_NAME:-}" ]; then
  python3 - "$APP/Contents/Info.plist" "$YAB_TASK_NAME" <<'PYNAME'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info['CFBundleName'] = info['CFBundleDisplayName'] = sys.argv[2]
path.write_bytes(plistlib.dumps(info, sort_keys=False))
PYNAME
fi

if [ "$STEP" = app ] && [ "${YAB_LAUNCH_PREVIEW:-}" = 1 ]; then
  /usr/libexec/PlistBuddy -c "Add :YabLaunchArrivalPreview bool true" "$APP/Contents/Info.plist"
fi

# A debug build (docs/debug-builds.md): YAB_DEBUG names what its journal
# writes down (DebugLog), "pip" for the floating window, and turns on the
# freeze watch.
if [ -n "${YAB_DEBUG:-}" ]; then
  /usr/libexec/PlistBuddy -c "Delete :YabDebug" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :YabDebug string $YAB_DEBUG" "$APP/Contents/Info.plist"
fi

# Signing. A Developer ID certificate, when there is one, with the hardened
# runtime Gatekeeper insists on for anything notarised; otherwise ad-hoc,
# which is enough for the app to run on the machine that built it, and
# which the updater refuses to swap anything in under.
# Yab's own team first: adhd's keychain also holds another company's
# Developer ID, listed before ours, and builds there were signed with it.
DEVELOPER_IDS="$(security find-identity -v -p codesigning ${IDENTITY_KEYCHAIN_ARGS[@]+"${IDENTITY_KEYCHAIN_ARGS[@]}"} 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)"
IDENTITY="${YAB_SIGN_IDENTITY:-$( { grep -F '(25UG4QYN9F)' <<<"$DEVELOPER_IDS" || head -1 <<<"$DEVELOPER_IDS"; } | head -1 || true)}"
# YAB_SIGN_IDENTITY=- signs ad hoc even where a Developer ID is in the
# keychain: a contributor's own certificate is not needed for a dev build.
[ "$IDENTITY" != - ] || IDENTITY=""
# Some entitlements only work with a Developer ID provisioning profile that
# carries them: passkeys (Apple grants browsers it on request) and site
# notifications that show the sender's face (Communication Notifications,
# SiteNotices). A restricted entitlement with no profile behind it is an app
# that won't open, so each goes in only when the profile says so, and the
# profile only into the app whose id it was made for: yab, never yab Dev.
ENTITLEMENTS="yab.entitlements"
PROFILE="${YAB_PROVISION_PROFILE:-yab.provisionprofile}"
if [ -f "$PROFILE" ]; then
  if python3 - "$PROFILE" yab.entitlements build/entitlements.plist "$BUNDLE_ID" <<'PYPROFILE'
import plistlib, sys
# The profile's plist lies in its signed envelope as it is: read straight
# out, with no keychain (security cms needs one, which SSH and launchd
# jobs may not have).
raw = open(sys.argv[1], 'rb').read()
start, end = raw.find(b'<?xml'), raw.find(b'</plist>')
if start < 0 or end < 0:
    print('profile: unreadable; signed without it')
    sys.exit(1)
profile = plistlib.loads(raw[start:end + len(b'</plist>')])
granted = profile.get('Entitlements', {})
app_id = granted.get('com.apple.application-identifier', '')
if app_id.split('.', 1)[-1] != sys.argv[4]:
    print(f"profile: made for {app_id}, not {sys.argv[4]}; signed without it")
    sys.exit(1)
entitlements = plistlib.loads(open(sys.argv[2], 'rb').read())
# How macOS ties the app to the profile: without these the rest is refused.
for key in ('com.apple.application-identifier', 'com.apple.developer.team-identifier'):
    entitlements[key] = granted[key]
carried = [key for key in ('com.apple.developer.web-browser.public-key-credential',
                           'com.apple.developer.usernotifications.communication',
                           'com.apple.developer.usernotifications.time-sensitive') if granted.get(key) is True]
for key in carried:
    entitlements[key] = True
open(sys.argv[3], 'wb').write(plistlib.dumps(entitlements))
print('profile: ' + (', '.join(key.rsplit('.', 1)[-1] for key in carried) or 'nothing restricted'))
PYPROFILE
  then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENTITLEMENTS="build/entitlements.plist"
  fi
fi
if [ -n "$IDENTITY" ] && ! unlock_found_keychain; then
  IDENTITY=""
fi
# The updater agent is signed on its own and again after --deep, which
# hands nested code the app's entitlements: it needs none, and a restricted
# one from the profile on a helper without one is a process macOS kills.
# Then the app once more, without --deep, so its seal covers the helper as
# it is now.
UPDATER="$APP/Contents/MacOS/YabUpdater"
if [ "${YAB_CEF:-0}" = 1 ]; then
  case "$ARCH_KEY" in arm64|universal) ;; *) echo 'YAB_CEF=1 requires an arm64 slice' >&2; exit 1 ;; esac
  CEF_DIR="${YAB_CEF_DIR:-$(bash scripts/cef/fetch.sh)}"
  CEF_HELPER="${YAB_CEF_HELPER:-}"
  if [ -z "$CEF_HELPER" ]; then
    [ "$STEP" = app ] || { echo 'CEF: production assembly requires the real YAB_CEF_HELPER' >&2; exit 1; }
    CEF_HELPER="build/cef-helper-stub"
    xcrun clang -arch arm64 -mmacosx-version-min="$MINIMUM" -O2 \
      scripts/cef/helper-stub.c -o "$CEF_HELPER"
    echo 'CEF: using packaging stub; set YAB_CEF_HELPER for the real YabCore host'
  fi
  if [ "$STEP" != app ]; then
    case "$IDENTITY" in ''|-) echo 'CEF: production assembly requires Developer ID signing' >&2; exit 1 ;; esac
    [ "$(basename "$CEF_HELPER")" = YabCore ] || { echo 'CEF: production helper must be YabCore, not a packaging stub' >&2; exit 1; }
  fi
  YAB_SIGN_KEYCHAIN="${YAB_SIGN_KEYCHAIN:-}" bash scripts/cef/embed.sh \
    "$APP" "$CEF_DIR" "$CEF_HELPER" "${IDENTITY:--}" "$ENTITLEMENTS"
elif [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$APP"
  codesign --force --timestamp --options runtime --identifier "$BUNDLE_ID.updater" \
    ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$UPDATER"
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  codesign --force --identifier "$BUNDLE_ID.updater" --sign - "$UPDATER"
  codesign --force --sign - "$APP"
  [ "$STEP" != "app" ] && echo "no Developer ID certificate found, the DMG will only open on this Mac" >&2
fi
codesign --verify --deep --strict "$APP"

case "$STEP" in prod|dmg|ship) python3 scripts/release/sdk_guard.py "$APP" ;; esac

echo "built: $APP ($VERSION, build $BUILD)"
case "$STEP" in app|prod) exit 0 ;; esac

# Shipping, the app is notarised before anything is packed: Apple looks it
# over, and the ticket is stapled to the bundle itself. Then the copy inside
# the disk image can say it is notarised on a Mac that is offline, which is
# what lets Open yab take the quarantine flag off it, so macOS asks once, not
# twice, and the ZIP the updater fetches carries the same stapled app.
[ "$STEP" = "ship" ] && [ -z "$IDENTITY" ] && { echo "can't ship without a Developer ID certificate" >&2; exit 1; }
ZIP="build/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
# Apple's ticket can lag behind "Accepted" by a minute or two.
staple() {
  local tries=0
  until xcrun stapler staple "$1"; do
    tries=$((tries + 1))
    [ "$tries" -lt 6 ] || return 1
    sleep 20
  done
}

if [ "$STEP" = "ship" ]; then
  unlock_release_keychain
  xcrun notarytool submit "$ZIP" --keychain-profile "${YAB_NOTARY_PROFILE:-yab}" ${NOTARY_KEYCHAIN_ARGS[@]+"${NOTARY_KEYCHAIN_ARGS[@]}"} --wait
  # Each embedded helper carries its own offline ticket. The
  # accepted parent submission covers these signatures; this submits no code.
  python3 scripts/security/staple_nested.py "$APP"
  staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi
# The ZIP is what the updater fetches, and its hash is what the updater
# checks before opening it.
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "packed: $ZIP"
# An arm64-only release half is the ZIP alone: the public disk image stays the
# universal one, and the site's row comes from its half API (worker.sh).
if [ "${YAB_ZIP_ONLY:-}" = 1 ]; then
  echo "shipped: $ZIP only (YAB_ZIP_ONLY: no disk image, no appcast)"
  exit 0
fi

# Open yab: the one thing in the disk image, see Installer/Open/main.swift.
# A small app of its own, built for both kinds of Mac and for older macOS
# than yab's, so that on a Mac yab can't run on it can say why. yab.app
# goes inside it whole, signature and staple untouched: the launcher is
# signed around it, not through it.
LAUNCHER="build/installer/Open yab.app"
rm -rf build/installer
mkdir -p "$LAUNCHER/Contents/MacOS" "$LAUNCHER/Contents/Resources/Payload"
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos12" Installer/Open/*.swift \
    -o "build/installer/open-$ARCH" 2>/dev/null
done
lipo -create build/installer/open-arm64 build/installer/open-x86_64 -output "$LAUNCHER/Contents/MacOS/Open yab"
rm -f build/installer/open-*
strip -x "$LAUNCHER/Contents/MacOS/Open yab"
ditto "$APP" "$LAUNCHER/Contents/Resources/Payload/$NAME.app"
# The disk image's window is dark whatever the Mac's look, so Open yab and
# the volume wear the icon on its dark square in both looks: Icon/yab.icon
# again, its light look's square ("automatic") made the dark one's.
DARK="$PWD/build/icon-dark"
rm -rf "$DARK"
mkdir -p "$DARK"
cp -R Icon/yab.icon "$DARK/yab.icon"
sed -E -i '' 's/"value" *: *"automatic"/"value": { "solid": "extended-srgb:0.07843,0.07843,0.07843,1.00000" }/' "$DARK/yab.icon/icon.json"
xcrun actool "$DARK/yab.icon" --compile "$DARK" \
  --output-partial-info-plist "$DARK/partial.plist" \
  --app-icon yab --include-all-app-icons --enable-on-demand-resources NO \
  --development-region en --target-device mac --platform macosx \
  --minimum-deployment-target "$MINIMUM" --errors --warnings > /dev/null
cp "$DARK/Assets.car" "$DARK/yab.icns" "$LAUNCHER/Contents/Resources/"
cp Icon/Mark.png "$LAUNCHER/Contents/Resources/Mark.png"
# Which image this launcher came in, so it puts away that one and no other.
STAMP="$BUILD-$(uuidgen)"
cat > "$LAUNCHER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Open Yab</string>
  <key>CFBundleDisplayName</key><string>Open Yab</string>
  <key>CFBundleExecutable</key><string>Open yab</string>
  <key>CFBundleIdentifier</key><string>dev.serafim.fast.installer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>yab</string>
  <key>CFBundleIconName</key><string>yab</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <!-- No Dock icon for the half second it usually runs; it takes one when
       it has a window to show. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>YabImageStamp</key><string>$STAMP</string>
</dict>
</plist>
PLIST
if [ -n "$IDENTITY" ]; then
  unlock_release_keychain
  codesign --force --timestamp --options runtime ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$LAUNCHER"
else
  codesign --force --sign - "$LAUNCHER" 2>/dev/null || true
fi
codesign --verify --deep --strict "$LAUNCHER"

# The disk image: Open yab alone, on the welcome's dark ground and light,
# drawn by Installer/background.swift and laid out by Installer/dmg.py
# through dmgbuild, which writes the Finder's layout file itself, so no
# Finder is scripted and no window opens mid-build. dmgbuild is installed
# into .build the first time, and needs Python 3 and a network then;
# without it the image is a plain one with Open yab in it.
DMG="build/$NAME.dmg"
ART="build/installer/art"
rm -f "$DMG"
DMGBUILD=".build/dmgbuild/bin/dmgbuild"
# A venv made where the repository used to be points at a python that is no
# longer there: made again, rather than trusted because the file exists.
if [ ! -x "$DMGBUILD" ] || ! "$DMGBUILD" --help >/dev/null 2>&1; then
  rm -rf .build/dmgbuild
  { python3 -m venv .build/dmgbuild && .build/dmgbuild/bin/pip install --quiet "dmgbuild==1.6.7"; } >/dev/null 2>&1 || true
fi
if [ -x "$DMGBUILD" ] \
  && swift Installer/background.swift "$ART" >/dev/null \
  && tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1
then
  "$DMGBUILD" -s Installer/dmg.py \
    -D launcher="$LAUNCHER" -D background="$ART/background.tiff" -D icon="$DARK/yab.icns" \
    "$NAME" "$DMG" >/dev/null
else
  echo "note: no dmgbuild, a plain disk image, without its window laid out" >&2
  hdiutil create -volname "$NAME" -srcfolder "$LAUNCHER" -ov -format UDZO -quiet "$DMG"
fi
rm -rf build/installer
if [ -n "$IDENTITY" ]; then
  unlock_release_keychain
  codesign --force --timestamp ${SIGN_KEYCHAIN_ARGS[@]+"${SIGN_KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$DMG"
fi
echo "packed: $DMG"

# What the updater reads. The newest release's notes, NOTES.md up to its
# first ---, as a JSON string.
if [ -z "${YAB_DOWNLOAD_URL:-}" ]; then
  echo "no appcast: YAB_DOWNLOAD_URL isn't set, so this build doesn't update itself"
else
BASE="${YAB_DOWNLOAD_URL%/}"
NOTES='""'
if [ -f NOTES.md ]; then
  NOTES="$(awk '/^---[[:space:]]*$/ { exit } { print }' NOTES.md | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read().strip()))')"
fi
cat > build/appcast.json <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$BASE/$NAME.zip",
  "dmg": "$BASE/$NAME.dmg",
  "sha256": "$SHA",
  "notes": $NOTES,
  "changelog": "${YAB_CHANGELOG_URL:-$BASE/changelog/$VERSION}",
  "minimumSystemVersion": "$MINIMUM"
}
JSON
echo "wrote: build/appcast.json ($VERSION, build $BUILD)"
fi
[ "$STEP" = "dmg" ] && exit 0

# The image is notarised too, and its ticket stapled, so it opens on a Mac
# that has never seen this app and is offline.
unlock_release_keychain
xcrun notarytool submit "$DMG" --keychain-profile "${YAB_NOTARY_PROFILE:-yab}" ${NOTARY_KEYCHAIN_ARGS[@]+"${NOTARY_KEYCHAIN_ARGS[@]}"} --wait
staple "$DMG"
echo "shipped: $DMG and $ZIP, ./release.sh is what puts a build on the site"
