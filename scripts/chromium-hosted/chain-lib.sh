#!/bin/bash
# Shared functions for the hosted Chromium chain and the APK CI. Sourced, not
# executed. All state lives under ROOT; releases carry the bytes between
# jobs and runs (GitHub artifacts cap at 10 GB per artifact and cannot be
# streamed per part; release assets cap at 2 GB per file, which the packer
# respects by chunking, and they survive across runs so the APK CI can reuse
# the latest successful base).

# shellcheck shell=bash
# shellcheck disable=SC2034
# Variables below are used by chain.sh, which sources this file; shellcheck
# cannot see cross-file usage, so SC2034 on them is a false positive.

set -euo pipefail

ROOT="$HOME/yab-chromium"
SRC="$ROOT/checkout/src"
GEN_OUT_NAME="out/YabDesktopArm64"
PARTS="$ROOT/parts"
CONFIG_DIR="${CONFIG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONFIG="$CONFIG_DIR/baseline.json"
ZSTD_LEVEL="${ZSTD_LEVEL:-12}"
PART_BYTES="${PART_BYTES:-1900M}"
PACK_MIN_FREE_MB="${PACK_MIN_FREE_MB:-2048}"
STAMP_NAME=.chain-stamp
DONE_MARKER_NAME=".chain-done"
CHAIN_TAG="${CHAIN_TAG:-chromium-chain-state}"
BASE_TAG="${BASE_TAG:-chromium-base}"

log() { echo "chain: $*" >&2; }
die() { log "$*"; exit 1; }

config_value() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CONFIG" "$1"; }

stamp_content() { sha256sum "$CONFIG" | cut -d' ' -f1; }

write_stamp() { stamp_content > "$ROOT/$STAMP_NAME"; }

check_stamp() {
  [ -f "$ROOT/$STAMP_NAME" ] || die "no chain stamp under $ROOT; tree did not come from prepare"
  [ "$(cat "$ROOT/$STAMP_NAME")" = "$(stamp_content)" ] \
    || die "chain stamp mismatch: tree was prepared from a different baseline.json"
}

# Free runner disk like ungoogled-chromium-android does: drop preinstalled
# toolchains the build never uses. /mnt is root-owned, so everything lives
# under $HOME (same filesystem; measured 108 GB free after cleanup).
light_disk() {
  sudo rm -rf /usr/local/lib/android /usr/local/.ghcup /usr/lib/jvm \
    /usr/lib/google-cloud-sdk /usr/lib/dotnet /usr/share/swift /opt/hostedtoolcache
  sudo apt-get remove -y --purge azure-cli google-chrome-stable firefox powershell \
    mono-complete > /dev/null 2>&1 || true
  sudo apt-get update -qq
  sudo apt-get install -y -qq zstd lsb-release > /dev/null
  df -h / | tail -1
}

# The libchrome.so link peaks above runner RAM; swap keeps it alive.
ensure_swap() {
  swapon --show | grep -q chain.swap && return 0
  sudo fallocate -l 6G "$ROOT/chain.swap"
  sudo chmod 600 "$ROOT/chain.swap"
  sudo mkswap "$ROOT/chain.swap" > /dev/null
  sudo swapon "$ROOT/chain.swap" || true
}

# Cache env mirroring the sandbox bootstrap: tool writes land inside ROOT.
export_cache_env() {
  mkdir -p "$ROOT/cache/cipd" "$ROOT/cache/vpython" "$ROOT/tmp"
  export CIPD_CACHE_DIR="$ROOT/cache/cipd" VPYTHON_VIRTUALENV_ROOT="$ROOT/cache/vpython"
  export XDG_CACHE_HOME="$ROOT/cache" TMPDIR="$ROOT/tmp"
  export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0
  export PATH="$PATH:$ROOT/tools/depot_tools"
}

# Same flags as the verified sandbox run. install-build-deps.py at the pinned
# revision supports resolute (26.04), checked in its check_distro.
ensure_system_deps() {
  (cd "$SRC" && sudo python3 build/install-build-deps.py --android --no-arm \
    --no-chromeos-fonts --no-nacl --no-prompt) > "$ROOT/deps.log" 2>&1 \
    || die "install-build-deps failed (see $ROOT/deps.log)"
}

# Release transport. GH_TOKEN comes from the workflow env.
repo() { echo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"; }

rel_ensure() {
  local tag="$1"
  gh release view "$tag" -R "$(repo)" > /dev/null 2>&1 && return 0
  gh release create "$tag" -R "$(repo)" --target "${GITHUB_SHA:?}" \
    --title "$tag" --notes "Chain transport. Do not edit; managed by CI." > /dev/null
}

rel_asset_names() { gh release view "$1" -R "$(repo)" --json assets --jq '.assets[].name'; }

rel_delete_asset() {
  local tag="$1" name="$2"
  local id
  id="$(gh release view "$tag" -R "$(repo)" --json assets --jq ".assets[] | select(.name == \"$name\") | .id")"
  [ -n "$id" ] || return 0
  gh api -X DELETE "repos/$(repo)/releases/assets/$id" || true
}

rel_upload_one() {
  local tag="$1" file="$2"
  gh release upload "$tag" "$file" -R "$(repo)" --clobber > /dev/null
}

rel_download_one() {
  local tag="$1" name="$2" dir="$3"
  gh release download "$tag" -R "$(repo)" --pattern "$name" --dir "$dir" > /dev/null
}

rel_delete() {
  gh release delete "$1" -R "$(repo)" --yes --cleanup-tag || true
}

# Drop every asset of one packed set, e.g. a superseded out generation.
drop_set() {
  local tag="$1" set_name="$2"
  while read -r name; do
    case "$name" in "$set_name"-part.*|"$set_name"-manifest.txt) rel_delete_asset "$tag" "$name" ;; esac
  done < <(rel_asset_names "$tag")
}

# Pack DIRS into zstd parts and upload each part as soon as split finishes
# writing it, deleting locally after upload. This keeps the disk peak at
# tree + one part instead of tree + whole packed copy. The stamp travels in
# every set so an unpacked tree always carries its provenance. EXCLUDE (a
# tar glob, "" for none) keeps the out dir out of the src set: without it
# the src pack at finish would re-upload the whole built out dir. Manifest
# goes up last and embeds the chain stamp.
pack_stream_upload() {
  local set_name="$1" tag="$2" exclude="$3"
  shift 3
  cd "$ROOT"
  local stamp
  stamp="$(stamp_content)"
  rel_ensure "$tag"
  # Drop stale assets from a previous attempt of the same set.
  while read -r name; do
    case "$name" in "$set_name"-part.*|"$set_name"-manifest.txt) rel_delete_asset "$tag" "$name" ;; esac
  done < <(rel_asset_names "$tag")

  mkdir -p "$PARTS"
  rm -f "$PARTS/$set_name"-part.* "$PARTS/$set_name"-manifest.txt
  local manifest="$PARTS/$set_name-manifest.txt"
  : > "$manifest"

  local tar_opts=(--format=pax -cf -)
  [ -n "$exclude" ] && tar_opts+=("--exclude=$exclude")
  # Subshell so pipefail reaches wait: without it, wait would report only
  # split's exit status and a tar failure would pass silently.
  ( tar "${tar_opts[@]}" "$@" "$STAMP_NAME" 2> "$PARTS/$set_name-tar.err" \
    | zstd -T0 -"$ZSTD_LEVEL" \
    | split -b "$PART_BYTES" -d - "$PARTS/$set_name-part." ) &
  local pack_pid=$!

  # Watcher: a part is complete once split moves on to the next name, or the
  # packer exits. sha256 then upload then delete, in order. Manifest lines are
  # "name hash" (not sha256sum's "hash  path" format) so download parses
  # cleanly and the part name survives the absolute local path.
  local uploaded=0 name next hash free_mb
  while kill -0 "$pack_pid" 2> /dev/null || [ -n "$(next_pending_part "$set_name" "$uploaded")" ]; do
    next="$(next_pending_part "$set_name" "$uploaded")"
    if [ -z "$next" ]; then
      # Nothing to drain: let the producer run even if the floor was hit on
      # the previous pass, or the pack freezes for good.
      kill -CONT "$pack_pid" 2> /dev/null || true
      sleep 5
      continue
    fi
    # tar+zstd+split runs unthrottled: when the upload is slower than the
    # pack, parts accumulate and can fill the runner disk mid-set. Hold the
    # producer below the free-space floor; the upload of this very part
    # frees ~one part, so the hold always lifts itself.
    free_mb="$(df -Pm "$PARTS" | awk 'NR==2 {print $4}')"
    if [ "$free_mb" -lt "$PACK_MIN_FREE_MB" ]; then
      kill -STOP "$pack_pid" 2> /dev/null || true
    else
      kill -CONT "$pack_pid" 2> /dev/null || true
    fi
    name="$(basename "$next")"
    hash="$(sha256sum "$next" | cut -d' ' -f1)"
    printf '%s %s\n' "$name" "$hash" >> "$manifest"
    rel_upload_one "$tag" "$next"
    rm -f "$next"
    uploaded=$((uploaded + 1))
  done
  wait "$pack_pid" || die "pack of $set_name failed: $(tail -3 "$PARTS/$set_name-tar.err")"

  # Drain parts the watcher could not see as complete (the last one has no
  # successor to signal it finished).
  while [ -f "$PARTS/$set_name-part.$(printf '%02d' "$uploaded")" ]; do
    next="$PARTS/$set_name-part.$(printf '%02d' "$uploaded")"
    hash="$(sha256sum "$next" | cut -d' ' -f1)"
    printf '%s %s\n' "$(basename "$next")" "$hash" >> "$manifest"
    rel_upload_one "$tag" "$next"
    rm -f "$next"
    uploaded=$((uploaded + 1))
  done
  [ -s "$PARTS/$set_name-tar.err" ] \
    && die "pack of $set_name failed: $(tail -3 "$PARTS/$set_name-tar.err")"
  [ "$uploaded" -le 99 ] || die "$set_name: more than 99 parts; lower PART_BYTES"

  echo "$stamp $uploaded" >> "$manifest"
  rel_upload_one "$tag" "$manifest"
  rm -f "$manifest"
  log "uploaded $set_name: $uploaded part(s) to $tag"
}

# Next completed part file for the watcher: part index N is complete when
# part N+1 exists or the packer is gone.
next_pending_part() {
  local set_name="$1" uploaded="$2" candidate next_name
  candidate="$PARTS/$set_name-part.$(printf '%02d' "$uploaded")"
  [ -f "$candidate" ] || return 0
  next_name="$PARTS/$set_name-part.$(printf '%02d' "$((uploaded + 1))")"
  if [ -f "$next_name" ]; then
    echo "$candidate"
  fi
}

# Download a packed set and unpack with streaming delete: each part is
# downloaded, checksummed, fed into the unpack pipe and deleted before the
# next part downloads, so the disk peak stays at tree-so-far + one part,
# never the tree plus all packed parts at once.
download_unpack() {
  local set_name="$1" tag="$2"
  local manifest="$PARTS/$set_name-manifest.txt"
  mkdir -p "$PARTS"
  rm -f "$PARTS/$set_name"-part.* "$manifest"

  rel_download_one "$tag" "$set_name-manifest.txt" "$PARTS"
  local stamp count
  read -r stamp count < <(tail -1 "$manifest")
  [ "$stamp" = "$(stamp_content)" ] \
    || die "$set_name: stamp mismatch (packed from a different baseline.json)"
  [ "$count" -gt 0 ] || die "$set_name: empty manifest"

  # Feed parts into the unpack pipe one at a time. The whole loop runs in a
  # subshell on the left of the pipeline, so a checksum failure kills the
  # pipe and tar dies on truncated input instead of unpacking garbage.
  local i=0 line name expected actual file
  while IFS= read -r line; do
    i=$((i + 1))
    [ "$i" -le "$count" ] || break
    name="${line%% *}"
    expected="${line##* }"
    rel_download_one "$tag" "$name" "$PARTS"
    file="$PARTS/$name"
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] || { log "$set_name/$name: checksum mismatch"; exit 1; }
    cat "$file"
    rm -f "$file"
  done < <(sed '$d' "$manifest") \
    | zstd -dc -T0 | tar -x -C "$ROOT" || die "$set_name: unpack failed"

  rm -f "$PARTS"/"$set_name"-part.* "$manifest"
  check_stamp
  log "imported $set_name ($count parts) from $tag"
}

# Test data the chrome_public_apk graph never reads; deleting it before
# gn gen keeps it out of the graph and ~4 GB off every disk budget.
prune_test_data() {
  rm -rf "$SRC/third_party/blink/web_tests" \
    "$SRC/media/test/data" "$SRC/media/cdm/test/data" \
    "$SRC/v8/test/test262" "$SRC/chrome/test/data"
}

latest_out_state() {
  # Highest uploaded out-pK set in the chain release, or empty if none.
  # Prepare uploads generation 0, so the scan must accept k=0: seeding best
  # with 0 and requiring k>best ignored the only state a fresh chain run has,
  # and every resume died with "no out state".
  local best="" name k
  while read -r name; do
    case "$name" in
      out-p*-manifest.txt)
        k="${name#out-p}"; k="${k%%-*}"
        if [ -z "$best" ] || [ "$k" -gt "$best" ]; then best="$k"; fi
        ;;
    esac
  done < <(rel_asset_names "$CHAIN_TAG")
  if [ -n "$best" ]; then echo "out-p$best"; fi
}

# Drop every out-pK generation from the chain release. Prepare calls this so
# a fresh chain run cannot be poisoned by stale generations from an older
# failed run (latest_out_state picks the highest index, not the newest).
drop_all_out_sets() {
  local name k
  while read -r name; do
    case "$name" in
      out-p*-part.*|out-p*-manifest.txt)
        k="${name#out-p}"; k="${k%%-*}"
        drop_set "$CHAIN_TAG" "out-p$k"
        ;;
    esac
  done < <(rel_asset_names "$CHAIN_TAG" | sort -u)
}