import Foundation

/// Runs only in one extension's isolated WKContentWorld. MAIN scripts get no API.
enum ChromiumDRMExtensionScripts {
    static let shim = #"""
    (()=>{
      if(globalThis.__yabWK)return;
      const config=__CONFIG__,ports=new Map();let serial=0;
      // An extension's messages and stored values reach Yab as plain data,
      // as Chromium's JSON-serialized messaging has them: a DOMRect posted
      // whole crashed WebKit of macOS 15 in Yab's own JavaScript context
      // (WebKitIPCBoundary.plainScript).
      const plain=\#(WebKitIPCBoundary.plainScript);
      __TRANSPORT__
      const event=()=>{const listeners=new Set();return {addListener:f=>listeners.add(f),removeListener:f=>listeners.delete(f),hasListener:f=>listeners.has(f),hasListeners:()=>!!listeners.size,listeners}};
      const base='chrome-extension://'+config.id;
      const dynamicPatterns=(config.dynamicResources||[]).map(pattern=>new RegExp('^'+pattern.split('*').map(part=>part.replace(/[.+?^$(){}|[\]\\]/g,'\\$&')).join('.*')+'$'));
      const getURL=path=>{
        const relative='/'+String(path||'').replace(/^\//,'');
        if(config.resourceHost&&dynamicPatterns.some(pattern=>pattern.test(new URL(base+relative).pathname.slice(1))))
          return 'chrome-extension://'+config.resourceHost+relative;
        return base+relative;
      };
      const runtime={id:config.id,getManifest:()=>config.manifest,getURL,onMessage:event(),onConnect:event()};
      const callback=(promise,cb)=>{if(typeof cb!=='function')return promise;promise.then(x=>cb(x),e=>{runtime.lastError={message:String(e.message||e)};try{cb()}finally{delete runtime.lastError}})};
      runtime.sendMessage=(...args)=>{const cb=typeof args.at(-1)==='function'?args.pop():null;if(args.length>1&&typeof args[0]==='string'&&/^[a-p]{32}$/.test(args[0])){if(args.shift()!==config.id)return callback(Promise.reject(Error('Cross-extension messaging is unavailable')),cb)}return callback(call('runtime.sendMessage',[args[0]]),cb)};
      const port=(id,name,sender)=>{const p={name,sender,onMessage:event(),onDisconnect:event(),postMessage:message=>{call('port.message',{port:id,message}).catch(()=>p.onDisconnect.listeners.forEach(f=>f(p)))},disconnect:()=>{ports.delete(id);call('port.disconnect',{port:id});p.onDisconnect.listeners.forEach(f=>f(p))}};ports.set(id,p);return p};
      runtime.connect=(info={})=>{const id='wk-'+nonce+'-'+(++serial),p=port(id,info.name||'');call('runtime.connect',{port:id,name:p.name}).catch(()=>p.onDisconnect.listeners.forEach(f=>f(p)));return p};
      const storage={onChanged:event()};for(const area of ['local','sync','session','managed']){storage[area]={onChanged:event()};for(const method of ['get','set','remove','clear','getBytesInUse'])storage[area][method]=(...args)=>{const cb=typeof args.at(-1)==='function'?args.pop():null;return callback(call('storage.'+area+'.'+method,args),cb)}}
      const i18n={getUILanguage:()=>config.language,getMessage:(name,substitutions=[])=>{const entry=config.messages[name]||config.messages[String(name).toLowerCase()];if(!entry)return '';const substitutionsArray=[substitutions].flat();return String(entry.message||'').replace(/\$([\w]+)\$/g,(_,key)=>entry.placeholders?.[key.toLowerCase()]?.content||'').replace(/\$(\d)/g,(_,i)=>substitutionsArray[Number(i)-1]||'').replace(/\$\$/g,'$')}};
      for(const method of ['getAcceptLanguages','detectLanguage'])i18n[method]=(...args)=>{const cb=typeof args.at(-1)==='function'?args.pop():null;return callback(call('i18n.'+method,args),cb)};
      // Some extensions choose the browser namespace on WebKit's Safari user agent.
      globalThis.browser=globalThis.chrome={runtime,storage,i18n};
      const receive=async(op,args)=>{
        if(relayIn)return new Promise((resolve,reject)=>{
          const callId='in'+(++incomingSerial);
          const timer=setTimeout(()=>{if(incoming.delete(callId))reject(Error('The extension page did not answer'))},12000);
          incoming.set(callId,{resolve,reject,timer});
          document.dispatchEvent(new CustomEvent('yab-page-incoming',{detail:JSON.stringify({callId,op,args})}));
        });
        if(op==='tabs.sendMessage')return new Promise((resolve,reject)=>{
          const listeners=[...runtime.onMessage.listeners];
          if(!listeners.length){reject(Error('Receiving end does not exist'));return}
          let answered=false,async=false,timeout;
          const settle=(complete,value)=>{if(answered)return;answered=true;clearTimeout(timeout);complete(value)};
          const done=value=>settle(resolve,value??null);
          for(const listener of listeners){
            try{
              const value=listener(args.message,{id:config.id},done);
              if(value===true)async=true;
              else if(value&&typeof value.then==='function'){
                async=true;Promise.resolve(value).then(done,error=>settle(reject,error));
              }
            }catch(error){settle(reject,error)}
          }
          if(answered)return;
          if(!async){done(null);return}
          timeout=setTimeout(()=>settle(reject,Error('Content script did not reply')),10000);
        });
        if(op==='tabs.connect'){const p=port(args.port,args.info?.name||'',{id:config.id});runtime.onConnect.listeners.forEach(f=>f(p));return null}
        if(op==='port.message'){const p=ports.get(args.port);if(!p)throw Error('Port is disconnected');p.onMessage.listeners.forEach(f=>f(args.message,p));return null}
        if(op==='port.disconnect'){const p=ports.get(args.port);ports.delete(args.port);p?.onDisconnect.listeners.forEach(f=>f(p));return null}
        if(op==='storage.changed'){storage.onChanged.listeners.forEach(f=>f(args.changes,args.area));storage[args.area]?.onChanged.listeners.forEach(f=>f(args.changes));return null}
        throw Error('Unsupported content event');
      };
      globalThis.__yabWK={nonce,receive:async(op,args)=>plain(await receive(op,args)),ready,epoch:config.epoch};
    })();
    """#

    /// The bootstrap's own gate. A page's address decides whether the
    /// extension's API world exists there at all: the extension's own pages
    /// get it (as an extension's pages do in Chrome), any other extension's
    /// page gets nothing, and a web page needs a site grant.
    static func pageGuard(id: String, grants: [String]) throws -> String {
        "if(location.protocol==='chrome-extension:'){if(window.origin!==\(try json("chrome-extension://" + id)))return;}"
        + "else{\(try guardSource(matches: grants, excludes: [], globs: [], excludeGlobs: []))}"
    }
    static func dynamicResources(_ manifest: [String: Any]) -> [String] {
        (manifest["web_accessible_resources"] as? [[String: Any]] ?? [])
            .filter { $0["use_dynamic_url"] as? Bool == true }
            .flatMap { $0["resources"] as? [String] ?? [] }
            .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
    }
    static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    /// The world's transport: every call crosses to the app through the
    /// handler, and on an extension's own page the page's world can reach
    /// this world's bridge through the document they share.
    static let worldTransport = #"""
      const handler=webkit.messageHandlers.yabChromiumExtension;
      const nonce=crypto.randomUUID();
      const ready=handler.postMessage({op:'hello',nonce,epoch:config.epoch,url:location.href});
      const call=(op,args)=>ready.then(()=>handler.postMessage({op,args:plain(args),nonce,epoch:config.epoch,url:location.href}));
      const relayIn=location.protocol==='chrome-extension:';
      const incoming=new Map();let incomingSerial=0;
      if(relayIn){
        document.addEventListener('yab-page-answer',event=>{
          let answer;try{answer=JSON.parse(event.detail)}catch(error){return}
          const entry=incoming.get(answer.callId);if(!entry)return;incoming.delete(answer.callId);
          clearTimeout(entry.timer);answer.error?entry.reject(Error(answer.error)):entry.resolve(answer.value);
        });
        document.addEventListener('yab-page-call',event=>{
          let request;try{request=JSON.parse(event.detail)}catch(error){return}
          call(request.op,request.args).then(
            value=>document.dispatchEvent(new CustomEvent('yab-page-result',{detail:JSON.stringify({callId:request.callId,value:plain(value)})})),
            error=>document.dispatchEvent(new CustomEvent('yab-page-result',{detail:JSON.stringify({callId:request.callId,error:String(error&&error.message||error)})})));
        });
      }
    """#
    /// The page's transport: the world's bridge answers through the
    /// document, and the calls it brings back arrive as events too.
    static let templateFetchHeader = "X-Yab-Extension-Template"
    static let pageTransport = #"""
      // DOM navigations cannot set this header. The scheme handler still
      // checks the request against the frame's native extension origin.
      if(typeof globalThis.fetch==='function'){
        const fetchResource=globalThis.fetch.bind(globalThis);
        globalThis.fetch=async(input,init)=>{
          const target=new URL(input instanceof Request?input.url:String(input),document.baseURI);
          if(target.protocol!=='chrome-extension:'||target.host!==config.id||
             target.username||target.password||!target.pathname.toLowerCase().endsWith('.html'))
            return fetchResource(input,init);
          const request=new Request(input,init);
          if(request.method==='GET')request.headers.set('\#(templateFetchHeader)','1');
          return fetchResource(request);
        };
      }
      // getRandomValues is available on extension pages outside secure contexts too.
      const nonce=crypto.getRandomValues(new Uint32Array(4)).join('-');
      const ready=Promise.resolve(true);
      const relayIn=false;
      const pending=new Map();let callSerial=0;
      const call=(op,args)=>new Promise((resolve,reject)=>{
        const callId='page'+(++callSerial);pending.set(callId,{resolve,reject});
        document.dispatchEvent(new CustomEvent('yab-page-call',{detail:JSON.stringify({callId,op,args:plain(args)})}));
        setTimeout(()=>{if(pending.delete(callId))reject(Error('The extension page bridge did not answer'))},15000);
      });
      document.addEventListener('yab-page-result',event=>{
        let answer;try{answer=JSON.parse(event.detail)}catch(error){return}
        const entry=pending.get(answer.callId);if(!entry)return;pending.delete(answer.callId);
        answer.error?entry.reject(Error(answer.error)):entry.resolve(answer.value);
      });
      document.addEventListener('yab-page-incoming',event=>{
        let request;try{request=JSON.parse(event.detail)}catch(error){return}
        Promise.resolve(globalThis.__yabWK.receive(request.op,request.args)).then(
          value=>document.dispatchEvent(new CustomEvent('yab-page-answer',{detail:JSON.stringify({callId:request.callId,value})})),
          error=>document.dispatchEvent(new CustomEvent('yab-page-answer',{detail:JSON.stringify({callId:request.callId,error:String(error&&error.message||error)})})));
      });
    """#
    static func bootstrap(_ config: [String: Any], page: Bool = false) throws -> String {
        try shim.replacingOccurrences(of: "__TRANSPORT__", with: page ? pageTransport : worldTransport)
            .replacingOccurrences(of: "__CONFIG__", with: json(config))
    }
    static func matches(_ pattern: String, url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
        if pattern == "<all_urls>" { return true }
        guard let delimiter = pattern.range(of: "://"), let slash = pattern[delimiter.upperBound...].firstIndex(of: "/") else { return false }
        let scheme = String(pattern[..<delimiter.lowerBound]), domain = String(pattern[delimiter.upperBound..<slash]).lowercased()
        guard scheme == "*" || scheme == url.scheme?.lowercased() else { return false }
        guard domain == "*" || domain == host || (domain.hasPrefix("*.") && ChromiumDRM.matches(host: host, domain: String(domain.dropFirst(2)))) else { return false }
        let path = NSRegularExpression.escapedPattern(for: String(pattern[slash...])).replacingOccurrences(of: "\\*", with: ".*")
        let candidate = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
        return candidate.range(of: "^" + path + "$", options: .regularExpression) != nil
    }
    /// The native handler repeats the grant check using WKFrameInfo, not this guard.
    static func guardSource(matches: [String], excludes: [String], globs: [String], excludeGlobs: [String]) throws -> String {
        // Multiple independent guards share one content-script function. Keep
        // their lexical helpers scoped, while return still exits that function.
        "{" + #"const glob=(p,u)=>new RegExp('^'+p.replace(/[.+^${}()|[\]\\]/g,'\\$&').replace(/\*/g,'.*').replace(/\?/g,'.')+'$').test(u);const match=p=>{const u=new URL(location.href);if(!['http:','https:'].includes(u.protocol))return false;if(p==='<all_urls>')return true;const m=p.match(/^(\*|https?):\/\/([^/]+)(\/.*)$/);return !!m&&(m[1]==='*'||m[1]+':'===u.protocol)&&(m[2]==='*'||m[2]===u.hostname||m[2].startsWith('*.')&&(u.hostname===m[2].slice(2)||u.hostname.endsWith(m[2].slice(1))))&&glob(m[3],u.pathname+u.search)};"#
        + "if(!\(try json(matches)).some(match)||\(try json(excludes)).some(match))return;"
        + "if(\(try json(globs)).length&&!\(try json(globs)).some(p=>glob(p,location.href)))return;if(\(try json(excludeGlobs)).some(p=>glob(p,location.href)))return;"
        + "}"
    }
}
