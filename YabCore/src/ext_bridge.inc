// Local app IPC only. All extension identity comes from a privileged profile tab,
// never from a web page, and all nested CDP sessions are profile-checked.
#include "ext_bridge_worker.inc"
// DevTools observers disallow reentrant dispatch. Start every bridge command
// on the next UI turn, including commands chained from a nested-session reply.
static void ExtensionCDP(Tab& tab, NSString* method, NSDictionary* params, Completion done) {
  auto id=tab.id;
  dispatch_async(dispatch_get_main_queue(),^{
    auto current=tabs.find(id);
    if(current==tabs.end()){done(nil,@"Extension control tab closed");return;}
    CDP(current->second,method,params,done);
  });
}
struct ExtensionWorker { std::string tab, extension, session; };
struct ExtensionCall { Completion done; double deadline; std::string session; };
struct ExtensionVirtual { std::string control, profile, document; int number, frame; NSString* url; NSString* topURL; };
static std::map<std::string, ExtensionWorker> extensionWorkers;
static std::map<std::string, std::string> extensionWorkerStates;
using ExtensionWaiter = std::pair<std::function<void(ExtensionWorker)>, Completion>;
static std::map<std::string, std::vector<ExtensionWaiter>> extensionOpening;
static std::map<int, ExtensionCall> extensionCalls;
static std::map<std::string, ExtensionVirtual> extensionVirtuals;
static NSMutableDictionary* extensionCatalogs = [NSMutableDictionary new];
static int extensionSequence = 0, virtualSequence = 1000000;
static std::map<std::string, int> extensionTabNumbers;
static NSMutableDictionary* extensionRoots = [NSMutableDictionary new];
// A closed profile's bridge state goes with it: every private window is a
// profile of its own, so these grew by one each all day.
static void ExtensionProfileClosed(const std::string& profile) {
  const std::string prefix = profile + ":";
  auto mine = [&](const std::string& key) { return key.rfind(prefix, 0) == 0; };
  for (auto i = extensionWorkerStates.begin(); i != extensionWorkerStates.end();) i = mine(i->first) ? extensionWorkerStates.erase(i) : std::next(i);
  for (auto i = extensionTabNumbers.begin(); i != extensionTabNumbers.end();) i = mine(i->first) ? extensionTabNumbers.erase(i) : std::next(i);
  for (auto i = extensionVirtuals.begin(); i != extensionVirtuals.end();) i = i->second.profile == profile ? extensionVirtuals.erase(i) : std::next(i);
  [extensionCatalogs removeObjectForKey:@(profile.c_str())];
  [extensionRoots removeObjectForKey:@(profile.c_str())];
}
// Frames of one WebKit tab's documents (ext.bridge.register): no count across
// tabs, and within one, as WebKit gives no word when a frame goes, the oldest
// subframe makes way past this many instead of the newest being refused.
// ChromiumDRMExtensions keeps the same number of documents per tab.
static constexpr size_t kVirtualFramesPerTab = 2048;
static bool ExtensionMatch(NSString* pattern, NSString* address) {
  NSURL* url = [NSURL URLWithString:address];
  if (![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]) return false;
  if ([pattern isEqual:@"<all_urls>"]) return true;
  NSRange sep = [pattern rangeOfString:@"://"];
  if (sep.location == NSNotFound) return false;
  NSString* scheme = [pattern substringToIndex:sep.location];
  if (![scheme isEqual:@"*"] && ![scheme isEqual:url.scheme.lowercaseString]) return false;
  NSString* tail = [pattern substringFromIndex:sep.location + 3];
  NSRange slash = [tail rangeOfString:@"/"]; if (slash.location == NSNotFound) return false;
  NSString* host = [[tail substringToIndex:slash.location] lowercaseString], *actual = url.host.lowercaseString;
  if (![host isEqual:@"*"] && ![host isEqual:actual] && !([host hasPrefix:@"*."] && ([actual isEqual:[host substringFromIndex:2]] || [actual hasSuffix:[host substringFromIndex:1]]))) return false;
  NSString* path = [NSRegularExpression escapedPatternForString:[tail substringFromIndex:slash.location]];
  path = [path stringByReplacingOccurrencesOfString:@"\\*" withString:@".*"];
  NSString* candidate = [(url.path.length ? url.path : @"/") stringByAppendingString:url.query ? [@"?" stringByAppendingString:url.query] : @""];
  return [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^%@$", path] options:0 error:nil] &&
    [[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^%@$", path] options:0 error:nil] numberOfMatchesInString:candidate options:0 range:NSMakeRange(0,candidate.length)] > 0;
}
// Chromium's storage_utils reads these extension-specific pref integers.
// Read only their allow/deny values from the live profile, never storage data.
static NSDictionary* ExtensionStorageAccess(Tab& tab, NSString* extension) {
  auto value=tab.browser->GetHost()->GetRequestContext()->GetPreference("extensions.settings");
  if(!value||value->GetType()!=VTYPE_DICTIONARY)return nil;
  auto settings=value->GetDictionary();auto entry=settings->GetDictionary(Key(extension));
  if(!entry)return nil;
  NSMutableDictionary* access=[NSMutableDictionary new];
  for(NSString* area in @[@"local",@"sync",@"managed",@"session"]){
    std::string key=Key([NSString stringWithFormat:@"storage_%@_access_level",area]);
    int level=entry->HasKey(key)&&entry->GetType(key)==VTYPE_INT?entry->GetInt(key):([area isEqual:@"session"]?1:2);
    access[area]=@(level==2);
  }
  return access;
}
static bool ExtensionAllowed(NSDictionary* entry, NSString* url) {
  for (NSString* host in entry[@"grants"]) if (ExtensionMatch(host, url)) return true;
  return false;
}
static void ExtensionNested(Tab& control, NSString* session, NSString* method, NSDictionary* params, Completion done) {
  int id = ++extensionSequence;
  extensionCalls.emplace(id, ExtensionCall{done, Now()+15, Key(session)});
  ExtensionCDP(control, @"Target.sendMessageToTarget", @{@"sessionId":session,@"message":JSON(@{@"id":@(id),@"method":method,@"params":params})},
    [id](NSDictionary*,NSString* error){if(!error)return;auto i=extensionCalls.find(id);if(i!=extensionCalls.end()){auto c=i->second.done;extensionCalls.erase(i);c(nil,error);}});
}
static void ExtensionEvaluate(const ExtensionWorker& worker, NSString* expression, Completion done) {
  auto t=tabs.find(worker.tab);if(t==tabs.end()){done(nil,@"Extension control tab closed");return;}
  ExtensionNested(t->second,@(worker.session.c_str()),@"Runtime.evaluate",@{@"expression":expression,@"awaitPromise":@YES,@"returnByValue":@YES},
   [done](NSDictionary* r,NSString* e){if(!e&&r[@"exceptionDetails"])e=[@"Extension JavaScript: " stringByAppendingString:JSON(r[@"exceptionDetails"])];done(e?nil:r[@"result"][@"value"],e);});
}
static void ExtensionFindWorker(std::string tab, std::string key, NSString* extension, NSString* context,
                                std::function<void(ExtensionWorker)> action, Completion fail, int attempt=0) {
  auto t=tabs.find(tab);if(t==tabs.end()){fail(nil,@"Control tab closed");return;}
  ExtensionCDP(t->second,@"Target.getTargets",@{},[tab,key,extension,context,action,fail,attempt](NSDictionary* r,NSString* error){
    auto t=tabs.find(tab);if(error||t==tabs.end()){fail(nil,error?:@"Control tab closed");return;}
    NSDictionary* found=nil;
    for(NSDictionary* target in r[@"targetInfos"])if([target[@"type"] isEqual:@"service_worker"]&&[S(target,@"url") hasPrefix:[NSString stringWithFormat:@"chrome-extension://%@/",extension]]&&context&&[context isEqual:target[@"browserContextId"]]){found=target;break;}
    if(!found){
      if(attempt==0){
        ExtensionCDP(t->second,@"ServiceWorker.enable",@{},[tab,key,extension,context,action,fail](NSDictionary*,NSString* error){
          auto t=tabs.find(tab);if(error||t==tabs.end()){fail(nil,error?:@"Control tab closed");return;}
          ExtensionCDP(t->second,@"ServiceWorker.startWorker",@{@"scopeURL":[NSString stringWithFormat:@"chrome-extension://%@/",extension]},[tab,key,extension,context,action,fail](NSDictionary*,NSString* error){
            if(error){fail(nil,[@"Cannot wake extension worker: " stringByAppendingString:error]);return;}
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ExtensionFindWorker(tab,key,extension,context,action,fail,1);});
          });
        });
      }else if(attempt<15){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ExtensionFindWorker(tab,key,extension,context,action,fail,attempt+1);});}
      else fail(nil,@"No running extension worker in this profile after native wake");
      return;
    }
    ExtensionCDP(t->second,@"Target.attachToTarget",@{@"targetId":found[@"targetId"],@"flatten":@NO},[tab,key,extension,action,fail](NSDictionary* r,NSString* error){
      auto t=tabs.find(tab);NSString* session=S(r,@"sessionId");if(error||t==tabs.end()||!session.length){fail(nil,error?:@"No extension worker session");return;}
      ExtensionWorker worker{tab,Key(extension),Key(session)};extensionWorkers[key]=worker;
      ExtensionNested(t->second,session,@"Runtime.enable",@{},[worker,action,fail](NSDictionary*,NSString* error){
        auto t=tabs.find(worker.tab);if(error||t==tabs.end()){fail(nil,error?:@"Control tab closed");return;}
        // The worker's isolate captures no stacks for us either (StackCaptureOff).
        if(!StackCaptureKept())ExtensionNested(t->second,@(worker.session.c_str()),StackCaptureOff().first,StackCaptureOff().second,Ignore);
        ExtensionNested(t->second,@(worker.session.c_str()),@"Runtime.addBinding",@{@"name":@"__yabExtensionBridge"},[worker,action,fail](NSDictionary*,NSString* error){
          if(error){fail(nil,error);return;}ExtensionEvaluate(worker,ExtensionWorkerShim,[worker,action,fail](NSDictionary*,NSString* error){if(error)fail(nil,error);else action(worker);});
        });
      });
    });
  });
}
static void ExtensionWithWorker(Tab& control, NSString* extension, std::function<void(ExtensionWorker)> action, Completion fail) {
  std::string key=control.profile+":"+Key(extension);
  if(auto i=extensionOpening.find(key);i!=extensionOpening.end()){i->second.push_back({action,fail});return;}
  if(auto i=extensionWorkers.find(key);i!=extensionWorkers.end()){action(i->second);return;}
  extensionOpening[key].push_back({action,fail});
  action=[key](ExtensionWorker worker){auto i=extensionOpening.find(key);if(i==extensionOpening.end())return;auto waiters=std::move(i->second);extensionOpening.erase(i);for(auto& waiter:waiters)waiter.first(worker);};
  fail=[key](NSDictionary*,NSString* error){extensionWorkers.erase(key);auto i=extensionOpening.find(key);if(i==extensionOpening.end())return;auto waiters=std::move(i->second);extensionOpening.erase(i);for(auto& waiter:waiters)waiter.second(nil,error);};
  auto tab=control.id;
  ExtensionCDP(control,@"Target.getTargetInfo",@{},[tab,key,extension,action,fail](NSDictionary* own,NSString* error){
    if(error){fail(nil,error);return;}
    NSString* context=own[@"targetInfo"][@"browserContextId"];
    if(!context){fail(nil,@"CDP did not identify the profile browser context");return;}
    auto t=tabs.find(tab);if(t==tabs.end()){fail(nil,@"Control tab closed");return;}
    ExtensionCDP(t->second,@"ServiceWorker.enable",@{},[tab,key,extension,context,action,fail](NSDictionary*,NSString* error){
      auto t=tabs.find(tab);if(error||t==tabs.end()){fail(nil,error?:@"Control tab closed");return;}
      ExtensionCDP(t->second,@"ServiceWorker.startWorker",@{@"scopeURL":[NSString stringWithFormat:@"chrome-extension://%@/",extension]},[tab,key,extension,context,action,fail](NSDictionary*,NSString* error){
        if(error){fail(nil,[@"Cannot start profile extension worker: " stringByAppendingString:error]);return;}
        ExtensionFindWorker(tab,key,extension,context,action,fail,1);
      });
    });
  });
}
static NSString* ExtensionResolved(NSString* root, NSString* relative) {
  if(!relative.length||[relative isAbsolutePath])return nil;
  NSString* base=root.stringByResolvingSymlinksInPath, *file=[[root stringByAppendingPathComponent:relative] stringByResolvingSymlinksInPath];
  if(![file hasPrefix:[base stringByAppendingString:@"/"]])return nil;
  NSDictionary* attributes=[NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
  return [attributes fileSize]>2*1024*1024?nil:file;
}
static NSString* ExtensionRead(NSString* root, NSString* relative) {
  NSString* file=ExtensionResolved(root,relative);if(!file)return nil;
  return [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
}
// An image or a font is not text: the bridge carries it base64-wrapped,
// with the same root and size checks as the text read.
static NSData* ExtensionReadData(NSString* root, NSString* relative) {
  NSString* file=ExtensionResolved(root,relative);if(!file)return nil;
  return [NSData dataWithContentsOfFile:file];
}
// Worker session -> a release in flight (1), another owed after it (2).
static std::map<std::string, int> extensionConsoleRelease;
static void ExtensionConsoleReleaseSend(std::string control, std::string session) {
  auto t=tabs.find(control);if(t==tabs.end()){extensionConsoleRelease.erase(session);return;}
  ExtensionNested(t->second,@(session.c_str()),@"Runtime.releaseObjectGroup",@{@"objectGroup":@"console"},[control,session](NSDictionary*,NSString* error){
    auto state=extensionConsoleRelease.find(session);if(state==extensionConsoleRelease.end())return;
    if(state->second==2&&!error){state->second=1;ExtensionConsoleReleaseSend(control,session);}else extensionConsoleRelease.erase(state);
  });
}
static void ExtensionConsoleRelease(Tab& control, const std::string& session) {
  int& state=extensionConsoleRelease[session];
  if(state){state=2;return;}
  state=1;ExtensionConsoleReleaseSend(control.id,session);
}
static void ExtensionForgetSession(std::string session, NSString* reason) {
  extensionConsoleRelease.erase(session);
  for(auto i=extensionWorkers.begin();i!=extensionWorkers.end();)if(i->second.session==session)i=extensionWorkers.erase(i);else ++i;
  std::vector<Completion> callbacks;for(auto i=extensionCalls.begin();i!=extensionCalls.end();)if(i->second.session==session){callbacks.push_back(i->second.done);i=extensionCalls.erase(i);}else ++i;
  for(auto& done:callbacks)done(nil,reason);
}
// Action state for Yab's buttons (ext_actions.inc) rides on the same sessions.
static bool ExtensionActionBinding(Tab& control, const std::string& extension, NSDictionary* value);
static void ExtensionActionWorker(Tab& control, NSString* extension, const std::string& before, const std::string& now);
static bool ExtensionBridgeEvent(Tab& tab, NSString* method, NSDictionary* p) {
  if([method isEqual:@"ServiceWorker.workerVersionUpdated"]){
    for(NSDictionary* version in p[@"versions"]){
      NSURL* url=[NSURL URLWithString:S(version,@"scriptURL")];if(![url.scheme isEqual:@"chrome-extension"])continue;
      std::string key=tab.profile+":"+Key(url.host), status=Key(S(version,@"runningStatus"));
      std::string before=extensionWorkerStates[key];
      extensionWorkerStates[key]=status;
      ExtensionActionWorker(tab,url.host,before,status);
      if(status=="stopped"||status=="stopping"){
        auto worker=extensionWorkers.find(key);if(worker!=extensionWorkers.end())ExtensionForgetSession(worker->second.session,@"Extension worker stopped");
      }
    }
    return true;
  }
  if([method isEqual:@"Target.detachedFromTarget"]){ExtensionForgetSession(Key(S(p,@"sessionId")),@"Extension worker detached");return true;}
  if(![method isEqual:@"Target.receivedMessageFromTarget"])return false;
  std::string session=Key(S(p,@"sessionId"));ExtensionWorker* worker=nullptr;
  for(auto& [key,w]:extensionWorkers)if(w.tab==tab.id&&w.session==session){worker=&w;break;}
  if(!worker)return true;
  NSString* message=S(p,@"message");NSDictionary* r=Decode(message.UTF8String,[message lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
  if([r[@"method"] isEqual:@"Inspector.detached"]){ExtensionForgetSession(session,@"Extension worker inspector detached");return true;}
  // The worker's session has Runtime enabled too: its console arguments and
  // exceptions are released as they come, as ConsoleRelease does for pages.
  if([r[@"method"] isEqual:@"Runtime.consoleAPICalled"]||[r[@"method"] isEqual:@"Runtime.exceptionThrown"]){ExtensionConsoleRelease(tab,session);return true;}
  if(r[@"id"]){
    Completion done;
    auto i=extensionCalls.find([r[@"id"] intValue]);
    if(i!=extensionCalls.end()&&i->second.session==session){done=i->second.done;extensionCalls.erase(i);}
    // Worker evaluation errors have the same strong handles as page errors.
    // ExtensionNested queues the releases outside this observer notification.
    for(NSString* object in ScriptResultObjects(r[@"result"], !done))
      ExtensionNested(tab,@(session.c_str()),@"Runtime.releaseObject",@{@"objectId":object},Ignore);
    if(done)done(r[@"result"],r[@"error"]?JSON(r[@"error"]):nil);
    return true;
  }
  if([r[@"method"] isEqual:@"Runtime.bindingCalled"]&&[r[@"params"][@"name"] isEqual:@"__yabExtensionBridge"]){
    NSString* payload=S(r[@"params"],@"payload");NSDictionary* value=Decode(payload.UTF8String,[payload lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    if(ExtensionActionBinding(tab,worker->extension,value))return true;
    if([S(value,@"op") isEqual:@"storage.changed"] && ![ExtensionStorageAccess(tab,@(worker->extension.c_str()))[S(value,@"area")] boolValue])return true;
    Event(@"ext.bridge.call",&tab,@{@"extension":@(worker->extension.c_str()),@"session":@(session.c_str()),@"call":value});
  }
  return true;
}
static bool ExtensionBridgeCommand(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if(![method hasPrefix:@"ext.bridge."])return false;
  if(![Str(tab.browser->GetMainFrame()->GetURL()) isEqual:@"chrome://extensions/"]){Reply(request,nil,@"Bridge requires this profile's privileged extension-management tab");return true;}
  auto profile=tab.profile;
  if([method isEqual:@"ext.bridge.catalog"]){
    NSString* cache=Str(tab.browser->GetHost()->GetRequestContext()->GetCachePath());
    Eval(tab,@"new Promise((resolve,reject)=>chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true},rows=>chrome.runtime.lastError?reject(chrome.runtime.lastError.message):resolve(rows)))",0,
      [request,profile,cache](NSDictionary* r,NSString* error){
        if(error){Reply(request,nil,error);return;}NSMutableDictionary* entries=[NSMutableDictionary new], *roots=[NSMutableDictionary new];
        for(NSDictionary* info in r[@"result"][@"value"]){
          if(![info[@"state"] isEqual:@"ENABLED"] || (profiles[profile].privateMode && ![info[@"incognitoAccess"][@"isActive"] boolValue]))continue;
          NSString* root=S(info,@"path"),*eid=S(info,@"id");if(!eid.length)continue;
          if(!root.length && cache.length){
            NSString* folder=[[cache stringByAppendingPathComponent:@"Extensions"] stringByAppendingPathComponent:eid];
            for(NSString* version in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil]){
              if(![version hasPrefix:[S(info,@"version") stringByAppendingString:@"_"]])continue;
              NSString* candidate=[folder stringByAppendingPathComponent:version];
              if([[candidate stringByResolvingSymlinksInPath] hasPrefix:[[folder stringByResolvingSymlinksInPath] stringByAppendingString:@"/"]]){root=candidate;break;}
            }
          }
          if(!root.length)continue;
          NSData* data=[ExtensionRead(root,@"manifest.json") dataUsingEncoding:NSUTF8StringEncoding];
          NSDictionary* manifest=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;if(![manifest isKindOfClass:NSDictionary.class])continue;
          NSMutableDictionary* files=[NSMutableDictionary new];
          // Source files are read on demand through ext.bridge.files.
          NSMutableArray* grants=[NSMutableArray new];
          NSDictionary* permissions=info[@"permissions"][@"runtimeHostPermissions"];
          for(NSDictionary* host in permissions[@"hosts"])if([host[@"granted"] boolValue])[grants addObject:host[@"host"]];
          // Old Chrome metadata without runtimeHostPermissions does not imply a grant.
          NSMutableDictionary* messages=[NSMutableDictionary new];NSString* locale=S(manifest,@"default_locale");
          if(locale.length){NSString* path=[NSString stringWithFormat:@"_locales/%@/messages.json",locale];NSData* data=[ExtensionRead(root,path) dataUsingEncoding:NSUTF8StringEncoding];if(data){id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if([value isKindOfClass:NSDictionary.class])[messages addEntriesFromDictionary:value];}}
          roots[eid]=root;entries[eid]=@{@"id":eid,@"manifest":manifest,@"files":files,@"grants":grants,@"messages":messages};
        }
        extensionRoots[@(profile.c_str())]=roots;extensionCatalogs[@(profile.c_str())]=entries;Reply(request,@{@"extensions":entries.allValues});
      });return true;
  }
  if([method isEqual:@"ext.bridge.register"]){
    NSString* identity=S(p,@"virtual"),*document=S(p,@"document"),*url=S(p,@"url");int frame=[p[@"frame"] intValue];
    // An extension's own page frame registers under its real address, as
    // Chrome reports sender.url; every other frame needs a web address it
    // holds a grant for (checked on invoke).
    NSURL* frameURL=[NSURL URLWithString:url];
    NSString* extension=S(p,@"extension");
    BOOL ownPage=frame>0&&[frameURL.scheme isEqual:@"chrome-extension"]&&[frameURL.host isEqual:extension]
      &&!frameURL.port&&!frameURL.user&&!frameURL.password&&extensionCatalogs[@(profile.c_str())][extension];
    if(!identity.length||!document.length||(!ownPage&&![@[@"http",@"https"] containsObject:frameURL.scheme])){Reply(request,nil,@"Invalid virtual frame");return true;}
    std::string key=profile+":"+Key(identity)+":"+std::to_string(frame);
    if(!extensionVirtuals.count(key)){
      // Frame numbers only grow within a tab's document set, so the lowest
      // subframe is the oldest; the main frame (0) stays.
      std::string prefix=profile+":"+Key(identity)+":";size_t held=0;auto oldest=extensionVirtuals.end();
      for(auto i=extensionVirtuals.lower_bound(prefix);i!=extensionVirtuals.end()&&i->first.rfind(prefix,0)==0;++i){
        ++held;if(i->second.frame>0&&(oldest==extensionVirtuals.end()||i->second.frame<oldest->second.frame))oldest=i;
      }
      if(held>=kVirtualFramesPerTab&&oldest!=extensionVirtuals.end())extensionVirtuals.erase(oldest);
    }
    std::string tabKey=profile+":"+Key(identity);int number=extensionTabNumbers[tabKey];
    if(!number)number=extensionTabNumbers[tabKey]=++virtualSequence;
    NSString* topURL=S(p,@"topURL");if(!topURL.length)topURL=url;
    extensionVirtuals[key]={tab.id,profile,Key(document),number,frame,url,topURL};Reply(request,@{@"tabId":@(number)});return true;
  }
  if([method isEqual:@"ext.bridge.unregister"]){
    std::string prefix=profile+":"+Key(S(p,@"virtual"))+":";
    int number=extensionTabNumbers[profile+":"+Key(S(p,@"virtual"))];
    for(auto i=extensionVirtuals.begin();i!=extensionVirtuals.end();)if(i->first.rfind(prefix,0)==0)i=extensionVirtuals.erase(i);else ++i;
    for(auto& [key,worker]:extensionWorkers)if(worker.tab==tab.id)ExtensionEvaluate(worker,[NSString stringWithFormat:@"__yabWKBridge.invoke('forget',%d,null)",number],Ignore);
    if([p[@"close"] boolValue])extensionTabNumbers.erase(profile+":"+Key(S(p,@"virtual")));
    Reply(request);return true;
  }
  NSString* extension=S(p,@"extension");NSDictionary* entry=extensionCatalogs[@(profile.c_str())][extension];
  if(!entry){Reply(request,nil,@"Extension is not enabled in this profile");return true;}
  if([method isEqual:@"ext.bridge.testingSleep"]){
    if(!CefCommandLine::GetGlobalCommandLine()->HasSwitch("yab-test-bridge")||profile!="diagnostic"){Reply(request,nil,@"Worker sleep requires the isolated native diagnostic");return true;}
    ExtensionCDP(tab,@"ServiceWorker.enable",@{},[tabID=tab.id,request](NSDictionary*,NSString* error){
      auto t=tabs.find(tabID);if(error||t==tabs.end()){Reply(request,nil,error?:@"Control tab closed");return;}
      ExtensionCDP(t->second,@"ServiceWorker.stopAllWorkers",@{},[request,tabID](NSDictionary*,NSString* error){
        if(error){Reply(request,nil,error);return;}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
          auto t=tabs.find(tabID);if(t==tabs.end()){Reply(request,nil,@"Control tab closed");return;}
          bool stopped=true;for(auto& [key,state]:extensionWorkerStates)if(key.rfind(t->second.profile+":",0)==0&&state!="stopped")stopped=false;
          if(stopped)Reply(request,@{@"stopped":@YES});else Reply(request,nil,@"Service worker did not report stopped");
        });
      });
    });return true;
  }
  if([method isEqual:@"ext.bridge.files"]){
    if(![p[@"files"] isKindOfClass:NSArray.class]||[p[@"files"] count]>128){Reply(request,nil,@"Invalid extension file list");return true;}
    NSMutableDictionary* files=[NSMutableDictionary new];NSString* root=extensionRoots[@(profile.c_str())][extension];
    for(id path in p[@"files"]){if(![path isKindOfClass:NSString.class]){Reply(request,nil,@"Invalid extension file");return true;}NSString* source=ExtensionRead(root,path);if(!source){NSData* raw=ExtensionReadData(root,path);if(raw)source=[NSString stringWithFormat:@"{\"b64\":\"%@\"}",[raw base64EncodedStringWithOptions:0]];}if(!source){Reply(request,nil,@"Extension file is missing or outside its root");return true;}files[path]=source;}
    Reply(request,files);return true;
  }
  if([method isEqual:@"ext.bridge.reply"]){
    NSString* session=S(p,@"session");std::string key=profile+":"+Key(extension);auto w=extensionWorkers.find(key);
    if(w==extensionWorkers.end()||w->second.session!=Key(session)){Reply(request,nil,@"Worker session expired");return true;}
    ExtensionEvaluate(w->second,[NSString stringWithFormat:@"__yabWKBridge.reply(%@,%@,%@)",JSON(S(p,@"call")),JSON(p[@"value"]),JSON(p[@"error"])],[request](NSDictionary* r,NSString* e){Reply(request,r,e);});return true;
  }
  NSString* op=S(p,@"op");NSDictionary* sender=nil;
  if(![op isEqual:@"dnr.snapshot"]){
    std::string key=profile+":"+Key(S(p,@"virtual"))+":"+std::to_string([p[@"frame"] intValue]);auto v=extensionVirtuals.find(key);
    if(v==extensionVirtuals.end()||v->second.control!=tab.id||v->second.document!=Key(S(p,@"document"))){Reply(request,nil,@"Extension has no access to this virtual document");return true;}
    NSURL* url=[NSURL URLWithString:v->second.url];
    BOOL ownPage=[url.scheme isEqual:@"chrome-extension"]&&[url.host isEqual:extension];
    if(!ExtensionAllowed(entry,ownPage?v->second.topURL:v->second.url)){Reply(request,nil,@"Extension has no access to this virtual document");return true;}
    NSString* origin=[NSString stringWithFormat:@"%@://%@%@",url.scheme,url.host,url.port?[@":" stringByAppendingString:url.port.stringValue]:@""];
    sender=@{@"id":extension,@"tab":@{@"id":@(v->second.number),@"url":v->second.topURL,@"incognito":@(profiles[profile].privateMode),@"active":@YES,@"windowId":@1},@"frameId":@(v->second.frame),@"documentId":@(v->second.document.c_str()),@"url":v->second.url,@"origin":origin};
  }
  if(![method isEqual:@"ext.bridge.invoke"]){Reply(request,nil,@"Unknown bridge method");return true;}
  NSDictionary* access=ExtensionStorageAccess(tab,extension);
  if([op hasPrefix:@"storage."]&&!access){Reply(request,nil,@"Live Chromium storage access preferences are unavailable");return true;}
  ExtensionWithWorker(tab,extension,[request,op,p,sender,access](ExtensionWorker worker){
    ExtensionEvaluate(worker,[NSString stringWithFormat:@"__yabWKBridge.invoke(%@,%@,%@,%@)",JSON(op),JSON(p[@"args"]?:@[]),JSON(sender),JSON(access)], [request](NSDictionary* r,NSString* error){Reply(request,r,error);});
  },[request](NSDictionary*,NSString* error){Reply(request,nil,error);});return true;
}
static void ExtensionBridgePoll() {
  std::vector<Completion> callbacks;for(auto i=extensionCalls.begin();i!=extensionCalls.end();)if(i->second.deadline<Now()){callbacks.push_back(i->second.done);i=extensionCalls.erase(i);}else ++i;
  for(auto& done:callbacks)done(nil,@"Extension worker CDP timeout");
}
