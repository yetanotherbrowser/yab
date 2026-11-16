# The Mac around a Chromium page

A Chromium page lives in a window that is never on screen, inside the helper.
What Chrome does with that window (cursor, tooltips, drags, dialogs,
accessibility, its display) has to cross to Yab's view. This is what crosses and
how. `evals/chromium-system` checks each row on a signed build:

    ./farm exec --display --needs foreground,pointer --urgent --name "…" -- \
        bash evals/chromium-system/job.sh APP [areas]

Areas that move the real pointer or press keys (`drag`, `hover`, `keys`, `ime`,
`paste`, `access`) need `pointer`.

| What | How it crosses |
| --- | --- |
| Drags | `Input.setInterceptDrags` hands a drag the page starts to Yab (`page.dragStart`), which runs an AppKit session from the page's view. What is dragged over that view goes back in through `Input.dispatchDragEvent` (`input.drag`), files included. Trusted CDP input from an agent keeps DevTools' own drag controller (`DragScriptInput`). |
| Cursor | `OnCursorChange` sends Chromium's own NSCursor as a picture, once per kind (`page.cursor`). Yab sets it only while the pointer is over the page. |
| Tooltips | CEF calls `OnTooltip` only for offscreen views, so `chromium-tips.js` reads the nearest `title` over the pointer. Drawn as every tip in Yab is (`KeyTip`). |
| Links for other apps | `OnBeforeBrowse` stops every scheme a page can't show (`page.external`); `Browser`'s action policy decides, as on a WebKit tab. Chrome's own question would wait in a hidden window. |
| Keys | Every ⌘ key goes to the page first, as on WebKit (`ContentView.pageFirst`) and in Chrome. `OnKeyEvent` returns what the page left (`page.keyUnhandled`), and the same event goes through the app again. Edit's keys and the ones that make and close windows stay the app's. |
| Passkeys | Yab's own ceremony (`Passkeys`), through the page script and relay WebKit tabs use. The relay waits as long as the Mac's sheet does. Chrome's dialog would wait in a hidden window. |
| Downloads | A file with the page's user activation goes ahead with no question, as `WKDownload.isUserInitiated` does; the rest take Yab's card. |
| Accessibility | `NSAccessibilityRemoteUIElement`: a token for the helper's element of the tab (`YabPageAccessibility`) becomes a child of Yab's view, and Yab's view its parent. The element answers with the tab's page view of the moment, as `views::WebView` does: each document (another site, a page back from the cache) has a view of its own. Asked for only when an assistive client reads the view (`SetAccessibilityState` builds the tree); once one has, pages attached later ask at once, as Chromium's mode is the whole process's. While it is read the hidden window follows the page (`tab.place`), so the tree's frames are true. A client typing into the page's focused field with `AXSelectedText` (dictation and text tools) is typed through the page's view (`insertText:replacementRange:`), as Yab commits typed text: Chromium turns that write into `kReplaceSelectedText`, which its renderer drops. `evals/ax-hints` counts what a hint app (Neru) finds, against Chrome. |
| Crash reports | `Crashes.reports` takes the helper's `YabCore…` reports too. |
| Folder uploads | Chrome asks "Upload N files?" as a tab-modal dialog on the hidden window. `queue/0060-folder-upload-no-hidden-dialog.patch` waits for the next SDK; until then `webkitdirectory` inputs hang. |

What no farm job can do: real sleep and wake, pulling the network, low power mode
and thermal states. `area_power` stands in with a stopped process tree, DevTools'
offline and `Memory.simulatePressureNotification`, and says so.

Open: a page takes its pixel density from the hidden window's display, the main
screen, not the display it shows on; and an update still swaps under a running
helper, so new renderers come from the new bundle until Yab restarts. Fixes for
both wait, unproved, on `claude/chromium-system-held`.
