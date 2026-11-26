# Chromium development tabs

This is an opt-in development integration, not a release or production engine
migration. WebKit remains the default. Set `YAB_ENGINE=chromium` on a dev
bundle (or an isolated `YAB_PROBE` world) before launch. The switch is read
when a Tab is made; restart the app after changing it. Exact-host engine
overrides are applied before page construction and can switch a live tab through
the isolated bench; see [chromium-drm.md](chromium-drm.md). No Settings UI
changes are included.

Release-mode builds on Apple Silicon with CEF bundled are on Auto unless the
`YabPageEngine` preference says otherwise; see
[Chromium release R1](chromium-release-r1.md). Environment overrides
remain limited to development and isolated testing.

Launch the delivered development app through LaunchServices:

```sh
open -n -a "/path/Chromium tabs.app" --env YAB_ENGINE=chromium
```

## Build and acceptance

Use the farm, off your own Mac, with a short task name:

```sh
./farm build --low --host adhd --pin 'keep off main' --name 'Chromium tabs'
./farm exec --low --display --needs capture --host adhd --pin 'keep off main' \
  --name 'Chromium tabs check' --estimate 900 -- bash evals/chromium-tabs/job.sh
```

Focused seam tests use `evals/chromium-tabs/tests.sh` in a farm display
job. It loads the current SwiftPM test bundle into the repository's
synchronous AppKit test host and selects `ChromiumPageTests`,
`TabEngineTests` and `PageEngineTests`. This is a development test invocation,
not a release gate. A plain `swift test` does not provide that AppKit loop.

`job.sh` builds YabCore using `scripts/cef/fetch.sh` (the official pinned
CEF 156 arm64 distribution, verified against its published SHA-1), then
assembles the real app with `YAB_CEF=1`, `YAB_UNIVERSAL=0` and
`YAB_CEF_HELPER=<YabCore executable>`. `embed.sh` copies the browser process
into `Contents/MacOS/YabCore` and uses its distinct CEF subprocess binaries
for the role-specific Helper bundles, signing nested code before the app.
YabCore selects renderer and GPU executables explicitly in CEF's
`OnBeforeChildProcessLaunch`; the generic utility helper does not receive
JIT entitlements.
The ordinary build without CEF remains supported. `runtime.sh` reuses an
exact signed app for harness-only reruns. It installs Pillow into the job's
output directory when the worker has no image decoder; it changes no global
Python installation.

The helper starts only when a Chromium page first receives work. One helper
serves all Chromium pages of the app. Each space ID has its own persistent
CEF request context; private contexts use a different ID and no cache path.
CEF's installation-level data root can still contain global bookkeeping.
Socket directories have mode 0700, sockets 0600, with peer UID validation.
Client EOF closes producer windows. Helper loss clears hosted layers, fails
pending calls and displays the existing page-load failure state; explicit
navigation/reload starts a fresh helper. A renderer crash retains its tab ID.

## Implemented boundary

- URL-only GET navigation, back/forward, reload (including ignore-cache), stop.
- Local title, URL, loading, history flags and theme color; navigation events.
- Named isolated worlds, document-world evaluation and JSON arguments/results.
  Undefined is distinct from JSON null. Foreign frame tokens are rejected.
- Renderer PNG snapshots through CDP. The app's own layer-drawing `bench shot`
  does **not** capture remote pixels. Acceptance uses target-window
  ScreenCaptureKit with the blackout left raised.
- Remote `CALayerHost` under the existing stage, with a flipped parent,
  zero bounds and anchor (0,0); context replacement, resize and visibility.
- Mouse, drag, wheel, key events and committed Unicode text over IPC.
- A test-only `chromium` bench verb for exercising these primitives in real
  tabs and the real stage. Acceptance opens two local fixture tabs, switches
  column selection, resizes, checks document/world state, captures displayed
  pixels and checks helper restart.

## Missing and explicit limits

This is not a general replacement for all remaining WebKit consumers.
WebKit-only commit/finish side effects are skipped for Chromium. Existing
WebKit script relays, extensions UI, authenticated frame/message tokens,
response policy interception, downloads, permissions, authentication,
file pickers, find, print/PDF and native popup menus remain TODOs. A page's own
floating window: [document-pip.md](document-pip.md).
Navigation policy and Shield: [chromium-features.md](chromium-features.md).
Sound, Now Playing, camera/microphone state and a page's own full screen are
reported by YabCore's media events (see "Media track" in `YabCore/README.md`). Chrome-created windows (`window.open` / target blank)
are closed until Yab tab adoption is implemented. Chromium PageFoot obscured
insets are not implemented. Non-GET requests, custom headers/body (except a
validated HTTP(S) Referer carried across a WebKit navigation), HTML with a base
URL, PDF and foreign frames fail explicitly. Child-frame discovery is empty.
Page zoom sets Chromium's own zoom level. Full IME marked-text composition and
accessibility are not implemented. Mixed-DPI producer-screen selection and
large tab counts have not been accepted. The smoke uses a normal isolated
space; private-window storage and cross-space profile scenarios were not run.
Helper recovery reloads the current URL without restoring its native history. No DRM or signed-in account tests
are claimed. Existing WebKit-specific auxiliary commands must not be used on
a Chromium tab until migrated. No release has been requested or performed.
