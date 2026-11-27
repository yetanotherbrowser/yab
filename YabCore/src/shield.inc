// Shield on Chromium pages: Filters' rules (shield_engine.h), asked of every
// request as WebKit asks its content rule lists, and the hiding rules as a
// document-start stylesheet. Included in core.mm after scripts.inc.

struct ShieldConfig {
  std::shared_ptr<const shield::Engine> engine;
  std::string path;
  double stamp = 0;
  bool enabled = false;
  bool local = false;   // Evals block on local pages, as YAB_BLOCK_LOCAL_PAGES does in WebKit.
  std::unordered_set<std::string> off;
};
static std::shared_ptr<const ShieldConfig> shieldConfig;

static std::shared_ptr<const ShieldConfig> ShieldNow() { return std::atomic_load(&shieldConfig); }

struct ShieldCount {
  int blocked = 0, spared = 0;
  bool topStopped = false;
  std::vector<std::string> samples;
};
static std::mutex shieldCountMutex;
static std::map<int, ShieldCount> shieldCounts;

// Pages opened by another, until their first document: a list's $popup rules.
static std::set<int> shieldPopups;
static void ShieldPopup(int browser, bool opening) {
  std::lock_guard<std::mutex> lock(shieldCountMutex);
  if (opening) shieldPopups.insert(browser); else shieldPopups.erase(browser);
}
static std::string_view ShieldHost(std::string_view url) {
  size_t scheme = url.find("://");
  if (scheme == url.npos) return {};
  size_t start = scheme + 3, end = url.find_first_of("/?#", start);
  if (end == url.npos) end = url.size();
  size_t at = url.rfind('@', end);
  if (at != url.npos && at >= start) start = at + 1;
  if (start < url.size() && url[start] == '[') {
    size_t close = url.find(']', start);
    return close == url.npos ? std::string_view() : url.substr(start, close - start + 1);
  }
  size_t port = url.find(':', start);
  if (port != url.npos && port < end) end = port;
  return url.substr(start, end - start);
}
static bool ShieldWeb(std::string_view url) {
  return url.rfind("https://", 0) == 0 || url.rfind("http://", 0) == 0 || url.rfind("wss://", 0) == 0 || url.rfind("ws://", 0) == 0;
}
// This Mac's and the network's own pages: LocalNetwork.space(of:). Names that
// only resolve to them come from Yab in `off`.
static bool ShieldHome(std::string_view host) {
  if (host.empty()) return false;
  if (host.back() == '.') host.remove_suffix(1);
  if (host == "localhost" || (host.size() > 10 && host.substr(host.size() - 10) == ".localhost")) return true;
  if (host.size() > 6 && host.substr(host.size() - 6) == ".local") return true;
  if (host.front() == '[') return true;  // Public IPv6 literals are no ad site either.
  if (host.find('.') == host.npos) return true;
  unsigned a = 0, b = 0, c = 0, d = 0;
  char tail = 0;
  if (sscanf(std::string(host).c_str(), "%u.%u.%u.%u%c", &a, &b, &c, &d, &tail) == 4) {
    return a == 127 || a == 10 || a == 0 || (a == 172 && (b & 0xf0) == 16) || (a == 192 && b == 168) ||
        (a == 169 && b == 254) || (a == 100 && (b & 0xc0) == 64);
  }
  return false;
}
// Shield names a page's site without its www (PageScripts.host).
static bool ShieldOff(const ShieldConfig& config, std::string_view host) {
  if (!config.engine || !config.enabled) return true;
  if (host.rfind("www.", 0) == 0) host.remove_prefix(4);
  if (config.off.count(std::string(host))) return true;
  return !config.local && ShieldHome(host);
}
static uint16_t ShieldKind(cef_resource_type_t type) {
  switch (type) {
    case RT_MAIN_FRAME: case RT_SUB_FRAME: return shield::kDocument;
    case RT_STYLESHEET: return shield::kStyle;
    case RT_SCRIPT: case RT_WORKER: case RT_SHARED_WORKER: case RT_SERVICE_WORKER: return shield::kScript;
    case RT_IMAGE: case RT_FAVICON: return shield::kImage;
    case RT_FONT_RESOURCE: return shield::kFont;
    case RT_MEDIA: return shield::kMedia;
    case RT_XHR: return shield::kFetch;
    case RT_PING: return shield::kPing;
    default: return shield::kOther;
  }
}
static bool ShieldStops(CefRefPtr<CefBrowser> browser, CefRefPtr<CefRequest> request) {
  auto config = ShieldNow();
  if (!config || !config->engine || !config->enabled) return false;
  std::string url = request->GetURL().ToString();
  if (!ShieldWeb(url)) return false;
  auto type = request->GetResourceType();
  bool top = type == RT_MAIN_FRAME;
  std::string page = top ? url : std::string();
  if (!top) {
    if (browser) if (auto main = browser->GetMainFrame()) page = main->GetURL().ToString();
    // The first subresources of a new document can arrive before the frame
    // reports its address; the request's own site is right by then.
    std::string first = request->GetFirstPartyForCookies().ToString();
    if (!first.empty() && (page.empty() || !ShieldWeb(page) ||
        shield::Site(ShieldHost(first)) != shield::Site(ShieldHost(page)))) page = first;
    if (!ShieldWeb(page)) return false;
  }
  std::string_view pageHost = ShieldHost(page);
  if (pageHost.empty() || ShieldOff(*config, pageHost)) return false;
  uint16_t kind = ShieldKind(type);
  if (top && browser) {
    std::lock_guard<std::mutex> lock(shieldCountMutex);
    if (shieldPopups.count(browser->GetIdentifier())) kind |= shield::kPopup;
  }
  shield::Request look{url, pageHost, kind, top};
  bool spared = false;
  bool stops = config->engine->Blocks(look, &spared);
  if ((stops || spared) && browser) {
    std::lock_guard<std::mutex> lock(shieldCountMutex);
    auto& count = shieldCounts[browser->GetIdentifier()];
    if (stops) { count.blocked++; count.topStopped = count.topStopped || top; if (count.samples.size() < 64) count.samples.push_back(url.substr(0, 256)); }
    else count.spared++;
  }
  return stops;
}
// The client's say over a tab's own navigation, as WebKit asks its navigation
// delegate: where a link goes in Yab is decided there (a peek, another space,
// an assistant's sites), and its scripts for the next document are in place
// when it answers. CEF's one chance to wait is here, before the request.
struct PageAsking {
  CefRefPtr<CefCallback> callback;
  CefRefPtr<CefRequest> request;
  std::string tab;
  bool stopped;
};
static std::map<std::string, PageAsking> pageAskings;
// `to`: where the request goes instead (Shield.redirect in the app), a click
// tracker's destination or the address without its tracking names, as a
// redirect, its own lists stopping it or not: the first address is never
// asked. That address is asked about in turn.
static void PageActionAnswered(NSString* token, bool allow, NSString* to = nil) {
  auto found = pageAskings.find(Key(token));
  if (found == pageAskings.end()) return;
  auto callback = found->second.callback;
  auto request = found->second.request;
  bool stopped = found->second.stopped;
  std::string tab = found->second.tab;
  pageAskings.erase(found);
  Mark("page.action.answered", tab);
  std::string skip = to ? Key(to) : std::string();
  if (allow && request && !skip.empty() && (skip.rfind("https://", 0) == 0 || skip.rfind("http://", 0) == 0) &&
      skip != request->GetURL().ToString()) {
    // Not the page's failure to tell as the ad blocker's (ShieldStoppedTop).
    auto open = tabs.find(tab);
    if (stopped && open != tabs.end() && open->second.browser) {
      std::lock_guard<std::mutex> lock(shieldCountMutex);
      shieldCounts[open->second.browser->GetIdentifier()].topStopped = false;
    }
    request->SetURL(skip);
    callback->Continue();
    return;
  }
  if (!allow || stopped) { callback->Cancel(); return; }
  callback->Continue();
}
static void PageActionAsk(CefRefPtr<CefBrowser> browser, NSDictionary* action, bool stopped, CefRefPtr<CefRequest> request, CefRefPtr<CefCallback> callback) {
  dispatch_async(dispatch_get_main_queue(), ^{
    Tab* tab = Find(browser);
    if (!tab || tab->internal || tab->closing) {
      if (stopped) callback->Cancel(); else callback->Continue();
      return;
    }
    NSString* token = NSUUID.UUID.UUIDString;
    Mark("page.action.asked", tab->id);
    pageAskings[Key(token)] = PageAsking{callback, request, tab->id, stopped};
    NSMutableDictionary* said = [action mutableCopy];
    said[@"request"] = token;
    said[@"gesture"] = @(tab->browseGesture);
    said[@"redirect"] = @(tab->browseRedirect);
    Event(@"page.action", tab, said);
    // A client that never answers must not cost the page: WebKit's own
    // watchdog is the page's; this one is a tenth of it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ PageActionAnswered(token, true); });
  });
}
class ShieldRequests : public CefResourceRequestHandler {
 public:
  cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, CefRefPtr<CefCallback> callback) override {
    bool stopped = ShieldStops(browser, request);
    if (!browser || !frame || !frame->IsMain() || request->GetResourceType() != RT_MAIN_FRAME)
      return stopped ? RV_CANCEL : RV_CONTINUE;
    PageActionAsk(browser, @{@"url": Str(request->GetURL()), @"method": Str(request->GetMethod()),
      @"transition": @((int)request->GetTransitionType())}, stopped, request, callback);
    return RV_CONTINUE_ASYNC;
  }
  IMPLEMENT_REFCOUNTING(ShieldRequests);
};
static CefRefPtr<CefResourceRequestHandler> ShieldHandler() {
  static CefRefPtr<CefResourceRequestHandler> handler = new ShieldRequests();
  return handler;
}

// One stylesheet each for every site's rules and the site's own, in a world
// of their own, adopted so the page's DOM holds nothing of it. Only the top
// document: these rules exist for what a page shows around its content.
// DevTools holds back what it is sent while a page changes renderers, so
// nothing can wait for these to land: each also runs where it lands, in the
// document that has just arrived, ahead of its first paint.
static NSString* ShieldStyleScript(NSString* css) {
  return [NSString stringWithFormat:@"if(window===window.top){const sheet=new CSSStyleSheet();sheet.replaceSync(%@[0]);"
    "const put=()=>{if(!document.adoptedStyleSheets.includes(sheet))document.adoptedStyleSheets=[...document.adoptedStyleSheets,sheet]};"
    "put();document.addEventListener('DOMContentLoaded',put,{once:true});}", JSON(@[css])];
}
// The rules for every site that take a selector, and a look for the plain
// classes and ids among the page's own elements as they arrive. The observer
// hears the parser's elements before they are painted, so nothing is seen.
static NSString* ShieldGenericScript(const shield::Engine& engine) {
  return [NSString stringWithFormat:@R"JS(if(window===window.top){
const sheet=new CSSStyleSheet();sheet.replaceSync(%@[0]);
const put=()=>{if(!document.adoptedStyleSheets.includes(sheet))document.adoptedStyleSheets=[...document.adoptedStyleSheets,sheet]};
put();document.addEventListener('DOMContentLoaded',put,{once:true});
const names=new Set(%@[0].split(' ')),seen=new Set();let fresh=[];
const take=k=>{if(names.has(k)&&!seen.has(k)){seen.add(k);fresh.push(k)}};
const look=e=>{if(e.id)take('#'+e.id);const c=e.classList;if(c)for(let i=0;i<c.length;i++)take('.'+c[i])};
const tree=e=>{if(e.nodeType!==1)return;look(e);for(const d of e.querySelectorAll('[id],[class]'))look(d)};
const hide=k=>{try{sheet.insertRule(k+'{display:none!important}',sheet.cssRules.length)}catch(e){}};
const flush=()=>{if(fresh.length){hide(fresh.join(','));fresh=[]}};
new MutationObserver(heard=>{for(const r of heard){if(r.type==='attributes')look(r.target);else for(const n of r.addedNodes)tree(n)}
flush()}).observe(document,{subtree:true,childList:true,attributes:true,attributeFilter:['id','class']});
if(document.documentElement){tree(document.documentElement);flush()}
})JS", JSON(@[Str(engine.generic())]), JSON(@[Str(engine.generic_names())])];
}
static void ShieldSettle(const std::string& id);
static void ShieldStyle(const std::string& id, bool generic, NSString* source, std::function<void()> done) {
  auto found = tabs.find(id);
  if (found == tabs.end()) return done();
  auto& scripts = found->second.scripts;
  NSString* old = generic ? scripts.shieldGenericScript : scripts.shieldOwnScript;
  (generic ? scripts.shieldGenericScript : scripts.shieldOwnScript) = nil;
  auto add = [id, generic, source, done]() {
    auto found = tabs.find(id);
    if (found == tabs.end() || !source.length) return done();
    CDP(found->second, @"Page.addScriptToEvaluateOnNewDocument",
        @{@"source": source, @"worldName": @"yab-world-shield", @"runImmediately": @YES},
        [id, generic, done](NSDictionary* result, NSString*) {
      auto found = tabs.find(id);
      if (found != tabs.end() && result[@"identifier"])
        (generic ? found->second.scripts.shieldGenericScript : found->second.scripts.shieldOwnScript) = result[@"identifier"];
      done();
    });
  };
  if (!old.length) return add();
  CDP(found->second, @"Page.removeScriptToEvaluateOnNewDocument", @{@"identifier": old},
      [add](NSDictionary*, NSString*) { add(); });
}
// What the top document on its way should get, kept current one step at a
// time: an arm can arrive while the last one's replies are out.
static void ShieldSettle(const std::string& id) {
  auto found = tabs.find(id);
  if (found == tabs.end()) return;
  auto& scripts = found->second.scripts;
  if (!found->second.domainsReady || scripts.shieldBusy) return;
  auto config = ShieldNow();
  const void* engine = config ? config->engine.get() : nullptr;
  bool generic = scripts.shieldWantGeneric;
  NSString* own = scripts.shieldWantOwn ?: @"";
  bool genericChanges = generic != scripts.shieldHasGeneric || (generic && scripts.shieldEngine != engine);
  bool ownChanges = ![own isEqualToString:scripts.shieldHasOwn ?: @""];
  if (!genericChanges && !ownChanges) return;
  scripts.shieldBusy = true;
  auto next = [id]() {
    auto found = tabs.find(id);
    if (found == tabs.end()) return;
    found->second.scripts.shieldBusy = false;
    ShieldSettle(id);
  };
  if (genericChanges) {
    scripts.shieldHasGeneric = generic;
    scripts.shieldEngine = engine;
    ShieldStyle(id, true, generic && engine ? ShieldGenericScript(*config->engine) : @"", next);
  } else {
    scripts.shieldHasOwn = own;
    ShieldStyle(id, false, own.length ? ShieldStyleScript(own) : @"", next);
  }
}
static void ShieldArm(Tab& tab, const std::string& url) {
  if (tab.internal) return;
  auto config = ShieldNow();
  std::string_view host = ShieldHost(url);
  bool on = config && ShieldWeb(url) && !host.empty() && !ShieldOff(*config, host);
  tab.scripts.shieldWantGeneric = on && !config->engine->GenericOff(url, host);
  tab.scripts.shieldWantOwn = on ? Str(config->engine->Own(host)) : nil;
  tab.scripts.shieldURL = Str(url);
  ShieldSettle(tab.id);
}
// The agent's scripts go with it; the next one is given them again.
static void ShieldAgentGone(Tab& tab) {
  tab.scripts.shieldHasGeneric = false; tab.scripts.shieldHasOwn = nil; tab.scripts.shieldBusy = false;
  tab.scripts.shieldGenericScript = nil; tab.scripts.shieldOwnScript = nil;
}
// A new rule set or a changed switch: the open tabs' next documents follow.
static void ShieldRearm() {
  for (auto& [key, tab] : tabs) if (tab.scripts.shieldURL.length) ShieldArm(tab, Key(tab.scripts.shieldURL));
}
static void ShieldBegan(CefRefPtr<CefBrowser> browser, Tab* tab, const std::string& url) {
  { std::lock_guard<std::mutex> lock(shieldCountMutex); shieldCounts.erase(browser->GetIdentifier()); }
  if (tab) ShieldArm(*tab, url);
}
// A page's own address on a list: a cancelled load says nothing by itself,
// so its failure is told as the ad blocker's.
static bool ShieldStoppedTop(CefRefPtr<CefBrowser> browser) {
  std::lock_guard<std::mutex> lock(shieldCountMutex);
  auto found = shieldCounts.find(browser->GetIdentifier());
  if (found == shieldCounts.end() || !found->second.topStopped) return false;
  found->second.topStopped = false;
  return true;
}
static void ShieldConfigure(NSDictionary* params) {
  auto next = std::make_shared<ShieldConfig>();
  auto old = ShieldNow();
  if (old) { next->engine = old->engine; next->path = old->path; next->stamp = old->stamp; }
  next->enabled = [params[@"enabled"] boolValue];
  next->local = [params[@"local"] boolValue];
  for (id host in params[@"off"]) if ([host isKindOfClass:NSString.class]) next->off.insert(Key(host));
  std::string path = Key(S(params, @"path"));
  double stamp = [params[@"stamp"] doubleValue];
  bool load = !path.empty() && (path != next->path || stamp != next->stamp);
  std::atomic_store(&shieldConfig, std::shared_ptr<const ShieldConfig>(next));
  if (!load) { ShieldRearm(); return; }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    auto engine = std::make_shared<shield::Engine>();
    bool loaded = engine->Load(path);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!loaded) { fprintf(stderr, "YabCore: shield rules did not load\n"); return; }
      auto now = ShieldNow();
      auto done = std::make_shared<ShieldConfig>(now ? *now : ShieldConfig());
      done->engine = engine; done->path = path; done->stamp = stamp;
      std::atomic_store(&shieldConfig, std::shared_ptr<const ShieldConfig>(done));
      ShieldRearm();
    });
  });
}
static NSDictionary* ShieldStatus(Tab* tab) {
  auto config = ShieldNow();
  NSMutableDictionary* out = [@{@"enabled": @(config && config->enabled), @"rules": @(config && config->engine ? config->engine->rules() : 0),
    @"tokenless": @(config && config->engine ? config->engine->tokenless() : 0),
    @"ownSites": @(config && config->engine ? config->engine->own_sites() : 0),
    @"genericBytes": @(config && config->engine ? config->engine->generic().size() + config->engine->generic_names().size() : 0)} mutableCopy];
  if (tab && tab->browser) {
    std::lock_guard<std::mutex> lock(shieldCountMutex);
    auto found = shieldCounts.find(tab->browser->GetIdentifier());
    NSMutableArray* samples = [NSMutableArray array];
    if (found != shieldCounts.end()) for (const auto& url : found->second.samples) [samples addObject:Str(url)];
    out[@"blocked"] = @(found == shieldCounts.end() ? 0 : found->second.blocked);
    out[@"spared"] = @(found == shieldCounts.end() ? 0 : found->second.spared);
    out[@"samples"] = samples;
    out[@"generic"] = @(tab->scripts.shieldHasGeneric);
    out[@"ownBytes"] = @(tab->scripts.shieldHasOwn.length);
  }
  return out;
}
