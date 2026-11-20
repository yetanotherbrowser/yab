# Page engine seam

`PageHandle` in `Sources/Fast/PageEngine.swift` is the consumer interface to
an engine's AppKit view. It imports AppKit, not WebKit. `WebKitPage.swift`
adapts `PageView` to it without changing the WebKit calls underneath.

This is an incremental migration. Tab owns a lazily created `any PageHandle`,
selected through `PageEngineFactory`. The standard factory defaults to WebKit. A dev app launched with
`YAB_ENGINE=chromium` installs the experimental `ChromiumPage` adapter; see
[`chromium-tabs.md`](chromium-tabs.md).
Production `Tab.web` has been removed; its trapping compatibility accessor
exists only in native WebKit tests. `Tab.built` remains a nonconstructing
optional cast, with no production consumers. Neither owns a second page.
App consumers use the handle, and features that exist only as
native WebKit code go through `Tab.webKitOnly`, which does nothing on a
Chromium tab; [`chromium-webkit-only.md`](chromium-webkit-only.md) lists them.

## Ownership, engine choice and state

`PageEngineKind` is stored on Tab. `Session.Entry.engine` persists its raw name;
an absent or unknown name defaults to WebKit, as does a recognized engine
unavailable in the installed factory. Session restoration, copied kept tabs,
shared pins and newly materialized sync tabs use the saved choice without
constructing a page. `PageEngineFactory.kinds` advertises supported engines;
its main-actor construction closure receives the Tab and chosen kind. The
standard factory calls the existing `buildWebKitPage` setup. A second engine
must advertise its kind and return a matching PageHandle.

An explicitly supplied factory retains its requested engine and DRM bridge
policy independently of the development override. `YAB_ENGINE` selects the
standard factory's initial engine; it does not rewrite injected factories.

Before lazy construction the factory also resolves an exact-host
`SiteEngineSettings` override. The three choices are Recommended, Chromium and
WebKit; Chromium remains unavailable in the ordinary WebKit-only factory.
`Tab.setSiteEngineChoice` applies a live choice through the replacement seam
below, after the same-space cookie barrier, or records it without waking a
sleeping tab. Where Chromium is available, Settings › General has the Default
engine menu and Engines for Sites (`SettingsEngine.swift`). See
[`chromium-drm.md`](chromium-drm.md) for precedence and bench acceptance.

`Tab.replaceEngine(with:at:)` is the navigation-boundary switch point. It
refuses closed tabs, the current kind and unavailable engines before changing
anything. It invalidates held writes and load retries, retires the old page,
and installs the replacement in the same parent, sibling position, frame and
responder position. The Tab object, id, title, row position and saved metadata
remain intact. `currentEntry` retains a copied `PageHistoryEntry` until the
new page has a committed entry. This preserves the current entry; transferring
an entire native back/forward stack across engines remains future work.
No WebKit interaction-state object is sent to another engine. Switching
itself does not write a history visit. The new request uses the usual engine
navigation events. Chromium is available only with that explicit development switch.

The Tab independently listens to `PageStateEvents`, alongside its window's
`PageEvents` navigation listener. `PageStateChange` copies title, URL, loading,
back/forward, theme and under-page colors, capture states and fullscreen.
Colors are Codable RGBA values. All these events are serializable and delivered
in order on the main actor. Engines mirror state locally rather than waiting
on a page process during a UI read. `WebKitPageState` owns KVO and private
screen-capture observation; Tab contains no WKWebView state observers. Existing
held writes, title throttling, about:blank protection, tone sampling and
fullscreen animation suppression remain in Tab. Old-page events and held
writes are identity-checked before changing the replacement's state.

`PageHandle.retire` owns engine cleanup. WebKit releases the same handlers,
scripts, callbacks and media as before, then runs its existing Farewell flow.
The main stage and PageHolder host the neutral NSView. Other legacy native
input, history and auxiliary surfaces remain explicit migration work.

## Consumer contract

Use `tab.page` when creating a page is intentional. Use `tab.builtPage`
when a read must not wake or build a tab. A handle is an `NSView`, so layout,
coordinate conversion, window access and responder operations stay AppKit
operations. Never downcast it for ordinary page operations.

- Navigation accepts a URL request or HTML and an optional base URL.
  Reload distinguishes an ordinary reload from a cache-bypassing reload.
- `run` evaluates an expression; `call` evaluates an async function body
  with named arguments and awaits its return value. Both have callback
  and async forms, and propagate script errors.
- `PageWorld.page` is the document's own world; `.client` is the engine's
  isolated embedder world; `.named(name)` identifies an isolated world
  consistently. `.yab` is `.named("yab")`. The WebKit adapter retains named
  content-world objects so their script state survives separate calls.
- A `PageFrame` carries the engine's opaque token. An engine must reject a
  foreign token instead of interpreting it as the main frame. WebKit also
  checks that the frame belongs to the receiving view.
- `childFrames` returns addressable child frames in tree order, excluding
  the main frame, with the existing limit of 40 frames and depth below
  eight. An unavailable frame-discovery capability returns an empty list.
  WebKit keeps its private `_frames:` call and raw frame traversal in
  `WebKitPage.swift`; ordinary consumers receive opaque `PageFrame` tokens.
- `gesture: true` preserves the public WebKit call's user-gesture behavior.
  A background read uses `false`, which preserves QuietScript's private
  no-gesture path and its existing public-API fallback.
- `runInYab` preserves `evaluateInYab`: the result or nil for an absent
  value or error, with the public call's gesture behavior.
- `snapshot` accepts `PageShot`: optional view-coordinate rectangle,
  optional width in points, and whether to wait for screen updates. Default
  options preserve WebKit's nil snapshot configuration.
- `pdf(rect:done:)` returns PDF bytes for a document-coordinate rectangle,
  or the engine's whole-document default for nil. A document capture must
  not substitute a viewport snapshot, which loses offscreen content.
- `contentProcess` and `killContent` expose the existing content-process
  observation and termination behavior. Shared process policy belongs to
  the browser; an engine must not imply that every tab has a unique pid.

`PageCode` names executable script input. `PageScript` remains the existing
resource loader, so page-script resources and their callers keep their API.

## Migrated consumers

`Capture.swift` uses only `PageHandle` for page access. Picking and secret
box measurement run in `.yab`; visible images and the editor backdrop use
`PageShot`; whole-page and tall-region captures use PDF bytes. Its existing
zoom, scroll offsets, resolution limit, rasterization and image handling
remain unchanged. Capture no longer imports WebKit.

`PageWords.swift` reads text and Google Sheets exports through the handle in
`.client`, keeping its existing cache, cookies, fetch, limits and public
script gesture behavior. It no longer imports WebKit.

`LinkCard.swift` uses the handle for DOM hit testing and highlighting in
`.yab`, page identity and AppKit window/coordinate operations. Its separate
preload/image pipeline still takes a WebKit website store; migrating page
access does not yet abstract persistent contexts.

`Bench.swift` routes ordinary eval, scripted click/type/submit, post-fill
reads, force-peek hit testing, split-deck width sampling and tab PNG shots
through the seam. Its window-composite page snapshot also uses `PageShot`.
`AgentBench.swift` uses the handle for polling text in `yab-agent` and inline
JPEG shots. Snapshot width, update timing, PNG encoding and JPEG resizing
and quality stay the same. Existing authorization and screenshot guards
still run before page access.

`AgentPage.run`, frame discovery, announced-frame matching and snapshot
weaving use `PageHandle` and `PageFrame`. `AgentBenchPage` scrolls in the
agent world through the handle; `AgentBenchPerson` carries opaque frames
when locating sign-in fields and reading manager menus. `ManagerMenus`
routes its reads, picks and visibility scripts through the seam, preserving
the page and yab worlds, and no longer imports WebKit. Its native click
uses the handle's input operations.

`FrameRelay` now lives in `WebKitPage.swift`: WebKit supplies the view and
frame identity before AgentPage sees the opaque token. This is an adapter
move, not the general message primitive; handler registration, the existing
message payload and teardown remain unchanged. No general message or
origin-authentication migration is claimed by this wave.

This is a partial Bench migration. Native input, offscreen lifecycle,
configuration, extension fixtures, process/media SPI, inspector and frame
APIs remain direct consumers. The raw WebKit snapshot overload is retained
only for separate inspector and extension popup/panel/popout surfaces, not
browser-tab shots. `AgentBench.performHeld` now takes a handle for the
agent guard.

`AgentPage`, `AgentKeys` and `AgentPermit` no longer import WebKit or
accept its view type. `PageHandle` dispatches native clicks, hover, drag,
text insertion and key strokes. `PageKey` carries the same Mac and DOM key
representations as the former `AgentPage.Stroke`, which remains an alias.
The WebKit adapter keeps CSS-to-view zoom conversion, tracking-area pointer
delivery, modifier flags, key equivalents, drag timing and `agentActing`
around each native dispatch. AgentPage keeps the existing script fallback
for text and keys when a page has no window. Its key-landing counter and
the keyed hold/eval guard run through the handle in `.agent` and
`.agentEval`, retaining their existing world names, public gesture path,
ordering, timeout and approval behavior. Eval callbacks now use the seam's
optional result value, preserving the distinction between absent values
and script failures.

The input consumers in Bench, AgentBenchPage, AgentBenchPerson,
ManagerMenus and ExtensionDebugger use `tab.page`. ManagerUnlock still
supports separate raw WebKit extension popups. Its `webKitAgentPress`
extension point keeps the old native/script key path in WebKitPage rather
than passing those surfaces into the browser-tab seam. AgentPage's concrete
`world` and `evalWorld` accessors also remain there for WebKit script/relay
registration and legacy fixtures. These exceptions do not claim that
extension surfaces, message registration or Tab ownership have migrated.

## Navigation events

`PageHandle.events` weakly holds a `PageEvents` listener. Navigation start,
redirect, commit, finish and both failure paths arrive in engine order on
MainActor. `PageNavigation` is a Codable UUID value, shared by all callbacks
for one navigation. Tab uses that value for late-failure restoration and
keyboard history traversal instead of retaining a WKNavigation. The WebKit
adapter associates the value with the original navigation object, including
the object returned by goBack/goForward.

Document responses carry Foundation response data, main-frame status and
whether the engine can display the MIME type. Their `PagePolicy` reply is a
callback, so it can be held after the event returns. WebKit translates it
only when answered and ignores duplicate replies. Browser still records
headers and informs history tracking before answering, then releases quiet
window work after the answer. Existing deferred finish work stays deferred.
An out-of-process engine must transport the response fields and errors as
values and route replies to the original pending request; it must not pass
engine objects or require a synchronous page return.

PageView retains `WebKitPageEvents` because WebKit's delegate is weak.
Tab installs it for PageEvents listeners and updates the weak listener when
a tab moves between windows. Close detaches it before Farewell takes over.
Legacy delegates without PageEvents keep their old installation path.
Remaining private callbacks use Objective-C responds/forwarding, preserving
absent-method defaults. Both delegate roles detach together;
separately installed delegates are preserved on detach.

Browser's private WebKit callbacks now live in `WebKitBrowser.swift` as a
WebKit-specific Browser extension. Their hit-test/SPI decoding, print deferral,
PDF saving and blocker behavior are unchanged. Remaining private UI callbacks target that
legacy delegate. The neutral navigation handlers temporarily use explicit
`page.webKit` extension points for diagnostics, application-response
metadata, SiteDownloads and Stage commit integration. Those helpers,
popup construction through Tab's engine factory and remaining consumer migrations
are still required before another engine can back a Tab.

Action policy uses `PageAction` values: the request, navigation kind,
optional main-frame target, copied source origin, modifiers, button mask,
download intent and engine-authenticated user initiation. A missing target
remains distinct from a child-frame target. No WKNavigationAction or frame
object is retained by the request. Kind and source support Codable; the
request uses Foundation URLRequest. An out-of-process engine must transport
its URL, method, headers and body along with those metadata values.

Both WebKit action-policy callbacks route through PageEvents, preserving
CallSound's preference update before the browser is asked, and returning
the same preferences object when the deferred reply arrives. Each request
answers once, even after the listener moves. With no listener, or one using
the lifecycle-only default implementation, action policy allows navigation.
Compatibility entry points remain in WebKitBrowser for direct legacy calls;
they do not replace the page's current listener.

Browser's existing policy order is retained: acquisition guard, history,
QuietLoad, warmed-page guard, explicit download intent, SafeBrowsing, site
agent, extension OAuth, userscripts, special-page routing, assistant scope,
modified links, filtering, internal pages, frame cookie grant and external
apps. QuietLoad now uses PageHandle for its entire retry lifecycle, including
its weak page capture and repeated request. Dress's event delivery uses
`.yab` scripts; ExtensionAuth and external-app ownership use `builtPage`.
Dress still constructs a WebKit document-start script for Tab registration.

WebKitPage contains named temporary action-policy extension points for
ContentWarm, artifact-store identity, site user agent, Shield rule lists,
DiaryPage registration and FrameGrants cookie seeding. Their ordering and
store/controller identities are unchanged. A missing WebKit frame-grant
capability cancels that request; it must not silently allow an unseeded
frame. These are explicitly unfinished engine capabilities, not support for
selecting Chromium yet. Popup, permission, authentication, process and download events now use the
seam. Stuck, Share and Calls still need their consumer migration.

## Adding an engine

1. Implement `PageHandle` on the engine's `NSView`, including both script
   result forms, authenticated frame tokens, named-world isolation,
   gesture semantics, snapshots, document PDF output and native agent input.
2. Advertise the kind in `PageEngineFactory` and test the same consumer
   contract. Chromium's case is already reserved. Return errors for unsupported
   operations rather than running a script in another frame or substituting
   a different capture.
3. Construct a matching PageHandle through the factory. Emit copied state
   through the weak `stateEvents` listener, mirror reads locally, and implement
   `retire` to stop observation, delegates, scripts, input and media. Exercise
   `replaceEngine(with:at:)` at a navigation boundary.
4. Implement PageEvents for navigation, action and response policy, then
   finish Browser's remaining private event and consumer migration. Preserve the current ordering
   of policy answers, history tracking and deferred window work.
5. Add an authenticated message primitive and migrate all 21 `Tab.relays`.
   Origins and frame identity must come from the engine, not the message
   body. Keep reply handlers, isolated worlds and handler teardown. A
   Chromium transport must preserve the page scripts' current handler API
   or migrate the scripts together with the native registration.
6. Migrate remaining consumers before enabling per-tab engine selection or
   FairPlay fallback. A fallback must define navigation/history transfer,
   storage isolation, pending callbacks, capture/media teardown and UI view
   replacement. Cross-engine frame tokens and opaque history state are
   never interchangeable.

## WebKit extension points and remaining migration

`PageHandle.webKit` is an explicit optional escape hatch in WebKitPage.swift;
it is not a general substitute for migrating consumers. It returns nil for
another engine. The current repository still has legacy direct consumers;
there is no completed short allowlist yet.

The WebKit-specific work to isolate includes:

| Area | Current owners | Contract another engine needs |
| --- | --- | --- |
| Process identifiers and termination SPI | WebKitProcesses, PageProcesses, SiteProcesses, MemoryCeiling | Process accounting, identity checks, shared GPU recovery and safe termination |
| Inspector and private developer tools | Inspector and Dev tools | An engine-specific tools capability, with ordinary tools routed through the seam |
| Capture, fullscreen, PiP and media SPI | Calls, Share, FloatPiP, Permissions | Media state and policy events, source selection and stream teardown |
| Configuration, scripts, content worlds and rule lists | Tab, PageScripts, Shield, Filters | Engine construction, document scripts, isolated message transport and filtering |
| Website stores, extensions and push | Spaces, Extensions, WebPush, SiteNotices | Engine-specific persistent contexts and native services |
| Navigation/UI/download and private callbacks | Browser and its delegate extensions | Engine-neutral policy requests and events; private callbacks stay in the adapter |
| Stage and native page interaction | Stage, PageView, AgentPage, Bench | Ordinary NSView integration and engine operations for input, selection and history |

The temporary raw `webKitSubframes` extension is used by PageView's
selected-text read, SelectionCommands and ExtensionTabAudio. Those consumers
still require WebKit frame APIs and must migrate with their own script and
selection state. WebKit's native input dispatch and installed content-world
wrappers live in `WebKitPage.swift`; frame discovery no longer exposes
WebKit types.

Mail, internal documents and extension-specific WebKit surfaces need a
separate inventory from browser-tab consumers. Their continued use of
WebKit does not justify a generic browser-tab consumer reaching through it.

## Verification

`PageEngineTests` exercises real WebKit through `any PageHandle`: async
arguments, named-world isolation, the no-gesture path, JavaScript errors,
foreign-frame rejection and snapshot option mapping. It also compares
legacy page callbacks with seam results (including null, undefined and
exceptions), verifies installed consumer-world identity and callback
arguments, and reads a Sheets export using a local fetch fixture.
A local nested cross-origin iframe fixture checks discovery order, per-frame
script targeting, agent-world isolation, relay announcements, AgentPage
rediscovery and rejection of another WebKit view's frame token.
The native input fixture dispatches through `any PageHandle` into a real
WebKit document, checking a trusted click under page zoom, drag movement,
text insertion and a trusted Backspace, without triggering person takeover.
AgentKeysTests, AgentHoldTests and AgentEvalTests now construct PageView so
their existing DOM, approval-guard and async-eval assertions use the product
adapter through the migrated entry points.
`PageNavigationEventsTests` checks a real local document held before its
response reply, event order and stable navigation identity, provisional
failure delivery, late-failure matching in Tab, duplicate policy replies,
weak listener lifetime, transfer and legacy callback forwarding.
`PageActionEventsTests` holds real local document requests before fetch,
cancels a real link after the policy callback returns, checks copied source
origin and external-app frame guards, verifies all policy values and both
callback variants, duplicate replies, absent-listener behavior and preference
identity across listener transfer. `ModifiedLinkFocusTests` exercises the
installed navigation adapter's action events through Browser's policy;
SafeBrowsingTests checks the PageEvents listener and direct compatibility
entry point.
`LinkCardTests` runs its DOM selection/highlight scenario through the
handle in `.yab`. Run it and the suites
selected by `scripts/runs/tests_for.py` through `./farm`, following AGENTS.md.
These tests do not establish pixel equivalence of Capture, media behavior,
Chromium support, or engine-switch correctness.

## Permission, authentication and lifetime events

Camera/microphone, geolocation and notification questions use copied
`PageOrigin` values. `PageCapture` preserves the three existing preference
key numbers, including legacy host-only key migration. The browser keeps
its cards, remembered decisions, macOS authorization sequence and waiting
question cancellation. The adapter translates the eventual reply once,
including private geolocation and notification entry points. No live frame
or WebKit origin is handed to these handlers. Capture-state observation and
controls in Asks remain WebKit-specific and will migrate with Share/Calls.

Password authentication carries host, scheme, realm, authentication method,
failure count, proposed username and whether the proposed password was empty.
It never exports the proposed password. The browser preserves its vault
lookup, HTTP cleartext guard, retry cutoff and card/sheet fallback. Replies
are default handling, cancel or username/password values; WebKit alone makes
the session credential. Replies may be deferred beyond listener transfer
and are answered once. Lifecycle-only listeners retain default authentication
handling; without a permission handler, permission requests are refused.

Server trust evaluation remains off the main thread, with the existing
`YAB_TRUST_MAIN` diagnostic override. WebKit keeps URLAuthenticationChallenge,
SecTrust, URLCredential and profile/store-scoped certificate approvals inside
`WebKitQuestions.swift`. An unapproved chain is explicitly canceled before
its copied certificate bytes and display words are delivered. Browser only
shows a certificate page for a matching main endpoint, preserving host/port
checks and WWW retry. The TLS chain, profile approvals, expiry, and cached
connection policy are unchanged. An out-of-process engine must implement
its own trust check and profile-scoped approval capability before using this
event; a canceled subresource must not become a main-page question.

Page close and content-process termination are events too. The adapter
resolves WebKit's Leaving, DocumentPiP and LinkWindow close ownership first.
Browser's ordinary tab closing and opener selection then use PageHandle.
Termination reasons are Codable values; the public callback retains its
unknown reason and unknown private reason numbers map to crash as before.
Stuck's recovery decisions and PageEnds batching are unchanged.

`WebKitQuestions` retains direct Browser compatibility entry points for
separate WebKit surfaces and existing fixtures. This is internal seam work,
with no changed UI design, Chromium implementation or engine switch.

## Popup, dialog, file and download events

`PagePopup` carries a request id, copied `PageAction`, optional width/height,
toolbar visibility and the consumed menu foreground intent. Browser keeps
its existing gate, modified-link focus, pinned/kept Peek, routing, folder,
agent handoff and small-window placement decisions. `WindowGate` reads the
handle's trusted input timestamp and copied source rather than a WebKit
frame. Its click consumption and site/burst policy are unchanged.

The engine retains pending construction context under the popup id. Browser
answers through a callback with the id of the tab made for that request or
nil to refuse it. WebKit uses its private asynchronous creation delegate
inside `WebKitPopups.swift`; the reply can be deferred without replacing
window.open with an unrelated navigation. The supplied configuration keeps
its website store, process pool and related opener. Each ordinary child gets
its own user content controller before Browser decides whether to open it.
The returned child must be the registered tab, built with that context.
Duplicate replies are ignored and the context is removed on answer. Existing
unrelated-configuration protection still loads that child independently
rather than returning a view that would make WebKit raise an exception.

`webKitPopupTab` is an explicit temporary construction capability, not a
finished engine factory. It creates the Tab from the retained configuration;
Tab owns a PageHandle selected by its factory. A second engine must supply
its own popup construction context before it can use this path. Document PiP remains an explicitly
WebKit-only surface: its configuration, source-frame/relay authentication,
secure-origin guard, existing-child teardown and native panel construction
stay in the adapter. The public synchronous Browser method is retained only
as a direct legacy compatibility entry point; installed tab delegates use
the asynchronous private method. WebKit declares that method in
[WKUIDelegatePrivate.h](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegatePrivate.h)
and chooses it before the public synchronous method in
[UIDelegate.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/UIDelegate.mm).
The new selector is inventoried in PrivateNamesTests.

`PageDialog` and its reply are Codable values, including the engine-copied
origin. Alert, confirm and prompt preserve their page cards, debugger
notifications, agent alert collection and held decisions. Separate WebKit
surfaces still use the same AppKit system-sheet helpers with copied origin
values. `PageFilePicker` copies directory and multiple-selection flags and carries
an opaque PageFrame for the existing Files suggestion scripts;
approved uploads, agent picker suppression, Files suggestions and remembered
folders stay in Browser. Adapter replies are deferred and answered once;
a missing listener accepts the alert, rejects confirm/prompt and refuses a
file picker as WebKit did without those handlers.

`PageDownload` is a local proxy interface with a stable UUID, request,
initiation flag, source surface, page metadata and Progress. A remote engine
must mirror those fields locally and transport requests, progress, terminal
errors, resume bytes and destination replies by that UUID. Native views,
Progress and local ObjectIdentifier UI keys are not wire payloads. The latter
remain local so existing Hoard and extension ids retain their identity.
WebKit's conformance and its retained, weak-listener download delegate are
in `WebKitDownloads.swift`; no WKDownload crosses a consumer signature.

Browser receives the navigation-to-download event and keeps the same
main-frame ownership for blank-page cleanup. WebKit fits DiaryPage's
controller before a response becomes a download. Destination questions wait
for one URL reply. Browser keeps agent destinations, site permission cards,
multiple-download coalescing, save panels, duplicate-click suppression,
folder access, filename selection, quarantine, provenance and tidying.
Hoard and AgentFiles use the download proxy for ownership, progress, cancel,
pause, retry, resume and completion. Restart is an asynchronous operation on
the original download, so a standalone WebKit surface remains a valid source
without becoming a browser-tab handle. Source disappearance reports nil
rather than silently leaving the row running. SiteDownloads no longer
imports WebKit; its page/input identity and remembered policy are unchanged.

Only the current WebKit extension system's created/named/finished/failed and
resume-carry hooks remain explicit `webKit*` download integration points.
Download-only blank-page cleanup retains an explicit WebKit history query
and close-ownership capability until ordinary history and auxiliary-window
ownership migrate. Remaining concrete consumers, authenticated general
messages and all 21 relays are still unfinished. The replacement switch point
is implemented; a Chromium engine and complete native history transfer are not.

`PagePopupEventsTests` and `PageDownloadEventsTests` exercise real WebKit
popup/dialog/download requests, deferred answers, listener transfer,
configuration/opener inheritance, file permission values and download
success/failure. Existing popup focus, DocumentPiP, permission, download
part/retry and Hoard suites remain in the farm selection. Passing fixture
coverage does not establish signed-in OAuth, real-profile media/download
acceptance or a working Chromium implementation.

## Process health and responsiveness

Stuck and Deaf use `Tab.builtPage`, locally mirrored `contentProcess`,
`gpuProcess` and `captureStatus`, and asynchronous scripts with
`gesture: false`. A health probe retains its existing timeout and counts any
callback as an answer, including a script error. It never manufactures a
user gesture. Memory, draft, agent, call and foreground protections, strike
counts, process grouping and reload/stop ordering are unchanged.

`PageMediaState` distinguishes absent, active and muted capture.
`PageCaptureStatus` copies the camera, microphone and display states into a
Codable value. The WebKit implementation reads its native capture states;
a separate engine must mirror its own state locally. This is a read
contract; capture KVO is owned by WebKitPageState and media controls use
the handle.

WebKit's private responsive/unresponsive callbacks emit
`PageEvents.page(_:responsive:)` through the current weak listener. Browser
keeps its existing deaf-page policy, question timing and recovery. The raw
Browser callback methods remain in WebKitProcesses for standalone WebKit
surfaces and compatibility callers.

WebKitProcesses also contains the private process identifiers and content
termination selector. `PageProcessLife` provides the shared local macOS
process birth-time check and guarded termination, so Stuck can protect
against a recycled pid without depending on WKWebView. The legacy
WKWebView helpers forward to the same checks. Process ids refer only to
local processes; an out-of-process engine must mirror them without waiting
on a synchronous page response.

The global `PageView.reached` input hook remains a WebKit construction/input
extension point in WebKitProcesses. Process-pool census, shared-process
selection and memory ceilings still need their own migration. No GPU kill,
actual hung-page recovery, live call, Chromium or engine replacement is
claimed verified by the health unit suite.

## Calls and capture controls

Calls, CallControls and CaptureDot use `PageMediaState` rather than a native
capture enum. Its numeric values retain the existing none/active/muted
values, including Bench's diagnostic output. Tab still observes WebKit
capture events from WebKitPageState; engine ownership is through PageHandle.

Camera/microphone changes and the display-capture fallback use asynchronous
PageHandle commands. The WebKit adapter maps them to the existing capture
setters and private display-capture selector, without changing their reply
ordering or the page's own mute/share-button preference.

CallStage accepts a PageHandle and uses the retained named `call` world.
Its short-call-first path, one-time stage injection, promises, weak page
capture, missing-stage marker and diagnostic byte accounting are preserved.
The raw WKWebView overload and content-world access are in WebKitCalls for
standalone surfaces and legacy fixtures; tab views forward to the seam.

WebKitCalls keeps the authenticated CallRelay registration and its unchanged
script until the general message primitive migrates. The native floating
view still belongs to Floater's WebKit lifecycle and uses the explicit
`webKitPutOut` extension point. Migrating ordinary call controls does not
claim that another engine can already float a call or that live camera,
microphone, device switching, meeting accounts or screen sharing passed.

## Share script endpoints

Share no longer imports WebKit or names native frame/view types. Its tab
geometry and lifecycle checks use builtPage; scripts, transport preparation,
frame delivery and teardown use named-world calls with PageFrame. Share's
picker, source selection, native ScreenCaptureKit feeds, backpressure,
readiness checks, focus retries and teardown order are unchanged.

`PageScriptTarget` is the scripting part of PageHandle, also implemented by
standalone WebKit documents. Share.Session can weakly reference such a
script-only document without giving it tab navigation, process, input or
ownership capabilities. WebKitPage implements the same script dispatch and
foreign-frame guard for both kinds of surface. Existing tab script callers
inherit the same methods through PageHandle.

PageFrame now includes an origin copied by the adapter. Share's normal
same-site/input checks use that metadata. `committedURL` mirrors the current
history entry so RelayGuard keeps checking the committed page while a new
address is provisional. It preserves the old backForwardList lookup and
address fallback rather than substituting a provisional URL.

WebKitShare holds the native display-picker callback, ShareRelay message
adapter, extension grant/audio conversion, raw offscreen-document/session
compatibility and Bench's native keep-drawing hooks. Extension grants and
audio taps remain capabilities of the current WebKit extension shim and
fail closed for unsupported frame/endpoint types. General message
registration, raw opaque frame-token transport, and native hidden-view
hosting remain separate work before a Chromium implementation can replace
the engine. No real recording, system picker, live screen-share pixels,
audio stream or signed-in extension profile is claimed by script tests.

`TabEngineTests` uses a non-WebKit NSView engine to test lazy construction,
factory choice, replacement identity/current entry/sibling position, stale-event
rejection, ordinary navigation controls, unavailable-engine refusal, serializable
state and session round trips. `PageStateEventsTests` verifies real WebKit KVO
conversion, listener transfer/removal and Tab state independent of its navigation
delegate. These fixtures do not establish Chromium, DRM fallback or signed-in
profile acceptance.

## Initial Chromium blank-fragment navigation

CEF may navigate its bootstrap `about:blank` document to a requested fragment
without another load-start/commit callback. ChromiumPage retains the initially
requested URL and the native loading receipt separately. Only a native URL
patch matching that exact requested `about:blank#…` may finish this initial
wait; a bootstrap, another tab or an incidental fragment during an HTTPS load
cannot. URL changes reach the state listener before the remembered loading
receipt. No page script, fake commit or second engine is used to settle it.

`Seam2InitialNavigationTests` covers split/combined URL and loading patches,
foreign identities and repeated incidental fragments. The signed golden check
is `evals/golden/chromium_initial_blank.py`; its exact integration-BASE control
and runtime acceptance are recorded in the seam2 track report. A test's initial
page must really finish loading before its sleep, source-tab or shared-renderer
assertions can establish parity.
