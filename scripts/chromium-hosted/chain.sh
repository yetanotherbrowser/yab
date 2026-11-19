#!/bin/bash
# Hosted Chromium chain driver for the Yab fork. Serves two workflows:
#
#   chromium-hosted-build.yml: prepare -> resume parts -> finish
#     Build the pristine baseline (pinned revisions, no adapter patch) on
#     stock runners too small for one job, exactly like
#     ungoogled-chromium-android chains build-tree artifacts, but moving the
#     bytes through release assets (see chain-lib.sh for why).
#
#   chromium-apk.yml: apk
#     Download the finished base from the chromium-base release, apply the
#     yab adapter patch, incrementally rebuild, package the Yab engine APK.
#
# Usage: chain.sh {prepare|resume|finish|apk}
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=chain-lib.sh
source "$here/chain-lib.sh"

BUILD_SECONDS="${BUILD_SECONDS:-15000}"

clone_pinned() {
  local dir="$1" url="$2" rev="$3"
  mkdir -p "$dir"
  if [ ! -d "$dir/.git" ]; then
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    git -C "$dir" fetch --depth=1 -q origin "$rev"
    git -C "$dir" checkout --detach -q FETCH_HEAD
  fi
  [ "$(git -C "$dir" rev-parse HEAD)" = "$rev" ] || die "$dir is not at the pinned revision"
}

prepare() {
  light_disk
  export_cache_env
  mkdir -p "$ROOT"/{checkout,tools}
  cd "$ROOT"

  clone_pinned tools/depot_tools "$(config_value depotToolsRepository)" "$(config_value depotToolsRevision)"
  clone_pinned checkout/src "$(config_value chromiumRepository)" "$(config_value chromiumRevision)"

  cat > checkout/.gclient <<EOF
solutions = [{'name': 'src', 'url': '$(config_value chromiumRepository)', 'deps_file': 'DEPS', 'managed': False, 'custom_deps': {}, 'custom_vars': {}}]
target_os = ['android']
EOF

  "$ROOT"/tools/depot_tools/ensure_bootstrap > prep-bootstrap.log 2>&1 || die "depot_tools bootstrap failed"
  cd checkout
  "$ROOT"/tools/depot_tools/gclient sync --nohooks --noprehooks --no-history --jobs 8 \
    --revision "src@$(config_value chromiumRevision)" || die "gclient sync failed"

  ensure_system_deps
  "$ROOT"/tools/depot_tools/gclient runhooks > prep-hooks.log 2>&1 || die "runhooks failed"

  # The chain never runs gclient again; dep metadata is dead weight on the
  # packed tree. Stripping .git only after runhooks: the LASTCHANGE hook
  # reads git history to stamp the version.
  find "$ROOT/checkout" -name .git -type d -prune -exec rm -rf {} +

  mkdir -p "src/$GEN_OUT_NAME"
  python3 - <<PYEOF
import json
args = json.load(open("$CONFIG"))["gnArgs"]
open("src/$GEN_OUT_NAME/args.gn", "w").write(
    "\n".join(f"{k} = {json.dumps(v)}" for k, v in args.items()) + "\n")
PYEOF
  (cd src && "$ROOT/tools/depot_tools/gn" gen "$GEN_OUT_NAME" --fail-on-unused-args) \
    || die "gn gen failed"
  # Prune only after gen: GN validates listed sources for every target while
  # generating, so deleting test data first could fail gen. Ninja reads only
  # the built target's inputs, and chrome_public_apk never touches these.
  prune_test_data

  write_stamp
  # Fresh chain run: stale assets from an older failed run must not poison
  # this one. latest_out_state picks the highest index, so purge everything.
  drop_all_out_sets
  drop_set "$CHAIN_TAG" src
  pack_stream_upload src "$CHAIN_TAG" "checkout/src/out" checkout tools
  pack_stream_upload out-p0 "$CHAIN_TAG" "" "checkout/src/out"
  log "prepare: baseline generated and uploaded"
}

# Import the latest state and build until the time budget ends, then upload
# the out dir as the next generation for the following part.
resume() {
  light_disk
  export_cache_env
  ensure_swap
  local state
  state="$(latest_out_state)"
  [ -n "$state" ] || die "no out state in $CHAIN_TAG; run prepare first"
  download_unpack src "$CHAIN_TAG"
  download_unpack "$state" "$CHAIN_TAG"
  local done_at_start="no"
  # The cd "$SRC" below has not run yet, so the out-relative marker path
  # needs the prefix; un-prefixed, a finished chain always re-uploads.
  [ -f "$SRC/$GEN_OUT_NAME/$DONE_MARKER_NAME" ] && done_at_start="yes"

  ensure_system_deps
  local target
  target="$(config_value target)"
  cd "$SRC"
  set +e
  timeout -k 5m -s INT "${BUILD_SECONDS}s" \
    "$ROOT/tools/depot_tools/autoninja" -C "$GEN_OUT_NAME" "$target"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ]; then
    die "ninja failed with exit $rc"
  fi
  [ "$rc" -eq 0 ] && touch "$GEN_OUT_NAME/$DONE_MARKER_NAME"

  local next_gen
  next_gen=$(( ${state#out-p} + 1 ))
  if [ "$done_at_start" = "yes" ]; then
    # The imported state was already complete; nothing to build or re-upload.
    # finish reads this same generation from the release.
    log "resume: BUILD COMPLETE (state stays $state)"
  elif [ -f "$GEN_OUT_NAME/$DONE_MARKER_NAME" ]; then
    # This slice finished the build; upload so finish sees the marker.
    pack_stream_upload "out-p$next_gen" "$CHAIN_TAG" "" "checkout/src/out"
    drop_set "$CHAIN_TAG" "$state"
    log "resume: BUILD COMPLETE (uploaded as out-p$next_gen)"
  else
    pack_stream_upload "out-p$next_gen" "$CHAIN_TAG" "" "checkout/src/out"
    # The old generation is superseded; drop its assets so the release does
    # not grow ~40 GB per part-job forever.
    drop_set "$CHAIN_TAG" "$state"
    log "resume: budget reached, state uploaded as out-p$next_gen"
  fi
}

# Ninth builder: run to completion, package the APK, and publish the base the
# APK CI reuses. Requires contents: write on GITHUB_TOKEN.
finish() {
  light_disk
  export_cache_env
  ensure_swap
  local state
  state="$(latest_out_state)"
  [ -n "$state" ] || die "no out state in $CHAIN_TAG; run prepare first"
  download_unpack src "$CHAIN_TAG"
  download_unpack "$state" "$CHAIN_TAG"
  ensure_system_deps

  local target
  target="$(config_value target)"
  cd "$SRC"
  "$ROOT/tools/depot_tools/autoninja" -C "$GEN_OUT_NAME" "$target" \
    || die "finish: final ninja failed"
  touch "$GEN_OUT_NAME/$DONE_MARKER_NAME"

  local apks_dir="$GEN_OUT_NAME/apks"
  ls "$apks_dir"/*.apk > /dev/null 2>&1 || die "no APK under $apks_dir"
  mkdir -p "$ROOT/apk-out"
  for apk in "$apks_dir"/*.apk; do
    cp "$apk" "$ROOT/apk-out/"
    sha256sum "$apk" | tee -a "$ROOT/apk-out/APK-SHA256SUMS"
  done

  # Publish the reusable base: same tree, second release. The APK CI reads
  # this and never touches the chain state. tools travels too: the APK job
  # runs autoninja out of depot_tools and has no other way to get it.
  pack_stream_upload src "$BASE_TAG" "checkout/src/out" checkout tools
  pack_stream_upload base "$BASE_TAG" "" "checkout/src/out"
  # The chain state is spent: the base now carries everything downstream
  # needs, so free ~100 GB of release storage and delete the transport tag.
  drop_all_out_sets
  drop_set "$CHAIN_TAG" src
  rel_delete "$CHAIN_TAG"
  log "finish: APK packaged, base published to $BASE_TAG"
}

# APK CI: reuse the published base, apply the adapter patch, rebuild the
# touched graph incrementally, package the Yab engine APK.
apk() {
  light_disk
  export_cache_env
  ensure_swap
  gh release view "$BASE_TAG" -R "$(repo)" > /dev/null 2>&1 \
    || die "no $BASE_TAG release: run the chromium-hosted-build workflow first"
  download_unpack src "$BASE_TAG"
  download_unpack base "$BASE_TAG"
  ensure_system_deps

  cd "$SRC"
  local expected_patch="d70300851d01a11ce601becd96dd9b56f6ad846f49f730ae979f8363a4ecffaa"
  local actual_patch
  actual_patch="$(sha256sum "$here/adapter/yab-chrome-adapter.patch" | cut -d' ' -f1)"
  [ "$actual_patch" = "$expected_patch" ] \
    || die "adapter patch hash mismatch: expected $expected_patch, got $actual_patch (see adapter/README.md)"
  patch -p1 --fuzz=0 < "$here/adapter/yab-chrome-adapter.patch" \
    || die "adapter patch did not apply cleanly against the base"

  local target
  target="$(config_value target)"
  "$ROOT/tools/depot_tools/autoninja" -C "$GEN_OUT_NAME" "$target" \
    || die "apk: incremental ninja failed (adapter patch may not compile)"

  local apks_dir="$GEN_OUT_NAME/apks"
  ls "$apks_dir"/*.apk > /dev/null 2>&1 || die "no APK under $apks_dir"
  mkdir -p "$ROOT/apk-out"
  for apk in "$apks_dir"/*.apk; do
    cp "$apk" "$ROOT/apk-out/"
    sha256sum "$apk" | tee -a "$ROOT/apk-out/APK-SHA256SUMS"
  done
  log "apk: Yab engine APK packaged"
}

case "${1:-}" in
  prepare) prepare ;;
  resume) resume ;;
  finish) finish ;;
  apk) apk ;;
  *) die "usage: chain.sh {prepare|resume|finish|apk}" ;;
esac