# Extension-specific source-build dependency

The official prebuilt CEF remains the runtime used by this track. No patch in
this directory is applied to it, and this directory does not change its build.

Full uBlock Origin is an explicit acceptance target, separate from the
catalog's uBlock Origin Lite. In Chromium 156.0.8078.96,
`extensions/browser/manifest_v2_handler.cc` blocks installation and enabling
of ordinary MV2 extensions. `ShouldDisableLegacyExtensions()` returns true
except for an in-process test-only override. The existing
`--allow-legacy-extension-manifests` switch affects manifest parsing in
`extensions/common/extension.cc`, but the handler does not honor it.
See the pinned upstream [handler](https://chromium.googlesource.com/chromium/src/+/156.0.8078.96/extensions/browser/manifest_v2_handler.cc)
and [manifest parser](https://chromium.googlesource.com/chromium/src/+/156.0.8078.96/extensions/common/extension.cc).

`mv2-legacy-switch.patch` is an **unapplied source-build proposal** for the
own-CEF track. It makes that existing explicit switch apply consistently to
the handler as well. It does not globally enable MV2 or alter the default.
Apply only after the own-CEF track's active compilation has finished, then
build and prove installation, enable/disable, restart, blocking webRequest
and the real full uBlock Origin package. No such proof is claimed here.

The local `evals/chromium-extensions/mv2_fixture` uses no network, credentials
or page access. Its acceptance/rejection belongs in `mv2_boundary`, separate
from the MV3 bridge checks. A fixture pass does not establish that every MV2
API remains implemented or that full uBlock Origin works.
