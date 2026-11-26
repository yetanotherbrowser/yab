#include "core.h"
#include "launch_trace.h"
#include "script_errors.h"
#include "core_lifetime.h"
#include "gpu_stability.h"
#include "original_caller.h"
#include "group_snapshot_store.h"
#include <CommonCrypto/CommonDigest.h>
#include "extensions.h"
#import <QuartzCore/QuartzCore.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <atomic>
#include <unordered_set>
#include <functional>
#include <fcntl.h>
#include <sys/mman.h>
#include <cerrno>
#include "original_pdf_budget.h"
#include "original_pdf_presence_owner.h"
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <vector>
#include <memory>
#include <iterator>
#include "keyboard_event.h"
#include <string>
#include <cmath>
#include <climits>
#include <algorithm>
#include <libproc.h>
#include <signal.h>
#include <unistd.h>
#include "include/cef_process_message.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_server.h"
#include "include/cef_command_line.h"
#include "include/cef_preference.h"
#include "include/cef_command_handler.h"
#include "include/cef_id_mappers.h"
#include "devtools_commands.h"
#include "devtools_extensions.h"
#include "devtools_files.h"
#include "devtools_target.h"
#include "extension_oauth.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_resource_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_response.h"
#include "include/cef_download_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_task.h"
#import "site_notice_center.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <bsm/libbsm.h>
#include <servers/bootstrap.h>
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_navigation_entry.h"
#include "include/cef_ssl_status.h"
#include "include/cef_x509_certificate.h"
#include "shield_engine.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"
#include "owncef_surface.h"
#include "page_zoom.h"
#include "accessibility_api.h"

// The experimental callback is available only with matching patched CEF.
#if defined(CEF_YAB_LAYER_CONTEXT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_OWNCEF_SURFACES 1
#else
#define YABCORE_OWNCEF_SURFACES 0
#endif
#if defined(CEF_YAB_EXTERNAL_HOST_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTERNAL_HOST 1
#else
#define YABCORE_EXTERNAL_HOST 0
#endif
#include "extensions_native.h"
#include "extensions_actions.h"

// AppKit gives no way to make a magnify event, and the original stays in the
// client's process. As in Chromium's SyntheticPinchEvent
// (synthetic_gesture_target_mac.mm), an object with what the view's event
// builder reads stands in for one, so a pinch takes the same path as Chromium's.
@interface YabGestureEvent : NSObject
@property NSEventType type;
@property NSEventPhase phase;
@property CGFloat magnification;
@property NSPoint locationInWindow;
@property NSTimeInterval timestamp;
@property NSEventModifierFlags modifierFlags;
@property(readonly) CGFloat deltaX;
@property(readonly) CGFloat deltaY;
@end
@implementation YabGestureEvent
@end

namespace yc {
static std::string Key(NSString* s) { return s.UTF8String ?: ""; }
static NSString* Str(const CefString& s) { return @(s.ToString().c_str()); }
static NSString* S(NSDictionary* p, NSString* k) { return [p[k] isKindOfClass:NSString.class] ? p[k] : @""; }
static double Now() { return NSProcessInfo.processInfo.systemUptime; }
// Deadlines are kept on the time this helper was running: while its main
// thread was held (a loaded Mac, swap, the process stopped) nobody could
// answer anything, so that time is no one's lateness. Before, the poll after
// such a pause found every deadline gone and failed the pages waiting
// ("Operation timed out", "CDP timeout"), each a PageLoadFailure report.
// The poll timer measures it: how much later than asked it came.
static double heldFor = 0;
static double Running() { return Now() - heldFor; }
// YAB_CEF_TRACE_TIMING: one line per step, on the same clock as Swift's marks.
static void Mark(const char* step, const std::string& detail = "") {
  static const bool on = getenv("YAB_CEF_TRACE_TIMING") != nullptr;
  if (on) fprintf(stderr, "YabCore T %.1f %s %s\n", NSDate.date.timeIntervalSince1970 * 1000, step, detail.c_str());
}
static NSDictionary* Decode(const void* bytes, size_t size) {
  if (!bytes || !size) return @{};
  id v = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:size] options:0 error:nil];
  return [v isKindOfClass:NSDictionary.class] ? v : @{};
}
static NSString* JSON(id value) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:value ?: NSNull.null options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}
// A request context is usable only after CEF reports it initialized: creating a
// browser earlier trips Chromium's own check in source builds. profile.open
// answers (and later opens of the same profile wait) until then.
// A private profile opened with a parent is that space profile's own
// off-the-record side (CEF 0092), as Chromium's incognito is of its profile:
// the space's extensions allowed in private tabs run there, and nothing is
// written to the space. Without the capability, or a parent, it is CEF's
// in-memory default, which no space's extension reaches.
struct Profile { CefRefPtr<CefRequestContext> context; bool privateMode = false; bool ready = false; std::vector<NSString*> waiting; std::string parent; };
#if defined(CEF_YAB_OFF_THE_RECORD_CONTEXT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_PRIVATE_EXTENSIONS 1
#else
#define YABCORE_PRIVATE_EXTENSIONS 0
#endif
#include "scripts_state.h"
#if defined(CEF_YAB_EXTERNAL_PAGE_VERSION) && YABCORE_OWNCEF_SURFACES && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_PAGE 1
#else
#define YABCORE_NATIVE_PAGE 0
#endif
#if defined(CEF_YAB_NATIVE_TAB_MODEL_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_TAB_MODEL 1
#else
#define YABCORE_NATIVE_TAB_MODEL 0
#endif
struct Tab {
  std::deque<std::shared_ptr<QueuedKeyboardEvent>> keyboard;
  std::string healthToken, healthFrame;
  pid_t healthPID = 0;
  double healthSendAt = 0, healthDeadline = 0;
  bool healthSent = false, healthUnresponsive = false, healthAgain = false;
  uint64_t healthPings = 0, healthPongs = 0;
  ScriptState scripts;
  std::string id, profile;
  std::string opener;
  NSString* creationURL = nil;
  NSString* title = @"";
  bool foreground = true;
  NSDictionary* popupSource = nil;
  NSDictionary* extensionCreation = nil;
  bool creationAnnounced = false;
  // Only a client-created, empty endpoint may manufacture a bootstrap load.
  // A native popup owns its pending navigation even before HasDocument is true.
  bool scriptBootstrapAllowed = false;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefBrowserView> view;
  CefRefPtr<CefWindow> window;
  CefRefPtr<CefRegistration> observer;
  NSWindow* native = nil;
  bool nativeExtensions = false;
  // A Chrome-created window (popup, tab in a Chrome window) has frame or
  // toolbar around the page: fit the page view to the requested size.
  bool fitPage = false;
  // Chrome's DevTools frontend for this page, and whether this tab is one.
  std::string devToolsFront; bool devToolsFrontend = false;
  bool browseGesture = false, browseRedirect = false;
  bool adopted = true, closing = false, visible = true, internal = false, themeReady = false, crashed = false, transportReady = false, domainsReady = false;
  // A worker's clients.openWindow() after a click on its notification.
  bool fromNotice = false;
  double themeAttempt = 0;
  double width = 800, height = 600, scale = 1;
  NSString* lastLayer = nil;
  OwnCEFSurface surface;
  bool externallyHosted = false;
  bool externalPage = false;
  bool pinched = false;
  // The zoom the page is drawn at, as its renderer said (page_zoom.h).
  yabcore::PageZoomCache zoomRead;
  // A page's own floating window. CEF always gives it Chrome's own Browser and
  // window, so it has no Views window and no compositor callback.
  bool documentPiP = false, documentPiPSized = false;
  NSString* nativePageToken = nil;
  NSDictionary* nativePageReceipt = nil;
  bool audible = false, focused = false, discarded = false, frozen = false;
  // The page holds the pointer (pointer_lock.inc), and where in its hidden
  // window the pointer last was.
  bool pointerLocked = false, pointerPointKnown = false;
  NSPoint pointerPoint = NSZeroPoint;
  // Muted by Yab (media.mute): what the browser's audio must stay (KeepMuted).
  bool mutedWanted = false;
  // The element Yab holds a token for, which stands for the page's document
  // view of the moment, and that view (accessibility.inc).
  ::id accessibilityElement = nil;
  __weak NSView* accessibilityView = nil;
  // Its waiting events were shed (transport.h) and its document is being ended.
  bool shedding = false;
  uint64_t visibleTurn = 0;
  bool everShown = false, viewCleared = false;
  // An agent's files for the next picker the page opens (agent_files.inc).
  NSArray* offeredFiles = nil;
  // Pictures in flight. Blink's scheduler counts a page being pictured as visible.
  int capturing = 0;
  // A hide that came while a picture was in flight: run once it is taken.
  bool clearAfterCapture = false;
  NSDictionary* textState = nil;
  NSString* closeOwner = nil;
  NSString* closeWireRequest = nil;
  NSDictionary* closePreflight = nil;
  bool closeUnresponsive = false;
  bool quitUnresponsive = false;
  uint64_t closeDocumentGeneration = 0;
  NSString* backgroundColor = nil;
  NSString* resizeSerial = nil;
  int resizeWidth = 0, resizeHeight = 0;
  int selectToken = 0;
  NSString* createRequest = nil;
  NSString* extensionPath = nil;
  bool extensionLoadPending = false;
  pid_t rendererPID = 0;
  uint64_t rendererBorn = 0;
  uint64_t documentGeneration = 0;
  bool drmReady = false, drmInstalling = false;
  std::vector<Completion> drmWaiters;
  std::string drmMainFrame;
  std::map<int, std::string> drmFrames;
  std::map<std::string, int> worlds;
  std::map<int, std::string> contextNames;
  std::map<std::string, std::set<std::string>> bindings;
};
struct Pending { int browser; Completion completion; double deadline; };
static Transport wire;
static NSString* dataRoot;
static std::map<std::string, Profile> profiles;
static std::map<std::string, Tab> tabs;
static std::map<int, std::string> browserTabs;
// A native creation receipt (OnExtensionTabCreated) that arrives before its
// browser's OnAfterCreated: an extension's windows.create from its service
// worker makes Chrome's Browser, and CEF reports the page to the client only
// later. Held by browser id until that page is a Yab tab, never dropped, or
// the page was retired as unrequested and Bitwarden's passkey window closed
// as it opened.
static std::map<int, CefRefPtr<CefDictionaryValue>> earlyExtensionReceipts;
static void ApplyEarlyExtensionReceipt(Tab& tab, int browser);  // owncef_native.inc
static void AccessibilityFocused(Tab& tab, bool focused);  // accessibility.inc
static void AccessibilityDocument(Tab& tab);  // accessibility.inc
static std::map<int, Pending> pending;
static std::map<std::string, double> requests;
static int sequence = 0, tabSequence = 0;
static bool hello = false, stopping = false;
static void OriginalPDFBrowserClosed(int browser, NSString* reason);
static void ClearOriginalPDF();
static void OriginalPDFPresenceSuspend(int browser);
static void OriginalPDFPresenceClosed(int browser);
static void ClearOriginalPDFPresence();
static void OriginalPDFPresenceDocumentEnded(CefRefPtr<CefBrowser> browser);

static int nativeCloseDepth = 0;
static bool contextInitialized = false, shutdownStarted = false;
static NSTimer* timer;
static NSMutableArray* windowWatches;
static uint64_t pollTicks = 0, fastPollTicks = 0, windowNotifications = 0, pollHurries = 0;
static void PollHurry();
static Tab* Find(CefRefPtr<CefBrowser> browser) {
  if (!browser) return nullptr;
  auto i = browserTabs.find(browser->GetIdentifier());
  if (i == browserTabs.end()) return nullptr;
  auto t = tabs.find(i->second); return t == tabs.end() ? nullptr : &t->second;
}
static bool IsReadTab(const Tab* tab);
static void Event(NSString* name, Tab* tab, NSDictionary* payload = @{}) {
  if (IsReadTab(tab) && ![name hasPrefix:@"read.page."]) return;
  if (!hello) return;
  NSMutableDictionary* p = [payload mutableCopy];
  if (tab) p[@"tab"] = @(tab->id.c_str());
  wire.Send(@{@"v": @1, @"event": name, @"params": p});
}
#include "owncef_surface.inc"
#include "owncef_page.inc"
static void Reply(NSString* id, ::id result = @{}, NSString* error = nil) {
  if (!id || requests.erase(Key(id)) == 0) return;
  if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore reply id=%s error=%s\n", id.UTF8String, error ? error.UTF8String : "-");
  NSMutableDictionary* value = [@{@"v": @1, @"id": id} mutableCopy];
  if (error) {
    value[@"error"] = @{@"code": @"operation_failed", @"message": error};
    // Failures are otherwise visible only to the client; keep them in the helper log too.
    fprintf(stderr, "YabCore error reply: %s\n", [error substringToIndex:MIN(error.length, (NSUInteger)300)].UTF8String);
  }
  else value[@"result"] = result ?: NSNull.null;
  wire.Send(value);
}
// `deadline`: the client request's own when the call is made for one (a
// page's scripts and appearance before its load), else 15 s for the helper's
// own work. Chrome's DevTools commands have no deadline: one ends with its
// answer, or with its target closed or crashed (DevToolsSession::
// ClearPendingMessages), as these end in CancelPending. A fixed 15 s under a
// request the client allows 300 s failed a page whose renderer answered at
// 16 s: "The page couldn't load", YabCoreError.remote "CDP timeout" (R1982).
static void CDP(Tab& t, NSString* method, NSDictionary* params, Completion completion, NSString* session = @"", double deadline = 0) {
  if (!t.browser || t.closing || !t.transportReady) { completion(nil, @"Tab DevTools is not ready or is closing"); return; }
  // No count of calls in flight: Chrome's DevTools sessions have none, and
  // each ends at its deadline below. 300 tabs waking at once with their
  // frames attaching sent more than a fixed 8192 and failed pages.
  NSString* encoded = JSON(params);
  auto v = CefParseJSON(Key(encoded), JSON_PARSER_RFC);
  int id = ++sequence;
  if (getenv("YAB_CEF_TRACE_CDP")) {
    NSString* source = S(params, @"expression");
    if (!source.length) source = S(params, @"functionDeclaration");
    if (!source.length) source = S(params, @"source");
    fprintf(stderr, "YabCore CDP send id=%d browser=%d window=%ld internal=%d method=%s bytes=%lu sourceBytes=%lu argumentBytes=%lu\n",
      id, t.browser->GetIdentifier(), (long)t.native.windowNumber, t.internal, method.UTF8String,
      (unsigned long)[encoded lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
      (unsigned long)[source lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
      params[@"arguments"] ? (unsigned long)[JSON(params[@"arguments"]) lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : 0UL);
  }
  pending.emplace(id, Pending{t.browser->GetIdentifier(), completion, deadline > 0 ? deadline : Running() + 15});
  int sent;
  if (session.length) {
    NSString* message = JSON(@{@"id": @(id), @"method": method, @"params": params, @"sessionId": session});
    sent = t.browser->GetHost()->SendDevToolsMessage(message.UTF8String, [message lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
  } else sent = t.browser->GetHost()->ExecuteDevToolsMethod(id, Key(method), v ? v->GetDictionary() : nullptr);
  if (!sent) { pending.erase(id); completion(nil, @"CDP rejected command"); }
}
static void Ignore(NSDictionary*, NSString*) {}
// Only our inspector session's results reach this path. The person's DevTools
// and chrome.debugger clients own their own object handles and release them.
// Called outside the observer notification, before delivering the text/value
// result. Releasing a handle does not erase the serialized exception details.
static void ReleaseScriptObjects(const std::string& id, NSString* session, NSArray<NSString*>* objects) {
  if (!objects.count) return;
  auto found = tabs.find(id);
  if (found == tabs.end()) return;  // Closing the target releases its handles.
  for (NSString* object in objects)
    CDP(found->second, @"Runtime.releaseObject", @{@"objectId": object}, Ignore, session);
}
// The page's zoom and pinch for a pointer or drag event, then `send` with
// them. The renderer's own zoom, not the zoom controller's level: in manual
// mode (Chrome's PDF viewer) that level is the viewer's and the page is not
// drawn at it (page_zoom.h, #1906). Read once per document and level; while a
// read is in flight later events wait behind it, so they keep their order.
static void WithPageZoom(Tab& tab, NSString* request, std::function<void(double zoom, double pinch)> send) {
  double level = tab.browser->GetHost()->GetZoomLevel();
  uint64_t generation = tab.documentGeneration;
  if (!tab.pinched && tab.zoomRead.Usable(generation, level)) { send(tab.zoomRead.zoom, 1); return; }
  tab.zoomRead.Ask(generation);
  std::string tabID = tab.id;
  CDP(tab, @"Page.getLayoutMetrics", @{}, [=](NSDictionary* value, NSString* error) {
    auto live = tabs.find(tabID);
    if (live != tabs.end()) live->second.zoomRead.Answered(generation);
    if (error) { Reply(request, nil, error); return; }
    NSDictionary* viewport = [value[@"cssVisualViewport"] isKindOfClass:NSDictionary.class] ? value[@"cssVisualViewport"] : @{};
    double zoom = yabcore::PageZoomOr([viewport[@"zoom"] doubleValue], level);
    double pinch = viewport[@"scale"] ? [viewport[@"scale"] doubleValue] : 1;
    if (!std::isfinite(pinch) || pinch <= 0) { Reply(request, nil, @"Invalid visual viewport scale"); return; }
    if (live != tabs.end() && live->second.documentGeneration == generation) live->second.zoomRead.Keep(zoom, generation, level);
    send(zoom, pinch);
  });
}
// Each tab has a window of its own, and a window keeps its last frame's surfaces
// in the GPU process for as long as no frame follows: a page-sized pass and its
// overlay per tab ever shown, 600 MB at 12 tabs of a 2x window. So the page's
// view goes first, the window draws without it until the overlay in flight is
// back, and only then hides. Nobody is looking: Yab took the window's layer down first.
static void HideProducer(Tab& tab) {
#if YABCORE_NATIVE_PAGE
  if (tab.externalPage) { if (tab.browser) tab.browser->GetHost()->SetExternalPageVisibility(false); return; }
#endif
  if (tab.window) tab.window->Hide();
}
// The window is still shown: on its way to hiding (HideClearing), its page
// still visible to itself, the view perhaps already cleared.
static bool ProducerShown(Tab& tab) {
  return !tab.externalPage && tab.window && tab.window->IsVisible();
}
static bool HoldHideForPicture(Tab& t);  // page_snapshot.inc
static void HideClearing(Tab& t) {
  // A picture asked before the hide (the stage's leaving picture is) is taken
  // with the page as it was shown; the hide follows it (FinishSnapshot).
  if (HoldHideForPicture(t)) return;
  std::string id = t.id;
  // A hide run again after a picture retires the timers of the one before.
  uint64_t turn = ++t.visibleTurn;
  t.viewCleared = true;
  t.view->SetVisible(false);
  auto later = [id, turn](int ms, void (^work)(Tab&)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      auto found = tabs.find(id);
      if (found == tabs.end() || found->second.closing || found->second.visibleTurn != turn) return;
      work(found->second);
    });
  };
  // The page's view is hidden and paints nothing: the window itself is told to.
  for (int ms : {40, 90, 140}) later(ms, ^(Tab& tab) { if (tab.window) tab.window->SetBackgroundColor(tab.window->GetBackgroundColor()); });
  later(200, ^(Tab& tab) { HideProducer(tab); });
}
// A shutdown request and the peer's disconnect both end the run; the message
// loop may be asked to quit only once (a second call trips CEF's context check).
static void QuitOnce() {
  static bool quit = false;
  if (quit) return;
  quit = true;
  CefQuitMessageLoop();
}
static void Eval(Tab& t, NSString* expression, int context, Completion completion, bool userGesture = false, bool repl = false) {
  NSMutableDictionary* p = [@{@"expression": expression, @"returnByValue": @YES, @"awaitPromise": @YES} mutableCopy];
  if (userGesture) p[@"userGesture"] = @YES;
  // A script's top-level let can be run again, as an eval's could.
  if (repl) p[@"replMode"] = @YES;
  if (context) p[@"contextId"] = @(context);
  CDP(t, @"Runtime.evaluate", p, [completion](NSDictionary* r, NSString* e) {
    if (e) { completion(nil, e); return; }
    if (r[@"exceptionDetails"]) { completion(nil, [@"JavaScript exception: " stringByAppendingString:JSON(r[@"exceptionDetails"])]); return; }
    completion(r, nil);
  });
}
static NSString* ScriptBridge(NSArray* names, NSString* world);
static void WithWorld(std::string id, NSString* world, std::function<void(Tab&, int)> action, Completion failure) {
  auto i = tabs.find(id);
  if (i == tabs.end()) { failure(nil, @"Tab closed"); return; }
  // New-document scripts already made their named worlds. Use that same
  // main-frame context when a native consumer calls into the script later.
  for (const auto& [key, context] : i->second.scripts.contexts) {
    if (!context.session.length && [context.frame isEqual:i->second.scripts.mainFrame] && [context.world isEqual:world]) {
      action(i->second, context.id); return;
    }
  }
  auto existing = i->second.worlds.find(Key(world));
  if (existing != i->second.worlds.end()) { action(i->second, existing->second); return; }
  CDP(i->second, @"Page.getFrameTree", @{}, [id, world, action, failure](NSDictionary* result, NSString* error) {
    if (error) { failure(nil, error); return; }
    auto t = tabs.find(id); if (t == tabs.end()) { failure(nil, @"Tab closed"); return; }
    NSString* frame = result[@"frameTree"][@"frame"][@"id"];
    if (!frame) { failure(nil, @"Main frame not available"); return; }
    // No universal cross-origin access is granted to an isolated world.
    CDP(t->second, @"Page.createIsolatedWorld", @{@"frameId": frame, @"worldName": world},
      [id, world, action, failure](NSDictionary* r, NSString* e) {
        auto j = tabs.find(id);
        if (e || j == tabs.end()) { failure(nil, e ?: @"Tab closed"); return; }
        int context = [r[@"executionContextId"] intValue];
        if (!context) { failure(nil, @"No isolated context"); return; }
        j->second.worlds[Key(world)] = context; j->second.contextNames[context] = Key(world);
        // A world created after load missed its new-document relay script.
        // Live features (dark pages enabled on an already-open light site)
        // need the same authenticated binding before their first request.
        NSArray* names = j->second.scripts.relays[world];
        if (!names.count) { action(j->second, context); return; }
        NSString* bridge = [NSString stringWithFormat:@"if(!globalThis.__yabScriptReply){%@}", ScriptBridge(names, world)];
        Eval(j->second, bridge, context, [id, context, action, failure](NSDictionary*, NSString* error) {
          auto current = tabs.find(id);
          if (error || current == tabs.end()) { failure(nil, error ?: @"Tab closed"); return; }
          action(current->second, context);
        });
      });
  });
}
#include "cursor.inc"
#include "drag.inc"
#include "external_scheme.inc"
#include "agent_files.inc"
#include "scripts.inc"
#include "shield.inc"
#include "page_tools.inc"
#include "agents.inc"
#include "drm.inc"
#include "drm_cookies.inc"
#include "clear_data.inc"
static bool OpensApplication(NSString* url) {
  NSString* scheme = [url componentsSeparatedByString:@":"].firstObject.lowercaseString;
  static NSSet* pages = [NSSet setWithArray:@[@"http", @"https", @"about", @"data", @"blob", @"file", @"filesystem",
    @"chrome", @"chrome-extension", @"chrome-untrusted", @"chrome-error", @"chrome-search", @"devtools", @"view-source", @"javascript"]];
  return scheme.length && ![pages containsObject:scheme];
}
#include "ext_bridge.inc"
#include "core_readiness.inc"
#include "ext_actions.inc"
#include "ext_commands.inc"

static NSWindow* Native(CefRefPtr<CefWindow> w) {
  NSView* v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(w->GetWindowHandle());
  return [(id)v isKindOfClass:NSWindow.class] ? (NSWindow*)(id)v : v.window;
}
#include "input_view.h"
#include "wheel_event.h"
// This private walk is confined to YabCore, never exposed in the client.
static void Layers(CALayer* layer, NSView* owner, NSMutableArray* rows, int depth) {
  if (!layer || depth > 60) return;
  if ([NSStringFromClass(layer.class) isEqual:@"CALayerHost"]) {
    NSNumber* context = [layer valueForKey:@"contextId"];
    if (context.unsignedIntValue) [rows addObject:@{@"contextId": context, @"view": NSStringFromClass(owner.class)}];
  }
  for (CALayer* sub in layer.sublayers) {
    if ([sub.delegate isKindOfClass:NSView.class] && (id)sub.delegate != (id)owner) continue;
    Layers(sub, owner, rows, depth + 1);
  }
}
static void ViewLayers(NSView* view, NSMutableArray* rows, int depth) {
  if (!view || depth > 60) return;
  Layers(view.layer, view, rows, 0);
  for (NSView* child in view.subviews) ViewLayers(child, rows, depth + 1);
}
static uint32_t Context(NSWindow* w) {
  NSMutableArray* rows = [NSMutableArray new];
  ViewLayers(w.contentView.superview ?: w.contentView, rows, 0);
  for (NSDictionary* row in rows) if ([row[@"view"] isEqual:@"BridgedContentView"]) return [row[@"contextId"] unsignedIntValue];
  for (NSDictionary* row in rows) if ([row[@"view"] isEqual:@"RenderWidgetHostViewCocoa"]) return [row[@"contextId"] unsignedIntValue];
  return 0;
}
// The window is never seen or pressed: its page is given the app's own events
// by sendEvent:. An NSWindow hands a mouse-moved event to its views only when
// it accepts them, so a page behind it would hear no pointer move at all.
static void Conceal(NSWindow* w) { if (w) { w.alphaValue = 0; w.ignoresMouseEvents = YES; w.acceptsMouseMovedEvents = YES; } }
// Chrome shows its floating document window twice over: the system's document
// animation as it is ordered in, then PictureInPictureWidgetFadeAnimator setting
// its alpha for half a second, which overwrites anything set from here. Seen from
// outside, a raw window faded in over the page. So the next window Chrome orders
// in while one is expected is hidden first and held at no alpha for good. Only
// that one, and never a window of ours: external hosting keeps those off screen.
static double documentPiPExpected = 0;
static NSHashTable* documentPiPWindows = nil;
static IMP orderWindowOriginal = nullptr, setAlphaOriginal = nullptr;
static void HoldDocumentPiPWindow(NSWindow* window) {
  window.animationBehavior = NSWindowAnimationBehaviorNone;
  [documentPiPWindows addObject:window];
  Conceal(window);
}
static void OrderWindowHidden(NSWindow* self, SEL command, NSWindowOrderingMode place, NSInteger other) {
  if (place != NSWindowOut && Now() < documentPiPExpected && ![self isKindOfClass:NSClassFromString(@"CefNSWindow")]) {
    documentPiPExpected = 0;
    HoldDocumentPiPWindow(self);
  }
  ((void (*)(NSWindow*, SEL, NSWindowOrderingMode, NSInteger))orderWindowOriginal)(self, command, place, other);
}
static void SetAlphaHeld(NSWindow* self, SEL command, CGFloat alpha) {
  ((void (*)(NSWindow*, SEL, CGFloat))setAlphaOriginal)(self, command, [documentPiPWindows containsObject:self] ? 0 : alpha);
}
static void ExpectDocumentPiP() {
  documentPiPExpected = Now() + 2;
  if (orderWindowOriginal) return;
  documentPiPWindows = [NSHashTable weakObjectsHashTable];
  Method order = class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:));
  orderWindowOriginal = method_setImplementation(order, (IMP)OrderWindowHidden);
  Method alpha = class_getInstanceMethod(NSWindow.class, @selector(setAlphaValue:));
  setAlphaOriginal = method_setImplementation(alpha, (IMP)SetAlphaHeld);
}
// Physical WindowServer state is independent of CEF's logical visibility.
static NSNumber* WindowOnScreen(NSWindow* window) {
  if (!window) return nil;
  NSArray* rows = CFBridgingRelease(CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID));
  if (!rows) return nil;
  for (NSDictionary* row in rows) {
    if ([row[(__bridge NSString*)kCGWindowNumber] integerValue] == window.windowNumber &&
        [row[(__bridge NSString*)kCGWindowOwnerPID] intValue] == NSProcessInfo.processInfo.processIdentifier)
      return @YES;
  }
  return @NO;
}
static void State(Tab* t, NSDictionary* fields) { if (t && !t->internal) Event(@"page.state", t, fields); }

// A muted tab stays muted. Chrome's SoundContentSettingObserver, on every new
// main document (PrimaryPageChanged: a reload, a link, the first page of a tab
// woken from sleep), lets a tab's mute back in unless Chrome's own tab code set
// it with a reason (LastMuteMetadata: the speaker's kAudioIndicator, an
// extension's kExtension). CefBrowserHost::SetAudioMuted records none, so the
// page played aloud again while IsAudioMuted had answered true to media.mute
// (feedback #2018: a muted pinned Slack pinging after its reload). Run after
// that observer, at the document's commit, and whenever the page turns audible.
static void KeepMuted(Tab* t, CefRefPtr<CefBrowser> b) {
  if (!t || !b || !t->mutedWanted || b->GetHost()->IsAudioMuted()) return;
  b->GetHost()->SetAudioMuted(true);
}
static void InstallTheme(std::string id) {
  auto tab = tabs.find(id);
  if (tab == tabs.end() || tab->second.closing || tab->second.crashed ||
      !tab->second.browser || !tab->second.transportReady || !tab->second.browser->HasDocument()) return;
  tab->second.themeAttempt = Now();
  Completion fail = [](NSDictionary*, NSString* e) { if (e) fprintf(stderr, "YabCore theme world: %s\n", e.UTF8String); };
  WithWorld(id, @"__yab_state", [](Tab& tab, int context) {
    tab.bindings["__yabTheme"].insert("__yab_state");
    CDP(tab, @"Runtime.addBinding", @{@"name": @"__yabTheme", @"executionContextName": @"__yab_state"},
      [id = tab.id, context](NSDictionary*, NSString* e) {
        auto i = tabs.find(id); if (e || i == tabs.end()) return;
        Eval(i->second, @"(()=>{const get=()=>document.querySelector('meta[name=\"theme-color\"]')?.content??null;if(!globalThis.__themeObserver){let previous=get();const f=()=>{const color=get();if(color!==previous){previous=color;__yabTheme(JSON.stringify({color}))}};globalThis.__themeObserver=new MutationObserver(f);__themeObserver.observe(document.documentElement,{subtree:true,attributes:true,childList:true})}return {color:get()}})()", context,
          [id](NSDictionary* result, NSString* error) {
            auto t = tabs.find(id); if (t == tabs.end()) return;
            if (error) { fprintf(stderr, "YabCore theme snapshot: %s\n", error.UTF8String); return; }
            NSDictionary* value = result[@"result"][@"value"];
            if (![value isKindOfClass:NSDictionary.class]) return;
            t->second.themeReady = true;
            State(&t->second, @{@"themeColor": value[@"color"] ?: NSNull.null});
          });
      });
  }, fail);
}
static void CancelPending(int browser, NSString* reason) {
  std::vector<Completion> callbacks;
  for (auto i = pending.begin(); i != pending.end();) {
    if (i->second.browser == browser) { callbacks.push_back(i->second.completion); i = pending.erase(i); }
    else ++i;
  }
  // Also called from DevTools observer callbacks; see OnDevToolsMethodResult.
  for (auto& c : callbacks) {
    // Blocks capture a C++ reference variable by reference, not its referent.
    // The vector dies on return, so give each queued block its own callable.
    Completion completion = std::move(c);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, reason); });
  }
}
static bool PushDoorEvent(Tab& tab, NSString* method, NSDictionary* params);
static bool DevToolsMessage(CefRefPtr<CefBrowser> browser, NSDictionary* message);
static void DevToolsClosed(const std::string& tab);
class Observer : public CefDevToolsMessageObserver {
 public:
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* bytes, size_t size) override {
    NSDictionary* message = Decode(bytes, size);
    if (DevToolsMessage(browser, message)) return true;
    NSString* session = S(message, @"sessionId");
    if (!session.length) return false;
    auto tab = Find(browser); if (!tab) return true;
    if (message[@"id"]) {
      auto found = pending.find([message[@"id"] intValue]);
      Completion completion;
      if (found != pending.end() && found->second.browser == browser->GetIdentifier()) {
        completion = found->second.completion; pending.erase(found);
      }
      NSDictionary* result = message[@"result"];
      NSArray<NSString*>* objects = ScriptResultObjects(result, !completion);
      NSString* error = message[@"error"] ? JSON(message[@"error"]) : nil;
      std::string owner = tab->id;
      // A timed-out call can still finish in a live frame. Its response has
      // no pending callback, but the handles it just created still need release.
      if (completion || objects.count) dispatch_async(dispatch_get_main_queue(), ^{
        ReleaseScriptObjects(owner, session, objects);
        if (completion) completion(result, error);
      });
    } else {
      ScriptEvent(*tab, S(message, @"method"), message[@"params"] ?: @{}, session);
      AgentFilesEvent(*tab, S(message, @"method"), message[@"params"] ?: @{}, session);
    }
    return true;
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int id, bool success, const void* bytes, size_t size) override {
    if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore CDP result id=%d success=%d bytes=%zu\n", id, success, size);
    auto p = pending.find(id);
    Completion completion;
    if (p != pending.end()) { completion = p->second.completion; pending.erase(p); }
    NSDictionary* value = Decode(bytes, size);
    NSArray<NSString*>* objects = ScriptResultObjects(success ? value : nil, !completion);
    if (!completion && !objects.count) return;
    auto tab = Find(browser);
    std::string owner = tab ? tab->id : "";
    // Completions often send the next CDP command. Sending it from inside
    // CEF's observer notification nests a second notification whenever the
    // agent answers synchronously, which trips Chromium's observer-list
    // reentrancy check (seen in extension options pages and at shutdown).
    // The main queue keeps results in arrival order.
    dispatch_async(dispatch_get_main_queue(), ^{
      ReleaseScriptObjects(owner, @"", objects);
      if (completion) completion(success ? value : nil, success ? nil : JSON(value));
    });
  }
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method, const void* bytes, size_t size) override {
    Tab* t = Find(browser); if (!t) return;
    NSString* m = Str(method); NSDictionary* p = Decode(bytes, size);
    ScriptEvent(*t, m, p, @"");
    AgentFilesEvent(*t, m, p, @"");
    if ([m isEqual:@"Page.domContentEventFired"]) ExtensionOptionsDocument(*t);
    if (PushDoorEvent(*t, m, p)) return;
    if ([m isEqual:@"Input.dragIntercepted"]) { DragIntercepted(*t, p); return; }
    if (ExtensionBridgeEvent(*t, m, p)) return;
    if ([m isEqual:@"Runtime.executionContextsCleared"] || [m isEqual:@"Page.frameNavigated"]) {
      if ([m isEqual:@"Page.frameNavigated"] && p[@"frame"][@"parentId"]) return;
      ++t->documentGeneration;
      // A document back from the back/forward cache keeps its contexts:
      // Runtime announced them when the agent reattached, just before this.
      if (![S(p, @"type") isEqual:@"BackForwardCacheRestore"]) {
        t->worlds.clear(); t->contextNames.clear(); t->drmFrames.clear();
      }
      if ([m isEqual:@"Page.frameNavigated"]) t->drmMainFrame = Key(S(p[@"frame"], @"id"));
    } else if ([m isEqual:@"Runtime.executionContextCreated"]) {
      NSDictionary* c = p[@"context"]; NSString* name = S(c, @"name");
      if (name.length) t->contextNames[[c[@"id"] intValue]] = Key(name);
      if ([c[@"auxData"][@"isDefault"] boolValue]) t->drmFrames[[c[@"id"] intValue]] = Key(S(c[@"auxData"], @"frameId"));
    } else if ([m isEqual:@"Runtime.executionContextDestroyed"]) {
      int context = [p[@"executionContextId"] intValue]; t->contextNames.erase(context); t->drmFrames.erase(context);
      for (auto i = t->worlds.begin(); i != t->worlds.end();) { if (i->second == context) i = t->worlds.erase(i); else ++i; }
    } else if ([m isEqual:@"Runtime.bindingCalled"]) {
      NSString* name = S(p, @"name"); int context = [p[@"executionContextId"] intValue];
      if ([name isEqual:@"__yabWidevineRejected"]) {
        auto frame = t->drmFrames.find(context);
        if (frame == t->drmFrames.end() || t->drmMainFrame.empty() || frame->second != t->drmMainFrame) return;
        NSDictionary* value = Decode(S(p, @"payload").UTF8String, [S(p, @"payload") lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        if ([S(value, @"keySystem") isEqual:@"com.widevine.alpha"])
          Event(@"drm.unavailable", t, @{@"keySystem": @"com.widevine.alpha", @"url": Str(browser->GetMainFrame()->GetURL())});
        return;
      }
      auto w = t->contextNames.find(context);
      if (w == t->contextNames.end()) return;
      auto binding = t->bindings.find(Key(name));
      if (binding == t->bindings.end() || !binding->second.count(w->second)) return;
      NSData* data = [S(p, @"payload") dataUsingEncoding:NSUTF8StringEncoding];
      id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] ?: NSNull.null;
      if ([name isEqual:@"__yabTheme"]) { if ([value isKindOfClass:NSDictionary.class]) State(t, @{@"themeColor": value[@"color"] ?: NSNull.null}); }
      else Event(@"script.message", t, @{@"world": @(w->second.c_str()), @"name": name, @"value": value});
    }
  }
  void OnDevToolsAgentAttached(CefRefPtr<CefBrowser> browser) override {
    auto tab = Find(browser); if (!tab || tab->closing) return;
    std::string id = tab->id;
    fprintf(stderr, "YabCore DevTools agent attached: %s\n", id.c_str());
    Mark("agent-attached", id);
    // Never dispatch recursively while CEF is attaching its DevTools agent.
    // Cached profiles can create the browser synchronously inside a Views callback.
    dispatch_async(dispatch_get_main_queue(), ^{
      auto found = tabs.find(id); if (found == tabs.end() || found->second.closing) return;
      Tab& t = found->second;
      ScriptAttach(t, @"", [id](NSDictionary*, NSString* error) {
        auto current = tabs.find(id); if (current == tabs.end() || current->second.closing) return;
        current->second.domainsReady = !error;
        Mark("domains-ready", id);
        if (!error) ShieldSettle(id);
        if (!error && !current->second.internal) DragAttach(current->second);
        if (error) { Event(@"script.error", &current->second, @{@"message": error}); return; }
        // The first document may have committed before this agent existed,
        // so no Page.frameNavigated was seen: learn the main frame now.
        CDP(current->second, @"Page.getFrameTree", @{}, [id](NSDictionary* tree, NSString* treeError) {
          auto found = tabs.find(id);
          if (treeError || found == tabs.end() || found->second.closing || !found->second.drmMainFrame.empty()) return;
          NSString* frameID = S(tree[@"frameTree"][@"frame"], @"id");
          if (frameID.length) found->second.drmMainFrame = Key(frameID);
        });
        if (!current->second.drmReady && !current->second.internal) InstallDRM(current->second, Ignore, true);
      });
      for (auto& [name, worlds] : t.bindings) for (const auto& world : worlds) {
        CDP(t, @"Runtime.addBinding", @{@"name": @(name.c_str()), @"executionContextName": @(world.c_str())}, Ignore);
      }
    });
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override {
    OriginalPDFPresenceClosed(browser->GetIdentifier());
    OriginalPDFBrowserClosed(browser->GetIdentifier(), @"Original PDF renderer detached");
    fprintf(stderr, "YabCore DevTools agent detached: browser %d\n", browser->GetIdentifier());
    if (auto t = Find(browser)) { ++t->documentGeneration; t->drmReady = false; t->drmFrames.clear(); t->domainsReady = false; ShieldAgentGone(*t); t->worlds.clear(); t->contextNames.clear(); t->scripts.contexts.clear(); t->scripts.sessions.clear(); t->scripts.attaching.clear(); t->scripts.sessionParents.clear(); t->scripts.identifiers.clear(); t->scripts.consoleRelease.clear(); }
    CancelPending(browser->GetIdentifier(), @"Renderer detached");
  }
  IMPLEMENT_REFCOUNTING(Observer);
};
static NSDictionary* NativeHookCapabilities();
static NSDictionary* CreatedState(Tab& t) {
  NSString* url = t.browser ? Str(t.browser->GetMainFrame()->GetURL()) : @"";
  auto profile = profiles.find(t.profile);
  NSMutableDictionary* result = [@{@"profile": @(t.profile.c_str()), @"private": @(profile != profiles.end() && profile->second.privateMode),
    @"opener": t.opener.empty() ? (id)NSNull.null : @(t.opener.c_str()), @"foreground": @(t.foreground),
    @"mustAdopt": @YES, @"source": t.popupSource ?: (id)NSNull.null,
    @"url": url.length ? url : (t.creationURL ?: @"about:blank")} mutableCopy];
  if (t.extensionCreation) result[@"extensionCreation"] = t.extensionCreation;
  result[@"creationPurpose"] = t.extensionCreation ? @"extension" : t.popupSource ? @"popup" : t.fromNotice ? @"notification" : t.adopted ? @"client" : @"unrequested";
  return result;
}
#include "tab_creation.inc"
static void BindPopupWindow(Tab& tab, CefRefPtr<CefBrowser> browser);
// The tab's own window arrives some tasks after OnAfterCreated. Should it ever be
// ordered in unseen by ExpectDocumentPiP, this still holds it within moments.
static void ConcealDocumentPiP(std::string id, int turns) {
  auto found = tabs.find(id);
  if (found == tabs.end() || found->second.closing || !found->second.browser) return;
  auto& tab = found->second;
  if (!tab.native) {
    NSView* native = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(tab.browser->GetHost()->GetWindowHandle());
    tab.native = [(NSObject*)native isKindOfClass:NSWindow.class] ? (NSWindow*)(NSObject*)native : native.window;
  }
  if (tab.native) { HoldDocumentPiPWindow(tab.native); return; }
  if (turns <= 0) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    ConcealDocumentPiP(id, turns - 1);
  });
}
static void Attach(CefRefPtr<CefBrowser> b, std::string profile, std::string preferred,
                   std::string opener = "", NSString* creationURL = nil, bool foreground = true, NSDictionary* source = nil) {
  if (browserTabs.count(b->GetIdentifier())) return;
  // Always derive ownership from the actual native request context. A popup
  // may inherit a Client from its opener while Chrome chooses another context.
  profile.clear();
  for (auto& [key, p] : profiles) if (b->GetHost()->GetRequestContext()->IsSame(p.context)) { profile = key; break; }
  auto t = tabs.find(preferred);
  bool spawned = t == tabs.end() || t->second.browser;
  if (getenv("YAB_CEF_TRACE_CDP")) {
    fprintf(stderr, "YabCore creation: %s\n", JSON(@{@"at": @(Now()), @"browser": @(b->GetIdentifier()),
      @"preferred": @(preferred.c_str()), @"spawned": @(spawned), @"profile": @(profile.c_str()),
      @"nativeOpener": @(b->GetHost()->GetOpenerIdentifier()), @"opener": @(opener.c_str()),
      @"creationURL": creationURL ?: (id)NSNull.null,
      @"source": source ?: (id)NSNull.null}).UTF8String);
    if (spawned) fprintf(stderr, "YabCore creation stack: %s\n", NSThread.callStackSymbols.description.UTF8String);
  }
  if (spawned) {
    preferred = "tab-" + std::to_string(++tabSequence);
    Tab value; value.id = preferred; value.profile = profile; value.adopted = false;
    auto nativeOpener = browserTabs.find(b->GetHost()->GetOpenerIdentifier());
    value.opener = nativeOpener != browserTabs.end() ? nativeOpener->second : opener;
    value.creationURL = creationURL; value.foreground = foreground;
    value.popupSource = source;
    value.documentPiP = [source[@"documentPiP"] boolValue];
    value.fitPage = true;
    t = tabs.emplace(preferred, std::move(value)).first;
  }
  t->second.browser = b;
  browserTabs[b->GetIdentifier()] = preferred;
  if (stopping || profile.empty()) { t->second.closing = true; b->GetHost()->CloseBrowser(true); return; }
  BindPopupWindow(t->second, b);
#if YABCORE_NATIVE_PAGE
  // The SDK already bound its exact native Browser before OnAfterCreated.
  // Refuse an unbound default client before tab.created, not a geometry fallback.
  // Chrome's window for a floating document exists only after this returns,
  // so it can't be bound yet: PollLayers finds it and shows its compositor.
  if (spawned && !CefBrowserView::GetForBrowser(b) && !AttachNativePage(t->second) && !t->second.documentPiP) {
    t->second.closing = true;
    b->GetHost()->CloseBrowser(true);
    return;
  }
#endif
  t->second.observer = b->GetHost()->AddDevToolsMessageObserver(new Observer);
  dispatch_async(dispatch_get_main_queue(), ^{
    auto current = tabs.find(preferred); if (current == tabs.end() || current->second.closing) return;
    current->second.transportReady = true;
    Mark("tab.created", preferred);
    // The native endpoint can accept LoadURL now. Page.enable can wait for
    // the first real renderer document; waiting for it here would prevent
    // that very first navigation on CEF's empty, unnavigated bootstrap.
    NSString* request = current->second.createRequest;
    current->second.createRequest = nil;
    if (request) Reply(request, @{@"tab": @(preferred.c_str())});
    CDP(current->second, @"Page.enable", @{}, Ignore);
  });
  ApplyEarlyExtensionReceipt(t->second, b->GetIdentifier());
  if (spawned) FinishNativeCreation(preferred);
  if (t->second.documentPiP) ConcealDocumentPiP(preferred, 400);
#if YABCORE_NATIVE_PAGE
  if (t->second.externalPage) PublishOwnCEFSurface(t->second);
#endif
}
#include "navigation.inc"
#include "print_find.inc"
#include "permissions.inc"
#include "site_notices.inc"
#include "questions.inc"
#include "agent_dialogs.inc"
#include "certificates.inc"
#include "owncef_native.inc"
#include "extension_tab_operations.inc"
#include "native_text_input.inc"
#include "original_pdf.inc"
#include "original_pdf_presence.inc"
#include "owncef_files.inc"
#include "downloads.inc"
#include "history.inc"
#include "media.inc"
#include "health.inc"
#include "context_menu.inc"
#include "lifecycle.inc"
#include "native_switch_group.inc"
#include "html_load.inc"

#include "request_read.inc"

class Client : public CefClient, public CefLifeSpanHandler, public CefLoadHandler, public CefDisplayHandler, public CefRequestHandler, public CefDialogHandler, public CefJSDialogHandler, public CefFindHandler, public CefPermissionHandler, public CefDownloadHandler, public CefContextMenuHandler, public CefKeyboardHandler, public CefCommandHandler {
  std::string profile_, tab_, opener_;
  NSString* creationURL_;
  bool foreground_;
  NSDictionary* popupSource_;
 public:
  Client(std::string profile, std::string tab, std::string opener = "", NSString* url = nil, bool foreground = true, NSDictionary* source = nil)
    : profile_(profile), tab_(tab), opener_(opener), creationURL_(url), foreground_(foreground), popupSource_(source) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  bool OnChromeCommand(CefRefPtr<CefBrowser> b, int command,
                       cef_window_open_disposition_t) override {
    auto action = DevToolsCommand(command, cef_id_for_command_id_name);
    if (!action) return false;
    // Chrome accelerators can bypass OnKeyEvent (notably F12). Never let
    // them construct an unrequested native DevTools BrowserView. Our
    // popup delegate closes its unreserved Window without adding the view;
    // CreateBrowser then dereferences that view's missing widget.
    auto t = Find(b);
    if (t && !t->internal && !t->closing && !t->devToolsFrontend)
      Event(@"page.devToolsCommand", t, @{@"action": @(action)});
    return true;
  }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>,
      bool is_navigation, bool, const CefString&, bool&) override {
    if (auto policy = ReadPolicyForBrowser(b)) return new ReadResourceGuard(std::move(policy));
    if (auto html = HTMLRequestHandler(b, is_navigation)) return html;
    return ShieldHandler();
  }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  bool OnJSDialog(CefRefPtr<CefBrowser> b, const CefString& origin, JSDialogType type,
      const CefString& message, const CefString& text, CefRefPtr<CefJSDialogCallback> callback,
      bool& suppress) override {
    if (IsReadBrowser(b)) { suppress = true; return false; }
    return OpenNativeDialog(Find(b), Str(origin), type == JSDIALOGTYPE_ALERT ? @"alert" :
      type == JSDIALOGTYPE_CONFIRM ? @"confirm" : @"prompt", Str(message), Str(text), callback, suppress);
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> b, const CefString& message, bool,
      CefRefPtr<CefJSDialogCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Continue(false, CefString()); return true; }
    bool suppress = false;
    return OpenNativeDialog(Find(b), Str(b->GetMainFrame()->GetURL()), @"beforeunload",
      Str(message), @"", callback, suppress);
  }
  void OnResetDialogState(CefRefPtr<CefBrowser> b) override {
    if (auto tab = Find(b)) CancelNativeDialogs(tab->id);
  }
  bool OnSelectClientCertificate(CefRefPtr<CefBrowser> browser, bool proxy, const CefString& host, int port,
      const X509CertificateList& certificates, CefRefPtr<CefSelectClientCertificateCallback> callback) override {
    return AskClientCertificate(Find(browser), proxy, Str(host), port, certificates, callback);
  }
  bool CanDownload(CefRefPtr<CefBrowser> b, const CefString&, const CefString&) override {
    return !IsReadBrowser(b);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (source == PID_RENDERER && HealthMessage(Find(b), frame, message)) return true;
    if (source == PID_RENDERER && MediaFrameMessage(Find(b), frame, message)) return true;
    if (source != PID_RENDERER || !frame || !frame->IsValid() || !frame->IsMain() || message->GetName() != "yab.media.renderer") return false;
    auto t = Find(b); if (!t) return true;
    auto args = message->GetArgumentList();
    if (args->GetSize() != 1 || args->GetType(0) != VTYPE_INT) return true;
    pid_t pid = args->GetInt(0);
    struct proc_bsdinfo info = {};
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_ppid != getpid()) return true;
    // Isolated worlds create contexts too. Their repeated PID report must
    // not cancel an input challenge for the very same renderer.
    const bool swapped = t->rendererPID != pid;
    if (swapped) HealthReset(t, true);
    t->rendererPID = pid;
    t->rendererBorn = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
#if YABCORE_OWNCEF_SURFACES
    // A new renderer behind the same compositor: say who owns the surface.
    if (swapped) PublishOwnCEFSurface(*t);
#endif
    State(t, @{ @"rendererPID": @(pid), @"nativeDiscard": NativeHookCapabilities()[@"nativeDiscard"],
      @"audible": @(t->audible), @"audibleSource": YABCORE_NATIVE_AUDIBLE ? @"native" : @"page" });
    return true;
  }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
#if defined(CEF_YAB_DOWNLOAD_NAMING_VERSION)
  bool UseChromeDownloadNaming() override { return true; }
#endif
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  bool RunContextMenu(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Cancel(); return true; }
    return OpenPageMenu(Find(b), frame, params, model, callback);
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser> b, CefRefPtr<CefDownloadItem> item,
      const CefString& name, CefRefPtr<CefBeforeDownloadCallback> callback) override {
    if (IsReadBrowser(b)) return true; // Never fall back to Chrome download UI.
    return BeginDownload(Find(b), item, Str(name), callback);
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser> b, CefRefPtr<CefDownloadItem> item,
      CefRefPtr<CefDownloadItemCallback> callback) override { UpdateDownload(b, item, callback); }
  bool OnCertificateError(CefRefPtr<CefBrowser> b, cef_errorcode_t code, const CefString& url,
      CefRefPtr<CefSSLInfo> info, CefRefPtr<CefCallback> callback) override {
    if (IsReadBrowser(b)) return false;
    return AskCertificate(Find(b), code, Str(url), info, callback);
  }
  bool GetAuthCredentials(CefRefPtr<CefBrowser> b, const CefString& origin, bool proxy,
                          const CefString& host, int port, const CefString& realm,
                          const CefString& scheme, CefRefPtr<CefAuthCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Cancel(); return true; }
    AskAuthentication(b, Str(origin), proxy, Str(host), port, Str(realm), Str(scheme), callback);
    return true;
  }
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame,
      const CefString& origin, uint32_t mask, CefRefPtr<CefMediaAccessCallback> callback) override {
    if (IsReadBrowser(b)) { if (callback) callback->Cancel(); return true; }
    auto* tab = Find(b);
    auto frameBrowser = frame && frame->IsValid() ? frame->GetBrowser() : nullptr;
    const bool sameBrowserFrame = tab && tab->browser && tab->browser->IsSame(b) &&
        frameBrowser && frameBrowser->IsSame(b);
    return AskMedia(tab, Str(origin), mask, callback, sameBrowserFrame);
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> b, uint64_t prompt, const CefString& origin,
      uint32_t mask, CefRefPtr<CefPermissionPromptCallback> callback) override {
    return AskPermission(Find(b), prompt, Str(origin), mask, callback);
  }
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> b, uint64_t prompt, cef_permission_request_result_t) override {
    DismissPermission(Find(b), prompt);
  }
  void OnFindResult(CefRefPtr<CefBrowser> b, int identifier, int count,
                    const CefRect&, int ordinal, bool final) override {
    NativeFindResult(Find(b), identifier, count, ordinal, final);
  }
#if YABCORE_NATIVE_FILE_SOURCE
  bool OnFileDialogForFrame(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefDictionaryValue> source, const CefString&, const CefString&,
      CefRefPtr<CefFileDialogCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Cancel(); return true; }
    return NativeFileDialog(Find(b), b, frame, source, callback);
  }
  void OnFileDialogClosed(CefRefPtr<CefBrowser> b, const CefString& request,
      const CefString&) override { NativeFileClosed(Find(b), request); }
#endif
  bool OnFileDialog(CefRefPtr<CefBrowser> b, FileDialogMode mode,
                    const CefString&, const CefString& defaultPath,
                    const std::vector<CefString>&, const std::vector<CefString>&,
                    const std::vector<CefString>&,
                    CefRefPtr<CefFileDialogCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Cancel(); return true; }
    auto t = Find(b);
    if (!t || !t->extensionPath || ![Str(b->GetMainFrame()->GetURL()) isEqual:@"chrome://extensions/"]) return OpenFilePick(t, mode, callback, nil, Str(defaultPath));
    NSString* path = t->extensionPath;
    t->extensionPath = nil;
    callback->Continue({CefString(Key(path))});
    return true;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int,
      const CefString& target, const CefString&, WindowOpenDisposition disposition, bool gesture,
      const CefPopupFeatures& features, CefWindowInfo&, CefRefPtr<CefClient>& client,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    auto owner = Find(browser);
    // No count of tabs refuses a window: Chrome has none, and every Chromium
    // tab Yab put to sleep keeps its native tab, discarded, as Chromium keeps a
    // discarded tab's WebContents. A fixed 256 here and in tab.create failed
    // every new page past 256 such tabs (feedback #1984, 270 tabs).
    if (IsReadBrowser(browser) || stopping || !owner || owner->closing) return true;
    // The disposition comes from Chromium's actual child WebContents, not
    // the target URL or a page binding. Preserve that live browser for PiP.
    NSDictionary* source = @{@"url": frame ? Str(frame->GetURL()) : @"", @"main": @(frame && frame->IsMain()), @"gesture": @(gesture),
      @"documentPiP": @(disposition == CEF_WOD_NEW_PICTURE_IN_PICTURE),
      @"popup": @(disposition == CEF_WOD_NEW_POPUP || features.widthSet || features.heightSet),
      @"width": @(features.widthSet ? features.width : 480), @"height": @(features.heightSet ? features.height : 320)};
    client = new Client(owner->profile, "", owner->id, Str(target), disposition != CEF_WOD_NEW_BACKGROUND_TAB, source);
    if (disposition == CEF_WOD_NEW_PICTURE_IN_PICTURE) ExpectDocumentPiP();
    return false;
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    PollHurry();
    // Chrome can reuse a Browser's Client when restoring/adding WebContents.
    // The original tab.create or OnBeforePopup request authorizes one browser.
    auto tab = tab_; tab_.clear();
    auto opener = opener_; opener_.clear();
    NSString* url = creationURL_; creationURL_ = nil;
    NSDictionary* source = popupSource_; popupSource_ = nil;
    if (!opener.empty()) ShieldPopup(b->GetIdentifier(), true);
    Attach(b, profile_, tab, opener, url, foreground_, source);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
#if YABCORE_CLOSE_PREFLIGHT
    NativeCloseScope closeScope;
#endif
    OriginalPDFPresenceClosed(b->GetIdentifier());
    OriginalPDFBrowserClosed(b->GetIdentifier(), @"Original PDF browser closed");
    NativeTextInputClosed(b);
    ReadPageClosed(b);
    if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore closing: browser=%d at=%.6f\n", b->GetIdentifier(), Now());
    CancelPending(b->GetIdentifier(), @"Tab closed");
    auto t = Find(b); if (t) {
#if YABCORE_EXTENSION_HOOKS
      NativeExtensionOwnerClosed(t);
#endif
#if YABCORE_CLOSE_PREFLIGHT
      LifecycleBeforeClose(*t);
#endif
      DevToolsClosed(t->id);
      // Whole-host shutdown is engine loss; keep tab rows for disconnect recovery.
      if (!stopping) Event(@"tab.closed", t);
      std::string id = t->id;
      CancelFilePick(id); CancelQuestions(id); CancelPageMenu(id);
      for (auto i = authAttempts.begin(); i != authAttempts.end();) {
        if (i->first.rfind(id + "|", 0) == 0) i = authAttempts.erase(i); else ++i;
      }
      CancelPrintFind(*t, @"Tab closed"); nativeFinds.erase(id); MediaForget(id);
      t->observer = nullptr; t->browser = nullptr; t->window = nullptr; t->view = nullptr;
      tabs.erase(id); ForgetReadPage(id);
    }
    browserTabs.erase(b->GetIdentifier());
    earlyExtensionReceipts.erase(b->GetIdentifier());
    if (stopping && tabs.empty()) QuitOnce();
  }
  void OnAddressChange(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (frame->IsMain()) {
      if (auto t = Find(b)) t->themeReady = false;
      State(Find(b), @{@"url": Str(url)});
    }
  }
  void OnMediaAccessChange(CefRefPtr<CefBrowser> b, bool video, bool audio) override { MediaAccess(Find(b), video, audio); }
  bool OnCursorChange(CefRefPtr<CefBrowser> b, CefCursorHandle cursor, cef_cursor_type_t type, const CefCursorInfo& custom) override {
    auto t = Find(b); if (!t || t->internal) return false;
    CursorChanged(t, cursor, type, custom);
    return true;
  }
  // After the page had its chance. Nothing here is Chrome's to act on: its
  // shortcuts would work on a window nobody sees. The client's menu goes next.
  bool OnKeyEvent(CefRefPtr<CefBrowser> b, const CefKeyEvent& event, CefEventHandle) override {
    auto t = Find(b); if (!t || t->internal) return false;
    if (!(event.modifiers & EVENTFLAG_COMMAND_DOWN)) return false;
    if (event.type == KEYEVENT_RAWKEYDOWN) Event(@"page.keyUnhandled", t, @{@"keyCode": @(event.native_key_code)});
    return true;
  }
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> b, bool fullscreen) override { MediaFullscreen(Find(b), fullscreen); }
#if YABCORE_NATIVE_VIDEO_PIP
  void OnNativeVideoPiPState(CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDictionaryValue> state) override {
    NativePiPChanged(Find(browser), browser, state);
  }
#endif
#if YABCORE_NATIVE_CAPTURE_ACTIVITY
  void OnNativeCaptureState(CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDictionaryValue> state) override {
    NativeCaptureChanged(Find(browser), browser, state);
  }
#endif
#if YABCORE_NATIVE_MEDIA_SESSION
  void OnNativeMediaSessionState(CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDictionaryValue> state) override {
    NativeMediaChanged(Find(browser), browser, state);
  }
#endif
#if YABCORE_NATIVE_AUDIBLE
  void OnAudioStateChanged(CefRefPtr<CefBrowser> b, bool audible) override { if (audible) KeepMuted(Find(b), b); NativeAudible(Find(b), audible); MediaNativeAudible(Find(b), audible); }
#endif
#if YABCORE_BACKGROUND_COLOR
  void OnBackgroundColorChange(CefRefPtr<CefBrowser> b, cef_color_t color, bool has) override { NativeBackground(Find(b), color, has); }
#endif
#if YABCORE_SELECT_MENU
  bool OnExternalSelectMenu(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> menu) override { return NativeSelectOpen(Find(b), menu); }
  void OnExternalSelectMenuDismissed(CefRefPtr<CefBrowser> b, int token) override { NativeSelectClosed(Find(b), token); }
#endif
#if YABCORE_NATIVE_PRINT
  void OnPrintRequest(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> request) override { NativePrintRequest(Find(b), request); }
  void OnPrintRequestWithdrawn(CefRefPtr<CefBrowser> b, const CefString& request) override { NativePrintWithdrawn(Find(b), request.ToString()); }
#endif
#if YABCORE_DISCARD_NOTIFY
  void OnPageDiscardedChange(CefRefPtr<CefBrowser> b, bool discarded) override { NativeDiscarded(Find(b), discarded); }
#endif
#if YABCORE_EXTENSION_HOOKS
  void OnExtensionPopup(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> popup) override { NativeExtensionPopup(Find(b), popup); }
  void OnExtensionTabCreated(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> info) override {
    if (b && info && !Find(b) && earlyExtensionReceipts.size() < 64) {
      fprintf(stderr, "YabCore extension receipt before its browser: browser=%d\n", b->GetIdentifier());
      earlyExtensionReceipts[b->GetIdentifier()] = info;
      return;
    }
    NativeExtensionTab(Find(b), info);
  }
#if YABCORE_NATIVE_PAGE
  void OnExternalPageFrame(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> state) override { NativePageFrame(Find(b), state); }
#endif
#endif
#if YABCORE_TEXT_INPUT
  void OnExternalTextInputState(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> state) override { NativeTextState(Find(b), state); }
#endif
#if YABCORE_CLOSE_PREFLIGHT
  void OnClosePreflightState(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> state) override { NativeClosePreflight(Find(b), state); }
#endif
  void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString& title) override {
    if (auto t = Find(b)) { t->title = Str(title); State(t, @{@"title": t->title}); }
  }
  // The link under the pointer, as Chromium's status bubble says it. The app
  // admits it only after the pointer's own moves (ChromiumPage+Hover).
  void OnStatusMessage(CefRefPtr<CefBrowser> b, const CefString& value) override {
    auto t = Find(b); if (!t || t->internal) return;
    Event(@"page.hover", t, @{@"url": Str(value) ?: @""});
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> b, const std::vector<CefString>& urls) override { State(Find(b), @{@"faviconURL": urls.empty() ? (id)NSNull.null : Str(urls[0])}); }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> b, bool loading, bool back, bool forward) override {
    State(Find(b), @{@"loading": @(loading), @"canGoBack": @(back), @"canGoForward": @(forward)});
    if (!loading) if (auto t = Find(b)) InstallTheme(t->id);
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool gesture, bool redirect) override {
    if (ExternalScheme(b, frame, request, gesture)) return true;
#if YABCORE_CLOSE_PREFLIGHT
    // A recovery approval belongs to the captured document tree. Native
    // preflight may already have timed out while another tab's prompt is up;
    // any frame navigation still retires our recovery token.
    if (auto t = Find(b)) if (t->closeUnresponsive && !t->closing) CancelClosePreflight(*t);
#endif
    // Every hop, redirects and frames too: a sign-in leaves its cookies on
    // hosts no document stays on, and CEF has no cookie change observer.
    if (request) if (auto t = Find(b)) if (!t->internal) Event(@"cookies.touched", t, @{@"url": Str(request->GetURL()), @"main": @(frame && frame->IsMain())});
    // A link to an app is Browser's question, as on WebKit. Chrome would ask in
    // a window nobody sees, and the link would seem to do nothing.
    if (request && frame && frame->IsMain() && OpensApplication(Str(request->GetURL()))) {
      if (auto t = Find(b)) if (!t->internal) Event(@"page.externalLink", t, @{@"url": Str(request->GetURL()), @"gesture": @(gesture)});
      return true;
    }
    if(frame&&frame->IsMain())OriginalPDFPresenceSuspend(b->GetIdentifier());
    OriginalPDFBrowserClosed(b->GetIdentifier(), @"Original PDF native navigation started");
    if (request && frame && frame->IsMain()) {
      if (auto t = Find(b)) { t->browseGesture = gesture; t->browseRedirect = redirect; }
      // Loading state includes child frames. Only a main-frame navigation
      // retires the app's document metadata and script frame ownership;
      // an iframe can start after the main document has already finished
      // and will never send a matching main-document commit.
      if (!redirect) Event(@"page.started", Find(b));
      ShieldBegan(b, Find(b), request->GetURL().ToString());
    }
    return false;
  }
  // A link followed another way than here: ⌘- and middle-clicks. Where it
  // opens is Yab's to say; Chrome's new tab would land in a window nobody sees.
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame>, const CefString& url,
      CefRequestHandler::WindowOpenDisposition disposition, bool gesture) override {
    auto t = Find(b);
    if (!t || t->internal || disposition == CEF_WOD_CURRENT_TAB) return false;
    Event(@"page.openLink", t, @{@"url": Str(url), @"foreground": @(disposition != CEF_WOD_NEW_BACKGROUND_TAB), @"gesture": @(gesture)});
    return true;
  }
  void OnLoadStart(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, TransitionType) override {
    if(frame->IsMain())OriginalPDFPresenceSuspend(b->GetIdentifier());
    OriginalPDFBrowserClosed(b->GetIdentifier(), @"Original PDF native document changed");
    if (frame->IsMain()) ShieldPopup(b->GetIdentifier(), false);
    if (frame->IsMain()) if (auto t = Find(b)) {
      ++t->documentGeneration;
      CancelPrintFind(*t, @"Document changed");
      CancelQuestions(t->id); CancelPageMenu(t->id);
      for (auto i = authAttempts.begin(); i != authAttempts.end();) {
        if (i->first.rfind(t->id + "|", 0) == 0) i = authAttempts.erase(i); else ++i;
      }
      KeepMuted(t, b);
      Event(@"page.committed", t, @{@"url": Str(frame->GetURL())});
      AccessibilityDocument(*t);
      MediaReset(t);
      t->themeReady = false; t->crashed = false;
#if YABCORE_OWNCEF_SURFACES
      // A renderer restart can reuse the window compositor's unchanged
      // CAContext. Rebind the client's cleared host without polling or
      // pretending that load start acknowledges frame presentation.
      PublishOwnCEFSurface(*t);
#endif
      State(t, @{@"themeColor": NSNull.null, @"faviconURL": NSNull.null});
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, int) override {
    if (frame->IsMain()) if (auto t = Find(b)) {
      OriginalPDFPresenceDocumentEnded(b);
      ExtensionOptionsDocument(*t);
      InstallTheme(t->id); Event(@"page.finished", t);
      // The blank document that brought up the agent is no Back entry.
      if (t->scripts.blankFirst && frame->GetURL() != "about:blank" && t->domainsReady) {
        t->scripts.blankFirst = false;
        std::string id = t->id;
        CDP(*t, @"Page.resetNavigationHistory", @{}, [id](NSDictionary*, NSString*) {
          auto found = tabs.find(id);
          if (found == tabs.end() || !found->second.browser) return;
          auto browser = found->second.browser;
          State(&found->second, @{@"canGoBack": @(browser->CanGoBack()), @"canGoForward": @(browser->CanGoForward())});
        });
      }
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString& text, const CefString& url) override {
    if (frame->IsMain() && code != ERR_ABORTED && ExtensionOAuthRedirect(Str(url))) {
      // Let Chrome's tabs observer finish the OAuth handoff. Reporting this
      // as a website failure races the extension with Yab's error/retry UI.
      Event(@"page.oauthRedirect", Find(b), @{@"url": Str(url)});
      return;
    }
    if (frame->IsMain() && code == ERR_ABORTED && ShieldStoppedTop(b)) {
      Event(@"page.loadError", Find(b), @{@"code": @(ERR_BLOCKED_BY_CLIENT), @"message": @"This page is on the ad blocker's lists", @"url": Str(url)});
      return;
    }
    if (frame->IsMain()) Event(@"page.loadError", Find(b), @{@"code": @(code), @"message": Str(text), @"url": Str(url)});
  }
  bool OnRenderProcessUnresponsive(CefRefPtr<CefBrowser> b,
                                  CefRefPtr<CefUnresponsiveProcessCallback>) override {
    auto t = Find(b);
    if (!t || t->internal) return false;
    HealthSignal(t, false);
    // Yab owns the existing Wait/Reload card. A hidden Chrome dialog cannot
    // answer for the hosted page; leave its renderer running while waiting.
    return true;
  }
  void OnRenderProcessResponsive(CefRefPtr<CefBrowser> b) override {
    auto t = Find(b);
    // Input ACKs and compositor responses do not answer our independent
    // main-thread challenge. Only its matching native pong can do that.
    if (t && t->healthToken.empty()) HealthSignal(t, true);
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> b, TerminationStatus status, int code, const CefString& text) override {
    OriginalPDFPresenceClosed(b->GetIdentifier());
    OriginalPDFBrowserClosed(b->GetIdentifier(), @"Original PDF renderer lost");
    if (auto t = Find(b)) { CancelPrintFind(*t, @"Renderer crashed"); CancelQuestions(t->id); CancelPageMenu(t->id); HealthReset(t, false); MediaReset(t, true); }
    // The CAContext belongs to the native window compositor, not this
    // renderer. Only its native reset callback invalidates the cached handle.
    // page.crash clears the client host; main-frame load rebinds that handle.
    if (auto t = Find(b)) { ++t->documentGeneration; t->rendererPID = 0; t->rendererBorn = 0; t->crashed = true; t->shedding = false; t->themeReady = false; t->worlds.clear(); t->contextNames.clear(); t->lastLayer = nil; if (!t->closing) Event(@"page.crash", t, @{@"status": @(status), @"code": @(code), @"message": Str(text)}); }
    CancelPending(b->GetIdentifier(), @"Renderer crashed");
  }
  IMPLEMENT_REFCOUNTING(Client);
};
// The frontend tab reserved for each inspected browser, during ShowDevTools.
static std::map<int, std::string> devToolsAsked;
class Window : public CefWindowDelegate {
  std::string id_;
  CefRefPtr<CefBrowserView> view_;
  CefRefPtr<CefWindow> window_;
  bool popup_ = false, hosted_ = false;
 public:
  Window(std::string id, CefRefPtr<CefBrowserView> view) : id_(id), view_(view) {}
  // Chromium hands over a page a site opened before it says the browser
  // exists, so the window comes first and its tab joins it in OnAfterCreated.
  explicit Window(CefRefPtr<CefBrowserView> popup) : view_(popup), popup_(true) {}
  void Bind(Tab& tab) {
    id_ = tab.id; popup_ = false;
    tab.window = window_; tab.view = view_; tab.fitPage = false;
    tab.externallyHosted = hosted_;
    tab.native = Native(window_);
    MediaProducerWindow(tab.native);
    if (hosted_) {
      tab.native.ignoresMouseEvents = YES;
      if (tab.visible) window_->Show();
    } else {
      Conceal(tab.native); window_->Show(); Conceal(tab.native);
      if (!tab.visible) [tab.native orderOut:nil];
    }
  }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
#if YABCORE_OWNCEF_SURFACES
  void OnAcceleratedFrame(CefRefPtr<CefWindow>, uint32_t context,
                           const CefSize& pixels, float scale) override {
    OwnCEFFrame(id_, context, pixels, scale);
  }
#endif
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override {
    auto t = tabs.find(id_); return CefRect(80, 120, t == tabs.end() ? 800 : t->second.width, t == tabs.end() ? 600 : t->second.height);
  }
  void OnWindowCreated(CefRefPtr<CefWindow> w) override {
    window_ = w;
    if (popup_) {
#if YABCORE_EXTERNAL_HOST
      hosted_ = w->EnableExternalHosting();
#endif
      w->AddChildView(view_);
      return;
    }
    auto t = tabs.find(id_); if (t == tabs.end()) { w->Close(); return; }
    t->second.window = w; t->second.view = view_;
#if YABCORE_EXTERNAL_HOST
    t->second.externallyHosted = w->EnableExternalHosting();
    if (!t->second.externallyHosted) {
      Event(@"page.loadError", &t->second,
            @{@"message": @"CEF external hosting was refused", @"code": @-1});
      NSString* request = t->second.createRequest;
      tabs.erase(t);
      Reply(request, nil, @"CEF external hosting was refused");
      w->Close();
      return;
    }
#endif
    // Bind the WebContents visibility observer before its first Show().
    w->AddChildView(view_); t->second.native = Native(w);
    MediaProducerWindow(t->second.native);
    if (t->second.externallyHosted) {
      t->second.native.ignoresMouseEvents = YES;
      if (t->second.visible) w->Show();
    } else {
      Conceal(t->second.native); w->Show(); Conceal(t->second.native);
      if (!t->second.visible) [t->second.native orderOut:nil];
    }
  }
  bool CanClose(CefRefPtr<CefWindow>) override { auto b = view_ ? view_->GetBrowser() : nullptr; return !b || b->GetHost()->TryCloseBrowser(); }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { view_ = nullptr; window_ = nullptr; }
  IMPLEMENT_REFCOUNTING(Window);
};
static std::map<int, CefRefPtr<Window>> popupWindows;
static void BindPopupWindow(Tab& tab, CefRefPtr<CefBrowser> browser) {
  auto found = popupWindows.find(browser->GetIdentifier());
  if (found == popupWindows.end()) return;
  auto window = found->second;
  popupWindows.erase(found);
  window->Bind(tab);
}
class View : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  bool UseFramelessWindowForPictureInPicture(CefRefPtr<CefBrowserView>) override { return true; }
  void OnBrowserCreated(CefRefPtr<CefBrowserView> view, CefRefPtr<CefBrowser> b) override { if (auto t = Find(b)) t->view = view; }
  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> owner, CefRefPtr<CefBrowserView> popup, bool devTools) override {
    if (devTools) {
      // Arrives before the frontend's OnAfterCreated. An id no request reserved
      // (Chrome's own F12 route) has no tab: its window closes as it is made.
      auto opener = owner ? owner->GetBrowser() : nullptr;
      auto asked = opener ? devToolsAsked.find(opener->GetIdentifier()) : devToolsAsked.end();
      CefWindow::CreateTopLevelWindow(new Window(asked == devToolsAsked.end() ? "" : asked->second, popup));
      return true;
    }
    auto b = popup->GetBrowser(); if (auto t = Find(b)) { CefWindow::CreateTopLevelWindow(new Window(t->id, popup)); return true; }
    if (!b) return false;
    // A window of Yab's, as every page has: CEF's own default one reports no
    // compositor, and the page would draw for nobody.
    CefRefPtr<Window> window = new Window(popup);
    popupWindows[b->GetIdentifier()] = window;
    CefWindow::CreateTopLevelWindow(window);
    return true;
  }
  IMPLEMENT_REFCOUNTING(View);
};
static std::string Create(std::string profile, NSString* url, NSString* request, bool internal = false) {
  std::string id = "tab-" + std::to_string(++tabSequence);
  Tab t; t.id = id; t.profile = profile; t.createRequest = request; t.internal = internal;
  t.scriptBootstrapAllowed = !url.length;
  tabs.emplace(id, std::move(t));
  CefBrowserSettings settings; settings.background_color = 0xffffffff;
  if (NativeExtensionWindows() && !internal) {
    tabs.at(id).nativeExtensions = true;
    CefWindowInfo info; info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    info.bounds = CefRect(80, 120, 800, 600);
    auto browser = CefBrowserHost::CreateBrowserSync(info, new Client(profile, id), Key(url), settings, nullptr, profiles.at(profile).context);
    if (!browser) { tabs.erase(id); Reply(request, nil, @"Could not create the native extension host"); return ""; }
    tabs.at(id).native = ExtensionBrowserWindow(browser);
    Conceal(tabs.at(id).native);
    return id;
  }
  auto view = CefBrowserView::CreateBrowserView(new Client(profile, id), Key(url), settings, nullptr, profiles.at(profile).context, new View);
  if (!view) { tabs.erase(id); Reply(request, nil, @"Could not create BrowserView"); return ""; }
  tabs.at(id).view = view;
  CefWindow::CreateTopLevelWindow(new Window(id, view));
  return id;
}
#include "devtools.inc"
static size_t openWidgets = 0;
#include "site_push.inc"
// A window with no compositor callback: its context is read from its layers.
[[maybe_unused]] static void PublishWindowSurface(Tab& tab) {
  uint32_t cid = Context(tab.native);
  NSRect page = tab.nativeExtensions || tab.fitPage ? ExtensionPageRect(tab.native) : NSZeroRect;
  NSDictionary* state = @{@"contextId": @(cid), @"width": @(tab.width), @"height": @(tab.height),
    @"pageX": @(page.origin.x), @"pageY": @(page.origin.y),
    @"scale": @(tab.native.backingScaleFactor), @"requestedScale": @(tab.scale), @"visible": @(tab.visible)};
  NSString* encoded = JSON(state);
  if (![encoded isEqual:tab.lastLayer]) { tab.lastLayer = encoded; if (!tab.internal) Event(@"layer.changed", &tab, state); }
}
static void PollLayers() {
  NSMutableSet* known = [NSMutableSet new];
  for (auto& [id, tab] : tabs) {
    HealthPoll(tab);
    if (!tab.view && tab.browser) tab.view = CefBrowserView::GetForBrowser(tab.browser);
    if (!tab.window && tab.view) tab.window = tab.view->GetWindow();
    if (!tab.native && tab.window) tab.native = Native(tab.window);
    if (!tab.native && tab.browser) {
      NSView* native = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(tab.browser->GetHost()->GetWindowHandle());
      tab.native = [(NSObject*)native isKindOfClass:NSWindow.class] ? (NSWindow*)(NSObject*)native : native.window;
    }
    if (!tab.native) continue;
    MediaProducerWindow(tab.native);
    [known addObject:@(tab.native.windowNumber)];
    if (!tab.externallyHosted) Conceal(tab.native);
    // Chrome made this window at the size the page asked for, which no popup
    // feature carries, and nothing has resized it yet.
    if (tab.documentPiP && !tab.documentPiPSized) {
      NSRect page = ExtensionPageRect(tab.native);
      if (page.size.width > 0 && page.size.height > 0) {
        tab.documentPiPSized = true;
        Event(@"documentPiP.size", &tab, @{@"width": @(page.size.width), @"height": @(page.size.height)});
      }
    }
    // A Chrome-created tab can still share its owner's native window before
    // adoption. Its default geometry must not compete with that owner.
    if (tab.adopted && !tab.externalPage && (tab.nativeExtensions || tab.fitPage) && (!tab.documentPiP || tab.documentPiPSized))
      ResizeExtensionWindow(tab.native, tab.width, tab.height);
    if (!tab.themeReady && !tab.crashed && tab.browser && !tab.browser->IsLoading() && Now() - tab.themeAttempt > 0.5) InstallTheme(id);
#if YABCORE_OWNCEF_SURFACES
    if (tab.documentPiP && !tab.externalPage)
#endif
    PublishWindowSurface(tab);
  }
  // Native Chrome widgets (including extension action popups) are independent
  // contexts. Report additions, movement, context replacement and disappearance.
  static NSMutableDictionary* previous = [NSMutableDictionary new];
  NSMutableDictionary* current = [NSMutableDictionary new];
  for (NSWindow* window in NSApp.windows) {
    if ([known containsObject:@(window.windowNumber)]) continue;
    // Chrome's original browserless download picker stays interactive.
    // NSOpenPanel is also an NSSavePanel subclass.
    if ([window isKindOfClass:NSSavePanel.class]) continue;
    // A context menu Chrome opens itself (an extension's action popup has no
    // CefBrowser to ask Yab for one): concealed, it was there and invisible,
    // and its Paste could not be reached. It tracks and closes on its own.
    if (window.level == NSPopUpMenuWindowLevel || [NSStringFromClass(window.class) containsString:@"Menu"]) continue;
    Conceal(window);
    uint32_t cid = Context(window);
    if (getenv("YAB_CEF_TRACE_CDP")) {
      static NSMutableSet* traced = [NSMutableSet new];
      NSString* key = [NSString stringWithFormat:@"%ld:%u:%ld:%d", (long)window.windowNumber, cid, (long)window.parentWindow.windowNumber, window.isVisible];
      if (![traced containsObject:key]) {
        [traced addObject:key];
        fprintf(stderr, "YabCore widget window=%ld parent=%ld context=%u visible=%d class=%s\n", (long)window.windowNumber, (long)window.parentWindow.windowNumber, cid, window.isVisible, NSStringFromClass(window.class).UTF8String);
      }
    }
    if (!cid || !window.isVisible) continue;
    Tab* owner = nullptr;
    for (auto& [id, tab] : tabs) if (window.parentWindow == tab.native) { owner = &tab; break; }
    NSRect frame = window.frame;
    if (owner) {
      NSRect content = [owner->native convertRectToScreen:owner->native.contentView.bounds];
      frame.origin = NSMakePoint(frame.origin.x - content.origin.x, NSMaxY(content) - NSMaxY(frame));
    }
    NSDictionary* row = @{@"popup": @(window.windowNumber).stringValue, @"contextId": @(cid),
      @"x": @(frame.origin.x), @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height),
      @"scale": @(window.backingScaleFactor), @"tab": owner ? (NSObject*)@(owner->id.c_str()) : NSNull.null,
      @"coordinateSpace": owner ? @"page" : @"screenBottomLeft"};
    NSString* key = @(window.windowNumber).stringValue; current[key] = row;
    if (![JSON(previous[key]) isEqual:JSON(row)]) Event(@"popup.layer", nullptr, row);
  }
  for (NSString* key in previous) if (!current[key]) Event(@"popup.closed", nullptr, @{@"popup": key});
  previous = current;
  openWidgets = current.count;
  PublishPopupTextStates();
}
// What only a look can find: a window still being made, a health ping due, a
// page that fits its window, a native widget that may be opening. Nothing of
// the kind with the tabs at rest, so the walk goes from 10 times a second to once.
static double hurriedUntil = 0, nextPoll = 0;
static const double kPollBusy = 0.1, kPollResting = 1;
static NSString* PollBusyReason() {
  if (Now() < hurriedUntil) return @"window-activity";
  if (openWidgets) return @"open-widget";
  if (NSApp.modalWindow) return @"modal-window";
  for (auto& [id, tab] : tabs) {
    if (!tab.native) return @"unbound-window";
    if (!tab.healthToken.empty()) return @"health-probe";
    if (!tab.externallyHosted) return @"unhosted-window";
    if (tab.nativeExtensions) return @"extension-window";
    if (tab.fitPage) return @"fitted-window";
    if (!tab.themeReady && !tab.crashed && tab.browser && !tab.browser->IsLoading() && tab.browser->HasDocument()) return @"theme";
  }
  return nil;
}
static bool PollBusy() { return PollBusyReason() != nil; }
// Only native window work needs discovery at the interactive cadence. A
// cookie read, status query or iframe load neither creates nor moves a window.
// Treating all of them as window activity kept the poll busy while idle.
static void PollHurry() {
  ++pollHurries;
  hurriedUntil = Now() + 2;
  if (timer && nextPoll > Now() + kPollBusy) {
    nextPoll = Now() + kPollBusy;
    timer.fireDate = [NSDate dateWithTimeIntervalSinceNow:kPollBusy];
  }
}
#include "accessibility.inc"
#include "pointer_lock.inc"
// Keep payloads outside NSEvent: AppKit can copy a posted event and discard
// Objective-C associated objects. The queue's native event stamp survives that
// copy. Older entries consumed by an AppKit modal text service are retired when
// its next event is dispatched; closing a tab destroys its remaining entries.
static void QueueKeyboard(Tab& tab, NSEvent* envelope, NSEvent* native,
                          std::function<void()> edit = {}, std::function<void()> canceled = {}) {
  envelope = KeyboardEnvelopeMark(envelope);
  auto entry = std::make_shared<QueuedKeyboardEvent>();
  entry->stamp = KeyboardEventStamp(envelope); entry->type = envelope.type; entry->code = envelope.keyCode;
  entry->native = native; entry->edit = std::move(edit); entry->canceled = std::move(canceled);
  tab.keyboard.push_back(entry);
  [NSApp postEvent:envelope atStart:NO];
}
static std::shared_ptr<QueuedKeyboardEvent> TakeKeyboard(Tab& tab, NSEvent* event) {
  const auto stamp = KeyboardEventStamp(event);
  auto found = std::find_if(tab.keyboard.begin(), tab.keyboard.end(), [&](const auto& entry) {
    return entry->stamp == stamp && entry->type == event.type && entry->code == event.keyCode;
  });
  if (found == tab.keyboard.end()) return {};
  auto entry = *found;
  tab.keyboard.erase(tab.keyboard.begin(), std::next(found));
  return entry;
}
static NSEvent* DispatchPageKeyboard(NSEvent* event) {
  Tab* target = nullptr;
#if YABCORE_EXTENSION_HOOKS
  for (auto& [token, popup] : nativePopupInputs) {
    if (popup.native == event.window) { target = &popup; break; }
  }
#endif
  if (!target) {
    for (auto& [id, tab] : tabs) {
      if (tab.native == event.window) { target = &tab; break; }
    }
  }
  // Another app typing into the field Yab has focused (Cotypist accepting a
  // completion with Tab) posts its keys to the process that owns the focused
  // element, this one. This process is never active and its windows never
  // key, so AppKit gives such a key no window and it was dropped: the
  // completion was never typed. It goes to the page Yab has focused, the one
  // whose focused element the other app was handed (accessibility.inc).
  if (!target && !event.window && event.type != NSEventTypeFlagsChanged && !KeyboardEnvelopeOwned(event)) {
    for (auto& [id, tab] : tabs) {
      if (tab.externallyHosted && tab.focused && tab.visible && !tab.closing && tab.native && tab.browser) { target = &tab; break; }
    }
    if (target && getenv("YAB_PROBE") && *getenv("YAB_PROBE"))
      fprintf(stderr, "YabCore keyboard from another app: %lu characters to %s\n", (unsigned long)event.characters.length, target->id.c_str());
  }
  if (target) {
    Tab& tab = *target;
    auto delivery = TakeKeyboard(tab, event);
    // A retired envelope (or an unrelated key in a concealed widget)
    // cannot be delivered to a replacement popup reusing its window.
    if (!delivery && (KeyboardEnvelopeOwned(event) || !tab.browser)) return nil;
    if (!delivery && !tab.keyboard.empty() && getenv("YAB_PROBE") && *getenv("YAB_PROBE"))
      fprintf(stderr, "YabCore keyboard stamp mismatch: got=%llu expected=%llu pending=%zu\n",
              (unsigned long long)KeyboardEventStamp(event), (unsigned long long)tab.keyboard.front()->stamp,
              tab.keyboard.size());
    NSWindow* window = tab.native;
    NSView* content = window.contentView;
    NSView* view = FindView(content.superview ?: content, @"RenderWidgetHostViewCocoa");
    if (!view) return delivery ? nil : event;
    if (delivery) {
      delivery->canceled = {};
      if (delivery->edit) { delivery->edit(); return nil; }
    }
    NSEvent* native = delivery && delivery->native ? delivery->native : event;
    if (getenv("YAB_PROBE") && *getenv("YAB_PROBE") && event.type == NSEventTypeKeyDown &&
        (event.characters.length > 1 || native.characters.length > 1))
      fprintf(stderr, "YabCore keyboard payload: found=%d envelopeUnits=%lu nativeUnits=%lu\n", (bool)delivery,
              (unsigned long)event.characters.length, (unsigned long)native.characters.length);
    NSResponder* target = [window.firstResponder isKindOfClass:NSView.class] &&
        [(NSView*)window.firstResponder isDescendantOf:window.contentView] ? window.firstResponder : view;
    if (event.type == NSEventTypeFlagsChanged) [target flagsChanged:native];
    else if (event.type == NSEventTypeKeyDown) [target keyDown:native];
    else [target keyUp:native];
    return nil;
  }
  return KeyboardEnvelopeOwned(event) ? nil : event;
}
// A Chrome sad tab is Views UI in the browser window, not a renderer.
// Dispatch its input through AppKit's native content view; CDP and
// RenderWidgetHostViewCocoa no longer have a live target after a crash.
static void SadTabInput(Tab& tab, NSDictionary* p, NSString* request) {
  NSWindow* window = tab.native;
  NSView* content = window.contentView;
  if (!content || !tab.view) { Reply(request, nil, @"Native crash view is unavailable"); return; }
  NSString* kind = S(p, @"kind");
  NSEventModifierFlags flags = [p[@"modifiers"] unsignedLongLongValue];
  if ([kind isEqual:@"keyDown"] || [kind isEqual:@"keyUp"] || [kind isEqual:@"flagsChanged"]) {
    const NSEventType type = [kind isEqual:@"flagsChanged"] ? NSEventTypeFlagsChanged :
        [kind isEqual:@"keyDown"] ? NSEventTypeKeyDown : NSEventTypeKeyUp;
    NSEvent* event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags
        timestamp:Now() windowNumber:window.windowNumber context:nil
        characters:S(p, @"characters") ?: @"" charactersIgnoringModifiers:S(p, @"unmodified") ?: @""
        isARepeat:[p[@"repeat"] boolValue] keyCode:[p[@"keyCode"] unsignedShortValue]];
    [window sendEvent:event];
    Reply(request); return;
  }
  NSDictionary* types = @{@"mouseDown": @(NSEventTypeLeftMouseDown), @"mouseUp": @(NSEventTypeLeftMouseUp),
    @"mouseMove": @(NSEventTypeMouseMoved), @"mouseDrag": @(NSEventTypeLeftMouseDragged)};
  NSDictionary* selectors = @{@"mouseDown": @"mouseDown:", @"mouseUp": @"mouseUp:",
    @"mouseMove": @"mouseMoved:", @"mouseDrag": @"mouseDragged:"};
  if (!types[kind]) { Reply(request, nil, @"Input kind is not supported by the native crash view"); return; }
  const double x = [p[@"x"] doubleValue], y = [p[@"y"] doubleValue];
  if (!std::isfinite(x) || !std::isfinite(y)) { Reply(request, nil, @"Invalid native crash view point"); return; }
  NSPoint local = NSMakePoint(x, content.isFlipped ? y : NSHeight(content.bounds) - y);
  NSView* target = [content hitTest:local];
  SEL selector = NSSelectorFromString(selectors[kind]);
  if (!target || ![target respondsToSelector:selector]) { Reply(request, nil, @"No native crash view at point"); return; }
  NSEvent* event = [NSEvent mouseEventWithType:(NSEventType)[types[kind] unsignedIntegerValue]
      location:[content convertPoint:local toView:nil] modifierFlags:flags timestamp:Now()
      windowNumber:window.windowNumber context:nil eventNumber:0
      clickCount:MAX(1, [p[@"clickCount"] integerValue]) pressure:[kind isEqual:@"mouseUp"] ? 0 : 1];
  ((void (*)(id, SEL, NSEvent*))objc_msgSend)(target, selector, event);
  Reply(request);
}
static void Input(Tab& tab, NSDictionary* p, NSString* request, bool nativePopup = false) {
  if (tab.closing) { Reply(request, nil, @"Page input target is no longer live"); return; }
  if (tab.crashed && !nativePopup) { SadTabInput(tab, p, request); return; }
  InstallPointerLockHooks();
  if (!nativePopup && !tab.browser) { Reply(request, nil, @"Page input browser not ready"); return; }
  NSString* kind = S(p, @"kind");
  // AppKit replacement coordinates are UTF-16 offsets in the focused editor.
  NSRange replacement = NSMakeRange(NSNotFound, 0);
  if (p[@"replacementStart"] || p[@"replacementLength"]) {
    id startValue = p[@"replacementStart"], lengthValue = p[@"replacementLength"];
    if (![startValue isKindOfClass:NSNumber.class] || ![lengthValue isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)startValue) == CFBooleanGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)lengthValue) == CFBooleanGetTypeID()) {
      Reply(request, nil, @"Invalid replacement range"); return;
    }
    double start = [startValue doubleValue], length = [lengthValue doubleValue];
    if (!std::isfinite(start) || !std::isfinite(length) || start < 0 || length < 0 ||
        std::trunc(start) != start || std::trunc(length) != length || start + length > INT32_MAX) {
      Reply(request, nil, @"Invalid replacement range"); return;
    }
    replacement = NSMakeRange((NSUInteger)start, (NSUInteger)length);
  }
  if (nativePopup && ([@[@"dragIntercept", @"dragEnter", @"dragOver", @"drop", @"dragCancel"] containsObject:kind] ||
                      [kind hasPrefix:@"middle"])) {
    Reply(request, nil, @"Native popup does not support this input kind"); return;
  }
  const std::string tabID = tab.id;
  const uint64_t generation = tab.documentGeneration;
  NSWindow* w = tab.native;
  NSView* content = w.contentView;
  NSView* view = FindView(content.superview ?: content, @"RenderWidgetHostViewCocoa");
  if (!view) { Reply(request, nil, @"Page input view not ready"); return; }
  // An authenticated native popup has its own original AppKit view.
  auto browser = tab.browser;
  auto host = browser ? browser->GetHost() : nullptr;
  NSEventModifierFlags flags = [p[@"modifiers"] unsignedLongLongValue];
  double x = [p[@"x"] doubleValue], y = [p[@"y"] doubleValue];
  NSPoint point = [view convertPoint:NSMakePoint(x, view.isFlipped ? y : view.bounds.size.height - y) toView:nil];
  if ([kind isEqual:@"dragIntercept"]) {
    if (!host) { Reply(request, nil, @"Page input browser not ready"); return; }
    CDP(tab, @"Input.setInterceptDrags", @{@"enabled": @([p[@"enabled"] boolValue])}, [request](NSDictionary* value, NSString* error) { Reply(request, value, error); });
    return;
  }
  if ([@[@"dragEnter", @"dragOver", @"drop", @"dragCancel"] containsObject:kind]) {
    if (!host) { Reply(request, nil, @"Page input browser not ready"); return; }
    int modifiers = (flags & NSEventModifierFlagOption ? 1 : 0) | (flags & NSEventModifierFlagControl ? 2 : 0) |
                    (flags & NSEventModifierFlagCommand ? 4 : 0) | (flags & NSEventModifierFlagShift ? 8 : 0);
    NSDictionary* data = p[@"data"] ?: @{@"items": @[], @"dragOperationsMask": @1};
    std::string tabID = tab.id;
    WithPageZoom(tab, request, [=](double zoom, double pinch) {
      auto live = tabs.find(tabID);
      if (live == tabs.end() || live->second.closing) { Reply(request, nil, @"Page closed during a drag"); return; }
      CDP(live->second, @"Input.dispatchDragEvent", @{@"type": kind, @"x": @(x / zoom / pinch), @"y": @(y / zoom / pinch), @"data": data, @"modifiers": @(modifiers)},
          [request](NSDictionary* value, NSString* error) { Reply(request, value, error); });
    });
    return;
  }
  if ([kind isEqual:@"editorKey"]) {
    // Human Edit shortcuts and ordinary keys must share AppKit's FIFO.
    // Dispatching this CDP key directly from the RPC can overtake backspaces
    // already posted there, pasting before deletion has finished.
    NSEvent* envelope = [NSEvent keyEventWithType:NSEventTypeKeyDown location:point
      modifierFlags:[p[@"macModifiers"] unsignedLongLongValue] timestamp:Now()
      windowNumber:w.windowNumber context:nil characters:S(p, @"key") charactersIgnoringModifiers:S(p, @"key")
      isARepeat:NO keyCode:[p[@"nativeCode"] unsignedShortValue]];
    NSMutableDictionary* key = [p mutableCopy]; key[@"kind"] = @"key";
    QueueKeyboard(tab, envelope, nil, [tabID, generation, key, request] {
      auto found = tabs.find(tabID);
      if (found == tabs.end() || found->second.closing || found->second.documentGeneration != generation) {
        Reply(request, nil, @"Editor input target changed"); return;
      }
      NSString* nativeEdit = S(key, @"nativeEdit");
      if (nativeEdit.length) {
        // Human editing in an extension window uses the same native view
        // selectors as its action popup, after preceding keyboard events.
        Input(found->second, @{@"kind": @"edit", @"command": nativeEdit}, request);
      } else {
        ScriptRequest(found->second, @"scripts.input", key, request);
      }
    }, [request] { Reply(request, nil, @"Editor input was consumed before dispatch"); });
    return;
  } else if ([kind isEqual:@"edit"]) {
    // An Edit command for an extension's action popup. In Chrome the Edit
    // menu sends paste: (and the rest) to this view; Blink on a Mac reads
    // ⌘V as a plain key, and this process has no Edit menu, so a forwarded
    // key pastes nothing. The client names the command; the view runs it on
    // its focused frame, as Chromium's menu does.
    static NSSet* const commands = [NSSet setWithArray:@[@"paste", @"pasteAndMatchStyle", @"copy", @"cut",
                                                          @"selectAll", @"undo", @"redo"]];
    NSString* command = S(p, @"command");
    SEL action = command && [commands containsObject:command] ? NSSelectorFromString([command stringByAppendingString:@":"]) : nullptr;
    if (!action) { Reply(request, nil, @"Unknown native edit command"); return; }
    if (![view respondsToSelector:action]) { Reply(request, nil, @"Popup view has no such edit command"); return; }
    if (w.firstResponder != view) [w makeFirstResponder:view];
    if (getenv("YAB_PROBE") && *getenv("YAB_PROBE"))
      fprintf(stderr, "yabcore popup edit %s: first responder %s\n", command.UTF8String, NSStringFromClass([w.firstResponder class]).UTF8String);
    ((void (*)(id, SEL, id))objc_msgSend)(view, action, nil);
  } else if ([kind isEqual:@"textSelection"]) {
    // NSTextCheckingClient selects in the original native editor. Its
    // accessibility selection uses the same editor-relative UTF-16 offsets;
    // no DOM lookup or synthetic arrow-key sequence substitutes for it.
    id focused = [view accessibilityFocusedUIElement];
    if (replacement.location == NSNotFound || !focused ||
        ![focused respondsToSelector:@selector(setAccessibilitySelectedTextRange:)]) {
      Reply(request, nil, @"Native editor has no selectable text range"); return;
    }
    [(id<NSAccessibility>)focused setAccessibilitySelectedTextRange:replacement];
  } else if ([kind isEqual:@"text"]) {
    if (![view respondsToSelector:@selector(insertText:replacementRange:)]) { Reply(request, nil, @"View has no text input client"); return; }
    [(id<NSTextInputClient>)view insertText:S(p, @"text") replacementRange:replacement];
  } else if ([kind isEqual:@"compose"] || [kind isEqual:@"unmark"]) {
    // The client's own input method composes; the page's view only shows it.
    // Committing goes through kind "text" (insertText ends the composition).
    if (![view respondsToSelector:@selector(setMarkedText:selectedRange:replacementRange:)]) { Reply(request, nil, @"View has no text input client"); return; }
    if ([kind isEqual:@"unmark"]) [(id<NSTextInputClient>)view unmarkText];
    else {
      NSString* text = S(p, @"text") ?: @"";
      NSUInteger location = MIN((NSUInteger)[p[@"selectionStart"] unsignedIntegerValue], text.length);
      NSUInteger length = MIN((NSUInteger)[p[@"selectionLength"] unsignedIntegerValue], text.length - location);
      [(id<NSTextInputClient>)view setMarkedText:text selectedRange:NSMakeRange(location, length) replacementRange:replacement];
    }
  } else if ([kind isEqual:@"keyDown"] || [kind isEqual:@"keyUp"] || [kind isEqual:@"flagsChanged"]) {
    bool lone = [kind isEqual:@"flagsChanged"];  // A modifier alone: BaseView's flagsChanged: makes its keydown or keyup.
    NSEventType type = lone ? NSEventTypeFlagsChanged : [kind isEqual:@"keyDown"] ? NSEventTypeKeyDown : NSEventTypeKeyUp;
    NSEvent* native = p[@"event"] ? KeyboardEventDecode(p, type) : nil;
    if (p[@"event"] && !native) { Reply(request, nil, @"Invalid native keyboard event"); return; }
    // AppKit's queue needs a window number from this process. Posting the
    // decoded event itself carries Yab's foreign window and may never reach
    // the local monitor. The envelope routes it; its payload is interpreted.
    NSEvent* event = [NSEvent keyEventWithType:type
      location:point modifierFlags:flags timestamp:Now() windowNumber:w.windowNumber context:nil
      characters:lone ? @"" : S(p, @"characters") charactersIgnoringModifiers:lone ? @"" : S(p, @"unmodified") isARepeat:[p[@"repeat"] boolValue] keyCode:[p[@"keyCode"] unsignedShortValue]];
    // Native correction panels consume subsequent events from AppKit's queue.
    // Calling keyDown directly strands that nested event loop and keeps the
    // input RPC unacknowledged, preventing the next key from reaching it.
    QueueKeyboard(tab, event, native ?: event);

  } else if ([kind isEqual:@"wheel"]) {
    // The scroll's own CGEvent, whole: Chrome's WebMouseWheelEventBuilder
    // and cc decide distance and glide, as in Chromium (wheel_event.h). Only
    // where it is changes, below, for the window here.
    CGEventRef cg = WheelEventCreate(p, Now());
    if (!cg) { Reply(request, nil, @"Cannot create wheel event"); return; }
    NSEvent* event = WheelEventPlace(cg, w, point);
    [view scrollWheel:event]; CFRelease(cg);
  } else if ([kind isEqual:@"magnify"] || [kind isEqual:@"smartMagnify"]) {
    // The view, not CDP or a scale set from here: Chromium's own wheel and
    // gesture filters then ask the page and the compositor scales the visual
    // viewport about the fingers, with no layout and no renderer round trip.
    bool pinch = [kind isEqual:@"magnify"];
    tab.pinched = true;
    YabGestureEvent* event = [YabGestureEvent new];
    event.type = pinch ? NSEventTypeMagnify : NSEventTypeSmartMagnify;
    event.phase = static_cast<NSEventPhase>([p[@"phase"] unsignedLongLongValue]);
    event.magnification = [p[@"magnification"] doubleValue];
    event.locationInWindow = point;
    event.timestamp = p[@"timestamp"] ? [p[@"timestamp"] doubleValue] : Now();
    event.modifierFlags = flags;
    if (pinch) [view magnifyWithEvent:(NSEvent*)event];
    else [view smartMagnifyWithEvent:(NSEvent*)event];
  } else if ([kind isEqual:@"mouseLeave"]) {
    // The host's tracking rectangles can remain inside the page while native
    // UI covers it. Explicitly retire Chromium's hover, including :hover and
    // renderer tooltips, rather than merely suppressing the next move.
    if (tab.externallyHosted) {
      NSEvent* event = [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:point
        modifierFlags:flags timestamp:Now() windowNumber:w.windowNumber context:nil
        eventNumber:0 trackingNumber:0 userData:nullptr];
      [view mouseExited:event];
    } else {
      CefMouseEvent event;
      event.x = static_cast<int>(x); event.y = static_cast<int>(y);
      if (!host) { Reply(request, nil, @"Page input browser not ready"); return; }
      host->SendMouseMoveEvent(event, true);
    }
  } else if (!nativePopup && tab.pointerLocked && IsPointerLockKind(kind)) {
    // The page holds the pointer: the event goes to its view, whole, and
    // Chrome's own code makes its movement (pointer_lock.inc).
    NSEvent* event = PointerLockEvent(p, kind, w, point, flags);
    if (!event) { Reply(request, nil, @"Cannot make the locked pointer's event"); return; }
    tab.pointerPoint = point;
    PointerLockDeliver(view, event);
  } else {
    NSDictionary* types = @{@"mouseDown": @"mousePressed", @"mouseUp": @"mouseReleased", @"mouseMove": @"mouseMoved", @"mouseDrag": @"mouseMoved", @"rightDown": @"mousePressed", @"rightUp": @"mouseReleased",
      @"rightDrag": @"mouseMoved", @"middleDown": @"mousePressed", @"middleUp": @"mouseReleased", @"middleDrag": @"mouseMoved"};
    if (!types[kind]) { Reply(request, nil, @"Unknown input kind"); return; }
    if (nativePopup) {
      NSDictionary* nativeTypes = @{@"mouseDown": @(NSEventTypeLeftMouseDown), @"mouseUp": @(NSEventTypeLeftMouseUp),
        @"mouseMove": @(NSEventTypeMouseMoved), @"mouseDrag": @(NSEventTypeLeftMouseDragged),
        @"rightDown": @(NSEventTypeRightMouseDown), @"rightUp": @(NSEventTypeRightMouseUp),
        @"rightDrag": @(NSEventTypeRightMouseDragged)};
      NSDictionary* selectors = @{@"mouseDown": @"mouseDown:", @"mouseUp": @"mouseUp:", @"mouseMove": @"mouseMoved:",
        @"mouseDrag": @"mouseDragged:", @"rightDown": @"rightMouseDown:", @"rightUp": @"rightMouseUp:",
        @"rightDrag": @"rightMouseDragged:"};
      SEL action = NSSelectorFromString(selectors[kind]);
      if (!nativeTypes[kind] || ![view respondsToSelector:action]) {
        Reply(request, nil, @"Popup view cannot take this mouse event"); return;
      }
      NSEvent* event = [NSEvent mouseEventWithType:(NSEventType)[nativeTypes[kind] unsignedIntegerValue]
        location:point modifierFlags:flags timestamp:Now() windowNumber:w.windowNumber context:nil eventNumber:0
        clickCount:p[@"clickCount"] ? [p[@"clickCount"] integerValue] : 1 pressure:[kind hasSuffix:@"Down"] ? 1 : 0];
      if ([kind hasSuffix:@"Down"] && w.firstResponder != view) [w makeFirstResponder:view];
      // The client already hit-tested the visible popup. Its concealed
      // producer is never key, so Cocoa would otherwise discard hover moves.
      if ([kind isEqual:@"mouseMove"]) PointerLockDeliver(view, event);
      else ((void (*)(id, SEL, NSEvent*))objc_msgSend)(view, action, event);
      Reply(request); return;
    }
    if (!host) { Reply(request, nil, @"Page input browser not ready"); return; }
    tab.pointerPoint = point; tab.pointerPointKnown = true;
    bool middle = [kind hasPrefix:@"middle"];
    if (getenv("YAB_CEF_TRACE_INPUT")) {
      static int traced = 0;
      if (traced++ < 12) {
        NSView* hit = [w.contentView hitTest:[w.contentView.superview convertPoint:point fromView:nil]];
        fprintf(stderr, "YabCore input %s at %s window %ld visible=%d key=%d alpha=%.1f ignores=%d accepts=%d hit=%s rwhv=%s frame=%s\n", kind.UTF8String,
          NSStringFromPoint(point).UTF8String, (long)w.windowNumber, w.isVisible, w.isKeyWindow, w.alphaValue, w.ignoresMouseEvents, w.acceptsMouseMovedEvents,
          hit ? NSStringFromClass(hit.class).UTF8String : "nil", NSStringFromClass(view.class).UTF8String, NSStringFromRect(view.frame).UTF8String);
      }
    }
    // Cocoa's hidden producer view can discard even directly delivered mouse
    // events. The real page's trusted input route does not depend on that
    // window being key or underneath the system pointer. This includes
    // externally hosted pages: after a back/forward-cache restore their
    // hidden Cocoa view can stop delivering clicks while the document still
    // answers JavaScript. Target the current page through the same trusted
    // route as scripts.input; retain the person's modifiers and click count.
    int modifiers = (flags & NSEventModifierFlagOption ? 1 : 0) | (flags & NSEventModifierFlagControl ? 2 : 0) |
                    (flags & NSEventModifierFlagCommand ? 4 : 0) | (flags & NSEventModifierFlagShift ? 8 : 0);
    bool right = [kind hasPrefix:@"right"], moved = [kind isEqual:@"mouseMove"], dragged = [kind hasSuffix:@"Drag"];
    bool pressed = [types[kind] isEqual:@"mousePressed"];
    int clicks = moved || dragged ? 0 : std::max(1, [p[@"clickCount"] intValue]);
    // CDP acknowledges after the page's handler. Arm before dispatch so a
    // handler stuck on the renderer's main thread cannot postpone its probe.
    HealthInput(tab);
    // Native AppKit coordinates are visual-viewport points. CDP scales its
    // CSS points by both page zoom and pinch, as it does for drag input.
    auto send = [=](double zoom, double pinch) {
      auto live = tabs.find(tabID);
      if (live == tabs.end() || live->second.closing || live->second.crashed ||
          live->second.browser != browser || live->second.documentGeneration != generation) {
        Reply(request, nil, @"Page changed during pointer input"); return;
      }
      CDP(live->second, @"Input.dispatchMouseEvent", @{@"type": types[kind], @"x": @(x / zoom / pinch), @"y": @(y / zoom / pinch),
        @"button": moved ? @"none" : right ? @"right" : middle ? @"middle" : @"left",
        @"buttons": @(pressed || dragged ? (right ? 2 : middle ? 4 : 1) : 0),
        @"clickCount": @(clicks), @"modifiers": @(modifiers)},
        [request](NSDictionary* value, NSString* error) { Reply(request, value, error); });
    };
    WithPageZoom(tab, request, send);
    return;
  }
  // AppKit delivery can synchronously close, replace or navigate the page.
  // Never touch the borrowed Tab after it; even a reused id is a new target.
  auto live = tabs.find(tabID);
  if ((!tabID.empty() && (live == tabs.end() || live->second.closing || live->second.crashed ||
       live->second.browser != browser || live->second.documentGeneration != generation)) ||
      w.contentView != content || view.isHiddenOrHasHiddenAncestor ||
      (view != content && ![view isDescendantOf:content])) {
    Reply(request, nil, @"Page input target is no longer live"); return;
  }
  if (!tabID.empty()) HealthInput(live->second);
  Reply(request);
}
#include "page_snapshot.inc"
static NSString* Validate(NSDictionary* p) {
  for (NSString* key in @[@"profile", @"tab", @"url", @"world", @"name", @"path", @"extension", @"kind", @"text", @"characters", @"unmodified", @"request", @"download", @"user", @"password"])
    if (p[key] && (![p[key] isKindOfClass:NSString.class] || [p[key] length] > 262144)) return @"Invalid string parameter";
  // Dark Reader is 346 KB before its evaluation wrapper. Script code has a
  // separate bounded allowance; ordinary input strings keep their old limit.
  for (NSString* key in @[@"function", @"expression"])
    if (p[key] && (![p[key] isKindOfClass:NSString.class] || [p[key] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 * 1024)) return @"Invalid script source";
  for (NSString* key in @[@"width", @"height", @"scale", @"x", @"y", @"deltaX", @"deltaY", @"modifiers", @"keyCode", @"phase", @"momentumPhase", @"clickCount"])
    if (p[key] && (![p[key] isKindOfClass:NSNumber.class] || !std::isfinite([p[key] doubleValue]) || fabs([p[key] doubleValue]) > 1e15)) return @"Invalid numeric parameter";
  for (NSString* key in @[@"private", @"visible", @"enabled", @"accept", @"repeat", @"userGesture", @"muted", @"forward", @"allow"])
    if (p[key] && ![p[key] isKindOfClass:NSNumber.class]) return @"Invalid boolean parameter";
  return nil;
}
static NSDictionary* ProfileReply(const Profile& profile, NSString* name) {
  return @{@"profile": name, @"private": @(profile.privateMode),
           @"parent": profile.parent.empty() ? (id)NSNull.null : @(profile.parent.c_str())};
}
static void ProfileOpened(const std::string& key) {
  auto found = profiles.find(key);
  if (found == profiles.end()) return;
  found->second.ready = true;
  Mark("profile.ready");
  NSString* name = @(key.c_str());
  NSDictionary* opened = ProfileReply(found->second, name);
  for (NSString* waiting : found->second.waiting) Reply(waiting, opened);
  found->second.waiting.clear();
}
class ProfileHandler : public CefRequestContextHandler {
  std::string key_;
 public:
  explicit ProfileHandler(std::string key) : key_(std::move(key)) {}
  // What no tab's client sees: a service worker's and a shared worker's own loads.
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>,
      bool, bool, const CefString&, bool&) override {
    return b ? nullptr : ShieldHandler();
  }
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext>) override {
    // Leave CEF's callback first: the caller's next request may create a tab.
    std::string key = key_;
    dispatch_async(dispatch_get_main_queue(), ^{ ProfileOpened(key); });
  }
  IMPLEMENT_REFCOUNTING(ProfileHandler);
};
// Settings › Tabs › Energy Saver is Chrome's own: Local State's
// performance_tuning.battery_saver_mode.state, which performance_manager's
// BatterySaverModeManager watches. While it holds (below 20% on battery,
// unplugged, or 3 for always) every frame sink is limited to 30 Hz, so
// scrolling, video and animations run at 30, wake-ups are aligned and
// background pages freeze. Chromium registers 1 (below 20%); Yab says 0
// unless the person picks another, and Chromium keeps what it was told.
static void EnergySaverRequest(NSDictionary* p, NSString* request) {
  NSNumber* wanted = [p[@"state"] isKindOfClass:NSNumber.class] ? p[@"state"] : nil;
  if (!wanted || wanted.doubleValue != wanted.intValue || wanted.intValue < 0 || wanted.intValue > 3) {
    Reply(request, nil, @"state must be 0, 1, 2 or 3"); return;
  }
  auto prefs = CefPreferenceManager::GetGlobalPreferenceManager();
  if (!prefs) { Reply(request, nil, @"Chromium's preferences are not ready"); return; }
  static const char kState[] = "performance_tuning.battery_saver_mode.state";
  auto read = [&] { auto value = prefs->GetPreference(kState); return value && value->GetType() == VTYPE_INT ? value->GetInt() : -1; };
  int was = read();
  auto value = CefValue::Create();
  value->SetInt(wanted.intValue);
  CefString error;
  if (!prefs->SetPreference(kState, value, error)) { Reply(request, nil, @(error.ToString().c_str())); return; }
  Reply(request, @{@"was": @(was), @"state": @(read())});
}
static void Request(NSDictionary* request) {
  NSString* id = S(request, @"id"); NSString* method = S(request, @"method");
  if (!id.length || id.length > 128 || requests.count(Key(id))) { wire.Close(); Shutdown(); return; }
  // The client says how long a request may take (the ones a page's load
  // waits on take long on a busy Mac); the rest keep 20 s.
  double allowed = [request[@"timeout"] isKindOfClass:NSNumber.class] && std::isfinite([request[@"timeout"] doubleValue])
    ? std::clamp([request[@"timeout"] doubleValue], 1.0, 300.0) : 20;
  requests.emplace(Key(id), Running() + allowed);
  if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore request id=%s method=%s tab=%s\n", id.UTF8String, method.UTF8String, ([request[@"params"] isKindOfClass:NSDictionary.class] ? S(request[@"params"], @"tab") : @"").UTF8String);
  if (![request[@"v"] isEqual:@1]) { Reply(id, nil, @"Unsupported protocol version"); return; }
  if (!hello) {
    if (![method isEqual:@"hello"]) { Reply(id, nil, @"hello must be the first request"); return; }
    Mark("hello");
    hello = true;
    original_caller::Hello([request[@"params"] isKindOfClass:NSDictionary.class] ? request[@"params"] : @{});
    NativeSwitchGroupsHello();
    for (auto& [key, tab] : tabs) {
      tab.lastLayer = nil;
#if YABCORE_OWNCEF_SURFACES
      PublishOwnCEFSurface(tab);
#endif
      if (!tab.adopted && tab.creationAnnounced) Event(@"tab.created", &tab, CreatedState(tab));
    }
    Reply(id, @{@"version": @1, @"eventFlow": @(wire.Flowing() ? 1 : 0), @"scriptBundles": @1, @"engine": @"CEF 156 Chrome style", @"capabilities": @[@"profiles", @"tabs", @"layerContexts", @"input", @"isolatedScripts", @"bindings", @"dialogs", @"extensionsExperimental"],
      @"layerContextSource": YABCORE_OWNCEF_SURFACES ? @"cefCallback" : @"windowTreePolling",
      @"externalHostingSupported": @(YABCORE_EXTERNAL_HOST), @"nativeHooks": NativeHookCapabilities(),
      @"nativeGroupSource": NativeSnapshotPeerIdentity(),
      @"nativeOriginalCaller": original_caller::Receipt(S(NativeSnapshotPeerIdentity(), @"helperOwner"), S(NativeSnapshotPeerIdentity(), @"connection")),
      @"limitations": @[@"nativeScaleOnly", @"nativeSelectNotHosted", @"focusAndIMEUnverified", @"extensionActionTabIdentityUnverified", @"developmentSigning"]}); return;
  }
  // No count of requests in flight refuses one: the client already waits
  // its turn past 128 (Client.swift, inFlight), the transport bounds bytes,
  // and each request ends at its deadline. A fixed 256 here failed what the
  // client had let go (cancelled, timed out on its side, switch.group).
  NSDictionary* p = request[@"params"] ?: @{};
  if (![p isKindOfClass:NSDictionary.class]) { Reply(id, nil, @"params must be an object"); return; }
  if (NSString* error = Validate(p)) { Reply(id, nil, error); return; }
  if (stopping) { Reply(id, nil, @"Helper is shutting down"); return; }
  if ([method isEqual:@"debug.windowPoll"]) {
    if (!getenv("YAB_PROBE")) { Reply(id, nil, @"Window-poll counters require a probe world"); return; }
    Reply(id, @{@"ticks": @(pollTicks), @"fastTicks": @(fastPollTicks),
      @"windowNotifications": @(windowNotifications), @"hurries": @(pollHurries),
      @"reason": PollBusyReason() ?: @""});
    return;
  }
  if ([method isEqual:@"originalCaller.diagnostic"]) {
    auto diagnostic=original_caller::DiagnosticReceipt(S(NativeSnapshotPeerIdentity(), @"helperOwner"), S(NativeSnapshotPeerIdentity(), @"connection"));
    if (!diagnostic) Reply(id,nil,@"Original diagnostic connection unavailable");
    else Reply(id,diagnostic);
    return;
  }
  if ([method isEqual:@"transport.metrics"]) { Reply(id, wire.Metrics()); return; }
  if (ScriptBundleRequest(method, p, id)) return;
  if ([method isEqual:@"shutdown"]) { Reply(id); stopping = true; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ Shutdown(); }); return; }
  if (ReadPageRequest(method, p, id)) return;
  if ([method isEqual:@"profile.open"]) {
    Mark("profile.open");
    NSString* profile = S(p, @"profile");
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
    if (!profile.length || profile.length > 100 || [profile rangeOfCharacterFromSet:invalid].location != NSNotFound) { Reply(id, nil, @"Profile must be a short alphanumeric identifier"); return; }
    auto found = profiles.find(Key(profile));
    bool privateMode = [p[@"private"] boolValue];
    // A private profile's space: only a private one has a parent, and only
    // an open, ready space profile is one. Absent, or without the SDK's
    // capability, the private profile stands alone as before.
    NSString* parentName = p[@"parent"] == nil || p[@"parent"] == NSNull.null ? nil : S(p, @"parent");
    if (parentName && (!privateMode || !parentName.length || parentName.length > 100 ||
                       [parentName rangeOfCharacterFromSet:invalid].location != NSNotFound)) {
      Reply(id, nil, @"parent must name a space profile, for a private profile only"); return;
    }
    std::string parent = YABCORE_PRIVATE_EXTENSIONS && parentName ? Key(parentName) : std::string();
    if (found != profiles.end()) {
      if (found->second.privateMode != privateMode) Reply(id, nil, @"Profile already exists with different privacy");
      else if (found->second.parent != parent) Reply(id, nil, @"Profile already exists with a different parent");
      else if (!found->second.ready) found->second.waiting.push_back(id);
      else Reply(id, ProfileReply(found->second, profile));
      return;
    }
    // No count of profiles: Chrome's ProfileManager has none. Every space and
    // every private window is one; a fixed 64 refused the 65th for good.
#if YABCORE_PRIVATE_EXTENSIONS
    if (!parent.empty()) {
      auto space = profiles.find(parent);
      if (space == profiles.end() || space->second.privateMode || !space->second.ready) {
        Reply(id, nil, @"Open the parent space profile first"); return;
      }
      auto context = space->second.context->CreateOffTheRecordContext(new ProfileHandler(Key(profile)));
      if (!context) { Reply(id, nil, @"Cannot create the private side of the space profile"); return; }
      Profile opened{context, true, false, {id}, parent};
      profiles[Key(profile)] = std::move(opened); return;
    }
#endif
    CefRequestContextSettings settings;
    if (!privateMode) {
      // Chrome style requires immediate children of root_cache_path. Nested
      // paths silently fall back to an off-the-record profile in CEF 156.
      NSString* path = [dataRoot stringByAppendingFormat:@"/space-%@", profile];
      SeedPreferences([path stringByAppendingPathComponent:@"Preferences"]);
      CefString(&settings.cache_path) = path.UTF8String;
      settings.persist_session_cookies = true;
    }
    auto context = CefRequestContext::CreateContext(settings, new ProfileHandler(Key(profile)));
    if (!context) { Reply(id, nil, @"Cannot create profile"); return; }
    profiles[Key(profile)] = {context, privateMode, false, {id}}; return;
  }
  if ([method isEqual:@"shield.configure"]) { ShieldConfigure(p); Reply(id); return; }
  if ([method isEqual:@"power.energySaver"]) { EnergySaverRequest(p, id); return; }  // The browser's, no tab.
  if ([method isEqual:@"profile.close"]) {
    auto profile = profiles.find(Key(S(p, @"profile")));
    if (profile == profiles.end()) { Reply(id, nil, @"Unknown profile"); return; }
    for (auto& [key, t] : tabs) if (t.profile == profile->first) { Reply(id, nil, @"Close profile tabs first"); return; }
    ExtensionProfileClosed(profile->first);
    profiles.erase(profile); Reply(id); return;
  }
  if ([method isEqual:@"extension.open"]) {
    std::string profile = Key(S(p, @"profile"));
    auto found = profiles.find(profile);
    if (found == profiles.end()) { Reply(id, nil, @"Unknown profile"); return; }
    if (found->second.privateMode) { Reply(id, nil, @"Extension management is unavailable in private profiles"); return; }
    Create(profile, @"chrome://extensions/", id, true); return;
  }
  if ([method isEqual:@"settings.open"]) {
    std::string profile = Key(S(p, @"profile"));
    auto found = profiles.find(profile);
    if (found == profiles.end()) { Reply(id, nil, @"Unknown profile"); return; }
    if (found->second.privateMode) { Reply(id, nil, @"Settings are unavailable in private profiles"); return; }
    if (!SettingsPageAllowed(S(p, @"page"))) { Reply(id, nil, @"Unknown settings page"); return; }
    Create(profile, [@"chrome://settings/" stringByAppendingString:S(p, @"page")], id, true); return;
  }
  if ([method isEqual:@"tab.create"]) {
    Mark("tab.create", Key(S(p, @"url")));
    std::string profile = Key(S(p, @"profile"));
    if (!profiles.count(profile)) { Reply(id, nil, @"Unknown profile"); return; }
    // Explicitly empty means CEF's native no-navigation bootstrap. Missing
    // URL retains the wire's previous default for other clients.
    Create(profile, p[@"url"] ? S(p, @"url") : @"about:blank", id); return;
  }
  if ([method isEqual:@"extension.consent.capabilities"]) {
    // A boolean on the wire, as the client compares it: boxed as the macro's
    // 1 it read as "no", and Settings asked its own card before Chrome's (#2030).
    Reply(id, @{@"nativeConsent": @(YABCORE_EXTENSION_CONSENT != 0)}); return;
  }
  if (DownloadPublicationRequest(method, p, id)) return;
  if (DownloadRequest(S(p, @"tab"), method, p, id)) return;
#if YABCORE_EXTENSION_CONSENT
  if ([method isEqual:@"extension.consent.reply"]) { ConsentReply(p, id); return; }  // Profile-level, no tab.
#endif
#if YABCORE_EXTENSION_DESKTOP_MEDIA
  if ([method isEqual:@"extension.desktopMedia.reply"]) { DesktopMediaReply(p, id); return; }  // By token, no tab.
#endif
  if (WebAuthnRespond(method, p, id)) return;  // By the request's token, no tab.
  if (GeolocationRequest(method, p, id)) return;  // The browser's, no tab.
  if (ExtensionTabOperationRequest(method, p, id)) return;
  if ([method isEqual:@"tabs.group"]) { TabsGroupRequest(p, id); return; }
  if (PermissionProfileRequest(method, p, id)) return;
  if (PushRequest(method, p, id)) return;
  if (SiteNoticeRequest(method, p, id)) return;
  if (OriginalPDFGlobalRequest(method, p, id)) return;
  if (NativeSwitchGroupRequest(method, p, id)) return;
  if (LifecycleBatchRequest(method, p, id)) return;
  auto found = tabs.find(Key(S(p, @"tab")));
  if (found == tabs.end() || !found->second.browser || found->second.closing) { Reply(id, nil, @"Unknown or unready tab"); return; }
  Tab& t = found->second;
  if (IsReadTab(&t)) { Reply(id, nil, @"Task read pages require dedicated read.page transport"); return; }
  if (!t.adopted && ![@[@"tab.adopt", @"tab.close", @"tab.state"] containsObject:method]) {
    Reply(id, nil, @"Adopt this Chrome-created tab first"); return;
  }
  auto b = t.browser;
  if ([method isEqual:@"tab.readiness"]) { Readiness(t, p, id); return; }
  if (DevToolsRequest(t, method, p, id)) return;
  if (NavigationRequest(t, method, p, id)) return;
  if (DragRequest(t, method, p, id)) return;
  if (AccessibilityRequest(t, method, p, id)) return;
  if (AccessibilityPlace(t, method, p, id)) return;
  if (OriginalPDFPresenceRequest(t, method, p, id)) return;
  if (OriginalPDFRequest(t, method, p, id)) return;
  if (PrintFindRequest(t, method, p, id)) return;
  if (QuestionRequest(t, method, p, id)) return;
  if (HistoryRequest(t, method, p, id)) return;
  if (MediaRequest(t, method, p, id)) return;
  if (ContextMenuRequest(t, method, p, id)) return;
  if (PermissionRequest(t, method, p, id)) return;
  if (LifecycleRequest(t, method, p, id)) return;
  if (HTMLLoadRequest(t, method, p, id)) return;
  if (NativeTextInputRequest(t, method, p, id)) return;
  if (NativeHookRequest(t, method, p, id)) return;
  if (DRMCookieCommand(t, method, p, id)) return;
  if (SettingsRequest(t, method, p, id)) return;
  if (SiteCookiesRequest(t, method, p, id)) return;
  if (OriginDataRequest(t, method, p, id)) return;
  if (ExtensionBridgeCommand(t, method, p, id)) return;
  if (ExtensionActionCommand(t, method, p, id)) return;
  if ([method isEqual:@"extension.actions"] || [method isEqual:@"extension.pressAction"]) {
    if (!t.nativeExtensions || t.internal) { Reply(id, nil, @"Native action diagnostics require the opt-in normal-window path"); return; }
    if ([method isEqual:@"extension.pressAction"]) {
      NSString* error = nil;
      if (!ExtensionPressNamedAction(t.native, S(p, @"name"), &error)) { Reply(id, nil, error); return; }
    }
    Reply(id, @{@"buttons": ExtensionActionButtons(t.native), @"widgets": ExtensionActionWidgets(t.native, Context),
      @"nativeWindow": @(t.native.windowNumber), @"keyWindow": @(t.native.isKeyWindow), @"appActive": @(NSApp.isActive)});
  }
  else if ([method isEqual:@"tab.adopt"]) {
    if (!t.adopted && !t.creationAnnounced) { Reply(id, nil, @"No native tab creation request"); return; }
    if (![S(p, @"profile") isEqual:@(t.profile.c_str())] || !p[@"private"] ||
        [p[@"private"] boolValue] != profiles.at(t.profile).privateMode) {
      Reply(id, nil, @"Adoption profile/privacy mismatch"); return;
    }
    t.adopted = true; t.lastLayer = nil; Reply(id, CreatedState(t));
    State(&t, @{@"url": Str(b->GetMainFrame()->GetURL()), @"title": t.title,
      @"loading": @(b->IsLoading()), @"canGoBack": @(b->CanGoBack()), @"canGoForward": @(b->CanGoForward())});
  }
  else if ([method isEqual:@"tab.close"]) { t.closing = true; Reply(id); WatchCommittedClose(t.id); b->GetHost()->CloseBrowser(true); }
  else if ([method isEqual:@"tab.navigate"]) {
    if (!S(p, @"url").length) { Reply(id, nil, @"url is required"); return; }
    NSString* url = S(p, @"url");
    NSString* referrer = S(p, @"referrer");
    if (p[@"referrer"]) {
      NSURLComponents* parts = [NSURLComponents componentsWithString:referrer];
      if (!referrer.length || ![@[@"http", @"https"] containsObject:parts.scheme.lowercaseString]
          || !parts.host.length || parts.user || parts.password || parts.fragment
          || [referrer rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
        Reply(id, nil, @"Invalid navigation referrer"); return;
      }

    }
    std::string tabID = t.id;
    // CEF's unnavigated bootstrap has no renderer document, so its DevTools
    // agent (and every CDP call) waits for the first real one. Never hold the
    // first navigation behind the hook there.
    if (!t.domainsReady && (!b->HasDocument() || !referrer.length)) {
      if (!referrer.length) {
        // Hook the first document right after DevTools attaches, in the
        // current document as well as later ones.
        ++t.documentGeneration; t.drmFrames.clear();
        b->GetMainFrame()->LoadURL(Key(url)); Reply(id);
        InstallDRM(t, [](NSDictionary*, NSString* error) {
          if (error) fprintf(stderr, "YabCore DRM hook after first navigation: %s\n", error.UTF8String);
        }, true);
        return;
      }
      // Page.navigate carries the referrer but needs an agent: load a blank
      // document first and drop that entry once the real one has loaded.
      t.scripts.blankFirst = true;
      ++t.documentGeneration; t.drmFrames.clear();
      b->GetMainFrame()->LoadURL("about:blank");
    }
    InstallDRM(t, [id, tabID, url, referrer](NSDictionary*, NSString* error) {
      auto t = tabs.find(tabID);
      if (t == tabs.end() || t->second.closing) { Reply(id, nil, @"Tab closed"); return; }
      // The hook only tells Yab a page was refused Widevine. A renderer too
      // busy to take it in time costs that notice, never the navigation.
      if (error) fprintf(stderr, "YabCore DRM hook before navigation: %s\n", error.UTF8String);
      ++t->second.documentGeneration; t->second.drmFrames.clear();
      if (referrer.length) {
        // LoadRequest requires an existing initiator origin in CEF. A fresh
        // replacement tab has none; Page.navigate accepts the referrer directly.
        DRMCDP(tabID, @"Page.navigate", @{@"url": url, @"referrer": referrer,
                @"referrerPolicy": @"strictOriginWhenCrossOrigin"},
          [id, tabID, url](NSDictionary* result, NSString* error) {
            // A load the network refused or that another replaced (a click
            // tracker's redirect, a download) is CEF's to say, in
            // page.loadError, as for every other navigation: errorText here
            // said it a second time as Yab's own failure (YabCoreError.remote, code 1).
            NSString* failure = S(result, @"errorText");
            if (failure.length) fprintf(stderr, "YabCore Page.navigate: %s\n", failure.UTF8String);
            auto t = tabs.find(tabID);
            if (error && t != tabs.end() && !t->second.closing && t->second.browser) {
              // No agent in time: the page still goes, as Chromium's would, only without the referrer.
              fprintf(stderr, "YabCore Page.navigate unavailable, loading without referrer: %s\n", error.UTF8String);
              t->second.browser->GetMainFrame()->LoadURL(Key(url)); Reply(id); return;
            }
            Reply(id, result, error);
          }, Running() + 10);
      } else { t->second.browser->GetMainFrame()->LoadURL(Key(url)); Reply(id); }

    });
  } else if ([method isEqual:@"tab.back"]) { if (b->CanGoBack()) { ++t.documentGeneration; t.drmFrames.clear(); b->GoBack(); } Reply(id); }
  else if ([method isEqual:@"tab.forward"]) { if (b->CanGoForward()) { ++t.documentGeneration; t.drmFrames.clear(); b->GoForward(); } Reply(id); }
  else if ([method isEqual:@"tab.reload"]) { ++t.documentGeneration; t.drmFrames.clear(); if ([p[@"fromOrigin"] boolValue]) b->ReloadIgnoreCache(); else b->Reload(); Reply(id); }
  else if ([method isEqual:@"tab.stop"]) { b->StopLoad(); Reply(id); }
  else if ([method isEqual:@"media.mute"]) {
    if (!p[@"muted"]) { Reply(id, nil, @"muted is required"); return; }
    t.mutedWanted = [p[@"muted"] boolValue];
    b->GetHost()->SetAudioMuted(t.mutedWanted);
    State(&t, @{@"audioMuted": @(b->GetHost()->IsAudioMuted())});
    Reply(id, @{@"muted": @(b->GetHost()->IsAudioMuted())});
  } else if ([method isEqual:@"page.killRenderer"]) {
    struct proc_bsdinfo info = {};
    pid_t pid = t.rendererPID;
    if (p[@"rendererPID"] && [p[@"rendererPID"] intValue] != pid) {
      Reply(id, nil, @"Renderer changed before termination"); return;
    }
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
        info.pbi_ppid != getpid() || info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec != t.rendererBorn) {
      Reply(id, nil, @"Renderer identity is unavailable or has changed"); return;
    }
    if (kill(pid, SIGKILL) != 0) { Reply(id, nil, @"Cannot end renderer"); return; }
    Reply(id);
  }
  else if ([method isEqual:@"tab.state"]) {
    // CEF can clear HasDocument after a same-document navigation while the
    // renderer and its default main-frame context are still alive.
    bool hasMainContext = std::any_of(t.scripts.contexts.begin(), t.scripts.contexts.end(), [&t](const auto& entry) {
      const auto& context = entry.second;
      return context.isDefault && !context.session.length && context.frame.length && [context.frame isEqual:t.scripts.mainFrame];
    });
    Reply(id, @{@"url": Str(b->GetMainFrame()->GetURL()), @"loading": @(b->IsLoading()), @"canGoBack": @(b->CanGoBack()), @"canGoForward": @(b->CanGoForward()), @"hasDocument": @(b->HasDocument()), @"hasMainContext": @(hasMainContext),
      @"cachePath": Str(b->GetHost()->GetRequestContext()->GetCachePath()), @"devToolsReady": @(t.domainsReady),
      @"nativeExtensionWindow": @(t.nativeExtensions), @"nativeWindow": @(t.native.windowNumber),
      @"contextId": @(t.externalPage ? t.surface.context : Context(t.native)),
      @"nativePage": t.nativePageReceipt ?: (::id)NSNull.null,
      @"pageRect": t.externalPage ? (::id)(t.nativePageReceipt ?: @{}) : (::id)NSStringFromRect(ExtensionPageRect(t.native)),
      @"rendererPID": @(t.rendererPID), @"audioMuted": @(b->GetHost()->IsAudioMuted()),
      @"audible": @(t.audible), @"focused": @(t.focused), @"discarded": @(t.discarded), @"frozen": @(t.frozen), @"backgroundColor": t.backgroundColor ?: (::id)NSNull.null,
      @"geometry": @{@"windowClass": t.native ? NSStringFromClass(t.native.class) : @"",
        @"frame": t.native ? NSStringFromRect(t.native.frame) : @"", @"content": t.native ? NSStringFromRect(t.native.contentView.frame) : @"",
        @"styleMask": @(t.native.styleMask), @"requested": @[@(t.width), @(t.height)], @"views": @(t.window != nullptr)},
      // Physical AppKit state is distinct from delegated Chromium visibility
      // and activation. Keep both observable for the external-host proofs.
      @"producer": @{@"visible": @(t.native.isVisible), @"key": @(t.native.isKeyWindow),
        @"externallyHosted": @(t.externallyHosted),
        @"windowNumber": @(t.native.windowNumber),
        @"onScreen": WindowOnScreen(t.native) ?: (::id)NSNull.null,
        @"appActive": @(NSApp.isActive), @"alpha": @(t.native.alphaValue),
        @"logicalVisible": @(t.externalPage ? t.visible : t.window && t.window->IsVisible()),
        @"logicalActive": @(t.externalPage ? t.focused : t.window && t.window->IsActive())}});
  } else if ([method isEqual:@"tab.resize"]) {
    double width = [p[@"width"] doubleValue], height = [p[@"height"] doubleValue], scale = [p[@"scale"] doubleValue];
    if (width < 1 || height < 1 || width > 16384 || height > 16384 || scale < 0.5 || scale > 4 || (!t.window && !t.nativeExtensions && !t.fitPage && !t.externalPage)) { Reply(id, nil, @"Invalid size or unready window"); return; }
    t.width = width; t.height = height; t.scale = scale;
    PageFollowScale(t, scale);
    const bool fitWindow = !t.externalPage && (t.nativeExtensions || t.fitPage);
    if (fitWindow && (!t.documentPiP || t.documentPiPSized)) ResizeExtensionWindow(t.native, width, height);
    NSString* serial = S(p, @"serial");
#if YABCORE_OWNCEF_SURFACES
    // Arm before SetSize: a synchronous CA frame may arrive during it.
    t.resizeSerial = serial.length ? serial : nil;
    t.resizeWidth = (int)ceil(width); t.resizeHeight = (int)ceil(height);
#endif
#if YABCORE_NATIVE_PAGE
    if (t.externalPage) {
      if (!b->GetHost()->SetExternalPageSize(CefSize((int)ceil(width), (int)ceil(height)))) {
        t.resizeSerial = nil;
        Reply(id, nil, @"Native page geometry owner is unavailable or refused the size"); return;
      }
    } else
#endif
    if (!fitWindow) t.window->SetSize(CefSize((int)ceil(width), (int)ceil(height)));
    t.lastLayer = nil;
    Reply(id, @{@"requestedScale": @(scale), @"actualScale": @(t.native.backingScaleFactor),
                @"resizeAck": @(YABCORE_OWNCEF_SURFACES && serial.length > 0 && !t.documentPiP)});
#if YABCORE_OWNCEF_SURFACES
    PublishOwnCEFSurface(t);
    AcknowledgeResize(t);  // Publish the context before even a no-op ACK.
#endif
  } else if ([method isEqual:@"tab.visible"]) {
    Mark("tab.visible", t.id);
    t.visible = [p[@"visible"] boolValue];
    // Hidden from the page only, the window being out of sight. Its picker may be what covers it.
    bool keep = [p[@"keep"] boolValue];
    // Shown again, or kept drawn: a hide held for a picture is not run after it.
    if (t.visible || keep) t.clearAfterCapture = false;
#if YABCORE_NATIVE_PAGE
    // WebContents visibility controls error-page recovery. Send it now,
    // independently of the delayed compositor cleanup below. Repeated hides
    // must reach it too, even when the view was already cleared.
    if (t.externalPage && !b->GetHost()->SetExternalPageVisibility(t.visible)) {
      Reply(id, nil, @"Native page visibility owner is unavailable"); return;
    }
#endif
    if (!t.visible && !keep) CancelFilePick(t.id);
    if (t.visible) {
      ++t.visibleTurn; t.everShown = true;
      if (t.viewCleared) { t.viewCleared = false; t.view->SetVisible(true); }
    }
    // A tab opened in the back has drawn nothing and hides at once, before it loads.
    if (!t.visible && !keep && (t.externalPage || t.externallyHosted) &&
        (t.viewCleared || (t.everShown && t.view && !getenv("YAB_KEEP_ON_HIDE")))) {
      if (!t.viewCleared) HideClearing(t);
      t.focused = false;
    } else {
#if YABCORE_NATIVE_PAGE
    if (t.externalPage) {
      if (!t.visible) t.focused = false;
    } else
#endif
    if (t.externallyHosted) {
      if (t.visible) t.window->Show(); else { t.window->Hide(); t.focused = false; }
    } else {
      if (t.visible) { Conceal(t.native); [t.native orderFront:nil]; } else [t.native orderOut:nil];
    }
    }
    t.lastLayer = nil;
#if YABCORE_OWNCEF_SURFACES
    PublishOwnCEFSurface(t);
#endif
#if YABCORE_DISCARD
    if (t.visible) {
      // Showing a page unfreezes it; a discarded one resumes its selected entry.
      if (t.frozen) { t.frozen = false; State(&t, @{@"frozen": @NO}); }
      if (t.discarded) {
        // Showing the page may already have started the restore on Chromium's side
        // (then RestoreDiscardedPage reports nothing left to do); either way the
        // client's discarded state ends here.
        b->GetHost()->RestoreDiscardedPage();
        NativeDiscarded(&t, false);
      }
    }
#endif
    if (!t.visible && t.domainsReady) {
      // Retire each target's CDP focus capturer: sent before the reply, so it
      // goes ahead of anything the client sends next, but not waited for. The
      // hide is applied already; a target that has just gone (an iframe's
      // session) must not turn it into an error, after which the client
      // counted the page as shown and never sent the next show (#883), nor
      // may a slow renderer hold the reply and the input queued behind it.
      std::vector<std::string> sessions(t.scripts.sessions.begin(), t.scripts.sessions.end());
      if (sessions.empty()) sessions.push_back("");
      std::string tabID = t.id;
      for (const auto& session : sessions) {
        CDP(t, @"Emulation.setFocusEmulationEnabled", @{@"enabled": @NO},
          [tabID, session](NSDictionary*, NSString* error) {
            if (!ScriptSessionGone(error)) return;
            auto found = tabs.find(tabID);
            if (found != tabs.end()) ForgetScriptSession(found->second, session);
          }, @(session.c_str()));
      }
    }
    Reply(id);
  } else if ([method isEqual:@"input.send"]) Input(t, p, id);
  else if (NativeDialogRequest(t, method, p, id)) { return;
  } else if ([method isEqual:@"page.frame"]) {
    // Two animation frames: the second starts after the first was handed to the compositor.
    Eval(t, @"new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))", 0, [id](NSDictionary*, NSString* e) { Reply(id, @{}, e); });
  } else if ([method isEqual:@"page.snapshot"]) {
    NSDictionary* proof = p[@"document"];
    if (!DocumentMatches(t, proof)) { Reply(id, nil, @"Snapshot document changed"); return; }
    // A picture wakes a frozen page: DevTools holds it hidden but painting, which
    // Blink's scheduler treats as visible, and nothing freezes it again afterward.
    if (t.frozen) { Reply(id, nil, @"Page is frozen"); return; }
    // A page out of sight whose view was let go, or that was opened in the
    // back and never shown, draws nothing. Chromium keeps such a picture
    // request until the page is shown again, minutes or never, and holds a
    // "Capturing" wake lock on the display all that while: with Yab in front
    // the Mac never slept (#1909). Its last picture is the client's to keep.
    if (!t.visible && (t.viewCleared || !t.everShown)) { Reply(id, nil, @"Page is hidden"); return; }
    Mark("page.snapshot", t.id + (t.viewCleared ? " cleared" : ""));
    // Counted from here: a hide that comes next waits for this picture
    // (HideClearing), so a picture asked before a hide is of the page as shown.
    ++t.capturing;
    // CDP copies the renderer's surface; AppKit cacheDisplay cannot read CALayerHost.
    NSDictionary* clip = [p[@"clip"] isKindOfClass:NSDictionary.class] ? p[@"clip"] : nil;
    SnapshotPage(t.id, t.documentGeneration, proof, id, [S(p, @"format") isEqual:@"jpeg"] ? 75 : 0, clip,
                 [p[@"surface"] boolValue], [p[@"raw"] boolValue]);
  } else if ([method isEqual:@"page.tone"]) {
    PageTone(t, p, id);
  } else if (AgentRequest(t, method, id) || AgentFilesRequest(t, method, p, id)) {
    return;
  } else if ([method isEqual:@"page.actionReply"]) {
    PageActionAnswered(S(p, @"request"), [p[@"allow"] boolValue], [p[@"url"] isKindOfClass:NSString.class] ? p[@"url"] : nil);
    Reply(id);
  } else if ([method isEqual:@"shield.status"]) {
    Reply(id, ShieldStatus(&t));
  } else if ([method isEqual:@"page.certificate"]) {
    Reply(id, PageCertificate(t));
  } else if ([method isEqual:@"page.emulate"]) {
    PageEmulate(t, p, id);
  } else if ([method isEqual:@"page.minimumFont"]) {
    PageMinimumFont(t, [p[@"size"] intValue]);
    Reply(id);
  } else if ([method isEqual:@"page.fonts"]) {
    PageFamilies(t, p);
    Reply(id);
  } else if (ScriptRequest(t, method, p, id)) {
    return;
  } else if ([method isEqual:@"script.document"]) {
    if (!DocumentMatches(t, p[@"document"])) { Reply(id, nil, @"Target document changed"); return; }
    NSString* expression = S(p, @"expression");
    if (!expression.length) { Reply(id, nil, @"expression is required"); return; }
    bool whole = [p[@"whole"] boolValue];
    Eval(t, expression, [p[@"document"][@"context"] intValue], [id, whole](NSDictionary* r, NSString* e) {
      if (e) Reply(id, nil, e);
      else if (r[@"exceptionDetails"]) Reply(id, nil, JSON(r[@"exceptionDetails"]));
      else Reply(id, whole ? WholeValue(r) : (r[@"result"][@"value"] ?: NSNull.null));
    }, [p[@"userGesture"] boolValue], whole);
  } else if ([method isEqual:@"script.evaluate"] || [method isEqual:@"script.bind"]) {
    NSString* world = S(p, @"world");
    if (!world.length || world.length > 128 || [world hasPrefix:@"__yab"]) { Reply(id, nil, @"A non-reserved world name is required"); return; }
    Completion fail = [id](NSDictionary*, NSString* e) { Reply(id, nil, e); };
    if ([method isEqual:@"script.bind"]) {
      NSString* name = S(p, @"name");
      if (!name.length || name.length > 128 || [name hasPrefix:@"__yab"]) { Reply(id, nil, @"Invalid binding name"); return; }
      t.bindings[Key(name)].insert(Key(world));
      // A binding asked for before DevTools attaches is kept and added when
      // the agent attaches (OnDevToolsAgentAttached re-adds every binding).
      if (!t.transportReady) { Reply(id, @{@"pending": @YES}); return; }
      CDP(t, @"Runtime.addBinding", @{@"name": name, @"executionContextName": world}, [id](NSDictionary* r, NSString* e) { Reply(id, r, e); });
    } else {
      NSString* function = S(p, @"function"); if (!function.length) { Reply(id, nil, @"function is required"); return; }
      ::id args = p[@"arguments"] ?: NSNull.null; bool gesture = [p[@"userGesture"] boolValue];
      if (!DocumentMatches(t, p[@"document"])) { Reply(id, nil, @"Target document changed"); return; }
      NSDictionary* document = p[@"document"];
      NSString* expression = S(p, @"expression");
      // An agent's upload: the function returns the file field, given these paths.
      NSArray* files = p[@"files"] ? AgentFilePaths(p[@"files"]) : nil;
      if (p[@"files"] && (!files || expression.length)) { Reply(id, nil, @"files must be absolute file paths"); return; }
      WithWorld(t.id, world, [id, function, args, gesture, document, expression, files](Tab& tab, int context) {
        if (!DocumentMatches(tab, document)) { Reply(id, nil, @"Target document changed"); return; }
        if (expression.length) {
          CDP(tab, @"Runtime.evaluate", @{@"expression": expression, @"contextId": @(context), @"awaitPromise": @YES,
            @"returnByValue": @YES, @"replMode": @YES, @"userGesture": @(gesture)}, [id](NSDictionary* r, NSString* e) {
              Reply(id, e ? nil : WholeValue(r), e ?: (r[@"exceptionDetails"] ? JSON(r[@"exceptionDetails"]) : nil));
            });
          return;
        }
        if (files) {
          std::string owner = tab.id;
          CDP(tab, @"Runtime.callFunctionOn", @{@"functionDeclaration": function, @"executionContextId": @(context),
            @"arguments": @[@{@"value": args}], @"awaitPromise": @YES, @"returnByValue": @NO},
            [id, files, owner](NSDictionary* r, NSString* e) {
              auto current = tabs.find(owner);
              if (current == tabs.end()) { Reply(id, nil, @"Tab closed"); return; }
              AgentSetFiles(current->second, r, e, files, @"", id);
            });
          return;
        }
        CDP(tab, @"Runtime.callFunctionOn", @{@"functionDeclaration": function, @"executionContextId": @(context),
          @"arguments": @[@{@"value": args}], @"awaitPromise": @YES, @"returnByValue": @YES, @"userGesture": @(gesture)},
          [id](NSDictionary* r, NSString* e) {
            if (e) Reply(id, nil, e);
            else if (r[@"exceptionDetails"]) Reply(id, nil, [@"JavaScript exception: " stringByAppendingString:JSON(r[@"exceptionDetails"])]);
            else if (r[@"result"][@"unserializableValue"] || [r[@"result"][@"subtype"] isEqual:@"error"]) Reply(id, nil, @"Script result is not JSON serializable");
            else if (!r[@"result"][@"value"] && ![r[@"result"][@"type"] isEqual:@"undefined"]) Reply(id, nil, @"Script result is not JSON serializable");
            else Reply(id, r[@"result"][@"value"] ?: NSNull.null);
          });
      }, fail);
    }
  } else if ([method isEqual:@"extension.load"]) {
    NSString* path = S(p, @"path");
    BOOL directory = NO;
    if (!path.isAbsolutePath || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || !directory) { Reply(id, nil, @"Extension path must be an existing absolute directory"); return; }
    if (![Str(b->GetMainFrame()->GetURL()) isEqual:@"chrome://extensions/"]) { Reply(id, nil, @"Use a chrome://extensions/ management tab in the target profile"); return; }
    if (t.extensionLoadPending) { Reply(id, nil, @"An extension load is already pending"); return; }
    t.extensionLoadPending = true; t.extensionPath = path;
    std::string tab = t.id;
    // Chrome owns installation and validation. Its directory chooser receives
    // only the path explicitly supplied by this IPC request, in this profile.
    NSString* expression = @"(async()=>{await chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true});const error=await chrome.developerPrivate.loadUnpacked({failQuietly:true,populateError:true});if(error)throw new Error(JSON.stringify(error));return true})()";
    Eval(t, expression, 0, [id, tab](NSDictionary* r, NSString* e) {
      auto current = tabs.find(tab);
      if (current != tabs.end()) { current->second.extensionLoadPending = false; current->second.extensionPath = nil; }
      Reply(id, r[@"result"][@"value"] ?: NSNull.null, e);
    }, true);
  } else if ([method isEqual:@"extension.list"] || [method isEqual:@"extension.review"] || [method isEqual:@"extension.setEnabled"] || [method isEqual:@"extension.access"] || [method isEqual:@"extension.incognito"] || [method isEqual:@"extension.userScripts"] || [method isEqual:@"extension.command"] || [method isEqual:@"extension.remove"] || [method isEqual:@"extension.removalState"] || [method isEqual:@"extension.checkUpdates"]) {
    // Chrome's privileged extension-management UI is kept in this profile.
    // The caller supplies a chrome://extensions tab, never an arbitrary page.
    if (![Str(b->GetMainFrame()->GetURL()) isEqual:@"chrome://extensions/"]) { Reply(id, nil, @"Use a chrome://extensions management tab in the target profile"); return; }
    NSString* error = nil;
    NSString* expression = ExtensionExpression(method, p, &error, YABCORE_EXTENSION_CONSENT);
    if (error) { Reply(id, nil, error); return; }
    // Propagate the native removal confirmation through Chrome's gesture check.
    // ExtensionExpression rejects removal without that explicit confirmation.
    // The same for turning on one whose update asked for more: management
    // refuses that without a gesture, and Yab asked first.
    // Each command's exact key, from Chrome's own record (ext_commands.inc).
    NSDictionary* commandKeys = [method isEqual:@"extension.list"] ? ExtensionCommandKeys(t) : nil;
    Eval(t, expression, 0, [id, commandKeys](NSDictionary* r, NSString* e) {
      ::id value = r[@"result"][@"value"];
      if (commandKeys && !e) value = ExtensionRowsWithCommandKeys(value, commandKeys);
      Reply(id, value ?: NSNull.null, e);
    }, ([method isEqual:@"extension.remove"] || [method isEqual:@"extension.setEnabled"]) && [p[@"userApproved"] isEqual:@YES]);
  } else Reply(id, nil, @"Unknown method");
}
void Shutdown() {
  stopping = true;
  if (!contextInitialized || shutdownStarted) return;
  shutdownStarted = true;
  std::vector<CefRefPtr<CefBrowser>> browsers;
  NSMutableSet* producers = [NSMutableSet new];
  for (auto i = tabs.begin(); i != tabs.end();) {
    auto& t = i->second;
    t.closing = true;
    if (t.native) [producers addObject:t.native];
    if (t.browser) { browsers.push_back(t.browser); ++i; }
    else { Reply(t.createRequest, nil, @"Client exited during tab creation"); i = tabs.erase(i); }
  }
  fprintf(stderr, "YabCore shutdown: closing %zu browsers\n", browsers.size());
  for (auto b : browsers) {
#if YABCORE_CLOSE_PREFLIGHT
    // A successful Quit preflight leaves documents open until the client
    // actually exits. Only now may its silent renderer be ended. Ordinary
    // pages still get their normal unload, and Cancel never reaches here.
    auto tab = Find(b);
    if (tab && tab->quitUnresponsive && tab->documentGeneration == tab->closeDocumentGeneration) {
      ForceCloseUnresponsive(*tab);
      continue;
    }
#endif
    b->GetHost()->CloseBrowser(true);
    if (auto tab = Find(b)) WatchCommittedClose(tab->id);
  }
  // Chrome menus, extension action widgets and native confirmation windows
  // are not necessarily children of a registered producer. Hide every extra
  // window at once; CEF's own teardown destroys them. Closing a views widget
  // from AppKit here could strand its browser's close sequence.
  for (NSWindow* window in [NSApp.windows copy]) if (![producers containsObject:window]) [window orderOut:nil];
  if (browsers.empty()) { QuitOnce(); return; }
  // A browser whose close never completes must not keep the helper and its
  // GPU/utility children alive after its client is gone.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (tabs.empty()) return;
    fprintf(stderr, "YabCore shutdown: %zu browsers did not close, quitting anyway\n", tabs.size());
    QuitOnce();
  });
  // Last resort if the message loop itself is wedged. Children see the
  // browser process vanish and exit on their own.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    fprintf(stderr, "YabCore shutdown: message loop wedged, exiting\n");
    _exit(3);
  });
}
// The wire's budget for waiting events was passed and this tab held the most
// (transport.h): its waiting notifications are gone, so what the client knows
// of its document can't be trusted. That document ends and says so; every
// other page goes on. Hidden, it is discarded as Chromium discards a tab, and
// comes back when shown; on screen, its renderer ends and the page shows it
// crashed. Never from inside the Send that shed it.
static void ShedPage(std::string id, size_t bytes) {
  dispatch_async(dispatch_get_main_queue(), ^{
    auto found = tabs.find(id);
    if (found == tabs.end() || !found->second.browser || found->second.closing) return;
    Tab& t = found->second;
    if (t.shedding || t.discarded || t.crashed) return;
    t.shedding = true;
    fprintf(stderr, "YabCore shed tab=%s bytes=%zu visible=%d\n", id.c_str(), bytes, (int)t.visible);
    Event(@"page.eventsShed", &t, @{@"bytes": @(bytes), @"budget": @(kEventBudget), @"visible": @(t.visible)});
#if YABCORE_DISCARD
    auto host = t.browser->GetHost();
    if (!t.visible && host->CanDiscardPage()) { host->DiscardPage(new DiscardDone(t.id, nil)); return; }
#endif
    pid_t pid = t.rendererPID;
    struct proc_bsdinfo info = {};
    if (pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) && info.pbi_ppid == getpid() &&
        info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec == t.rendererBorn && kill(pid, SIGKILL) == 0) return;
    t.shedding = false;
    fprintf(stderr, "YabCore shed tab=%s: renderer identity unavailable, page left running\n", id.c_str());
  });
}
class App : public CefApp, public CefBrowserProcessHandler {
  NSString* socket_;
  NSString* bundle_;
  int bundleFolder_;
 public:
  App(NSString* root, NSString* socket) : socket_(socket), bundle_(NSBundle.mainBundle.bundlePath),
      bundleFolder_(open(NSBundle.mainBundle.bundlePath.fileSystemRepresentation, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)) { dataRoot = root; }
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override { return new Client("", ""); }
#if YABCORE_EXTENSION_CONSENT
  void OnExtensionConsent(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> request, CefRefPtr<CefExtensionConsentCallback> callback) override { NativeConsentRequest(Find(b), request, callback); }
  void OnExtensionConsentWithdrawn(const CefString& request) override { NativeConsentWithdrawn(request.ToString()); }
#endif
#if YABCORE_EXTENSION_DESKTOP_MEDIA
  void OnExtensionDesktopMedia(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> request,
                               CefRefPtr<CefExtensionDesktopMediaCallback> callback) override {
    NativeDesktopMediaRequest(b ? Find(b) : nullptr, request, callback);
  }
  void OnExtensionDesktopMediaWithdrawn(const CefString& request) override { NativeDesktopMediaWithdrawn(request.ToString()); }
#endif
#if YABCORE_WEBAUTHN_PROXY
  bool OnWebAuthnRequest(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> request, CefRefPtr<CefWebAuthnCallback> callback) override {
    return WebAuthnRequest(Find(b), request, callback);
  }
  void OnWebAuthnRequestCanceled(const CefString& request) override { WebAuthnCanceled(request.ToString()); }
#endif
#if YABCORE_GEOLOCATION_SOURCE
  void OnGeolocationSource(CefRefPtr<CefGeolocationSource> source) override { geolocationSource = source; }
  void OnGeolocationWatch(bool watching, bool high) override {
    if (hello) Event(@"geolocation.watch", nullptr, @{@"watching": @(watching), @"highAccuracy": @(high)});
  }
  void OnGeolocationPermissionRequested() override { if (hello) Event(@"geolocation.ask", nullptr, @{}); }
#endif
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    // Before Chrome starts: it launches its notification service while the
    // context is still coming up, and a service launched without the stand-in
    // reaches macOS itself, which asks about "YabCore Helper".
    StartSiteNotices();
    // The global context must not follow Chrome's last-used space profile.
    command->AppendSwitchWithValue("profile-directory", "Default");
    command->AppendSwitch("no-first-run");
#if YABCORE_NATIVE_PAGE
    // Default Chrome-created pages get independent hidden native endpoints
    // before OnAfterCreated publishes tab.created.
    command->AppendSwitch("yab-external-default-windows");
#endif
    command->AppendSwitch("no-default-browser-check");
#if YABCORE_GEOLOCATION_SOURCE
    // Where the device is comes from Yab (geolocation_source.inc): Chrome
    // makes no CoreLocation manager in this process, which macOS would see
    // under Yab's bundle signed as YabCore (#1971).
    command->AppendSwitch("yab-external-geolocation");
#endif
    // Any build without Google's branding counts as a developer's: a sampling
    // thread in the helper, GPU, network and a fifth of the renderers, ten stacks
    // a second for each one's first 30 s, then 2% of the time. Chrome Stable does
    // this for 0.006% of its users.
    command->AppendSwitch("disable-stack-profiler");
    ::yabcore::ApplyGpuStabilityPolicy(*command);
    // A folder picked in Yab's panel: no second question from a hidden window.
    command->AppendSwitch("yab-plain-folder-upload");
    // Chrome-style CEF otherwise owns the hidden HTTP authentication prompt.
    command->AppendSwitch("disable-chrome-login-prompt");
    // The parent app owns macOS Now Playing. Preserve MediaSession actions
    // while preventing the hidden helper from registering a second OS player.
    std::string disabled = command->GetSwitchValue("disable-features").ToString();
    disabled += disabled.empty() ? "HardwareMediaKeyHandling" : ",HardwareMediaKeyHandling";
    // These ask through a chooser or an account sheet of Chrome's own, in a
    // window nobody sees, so the page would wait for ever. Without them a page
    // finds the feature missing, as under WebKit, and says so or falls back.
    std::string blink = command->GetSwitchValue("disable-blink-features").ToString();
    blink += blink.empty() ? "WebUSB,WebHID,Serial,WebBluetooth,FedCm" : ",WebUSB,WebHID,Serial,WebBluetooth,FedCm";
    command->AppendSwitchWithValue("disable-blink-features", blink);
    // Nothing calls Google on its own: what Chrome fetches in the background
    // is for Chrome's own omnibox, translate bubble and services, and Yab has
    // none of them. docs/chromium-network.md lists every host and why.
    disabled += ",NetworkTimeServiceQuerying,AimEnabled,AimServerEligibilityEnabled,TranslateRankerQuery,TranslateRankerEnforcement"
                ",OptimizationHints,OptimizationHintsFetching,OptimizationGuideModelDownloading,AutofillServerCommunication";
    // Save to Drive in the PDF viewer uploads with the Google account Chrome is
    // signed in to, and Yab never signs Chrome in: with no account the button
    // opens Chrome's sign-in popup through OpenURLFromTab, which this helper
    // hands to Yab as a link, and Chrome's CHECK on the missing popup ended the
    // helper (report 1524, cef-patches/0108). Download and Print stay.
    disabled += ",PdfSaveToDrive";
    // Payment Request's sheet, and the payment app it opens (Google Pay's
    // pay.google.com handler), is a tab-modal dialog of Chrome's browser
    // window (PaymentRequestDialogView), which nobody sees here: show() waited
    // for ever and a checkout's Google Pay button did nothing (#1974). Chrome's
    // own switch for the API (WebPreferences.payment_request_enabled): without
    // it pay.js and Stripe go the way they go in Firefox, pay.google.com in a
    // popup window, which is Yab's.
    disabled += ",WebPayments";
    command->AppendSwitchWithValue("disable-features", disabled);
    command->AppendSwitch("disable-component-update");
    command->AppendSwitch("disable-domain-reliability");
    command->AppendSwitch("disable-client-side-phishing-detection");
    command->AppendSwitch("disable-sync");
    // The list of on-device AI models is a component of its own, asked for
    // with no regard to the switch above. Chrome's offer: read a local list.
    command->AppendSwitchWithValue("optimization-guide-manifest-override",
                                   Key([dataRoot stringByAppendingPathComponent:@"no-model-list"]));
    // Chrome's speech recognition sends the microphone to Google under an API
    // key this build has none of: it could only fail, after the audio left.
    command->AppendSwitchWithValue("disable-blink-features",
        "ScriptedSpeechRecognition,UnprefixedSpeechRecognition,WebShare,EyeDropperAPI");
#if YABCORE_NATIVE_PRINT
    // Page-initiated prints go to the client, not Chrome's print preview.
    command->AppendSwitch("yab-native-print");
#endif
#if YABCORE_EXTENSION_CONSENT
    // Chrome's install/uninstall dialogs go to the client instead of a hidden window.
    command->AppendSwitch("yab-extension-consent");
#endif
#if YABCORE_EXTENSION_DESKTOP_MEDIA
    // An extension's chooseDesktopMedia goes to Yab's share box, not Chrome's
    // picker over a hidden window (patch 0122).
    command->AppendSwitch("yab-extension-desktop-media");
#endif
    // Keep any features already set.
    std::string features = command->GetSwitchValue("enable-features").ToString();
    // Each tab has a window of its own, so a hidden tab's compositor must let
    // go of its back buffers: one page-sized surface per tab ever shown, or
    // 900 MB in the GPU process at 12 tabs. Chrome gets this from Finch
    // (DiscardCompositionBackBuffersMac); an official build has no field trials.
    features += features.empty() ? "" : ",";
    features += "NotifyCompositorOfWindowVisibilityOnMacOs,VizBufferQueueDiscardOnVisibilityChange";
    // V8's old space starts at 16 MB (Finch: V8PreconfigureOldGen): 9 to 11 MB
    // less per renderer, none of it slower in the stand.
    features += ",V8PreconfigureOldGen:V8PreconfigureOldGenSize/16";
    // Native AX text insertion is compiled but disabled by default. Without
    // this, the Cocoa provider neither advertises nor handles AXTextOperation,
    // and an assistive client's replacement returns kAXErrorNoValue.
    features += ",MacAccessibilityTextOperation";
    // Yab's floating window shows the video and nothing else. Chrome paints the
    // site's favicon and address, over a dark scrim, on top of the video in the
    // compositor Yab hosts, until the overlay gets a press or the site earns high
    // media engagement, and the hidden overlay never gets a press. A trusted one
    // leaves both hidden. Document Picture in Picture doesn't read this.
    features += ",VideoPipForceTrustedForMediaPlaybackForTesting";
    // Global Privacy Control, as WebKit tabs send it (Web.globalPrivacyControl).
    // Chrome's own pref needs its UniversalOptOut settings UI; this is the
    // switch behind chrome://flags#enable-global-privacy-control.
    features += ",GlobalPrivacyControlForce";
#if YABCORE_DISCARD
    // Native discard is off by default on macOS.
    features += ",WebContentsDiscard";
#endif
    command->AppendSwitchWithValue("enable-features", features);
  }
  // The bundle this process runs from now. An update puts the new build in
  // place while Yab runs and sets the running bundle aside as yab.app.old
  // (Update.Swap): from then on the path this process started from holds
  // another build, with another framework. A descriptor of the bundle folder,
  // opened at launch, follows the rename. (The executable's own path is no
  // help: macOS 26 can report a code-signing clone of the bundle there, from
  // which no helper starts.)
  NSString* CurrentBundle() const {
    char bytes[MAXPATHLEN]{};
    if (bundleFolder_ < 0 || fcntl(bundleFolder_, F_GETPATH, bytes) == -1 || !bytes[0]) return bundle_;
    NSString* bundle = @(bytes);
    BOOL folder = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:[bundle stringByAppendingPathComponent:@"Contents/Frameworks"]
                                              isDirectory:&folder] && folder ? bundle : bundle_;
  }
  void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command) override {
    // An explicit browser_subprocess_path bypasses Chrome's bundle-name
    // inference. Route JIT processes to the role-specific signed executables,
    // rather than weakening the generic utility helper's entitlements.
    auto type = command->GetSwitchValue("type").ToString();
    SiteNoticesToChild(command);
    // Chrome's notification service runs in its " (Alerts)" helper
    // (kChildProcessHelperAlerts), every other utility in the plain one. The
    // explicit path below would otherwise put it in the plain helper too.
    NSString* name = type == "renderer" ? @"YabCore Helper (Renderer)" :
      type == "gpu-process" ? @"YabCore Helper (GPU)" : IsNoticeService(command) ? @"YabCore Helper (Alerts)" : @"YabCore Helper";
    // Every child comes from the bundle this process runs from, never from
    // the path it started at: after an update that path is the new build,
    // whose helper and framework do not match this browser.
    NSString* bundle = CurrentBundle();
    NSString* path = [bundle stringByAppendingFormat:@"/Contents/Frameworks/%@.app/Contents/MacOS/%@", name, name];
    fprintf(stderr, "YabCore child %s: %s -> %s\n", type.c_str(), command->GetProgram().ToString().c_str(), path.UTF8String);
    TraceLaunch(dataRoot, [@"core.child." stringByAppendingString:@(type.c_str())], path);
    command->SetProgram(Key(path));
    // And it is told where that bundle is. CEF finds it as the first path
    // component ending in .app, which in yab.app.old/ is the helper's own
    // bundle: there is no framework in it, and the child CHECKs in
    // BundleFromPath at startup (#1505, a renderer of yab.app.old).
    command->AppendSwitchWithValue("main-bundle-path", Key(bundle));
    command->AppendSwitchWithValue("framework-dir-path",
        Key([bundle stringByAppendingPathComponent:@"Contents/Frameworks/Chromium Embedded Framework.framework"]));
  }
  void OnContextInitialized() override {
    Mark("context-initialized");
    contextInitialized = true;
    TraceLaunch(dataRoot, @"core.context-ready");
    if (stopping) { Shutdown(); return; }
    fprintf(stderr, "YabCore canonical root: %s\n", dataRoot.UTF8String);
    if (!wire.Start(socket_)) { fprintf(stderr, "Cannot bind private YabCore socket\n"); QuitOnce(); return; }
    [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged)
      handler:^NSEvent*(NSEvent* event) {
        return DispatchPageKeyboard(event);
      }];
    wire.onRequest = Request;
    wire.onShed = [](const std::string& tab, size_t bytes) { ShedPage(tab, bytes); };
    wire.onDisconnect = [] {
      hello = false; requests.clear(); ClearScriptBundles(); ClearOriginalPDFPresence(); ClearOriginalPDF();
      NativeSwitchGroupsDisconnected();
      // The wire can be lost (Transport::Shed, a broken peer) inside a synchronous native close callback.
      // Retire the connection now, defer all native shutdown mutation until
      // the validate/commit/final callback stack has returned.
      if (nativeCloseDepth) dispatch_async(dispatch_get_main_queue(), ^{ ClearConsents(); ClearDesktopMedia(); ClearWebAuthn(); BeginShutdown("client disconnected"); });
      else { ClearConsents(); ClearDesktopMedia(); ClearWebAuthn(); BeginShutdown("client disconnected"); }
    };
    // The socket wakes the loop by itself. This is only deadlines and the
    // window watch, and a last look at the socket if a source ever stayed quiet.
    timer = [NSTimer timerWithTimeInterval:kPollBusy repeats:YES block:^(NSTimer* clock) {
      double late = nextPoll > 0 ? Now() - nextPoll - clock.tolerance : 0;
      if (late > 0.5) heldFor += late;
      wire.Poll(); OriginalPDFPoll();
      PollLayers();
      if (!pushDoors.empty()) PushDoorPoll();
      std::vector<Completion> expired;
      for (auto i = pending.begin(); i != pending.end();) {
        if (Running() > i->second.deadline) { expired.push_back(i->second.completion); i = pending.erase(i); } else ++i;
      }
      for (auto& completion : expired) completion(nil, @"CDP timeout");
      ExtensionBridgePoll();
      NSMutableArray* overdue = [NSMutableArray new];
      for (auto& [id, deadline] : requests) if (Running() > deadline) [overdue addObject:@(id.c_str())];
      for (NSString* id in overdue) if (!LifecycleExpireRequest(id)) Reply(id, nil, @"Operation timed out");
      bool busy = PollBusy();
      ++pollTicks;
      if (busy) ++fastPollTicks;
      double wait = busy ? kPollBusy : kPollResting;
      nextPoll = Now() + wait;
      clock.fireDate = [NSDate dateWithTimeIntervalSinceNow:wait];
      clock.tolerance = wait / 5;
    }];
    timer.tolerance = 0.02;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    windowWatches = [NSMutableArray new];
    for (NSNotificationName name in @[NSWindowDidChangeOcclusionStateNotification, NSWindowDidMoveNotification,
          NSWindowDidResizeNotification, NSWindowDidBecomeKeyNotification, NSWindowWillCloseNotification]) {
      id watch = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
          usingBlock:^(NSNotification* note) {
        if (![note.object isKindOfClass:NSWindow.class]) return;
        auto changed = ^{ ++windowNotifications; PollHurry(); };
        if (NSThread.isMainThread) changed();
        else dispatch_async(dispatch_get_main_queue(), changed);
      }];
      [windowWatches addObject:watch];
    }
  }
  ~App() override { TearDown(); }
  IMPLEMENT_REFCOUNTING(App);
};
void TearDown() {
  for (id watch in windowWatches) [NSNotificationCenter.defaultCenter removeObserver:watch];
  windowWatches = nil;
  ClearReadPages();
  ClearOriginalPDFPresence(); ClearOriginalPDF();
  ClearPDFStreams();
  [timer invalidate]; timer = nil; wire.onDisconnect = nullptr; wire.Close();
  pending.clear(); pageQuestions.clear(); authAttempts.clear();
  nativeDownloads.clear(); nativeFinds.clear(); filePicks.clear(); pageMenus.clear();
  tabs.clear(); profiles.clear(); browserTabs.clear(); requests.clear();
}
CefRefPtr<CefApp> MakeApp(NSString* root, NSString* socket) { return new App(root, socket); }
}
