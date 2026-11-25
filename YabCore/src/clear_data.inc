// What Chrome would otherwise do with a profile, in Chrome's own preferences:
// Yab owns passwords, autofill, translation and its anti-phishing list, each with
// its own card, so Chrome's never run, never save a thing and never call home.
// Read before any profile service starts; the same keys keep working in a profile
// that was used before this list existed.
static NSDictionary* ChosenPreferences() {
  // Seeding also runs before CefInitialize, when CEF's global command line
  // does not yet exist. Read the same owning-app argument directly.
  NSString* languages = nil;
  for (NSString* argument in NSProcessInfo.processInfo.arguments)
    if ([argument hasPrefix:@"--accept-lang="]) languages = [argument substringFromIndex:14];
  return @{
    @"intl.accept_languages": languages.length ? languages : @"en-US,en",
    @"intl.selected_languages": languages.length ? languages : @"en-US,en",
    @"safebrowsing.enabled": @NO, @"safebrowsing.enhanced": @NO,
    @"credentials_enable_service": @NO, @"credentials_enable_autosignin": @NO,
    @"profile.password_manager_leak_detection": @NO,
    @"autofill.profile_enabled": @NO, @"autofill.credit_card_enabled": @NO,
    @"translate.enabled": @NO,
    @"search.suggest_enabled": @NO,
    @"alternate_error_pages.enabled": @NO,
    @"spellcheck.use_spelling_service": @NO,
    @"omnibox.ai_mode_settings": @1,
    // WindowGate decides which windows open: Chrome's blocker would drop one
    // and say so on a bubble nobody sees.
    @"profile.default_content_setting_values.popups": @1,
    // Yab's own card asks about a site's automatic downloads, and Chromium
    // holds only what Yab writes there once the profile opens
    // (ChromiumPermissions). A block YabCore's own refusal once left
    // (questions.inc, AnswerDownloads) dropped every later file silently.
    @"profile.content_settings.exceptions.automatic_downloads": @{},
    // Yab is the source of these decisions too. Older helpers denied unknown
    // permission masks before a card existed, leaving Chromium-only BLOCKs
    // which prevented a later helper from asking at all. Start without that
    // native copy; ChromiumPermissions.opened restores every answer Yab kept
    // before the profile's first page, including the person's font refusals.
    // Clear the old combined network key as well, before Chromium can migrate
    // it into the split local/loopback settings.
    @"profile.content_settings.exceptions.local_fonts": @{},
    @"profile.content_settings.exceptions.local_network_access": @{},
    @"profile.content_settings.exceptions.local_network": @{},
    @"profile.content_settings.exceptions.loopback_network": @{},
    @"unified_consent.url_keyed_anonymized_data_collection.enabled": @NO,
    // As WebKit tabs: no preloading, <a ping>, LAN address over WebRTC or third-party
    // cookies (ShieldCookieExceptions). 2 is "no prediction"; 1 is "block third party".
    @"net.network_prediction_options": @2,
    @"enable_a_ping": @NO,
    @"webrtc.ip_handling_policy": @"default_public_interface_only",
    @"profile.cookie_controls_mode": @1,
  };
}
void SeedPreferences(NSString* path) {
  auto files = NSFileManager.defaultManager;
  NSData* data = [NSData dataWithContentsOfFile:path];
  id read = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : [NSMutableDictionary new];
  // A file Chrome cannot read either: left for Chrome's own recovery.
  if (![read isKindOfClass:NSMutableDictionary.class]) return;
  NSMutableDictionary* preferences = read;
  __block bool changed = !data;
  [ChosenPreferences() enumerateKeysAndObjectsUsingBlock:^(NSString* key, id value, BOOL*) {
    NSArray* parts = [key componentsSeparatedByString:@"."];
    NSMutableDictionary* level = preferences;
    for (NSUInteger i = 0; i + 1 < parts.count; ++i) {
      id next = level[parts[i]];
      if (![next isKindOfClass:NSMutableDictionary.class]) { next = [NSMutableDictionary new]; level[parts[i]] = next; }
      level = next;
    }
    if ([level[parts.lastObject] isEqual:value]) return;
    level[parts.lastObject] = value;
    changed = true;
  }];
  if (!changed) return;
  [files createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
    attributes:@{NSFilePosixPermissions: @0700} error:nil];
  NSData* written = [NSJSONSerialization dataWithJSONObject:preferences options:0 error:nil];
  if (written && [written writeToFile:path atomically:YES])
    [files setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
}
// Chromium's own data removal has no CEF or DevTools entry for a whole profile
// or a whole site: its Settings page is the one caller of BrowsingDataRemover
// and of the site data model. A hidden internal tab on that page runs them, so
// every store Chrome clears is cleared, and a new one comes with the next SDK.
static bool SettingsPageAllowed(NSString* page) {
  return [page isEqual:@"clearBrowserData"] || [page isEqual:@"content/all"];
}
// Settings' WebUI answers on its own page, never on a page a site can reach.
static bool SettingsRequest(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  const bool forgetUse = [method isEqual:@"settings.forgetUse"];
  if (!forgetUse && ![method isEqual:@"settings.run"]) return false;
  if (!t.internal || ![Str(t.browser->GetMainFrame()->GetURL()) hasPrefix:@"chrome://settings/"]) {
    Reply(request, nil, @"Use a chrome://settings management tab"); return true;
  }
  // Chrome's scores of how much each site is used name the site, and its
  // history removal leaves them: they go only with cookies or settings there.
  if (forgetUse) {
    auto context = t.browser->GetHost()->GetRequestContext();
    for (const char* kind : {"site_engagement", "media_engagement"}) {
      auto empty = CefValue::Create();
      empty->SetDictionary(CefDictionaryValue::Create());
      CefString error;
      const std::string name = std::string("profile.content_settings.exceptions.") + kind;
      if (!context->SetPreference(name, empty, error)) { Reply(request, nil, Str(error)); return true; }
    }
    Reply(request, @{}); return true;
  }
  NSString* script = S(p, @"script");
  if (!script.length) { Reply(request, nil, @"script required"); return true; }
  DRMWhenReady(t.id, [script, request](Tab& tab) {
    Eval(tab, script, 0, [request](NSDictionary* value, NSString* error) {
      if (error) Reply(request, nil, error);
      else Reply(request, @{@"value": value[@"result"][@"value"] ?: NSNull.null});
    });
  }, [request](NSString* error) { Reply(request, nil, error); }, Running() + 15);
  return true;
}
// A cookie the site set, in any partition, or one another site set inside
// the site's partition (an embed's, CHIPS): Chrome's own site clearing takes
// both, and a domain filter alone misses the second.
static bool CookieOfSite(NSDictionary* cookie, NSString* site) {
  NSString* tail = [@"." stringByAppendingString:site];
  NSString* domain = S(cookie, @"domain").lowercaseString;
  if ([domain hasPrefix:@"."]) domain = [domain substringFromIndex:1];
  if ([domain isEqual:site] || [domain hasSuffix:tail]) return true;
  id key = cookie[@"partitionKey"];
  NSString* top = [key isKindOfClass:NSDictionary.class] ? S(key, @"topLevelSite") : ([key isKindOfClass:NSString.class] ? key : nil);
  NSString* host = top.length ? [NSURL URLWithString:top].host.lowercaseString : nil;
  return host && ([host isEqual:site] || [host hasSuffix:tail]);
}
static NSArray* CookiesOfSite(NSDictionary* value, NSString* site) {
  NSArray* cookies = [value[@"cookies"] isKindOfClass:NSArray.class] ? value[@"cookies"] : @[];
  NSMutableArray* theirs = [NSMutableArray new];
  for (NSDictionary* cookie in cookies)
    if ([cookie isKindOfClass:NSDictionary.class] && CookieOfSite(cookie, site)) [theirs addObject:cookie];
  return theirs;
}
// A site's cookies, on a live page or a management tab of its profile: Arc's
// Clear Cookies and Refresh, private pages, which have no Settings page, and
// the check after a Settings clearing. `left` is what a second read of the
// jar still finds: zero is the proof they are gone.
static bool SiteCookiesRequest(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"site.cookies.clear"]) return false;
  NSString* site = S(p, @"site").lowercaseString;
  if (!site.length) { Reply(request, nil, @"site required"); return true; }
  std::string id = t.id;
  // Network, not Storage: Storage's answer is the default profile's, whatever
  // the tab. This one reads the jar of the page it runs on.
  DRMCDP(id, @"Network.getAllCookies", @{}, [id, site, request](NSDictionary* value, NSString* error) {
    if (error) { Reply(request, nil, error); return; }
    auto found = tabs.find(id);
    if (found == tabs.end() || found->second.closing) { Reply(request, nil, @"Tab closed"); return; }
    NSArray* theirs = CookiesOfSite(value, site);
    if (!theirs.count) { Reply(request, @{@"removed": @0, @"left": @0}); return; }
    auto left = std::make_shared<NSUInteger>(theirs.count);
    NSUInteger total = theirs.count;
    for (NSDictionary* cookie in theirs) {
      NSMutableDictionary* one = [@{@"name": S(cookie, @"name"), @"domain": S(cookie, @"domain"), @"path": S(cookie, @"path")} mutableCopy];
      if (cookie[@"partitionKey"]) one[@"partitionKey"] = cookie[@"partitionKey"];
      CDP(found->second, @"Network.deleteCookies", one, [id, site, left, total, request](NSDictionary*, NSString*) {
        if (--*left) return;
        DRMCDP(id, @"Network.getAllCookies", @{}, [site, total, request](NSDictionary* again, NSString* error) {
          if (error) { Reply(request, nil, error); return; }
          Reply(request, @{@"removed": @(total), @"left": @(CookiesOfSite(again, site).count)});
        }, Running() + 10);
      });
    }
  }, Running() + 10);
  return true;
}
// A private page's own origin: its profile has no Settings page to ask.
static bool OriginDataRequest(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"site.origin.clear"]) return false;
  NSString* origin = S(p, @"origin");
  if (!origin.length) { Reply(request, nil, @"origin required"); return true; }
  DRMCDP(t.id, @"Storage.clearDataForOrigin", @{@"origin": origin, @"storageTypes": @"all"},
    [request](NSDictionary*, NSString* error) { Reply(request, error ? nil : @{}, error); }, Running() + 10);
  return true;
}
