// Exercise the real Input() body extracted by input_crash.py, with only CEF
// transport and the producer window replaced. AppKit view lookup stays real.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include "page_zoom.h"
#include INPUT_GESTURE
#include "../src/input_view.h"
#include "keyboard_event.h"
#include "key_commands.h"

static int nativePastes = 0;
static int inserted = 0, marked = 0, unmarked = 0, mouseEvents = 0, keyEvents = 0;
static std::function<void()> onInsert, onKey;
static NSEvent* lastKey;
@interface RenderWidgetHostViewCocoa : NSView
@end
@implementation RenderWidgetHostViewCocoa
- (void)paste:(id)sender { ++nativePastes; }
- (void)keyDown:(NSEvent*)event { lastKey = event; ++keyEvents; if (onKey) onKey(); }
- (void)keyUp:(NSEvent*)event { lastKey = event; ++keyEvents; if (onKey) onKey(); }
- (void)flagsChanged:(NSEvent*)event { lastKey = event; ++keyEvents; if (onKey) onKey(); }
- (void)mouseDown:(NSEvent*)event { assert(event.type == NSEventTypeLeftMouseDown); ++mouseEvents; }
- (void)mouseUp:(NSEvent*)event { assert(event.type == NSEventTypeLeftMouseUp); ++mouseEvents; }
- (void)mouseMoved:(NSEvent*)event { assert(event.type == NSEventTypeMouseMoved); ++mouseEvents; }
- (void)mouseDragged:(NSEvent*)event { assert(event.type == NSEventTypeLeftMouseDragged); ++mouseEvents; }
- (void)rightMouseDown:(NSEvent*)event { assert(event.type == NSEventTypeRightMouseDown); ++mouseEvents; }
- (void)rightMouseUp:(NSEvent*)event { assert(event.type == NSEventTypeRightMouseUp); ++mouseEvents; }
- (void)rightMouseDragged:(NSEvent*)event { assert(event.type == NSEventTypeRightMouseDragged); ++mouseEvents; }
- (void)insertText:(id)text replacementRange:(NSRange)range {
  assert([text isKindOfClass:NSString.class]); ++inserted;
  if (onInsert) onInsert();
}
- (void)setMarkedText:(id)text selectedRange:(NSRange)selection replacementRange:(NSRange)range { ++marked; }
- (void)unmarkText { ++unmarked; }
@end

// A real NSWindow needs a WindowServer session; Input only reads this view
// tree for these cases, so the fixture supplies its window properties.
@interface InputWindow : NSObject
@property NSView* contentView;
@property NSResponder* firstResponder;
- (NSInteger)windowNumber;
- (BOOL)makeFirstResponder:(NSResponder*)responder;
- (BOOL)isVisible;
@end
@implementation InputWindow
- (NSInteger)windowNumber { return 0; }
- (BOOL)isVisible { return NO; }
- (BOOL)makeFirstResponder:(NSResponder*)responder { self.firstResponder = responder; return YES; }
@end

struct CefMouseEvent { int x = 0, y = 0; };
struct Host {
  int leaves = 0, zoomReads = 0;
  double GetZoomLevel() { ++zoomReads; return 1; }
  void SendMouseMoveEvent(const CefMouseEvent&, bool leave) { assert(leave); ++leaves; }
};
struct Browser {
  std::shared_ptr<Host> host;
  std::shared_ptr<Host> GetHost() { return host; }
};
struct Tab {
  std::string id;
  NSWindow* native = nil;
  NSView* view = nil;
  std::vector<std::shared_ptr<QueuedKeyboardEvent>> keyboard;
  std::shared_ptr<Browser> browser;
  bool externallyHosted = false, pinched = false, closing = false, crashed = false;
  uint64_t documentGeneration = 0;
  yabcore::PageZoomCache zoomRead;
  // Pointer lock (pointer_lock.inc, R2472): Input() reads these. The fixture's
  // pages never lock, so they stay at core.mm's defaults.
  bool pointerLocked = false, pointerPointKnown = false;
  NSPoint pointerPoint = NSZeroPoint;
};
static std::map<std::string, Tab> tabs;
static int replies = 0, commands = 0, health = 0;
static NSString* error = nil;
static NSString* method = nil;
static NSDictionary* params = nil;
static NSString* S(NSDictionary* p, NSString* key) { return [p[key] isKindOfClass:NSString.class] ? p[key] : @""; }
static double Now() { return NSProcessInfo.processInfo.systemUptime; }
static void Reply(NSString* request, id result = @{}, NSString* failure = nil) {
  assert([request isEqual:@"input-test"]); ++replies; error = failure;
}
static void HealthInput(Tab&) { ++health; }
// pointer_lock.inc's helpers, for the locked branch of Input(). No fixture tab
// is locked, so reaching them is a failure of the test, not a path it covers.
[[maybe_unused]] static bool IsPointerLockKind(NSString*) { return false; }
[[maybe_unused]] static NSEvent* PointerLockEvent(NSDictionary*, NSString*, NSWindow*, NSPoint, NSEventModifierFlags) { std::abort(); }
// PointerLockDeliver is extracted from production in INPUT_HELPERS.
// Input() installs the lock hooks on the page's view class; the fixture's
// views are plain, so there is nothing to hook.
[[maybe_unused]] static void InstallPointerLockHooks() {}
#if __has_include("wheel_event.h")
#include "wheel_event.h"  // the real wheel builder (R2566), self-contained
#endif
static int zoomCommands = 0;
static void CDP(Tab& tab, NSString* name, NSDictionary* arguments,
                std::function<void(NSDictionary*, NSString*)> completion) {
  // The page's own zoom read (WithPageZoom): the renderer says 1.2, the
  // controller's level 1 would say the same. Not the input command itself.
  if ([name isEqual:@"Page.getLayoutMetrics"]) {
    ++zoomCommands;
    completion(@{@"cssVisualViewport": @{@"zoom": @1.2, @"scale": @1}}, nil);
    return;
  }
  ++commands; method = name; params = arguments;
  if (!tab.browser) completion(nil, @"Tab DevTools is not ready or is closing");
  else completion(@{}, nil);
}
#include INPUT_ZOOM
// Replace the producer application's event transport, not QueueKeyboard or
// TakeKeyboard. Delivery runs after Input returns, in the same FIFO order as
// AppKit's local monitor; the original payload and cancellation remain real.
static NSMutableArray<NSEvent*>* postedKeys;
@interface InputApplication : NSObject
- (void)postEvent:(NSEvent*)event atStart:(BOOL)atStart;
@end
@implementation InputApplication
- (void)postEvent:(NSEvent*)event atStart:(BOOL)atStart {
  assert(!atStart);
  [postedKeys addObject:event];
}
@end
static InputApplication* fixtureApplication;
#undef NSApp
#define NSApp fixtureApplication
static void ScriptRequest(Tab&, NSString* name, NSDictionary* arguments, NSString* request) {
  ++commands; method = name; params = arguments; Reply(request);
}
#include INPUT_HELPERS
#include INPUT_FUNCTION

static int checks = 0;
static void Check(bool passed, const char* name) {
  ++checks;
  if (!passed) { std::cerr << "FAIL " << name << '\n'; std::exit(1); }
  std::cout << "PASS " << name << '\n';
}
static void Send(Tab& tab, NSString* kind, bool nativePopup = false, NSDictionary* extra = nil) {
  replies = commands = health = 0; error = method = nil; params = nil;
  NSMutableDictionary* packet = [@{@"kind": kind, @"x": @120, @"y": @60, @"text": @"hello"} mutableCopy];
  if (extra) [packet addEntriesFromDictionary:extra];
#if INPUT_HAS_NATIVE_POPUP
  Input(tab, packet, @"input-test", nativePopup);
#else
  Input(tab, packet, @"input-test");
#endif
}
static void DrainKeys(Tab& tab) {
#if INPUT_HAS_KEYBOARD_QUEUE
  while (postedKeys.count) {
    NSEvent* envelope = postedKeys.firstObject;
    [postedKeys removeObjectAtIndex:0];
    auto delivery = TakeKeyboard(tab, envelope);
    assert(delivery && (delivery->native || delivery->edit));
    delivery->canceled = {};
    if (delivery->edit) { delivery->edit(); continue; }
    NSView* content = tab.native.contentView;
    NSView* view = FindView(content.superview ?: content, @"RenderWidgetHostViewCocoa");
    NSResponder* target = [(id)tab.native.firstResponder isKindOfClass:NSView.class] &&
        [(NSView*)tab.native.firstResponder isDescendantOf:content] ? tab.native.firstResponder : view;
    NSEvent* native = delivery->native;
    if (envelope.type == NSEventTypeFlagsChanged) [target flagsChanged:native];
    else if (envelope.type == NSEventTypeKeyDown) KeyDown(target, native, delivery->commands);
    else [target keyUp:native];
  }
#endif
}
int main(int argc, char**) { @autoreleasepool {
  postedKeys = [NSMutableArray new]; fixtureApplication = [InputApplication new];
  InputWindow* window = [InputWindow new];
  auto* view = [RenderWidgetHostViewCocoa new];
  window.contentView = [NSView new]; [window.contentView addSubview:view];
  // Exactly the window-only target made by NativeHookRequest(popup.input).
  Tab popup; popup.native = (NSWindow*)(id)window; popup.externallyHosted = true;
  if (argc > 1) { Send(popup, @"mouseMove"); return 0; }

  NSArray* browserKinds = @[@"mouseDown", @"mouseUp", @"mouseMove", @"mouseDrag",
    @"rightDown", @"rightUp", @"rightDrag", @"middleDown", @"middleUp", @"middleDrag",
    @"dragEnter", @"dragOver", @"drop", @"dragCancel", @"dragIntercept"];
  for (bool emptyHost : {false, true}) {
    popup.browser = emptyHost ? std::make_shared<Browser>() : nullptr;
    for (NSString* kind in browserKinds) {
      Send(popup, kind);
      Check(replies == 1 && [error isEqual:@"Page input browser not ready"] && commands == 0 && health == 0,
            (std::string(emptyHost ? "null host: " : "popup has no browser: ") + kind.UTF8String).c_str());
    }
    popup.externallyHosted = false;
    Send(popup, @"mouseLeave");
    Check(replies == 1 && [error isEqual:@"Page input browser not ready"] && !commands,
          "CEF mouseLeave without browser/host replies once");
    popup.externallyHosted = true;
  }
  popup.browser = nullptr;
#if INPUT_HAS_NATIVE_POPUP
  for (NSString* kind in @[@"mouseDown", @"mouseUp", @"mouseMove", @"mouseDrag", @"rightDown", @"rightUp", @"rightDrag"]) {
    int before = mouseEvents;
    Send(popup, kind, true);
    Check(replies == 1 && !error && mouseEvents == before + 1 && !commands && !health,
          "authenticated popup mouse event reaches its original view without page CDP");
  }
  for (NSString* kind in @[@"middleDown", @"middleUp", @"middleDrag", @"dragEnter", @"dragOver", @"drop", @"dragCancel", @"dragIntercept"]) {
    int before = mouseEvents;
    Send(popup, kind, true);
    Check(replies == 1 && error && mouseEvents == before && !commands && !health,
          "unsupported popup input fails closed without touching another page");
  }
  Send(popup, @"text");
  Check(replies == 1 && error && !inserted && !commands, "window-only input needs an explicit native popup route");
#endif
  Send(popup, @"text", true);
  Check(replies == 1 && !error && inserted == 1 && !commands, "window-only popup still accepts text");
  Send(popup, @"compose", true); Send(popup, @"unmark", true);
  Check(replies == 1 && !error && marked == 1 && unmarked == 1, "window-only popup still accepts composition");
  Send(popup, @"unknown", true);
  Check(replies == 1 && [error isEqual:@"Unknown input kind"], "unknown input remains an error");
  popup.native = nil; Send(popup, @"mouseDown", true);
  Check(replies == 1 && [error isEqual:@"Page input view not ready"], "missing window fails closed");
  popup.native = (NSWindow*)(id)window; view.hidden = YES; Send(popup, @"mouseDown", true);
  Check(replies == 1 && [error isEqual:@"Page input view not ready"], "hidden input view fails closed");
  view.hidden = NO;

  // #1850: the earlier regression only exercised mouse/text paths. Modifier
  // transitions and command-key pairs use the same window-only popup target.
  for (NSString* kind in @[@"flagsChanged", @"keyDown", @"keyUp"]) {
    int before = keyEvents;
    Send(popup, kind, true);
#if INPUT_HAS_KEYBOARD_QUEUE
    Check(replies == 1 && keyEvents == before && postedKeys.count == 1,
          "popup keyboard acknowledges enqueue before native delivery");
#endif
    DrainKeys(popup);
    Check(replies == 1 && !error && keyEvents == before + 1 && !commands && !health,
          "popup keyboard input needs no page browser or host");
  }
  NSView* unrelated = [NSView new]; window.firstResponder = unrelated;
  Send(popup, @"keyDown", true);
  DrainKeys(popup);
  Check(!error && keyEvents == 4, "keyboard ignores a responder outside the popup content");
  window.firstResponder = view;
  for (NSDictionary* key in @[@{@"keyCode": @17, @"characters": @"t"},
                              @{@"keyCode": @13, @"characters": @"w"},
                              @{@"keyCode": @37, @"characters": @"l"},
                              @{@"keyCode": @15, @"characters": @"r"},
                              @{@"keyCode": @8, @"characters": @"c"},
                              @{@"keyCode": @9, @"characters": @"v"}]) {
    NSMutableDictionary* fields = [key mutableCopy];
    fields[@"unmodified"] = key[@"characters"];
    fields[@"modifiers"] = @(NSEventModifierFlagCommand);
    for (NSString* kind in @[@"keyDown", @"keyUp"]) {
      Send(popup, kind, true, fields);
      DrainKeys(popup);
      Check(!error && replies == 1 && lastKey.keyCode == [key[@"keyCode"] unsignedShortValue] &&
            lastKey.modifierFlags == NSEventModifierFlagCommand &&
            [lastKey.charactersIgnoringModifiers isEqual:key[@"characters"]],
            "Command shortcut retains its code, modifiers and text in the popup");
    }
  }

  Tab page = popup; page.id = "page"; page.browser = std::make_shared<Browser>();
  page.browser->host = std::make_shared<Host>(); tabs[page.id] = page;
  for (NSString* kind in @[@"flagsChanged", @"keyDown", @"keyUp"]) {
    Send(tabs.at("page"), kind);
    Check(replies == 1 && !error && health == 1, "live page keyboard input acknowledged once");
    DrainKeys(tabs.at("page"));
    onKey = [] { tabs.erase("page"); };
    Send(tabs.at("page"), kind);
#if INPUT_HAS_KEYBOARD_QUEUE
    Check(replies == 1 && !error && health == 1 && tabs.size() == 1,
          "queued keyboard acknowledges the live target before dispatch");
    DrainKeys(tabs.at("page"));
    Check(replies == 1 && !error && health == 1 && tabs.empty(),
          "queued keyboard callback retires its tab without another acknowledgement or borrowed access");
#else
    Check(replies == 1 && error && !health && tabs.empty(), "keyboard callback may retire its tab");
#endif
    onKey = nullptr; tabs["page"] = page;
  }
#if INPUT_HAS_KEYBOARD_QUEUE
  Send(tabs.at("page"), @"keyDown", false, @{@"event": @"not-base64"});
  Check(replies == 1 && error && postedKeys.count == 0 && !health,
        "malformed native keyboard payload refuses before enqueue");
  Send(tabs.at("page"), @"keyDown", false, @{@"commands": @[ @"moveLeft:; rm" ]});
  Check(replies == 1 && error && postedKeys.count == 0 && !health,
        "a keydown's editing commands are AppKit selector names or refused before enqueue");
  Send(tabs.at("page"), @"keyDown", false, @{@"commands": @[ @"moveToBeginningOfParagraph:" ]});
  Check(replies == 1 && !error && postedKeys.count == 1 && tabs.at("page").keyboard.size() == 1 &&
        [tabs.at("page").keyboard.back()->commands isEqual:@[ @"moveToBeginningOfParagraph:" ]],
        "a keydown's editing commands wait in the native FIFO with its event");
  DrainKeys(tabs.at("page"));
  Send(tabs.at("page"), @"keyUp", false, @{@"commands": @[ @"moveToBeginningOfParagraph:" ]});
  Check(replies == 1 && !error && tabs.at("page").keyboard.size() == 1 && !tabs.at("page").keyboard.back()->commands,
        "only a keydown carries editing commands");
  DrainKeys(tabs.at("page"));
  Send(tabs.at("page"), @"editorKey", false, @{@"key": @"v", @"nativeCode": @9});
  Check(!replies && !commands && postedKeys.count == 1,
        "editor key waits behind the native FIFO before script dispatch");
  DrainKeys(tabs.at("page"));
  Check(replies == 1 && !error && commands == 1 && [method isEqual:@"scripts.input"] &&
        [params[@"kind"] isEqual:@"key"], "queued editor key dispatches the real input command once");
  const int pastesBefore = nativePastes;
  Send(tabs.at("page"), @"editorKey", false,
       @{@"key": @"v", @"nativeCode": @9, @"nativeEdit": @"paste"});
  Check(!replies && !commands && nativePastes == pastesBefore && postedKeys.count == 1,
        "extension-window paste waits in the native keyboard FIFO");
  DrainKeys(tabs.at("page"));
  Check(replies == 1 && !error && !commands && nativePastes == pastesBefore + 1,
        "extension-window paste invokes the native view instead of CDP");
  Send(tabs.at("page"), @"editorKey", false,
       @{@"key": @"v", @"nativeCode": @9, @"nativeEdit": @"arbitrarySelector"});
  DrainKeys(tabs.at("page"));
  Check(replies == 1 && error && nativePastes == pastesBefore + 1,
        "native editing rejects selectors outside the Edit commands");
  Send(tabs.at("page"), @"editorKey", false,
       @{@"key": @"v", @"nativeCode": @9, @"nativeEdit": @"paste"});
  tabs.erase("page");
  Check(replies == 1 && error && !commands,
        "retiring a pending editor key reports cancellation instead of dispatching to another tab");
  [postedKeys removeAllObjects];
  tabs["page"] = page;
#endif
  for (NSString* kind in browserKinds) {
    Send(page, kind);
    Check(replies == 1 && !error && commands == 1, (std::string("live page: ") + kind.UTF8String).c_str());
    if ([kind isEqual:@"mouseDown"])
      Check([method isEqual:@"Input.dispatchMouseEvent"] && std::abs([params[@"x"] doubleValue] - 100) < .001 &&
            std::abs([params[@"y"] doubleValue] - 50) < .001 && health == 1, "live mouse retains zoom and health probe");
  }
  page.externallyHosted = false; Send(page, @"mouseLeave");
  Check(replies == 1 && !error && page.browser->host->leaves == 1 && !commands, "live CEF mouseLeave delivered");
  onInsert = [] { tabs.erase("page"); };
  Send(tabs.at("page"), @"text");
  Check(replies == 1 && [error isEqual:@"Page input target is no longer live"] && !health && tabs.empty(),
        "text callback that erases its tab replies with an error, without later access");
  tabs["page"] = page;
  onInsert = [] { tabs.at("page").documentGeneration++; };
  Send(tabs.at("page"), @"text");
  Check(replies == 1 && error && !health, "navigation during input cannot acknowledge a different document");
  tabs["page"] = page;
  onInsert = [page] { tabs.erase("page"); tabs["page"] = page; tabs["page"].browser = std::make_shared<Browser>(); };
  Send(tabs.at("page"), @"text");
  Check(replies == 1 && error && !health, "reused tab id cannot acknowledge a new browser");
  onInsert = nullptr;
  for (bool crashed : {false, true}) {
    page.closing = !crashed; page.crashed = crashed;
    int before = inserted;
    Send(page, @"text");
    Check(replies == 1 && error && !health && inserted == before,
          "closing or crashed target rejects input before native dispatch");
  }
  onInsert = [view] { [view removeFromSuperview]; };
  Send(popup, @"text", true);
  Check(replies == 1 && error && !health, "popup detached during input replies with an error");
  onInsert = nullptr;
  std::cout << "QA_CHECK_RESULT {\"passed\":true,\"checks\":" << checks << "}\n";
} }
