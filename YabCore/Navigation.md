# Navigation wire additions

This supplements wire v1. The default app engine remains WebKit. These
methods are implemented by `src/navigation.inc`, included by the private
core dispatcher. No CEF object crosses the socket.

- `page.zoom {tab, factor}` sets native Chromium page zoom. The factor must
  be finite and between 0.25 and 10. Yab applies its narrower existing
  UI range and remembers values per site.
- `file.open` carries `tab`, opaque `request`, `directories` and `multiple`.
  It comes from CefDialogHandler, not a document script. The app replies
  with `file.reply {tab, request, paths:[absolute paths]}`. An empty list
  cancels. An old request ID or an invalid path list is rejected. Callback
  state is released before invoking CEF, including on tab close.
- Native `dialog.open` events from CefJSDialogHandler are translated into
  PageDialog and the existing Asks card. The one-shot callback uses the
  page-question registry; the app replies with `dialog.reply {tab, request,
  accept, text}` directly on the live connection, outside the serialized
  renderer-operation queue. Unknown/stale tokens and wrong tabs are rejected.
  Tokenless tab-scoped wire-v1 replies remain supported for direct clients.
  Beforeunload uses the same native callback, with Leaving owning the close
  lifecycle and its existing Stay/Leave UI.
- The `yabFindChanged` binding is registered only in the `yab-world-yab`
  isolated world. The Finder script uses it for dynamic count updates.
  Its JSON payload changes only Finder state. This is not an authenticated
  general-purpose page-message or permission channel.

Acceptance is `evals/chromium-nav/job.sh` on a farm display worker. It
builds the real helper and app with CEF, uses an isolated profile and local
HTTP fixtures, captures the Yab window through ScreenCaptureKit, then runs
the tests selected by `scripts/runs/tests_for.py`. See the track's REPORT
for actual results and remaining boundaries. A fixture upload supplied via
`Tab.uploading` proves the callback and selected file contents; it does not
prove the custom FormFiles UI, directory upload, or iframe upload.

## Print and native find candidate

These additions live in `src/print_find.inc`. See the track report for
acceptance; source support alone does not establish PDF viewer parity.

- `page.find {tab, text, forward}` invokes CEF's native search and replies
  only on the final count, with `count` and one-based `ordinal`. The adapter
  serializes searches and Stop to preserve callback identity. CEF 156
  forwards its findNext flag to Chromium's find_match argument, so it is
  true even for the first query. Chromium recognizes a new text session.
- `page.find.stop {tab}` clears native find marks and cancels a pending find.
- `page.printPDF {tab, paperWidth, paperHeight}` renders the full document
  using print styles onto paper of that size in inches (Letter when none is
  given) with 1 cm margins, and returns an opaque stream token.
- `page.pdf.read {tab, stream}` returns at most 192 KiB per CDP read as
  `data`, `base64Encoded` and `eof`. The token is scoped to its originating
  tab. The app limits decoded PDF bytes to 64 MiB; the helper limits encoded
  stream data and the number of simultaneous streams.
- `page.pdf.close {tab, stream}` releases the stream. EOF, document change,
  renderer termination and tab close also release retained streams.

The print consumer sends the generated PDF to PDFKit's native AppKit print
operation, attached to Yab's own window. Save as PDF uses the existing
PageSave entry point. This is a paginated print document, not an implementation
of PageHandle.pdf(rect:) for viewport/tall-region capture. Page-authored
window.print() interception is not implemented by these additions.

## Native site questions candidate

`src/questions.inc` retains callback continuations on CEF's browser UI
thread. `question.open` contains a fresh opaque `request`, a native `kind`
and copied origin. The only reply is `question.reply {tab, request, allow}`,
with `user` and `password` for HTTP auth. A mismatched tab or request is
rejected, and the registry entry is removed before invoking CEF. Navigation
commit, renderer crash and close cancel outstanding callbacks. Auth's IO
callback dispatches to the UI thread before accessing the registry.

Kinds `capture`, `location`, `notifications` and `auth` route to existing
PageEvents and Asks/Dialogs UI. Capture grants exactly the requested device
mask; desktop capture and unsupported prompt types are denied. Notification
and location grants still depend on their platform providers. The isolated
runtime probe can request fake media devices; it never auto-grants media or
system permission, and normal app launches do not receive that switch.

`src/certificates.inc` sends kind `certificate` only after CEF rejects TLS.
It copies the leaf and complete issuer chain as bounded DER base64, the
native error and names, and whether the request matches the pending main
navigation. The adapter checks remembered exact-chain exceptions in the
Chromium profile; otherwise it cancels first and presents the existing
Untrusted screen for the main request only. Continue records the exact
endpoint and chain and retries. Exceptions use the existing lifetime/file
rules with separate Chromium profile keys; private exceptions are in memory.
No global TLS bypass or system trust mutation is used. Site-data clearing
for Chromium contexts remains dependent on the profile track's integration.

## Downloads candidate with prebuilt-CEF limits

`src/downloads.inc` copies native `download.open {tab, download, url, name,
mime, total}` and `download.updated` progress/terminal state. The app replies
with `download.destination {tab, download, path}` or `download.cancel`.
The token remains scoped to the original tab even after that tab closes;
control dispatch does not require its producer window to remain registered.
No CEF item pointer is retained across callbacks. The destination callback
is released on cancel, and native registry entries leave before cancellation
or after a terminal update. A live process-level Swift proxy routes updates
to Browser/Hoard/Loot even after the source page retires.

The official CEF item does not supply original request method/body or
trustworthy user gesture metadata. The candidate exposes no replayable
original request and conservatively asks via SiteDownloads. Retry/resume,
exact source attribution, download-only tab closure and extension downloads
are not certified by this adapter. These remain part of the native contract
in the track's DOWNLOAD-CONTRACT.md. This implementation does not call the
unbuilt facade additions from that proposal.

## Native navigation beforeunload and renderer endings candidate

`dialog.open` kind `beforeunload` uses PageDialog's explicit beforeUnload
case and the existing serialized Leave card. Stay replies to the original
blocked native navigation and restores the shown address; Leave lets the
original continuation proceed. This covers navigation/reload only. Closing
several tabs, a window or the app still needs the non-destructive native
preflight in the track's LIFECYCLE-CONTRACT.md.

`page.crash` now reports PageEnd through the existing Browser retry budget
and repeated-crash UI. OOM maps to memory; other renderer endings map to
crash. Remote recovery navigates the existing handle rather than casting
it to WebKit. Helper loss retains its explicit existing load-error/reload
behavior. `page.crashForTesting` is accepted only when the helper was
launched with the isolated test world's mock-keychain switch; it invokes
the real CDP Page.crash, not a synthesized crash event.

## Native history candidate

`history.read` returns Page.getNavigationHistory's native entries and current
index. `history.go` takes an integer `entry` ID, re-reads that browser's
current native history, and calls Page.navigateToHistoryEntry only if the
ID is still present. An expired menu entry is a no-op; it never becomes a
new URL load, and an entry from another tab cannot authorize navigation.

The host adapts this snapshot to the existing DoorList and Search History
panel. WebKit still supplies its original entries/actions through a local
adapter. Chromium list creation is asynchronous and a later press, key,
close or detached source invalidates its pending opening. Row/panel choices
use native entry IDs, preserving native history rather than replaying URLs.
Opening a history destination beside the current tab reads the nearest
native entry and uses the existing openBeside policy. This is a history
menu candidate, not a claim that PageView's swipe gesture has been migrated.

For ordinary tab bootstrap, the host explicitly supplies an empty initial
URL. The dispatcher preserves empty versus missing: pinned CEF creates no
initial navigation for empty, whereas an explicit about:blank is a real
committed history entry. The menu never filters real native history rows.

Certificate provenance comes from pinned certificate_query::AllowCertificateError,
which denies subresources before invoking CefRequestHandler::OnCertificateError.
The native event therefore marks mainFrame directly. It supplies the final
failed URL through PageCertificate.failingURL so an HTTP-to-HTTPS redirect
can show the existing Untrusted screen before its final address commits.
WebKit leaves that optional field nil and retains its previous lookup.
Primary implementation:
https://github.com/chromiumembedded/cef/blob/4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f/libcef/browser/chrome/chrome_browser_host_impl.cc
https://github.com/chromiumembedded/cef/blob/4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f/libcef/browser/certificate_query.cc
