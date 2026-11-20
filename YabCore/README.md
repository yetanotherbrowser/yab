# YabCore

A macOS C++/Objective-C++ page helper, built against the verified prebuilt
CEF 156 distribution. `Client/` is an independent Swift package with no CEF
linkage. This is a development integration target, not a shipping browser.

## Process boundary

YabCore owns Chrome-style `CefBrowserView`s in frameless `CefWindow`s with
`CEF_CTT_NONE`. Producer windows have alpha zero and ignore mouse events.
A 100 ms UI-thread walk finds the widget compositor's `CALayerHost` under
`BridgedContentView`. The client receives only context IDs and geometry.
Host these with a flipped parent, anchor `(0,0)`, position at the page's
origin and **zero bounds**. Do not give the remote layer the page's bounds.
`tests/layer_host.mm` is a separate-process reference host.

Unix stream sockets were chosen over XPC/Mach: the payloads are small JSON
control messages, not pixel buffers or Mach rights; a socket is inspectable
from a headless test client and usable directly from Swift and C++ without
an Objective-C protocol shared across the boundary. CALayerHost context IDs
already cross the process boundary as integers. There is no TCP listener.

One helper belongs to one client. Launch its stable executable
`TASK_NAME.app/Contents/MacOS/YabCore` with absolute `--socket=PATH` and
`--data-root=PATH` arguments. Create a new owner-only (`0700`) directory for
the socket. Never reuse a live helper's endpoint. The socket is `0600`, both
ends check the peer UID, and an existing endpoint is never unlinked during
startup. Client EOF closes all pages and exits the helper. A helper crash
fails pending Swift calls and ends its event stream; the app must launch a
new helper and recreate tabs. A renderer crash keeps the tab identity and
allows `tab.navigate`/`tab.reload` to recover it. CDP domains and registered
world-name bindings are restored on agent reattachment.

CEF processes use the CEF library loader and the standard role-specific
Helper bundles. The development build currently disables the CEF sandbox
and uses ad-hoc signing. Shipping entitlements, hardened runtime, notarization
and sandbox validation belong to the packaging track.

## Build and checks

Run builds and tests through the farm:

```sh
mkdir -p "$HOME/.local/state/yab-farm/producer-objects"
GIT_OBJECT_DIRECTORY="$HOME/.local/state/yab-farm/producer-objects" \
GIT_ALTERNATE_OBJECT_DIRECTORIES="$MAIN_CHECKOUT/.git/objects" \
./farm exec --low --display --needs capture --host adhd --pin "keep off main" \
  --name "Page core check" --estimate 360 -- bash YabCore/tests/job.sh
```

`build.sh` calls `scripts/cef/fetch.sh`, which downloads only from
`cef-builds.spotifycdn.com` and verifies the published SHA-1. CMake builds
the CEF wrapper and our helper; it does not build Chromium or patch CEF's
sample application. The app's visible name and delivered artifact name use
`YAB_TASK_NAME`; executable and bundle IDs stay stable. Routine iterations
reuse the worker's `yabcore-v2` build directory and stable native-source copy. The farm serializes compiler
work. `YABCORE_BUILD_DIR` can select an isolated build cache.

`tests/compile.sh` checks the helper, separate layer host and Swift tests in
a non-display lane. `tests/job.sh` also launches a loopback-only HTTP fixture,
helper, headless-capable Swift protocol client and separate AppKit layer
host. It captures green/red pages, resize and crash recovery, and checks the
captured pixels, not a CEF screenshot. No credentials or external pages are
used. The fixture launcher uses `--use-mock-keychain` with disposable data roots.
Output includes logs, `run/summary.json`, `events.json`,
`extensions.json`, `wire-summary.json`, and captured PNG/JSON pairs. Test
processes terminate in `finally`; adhd's blackout is never lowered.

## Wire version 1

UTF-8 JSON objects, one per LF, maximum 4 MiB per message. Newlines inside
strings must be escaped by a JSON encoder. Transport handles partial and
coalesced frames. A client sends `hello` first. Every request has `v:1`, a
unique nonempty string `id` (up to 128 bytes), `method`, and optional object
`params`. Every request gets one result or error; events can interleave with
results. Ordering is preserved on each stream, and request completion can
be out of order. An acknowledgement accepts an operation; await page events
for navigation or painting completion.

```json
{"v":1,"id":"1","method":"hello","params":{}}
{"v":1,"id":"1","result":{"version":1,"engine":"CEF 156 Chrome style","capabilities":[]}}
{"v":1,"id":"2","method":"profile.open","params":{"profile":"space-123","private":false}}
{"v":1,"id":"3","method":"tab.create","params":{"profile":"space-123","url":"https://example.com"}}
{"v":1,"id":"3","result":{"tab":"tab-1"}}
{"v":1,"event":"page.state","params":{"tab":"tab-1","title":"Example"}}
{"v":1,"id":"4","error":{"code":"operation_failed","message":"Unknown method"}}
```

The helper bounds pending calls, incoming/outgoing buffers and work per
run-loop tick. A malformed frame, duplicate in-flight ID or a stalled
consumer exceeding its buffer closes the session. Recoverable parameter,
version, JavaScript and CDP failures return errors. CDP calls expire after
15 seconds; other uncompleted requests expire after 20 seconds. The Swift client's default deadline is 20 seconds; cancellation
or deadline resumes the caller once and ignores a late result. Cancellation
does not undo browser side effects already accepted by the helper.

| Method | Parameters beyond `tab` | Result / behavior |
| --- | --- | --- |
| `hello` | none | Version, capabilities, known limitations |
| `profile.open` | `profile`, `private` (default false) | Idempotent for the same privacy mode; safe alphanumeric ID |
| `profile.close` | `profile` (no tab) | Refuses while any tab belongs to the profile |
| `tab.create` | `profile`, `url` (default about:blank), no tab | New stable tab ID |
| `tab.close` | none | Asynchronous close, followed by `tab.closed` |
| `tab.adopt` | `profile`, `private` | Accept a Chrome-created tab's identity in that exact context |
| `tab.navigate` | `url` | Begin navigation |
| `tab.loadHTML` | `url`, `html` | Show `html` under `url` (its origin and base); served once to the next main-frame navigation to `url` |
| `tab.back`, `tab.forward` | none | Browser history |
| `tab.reload`, `tab.stop` | none | Reload / stop |
| `tab.state` | none | Current URL, loading, document and DevTools readiness, cache path and history flags |
| `tab.readiness` | `profile`, optional exact `url` | Verified main-frame/default-world document proof; see CoreContracts.md |
| `tab.resize` | `width`, `height` in points, `scale` | Requested and actual native backing scale |
| `tab.visible` | `visible` | `orderOut` stops painting/rAF; show resumes with retained content |
| `input.send` | fields below | Forward AppKit event to hidden producer window |
| `script.evaluate` | `world`, `function`, JSON `arguments`, optional `userGesture` | Awaited JSON result or error |
| `script.bind` | `world`, `name` | Persistent world-name binding; emits `script.message` |
| `dialog.reply` | `accept`, optional `text`, native `request` token | Resolve the matching native JS dialog; tokenless tab-scoped wire-v1 callers remain supported |
| `extension.load` | Existing absolute unpacked `path`; `chrome://extensions/` tab | Install in the management tab's profile or explicit error |
| `extension.list` | Use a `chrome://extensions/` tab | ID, name, state list in that profile |
| `extension.access` | Use a `chrome://extensions/` tab, with `extension`, `hostAccess`, `add`, `remove` | Sets its runtime host permissions as Yab's one list says |
| `extension.review` | Manifest JSON string, at most 1 MB; management tab | Candidate review; target API is unavailable in the tested WebUI context |
| `extension.setEnabled` | `extension` ID, `enabled`; management tab | Enable/disable in that profile |
| `extension.incognito` | `extension` ID, `enabled`; management tab | Chrome's "Allow in Incognito" for it |
| `extension.userScripts` | `extension` ID, `enabled`; management tab | Chrome's "Allow User Scripts" for it; `extension.list` reports `userScripts` and `userScriptsChangeable` |
| `extension.remove` | `extension` ID, `userApproved: true`; management tab | Start reviewed removal; caller must verify absence |
| `extension.removalState` | Same management tab and extension ID | Callback state/error for that removal only |
| `extension.installCrx` | Absolute store-signed CRX `path`, expected `extension` ID; management tab | Chrome's own CRX3 installer with publisher proof and native consent (CEF 0021/0022): a store install Chrome updates; status installed, cancelled or error, with the installed version |
| `extension.checkUpdates` | Management tab | Chrome's ExtensionUpdater checks every store install now and installs newer versions |
| `shutdown` | none | Acknowledge, close all tabs, exit, remove socket |

A persistent profile uses `DATA_ROOT/space-PROFILE` as its request context's
cache path, as an immediate child required by [CEF ChromeBrowserContext](https://raw.githubusercontent.com/chromiumembedded/cef/master/libcef/browser/chrome/chrome_browser_context.cc). A private profile passes no cache path; its page storage stays
in memory. Installation-level CEF data may still be written beneath the
helper's root cache path. The helper canonicalizes the root before configuring both global and per-space
contexts, including macOS's `/tmp` symlink. The unused global Default profile
is pinned by `--profile-directory=Default` so it never aliases the last-used
space after restart, and is on disk; private space contexts remain off the record. The root must be
unique to this running helper;
CEF's process singleton protects it from concurrent writers. There is no
API to delete profile data from disk.

### Page and layer events

- `page.state`: a patch containing `url`, `title`, `faviconURL` (or null),
  `loading`, `canGoBack`, `canGoForward`, or `themeColor` (or null). Theme
  meta changes are observed in a reserved isolated world. Reduce patches
  per tab; absent fields retain their previous value.
- `page.loadError`: code, message, URL.
- `page.crash`: termination status, code and message. Recreate the hosted
  layer if its next context ID changes.
- `layer.changed`: context ID (zero means unavailable), point width/height,
  actual `scale`, `requestedScale`, and `visible`. Emitted for every change,
  including size/visibility changes with the same context ID.
- `tab.created`: Chrome-created browser tab, profile, URL, `mustAdopt:true`.
  `creationPurpose` is `popup` (native OnBeforePopup opener/source) or
  `extension` (native chrome.tabs.create receipt in `extensionCreation`).
  An incidental Chrome browser, including its own restored session content,
  is not a Yab tab request. It is retired without publishing this event;
  about:blank itself is neither rejected nor treated as creation intent.
  It remains owned and hidden by YabCore until adopted or explicitly closed.
  `tab.closed` releases that identity. New windows use the same hidden
  CefWindow path as ordinary tabs.
- `dialog.open`: native alert/confirm/prompt/beforeunload kind, opaque `request`, origin, message and default text. The callback shares the native question registry; renderer CDP events do not create this event.
- `popup.layer`: popup ID, context ID, rectangle and scale. `tab` identifies
  the owner when the NSWindow parent is known. Rectangles are page-relative
  top-left points when `coordinateSpace` is `page`; otherwise they are
  explicitly `screenBottomLeft` and `tab` is null. Do not assume ownership
  or reinterpret screen coordinates as page coordinates.
- `popup.closed`: popup ID.
- `script.message`: world, binding name, JSON value, tab.

### Scripts

`function` is a function declaration taking **one JSON argument**; use an
object for named arguments. A reserved world prefix `__yab` is unavailable
to callers. The helper obtains the main frame with `Page.getFrameTree`,
creates the named isolated world with `Page.createIsolatedWorld`, then calls
`Runtime.callFunctionOn` with `awaitPromise` and `returnByValue`. It grants
no universal cross-origin access. Navigation invalidates context IDs.
Bindings use `Runtime.addBinding` with `executionContextName`, so they
survive navigation without reusing an old renderer execution-context ID.
A binding's page-side function takes a JSON **string**, for example
`yabMessage(JSON.stringify({kind:'done'}))`. These APIs follow the
[CDP Runtime](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/)
and [Page](https://chromedevtools.github.io/devtools-protocol/tot/Page/)
contracts. World globals are isolated; the DOM is intentionally shared.

```swift
import YabCoreClient
let core = try await YabCoreClient.connect(path: socketPath)
Task {
    for await event in core.events {
        // Apply state patches and layer context changes on the app's UI actor.
        print(event.name, event.params)
    }
}
try await core.openProfile("space-123")
let tab = try await core.createTab(profile: "space-123", url: "https://example.com")
let title = try await core.evaluate(tab: tab, world: "agent",
    function: "function(args) { return {title:document.title, value:args.value}; }",
    arguments: .object(["value": .number(42)]))
```

### Input

`input.send` coordinates are page points from the top-left. Mouse kinds:
`mouseDown`, `mouseUp`, `mouseMove`, `mouseDrag`, `rightDown`, `rightUp`, `rightDrag`;
fields `x`, `y`, optional `clickCount`, `modifiers` (NSEvent flag bits).
Touch kinds, a finger on a touch display: `touchStart`, `touchMove` with `x`, `y`;
`touchEnd`, `touchCancel` with no point. Each names its `gesture` (a number per
gesture, at least 1). They go to CDP's `Input.dispatchTouchEvent`, so Chromium's
own gesture detector scrolls and flings, and the page's touch handlers and
`touch-action` decide. A touch kind is answered as soon as it joins the tab's touch line,
before Chromium has seen it. What Chromium then refuses goes to the helper's
log. Later mouse and wheel input wait behind a touch step waiting for a
request slot, just as they wait behind a mouse move. Keys, resize and
navigation wait on ChromiumPage's completion chain. That chain waits for
the helper's enqueue reply to a touch, which precedes Chromium's answer.
These waits under transport saturation are the same as for mouse moves.
The line sends a tab's touch kinds in order, one at a time, each once Chromium
has answered the one before it; moves waiting behind one merge into the
latest. No order is kept with other input kinds: a `wheel` goes to the page's
view at once, and a mouse kind never waits for a touch's zoom read. A kind acts
only on its own gesture. A gesture stays on the document its `touchStart` went
out on: once that document goes (a navigation commits, or the client asks
for one), its next kind goes out as a `touchCancel` and the rest of it is not
sent. A `touchStart` names no document, so one that
waits in line while a page-initiated navigation commits goes to the new
document, as a mouse press queued then does. The rest of a gesture whose start
Chromium refused is not sent. Before a `touchStart`, a finger Chromium may
still hold gets a `touchCancel`, and the start waits for its answer: it is not
sent unless that answer shows the finger released. A finger is not left held
once it is gone: a start that fails, or a `touchEnd` whose answer does not show
the release, is followed at once by a `touchCancel`, and the lift of a gesture
whose start failed or was not sent goes out as a `touchCancel` while Chromium
may still hold a finger.
Cancelling a gesture before dispatch drops its queued start and other steps.
Hiding a tab drops every queued touch step and cancels any contact Chromium
may still hold. When the view changes windows, is hidden, is retired, or
starts a native close commit, ChromiumPage sends `input.resetTouch` with
its last gesture number on the same socket, outside the page queue and
request slot limit. It sends at most one reset per gesture. The helper
rejects late steps at or below that number, including if native close
retains the tab. A touch step dispatched before the helper reads a reset
or hide can still reach the page, as a mouse event sent just before a hide
can. A message-based reset cannot close that window without synchronous IPC.
Keys: `keyDown`/`keyUp`, macOS `keyCode`, `characters`, `unmodified`, optional
`repeat` and modifiers. `text` inserts committed Unicode through the page
view's `NSTextInputClient`. `wheel` takes `deltaX`, `deltaY`, AppKit/CG scroll
phase and momentumPhase, location and modifiers. `magnify` takes `x`, `y`,
NSEvent `phase`, `magnification`, `timestamp` and modifiers; `smartMagnify` the
same without phase and magnification. They reach the page view's
`magnifyWithEvent:` and `smartMagnifyWithEvent:` through a stand-in event, as
Chromium's `SyntheticPinchEvent` does, so a pinch is Chrome's own: the page may
take it as a ctrl wheel, else the compositor scales the visual viewport about
the point, with no layout. CDP input (`Input.dispatchMouseEvent`,
`Input.dispatchDragEvent`) multiplies its points by that scale; a person's mouse
goes to the view and is not affected. The helper converts pointer
coordinates to viewport CSS pixels using the native browser zoom and sends
trusted `Input.dispatchMouseEvent` commands. NSEvent modifiers become CDP
modifier bits; drag buttons and click counts retain their native values.
The hidden producer's Cocoa view can discard direct mouse events even when
its window is visible. Keys still use `NSWindow.sendEvent:` and wheel goes
to that view's `scrollWheel:`. There is no synthesized system HID
pointer or permission requirement. Full IME marked-text composition, key
state/caret, accessibility and native menu interaction are not claimed.

## Known boundaries

- Native backing scale is reported honestly. CEF Views uses the producer's
  screen scale; a request does not force another display's scale. Mixed-DPI
  production hosting needs a producer-screen handshake or Chromium hook.
- `<select>` and some native menus do not provide a remote layer context.
- Extension action popup tab identity and placement remain prebuilt-CEF
  constraints documented in experiment F. Extra contexts are reported,
  but there is no claim that an action targets the correct Yab tab.
- Extension commands rely on Chrome's privileged `chrome://extensions/`
  management page and its internal `developerPrivate` API, a version-specific
  compatibility surface. The tab must belong to the intended profile. An
  unpacked load enables that profile's developer mode and intercepts only
  its pending directory chooser via public `CefDialogHandler`, supplying the
  explicitly requested path. Chrome retains manifest validation and errors.
  No external DevTools port or unsafe extension-debugging switch is enabled.
  See [Chromium's extension management service](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/resources/extensions/service.ts)
  and [CEF's dialog handler](https://github.com/chromiumembedded/cef/blob/master/include/cef_dialog_handler.h).
- Private CoreAnimation APIs and the layer-tree class names are an explicit
  compatibility surface in the helper and ChromiumPage hosting adapter. There is no GPU restart,
  Retina, hundreds-of-tabs or signed password-manager acceptance here.
- The app's development adapter is `Sources/Fast/ChromiumPage.swift`.
  It is registered only with the explicit dev switch; see
  [`docs/chromium-tabs.md`](../docs/chromium-tabs.md). Production remains WebKit.

## Integration with the page seam

The main-actor adapter hosts the reported layer, reduces ordered state
patches and closes its remote tab on retirement. A lazy per-app process
owner routes events and invalidates pages after helper loss. A socket reply accepts
navigation; it is not a substitute for committed-navigation or policy events.
Use `tab.readiness` / `waitForDocument` before scripting newly created or
restored documents. CEF's `hasDocument` is diagnostic, not a readiness gate.
See [core runtime contracts](CoreContracts.md) for proof and lifetime details.
`hasMainContext` remains a diagnostic for a live root-session default
context. CEF can clear `HasDocument` after `pushState` while that context
and document remain alive. Context-destroyed and context-cleared events
remove this evidence; scripting uses the verified document proof above.

The helper also exposes `script.document` for main-frame document-world
evaluation and `page.snapshot` for CDP PNG capture. Named-world calls cover
main-frame isolated scripts. Remaining seam work includes authenticated
opaque child-frame tokens, request method/headers/body and HTML loading
with a base URL, PDF bytes, process/media state, action and
response policy, permissions, authentication, file picks and downloads.
`script.message` identifies the CDP execution context/world; its JSON body is
untrusted and supplies no authenticated origin or frame token. It cannot be
used as the general authenticated relay primitive described by the seam.
Wire v1 maps raw undefined results to JSON null. ChromiumPage wraps script
values in a JSON envelope to preserve the seam's absent-value distinction
and explicitly rejects unsupported operations. No per-tab engine selection or cross-engine history transfer is
provided by this track.

App-level acceptance uses `evals/chromium-tabs/`; it records a JSON summary,
exact signed app and target-window ScreenCaptureKit pictures. The track's
handoff report records the actual job IDs and remaining work.

### Page script registration (scripts track)

The additive `scripts.*` family registers ordered page scripts and isolated
relay handlers before navigation, auto-attaches out-of-process iframe
sessions, evaluates within authenticated live frame tokens, settles relay
promises and dispatches trusted CDP agent input. `script.relay` events carry
CDP-derived frame/origin metadata separately from page-controlled payloads.
See [the script contract and current scope](../docs/chromium-scripts.md).
The first integration wave installs agent frame announcements; it does not
yet migrate the general Tab relay table or claim feature parity.

`page.hover` (`url`: CEF's status message, the link under the pointer or
empty) reports Chrome's status-bubble text. The app shows it in the link
status pill only after the pointer's own moves inside the page and treats
any text that is not an absolute address as no link.

`scripts.appearance` (`tab`, `appearance`: `scheme` `light` or `dark`,
optional `ground` `{r, g, b, a}`) sets CSS `prefers-color-scheme` through
`Emulation.setEmulatedMedia` and the default background through
`Emulation.setDefaultBackgroundColorOverride` on the main target and every
attached out-of-process frame; frames attached later get it before they
resume. The app sends it before each navigation and when the page view's
appearance or dark pages' ground changes (ChromiumPage+Dark.swift), so a
Chromium page follows Yab's theme as a WebKit page follows its view.

## Media track: renderer lifetime and audio mute

The media wave adds `media.mute` (`tab`, required Boolean `muted`) and
`page.killRenderer` (`tab`, no caller-supplied PID). `media.mute` uses CEF's
whole-browser audio output mute, including subframes and WebAudio; it does
not modify media-element volume or microphone capture. The result contains
`muted`, and `page.state` reports `audioMuted`. `tab.state` includes both
`audioMuted` and `rendererPID`. Audible state is in the media section below.
The mute is the tab's until `media.mute` lets it back in: Chrome's
SoundContentSettingObserver unmutes a tab on every new main document unless
Chrome's tab code muted it with a reason, which `SetAudioMuted` never gives,
so YabCore mutes again at each main-frame commit and whenever the page turns
audible (`KeepMuted`, feedback #2018).

The role-specific renderer Helper installs `MediaRenderer`, which reports
its OS PID when CEF creates the main-frame V8 context. YabCore accepts that
message only on CEF's renderer channel for the owning main frame, validates
that it is a child process, and retains its process birth time. Ending it
requires that identity still to match. A shared renderer may end several
tabs, as WebKit process termination does. A crash clears the PID. A later
renderer context reports the replacement PID. The Swift app never infers
tab ownership from process titles and never accepts a PID from page script.

Chromium pages join PageProcesses' census, which groups views by PID so
shared renderer memory is counted once. MemoryCeiling consumes that census.
Renderer crash events enter the existing PageEnds recovery policy; explicit
recovery and stale-tab selection stay on the selected engine. Helper loss
retains its existing explicit reload behavior.

`evals/chromium-media/job.sh` builds and signs the real app, runs the suites
selected for touched Swift files, and exercises native mute, renderer
identity, memory reporting and foreground/background recovery in an isolated
Chromium world with ScreenCaptureKit window captures. Its report is the
acceptance source; this protocol description alone is not a passing result.

## Media track: native renderer responsiveness

`page.responsive` carries a Boolean `responsive` and the native `rendererPID`
for the owning tab. The existing CEF callbacks are relayed when available,
but Chromium suppresses them while any CDP client is attached. YabCore keeps
its instrumentation attached, so real input also starts a native main-thread
challenge (`health.inc`, `media_renderer.h`). No page script or global is added.

Accepted AppKit input starts one coalesced challenge after 100 ms. The renderer
answers from its main thread through CEF process IPC with its own PID and an
opaque nonce. The helper's existing native poll observes the three-second
response deadline; matching replies recover immediately. Browser/tab, current
main frame, nonce and live PID must match. PID changes, closure, replacement
frames and an actual DevTools frontend invalidate the challenge. Normal CEF
input/compositor ACKs cannot answer this separate main-thread challenge. Idle
pages are never probed, and unresponsive pages retain one bounded challenge.

Yab's existing two-second Wait/Reload card delay remains unchanged. Explicit
Reload still owns renderer termination. Automatic background-agent recovery
must also pass Chromium's existing activity/draft/capture veto. The Swift
adapter rejects absent, ended or replaced PID state before forwarding to the
current PageEvents listener. No Chromium feature switches are changed.

`evals/chromium-media/health.py` checks a bounded input-handler stall, card
presentation and native recovery with the same document and renderer. Its
baseline mode observes the missing notification on the preserved pre-health app.
The signed job also runs the existing hung-pages eval unchanged. REPORT.md
records acceptance; this contract alone is not a passing result.

## Media track: sound, Now Playing, capture and full screen

`media.inc` adds these events and methods (all keyed by `tab`):

| Name | Kind | Contents |
| --- | --- | --- |
| `media.state` | event | `audible`, `audibleSource` (`native` or `page`), `playing`, `session` (`title`, `artist`, `album`, `artwork` URLs) or null, `sessionState`, `media` (`t`, `d`, `paused`, `muted`, `loop`, `video`) or null, `frames`, `mainFrame` |
| `media.capture` | event | `camera`, `microphone`, from `CefDisplayHandler::OnMediaAccessChange` |
| `media.capture.changed` | event | Chrome's own capture state of the browser: `camera`, `microphone`, `screen`, `tabCapture`, `window`, `display`, `allScreens`, `mirrored`, `videoPiP`, `documentPiP`, `actions`. `tab` is the page, as on every event |
| `documentPiP.size` | event | `width`, `height`: the page's size in Chrome's window of a page's own floating window, before anything resizes it. It is the size the page asked for, which no popup feature carries |
| `page.fullscreen` | event | `fullscreen`, from `OnFullscreenModeChange` |
| `media.action` | method | `action` = `play`, `pause` or `seekto` (with `value` seconds); answers the number of frames reached |
| `page.exitFullscreen` | method | `CefBrowserHost::ExitFullscreen(true)` |
| `media.read` | method | Republishes `media.state`; answers capture, full-screen and producer-window state for probes |

Sound and session come from every frame's renderer. The role-specific
renderer Helper's `MediaRenderer` runs a watcher in each frame's main world
when CEF creates its context: capture-phase listeners for the media
elements' own events and a read of `navigator.mediaSession` when they fire.
No prototype is replaced and nothing is added to the page's globals; the
report function is a native closure argument, and the timer, JSON and
listener functions it uses are taken before any page script runs. Reports
travel as `yab.media.frame` process messages, which CEF ties to the sending
frame; YabCore bounds and types every field (page-authored strings, artwork
URLs limited to http, https and data) and drops a frame on context release,
detachment, main-frame commit or renderer crash. Yab's actions go back as
`yab.media.action` to the frame playing (pause reaches every frame playing).

On prebuilt CEF, `audible` means a media element in the document playing
unmuted with decoded audio (`audibleSource: page`). Media created outside the
document and WebAudio are not seen. Built against Yab's own CEF with the
`0007-native-audible` patch (`CEF_YAB_AUDIBLE_VERSION`), `OnAudioStateChanged`
supplies Chromium's own audible state, including WebAudio and every frame,
and `audibleSource` is `native`; the page reports still name the session.

Chrome style performs a page's full screen in its own window, here the
concealed producer, which would take a Space nobody sees. `MediaProducerWindow`
replaces `toggleFullScreen:` for the producer windows' class: the transition
Chromium's controller waits for is reported without one, the content fills
the producer, and the app lends the page to a full-screen window of its own
(`ChromiumPage+Media.swift`). Escape, the page's own exit, the green button
and ⌃⌘F all end in `page.fullscreen false`.

The autoplay policy is Chrome's own (sound after a user activation, or for
sites Chrome's media engagement allows); Yab adds no command-line policy.
Native discard with session restore and freezing remain requests to the
own-CEF track. Sleep closes the remote browser and keeps its URL and scroll
place; back/forward entries are not restored on the prebuilt SDK.

## WebKit DRM extension bridge (development candidate)

`tab.navigate` also accepts an optional HTTP(S) `referrer` without credentials
or fragment. After the existing DRM readiness barrier it uses CDP Page.navigate
with strict-origin-when-cross-origin policy and reports its errorText as an IPC
failure. Calls without a referrer keep their existing CEF LoadURL path. This
supports ordinary WebKit GET navigation when a host override replaces its tab;
arbitrary request headers and bodies are still unsupported by the app adapter.

The additive `ext.bridge.*` family is local-app IPC, available only on a
profile's `chrome://extensions/` control tab. It is not a page binding.
See [the bridge contract and explicit limits](../docs/chromium-drm.md).

| Method | Additional parameters | Behavior |
| --- | --- | --- |
| `ext.bridge.catalog` | none | Enabled installed manifests, source metadata and actual host grants |
| `ext.bridge.files` | `extension`, `files` | Bounded UTF-8 sources from that installed root; no traversal |
| `ext.bridge.register` | `virtual`, `document`, `frame`, `url` | Register a native-app-owned WebKit frame; return virtual tab ID |
| `ext.bridge.unregister` | `virtual`, optional `close` | Expire frames/ports; retain tab ID across navigation unless closed |
| `ext.bridge.invoke` | `extension`, `op`, `args`, frame registration fields | Profile-checked worker dispatch, with live storage content-access checks |
| `ext.bridge.reply` | `extension`, `session`, `call`, `value` or `error` | Resolve a worker's reverse WebKit call |

`ext.bridge.call` events identify the authenticated worker session and
extension, carrying a reverse operation for the native WebKit bridge. Stale
sessions, closed tabs and expired document/frame selections fail. No real
cookie/storage values are logged. `ext.bridge.testingSleep` is diagnostic-only:
it requires the `--yab-test-bridge` helper flag and disposable `diagnostic`
profile, and stops that test profile's workers to check native wake behavior.

## Extension action state for Yab's buttons

`CEF_CTT_NONE` draws no Chrome toolbar, so Yab draws each extension's button
itself. Chrome still keeps the action's badge, title and enabled state per
tab; `ext.actions.state` reads them from the extension's own worker over the
same profile-checked worker sessions as the bridge above.

| Method | Parameters | Behavior |
| --- | --- | --- |
| `ext.actions.state` | `tab` (the profile's `chrome://extensions/` control tab), `page` (an open Yab tab of the same profile), `extensions` (up to 64 IDs) | For each ID: `action`, native `tabId`, `title`, display `badge`, `countHidden`, `background` and `color` RGBA, `enabled`, `popup`, recorded dynamic `icon` PNG data URL or null; or `error` |

The page's Chrome window comes from `Browser.getWindowForTarget` on the
page's own DevTools session; a Yab page's window holds exactly one tab, and
any other count is reported as an error rather than guessed. Badge text is
Chrome's display text. When an extension shows its declarativeNetRequest
count without feedback access, Chrome answers a placeholder: that is reported
as `countHidden` with an empty badge, never as a number. Dynamic icons have
no getter: `setIcon` calls are recorded after the worker is first read, and
the recorded icon for a tab is dropped when that tab navigates. Private
profiles are refused.

`ext.actions.changed` events (on the control tab, with `extension`,
`profile`, `reason` `action` or `worker`, optional `nativeTab`) tell the app
to read again: after the extension changed its action, or when its worker
started again and lost the hook.

## Safe Storage ownership

The signed outer Yab app owns the existing `Yab Safe Storage` / `Yab` generic
password. Before CEF profile services initialize, CEF patch 0129 requests its
exact bytes from the owning app over `--yab-safe-storage-socket`. The switch
contains only the address of a one-use socket next to `core.sock` in the
owner-only launch directory. Both peers check kernel process identity; the
app additionally validates its bundle seal and the live nested helper image
before any Keychain lookup. The ordinary wire and original-caller stdin are
unchanged. Broker failure cannot fall back to Keychain or a basic/mock key.
The provider keeps Chromium's existing `v10` PBKDF2/AES format, so no cookie
or password database re-encryption is needed. Denied access never creates a
replacement key. A legacy item's ACL may ask its owner to authorize the
outer app; the app does not silently change that ACL.

The native helper requires a broker-capable SDK for real-Keychain runs.
Standalone fixture tests continue to explicitly use `--use-mock-keychain`.
Certificate/trust Keychain notifications and certificate queries remain in
Chromium; the Safe Storage broker does not change TLS trust handling.
`evals/golden/cortex_safe_storage.py` checks ownership and encrypted data
across relaunch. `scripts/cef/cortex-keychain-proof.sh` additionally builds
0.47.8 and checks migration of its synthetic real-Keychain profile.

The launch audit identifies every captured PID, including the outer app. An
application display name cannot identify the caller in pre-0.47.8 builds. This
ownership change retains an app-owned Safe Storage read during initialization,
as well as production session/sync reads and Chromium trust operations; it is
not a claim of zero startup Keychain access or verified Cortex acceptance.
