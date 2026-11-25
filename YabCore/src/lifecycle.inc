static void ForceCloseUnresponsive(Tab& tab) {
  // Never signal a process still serving a tab outside this close batch.
  // Interrupt its script instead, leaving those documents and their process
  // alive. Most tabs have a private renderer, which can be ended directly.
  bool shared = std::any_of(tabs.begin(), tabs.end(), [&](const auto& row) {
    return row.first != tab.id && !row.second.closing && tab.rendererPID > 0 &&
           row.second.rendererPID == tab.rendererPID;
  });
  Mark(shared ? "close.interrupt-shared-renderer" : "close.end-renderer", tab.id);
  if (shared) {
    // The ordinary CDP wrapper deliberately rejects closing tabs. This
    // lifecycle-only interrupt is dispatched after batch authorization, so
    // use the host directly; no renderer callback is needed to keep closing.
    tab.browser->GetHost()->ExecuteDevToolsMethod(++sequence,
        "Runtime.terminateExecution", CefDictionaryValue::Create());
    tab.browser->GetHost()->CloseBrowser(true);
    return;
  }
  // Authenticate the child and its birth time before sending any signal.
  struct proc_bsdinfo info = {};
  if (tab.rendererPID > 0 && proc_pidinfo(tab.rendererPID, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
      info.pbi_ppid == getpid() && info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec == tab.rendererBorn)
    kill(tab.rendererPID, SIGKILL);
  tab.browser->GetHost()->CloseBrowser(true);
}

// A committed endpoint must disappear even if its renderer never unloads.
static void WatchCommittedClose(std::string id) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    auto found = tabs.find(id);
    if (found != tabs.end() && found->second.closing && found->second.browser)
      ForceCloseUnresponsive(found->second);
  });
}

// Native non-destructive approvals and final original-document outcomes.
#if YABCORE_CLOSE_PREFLIGHT
struct NativeCloseScope { NativeCloseScope() { ++nativeCloseDepth; } ~NativeCloseScope() { --nativeCloseDepth; } };
struct CloseMember {
  std::string tab;
  NSString* owner;
  NSString* request;
  NSString* document;
  NSString* token;
  bool final = false, closed = false;
};
struct CloseBatch {
  NSString* wire;
  std::vector<CloseMember> members;
  bool dispatching = true;
};
static std::map<std::string, CloseBatch> closeBatches;
static void ReplyCloseBatch(const std::string& id, bool expired = false) {
  auto found = closeBatches.find(id); if (found == closeBatches.end() || found->second.dispatching) return;
  bool complete = std::all_of(found->second.members.begin(), found->second.members.end(), [](const auto& member) { return member.final; });
  if (!complete && !expired) return;
  NSMutableArray* closed = [NSMutableArray new], *retained = [NSMutableArray new], *unknown = [NSMutableArray new];
  for (const auto& member : found->second.members) {
    if (!member.final) [unknown addObject:@(member.tab.c_str())];
    else [(member.closed ? closed : retained) addObject:@(member.tab.c_str())];
  }
  NSString* wire = found->second.wire; found->second.wire = nil;
  if (complete) closeBatches.erase(found);
  if (wire.length) Reply(wire, @{@"complete": @(complete), @"closed": closed, @"retained": retained, @"unknown": unknown});
}
static void RecordCloseFinal(Tab& tab, NSDictionary* state) {
  std::vector<std::string> ready;
  for (auto& [id, batch] : closeBatches) {
    for (auto& member : batch.members) {
      if (member.tab != tab.id || member.final || ![member.owner isEqual:tab.closeOwner] ||
          ![member.request isEqual:S(state, @"request")] || ![member.document isEqual:S(state, @"document")] ||
          ![member.token isEqual:S(state, @"token")]) continue;
      member.final = true; member.closed = [state[@"closed"] boolValue];
      // A replacement native document remains a usable tab. An unknown
      // in-flight unload stays closing until a real final state arrives.
      if (!member.closed) {
        tab.closing = false;
        // Leave the native close callback before sending any touch cleanup.
        const auto tabID = tab.id;
        dispatch_async(dispatch_get_main_queue(), ^{ TouchPump(tabID); });
      }
      ready.push_back(id);
    }
  }
  for (const auto& id : ready) ReplyCloseBatch(id);
}
static void NativeClosePreflight(Tab* tab, CefRefPtr<CefDictionaryValue> native) {
  NativeCloseScope scope; // Even a wire overflow cannot synchronously shut down another browser here.
  if (!tab || !tab->browser || !tab->closeOwner.length) return;
  NSDictionary* state = NativeDictionary(native);
  if (![state[@"version"] isEqual:@1] || [state[@"browserId"] intValue] != tab->browser->GetIdentifier() ||
      !S(state, @"request").length || !S(state, @"document").length) return;
  // Once force-close is dispatched, native renderer-gone/retained events
  // describe the abandoned preflight, not the force-close receipt. Only
  // OnBeforeClose may confirm destruction of that endpoint.
  if (tab->closeUnresponsive && (tab->closing || [S(state, @"reason") isEqual:@"renderer-timeout"])) return;
  // A late pending/approved notification cannot replace the recovery token
  // already returned to the client. Real Stay and document retirement still
  // revoke it while another page's question holds the batch open.
  if (tab->closeUnresponsive && ![state[@"withdrawn"] boolValue] &&
      !([state[@"decision"] boolValue] && ![state[@"allow"] boolValue])) return;
  NSString* expected = S(tab->closePreflight, @"request");
  if (expected.length && ![expected isEqual:S(state, @"request")]) return;
  if (S(tab->closePreflight, @"document").length && ![S(tab->closePreflight, @"document") isEqual:S(state, @"document")]) return;
  if ([state[@"final"] boolValue] &&
      (!S(tab->closePreflight, @"token").length || ![S(tab->closePreflight, @"token") isEqual:S(state, @"token")] ||
       ![@[@"closed", @"retained"] containsObject:S(state, @"phase")] ||
       [state[@"closed"] boolValue] != [S(state, @"phase") isEqual:@"closed"])) return;
  tab->closeUnresponsive = false;
  tab->closePreflight = state;
  NSMutableDictionary* event = [state mutableCopy]; event[@"owner"] = tab->closeOwner;
  Event(@"tab.closePreflight", tab, event);
  if ([state[@"final"] boolValue]) {
    RecordCloseFinal(*tab, state);
    if (![state[@"closed"] boolValue]) tab->closeOwner = nil;
    return;
  }
  if ([state[@"decision"] boolValue] || [state[@"withdrawn"] boolValue]) {
    NSString* wire = tab->closeWireRequest; tab->closeWireRequest = nil;
    if (wire.length) Reply(wire, event);
  }
}
static void CancelClosePreflight(Tab& tab) {
  NSString* owner = tab.closeOwner, *request = S(tab.closePreflight, @"request");
  if (request.length && tab.browser && !tab.closing && ![tab.closePreflight[@"final"] boolValue])
    tab.browser->GetHost()->CancelClosePreflight(Key(request));
  NSString* wire = tab.closeWireRequest; tab.closeWireRequest = nil;
  if (!tab.closing) { tab.closeOwner = nil; tab.closePreflight = nil; tab.closeUnresponsive = false; }
  if (owner.length) CancelCloseDialogs(tab.id, owner);
  if (wire.length) Reply(wire, nil, @"Native close preflight cancelled");
}
// A renderer that never returns from beforeunload cannot veto a user's
// close forever. Reserve a force-close approval, but do not destroy anything
// until the whole batch agrees. A real dialog has no deadline.
static void WatchClosePreflight(std::string id, NSString* owner, NSString* wire) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    auto found = tabs.find(id);
    if (found == tabs.end()) return;
    auto& tab = found->second;
    if (![tab.closeOwner isEqual:owner] || ![tab.closeWireRequest isEqual:wire] || tab.closing) return;
    for (const auto& [key, question] : pageQuestions) {
      if (question.tab == id && question.isDialog) {
        WatchClosePreflight(id, owner, wire); return;
      }
    }
    if (tab.documentGeneration != tab.closeDocumentGeneration || !tab.browser) {
      CancelClosePreflight(tab); return;
    }
    NSMutableDictionary* state = [tab.closePreflight mutableCopy];
    if (!S(state, @"request").length || !S(state, @"document").length) {
      CancelClosePreflight(tab); return;
    }
    state[@"version"] = @1; state[@"browserId"] = @(tab.browser->GetIdentifier());
    state[@"phase"] = @"approved"; state[@"decision"] = @YES; state[@"allow"] = @YES;
    state[@"token"] = NSUUID.UUID.UUIDString; state[@"owner"] = owner;
    state[@"unresponsive"] = @YES;
    Mark("close.preflight-timeout", tab.id);
    tab.closeUnresponsive = true; tab.closePreflight = state; tab.closeWireRequest = nil;
    Reply(wire, state);
  });
}
static void LifecycleBeforeClose(Tab& tab) {
  // The native observer emits final before delegate Close. An external
  // browser destruction may instead arrive here: record the real endpoint
  // death, never infer closure from dispatch or a timer.
  if (tab.closing && tab.closeOwner.length) {
    NSMutableDictionary* final = [tab.closePreflight mutableCopy];
    final[@"final"] = @YES; final[@"closed"] = @YES; final[@"phase"] = @"closed";
    RecordCloseFinal(tab, final);
  }
  CancelClosePreflight(tab);
}
#endif

static bool LifecycleExpireRequest(NSString* request) {
#if YABCORE_CLOSE_PREFLIGHT
  if (closeBatches.count(Key(request))) { ReplyCloseBatch(Key(request), true); return true; }
  for (auto& [id, tab] : tabs) if ([tab.closeWireRequest isEqual:request]) { CancelClosePreflight(tab); return true; }
#else
  (void)request;
#endif
  return false;
}

static bool LifecycleBatchRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"tabs.close.commit"]) return false;
#if YABCORE_CLOSE_PREFLIGHT
  NSArray* approvals = [p[@"approvals"] isKindOfClass:NSArray.class] ? p[@"approvals"] : nil;
  // A tab is in one batch at most (closing below), so batches are bounded
  // by the tabs there are; a fixed 64 failed closes past it.
  if (!approvals.count || approvals.count > tabs.size()) { Reply(request, nil, @"Expected bounded native close approvals"); return true; }
  struct Commit { std::string tab, token; CefRefPtr<CefBrowserHost> host; bool unresponsive; };
  std::vector<Commit> commits;
  CloseBatch batch; batch.wire = request;
  std::set<std::string> seen;
  NativeCloseScope scope;
  // No event-loop yield or client/native mutation between validate-all and dispatch-all.
  for (::id row in approvals) {
    NSDictionary* item = [row isKindOfClass:NSDictionary.class] ? row : @{};
    auto found = tabs.find(Key(S(item, @"tab")));
    if (found == tabs.end() || !found->second.browser || found->second.closing || !found->second.adopted || !seen.insert(found->first).second) {
      Reply(request, nil, @"Close batch contains an unavailable or duplicate tab"); return true;
    }
    auto& t = found->second; NSString* token = S(item, @"token");
    if (!token.length || ![S(item, @"owner") isEqual:t.closeOwner] ||
        ![S(item, @"document") isEqual:S(t.closePreflight, @"document")] || ![token isEqual:S(t.closePreflight, @"token")] ||
        ![t.closePreflight[@"allow"] boolValue] || [t.closePreflight[@"withdrawn"] boolValue] ||
        (t.closeUnresponsive ? t.documentGeneration != t.closeDocumentGeneration : !t.browser->GetHost()->ValidateClosePreflight(Key(token))) ||
        std::any_of(pageQuestions.begin(), pageQuestions.end(), [&](const auto& row) {
          return row.second.tab == t.id && row.second.isDialog;
        })) {
      Reply(request, nil, @"A native close approval expired; no page was closed"); return true;
    }
    batch.members.push_back({found->first, t.closeOwner, S(t.closePreflight, @"request"), S(t.closePreflight, @"document"), token});
    commits.push_back({found->first, Key(token), t.browser->GetHost(), t.closeUnresponsive});
  }
  const std::string id = Key(request);
  closeBatches.emplace(id, std::move(batch)); requests[id] = Now() + 240;
  for (const auto& commit : commits) {
    auto& tab = tabs.at(commit.tab);
    tab.closing = true;
    // The preceding client reset recorded which delayed steps to reject.
    tab.touch.Interrupt();
  }
  for (const auto& commit : commits) {
    if (commit.unresponsive) {
      ForceCloseUnresponsive(tabs.at(commit.tab));
    } else if (!commit.host->CommitClosePreflight(commit.token)) {
      // Refusal is a retained outcome, never a force-close retry.
      auto found = tabs.find(commit.tab);
      if (found != tabs.end()) {
        NSMutableDictionary* final = [found->second.closePreflight mutableCopy];
        final[@"final"] = @YES; final[@"closed"] = @NO; final[@"phase"] = @"retained";
        RecordCloseFinal(found->second, final);
      }
    }
  }
  for (const auto& commit : commits) {
    std::string tabID = commit.tab;
    NSString* owner = tabs.count(tabID) ? tabs.at(tabID).closeOwner : nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      auto found = tabs.find(tabID);
      if (found != tabs.end() && found->second.closing && found->second.browser &&
          [found->second.closeOwner isEqual:owner]) {
        found->second.closeUnresponsive = true;
        ForceCloseUnresponsive(found->second);
      }
    });
  }
  auto current = closeBatches.find(id);
  if (current != closeBatches.end()) current->second.dispatching = false;
  ReplyCloseBatch(id);
#else
  (void)p;
  Reply(request, nil, @"Non-destructive native close is unavailable in this SDK/API mode");
#endif
  return true;
}

static bool LifecycleRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"tab.close.prepare"]) {
#if YABCORE_CLOSE_PREFLIGHT
    NSString* owner = S(p, @"owner");
    if (!owner.length || owner.length > 128 || tab.closeOwner.length) {
      Reply(request, nil, @"Invalid or competing native close preflight"); return true;
    }
    tab.closeOwner = owner; tab.closeWireRequest = request; tab.closePreflight = nil;
    tab.closeUnresponsive = false; tab.quitUnresponsive = false; tab.closeDocumentGeneration = tab.documentGeneration;
    requests[Key(request)] = Now() + 240;
    NSDictionary* begin = NativeDictionary(tab.browser->GetHost()->BeginClosePreflight());
    if (![begin[@"accepted"] boolValue] || !S(begin, @"request").length || !S(begin, @"document").length) {
      CancelClosePreflight(tab);
      return true;
    }
    // A no-listener native decision is permitted to arrive synchronously.
    if (!tab.closePreflight) tab.closePreflight = begin;
    // Engine switches are non-destructive and must never force an approval.
    if ([p[@"allowUnresponsive"] boolValue]) WatchClosePreflight(tab.id, owner, request);
#else
    (void)p;
    Reply(request, nil, @"Non-destructive native close is unavailable in this SDK/API mode");
#endif
    return true;
  }
  if ([method isEqual:@"tab.close.cancel"]) {
#if YABCORE_CLOSE_PREFLIGHT
    if (![S(p, @"owner") isEqual:tab.closeOwner]) { Reply(request, nil, @"Close preflight owner changed"); return true; }
    // Reserve cleanup only for an approved quit. The app can still cancel
    // its own quit warning; no renderer is touched until helper shutdown.
    tab.quitUnresponsive = [p[@"quitting"] boolValue] && tab.closeUnresponsive &&
                          tab.documentGeneration == tab.closeDocumentGeneration;
    CancelClosePreflight(tab); Reply(request);
#else
    Reply(request, nil, @"Non-destructive native close is unavailable in this SDK/API mode");
#endif
    return true;
  }
  if ([method isEqual:@"tab.tryClose"]) {
    bool now = tab.browser->GetHost()->TryCloseBrowser();
    Reply(request, @{@"immediate": @(now)});
    return true;
  }
  if (![method isEqual:@"page.beforeUnloadListeners"]) return false;
  std::string id = tab.id;
  CDP(tab, @"Runtime.evaluate", @{@"expression": @"window", @"returnByValue": @NO}, [id, request](NSDictionary* r, NSString* e) {
    auto t = tabs.find(id);
    NSString* object = S(r[@"result"], @"objectId");
    if (e || t == tabs.end() || !object.length) { Reply(request, nil, e ?: @"No window object"); return; }
    CDP(t->second, @"DOMDebugger.getEventListeners", @{@"objectId": object}, [id, request, object](NSDictionary* r, NSString* e) {
      int count = 0;
      for (NSDictionary* listener in r[@"listeners"]) if ([S(listener, @"type") isEqual:@"beforeunload"]) count++;
      auto t = tabs.find(id);
      if (t != tabs.end()) CDP(t->second, @"Runtime.releaseObject", @{@"objectId": object}, Ignore);
      if (e) Reply(request, nil, e); else Reply(request, @{@"count": @(count)});
    });
  });
  return true;
}
