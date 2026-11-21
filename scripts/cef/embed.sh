#!/bin/bash
# Usage: embed.sh Yab.app CEF_DISTRIBUTION HELPER_EXECUTABLE IDENTITY [APP_ENTITLEMENTS]
# Seals the app last, without --deep (which would overwrite helper entitlements).
set -euo pipefail
[ "$#" -ge 4 ] && [ "$#" -le 5 ] || { echo "usage: $0 APP CEF_DIR HELPER IDENTITY [APP_ENTITLEMENTS]" >&2; exit 2; }
APP="$1" CEF="$2" HELPER="$3" IDENTITY="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="${5:-$HERE/../../yab.entitlements}"
for need in "-f:$APP/Contents/Info.plist" "-x:$HELPER" "-f:$ENTITLEMENTS"; do
  [ "${need%%:*}" "${need#*:}" ] || { echo "CEF: missing app, executable helper or entitlements: ${need#*:}" >&2; exit 1; }
done
[ -n "$IDENTITY" ] || { echo 'CEF: signing identity is required (use - for ad hoc)' >&2; exit 1; }
# Old diagnostic receipts pin a flat executable, not a signed nested bundle.
# Refuse before modifying the app rather than bypassing or invalidating the pin.
PREPARED_HELPER_INPUT="${YABCORE_PREPARED_HELPER_INPUT:-}"
if [ -n "$PREPARED_HELPER_INPUT" ]; then
  # A flat-file receipt cannot authorize the new bundle's resource seal.
  # Never silently resign an image pinned into the diagnostic Swift binary.
  echo 'CEF: flat prepared-helper receipts must be regenerated for the YabCore bundle layout' >&2
  exit 1
fi
SOURCE="$CEF/Release/Chromium Embedded Framework.framework"
[ -d "$SOURCE" ] || { echo 'CEF: Release framework missing' >&2; exit 1; }
[ -f "$CEF/LICENSE.txt" ] || { echo 'CEF: distribution license missing' >&2; exit 1; }
/usr/bin/python3 -I - "$APP" "$CEF" "$HELPER" <<'PY'
import pathlib, plistlib, re, subprocess, sys
app, cef, helper = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', info['CFBundleIdentifier']):
    sys.exit('CEF: invalid parent bundle identifier')
header = (cef / 'include/cef_version.h').read_text()
if not re.search(r'#define CEF_VERSION_MAJOR\s+156\b', header):
    sys.exit('CEF: requires CEF 156')
for binary in [helper, cef / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework']:
    arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
    if arch != 'arm64':
        sys.exit('CEF: minimal arm64 packaging requires arm64-only binaries: ' + str(binary))
parent_archs = set(subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True).split())
if 'arm64' not in parent_archs or not parent_archs <= {'arm64', 'x86_64'}:
    sys.exit('CEF: parent must contain arm64, optionally with an Intel WebKit slice')
PY
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
FRAMEWORK="$FRAMEWORKS/Chromium Embedded Framework.framework"
# Replace only this script's owned payload; repeated embedding keeps no stale files.
rm -rf "$FRAMEWORK"
ditto --noqtn "$SOURCE" "$FRAMEWORK"
mkdir -p "$APP/Contents/Resources"
cp "$CEF/LICENSE.txt" "$APP/Contents/Resources/CEF-LICENSE.txt"
/usr/bin/python3 -I - "$APP" "$HELPER" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
app, binary = map(Path, sys.argv[1:])
parent = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if binary.name == 'YabCore':
    target = app / 'Contents/MacOS/YabCore'
    if target.is_symlink():
        target.unlink()
    shutil.copy2(binary, target)
for suffix, identifier in [('', ''), (' (GPU)', '.gpu'), (' (Renderer)', '.renderer'), (' (Plugin)', '.plugin'), (' (Alerts)', '.alerts')]:
    name = 'YabCore Helper' + suffix
    bundle = app / 'Contents/Frameworks' / (name + '.app')
    if bundle.is_symlink():
        bundle.unlink()
    elif bundle.exists():
        shutil.rmtree(bundle)
    macos = bundle / 'Contents/MacOS'
    macos.mkdir(parents=True)
    # A real YabCore has a distinct CEF subprocess entry point. Never copy
    # its browser main into renderer/GPU bundles.
    source = binary.parent.parent / 'Frameworks' / (name + '.app') / 'Contents/MacOS' / name
    if binary.name == 'YabCore' and not source.is_file():
        sys.exit('CEF: real YabCore is missing its subprocess executable: ' + str(source))
    shutil.copy2(source if source.is_file() else binary, macos / name)
    info = dict(CFBundleName=name, CFBundleDisplayName=name, CFBundleExecutable=name,
                CFBundleIdentifier=parent['CFBundleIdentifier'] + '.helper' + identifier,
                CFBundlePackageType='APPL', CFBundleSignature='????',
                CFBundleDevelopmentRegion='en', CFBundleInfoDictionaryVersion='6.0',
                CFBundleVersion=parent['CFBundleVersion'],
                CFBundleShortVersionString=parent['CFBundleShortVersionString'],
                LSMinimumSystemVersion=parent.get('LSMinimumSystemVersion', '15.4'),
                LSUIElement=True, LSBackgroundOnly=True, LSFileQuarantineEnabled=True, LSEnvironment={'MallocNanoZone': '0'},
                NSHighResolutionCapable=True, NSSupportsAutomaticGraphicsSwitching=True)
    if suffix == ' (Alerts)':
        info['NSUserNotificationAlertStyle'] = 'alert'
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
    (bundle / 'Contents/PkgInfo').write_bytes(b'APPL????')
PY
SIGN=(--force --sign "$IDENTITY")
# Ad hoc code has no Team ID, so the hardened runtime's library validation
# refuses the ad hoc framework in every helper. build.sh's own ad hoc path
# signs without the runtime too.
if [ "$IDENTITY" = - ]; then SIGN+=(--timestamp=none); else SIGN+=(--options runtime --timestamp); fi
if [ -n "${YAB_SIGN_KEYCHAIN:-}" ]; then SIGN+=(--keychain "$YAB_SIGN_KEYCHAIN"); fi
# Sign every Mach-O leaf first, including framework dylibs and crashpad_handler.
# Materialize the list so an enumeration failure cannot disappear inside a pipe.
LIST="$(mktemp -t yab-cef-sign)"
trap 'rm -f "$LIST"' EXIT
/usr/bin/python3 -I - "$FRAMEWORK" > "$LIST" <<'PY'
from pathlib import Path
import sys
magic = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
for p in sorted(Path(sys.argv[1]).rglob('*'), key=lambda p: len(p.parts), reverse=True):
    if p.is_file() and not p.is_symlink():
        with p.open('rb') as stream:
            if stream.read(4) in magic:
                sys.stdout.buffer.write(bytes(p) + b'\0')
PY
while IFS= read -r -d '' BINARY; do
  codesign "${SIGN[@]}" "$BINARY"
done < "$LIST"
codesign "${SIGN[@]}" "$FRAMEWORK"
for SUFFIX in '' ' (GPU)' ' (Renderer)' ' (Plugin)' ' (Alerts)'; do
  ENT="$HERE/helper-entitlements.plist"
  case "$SUFFIX" in ' (GPU)'|' (Renderer)') ENT="$HERE/helper-jit-entitlements.plist" ;; esac
  codesign "${SIGN[@]}" --entitlements "$ENT" "$FRAMEWORKS/YabCore Helper$SUFFIX.app"
done
# The normal assembly also contains a Dock tile plug-in. Its signature must
# be made explicitly now that the parent is no longer signed with --deep.
if [ -d "$APP/Contents/PlugIns/YabDockTile.docktileplugin" ]; then
  codesign "${SIGN[@]}" "$APP/Contents/PlugIns/YabDockTile.docktileplugin"
fi
if [ -f "$APP/Contents/MacOS/YabCore" ]; then
  # Preserve the old code identifier for existing keychain access requirements
  # while changing its LaunchServices identity through the nested plist.
  codesign "${SIGN[@]}" --entitlements "$HERE/helper-entitlements.plist" "$APP/Contents/MacOS/YabCore"
  CORE_IDENTIFIER="$(codesign -dvv "$APP/Contents/MacOS/YabCore" 2>&1 | sed -n 's/^Identifier=//p')"
  [ -n "$CORE_IDENTIFIER" ] || { echo 'CEF: missing helper code identifier' >&2; exit 1; }
  python3 "$HERE/package_core.py" "$APP"
  codesign "${SIGN[@]}" --identifier "$CORE_IDENTIFIER" --entitlements "$HERE/helper-entitlements.plist" "$FRAMEWORKS/YabCore.app"
fi
UPDATER="$APP/Contents/MacOS/YabUpdater"
if [ -f "$UPDATER" ]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  codesign "${SIGN[@]}" --identifier "$BUNDLE_ID.updater" "$UPDATER"
fi
codesign "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
echo "CEF: embedded and signed inside out ($IDENTITY)"
