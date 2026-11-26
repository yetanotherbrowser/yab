// VoiceOver works in the client's process, and the page's accessibility tree
// lives on a view in a window nobody sees. Chromium's remote Cocoa does the
// same crossing for app shims: a token for the local element, which AppKit
// turns into an element of this process in the other one. A tree costs a page
// real work, so nothing is built until an assistive client asks the view.
//
// The token is for this element, one per tab, not for the page's view: each
// document has a view of its own (Chrome's RenderWidgetHostViewCocoa, one per
// RenderWidgetHost), and a navigation to another site, a page back from the
// cache or a renderer swapped on reload brings another. A token for the first
// view left Yab holding a document that was gone: after one navigation to
// another site, assistive clients found no page in the tab (R2594: Neru, a
// keyboard-hint app, drew no hint on it).
// This element answers with the tab's view of the moment, as Chromium's own
// window reaches its web contents (views::WebView::GetNativeViewAccessible
// asks for the current view each time).
static NSView* AccessibilityPageView(Tab& tab) {
  NSWindow* window = tab.native;
  return window ? FindView(window.contentView.superview ?: window.contentView, @"RenderWidgetHostViewCocoa") : nil;
}
}  // namespace yc: Objective-C classes live at file scope.
@interface YabPageAccessibility : NSAccessibilityElement
@end
@implementation YabPageAccessibility {
 @public
  std::string _tab;
  // Yab's page view, in Yab: what is up from the page.
  ::id _parent;
}
- (NSView*)currentView {
  auto found = yc::tabs.find(_tab);
  if (found == yc::tabs.end() || found->second.closing || !found->second.browser) return nil;
  yc::Tab& tab = found->second;
  NSView* view = yc::AccessibilityPageView(tab);
  if (view && view != tab.accessibilityView) {
    // A document this element has not handed out: up from it is here, and its
    // tree is built now, an assistive client having asked.
    if ([view respondsToSelector:@selector(setAccessibilityParentElement:)]) [view setAccessibilityParentElement:self];
    tab.accessibilityView = view;
    tab.browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
  }
  return view;
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (id)accessibilityParent { return _parent; }
- (NSArray*)accessibilityChildren {
  NSView* view = [self currentView];
  return view ? @[view] : @[];
}
- (NSRect)accessibilityFrame {
  NSView* view = [self currentView];
  if (!view.window) return NSZeroRect;
  return [view.window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
}
- (id)accessibilityHitTest:(NSPoint)point {
  NSView* view = [self currentView];
  return view ? [view accessibilityHitTest:point] : self;
}
@end
namespace yc {
static void AccessibilityTypeIntoFocus();
static bool AccessibilityRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"tab.accessibility"]) return false;
  if (!tab.browser) { Reply(request, nil, @"Page not ready"); return true; }
  AccessibilityTypeIntoFocus();
  [NSAccessibilityRemoteUIElement registerRemoteUIProcessIdentifier:[p[@"client"] intValue]];
  YabPageAccessibility* element = tab.accessibilityElement;
  if (!element) {
    element = [YabPageAccessibility new];
    element->_tab = tab.id;
    tab.accessibilityElement = element;
  }
  // Up from the page is the client's view, not the hidden window.
  NSData* parent = [[NSData alloc] initWithBase64EncodedString:S(p, @"parent") options:0];
  if (parent.length) element->_parent = [[NSAccessibilityRemoteUIElement alloc] initWithRemoteToken:parent];
  // The view of this moment, if any, is given its parent and its tree; a
  // page asked for as it opens has none yet, and its first document's
  // arrives with it (AccessibilityDocument).
  tab.accessibilityView = nil;
  NSView* view = [element currentView];
  if (getenv("YAB_PROBE") && *getenv("YAB_PROBE")) fprintf(stderr, "YabCore AX token: %s, a page view %d, at %.3f\n", tab.id.c_str(), view != nil, NSDate.date.timeIntervalSince1970);
  NSData* token = [NSAccessibilityRemoteUIElement remoteTokenForLocalUIElement:element];
  if (!token.length) { Reply(request, nil, @"No accessibility token"); return true; }
  Reply(request, @{@"token": [token base64EncodedStringWithOptions:0], @"pid": @(getpid())});
  return true;
}
// A document of a tab Yab reads has its tree as it starts, not at the walk
// that first reaches it: a tab asked for before its first document (once a
// client reads pages, every page is) had no tree at a hint key's first press.
static void AccessibilityDocument(Tab& tab) {
  if (YabPageAccessibility* element = tab.accessibilityElement) [element currentView];
}
// A client asking Yab for its focus gets the page view's element from Yab,
// and AppKit continues the question here, in this process's application,
// as Chromium's app shims and WebKit's web process have it. This process is
// never active and its windows never key, so AppKit's own answer is nothing:
// the page Yab has focused answers, with its focused node (a field takes
// AXSelectedText there). The last focused page stands in while Yab's focus
// is on its way back, as when a dictation panel hands it back.
static std::string lastFocusedTab;
// Every page view shown in a window: a window of Chrome's own can hold more
// than one tab's, and only views whose tree Yab asked for have one.
static void PageViews(NSView* view, NSMutableArray* found) {
  if (!view || view.isHiddenOrHasHiddenAncestor) return;
  if ([NSStringFromClass(view.class) isEqual:@"RenderWidgetHostViewCocoa"]) { [found addObject:view]; return; }
  for (NSView* child in view.subviews) PageViews(child, found);
}
// The page views of a tab that can hold its focus.
static NSArray<NSView*>* AccessibilityFocusViews(Tab& tab) {
  NSWindow* window = tab.native;
  NSMutableArray* views = [NSMutableArray new];
  // The view Yab was given first: Chrome's window may be showing another
  // tab's (a popup's) for the moment.
  // A hidden one is a document kept for going back.
  NSView* given = tab.accessibilityView;
  if (given && !given.isHiddenOrHasHiddenAncestor) [views addObject:given];
  PageViews(window.contentView.superview ?: window.contentView, views);
  return views;
}
static ::id AccessibilityFocus() {
  std::vector<Tab*> order;
  for (auto& entry : tabs) if (entry.second.focused) order.push_back(&entry.second);
  auto last = tabs.find(lastFocusedTab);
  if (last != tabs.end()) order.push_back(&last->second);
  const bool trace = getenv("YAB_PROBE") && *getenv("YAB_PROBE");
  for (Tab* tab : order) {
    if (tab->closing || !tab->visible || !tab->native || !tab->browser) continue;
    NSArray<NSView*>* views = AccessibilityFocusViews(*tab);
    for (NSView* view in views) {
      if (::id focused = [view accessibilityFocusedUIElement]) {
        if (trace) fprintf(stderr, "YabCore AX focus: %s of %lu views: %s\n", tab->id.c_str(), (unsigned long)views.count, NSStringFromClass([focused class]).UTF8String);
        return focused;
      }
    }
    if (trace) fprintf(stderr, "YabCore AX focus: %s focused %d, %lu views (given %d, in a window %d), none with a tree\n", tab->id.c_str(),
                       (int)tab->focused, (unsigned long)views.count, tab->accessibilityView != nil, tab->accessibilityView.window != nil);
    // A view built since (another site's document) has no tree yet: turn it
    // on for the next question.
    tab->browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
  }
  if (trace) fprintf(stderr, "YabCore AX focus: nothing (%lu candidates, last %s)\n", (unsigned long)order.size(), lastFocusedTab.c_str());
  return nil;
}
::id AccessibilityFocusedElement() { return AccessibilityFocus(); }
// The page view whose focused element this is, if it is the focus of a page.
// Every page is asked, not only those Yab has focused: the element is the one
// a client was handed as the focus, and only its own page answers with it.
static NSView* AccessibilityFocusView(::id element) {
  for (auto& entry : tabs) {
    Tab& tab = entry.second;
    if (tab.closing || !tab.native || !tab.browser) continue;
    for (NSView* view in AccessibilityFocusViews(tab)) {
      if ([view accessibilityFocusedUIElement] == element) return view;
    }
  }
  return nil;
}
// Apps that type into the focused field by setting its AXSelectedText
// (dictation and text tools) got nothing typed on a Chromium tab. Chromium
// turns that write into kReplaceSelectedText, which its renderer drops and
// Blink has no handler for (cef-patches/proposed/P003): the write answered
// success and the field stayed as it was. The field's page view is the
// text input client Yab commits typed text through (Input, kind "text"), so
// the selection is replaced there, as typing replaces it, and the page gets
// the beforeinput and input events of typed text. Any element that is not a
// page's focus keeps Chromium's own path.
static void AccessibilityTypeIntoFocus() {
  static bool installed = false;
  if (installed) return;
  installed = true;
  Class page = NSClassFromString(@"BrowserAccessibilityCocoa");
  SEL set = @selector(setAccessibilitySelectedText:);
  Method inherited = page ? class_getInstanceMethod(page, set) : nullptr;
  if (!inherited) return;
  using Setter = void (*)(::id, SEL, NSString*);
  const Setter chromium = (Setter)method_getImplementation(inherited);
  IMP typed = imp_implementationWithBlock(^(::id element, NSString* text) {
    // A client can write any value: only a string is typed, or measured.
    const bool string = [text isKindOfClass:NSString.class];
    NSView* view = string ? AccessibilityFocusView(element) : nil;
    const bool types = [view respondsToSelector:@selector(insertText:replacementRange:)];
    if (getenv("YAB_PROBE") && *getenv("YAB_PROBE")) fprintf(stderr, "YabCore AX selected text: %lu characters, %s\n", string ? (unsigned long)text.length : 0ul, types ? "typed into the page's focus" : "not a page's focus, Chromium's path");
    if (types) {
      [(id<NSTextInputClient>)view insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
      return;
    }
    chromium(element, set, text);
  });
  // Chromium defines the setter on the base class every element shares: the
  // page's elements get their own, and the base keeps Chromium's.
  if (!class_addMethod(page, set, typed, method_getTypeEncoding(inherited))) method_setImplementation(inherited, typed);
}
static void AccessibilityFocused(Tab& tab, bool focused) {
  if (focused) lastFocusedTab = tab.id;
}
// The window a page lives in never shows, but its place counts: its display
// gives the page its pixel density and its frames give a tree its screen points.
static bool AccessibilityPlace(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"tab.place"]) return false;
  double x = [p[@"x"] doubleValue], y = [p[@"y"] doubleValue];
  if (!tab.native || !std::isfinite(x) || !std::isfinite(y)) { Reply(request, nil, @"No window to place"); return true; }
  [tab.native setFrameOrigin:NSMakePoint(x, y)];
  // AppKit says nothing of a screen change to a window that isn't on one.
  NSView* view = FindView(tab.native.contentView.superview ?: tab.native.contentView, @"RenderWidgetHostViewCocoa");
  SEL update = NSSelectorFromString(@"updateScreenProperties");
  if ([view respondsToSelector:update]) ((void (*)(id, SEL))objc_msgSend)(view, update);
  Reply(request);
  return true;
}
