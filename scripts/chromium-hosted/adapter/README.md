# Yab Chromium adapter patch

`yab-chrome-adapter.patch` carries the Yab embedding changes against the
pinned Chromium baseline in `../baseline.json`: 27 files, of which 10 are
C++ (.cc/.h) and the rest Java/gni (chrome_java_sources.gni,
ChromeApplicationImpl.java, TabBuilder.java, TabImpl.java and the
org.chromium.chrome.browser.yab.* sources). Applied at `-p1` from the
Chromium src root by `chain.sh apk` on top of the base published by the
hosted chain.

Status, measured on 2026-11-18:

- sha256 of this file: `d70300851d01a11ce601becd96dd9b56f6ad846f49f730ae979f8363a4ecffaa`
- The snapshot receipt (`verification.json` in the engine snapshot) records
  `patchSha256 = 1c40380e...` for a patch with `applied: false,
  compiled: false`. That hash does not match this file. The receipt was
  written before the patch reached its final form; this file is the
  snapshot's measured bytes. The mismatch is unresolved: if a copy of the
  1c40380e patch exists anywhere it must be reconciled before either is
  trusted.
- This patch has never compiled as part of a full Chromium build. The
  only C++ syntax attempt failed on a missing generated header
  (event_dispatcher.mojom-forward.h) inside a minimal scaffold that had
  not run gn gen, which proves nothing either way about a full tree.
- Expect the APK CI job to fail fast if the patch does not apply cleanly
  against the base, and to fail loudly if the patched sources do not
  compile. That is the first real test this patch gets.

Do not regenerate this file without re-measuring and updating the hash
above, and without reconciling the receipt.