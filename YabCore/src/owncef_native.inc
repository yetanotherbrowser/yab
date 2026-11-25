// Own CEF native hooks (patches 0004, 0007, 0008). Included inside namespace
// yc after downloads.inc. Each hook is compiled only against a source-built
// SDK that advertises it and only when the helper uses the experimental API;
// official CEF and the stable API keep the previous wire behavior.
#if defined(CEF_YAB_AUDIBLE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_AUDIBLE 1
#else
#define YABCORE_NATIVE_AUDIBLE 0
#endif
#if defined(CEF_YAB_DOWNLOAD_PROVENANCE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_DOWNLOAD_PROVENANCE 1
#else
#define YABCORE_DOWNLOAD_PROVENANCE 0
#endif
#if defined(CEF_YAB_EXTERNAL_FOCUS_VERSION) && YABCORE_EXTERNAL_HOST
#define YABCORE_EXTERNAL_FOCUS 1
#else
#define YABCORE_EXTERNAL_FOCUS 0
#endif
#if defined(CEF_YAB_BACKGROUND_COLOR_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_BACKGROUND_COLOR 1
#else
#define YABCORE_BACKGROUND_COLOR 0
#endif
#if defined(CEF_YAB_SELECT_MENU_VERSION) && defined(CEF_YAB_EXTERNAL_SELECT_VERSION) && YABCORE_EXTERNAL_HOST
#define YABCORE_SELECT_MENU 1
#else
#define YABCORE_SELECT_MENU 0
#endif
#if defined(CEF_YAB_EXTENSION_HOOKS_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTENSION_HOOKS 1
#else
#define YABCORE_EXTENSION_HOOKS 0
#endif
#if defined(CEF_YAB_EXTERNAL_ACTION_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTERNAL_ACTION 1
#else
#define YABCORE_EXTERNAL_ACTION 0
#endif
// An extension's named command for a page (patch 0116): Chrome's activeTab
// grant and commands.onCommand, the client choosing the key.
#if defined(CEF_YAB_EXTENSION_COMMAND_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTENSION_COMMAND 1
#else
#define YABCORE_EXTENSION_COMMAND 0
#endif
// An extension's own surfaces Yab draws (patch 0124): its button's menu
// items, its omnibox keyword's events, its side panel's options changes.
#if defined(CEF_YAB_EXTENSION_SURFACES_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTENSION_SURFACES 1
#else
#define YABCORE_EXTENSION_SURFACES 0
#endif
#if defined(CEF_YAB_DISCARD_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_DISCARD 1
#else
#define YABCORE_DISCARD 0
#endif
#if defined(CEF_YAB_NATIVE_PRINT_VERSION) && defined(CEF_YAB_NATIVE_PRINT_NOTIFY_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_PRINT 1
#else
#define YABCORE_NATIVE_PRINT 0
#endif
#if defined(CEF_YAB_WEBAUTHN_PROXY_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_WEBAUTHN_PROXY 1
#else
#define YABCORE_WEBAUTHN_PROXY 0
#endif
#if defined(CEF_YAB_GEOLOCATION_SOURCE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_GEOLOCATION_SOURCE 1
#else
#define YABCORE_GEOLOCATION_SOURCE 0
#endif
#if defined(CEF_YAB_EXTENSION_CONSENT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTENSION_CONSENT 1
#else
#define YABCORE_EXTENSION_CONSENT 0
#endif
#if defined(CEF_YAB_DISCARD_NOTIFY_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_DISCARD_NOTIFY 1
#else
#define YABCORE_DISCARD_NOTIFY 0
#endif
#if defined(CEF_YAB_TEXT_INPUT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_TEXT_INPUT 1
#else
#define YABCORE_TEXT_INPUT 0
#endif

// API presence is negotiated separately from the legacy text-state snapshot.
// Source60 has no such macro, so this route and capability remain unavailable.
#if defined(CEF_YAB_NATIVE_TEXT_FOCUS_VERSION) && CEF_YAB_NATIVE_TEXT_FOCUS_VERSION == 1 && YABCORE_TEXT_INPUT
#define YABCORE_NATIVE_TEXT_FOCUS_API 1
#else
#define YABCORE_NATIVE_TEXT_FOCUS_API 0
#endif
// Promotion requires the exact future SDK's actual native acceptance receipt.
// API shape/compilation alone must not enable a production capability.
#ifndef YABCORE_NATIVE_TEXT_FOCUS_ACCEPTED_VERSION
#define YABCORE_NATIVE_TEXT_FOCUS_ACCEPTED_VERSION 0
#endif
#define YABCORE_NATIVE_TEXT_FOCUS (YABCORE_NATIVE_TEXT_FOCUS_API && YABCORE_NATIVE_TEXT_FOCUS_ACCEPTED_VERSION == 1)

// Original native approval claims are a partial primitive, never switch commit.
#if defined(CEF_YAB_NATIVE_GROUP_APPROVAL_VERSION) && CEF_YAB_NATIVE_GROUP_APPROVAL_VERSION == 1 && defined(CEF_YAB_NATIVE_GROUP_OWNER_VERSION) && CEF_YAB_NATIVE_GROUP_OWNER_VERSION == 1 && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_GROUP_APPROVAL_API 1
#else
#define YABCORE_NATIVE_GROUP_APPROVAL_API 0
#endif
#ifndef YABCORE_NATIVE_GROUP_APPROVAL_ACCEPTED_VERSION
#define YABCORE_NATIVE_GROUP_APPROVAL_ACCEPTED_VERSION 0
#endif
#define YABCORE_NATIVE_GROUP_APPROVAL (YABCORE_NATIVE_GROUP_APPROVAL_API && YABCORE_NATIVE_GROUP_APPROVAL_ACCEPTED_VERSION == 1)
#ifndef YABCORE_NATIVE_GROUP_SNAPSHOT_ACCEPTED_VERSION
#define YABCORE_NATIVE_GROUP_SNAPSHOT_ACCEPTED_VERSION 0
#endif
#define YABCORE_NATIVE_GROUP_SNAPSHOTS (YABCORE_NATIVE_GROUP_APPROVAL && YABCORE_NATIVE_GROUP_SNAPSHOT_ACCEPTED_VERSION == 1)
#if YABCORE_NATIVE_GROUP_APPROVAL_API && defined(CEF_YAB_NATIVE_GROUP_SOURCES_VERSION) && CEF_YAB_NATIVE_GROUP_SOURCES_VERSION == 1
#define YABCORE_NATIVE_GROUP_SOURCES_API 1
#else
#define YABCORE_NATIVE_GROUP_SOURCES_API 0
#endif
#ifndef YABCORE_NATIVE_GROUP_SOURCES_ACCEPTED_VERSION
#define YABCORE_NATIVE_GROUP_SOURCES_ACCEPTED_VERSION 0
#endif
#define YABCORE_NATIVE_GROUP_SOURCES (YABCORE_NATIVE_GROUP_APPROVAL && YABCORE_NATIVE_GROUP_SOURCES_API && YABCORE_NATIVE_GROUP_SOURCES_ACCEPTED_VERSION == 1)


#if defined(CEF_YAB_VERIFIED_CRX_VERSION) && YABCORE_EXTENSION_CONSENT && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_VERIFIED_CRX 1
#else
#define YABCORE_VERIFIED_CRX 0
#endif

#if defined(CEF_YAB_EXTERNAL_TAB_GROUP_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_TAB_GROUP 1
#else
#define YABCORE_TAB_GROUP 0
#endif

#if defined(CEF_YAB_NATIVE_CLOSE_PREFLIGHT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_CLOSE_PREFLIGHT 1
#else
#define YABCORE_CLOSE_PREFLIGHT 0
#endif

#if defined(CEF_YAB_NATIVE_MEDIA_SESSION_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_MEDIA_SESSION 1
#else
#define YABCORE_NATIVE_MEDIA_SESSION 0
#endif

#if defined(CEF_YAB_NATIVE_CAPTURE_ACTIVITY_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_CAPTURE_ACTIVITY 1
#else
#define YABCORE_NATIVE_CAPTURE_ACTIVITY 0
#endif

#if defined(CEF_YAB_NATIVE_DISPLAY_SOURCE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_DISPLAY_SOURCE 1
#else
#define YABCORE_NATIVE_DISPLAY_SOURCE 0
#endif

#if defined(CEF_YAB_NATIVE_VIDEO_PIP_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_VIDEO_PIP 1
#else
#define YABCORE_NATIVE_VIDEO_PIP 0
#endif

#ifndef YABCORE_ENABLE_ORIGINAL_PDF
#define YABCORE_ENABLE_ORIGINAL_PDF 0
#endif
#if defined(CEF_YAB_ORIGINAL_PDF_VERSION) && CEF_YAB_ORIGINAL_PDF_VERSION == 1 && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_ORIGINAL_PDF_API 1
#else
#define YABCORE_ORIGINAL_PDF_API 0
#endif
#define YABCORE_ORIGINAL_PDF (YABCORE_ORIGINAL_PDF_API && YABCORE_ENABLE_ORIGINAL_PDF)
#ifndef YABCORE_ENABLE_ORIGINAL_PDF_PRESENCE
#define YABCORE_ENABLE_ORIGINAL_PDF_PRESENCE 0
#endif
#if defined(CEF_YAB_ORIGINAL_PDF_PRESENCE_VERSION) && CEF_YAB_ORIGINAL_PDF_PRESENCE_VERSION == 1 && defined(CEF_YAB_NATIVE_CAPTURE_ACTIVITY_VERSION) && CEF_YAB_NATIVE_CAPTURE_ACTIVITY_VERSION == 1 && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_ORIGINAL_PDF_PRESENCE_API 1
#else
#define YABCORE_ORIGINAL_PDF_PRESENCE_API 0
#endif
#define YABCORE_ORIGINAL_PDF_PRESENCE (YABCORE_ORIGINAL_PDF && YABCORE_ORIGINAL_PDF_PRESENCE_API && YABCORE_ENABLE_ORIGINAL_PDF_PRESENCE)


static bool NativeSwitchApprovalsAvailable();
static bool NativeGroupSourcesAvailable();
static bool NativeSnapshotsAvailable();
static NSDictionary* NativeHookCapabilities() {
  return @{@"nativeOriginalPDFPresence": @(YABCORE_ORIGINAL_PDF_PRESENCE),
           @"nativeOriginalPDFPresenceVersion": @(YABCORE_ORIGINAL_PDF_PRESENCE ? 1 : 0),
           @"nativeOriginalPDF": @(YABCORE_ORIGINAL_PDF),
           @"nativeOriginalPDFVersion": @(YABCORE_ORIGINAL_PDF ? 1 : 0),
           @"nativeOriginalCallerAuthenticated": @(original_caller::Ready()),
           @"nativeOriginalCallerVersion": @(original_caller::Ready() ? 1 : 0),
           @"nativeRemoteRead": @NO,
           @"nativeAudible": @(YABCORE_NATIVE_AUDIBLE),
           @"nativeMediaSession": @(YABCORE_NATIVE_MEDIA_SESSION),
           @"nativeCaptureActivity": @(YABCORE_NATIVE_CAPTURE_ACTIVITY),
           @"nativeDisplaySource": @(YABCORE_NATIVE_DISPLAY_SOURCE),
           @"nativeVideoPiP": @(YABCORE_NATIVE_VIDEO_PIP),
           @"externalTabGroup": @(YABCORE_TAB_GROUP),
           @"downloadProvenance": @(YABCORE_DOWNLOAD_PROVENANCE),
           @"externalFocus": @(YABCORE_EXTERNAL_FOCUS),
           @"nativeTextInput": @(YABCORE_TEXT_INPUT),
           @"nativeTextFocus": @(YABCORE_NATIVE_TEXT_FOCUS),
           @"nativeTextFocusVersion": @(YABCORE_NATIVE_TEXT_FOCUS ? 1 : 0),
           @"nativeGroupApprovals": @(YABCORE_NATIVE_GROUP_APPROVAL && NativeSwitchApprovalsAvailable()),
           @"nativeGroupApprovalVersion": @(YABCORE_NATIVE_GROUP_APPROVAL && NativeSwitchApprovalsAvailable() ? 1 : 0),
           @"nativeGroupOwnerVersion": @(YABCORE_NATIVE_GROUP_APPROVAL && NativeSwitchApprovalsAvailable() ? 1 : 0),
           @"nativeGroupSources": @(NativeGroupSourcesAvailable()),
           @"nativeGroupSourcesVersion": @(NativeGroupSourcesAvailable() ? 1 : 0),
           @"nativeGroupSnapshots": @(NativeSnapshotsAvailable()),
           @"nativeGroupSnapshotVersion": @(NativeSnapshotsAvailable() ? 1 : 0),
           @"nativeFullMutationFence": @NO,
           @"nativeFullStorageFence": @NO,
           @"nativeMixedWKSwitch": @NO,
           @"nativeAtomicSwitchCommit": @NO,
           @"backgroundColor": @(YABCORE_BACKGROUND_COLOR),
           @"selectMenu": @(YABCORE_SELECT_MENU),
           // profile.open's parent makes a private profile its space's
           // off-the-record side, where that space's extensions can run.
           @"privateExtensions": @(YABCORE_PRIVATE_EXTENSIONS != 0),
           @"extensionPopups": @(YABCORE_EXTENSION_HOOKS),
           @"extensionTabMetadata": @(YABCORE_EXTENSION_HOOKS),
           @"externalExtensionAction": @(YABCORE_EXTERNAL_ACTION),
           @"extensionCommands": @(YABCORE_EXTENSION_COMMAND != 0),
           @"extensionActionMenu": @(YABCORE_EXTENSION_SURFACES),
           @"extensionOmnibox": @(YABCORE_EXTENSION_SURFACES),
           @"sidePanelOptions": @(YABCORE_EXTENSION_SURFACES),
           @"nativeExternalPages": @(YABCORE_NATIVE_PAGE),
           @"nativeTabModel": @(YABCORE_NATIVE_TAB_MODEL),
           @"nativeDiscard": @(YABCORE_DISCARD),
           @"extensionConsent": @(YABCORE_EXTENSION_CONSENT != 0),
           // Chromium checks each WebAuthn request, then hands it to the
           // client (webauthn.request); no page script stands in for it.
           @"webauthnProxy": @(YABCORE_WEBAUTHN_PROXY),
           // The browser's location source is Yab's (patch 0120): the
           // client hands over macOS's answer and its fixes.
           @"geolocationSource": @(YABCORE_GEOLOCATION_SOURCE != 0),
           @"verifiedCrxInstall": @(YABCORE_VERIFIED_CRX),
           @"nativePrint": @(YABCORE_NATIVE_PRINT),
           @"nativeClosePreflight": @(YABCORE_CLOSE_PREFLIGHT),
           @"resizeAck": @(YABCORE_OWNCEF_SURFACES)};
}

// Copies a CEF value tree into Foundation objects for the JSON wire.
[[maybe_unused]] static ::id NativeValue(CefRefPtr<CefValue> value);
[[maybe_unused]] static NSDictionary* NativeDictionary(CefRefPtr<CefDictionaryValue> value) {
  if (!value) return @{};
  CefDictionaryValue::KeyList keys;
  value->GetKeys(keys);
  NSMutableDictionary* result = [NSMutableDictionary dictionary];
  for (const auto& key : keys) result[Str(key)] = NativeValue(value->GetValue(key));
  return result;
}
[[maybe_unused]] static ::id NativeValue(CefRefPtr<CefValue> value) {
  if (!value) return NSNull.null;
  switch (value->GetType()) {
    case VTYPE_BOOL: return @(value->GetBool());
    case VTYPE_INT: return @(value->GetInt());
    case VTYPE_DOUBLE: return @(value->GetDouble());
    case VTYPE_STRING: return Str(value->GetString());
    case VTYPE_DICTIONARY: return NativeDictionary(value->GetDictionary());
    case VTYPE_LIST: {
      auto list = value->GetList();
      NSMutableArray* result = [NSMutableArray array];
      for (size_t i = 0; list && i < list->GetSize(); ++i) [result addObject:NativeValue(list->GetValue(i))];
      return result;
    }
    default: return NSNull.null;
  }
}

#include "owncef_media.inc"
#include "owncef_capture.inc"
#include "owncef_pip.inc"

[[maybe_unused]] static void NativeAudible(Tab* tab, bool audible) {
  if (!tab || tab->audible == audible) return;
  tab->audible = audible;
  State(tab, @{@"audible": @(audible), @"audibleSource": @"native"});
}

// The page's CSS background color, so the client can fill area the page has
// not yet drawn while resizing (Chrome's own NSView does the same).
[[maybe_unused]] static void NativeBackground(Tab* tab, cef_color_t color, bool has) {
  if (!tab) return;
  NSString* hex = has && CefColorGetA(color) == 255
      ? [NSString stringWithFormat:@"#%02x%02x%02x", CefColorGetR(color), CefColorGetG(color), CefColorGetB(color)] : nil;
  if (hex == tab->backgroundColor || [hex isEqual:tab->backgroundColor]) return;
  tab->backgroundColor = hex;
  State(tab, @{@"backgroundColor": hex ?: (::id)NSNull.null});
}

#if YABCORE_NATIVE_PRINT
// A page asked to print (window.print, the PDF viewer). Chromium suspends the
// script until the request finishes, so a request that cannot reach the client
// is finished at once instead of leaving the page stuck.
static void NativePrintRequest(Tab* tab, CefRefPtr<CefDictionaryValue> request) {
  if (!request) return;
  std::string token = request->GetString("request").ToString();
  if (!tab || tab->internal || !tab->adopted || !hello || !tab->browser) {
    if (tab && tab->browser) {
      tab->browser->GetHost()->FinishNativePrint(token);
#if YABCORE_NATIVE_PRINT_SOURCE
      tab->browser->GetHost()->ReleaseNativePrintSource(token);
#endif
    }
    return;
  }
  Event(@"print.request", tab, NativeDictionary(request));
}
static void NativePrintWithdrawn(Tab* tab, const std::string& token) {
  if (tab) CancelNativePrintSource(*tab, token);
  if (tab) Event(@"print.withdrawn", tab, @{@"request": @(token.c_str())});
}
#endif

#if YABCORE_EXTENSION_CONSENT
// Extension install/permission/uninstall consent. Chrome asks before any side
// effect; the callback is retained until the client answers, the request is
// withdrawn or the session ends, and a dropped callback cancels.
struct Consent { CefRefPtr<CefExtensionConsentCallback> callback; std::string profile; std::string extension; };
static std::map<std::string, Consent> consents;
static void ClearConsents() { consents.clear(); }  // Releasing a callback cancels.
// Profile of a request: the originating tab's, else the persistent profile whose
// directory it names. A private (off the record) request without a tab has no
// identity the client can verify, so it is refused.
static NSString* ConsentProfile(Tab* tab, NSDictionary* request) {
  if (tab) return @(tab->profile.c_str());
  if ([request[@"offTheRecord"] boolValue]) return nil;
  NSString* path = request[@"profilePath"];
  if (![path isKindOfClass:NSString.class]) return nil;
  NSString* wanted = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  for (auto& [name, profile] : profiles) {
    if (profile.privateMode) continue;
    NSString* candidate = [dataRoot stringByAppendingFormat:@"/space-%s", name.c_str()];
    if ([candidate.stringByStandardizingPath.stringByResolvingSymlinksInPath isEqual:wanted]) return @(name.c_str());
  }
  return nil;
}
static void NativeConsentRequest(Tab* tab, CefRefPtr<CefDictionaryValue> request, CefRefPtr<CefExtensionConsentCallback> callback) {
  if (!callback) return;
  NSMutableDictionary* copy = [NativeDictionary(request) mutableCopy];
  std::string token = Key(copy[@"request"] ?: @""), extension = Key(copy[@"extensionId"] ?: @"");
  NSString* profile = ConsentProfile(tab, copy);
  // Fail closed: unknown identity or a duplicate token cancel. No count of
  // open questions: Chrome's install prompts have none, and an import of 20
  // extensions asks 20 at once (each goes when answered or withdrawn).
  if (!hello || token.empty() || extension.empty() || !profile || consents.count(token)) { callback->Respond(false); return; }
  consents[token] = {callback, Key(profile), extension};
  copy[@"profile"] = profile;
  [copy removeObjectForKey:@"profilePath"];
  if (tab && !tab->internal) copy[@"tab"] = @(tab->id.c_str());
  Event(@"extension.consent", nullptr, copy);
}
static void NativeConsentWithdrawn(const std::string& token) {
  if (consents.erase(token)) Event(@"extension.consent.withdrawn", nullptr, @{@"request": @(token.c_str())});
}
static bool ConsentReply(NSDictionary* p, NSString* request) {
  auto found = consents.find(Key(S(p, @"request") ?: @""));
  // A stale, duplicate or cross-profile answer has no effect.
  if (found == consents.end() || found->second.extension != Key(S(p, @"extension") ?: @"") || found->second.profile != Key(S(p, @"profile") ?: @"")) {
    Reply(request, nil, @"Unknown, stale or mismatched consent request"); return true;
  }
  auto callback = found->second.callback;
  consents.erase(found);
  bool accept = [p[@"accept"] boolValue];
  callback->Respond(accept);
  Reply(request, @{@"accepted": @(accept)});
  return true;
}
#else
static void ClearConsents() {}
#endif
#include "desktop_media.inc"

[[maybe_unused]] static void NativeDiscarded(Tab* tab, bool discarded) {
  if (!tab) return;
  fprintf(stderr, "YabCore discarded tab=%s value=%d (was %d)\n", tab->id.c_str(), (int)discarded, (int)tab->discarded);
  if (discarded) tab->shedding = false;
  if (tab->discarded == discarded) return;
  tab->discarded = discarded;
  if (discarded) { tab->rendererPID = 0; tab->rendererBorn = 0; }
  State(tab, @{@"discarded": @(discarded), @"rendererPID": @(tab->rendererPID)});
}

#if YABCORE_DISCARD
// Answers tab.discard once Chromium finished or refused the attempt. The tab
// may have closed meanwhile; success is the engine's own discarded state.
class DiscardDone : public CefCompletionCallback {
  std::string tab_;
  NSString* request_;
 public:
  DiscardDone(const std::string& tab, NSString* request) : tab_(tab), request_(request) {}
  void OnComplete() override {
    auto found = tabs.find(tab_);
    if (found == tabs.end() || !found->second.browser) { Reply(request_, nil, @"Tab closed"); return; }
    bool discarded = found->second.browser->GetHost()->IsPageDiscarded();
    NativeDiscarded(&found->second, discarded);
    Reply(request_, @{@"discarded": @(discarded)});
  }
  IMPLEMENT_REFCOUNTING(DiscardDone);
};
#endif

#if YABCORE_TEXT_INPUT
static void NativeTextState(Tab* tab, CefRefPtr<CefDictionaryValue> state) {
  if (!tab || !state) return;
  NSDictionary* copy = NativeDictionary(state);
  if (![copy[@"stateVersion"] isEqual:@1]) return;
  tab->textState = copy;
  if (!tab->internal) Event(@"page.textInput", tab, copy);
}
#endif

#if YABCORE_SELECT_MENU
// <select> popups of externally hosted tabs are drawn by the client. Only an
// adopted, visible page may present one; anything else is cancelled.
static bool NativeSelectOpen(Tab* tab, CefRefPtr<CefDictionaryValue> menu) {
  if (!tab || tab->internal || !tab->adopted || !tab->visible || !menu) return false;
  NSDictionary* copy = NativeDictionary(menu);
  tab->selectToken = [copy[@"token"] intValue];
  Event(@"select.open", tab, copy);
  return true;
}
static void NativeSelectClosed(Tab* tab, int token) {
  if (!tab || token != tab->selectToken) return;
  tab->selectToken = 0;
  Event(@"select.closed", tab, @{@"token": @(token)});
}
#endif

#if YABCORE_EXTENSION_HOOKS
// Extension action popups: identity is captured by Chromium when the action
// fires (owner page, extension, token). The popup's own compositor context is
// reported for the client to host beside its extension button; its native
// window stays transparent, and input reaches it through popup.input.
static std::map<std::string, std::pair<int, std::string>> extensionPopups;
// The native widget owns its queued keyboard events until AppKit dispatches
// them. An RPC-local Tab loses that queue before the local monitor runs.
static std::map<std::string, Tab> nativePopupInputs;
// Action widgets aren't CefBrowsers, so their cursors never reach
// CefDisplayHandler::OnCursorChange. Forward their original Cocoa updates.
static IMP nativePopupCursorOriginal = nullptr;
static void NativePopupCursorUpdate(NSView* view, SEL action, NSCursor* cursor) {
  ((void (*)(id, SEL, NSCursor*))nativePopupCursorOriginal)(view, action, cursor);
  // nil invalidates the concealed producer's cursor after an AppKit hit-test
  // rejects its own mouse event. It isn't an arrow chosen by the renderer;
  // the visible host owns mouse exit and resets its cursor there.
  if (!cursor) return;
  for (const auto& [token, entry] : extensionPopups) {
    if (!view.window || view.window.windowNumber != entry.first) continue;
    auto owner = tabs.find(entry.second);
    if (owner == tabs.end() || owner->second.internal) return;
    NSCursor* actual = cursor;
    NSData* picture = actual.image.TIFFRepresentation;
    if (!picture.length || picture.length >= 1 << 20) return;
    NSString* shape = actual == NSCursor.IBeamCursor ? @"text" :
        actual == NSCursor.pointingHandCursor ? @"pointer" : actual == NSCursor.arrowCursor ? @"arrow" : @"custom";
    Event(@"popup.cursor", &owner->second, @{@"token": @(token.c_str()), @"shape": shape,
        @"picture": [picture base64EncodedStringWithOptions:0],
        @"width": @(actual.image.size.width), @"height": @(actual.image.size.height),
        @"hotX": @(actual.hotSpot.x), @"hotY": @(actual.hotSpot.y)});
    return;
  }
}
static void InstallNativePopupCursorHook() {
  if (nativePopupCursorOriginal) return;
  Class view = NSClassFromString(@"RenderWidgetHostViewCocoa");
  SEL action = NSSelectorFromString(@"updateCursor:");
  Method method = view ? class_getInstanceMethod(view, action) : nullptr;
  if (!method) return;
  nativePopupCursorOriginal = method_getImplementation(method);
  class_replaceMethod(view, action, (IMP)NativePopupCursorUpdate, method_getTypeEncoding(method));
}
struct NativePopupLease {
  std::string owner, extension, ownerDocument, document;
  bool closedDelivered = false;
};
static std::map<std::string, NativePopupLease> nativePopupLeases;
// Ended popups, so a late frame or a second close of one is never taken for a
// new popup. Kept while their owner tab lives, at most kRetiredPopups: past
// that the oldest whose one native close was delivered goes. A fixed 16384
// here once closed admission for good, and no extension popup opened again
// until Yab quit.
static std::map<std::string, NativePopupLease> retiredNativePopups;
static std::deque<std::string> retiredNativePopupOrder;
static constexpr size_t kRetiredPopups = 4096;
static void TrimRetiredNativePopups() {
  for (auto i = retiredNativePopupOrder.begin(); retiredNativePopups.size() > kRetiredPopups && i != retiredNativePopupOrder.end();) {
    auto found = retiredNativePopups.find(*i);
    if (found == retiredNativePopups.end()) { i = retiredNativePopupOrder.erase(i); continue; }
    if (!found->second.closedDelivered) { ++i; continue; }
    retiredNativePopups.erase(found); i = retiredNativePopupOrder.erase(i);
  }
}
#if !defined(CEF_YAB_OPTIONS_CREATION_VERSION)
static std::map<std::string, int> popupOptionsAttempts;
#endif
static void RetireNativeExtensionPopup(const std::string& token) {
  auto active = nativePopupLeases.find(token);
  if (active != nativePopupLeases.end() && !retiredNativePopups.count(token)) {
    retiredNativePopups.emplace(token, active->second);
    retiredNativePopupOrder.push_back(token);
    TrimRetiredNativePopups();
  }
  nativePopupInputs.erase(token);
  extensionPopups.erase(token);
  nativePopupLeases.erase(token);
#if !defined(CEF_YAB_OPTIONS_CREATION_VERSION)
  popupOptionsAttempts.erase(token);
#endif
}
static void NativeExtensionOwnerClosed(Tab* owner) {
  if (!owner) return;
  std::vector<std::string> owned;
  for (const auto& [token, lease] : nativePopupLeases)
    if (lease.owner == owner->id) owned.push_back(token);
  for (const auto& token : owned) RetireNativeExtensionPopup(token);
  // A closed tab sends no popup event again: its ended popups go with it.
  for (auto i = retiredNativePopups.begin(); i != retiredNativePopups.end();)
    i = i->second.owner == owner->id ? retiredNativePopups.erase(i) : std::next(i);
  retiredNativePopupOrder.erase(std::remove_if(retiredNativePopupOrder.begin(), retiredNativePopupOrder.end(),
      [](const std::string& token) { return !retiredNativePopups.count(token); }), retiredNativePopupOrder.end());
}
static void Input(Tab& tab, NSDictionary* p, NSString* request, bool nativePopup);
// Test worlds only: every step of a popup, with its producer window.
static void PopupTrace(NSString* line) {
  static const bool on = getenv("YAB_PROBE") && *getenv("YAB_PROBE");
  if (!on) return;
  fprintf(stderr, "yabcore popup %.3f: %s\n", NSProcessInfo.processInfo.systemUptime, line.UTF8String);
}
static NSString* PopupWindowTrace(int number) {
  NSWindow* w = number > 0 ? [NSApp windowWithWindowNumber:number] : nil;
  if (!w) return [NSString stringWithFormat:@"window %d absent", number];
  return [NSString stringWithFormat:@"window %d frame %@ alpha %.2f visible %d occlusion %lu key %d screen %@",
          number, NSStringFromRect(w.frame), w.alphaValue, w.visible, (unsigned long)w.occlusionState, w.keyWindow,
          NSStringFromRect(w.screen.frame)];
}
#if !defined(CEF_YAB_OPTIONS_CREATION_VERSION)
// Original Chrome popup WebContents may have no CefRenderProcessHandler.
// Install the same compatibility method only after a native popup lease,
// and only in that extension and the owner's exact browser context.
static void NativePopupOptions(Tab& owner, const std::string& token, const std::string& extension) {
  if (!ExtensionValidID(@(extension.c_str()))) return;
  auto& attempts = popupOptionsAttempts[token];
  if (attempts >= 3) return;
  ++attempts;
  const auto id = owner.id;
  ExtensionCDP(owner, @"Target.getTargetInfo", @{}, [id, token, extension](NSDictionary* own, NSString* error) {
    auto t = tabs.find(id);
    auto lease = nativePopupLeases.find(token);
    NSString* context = own[@"targetInfo"][@"browserContextId"];
    if (error || t == tabs.end() || !context || lease == nativePopupLeases.end() ||
        lease->second.owner != id || lease->second.extension != extension) return;
    ExtensionCDP(t->second, @"Target.getTargets", @{}, [id, token, extension, context](NSDictionary* targets, NSString* error) {
      auto t = tabs.find(id);
      auto lease = nativePopupLeases.find(token);
      if (error || t == tabs.end() || lease == nativePopupLeases.end() || lease->second.owner != id) return;
      NSString* prefix = [NSString stringWithFormat:@"chrome-extension://%s/", extension.c_str()];
      for (NSDictionary* target in targets[@"targetInfos"]) {
        if (![target[@"type"] isEqual:@"page"] || ![context isEqual:target[@"browserContextId"]] ||
            ![S(target, @"url") hasPrefix:prefix]) continue;
        ExtensionCDP(t->second, @"Target.attachToTarget", @{@"targetId":target[@"targetId"], @"flatten":@NO},
          [id, token, extension](NSDictionary* attached, NSString* error) {
            auto t = tabs.find(id);
            NSString* session = S(attached, @"sessionId");
            if (error || t == tabs.end() || !session.length) return;
            auto detach = [id, session]() {
              auto t = tabs.find(id);
              if (t != tabs.end()) ExtensionCDP(t->second, @"Target.detachFromTarget", @{@"sessionId":session}, Ignore);
              ExtensionForgetSession(Key(session), @"Popup options inspection ended");
            };
            auto lease = nativePopupLeases.find(token);
            if (lease == nativePopupLeases.end() || lease->second.owner != id || lease->second.extension != extension) { detach(); return; }
            std::string key = "popup-options:" + token + ":" + Key(session);
            extensionWorkers[key] = {id, extension, Key(session)};
            NSString* expression = [NSString stringWithFormat:
              @"(()=>{if(globalThis.chrome?.runtime?.id!=='%s')return false;%s;return !!chrome.runtime.openOptionsPage?.__yabOptionsReceipt})()",
              extension.c_str(), yab_extension_options::kInstall];
            ExtensionNested(t->second, session, @"Runtime.evaluate", @{@"expression":expression, @"returnByValue":@YES},
              [detach](NSDictionary*, NSString*) { detach(); });
          });
      }
    });
  });
}
#endif
static void NativeExtensionPopup(Tab* owner, CefRefPtr<CefDictionaryValue> popup) {
  if (!owner || !popup) return;
  NSMutableDictionary* copy = [NativeDictionary(popup) mutableCopy];
  PopupTrace([NSString stringWithFormat:@"event %@ token %@ closedReason %@ context %@ pixels %@x%@ scale %@ %@ retired %d",
              copy[@"state"], S(copy, @"token"), copy[@"closedReason"], copy[@"contextId"], copy[@"pixelWidth"], copy[@"pixelHeight"],
              copy[@"scale"], PopupWindowTrace([copy[@"windowNumber"] intValue]),
              (int)retiredNativePopups.count(Key(S(copy, @"token") ?: @""))]);
  std::string token = Key(S(copy, @"token") ?: @"");
  std::string extension = Key(S(copy, @"extensionId") ?: @"");
  NSString* state = S(copy, @"state");
  const bool closed = [state isEqual:@"closed"];
  if (token.empty() || token.size() > 128 || extension.empty() || extension.size() > 128 ||
      (!closed && ![state isEqual:@"shown"] && ![state isEqual:@"frame"])) return;
  NativePopupLease source{owner->id, extension, "", "", false};
  if ([copy[@"nativeLeaseVersion"] intValue] == 1) {
    source.ownerDocument = Key(S(copy, @"ownerDocument") ?: @"");
    source.document = Key(S(copy, @"document") ?: @"");
    if (source.ownerDocument.empty() || source.document.empty() ||
        source.ownerDocument.size() > 128 || source.document.size() > 128) return;
  }
  auto matches = [&](const NativePopupLease& original) {
    return original.owner == source.owner && original.extension == source.extension &&
           original.ownerDocument == source.ownerDocument && original.document == source.document;
  };
  copy[@"profile"] = @(owner->profile.c_str());
  auto retired = retiredNativePopups.find(token);
  if (retired != retiredNativePopups.end()) {
    if (!closed || !matches(retired->second) || retired->second.closedDelivered) return;
    // A helper close request retires before native reentry; still deliver its
    // one ORIGINAL native terminal callback, never later frames or duplicates.
    retired->second.closedDelivered = true;
    if (!owner->internal) Event(@"popup.layer", owner, copy);
    return;
  }
  auto active = nativePopupLeases.find(token);
  if (active != nativePopupLeases.end() && !matches(active->second)) return;
  if (closed) {
    if (active == nativePopupLeases.end()) nativePopupLeases.emplace(token, source);
    RetireNativeExtensionPopup(token);
    auto terminal = retiredNativePopups.find(token);
    if (terminal != retiredNativePopups.end()) terminal->second.closedDelivered = true;
    if (!owner->internal) Event(@"popup.layer", owner, copy);
    return;
  }
  int number = [copy[@"windowNumber"] intValue];
  // No count of open popups: each is its owner tab's and goes when it
  // closes or its tab does. Chrome keeps one per window by closing the last.
  if (number <= 0) return;
  auto originalWindow = extensionPopups.find(token);
  if (originalWindow != extensionPopups.end() &&
      (originalWindow->second.first != number || originalWindow->second.second != owner->id)) return;
  nativePopupLeases.emplace(token, source);
  extensionPopups[token] = {number, owner->id};
  InstallNativePopupCursorHook();
  CefRefPtr<CefBrowser> ownerBrowser = owner->browser;
  if (NSWindow* window = [NSApp windowWithWindowNumber:number]) Conceal(window);
  // NSWindow changes can synchronously reenter native close/navigation and the
  // helper transport. Revalidate the lease AFTER that effect before its event.
  owner = ownerBrowser ? Find(ownerBrowser) : nullptr;
  auto current = nativePopupLeases.find(token);
  if (!owner || owner->id != source.owner || retiredNativePopups.count(token) ||
      current == nativePopupLeases.end() || !matches(current->second)) return;
#if !defined(CEF_YAB_OPTIONS_CREATION_VERSION)
  NativePopupOptions(*owner, token, extension);
#endif
  if (!owner->internal) Event(@"popup.layer", owner, copy);
}
// What Yab's own input method needs of a popup's focused field, as a page's
// native text state gives it: whether it takes text, and where its caret is.
// Chrome's view hands out its input context only for an editable element
// that is no password (RenderWidgetHostViewCocoa -inputContext), which is
// Chrome's own test for composing. The caret is in the popup's points from
// its top left, from the view's cached first rect (no renderer round trip).
static std::map<std::string, std::string> popupTextStates;
static NSDictionary* PopupTextState(NSWindow* window) {
  NSView* content = window.contentView;
  NSView* view = FindView(content.superview ?: content, @"RenderWidgetHostViewCocoa");
  if (!view || ![view conformsToProtocol:@protocol(NSTextInputClient)]) return nil;
  // Chrome's -inputContext test itself, read from the view's own state:
  // AppKit's -[NSView inputContext] under it can be nil for a producer
  // window that is never shown, which would read every field as none.
  bool editable;
  NSMutableDictionary* state = [NSMutableDictionary dictionary];
  static SEL const typeGetter = NSSelectorFromString(@"textInputType");
  static SEL const flagsGetter = NSSelectorFromString(@"textInputFlags");
  if ([view respondsToSelector:typeGetter] && [view respondsToSelector:flagsGetter]) {
    int type = ((int (*)(id, SEL))objc_msgSend)(view, typeGetter);
    int flags = ((int (*)(id, SEL))objc_msgSend)(view, flagsGetter);
    const int kNone = 0, kPassword = 2, kHasBeenPassword = 1 << 12, kHasBeenCustomPassword = 1 << 14;
    editable = type != kNone && type != kPassword && !(flags & (kHasBeenPassword | kHasBeenCustomPassword));
    state[@"inputType"] = @(type);
  } else {
    editable = view.inputContext != nil;
  }
  state[@"editable"] = @(editable);
  if (!editable) return state;
  id<NSTextInputClient> client = (id<NSTextInputClient>)view;
  NSRange range = [client hasMarkedText] ? [client markedRange] : [client selectedRange];
  if (range.location == NSNotFound) return state;
  NSRect screen = [client firstRectForCharacterRange:NSMakeRange(range.location, 0) actualRange:nullptr];
  if (NSIsEmptyRect(screen) && screen.size.height <= 0) return state;
  NSRect local = [view convertRect:[window convertRectFromScreen:screen] fromView:nil];
  double top = view.isFlipped ? NSMinY(local) : NSHeight(view.bounds) - NSMaxY(local);
  if (!std::isfinite(NSMinX(local)) || !std::isfinite(top) || !std::isfinite(NSHeight(local))) return state;
  state[@"caret"] = @{@"x": @(NSMinX(local)), @"y": @(top), @"width": @(MAX(0.0, NSWidth(local))),
                      @"height": @(NSHeight(local))};
  return state;
}
// Sent when it changes: from the poll while a popup is up, and after each
// input to it (a click into a field, a key that moved the caret).
static void PublishPopupTextStates() {
  for (const auto& [token, entry] : extensionPopups) {
    auto owner = tabs.find(entry.second);
    NSWindow* window = owner == tabs.end() || owner->second.internal ? nil : [NSApp windowWithWindowNumber:entry.first];
    NSDictionary* state = window ? PopupTextState(window) : nil;
    if (!state) continue;
    NSMutableDictionary* row = [state mutableCopy];
    row[@"token"] = @(token.c_str());
    NSString* encoded = JSON(row);
    std::string key = encoded.UTF8String ?: "";
    auto last = popupTextStates.find(token);
    if (last != popupTextStates.end() && last->second == key) continue;
    popupTextStates[token] = key;
    PopupTrace([@"text input " stringByAppendingString:encoded]);
    Event(@"popup.textInput", &owner->second, row);
  }
  for (auto i = popupTextStates.begin(); i != popupTextStates.end();)
    i = extensionPopups.count(i->first) ? std::next(i) : popupTextStates.erase(i);
}
#if defined(CEF_YAB_EXTENSION_SIDE_PANEL_VERSION)
// The panel page of a valid extension id, in that extension's own origin;
// nil for anything else. Chrome resolved the tab's options already.
static NSDictionary* ExtensionSidePanelRequest(NSDictionary* info) {
  NSString* extension = S(info, @"extensionId");
  NSString* spec = S(info, @"panelURL");
  if (!ExtensionValidID(extension) || spec.length == 0 || spec.length > 8192) return nil;
  NSURL* url = [NSURL URLWithString:spec];
  if (!url || ![url.scheme isEqual:@"chrome-extension"] || ![url.host isEqual:extension] ||
      url.user || url.password || url.port) return nil;
  return @{@"extensionId": extension, @"url": spec};
}
#endif
#if YABCORE_EXTENSION_SURFACES
// chrome.sidePanel.setOptions as Chromium kept it (patch 0124): a valid
// extension, Chrome's tab id (-1, the global options), an optional path of
// bounded length and an optional switch. Nil for anything else.
static NSDictionary* ExtensionPanelOptionsEvent(NSDictionary* info) {
  NSString* extension = S(info, @"extensionId");
  if (!ExtensionValidID(extension) || ![info[@"tabId"] isKindOfClass:NSNumber.class]) return nil;
  NSMutableDictionary* event = [@{@"extensionId": extension, @"tabId": @([info[@"tabId"] intValue])} mutableCopy];
  if (info[@"path"]) {
    if (![info[@"path"] isKindOfClass:NSString.class] || [info[@"path"] length] > 8192) return nil;
    event[@"path"] = info[@"path"];
  }
  if (info[@"enabled"]) {
    if (![info[@"enabled"] isKindOfClass:NSNumber.class]) return nil;
    event[@"enabled"] = @([info[@"enabled"] boolValue]);
  }
  return event;
}
// An extension's omnibox suggestions for the words Yab's field last sent
// (patch 0124): at most 64 rows of bounded content and description.
static NSDictionary* ExtensionOmniboxSuggestionsEvent(NSDictionary* info) {
  NSString* extension = S(info, @"extensionId");
  if (!ExtensionValidID(extension) || ![info[@"requestId"] isKindOfClass:NSNumber.class]) return nil;
  NSArray* list = [info[@"suggestions"] isKindOfClass:NSArray.class] ? info[@"suggestions"] : @[];
  NSMutableArray* rows = [NSMutableArray array];
  for (id value in list) {
    if (rows.count >= 64) break;
    if (![value isKindOfClass:NSDictionary.class]) continue;
    NSString* content = S(value, @"content"), *description = S(value, @"description");
    if (content.length > 4096 || description.length > 4096) continue;
    [rows addObject:@{@"content": content, @"description": description}];
  }
  return @{@"extensionId": extension, @"requestId": @([info[@"requestId"] intValue]), @"suggestions": rows};
}
#endif
static void NativeExtensionTab(Tab* tab, CefRefPtr<CefDictionaryValue> info) {
  if (!tab || !info) return;
  NSMutableDictionary* copy = [NativeDictionary(info) mutableCopy];
  if ([copy[@"requestedKind"] isEqual:@"tabOperation"]) {
    copy[@"profile"] = @(tab->profile.c_str());
    if (ExtensionValidID(S(copy, @"extensionId")) && [copy[@"operation"] intValue] > 0)
      Event(@"extension.tabOperation", tab, copy);
    return;
  }
  // chrome.tabs.update({active:true}): Yab selects, and lists the window again.
  if ([copy[@"requestedKind"] isEqual:@"activate"]) { Event(@"tab.extensionActivate", tab, @{}); return; }
  // chrome.windows.update({focused:true}) on a window Yab shows, named by
  // this page (patch 0119): Yab brings that window to the front. An SDK
  // without 0119 never asks.
  if ([copy[@"requestedKind"] isEqual:@"focus"]) { Event(@"tab.extensionFocus", tab, @{}); return; }
#if defined(CEF_YAB_EXTENSION_SIDE_PANEL_VERSION)
  // chrome.sidePanel.open() for this page (patch 0095): Chrome's own panel
  // would open in the concealed Browser, so Yab shows this exact page of the
  // extension in its column. Never a creation receipt, never another origin.
  if ([copy[@"requestedKind"] isEqual:@"sidePanel"]) {
    if (NSDictionary* panel = ExtensionSidePanelRequest(copy); panel && !tab->internal)
      Event(@"extension.sidePanelOpen", tab, panel);
    return;
  }
#endif
#if YABCORE_EXTENSION_SURFACES
  // chrome.sidePanel.setOptions (patch 0124): Yab's panel for that tab, or
  // the window's, follows. Never a creation receipt.
  if ([copy[@"requestedKind"] isEqual:@"sidePanelOptions"]) {
    if (NSDictionary* event = ExtensionPanelOptionsEvent(copy); event && !tab->internal)
      Event(@"extension.sidePanelOptions", tab, event);
    return;
  }
  // omnibox.suggest's rows for Yab's field (patch 0124).
  if ([copy[@"requestedKind"] isEqual:@"omniboxSuggestions"]) {
    if (NSDictionary* event = ExtensionOmniboxSuggestionsEvent(copy); event && !tab->internal)
      Event(@"extension.omniboxSuggestions", tab, event);
    return;
  }
#endif
  auto opener = browserTabs.find([copy[@"openerBrowserId"] intValue]);
  copy[@"openerTab"] = opener == browserTabs.end() ? (::id)NSNull.null : @(opener->second.c_str());
  [copy removeObjectForKey:@"openerBrowserId"];
  // The active page of the window Chrome chose (patch 0041). A worker's
  // chrome.tabs.create has no opener: this is all that places its tab.
  auto owner = browserTabs.find([copy[@"ownerBrowserId"] intValue]);
  copy[@"ownerTab"] = owner == browserTabs.end() ? (::id)NSNull.null : @(owner->second.c_str());
  [copy removeObjectForKey:@"ownerBrowserId"];
  // The native hook runs after Attach's creation event. Retain the receipt
  // until tab.adopt answers so Swift installs the final metadata atomically,
  // even when its first tab.created event preceded this callback.
  tab->extensionCreation = copy;
  tab->foreground = [copy[@"active"] boolValue];
  tab->opener = opener == browserTabs.end() ? "" : opener->second;
  PublishNativeCreation(*tab);
  Event(@"tab.extensionCreated", tab, copy);
}
static void ApplyEarlyExtensionReceipt(Tab& tab, int browser) {
  auto early = earlyExtensionReceipts.find(browser);
  if (early == earlyExtensionReceipts.end()) return;
  auto info = early->second;
  earlyExtensionReceipts.erase(early);
  NativeExtensionTab(&tab, info);
}
#else
static void ApplyEarlyExtensionReceipt(Tab&, int) {}
static void PublishPopupTextStates() {}
#endif

// Yab's window as extensions see it: its pages in order, one active. Pages
// not listed (management, side panel) are not tabs to them.
static void TabsGroupRequest(NSDictionary* p, NSString* request) {
#if YABCORE_TAB_GROUP
  NSArray* list = [p[@"tabs"] isKindOfClass:NSArray.class] ? p[@"tabs"] : @[];
  NSString* active = S(p, @"active");
  CefRefPtr<CefBrowser> lead;
  for (id value in list) {
    if (![value isKindOfClass:NSString.class]) continue;
    auto found = tabs.find(Key(value));
    if (found != tabs.end() && found->second.browser && !found->second.closing) { lead = found->second.browser; break; }
  }
  int index = 0, refused = 0;
  if (lead) for (id value in list) {
    if (![value isKindOfClass:NSString.class]) continue;
    auto found = tabs.find(Key(value));
    if (found == tabs.end() || !found->second.browser || found->second.closing) continue;
#if defined(CEF_YAB_EMBEDDED_TAB_OPERATIONS_VERSION)
    NSDictionary* groups = [p[@"groups"] isKindOfClass:NSDictionary.class] ? p[@"groups"] : @{};
    auto state = CefDictionaryValue::Create();
    state->SetString("windowKey", Key(S(p, @"windowKey")));
    state->SetInt("index", index); state->SetBool("active", [active isEqual:value]);
    state->SetInt("groupId", groups[value] ? [groups[value] intValue] : -1);
    NSDictionary* pins = [p[@"pinned"] isKindOfClass:NSDictionary.class] ? p[@"pinned"] : @{};
    state->SetBool("pinned", [pins[value] boolValue]);
    NSDictionary* openers = [p[@"openers"] isKindOfClass:NSDictionary.class] ? p[@"openers"] : @{};
    auto opener = tabs.find(Key(S(openers, value)));
    auto identity = opener != tabs.end() && opener->second.profile == found->second.profile && opener->second.browser
        ? opener->second.browser->GetHost()->GetExternalPageState() : nullptr;
    state->SetInt("openerTabId", identity ? identity->GetInt("extensionTabId") : -1);
    if (found->second.browser->GetHost()->SetExternalTabState(state)) index++;
    else refused++;
#else
    if (!found->second.browser->GetHost()->SetExternalTabGroup(lead, index, [active isEqual:value])) refused++;
    else index++;
#endif
  }
  Reply(request, @{@"listed": @(index), @"refused": @(refused)});
#else
  (void)p;
  Reply(request, nil, @"Native tab groups are unavailable in this CEF build");
#endif
}

// Native provenance for download.open. Unavailable fields are reported as
// such; a recent local input time is never substituted for a user gesture.
static NSDictionary* DownloadProvenance(CefRefPtr<CefDownloadItem> item) {
#if YABCORE_DOWNLOAD_PROVENANCE
  NSString* initiator = Str(item->GetRequestInitiator());
  NSString* page = Str(item->GetTabURL());
  return @{@"provenance": @"native", @"userGesture": @(item->HasUserGesture()),
           @"initiator": initiator.length ? initiator : (::id)NSNull.null,
           @"tabURL": page.length ? page : (::id)NSNull.null,
           @"canResume": @(item->CanResume())};
#else
  (void)item;
  return @{@"provenance": @"unavailable"};
#endif
}

// tab.focus delegates key status for an externally hosted producer. The
// caller owns the real key window and must clear focus on hide or key loss.
#if YABCORE_VERIFIED_CRX
class VerifiedCrxDone final : public CefExtensionInstallCallback {
 public:
  VerifiedCrxDone(NSString* request, std::string profile, std::string expected)
      : request_(request), profile_(std::move(profile)), expected_(std::move(expected)) {}
  void OnComplete(CefRefPtr<CefDictionaryValue> native) override {
    if (done_) return;
    done_ = true;
    NSDictionary* result = NativeDictionary(native);
    NSString* status = S(result, @"status");
    if (![@[@"installed", @"cancelled", @"error"] containsObject:status] ||
        ![S(result, @"extensionId") isEqual:@(expected_.c_str())] ||
        ([status isEqual:@"installed"] && !S(result, @"version").length)) {
      Reply(request_, nil, @"Invalid native installer completion"); return;
    }
    NSMutableDictionary* copy = [result mutableCopy]; copy[@"profile"] = @(profile_.c_str());
    Reply(request_, copy);
  }
 private:
  NSString* request_;
  std::string profile_, expected_;
  bool done_ = false;
  IMPLEMENT_REFCOUNTING(VerifiedCrxDone);
};
#endif

static bool NativeHookRequest(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  if (NativePiPRequest(t, method, p, request)) return true;
  if (NativeCaptureRequest(t, method, p, request)) return true;
  if (NativeMediaRequest(t, method, p, request)) return true;
  if ([method isEqual:@"extension.installCrx"]) {
#if YABCORE_VERIFIED_CRX
    NSString* path = S(p, @"path"), *expected = S(p, @"extension");
    if (!t.internal || !t.browser || !t.browser->GetMainFrame() ||
        t.browser->GetMainFrame()->GetURL() != "chrome://extensions/" ||
        profiles.at(t.profile).privateMode ||
        (p[@"profile"] && ![S(p, @"profile") isEqual:@(t.profile.c_str())])) {
      Reply(request, nil, @"Verified installation requires this profile's native management owner"); return true;
    }
    NSData* bytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    std::string file(bytes ? static_cast<const char*>(bytes.bytes) : "", bytes.length);
    const std::string extension = Key(expected);
    if (![path isAbsolutePath] || file.find('\0') != std::string::npos ||
        extension.size() != 32 || expected.length != 32 ||
        extension.find_first_not_of("abcdefghijklmnop") != std::string::npos) {
      Reply(request, nil, @"Expected an original absolute CRX path and extension ID"); return true;
    }
    requests[Key(request)] = Now() + 240;
    auto callback = new VerifiedCrxDone(request, t.profile, extension);
    if (!t.browser->GetHost()->GetRequestContext()->InstallVerifiedExtensionCrx(
          t.browser, file, extension, callback))
      Reply(request, nil, @"Native verified installer refused the request");
#else
    Reply(request, nil, @"Verified CRX installation is unavailable in this SDK/API mode");
#endif
    return true;
  }

  if ([method isEqual:@"tab.focus"]) {
#if YABCORE_EXTERNAL_FOCUS
    if (!t.externallyHosted || (!t.externalPage && (!t.window || !t.view))) { Reply(request, nil, @"External focus requires an externally hosted tab"); return true; }
    bool focused = [p[@"focused"] boolValue];
    if (focused && !t.visible) { Reply(request, nil, @"Cannot focus a hidden tab"); return true; }
    bool accepted = false;
#if YABCORE_NATIVE_PAGE
    if (t.externalPage) accepted = t.browser && t.browser->GetHost()->SetExternalPageFocus(focused);
    else
#endif
    accepted = t.window->SetExternalFocus(t.view, focused);
    if (!accepted) { Reply(request, nil, @"CEF refused external focus"); return true; }
    t.focused = focused;
    AccessibilityFocused(t, focused);
    Reply(request, @{@"focused": @(focused)});
#else
    (void)t; (void)p;
    Reply(request, nil, @"External focus is unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"select.reply"]) {
#if YABCORE_SELECT_MENU
    int token = [p[@"token"] intValue], index = p[@"index"] ? [p[@"index"] intValue] : -1;
    if (!token || token != t.selectToken || (!t.externalPage && (!t.window || !t.view))) { Reply(request, nil, @"Unknown or closed select menu"); return true; }
    t.selectToken = 0;
    bool accepted = false;
#if YABCORE_NATIVE_PAGE
    if (t.externalPage) accepted = t.browser && t.browser->GetHost()->ReplyExternalPageSelect(token, index);
    else
#endif
    accepted = t.window->ReplyExternalSelect(t.view, token, index);
    if (!accepted) { Reply(request, nil, @"CEF refused the select reply"); return true; }
    Reply(request, @{@"token": @(token), @"index": @(index)});
#else
    Reply(request, nil, @"Client-drawn select menus are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"extension.actionMenu"] || [method isEqual:@"extension.actionMenu.run"]) {
    // The extension's own rows of its button's menu, as Chromium lists them,
    // and the one a person chose there (patch 0124).
#if YABCORE_EXTENSION_SURFACES
    NSString* extension = S(p, @"extension");
    if (!t.browser || t.internal || !t.adopted || !ExtensionValidID(extension)) {
      Reply(request, nil, @"An action menu needs an enabled extension and an adopted page"); return true;
    }
    if ([method isEqual:@"extension.actionMenu"]) {
      CefRefPtr<CefListValue> rows = t.browser->GetHost()->GetExtensionActionMenu(Key(extension));
      if (!rows) { Reply(request, nil, @"Chrome has no action menu for this extension here"); return true; }
      NSMutableArray* items = [NSMutableArray array];
      for (size_t i = 0; i < rows->GetSize(); ++i) [items addObject:NativeValue(rows->GetValue(i))];
      Reply(request, @{@"items": items});
      return true;
    }
    NSString* item = S(p, @"item");
    if (!t.visible || !item.length || item.length > 1024) {
      Reply(request, nil, @"An action menu item needs its id and a visible page"); return true;
    }
    bool ran = t.browser->GetHost()->RunExtensionActionMenuItem(Key(extension), Key(item));
    Reply(request, ran ? @{@"ran": @YES} : nil, ran ? nil : @"Chrome refused the action menu item");
#else
    Reply(request, nil, @"Extension action menus are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"extension.omnibox"]) {
    // Yab's field in an extension's keyword, as Chromium's omnibox tells the
    // extension (patch 0124); suggestions come back as
    // extension.omniboxSuggestions on this page.
#if YABCORE_EXTENSION_SURFACES
    NSString* extension = S(p, @"extension"), *event = S(p, @"event"), *text = S(p, @"text");
    NSString* disposition = p[@"disposition"] ? S(p, @"disposition") : @"currentTab";
    if (!t.browser || t.internal || !t.adopted || !ExtensionValidID(extension) ||
        ![@[@"started", @"changed", @"entered", @"cancelled"] containsObject:event] || text.length > 4096 ||
        ![@[@"currentTab", @"newForegroundTab", @"newBackgroundTab"] containsObject:disposition] ||
        (p[@"requestId"] && ![p[@"requestId"] isKindOfClass:NSNumber.class]) ||
        ([event isEqual:@"entered"] && !t.visible)) {
      Reply(request, nil, @"An omnibox event needs an extension with a keyword, a known event and a page"); return true;
    }
    CefRefPtr<CefDictionaryValue> input = CefDictionaryValue::Create();
    input->SetString("event", Key(event));
    input->SetString("text", Key(text));
    input->SetInt("requestId", [p[@"requestId"] intValue]);
    input->SetString("disposition", Key(disposition));
    CefRefPtr<CefDictionaryValue> answer = t.browser->GetHost()->SendExtensionOmniboxInput(Key(extension), input);
    if (!answer) { Reply(request, nil, @"Chrome refused the omnibox event"); return true; }
    Reply(request, NativeDictionary(answer));
#else
    Reply(request, nil, @"Extension omnibox keywords are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"extension.action.open"]) {
#if YABCORE_EXTERNAL_ACTION
    NSString* extension = S(p, @"extension");
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet];
    if (!t.browser || t.internal || !t.adopted || !t.visible || !t.externallyHosted ||
        extension.length != 32 || [extension rangeOfCharacterFromSet:invalid].location != NSNotFound) {
      Reply(request, nil, @"Action requires an enabled extension and a visible externally hosted owner"); return true;
    }
    NSDictionary* anchor = [p[@"anchor"] isKindOfClass:NSDictionary.class] ? p[@"anchor"] : @{};
    double x = [anchor[@"x"] doubleValue], y = [anchor[@"y"] doubleValue];
    double width = [anchor[@"width"] doubleValue], height = [anchor[@"height"] doubleValue];
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
        fabs(x) > 100000 || fabs(y) > 100000 || width < 0 || height < 0 || width > 16384 || height > 16384) {
      Reply(request, nil, @"Invalid action anchor"); return true;
    }
    bool opened = t.browser->GetHost()->OpenExtensionAction(Key(extension), CefRect(x, y, width, height));
    Reply(request, opened ? @{@"opened": @YES} : nil, opened ? nil : @"Chrome refused the external action");
#else
    Reply(request, nil, @"External extension actions are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"extension.command.run"]) {
    // A key the person pressed (or Yab's own equivalent, a ⌘T alias) for an
    // extension's named command, on the page in front. Action commands go
    // through extension.action.open, as a press of the button does.
#if YABCORE_EXTENSION_COMMAND
    NSString* extension = S(p, @"extension"), *command = S(p, @"command");
    if (!t.browser || t.internal || !t.adopted || !t.visible || !ExtensionValidID(extension) ||
        !command.length || command.length > 256) {
      Reply(request, nil, @"A command needs an enabled extension's command and a visible page"); return true;
    }
    bool ran = t.browser->GetHost()->RunExtensionCommand(Key(extension), Key(command));
    Reply(request, ran ? @{@"ran": @YES} : nil, ran ? nil : @"Chrome refused the extension command");
#else
    Reply(request, nil, @"Extension commands are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"popup.input"] || [method isEqual:@"popup.close"] || [method isEqual:@"popup.focus"] || [method isEqual:@"popup.anchor"]) {
#if YABCORE_EXTENSION_HOOKS
    auto popup = extensionPopups.find(Key(S(p, @"token") ?: @""));
    // The token names the popup; only the tab it was opened for may drive it.
    NSWindow* window = popup == extensionPopups.end() || popup->second.second != t.id ? nil : [NSApp windowWithWindowNumber:popup->second.first];
    PopupTrace([NSString stringWithFormat:@"control %@ kind %@ token %@ known %d retired %d window %d", method, p[@"kind"], S(p, @"token"),
                popup != extensionPopups.end(), (int)retiredNativePopups.count(Key(S(p, @"token") ?: @"")), window != nil]);
    if (!window) { Reply(request, nil, @"Unknown or closed extension popup"); return true; }
#if YABCORE_EXTERNAL_ACTION
    NSDictionary* anchor = [p[@"anchor"] isKindOfClass:NSDictionary.class] ? p[@"anchor"] : @{};
    double x = [anchor[@"x"] doubleValue], y = [anchor[@"y"] doubleValue];
    double width = [anchor[@"width"] doubleValue], height = [anchor[@"height"] doubleValue];
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
        fabs(x) > 100000 || fabs(y) > 100000 || width < 0 || height < 0 || width > 16384 || height > 16384) {
      Reply(request, nil, @"Invalid popup anchor"); return true;
    }
    bool close = [method isEqual:@"popup.close"];
    bool focused = ![method isEqual:@"popup.focus"] || [p[@"focused"] boolValue];
    if (close) RetireNativeExtensionPopup(Key(S(p, @"token")));
    if (!t.browser || !t.browser->GetHost()->ControlExtensionPopup(Key(S(p, @"token")),
          CefRect(x, y, width, height), focused, close)) {
      PopupTrace([NSString stringWithFormat:@"ControlExtensionPopup refused %@ kind %@ close %d focused %d owner visible %d",
                  method, p[@"kind"], close, focused, t.visible]);
      RetireNativeExtensionPopup(Key(S(p, @"token")));
      Reply(request, nil, @"Native popup owner or document is no longer live"); return true;
    }
    if (close) RetireNativeExtensionPopup(Key(S(p, @"token")));
    if (close || [method isEqual:@"popup.focus"] || [method isEqual:@"popup.anchor"]) { Reply(request); return true; }
#else
    if ([method isEqual:@"popup.close"]) { RetireNativeExtensionPopup(Key(S(p, @"token"))); [window performClose:nil]; Reply(request); return true; }
    if (![method isEqual:@"popup.input"]) { Reply(request, nil, @"Native popup control is unavailable"); return true; }
#endif
    const std::string token = Key(S(p, @"token"));
    Tab& target = nativePopupInputs[token];  // Original widget's lifetime, not this RPC's.
    target.native = window;
    // This token names the original popup view, never a tab CDP session.
    // Deliver AppKit events directly while its producer stays concealed.
    target.externallyHosted = true;
    Input(target, p, request, true);
    // A click into a field or a key changes what the input method needs to
    // know; the renderer's answer lands within the next polls.
    PublishPopupTextStates();
    PollHurry();
#else
    Reply(request, nil, @"Extension popup hosting is unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"tab.discard"] || [method isEqual:@"tab.restore"] || [method isEqual:@"tab.freeze"]) {
#if YABCORE_DISCARD
    auto host = t.browser ? t.browser->GetHost() : nullptr;
    if (!host) { Reply(request, nil, @"Tab has no browser"); return true; }
    if (([method isEqual:@"tab.discard"] || ([method isEqual:@"tab.freeze"] && [p[@"frozen"] boolValue])) &&
        (p[@"captureToken"] || p[@"captureDocument"])) {
#if YABCORE_NATIVE_CAPTURE_ACTIVITY
      if (!NativeCaptureAllowsLifecycle(t, p)) {
        Reply(request, nil, @"Native capture snapshot retired or the page is active"); return true;
      }
#else
      Reply(request, nil, @"Native capture lifecycle guard is unavailable"); return true;
#endif
    }
    if ([method isEqual:@"tab.discard"]) {
#if YABCORE_NATIVE_PAGE
      // Chrome refuses to discard a VISIBLE WebContents. A page never shown
      // in Yab's window can still carry its creation-time visibility.
      if (!t.visible && t.externalPage) host->SetExternalPageVisibility(false);
#endif
      // A hide on its way (HideClearing draws the window without the page for
      // 200 ms before it hides it) leaves the page VISIBLE to Chrome, which
      // refused the discard: put to sleep just after it was left, a tab stayed
      // awake. A discarded page's window gives up its compositor (CEF 0117), so
      // that empty last frame is no longer needed: the window hides now.
      if (!t.visible && t.viewCleared && !t.capturing && ProducerShown(t)) { ++t.visibleTurn; HideProducer(t); }
      if (t.visible || !host->CanDiscardPage()) { Reply(request, @{@"discarded": @NO, @"refused": t.visible ? @"visible" : @"unavailable"}); return true; }
      host->DiscardPage(new DiscardDone(t.id, request));
    } else if ([method isEqual:@"tab.restore"]) {
      // Native restore of the selected entry only; history is untouched.
      bool restored = host->RestoreDiscardedPage();
      if (restored) { t.frozen = false; NativeDiscarded(&t, false); }
      Reply(request, @{@"restored": @(restored), @"discarded": @(restored ? false : host->IsPageDiscarded())});
    } else {
      bool frozen = [p[@"frozen"] boolValue];
      // A request to the renderer, never an acknowledgement or a discard. Blink
      // drops a freeze while a picture holds the page painting: it lands after.
      bool accepted = !t.visible && (t.capturing > 0 || host->SetPageFrozen(frozen));
      if (accepted) { t.frozen = frozen; State(&t, @{@"frozen": @(frozen)}); }
      Reply(request, @{@"frozen": @(t.frozen), @"accepted": @(accepted)});
    }
#else
    (void)t; (void)p;
    Reply(request, nil, @"Native discard and freeze are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"print.finish"]) {
#if YABCORE_NATIVE_PRINT
    auto host = t.browser ? t.browser->GetHost() : nullptr;
    bool finished = host && host->FinishNativePrint(Key(S(p, @"request") ?: @""));
    Reply(request, @{@"finished": @(finished)});
#else
    (void)t; (void)p;
    Reply(request, nil, @"Native print requests are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"tab.textInput"]) {
    Reply(request, @{@"state": t.textState ?: (::id)NSNull.null,
                     @"available": @(YABCORE_TEXT_INPUT)});
    return true;
  }
  return false;
}
#include "webauthn_proxy.inc"
#include "geolocation_source.inc"
