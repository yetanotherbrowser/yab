#include "script_errors.h"
// Included in core.mm so page scripts share its bounded CDP transport.
// An expression's value as the client reads a function's: undefined apart from null.
static NSDictionary* WholeValue(NSDictionary* r) {
  NSDictionary* result = r[@"result"];
  if ([result[@"type"] isEqual:@"undefined"]) return @{@"absent": @YES};
  return @{@"value": result[@"value"] ?: NSNull.null};
}
static void ScriptTree(Tab& tab, NSDictionary* tree) {
  NSDictionary* frame = tree[@"frame"];
  if (S(frame, @"id").length) {
    std::string id = Key(S(frame, @"id"));
    if (!tab.scripts.frames.count(id)) tab.scripts.frameOrder.push_back(id);
    tab.scripts.frames[id] = frame;
    if (S(frame, @"parentId").length) tab.scripts.parents[id] = Key(S(frame, @"parentId"));
  }
  for (NSDictionary* child in tree[@"childFrames"]) ScriptTree(tab, child);
}
using ScriptCommands = std::vector<std::pair<NSString*, NSDictionary*>>;
// All sent at once: a session keeps its commands in order, and a paused
// out-of-process frame waits for these, not for one round trip after another.
// `deadline`: the asking request's (RequestDue), 0 for Yab's own 15 s.
static void ScriptRun(std::string tab, NSString* session, std::shared_ptr<ScriptCommands> commands,
                      double deadline, Completion done) {
  auto found = tabs.find(tab);
  if (found == tabs.end() || found->second.closing) { done(nil, @"Tab closed"); return; }
  if (commands->empty()) { done(@{}, nil); return; }
  auto left = std::make_shared<size_t>(commands->size());
  auto failure = std::make_shared<NSString*>(nil);
  for (auto& [method, params] : *commands) {
    NSString* name = method;
    auto current = tabs.find(tab);
    if (current == tabs.end() || current->second.closing) { *failure = *failure ?: @"Tab closed"; if (--*left == 0) done(nil, *failure); continue; }
    CDP(current->second, method, params, [tab, session, left, failure, done, name](NSDictionary* result, NSString* error) {
      auto owner = tabs.find(tab);
      if (error && !ScriptRemovalAlreadyGone(name, error) && !StackCaptureOptional(name)) *failure = *failure ?: error;
      else if (owner == tabs.end()) *failure = *failure ?: @"Tab closed";
      else if ([name isEqual:@"Page.getFrameTree"]) {
        ScriptTree(owner->second, result[@"frameTree"]);
        if (!session.length) owner->second.scripts.mainFrame = S(result[@"frameTree"][@"frame"], @"id");
      } else if ([name isEqual:@"Page.addScriptToEvaluateOnNewDocument"] && result[@"identifier"])
        owner->second.scripts.identifiers[Key(session)].push_back(result[@"identifier"]);
      if (--*left == 0) { if (*failure) done(nil, *failure); else done(@{}, nil); }
    }, session, deadline);
  }
}
// One name to a world: V8 takes a binding's name once it is live in any context,
// so a world added to a page that already ran would get nothing under the old one.
static NSString* ScriptRelayName(NSString* world) {
  return [NSString stringWithFormat:@"yabScriptRelay_%zx", std::hash<std::string>{}(Key(world))];
}
static NSString* ScriptBridge(NSArray* names, NSString* world) {
  return [NSString stringWithFormat:@R"JS((()=>{
    const pending=new Map(); let serial=0;
    const prefix=Array.from(crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16)).join('-');
    const send=globalThis[%@];
    Object.defineProperty(globalThis,'yabScriptRelay',{value:send,configurable:true});
    const handlers=Object.create(null);
    for(const name of %@) handlers[name]={postMessage(body){
      if(pending.size>=128) return Promise.reject(new Error('Too many relay requests'));
      const id=prefix+':'+String(++serial);
      return new Promise((resolve,reject)=>{
        // A passkey waits for a person at the Mac's own sheet.
        const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Relay timed out'))},name==='yabPasskeys'?600000:20000);
        pending.set(id,{resolve,reject,timer});
        try {send(JSON.stringify({id,name,body}));} catch(error){clearTimeout(timer);pending.delete(id);reject(error)}
      });
    }};
    Object.defineProperty(globalThis,'__yabScriptReply',{value:(id,value,error)=>{
      const call=pending.get(id); if(!call)return;
      pending.delete(id);clearTimeout(call.timer);
      if(error)call.reject(new Error(error));else call.resolve(value);
    },configurable:true});
    Object.defineProperty(globalThis,'webkit',{value:{messageHandlers:handlers},configurable:true});
  })();
  )JS", JSON(ScriptRelayName(world)), JSON(names)];
}
// `fresh`: worlds this install binds for the first time; their bridges also
// run in the documents already up, so a script run there now can reach Yab.
static void ScriptSetup(Tab& tab, NSString* session, bool immediately, Completion done, NSSet* fresh = nil, double deadline = 0) {
  auto commands = std::make_shared<ScriptCommands>();
  auto old = tab.scripts.identifiers.find(Key(session));
  if (old != tab.scripts.identifiers.end()) {
    for (NSString* identifier : old->second)
      commands->push_back({@"Page.removeScriptToEvaluateOnNewDocument", @{@"identifier": identifier}});
    old->second.clear();
  }
  // Bind every world before feature scripts can execute. Register each
  // script separately in the caller's order, including across worlds.
  for (NSString* world in tab.scripts.relays) {
    NSArray* names = tab.scripts.relays[world];
    if (!names.count) continue;
    commands->push_back({@"Runtime.addBinding", @{@"name": ScriptRelayName(world), @"executionContextName": world}});
    NSMutableDictionary* bridge = [@{@"source": ScriptBridge(names, world), @"worldName": world} mutableCopy];
    if (immediately || [fresh containsObject:world]) bridge[@"runImmediately"] = @YES;
    commands->push_back({@"Page.addScriptToEvaluateOnNewDocument", bridge});
  }
  for (NSDictionary* script in tab.scripts.definitions) {
    NSString* world = S(script, @"world"), *source = S(script, @"source");
    if ([script[@"mainOnly"] boolValue]) source = [NSString stringWithFormat:@"if(window===window.top){\n%@\n}", source];
    source = [NSString stringWithFormat:@"(()=>{\n%@\n})();\n", source];
    if ([script[@"end"] boolValue]) source = [NSString stringWithFormat:@"(()=>{const run=()=>{%@};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',run,{once:true});else run()})();\n", source];
    NSMutableDictionary* params = [@{@"source": source} mutableCopy];
    if (world.length) params[@"worldName"] = world;
    if (immediately) params[@"runImmediately"] = @YES;
    commands->push_back({@"Page.addScriptToEvaluateOnNewDocument", params});
  }
  ScriptRun(tab.id, session, commands, deadline, done);
}
// CSS prefers-color-scheme and the ground before a page paints, as the
// app's view would give them in WebKit. Each target (main and every
// out-of-process frame) keeps its own emulation, so each session is told.
static void ScriptAppearance(const Tab& tab, ScriptCommands& commands) {
  NSDictionary* appearance = tab.scripts.appearance;
  if (!appearance) return;
  NSString* scheme = S(appearance, @"scheme");
  commands.push_back({@"Emulation.setEmulatedMedia", @{@"features": @[@{@"name": @"prefers-color-scheme", @"value": scheme}]}});
  NSDictionary* ground = [appearance[@"ground"] isKindOfClass:NSDictionary.class] ? appearance[@"ground"] : nil;
  commands.push_back({@"Emulation.setDefaultBackgroundColorOverride", ground ? @{@"color": ground} : @{}});
  // A page in a window nobody focuses (ours is hidden) hears its focus events
  // only when told it has focus, as a page in the key window would.
  if ([appearance[@"focused"] isKindOfClass:NSNumber.class])
    commands.push_back({@"Emulation.setFocusEmulationEnabled", @{@"enabled": @([appearance[@"focused"] boolValue] && tab.visible)}});
}
// A child session is gone (detached, or answering "Session with given id not
// found"): it and every session that arrived on it, with what they held.
static void ForgetScriptSession(Tab& tab, const std::string& session) {
  if (session.empty()) return;
  std::set<std::string> gone{session};
  for (bool grew = true; grew;) {
    grew = false;
    for (const auto& [child, parent] : tab.scripts.sessionParents)
      if (gone.count(parent) && gone.insert(child).second) grew = true;
  }
  for (const auto& key : gone) {
    tab.scripts.sessions.erase(key); tab.scripts.attaching.erase(key); tab.scripts.sessionParents.erase(key);
    tab.scripts.identifiers.erase(key); tab.scripts.consoleRelease.erase(key);
  }
  for (auto it = tab.scripts.contexts.begin(); it != tab.scripts.contexts.end();) {
    if (gone.count(Key(it->second.session))) it = tab.scripts.contexts.erase(it); else ++it;
  }
}
static void ScriptAttach(Tab& tab, NSString* session, Completion done) {
  tab.scripts.sessions.insert(Key(session));
  auto commands = std::make_shared<ScriptCommands>();
  commands->push_back({@"Page.enable", @{}});
  commands->push_back({@"Runtime.enable", @{}});
  if (!StackCaptureKept()) commands->push_back(StackCaptureOff());
  commands->push_back({@"Page.getFrameTree", @{}});
  // The page's view here is never on screen, so AppKit can't hold a drag for
  // it. The app's view does: a drag the page starts goes there as page.drag.
  if (!session.length) commands->push_back({@"Input.setInterceptDrags", @{@"enabled": @YES}});
  // Pause new out-of-process frames until their scripts and bindings exist.
  // Chromium 156 pauses both worker and worklet threads before the browser
  // applies this filter (DevToolsAgent::WorkerThreadCreated). Both must get
  // a session to resume them, even though only frames need our scripts.
  commands->push_back({@"Target.setAutoAttach", @{@"autoAttach": @YES, @"waitForDebuggerOnStart": @YES,
    @"flatten": @YES, @"filter": @[@{@"type": @"iframe", @"exclude": @NO}, @{@"type": @"worker", @"exclude": @NO},
      @{@"type": @"worklet", @"exclude": @NO}, @{@"exclude": @YES}]}});
  ScriptAppearance(tab, *commands);
  ScriptRun(tab.id, session, commands, 0, [id = tab.id, session, done](NSDictionary*, NSString* error) {
    auto found = tabs.find(id);
    if (error && found != tabs.end() && session.length) {
      // Paused by waitForDebuggerOnStart: a live frame must not stay paused
      // because its setup failed, and a gone one leaves the session set.
      if (ScriptSessionGone(error)) ForgetScriptSession(found->second, Key(session));
      else CDP(found->second, @"Runtime.runIfWaitingForDebugger", @{}, Ignore, session);
    }
    if (error || found == tabs.end()) { done(nil, error ?: @"Tab closed"); return; }
    ScriptSetup(found->second, session, true, [id, session, done](NSDictionary* value, NSString* error) {
      // Release the target even on setup failure, and surface the failure.
      auto found = tabs.find(id);
      if (found != tabs.end() && session.length) CDP(found->second, @"Runtime.runIfWaitingForDebugger", @{}, Ignore, session);
      done(value, error);
    });
  });
}
static NSDictionary* ScriptFrame(const Tab& tab, const ScriptContext& context) {
  NSString* origin = context.origin;
  for (const auto& [key, candidate] : tab.scripts.contexts)
    if (candidate.isDefault && [candidate.session isEqual:context.session] && [candidate.frame isEqual:context.frame]) { origin = candidate.origin; break; }
  NSURL* url = [NSURL URLWithString:origin];
  auto frame = tab.scripts.frames.find(Key(context.frame));
  NSString* href = frame == tab.scripts.frames.end() ? origin : S(frame->second, @"url");
  bool main = !context.session.length && [context.frame isEqual:tab.scripts.mainFrame];
  return @{@"token": context.token, @"frameId": context.frame, @"main": @(main), @"url": href,
    @"scheme": url.scheme ?: @"", @"host": url.host ?: @"", @"port": url.port ?: @0};
}
// Runtime.enable, which every session here needs for its contexts and
// bindings, makes V8 wrap each console argument and each thrown exception for
// that session, in the object group "console", and hold every one until the
// group is released or the document goes. Chrome with DevTools closed holds
// none of them: a long-lived page that logs kept everything it logged, here
// only. Nothing in Yab reads them, so each session's group is released as the
// messages come: one release per burst, since one in flight takes everything
// wrapped before it, and one more after it if more came meanwhile. V8's own
// message store (1,000 messages, the same as Chromium's) is left alone.
static void ConsoleReleaseSend(std::string id, std::string session) {
  auto found = tabs.find(id);
  if (found == tabs.end()) return;
  if (found->second.closing || (!session.empty() && !found->second.scripts.sessions.count(session))) {
    found->second.scripts.consoleRelease.erase(session); return;
  }
  CDP(found->second, @"Runtime.releaseObjectGroup", @{@"objectGroup": @"console"}, [id, session](NSDictionary*, NSString* error) {
    auto found = tabs.find(id);
    if (found == tabs.end()) return;
    auto state = found->second.scripts.consoleRelease.find(session);
    if (state == found->second.scripts.consoleRelease.end()) return;
    if (state->second == 2 && !error) { state->second = 1; ConsoleReleaseSend(id, session); }
    else found->second.scripts.consoleRelease.erase(state);
  }, @(session.c_str()));
}
static void ConsoleRelease(Tab& tab, NSString* session) {
  int& state = tab.scripts.consoleRelease[Key(session)];
  if (state) { state = 2; return; }
  state = 1;
  // Not from inside the observer's notification (see Target.attachedToTarget).
  std::string id = tab.id, key = Key(session);
  dispatch_async(dispatch_get_main_queue(), ^{ ConsoleReleaseSend(id, key); });
}
static void ScriptEvent(Tab& tab, NSString* method, NSDictionary* params, NSString* session) {
  if ([method isEqual:@"Runtime.consoleAPICalled"] || [method isEqual:@"Runtime.exceptionThrown"]) {
    ConsoleRelease(tab, session); return;
  }
  if ([method isEqual:@"Page.frameNavigated"]) {
    NSDictionary* frame = params[@"frame"];
    if (S(frame, @"id").length) {
      std::string id = Key(S(frame, @"id"));
      if (!tab.scripts.frames.count(id)) tab.scripts.frameOrder.push_back(id);
      tab.scripts.frames[id] = frame;
      if (S(frame, @"parentId").length) tab.scripts.parents[id] = Key(S(frame, @"parentId"));
    }
    if (!session.length && !frame[@"parentId"]) tab.scripts.mainFrame = S(frame, @"id");
    // A new document in a new renderer gets a new surface, which is drawn
    // in the default ground until told: say the ground again as it commits.
    if (!frame[@"parentId"] && tab.scripts.appearance && [tab.scripts.appearance[@"ground"] isKindOfClass:NSDictionary.class]) {
      std::string id = tab.id;
      dispatch_async(dispatch_get_main_queue(), ^{
        auto found = tabs.find(id);
        if (found == tabs.end() || found->second.closing) return;
        auto commands = std::make_shared<ScriptCommands>();
        ScriptAppearance(found->second, *commands);
        ScriptRun(id, session, commands, 0, [](NSDictionary*, NSString*) {});
      });
    }
  } else if ([method isEqual:@"Page.frameAttached"]) {
    std::string id = Key(S(params, @"frameId"));
    if (!tab.scripts.parents.count(id)) tab.scripts.frameOrder.push_back(id);
    tab.scripts.parents[id] = Key(S(params, @"parentFrameId"));
  } else if ([method isEqual:@"Page.frameDetached"] && [S(params, @"reason") isEqual:@"remove"]) {
    std::set<std::string> removed{Key(S(params, @"frameId"))};
    bool changed = true;
    while (changed) {
      changed = false;
      for (const auto& [frame, parent] : tab.scripts.parents)
        if (removed.count(parent) && removed.insert(frame).second) changed = true;
    }
    for (const auto& frame : removed) { tab.scripts.frames.erase(frame); tab.scripts.parents.erase(frame); }
    std::erase_if(tab.scripts.frameOrder, [&](const std::string& frame) { return removed.count(frame); });
    for (auto it = tab.scripts.contexts.begin(); it != tab.scripts.contexts.end();) {
      if (removed.count(Key(it->second.frame))) it = tab.scripts.contexts.erase(it); else ++it;
    }
  } else if ([method isEqual:@"Target.attachedToTarget"]) {
    NSString* child = S(params, @"sessionId");
    std::string id = tab.id;
    NSString* type = S(params[@"targetInfo"], @"type");
    if (!child.length || !([type isEqual:@"iframe"] || [type isEqual:@"worker"] || [type isEqual:@"worklet"])) return;
    // Recorded now, in event order with its detach: the attach below runs later.
    NSString* parent = session ?: @"";
    tab.scripts.sessionParents[Key(child)] = Key(parent);
    bool frame = [type isEqual:@"iframe"];
    if (frame) tab.scripts.attaching.insert(Key(child));
    // Not from inside the observer's notification: the commands it sends may
    // be answered at once, which would nest a second one.
    dispatch_async(dispatch_get_main_queue(), ^{
      auto found = tabs.find(id);
      if (found == tabs.end() || found->second.closing) return;
      if (!frame) {
        CDP(found->second, @"Runtime.runIfWaitingForDebugger", @{}, Ignore, child);
        // A nested worker's attachment belongs to the session it arrived on.
        CDP(found->second, @"Target.detachFromTarget", @{@"sessionId": child}, Ignore, parent);
        return;
      }
      // Detached meanwhile, or the agent went (its sessions cleared): nothing to attach.
      if (!found->second.scripts.attaching.erase(Key(child))) return;
      ScriptAttach(found->second, child, [id](NSDictionary*, NSString* error) {
        auto found = tabs.find(id);
        if (error && found != tabs.end()) Event(@"script.error", &found->second, @{@"message": error});
      });
    });
  } else if ([method isEqual:@"Target.detachedFromTarget"]) {
    ForgetScriptSession(tab, Key(S(params, @"sessionId")));
  } else if ([method isEqual:@"Runtime.executionContextCreated"]) {
    NSDictionary* context = params[@"context"], *aux = context[@"auxData"];
    NSString* token = S(context, @"uniqueId"), *frame = S(aux, @"frameId");
    if (!token.length || !frame.length) return;
    tab.scripts.contexts[Key(token)] = {token, session, frame, S(context, @"name"), S(context, @"origin"),
      [context[@"id"] intValue], [aux[@"isDefault"] boolValue], S(aux, @"yabDocumentToken")};
  } else if ([method isEqual:@"Runtime.executionContextsCleared"] || [method isEqual:@"Runtime.executionContextDestroyed"]) {
    for (auto it = tab.scripts.contexts.begin(); it != tab.scripts.contexts.end();) {
      if ([it->second.session isEqual:session] && ([method isEqual:@"Runtime.executionContextsCleared"] || it->second.id == [params[@"executionContextId"] intValue]))
        it = tab.scripts.contexts.erase(it);
      else ++it;
    }
  } else if ([method isEqual:@"Runtime.bindingCalled"] && [S(params, @"name") hasPrefix:@"yabScriptRelay_"]) {
    const ScriptContext* context = nullptr;
    for (auto& [key, value] : tab.scripts.contexts)
      if ([value.session isEqual:session] && value.id == [params[@"executionContextId"] intValue]) { context = &value; break; }
    if (!context) return;
    NSData* data = [S(params, @"payload") dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 1024 * 1024) return;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class]) return;
    NSArray* allowed = tab.scripts.relays[context->world];
    if (![allowed containsObject:S(value, @"name")] || !S(value, @"id").length) return;
    // Frame metadata comes only from CDP. The page cannot supply its origin.
    Event(@"script.relay", &tab, @{@"world": context->world, @"name": S(value, @"name"),
      @"request": S(value, @"id"), @"value": value[@"body"] ?: NSNull.null,
      @"frame": ScriptFrame(tab, *context)});
  }
}
// A tab CEF made with no URL has no DevTools agent until its first
// navigation starts, and the scripts must be in before the first document.
// So the agent is asked for with a blank document, which the first real load
// takes out of the history again (OnLoadEnd), and the request waits for it.
// `deadline`: the asking request's own (a page's scripts may wait as long as
// its load does: a renderer comes up late on a loaded Mac, not never).
static void ScriptWithAgent(std::string id, Completion ready, double deadline = 0, double asked = 0) {
  auto found = tabs.find(id);
  if (found == tabs.end() || found->second.closing) { ready(nil, @"Tab closed"); return; }
  Tab& tab = found->second;
  if (tab.domainsReady) { ready(@{}, nil); return; }
  if (asked == 0) {
    asked = Running();
    if (deadline == 0) deadline = asked + 15;
    if (tab.scriptBootstrapAllowed && tab.browser && !tab.browser->HasDocument() && !tab.scripts.blankFirst) {
      tab.scripts.blankFirst = true;
      if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore script bootstrap: tab=%s browser=%d at=%.6f\n", id.c_str(), tab.browser->GetIdentifier(), Now());
      tab.browser->GetMainFrame()->LoadURL("about:blank");
    }
  }
  if (Running() > deadline) { ready(nil, @"DevTools did not attach"); return; }
  // Every 5 ms while an agent is due, then every 50: eighty tabs waiting on
  // renderers no longer wake the main thread 16,000 times a second.
  int64_t every = Running() - asked < 1 ? 5 : 50;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, every * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    ScriptWithAgent(id, ready, deadline, asked);
  });
}
// A tab's scripts are nearly all every tab's, and each arrives as its own copy
// of a megabyte: one copy of each text, however many tabs keep it.
static NSArray* ScriptsShared(NSArray* scripts) {
  static NSHashTable<NSString*>* texts = [NSHashTable weakObjectsHashTable];
  NSMutableArray* shared = [NSMutableArray arrayWithCapacity:scripts.count];
  for (NSDictionary* script in scripts) {
    NSString* source = script[@"source"];
    NSString* known = [texts member:source];
    if (!known) { [texts addObject:source]; known = source; }
    NSMutableDictionary* copy = [script mutableCopy];
    copy[@"source"] = known;
    [shared addObject:copy];
  }
  return shared;
}
// Sets of page scripts the client defined once for this connection
// (YabCoreClient's ScriptBundles keeps at most 32 idle and forgets the rest);
// scripts.install names one instead of carrying its megabyte again. The
// client's count is the bound: sets in use by installs in flight can't be
// forgotten, and up to 128 installs fly at once, so a fixed 64 here refused
// a define while many tabs of different sites loaded.
static NSMutableDictionary<NSString*, NSArray*>* scriptBundles = [NSMutableDictionary new];
static void ClearScriptBundles() { [scriptBundles removeAllObjects]; }
// No count of scripts: Yab's own and every userscript and boost a person
// added, as Chromium takes any number of content and user scripts. The wire
// bounds a message's bytes.
static NSString* ScriptsInvalid(id scripts) {
  if (![scripts isKindOfClass:NSArray.class]) return @"Invalid scripts or relays";
  for (id script in scripts) {
    if (![script isKindOfClass:NSDictionary.class] || !S(script, @"source").length || S(script, @"world").length > 128 || [S(script, @"world") hasPrefix:@"__yab"])
      return @"Invalid page script";
  }
  return nil;
}
static bool ScriptBundleRequest(NSString* method, NSDictionary* params, NSString* request) {
  if (![method isEqual:@"scripts.define"] && ![method isEqual:@"scripts.forget"]) return false;
  NSString* name = S(params, @"bundle");
  if (!name.length || name.length > 128) { Reply(request, nil, @"Invalid script bundle"); return true; }
  if ([method isEqual:@"scripts.forget"]) { [scriptBundles removeObjectForKey:name]; Reply(request); return true; }
  if (NSString* invalid = ScriptsInvalid(params[@"scripts"])) { Reply(request, nil, invalid); return true; }
  scriptBundles[name] = ScriptsShared(params[@"scripts"]);
  Reply(request); return true;
}
// A request's deadline, as the client gave it (Request in core.mm), for the
// waits it makes: 0 when it has none left.
static double RequestDue(NSString* request) {
  auto due = requests.find(Key(request));
  return due != requests.end() ? due->second : 0;
}
static bool ScriptRequest(Tab& tab, NSString* method, NSDictionary* params, NSString* request) {
  // No renderer behind the tab: the one it had ended (a crash, memory, a
  // page that stopped answering) and no document has come since, or Chrome
  // discarded it. Its DevTools session holds what it is sent for the next
  // renderer, which only the navigation the client queues after these
  // requests brings; waiting for their answers held that navigation until
  // the CDP deadline and failed it: "The page couldn't load", 15 s after
  // coming back to any tab whose renderer ended behind another, until ⌘R
  // (feedback #1788). So they are sent, kept, and answered at once.
  bool noRenderer = tab.crashed || tab.discarded;
  if (!tab.domainsReady && !noRenderer && ([method isEqual:@"scripts.appearance"] || [method isEqual:@"scripts.install"])) {
    ScriptWithAgent(tab.id, [id = tab.id, method, params, request](NSDictionary*, NSString* error) {
      auto found = tabs.find(id);
      if (error || found == tabs.end()) { Reply(request, nil, error ?: @"Tab closed"); return; }
      ScriptRequest(found->second, method, params, request);
    }, RequestDue(request));
    return true;
  }
  if ([method isEqual:@"scripts.input"]) {
    NSString* kind = S(params, @"kind");
    auto commands = std::make_shared<ScriptCommands>();
    DragScriptInput(kind, *commands, true);
    int modifiers = [params[@"modifiers"] intValue];
    if ([kind isEqual:@"text"]) commands->push_back({@"Input.insertText", @{@"text": S(params, @"text")}});
    else if ([kind isEqual:@"key"]) {
      NSMutableDictionary* key = [@{@"type": @"keyDown", @"modifiers": @(modifiers), @"key": S(params, @"key"),
        @"code": S(params, @"code"), @"windowsVirtualKeyCode": params[@"keyCode"] ?: @0,
        @"nativeVirtualKeyCode": params[@"nativeCode"] ?: @0} mutableCopy];
      NSString* text = S(params, @"text");
      if ([S(params, @"key") isEqual:@"Enter"]) text = @"\r";
      if (text.length && !(modifiers & 6)) key[@"text"] = text;
      // CDP on macOS needs the editor command for native command shortcuts.
      if (modifiers & 4) {
        NSDictionary* editing = @{@"a": @"selectAll", @"c": @"copy", @"v": @"paste", @"x": @"cut", @"z": @"undo"};
        NSString* command = editing[[S(params, @"key") lowercaseString]];
        if ([command isEqual:@"undo"] && (modifiers & 8)) command = @"redo";
        if ([command isEqual:@"paste"] && (modifiers & 8)) command = @"pasteAndMatchStyle";
        if (command) key[@"commands"] = @[command];
      }
      if (modifiers == 2 && [[S(params, @"key") lowercaseString] isEqual:@"d"])
        key[@"commands"] = @[@"deleteForward"];
      commands->push_back({@"Input.dispatchKeyEvent", key});
      NSMutableDictionary* up = [key mutableCopy]; up[@"type"] = @"keyUp";
      [up removeObjectForKey:@"text"]; [up removeObjectForKey:@"commands"];
      commands->push_back({@"Input.dispatchKeyEvent", up});
    } else if ([kind isEqual:@"mousePressed"] || [kind isEqual:@"mouseReleased"] || [kind isEqual:@"mouseMoved"]) {
      double x = [params[@"x"] doubleValue], y = [params[@"y"] doubleValue];
      if (!std::isfinite(x) || !std::isfinite(y)) { Reply(request, nil, @"Invalid input coordinates"); return true; }
      commands->push_back({@"Input.dispatchMouseEvent", @{@"type": kind, @"x": @(x), @"y": @(y),
        @"button": S(params, @"button").length ? S(params, @"button") : @"none", @"buttons": params[@"buttons"] ?: @0,
        @"clickCount": params[@"clickCount"] ?: @0, @"modifiers": @(modifiers)}});
    } else { Reply(request, nil, @"Unknown script input"); return true; }
    DragScriptInput(kind, *commands, false);
    ScriptRun(tab.id, @"", commands, 0, [request](NSDictionary* value, NSString* error) { Reply(request, value, error); });
    return true;
  }
  if ([method isEqual:@"scripts.appearance"]) {
    NSDictionary* appearance = params[@"appearance"];
    NSString* scheme = [appearance isKindOfClass:NSDictionary.class] ? S(appearance, @"scheme") : nil;
    if (![scheme isEqual:@"light"] && ![scheme isEqual:@"dark"]) { Reply(request, nil, @"A light or dark scheme is required"); return true; }
    id ground = appearance[@"ground"];
    NSMutableDictionary* stored = [@{@"scheme": scheme} mutableCopy];
    if ([ground isKindOfClass:NSDictionary.class]) {
      NSMutableDictionary* color = [NSMutableDictionary dictionary];
      for (NSString* key in @[@"r", @"g", @"b"]) {
        id v = ground[key];
        if (![v isKindOfClass:NSNumber.class] || !std::isfinite([v doubleValue]) || [v doubleValue] < 0 || [v doubleValue] > 255) { Reply(request, nil, @"Invalid ground"); return true; }
        color[key] = @((int)lround([v doubleValue]));
      }
      id a = ground[@"a"];
      double alpha = [a isKindOfClass:NSNumber.class] ? [a doubleValue] : 1;
      if (!std::isfinite(alpha) || alpha < 0 || alpha > 1) { Reply(request, nil, @"Invalid ground"); return true; }
      color[@"a"] = @(alpha);
      stored[@"ground"] = color;
    } else if (ground && ground != NSNull.null) { Reply(request, nil, @"Invalid ground"); return true; }
    if ([appearance[@"focused"] isKindOfClass:NSNumber.class]) stored[@"focused"] = @([appearance[@"focused"] boolValue]);
    // Chrome draws a page's surface in the theme's ground until the first
    // frame, and takes the theme from the process's appearance: the same
    // scheme, so the ground before the first frame is not a white flash.
    NSAppearance* wanted = [NSAppearance appearanceNamed:[scheme isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    if (wanted && ![NSApp.appearance.name isEqual:wanted.name]) NSApp.appearance = wanted;
    tab.scripts.appearance = stored;
    // No agent yet: ScriptAttach applies it when one comes.
    if (!tab.domainsReady) { Reply(request, @{}); return true; }
    auto sessions = std::make_shared<std::vector<std::string>>(tab.scripts.sessions.begin(), tab.scripts.sessions.end());
    if (sessions->empty()) sessions->push_back("");
    if (noRenderer) {
      for (const auto& session : *sessions) {
        auto commands = std::make_shared<ScriptCommands>();
        ScriptAppearance(tab, *commands);
        ScriptRun(tab.id, @(session.c_str()), commands, 0, Ignore);
      }
      Reply(request, @{}); return true;
    }
    auto remaining = std::make_shared<size_t>(sessions->size());
    auto failure = std::make_shared<NSString*>(nil);
    for (const auto& session : *sessions) {
      auto commands = std::make_shared<ScriptCommands>();
      ScriptAppearance(tab, *commands);
      ScriptRun(tab.id, @(session.c_str()), commands, RequestDue(request), [id = tab.id, session, request, remaining, failure](NSDictionary*, NSString* error) {
        auto owner = tabs.find(id);
        if (owner == tabs.end()) *failure = @"Tab closed";
        else if (ScriptSessionErrorMatters(@(session.c_str()), owner->second.scripts.sessions.count(session), error)) *failure = error;
        if (--*remaining) return;
        Reply(request, @{}, *failure);
      });
    }
    return true;
  }
  if ([method isEqual:@"scripts.install"]) {
    id scripts = params[@"scripts"], relays = params[@"relays"];
    if (params[@"immediately"] && ![params[@"immediately"] isKindOfClass:NSNumber.class]) {
      Reply(request, nil, @"Invalid immediate script installation"); return true;
    }
    if (S(params, @"bundle").length) {
      scripts = scriptBundles[S(params, @"bundle")];
      if (!scripts) { Reply(request, nil, @"Unknown script bundle"); return true; }
    }
    if (![relays isKindOfClass:NSDictionary.class]) { Reply(request, nil, @"Invalid scripts or relays"); return true; }
    if (NSString* invalid = ScriptsInvalid(scripts)) { Reply(request, nil, invalid); return true; }
    for (NSString* world in relays) {
      id names = relays[world];
      if (!world.length || world.length > 128 || [world hasPrefix:@"__yab"] || ![names isKindOfClass:NSArray.class] || [names count] > 64) {
        Reply(request, nil, @"Relays require an isolated world"); return true;
      }
      for (id name in names) if (![name isKindOfClass:NSString.class] || ![name length] || [name length] > 128) {
        Reply(request, nil, @"Invalid relay name"); return true;
      }
    }
    if (tab.scripts.applying) { Reply(request, nil, @"Scripts are already being installed"); return true; }
    // A world added to an install already in place; a first install runs
    // nothing in the document up now, as before.
    NSMutableSet* fresh = [NSMutableSet set];
    if (tab.scripts.relays.count)
      for (NSString* world in relays) if (!tab.scripts.relays[world]) [fresh addObject:world];
    tab.scripts.definitions = ScriptsShared(scripts); tab.scripts.relays = relays;
    if (!tab.domainsReady) { Reply(request); return true; }
    if (noRenderer) {
      std::vector<std::string> sessions(tab.scripts.sessions.begin(), tab.scripts.sessions.end());
      if (sessions.empty()) sessions.push_back("");
      for (const auto& session : sessions) ScriptSetup(tab, @(session.c_str()), [params[@"immediately"] boolValue], Ignore);
      Reply(request); return true;
    }
    tab.scripts.applying = true;
    auto sessions = std::make_shared<std::vector<std::string>>(tab.scripts.sessions.begin(), tab.scripts.sessions.end());
    if (sessions->empty()) sessions->push_back("");
    auto remaining = std::make_shared<size_t>(sessions->size());
    auto failure = std::make_shared<NSString*>(nil);
    // Adopted native pages may have committed before the client attached.
    // Install their bridge and features into that original document too.
    for (const auto& session : *sessions) ScriptSetup(tab, @(session.c_str()), [params[@"immediately"] boolValue], [id = tab.id, session, request, remaining, failure](NSDictionary*, NSString* error) {
      auto owner = tabs.find(id);
      if (owner == tabs.end()) *failure = @"Tab closed";
      else if (ScriptSessionErrorMatters(@(session.c_str()), owner->second.scripts.sessions.count(session), error)) *failure = error;
      if (--*remaining) return;
      auto found = tabs.find(id); if (found != tabs.end()) found->second.scripts.applying = false;
      Reply(request, @{}, *failure);
    }, fresh, RequestDue(request));
    return true;
  }
  if ([method isEqual:@"scripts.reply"] || [method isEqual:@"scripts.evaluate"]) {
    auto found = tab.scripts.contexts.find(Key(S(params, @"frame")));
    if (found == tab.scripts.contexts.end()) { Reply(request, nil, @"Stale or foreign frame"); return true; }
    ScriptContext context = found->second;
    if ([method isEqual:@"scripts.reply"]) {
      if (!tab.scripts.relays[context.world]) { Reply(request, nil, @"Not a relay context"); return true; }
      NSString* expression = [NSString stringWithFormat:@"globalThis.__yabScriptReply(%@,%@,%@)", JSON(S(params, @"request")), JSON(params[@"value"]), JSON(params[@"error"])];
      CDP(tab, @"Runtime.evaluate", @{@"expression": expression, @"uniqueContextId": context.token},
        [request](NSDictionary* result, NSString* error) { Reply(request, result, error); }, context.session);
      return true;
    }
    NSString* world = S(params, @"world"), *function = S(params, @"function");
    if (!function.length || world.length > 128 || [world hasPrefix:@"__yab"]) { Reply(request, nil, @"Invalid evaluation"); return true; }
    auto run = [id = tab.id, request, context, function, params](int executionContext) {
      auto current = tabs.find(id);
      if (current == tabs.end() || !current->second.scripts.contexts.count(Key(context.token))) { Reply(request, nil, @"Stale frame"); return; }
      NSString* unique = nil;
      for (const auto& [key, candidate] : current->second.scripts.contexts)
        if ([candidate.session isEqual:context.session] && candidate.id == executionContext) { unique = candidate.token; break; }
      if (!unique) { Reply(request, nil, @"Execution context unavailable"); return; }
      NSString* expression = S(params, @"expression");
      if (expression.length) {
        CDP(current->second, @"Runtime.evaluate", @{@"expression": expression, @"uniqueContextId": unique, @"awaitPromise": @YES,
          @"returnByValue": @YES, @"replMode": @YES, @"userGesture": @([params[@"userGesture"] boolValue])}, [request](NSDictionary* result, NSString* error) {
            Reply(request, error ? nil : WholeValue(result), error ?: (result[@"exceptionDetails"] ? JSON(result[@"exceptionDetails"]) : nil));
          }, context.session);
        return;
      }
      if (params[@"files"]) {
        // An agent's upload in this frame: the function returns its file field (agent_files.inc).
        NSArray* files = AgentFilePaths(params[@"files"]);
        if (!files) { Reply(request, nil, @"files must be absolute file paths"); return; }
        CDP(current->second, @"Runtime.callFunctionOn", @{@"functionDeclaration": function, @"uniqueContextId": unique,
          @"arguments": @[@{@"value": params[@"arguments"] ?: NSNull.null}], @"awaitPromise": @YES, @"returnByValue": @NO},
          [request, id, files, session = context.session](NSDictionary* result, NSString* error) {
            auto owner = tabs.find(id);
            if (owner == tabs.end()) { Reply(request, nil, @"Tab closed"); return; }
            AgentSetFiles(owner->second, result, error, files, session, request);
          }, context.session);
        return;
      }
      CDP(current->second, @"Runtime.callFunctionOn", @{@"functionDeclaration": function, @"uniqueContextId": unique,
        @"arguments": @[@{@"value": params[@"arguments"] ?: NSNull.null}], @"awaitPromise": @YES, @"returnByValue": @YES,
        @"userGesture": @([params[@"userGesture"] boolValue])}, [request](NSDictionary* result, NSString* error) {
          Reply(request, result[@"result"][@"value"] ?: NSNull.null, error ?: (result[@"exceptionDetails"] ? JSON(result[@"exceptionDetails"]) : nil));
        }, context.session);
    };
    if ([world isEqual:context.world] || (!world.length && context.isDefault)) run(context.id);
    else if (world.length && ([&]() {
      // A world of that name this frame already has (made by an earlier call or
      // by a script registered for it): reuse it, each Page.createIsolatedWorld
      // makes a new one, and a script defined in one is not seen from another.
      for (const auto& [key, candidate] : tab.scripts.contexts)
        if ([candidate.session isEqual:context.session] && [candidate.frame isEqual:context.frame] && [candidate.world isEqual:world]) {
          run(candidate.id); return true;
        }
      return false;
    })()) {}
    else if (world.length) CDP(tab, @"Page.createIsolatedWorld", @{@"frameId": context.frame, @"worldName": world},
      [run, request, id = tab.id, world, context](NSDictionary* result, NSString* error) {
        if (error) { Reply(request, nil, error); return; }
        int created = [result[@"executionContextId"] intValue];
        // A world made now, in a document that is already up, never saw the
        // bridge the new-document script gives it: give it, once, so a script
        // run there (dark pages turned on live) can reach its relay.
        auto current = tabs.find(id);
        NSArray* names = current == tabs.end() ? nil : current->second.scripts.relays[world];
        if (!names.count) { run(created); return; }
        NSString* once = [NSString stringWithFormat:@"if(!globalThis.__yabScriptReply){%@}", ScriptBridge(names, world)];
        CDP(current->second, @"Runtime.evaluate", @{@"expression": once, @"contextId": @(created)},
          [run, created](NSDictionary*, NSString*) { run(created); }, context.session);
      }, context.session);
    else {
      bool foundDefault = false;
      for (auto& [key, candidate] : tab.scripts.contexts) if (candidate.isDefault && [candidate.session isEqual:context.session] && [candidate.frame isEqual:context.frame]) {
        run(candidate.id); foundDefault = true; break;
      }
      if (!foundDefault) Reply(request, nil, @"Document context unavailable");
    }
    return true;
  }
  if ([method isEqual:@"scripts.status"]) {
    NSMutableArray* contexts = [NSMutableArray new], *sessions = [NSMutableArray new];
    for (auto& [key, context] : tab.scripts.contexts) {
      NSMutableDictionary* value = [ScriptFrame(tab, context) mutableCopy];
      value[@"nativeDocument"] = context.nativeDocument; value[@"world"] = context.world; value[@"session"] = context.session; value[@"default"] = @(context.isDefault);
      [contexts addObject:value];
    }
    for (const auto& session : tab.scripts.sessions) [sessions addObject:@(session.c_str())];
    Reply(request, @{@"contexts": contexts, @"sessions": sessions}); return true;
  }
  if ([method isEqual:@"scripts.frames"]) {
    CDP(tab, @"Page.getFrameTree", @{}, [id = tab.id, request](NSDictionary* result, NSString* error) {
      auto found = tabs.find(id);
      if (error || found == tabs.end()) { Reply(request, nil, error ?: @"Tab closed"); return; }
      NSString* main = result[@"frameTree"][@"frame"][@"id"];
      ScriptTree(found->second, result[@"frameTree"]);
      NSMutableArray* frames = [NSMutableArray new];
      std::set<std::string> visited;
      std::function<void(std::string, int)> walk = [&](std::string frame, int depth) {
        if (depth >= 8 || frames.count >= 40 || !visited.insert(frame).second) return;
        if (frame != Key(main)) for (const auto& [key, context] : found->second.scripts.contexts)
          if (context.isDefault && Key(context.frame) == frame) { [frames addObject:ScriptFrame(found->second, context)]; break; }
        for (const auto& child : found->second.scripts.frameOrder) {
          auto parent = found->second.scripts.parents.find(child);
          if (parent != found->second.scripts.parents.end() && parent->second == frame) walk(child, depth + 1);
        }
      };
      walk(Key(main), 0);
      Reply(request, frames);
    });
    return true;
  }
  return false;
}
