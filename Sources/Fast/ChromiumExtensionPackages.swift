import Foundation
import CryptoKit

/// Keep original packages separate from WebKit's rewritten extension folders.
enum ChromiumExtensionPackages {
    /// The store picks a package by the asking browser's version: the pinned
    /// engine's, the same one scripts/cef/fetch.sh downloads.
    static let engineVersion = "156.0.8078.96"

    /// A stable key keeps the copied native folder's identity independent of
    /// the farm/profile path. Never pass WebKit's rewritten files to Chromium.
    static func unpackedKey(_ source: URL) throws -> Data {
        let manifest = try manifest(in: source)
        if let encoded = manifest["key"] as? String,
           let key = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !key.isEmpty { return key }
        return Data(source.standardizedFileURL.path.utf8)
    }

    static func unpackedID(_ source: URL) throws -> String {
        let digest = SHA256.hash(data: try unpackedKey(source))
        return String(digest.prefix(16).flatMap { [$0 >> 4, $0 & 15] }.map { Character(UnicodeScalar(97 + $0)) })
    }

    static func existingUnpacked(_ id: String) -> URL? {
        guard ChromiumExtensions.validID(id) else { return nil }
        let folder = Store.file("ChromiumPackages").appendingPathComponent("Unpacked").appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) ? folder : nil
    }

    static func prepareUnpacked(_ source: URL, id: String) throws -> URL {
        guard try unpackedID(source) == id else { throw Crx.Refused.notAnID }
        let root = Store.file("ChromiumPackages").appendingPathComponent("Unpacked", isDirectory: true)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        let staged = root.appendingPathComponent(".staged-" + UUID().uuidString, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staged) }
        try files.copyItem(at: source, to: staged)
        var manifest = try self.manifest(in: staged)
        manifest["key"] = try unpackedKey(source).base64EncodedString()
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: staged.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try arm(staged)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: staged, to: destination)
        return destination
    }

    static func prepare(_ crx: Data, id: String, root: URL) throws -> URL {
        guard ChromiumExtensions.validID(id), root.isFileURL else { throw Crx.Refused.notAnID }
        let package = try Crx.verifiedPackage(crx, id: id)
        let digest = SHA256.hash(data: crx).map { String(format: "%02x", $0) }.joined()
        let parent = root.appendingPathComponent(id, isDirectory: true)
        let destination = parent.appendingPathComponent(digest, isDirectory: true)
        let receipt = destination.appendingPathComponent(".yab-native-package")
        let files = FileManager.default
        // The package as the store signed it, beside its folder: Chrome
        // installs that, not the folder (ChromiumStoreInstalls).
        let original = parent.appendingPathComponent(digest + ".crx")
        if files.fileExists(atPath: destination.path) {
            guard try String(contentsOf: receipt, encoding: .utf8) == digest else { throw Crx.Refused.unpack }
            if !files.fileExists(atPath: original.path) { try crx.write(to: original, options: .atomic) }
            // Kept from a copy brought in from WebKit, it is a package again
            // here: a load of it is an install (ChromiumArrivalHook).
            _ = try arm(destination, broughtIn: false)
            return destination
        }
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try crx.write(to: original, options: .atomic)
        let staging = parent.appendingPathComponent(".staged-" + UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try Crx.unpack(package.zip, into: staging)
        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            throw Crx.Refused.unpack
        }
        manifest["key"] = package.publicKey.base64EncodedString()
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        try digest.write(to: staging.appendingPathComponent(".yab-native-package"), atomically: true, encoding: .utf8)
        _ = try arm(staging)
        try files.moveItem(at: staging, to: destination)
        return destination
    }

    /// The store's own signed file a kept package folder was made from, if
    /// it is still beside it and still the same bytes. Folders kept before
    /// the file was kept have none.
    static func original(of folder: URL, id: String) -> URL? {
        let folder = folder.standardizedFileURL
        let digest = folder.lastPathComponent, parent = folder.deletingLastPathComponent()
        guard ChromiumExtensions.validID(id), parent.lastPathComponent == id,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              (try? String(contentsOf: folder.appendingPathComponent(".yab-native-package"), encoding: .utf8)) == digest else { return nil }
        let file = parent.appendingPathComponent(digest + ".crx")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { return nil }
        return file
    }

    /// The package kept for `id` most recently, if any.
    static func existing(_ id: String, root: URL) -> URL? {
        guard ChromiumExtensions.validID(id) else { return nil }
        let parent = root.appendingPathComponent(id, isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return found.filter { folder in
            !folder.lastPathComponent.hasPrefix(".")
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent(".yab-native-package").path)
        }.max { a, b in
            let at = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            return at(a) < at(b)
        }
    }

    static func manifest(in folder: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard data.count <= 1_000_000, let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Crx.Refused.unpack
        }
        return manifest
    }

    // MARK: the action hook

    private static let hookStart = "/*yab-action-hook-1*/"
    private static let hookEnd = "/*yab-action-hook-end*/\n"

    /// Chrome has no getter for chrome.action.setIcon, so the icon an
    /// extension sets is read off its worker's own calls (ext_actions.inc).
    /// A hook put in over CDP arrives after the worker started, too late for
    /// one that sets it as it starts, as Bitwarden sets its lock. So the
    /// worker of Chromium's copy starts with the hook: the same watching, at
    /// its first line. True when the file changed. `plain` takes it out again.
    ///
    /// `broughtIn`: the copy is of one the person installed long ago in the
    /// other engine, so Chrome's first runtime.onInstalled to it ("install",
    /// as Chromium has never seen it) is told as the update it is
    /// (ChromiumArrivalHook). Nil keeps what the folder's hook says, so a
    /// pass's arm never takes it out from under a load.
    ///
    /// A module worker runs its imports before its own first line, and an
    /// extension built as modules (a bundler's loader) adds its listeners in
    /// them: there the hook is a module of its own beside the worker, and
    /// the worker imports it first.
    static func arm(_ folder: URL, broughtIn: Bool? = nil) throws -> Bool {
        guard let worker = try serviceWorker(in: folder), let text = try? String(contentsOf: worker.file, encoding: .utf8) else { return false }
        let bare = unhooked(text)
        let side = worker.file.deletingLastPathComponent().appendingPathComponent(hookModule)
        let had = !text.hasPrefix(hookStart) ? "" : worker.module ? (try? String(contentsOf: side, encoding: .utf8)) ?? ""
            : String(text[..<(text.range(of: hookEnd)?.lowerBound ?? text.startIndex)])
        let arrival = broughtIn ?? had.contains(ChromiumArrivalHook.mark)
        let source = ChromiumActionHook.source + (arrival ? ChromiumArrivalHook.source : "")
        let next: String
        var changed = false
        if worker.module {
            next = hookStart + "import './\(hookModule)';\n" + hookEnd + bare
            if (try? String(contentsOf: side, encoding: .utf8)) != source {
                try source.write(to: side, atomically: true, encoding: .utf8)
                changed = true
            }
        } else {
            // A top-level directive must stay the first thing in the file.
            let strict = bare.hasPrefix("'use strict'") || bare.hasPrefix("\"use strict\"")
            next = hookStart + (strict ? "'use strict';" : "") + source + "\n" + hookEnd + bare
        }
        if next != text {
            try next.write(to: worker.file, atomically: true, encoding: .utf8)
            changed = true
        }
        return changed
    }

    /// The hook of a module worker, beside it.
    private static let hookModule = "yab-hook-1.js"

    /// A copy of a package as it came from the store, for WebKit.
    nonisolated static func plain(_ folder: URL) throws {
        if let worker = try serviceWorker(in: folder), let text = try? String(contentsOf: worker.file, encoding: .utf8), text.hasPrefix(hookStart) {
            try unhooked(text).write(to: worker.file, atomically: true, encoding: .utf8)
            if worker.module { try? FileManager.default.removeItem(at: worker.file.deletingLastPathComponent().appendingPathComponent(hookModule)) }
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".yab-native-package"))
    }

    nonisolated private static func unhooked(_ text: String) -> String {
        guard text.hasPrefix(hookStart), let end = text.range(of: hookEnd) else { return text }
        return String(text[end.upperBound...])
    }

    /// The worker its manifest names, inside the folder, and whether it is a module.
    nonisolated private static func serviceWorker(in folder: URL) throws -> (file: URL, module: Bool)? {
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let background = manifest["background"] as? [String: Any],
              let name = background["service_worker"] as? String, !name.isEmpty else { return nil }
        let root = folder.standardizedFileURL
        let file = root.appendingPathComponent(name).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return (file, background["type"] as? String == "module")
    }

    static func fetch(_ id: String) async throws -> Data {
        guard ChromiumExtensions.validID(id) else { throw Crx.Refused.notAnID }
        // Fixture worlds have the store's packages in a folder of their own.
        if Store.testing, let folder = ProcessInfo.processInfo.environment["YAB_TEST_CRX_FOLDER"] {
            return try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(id + ".crx"))
        }
        var parts = URLComponents(url: Crx.downloadURL(for: id), resolvingAgainstBaseURL: false)!
        parts.queryItems = parts.queryItems?.map { $0.name == "prodversion" ? URLQueryItem(name: "prodversion", value: engineVersion) : $0 }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw Crx.Refused.download((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard !data.isEmpty else { throw Crx.Refused.empty }
        return data
    }
}

/// What YabCore's ExtensionActionScript watches for, at the top of the worker
/// of a Chromium package. Keep the two alike: the script finds
/// `__yabActionWatch` here and leaves it. The bridge binding comes later, when
/// Yab first reads the worker, so a call before it says nothing and is found
/// by that read. No tab listeners here: added at a worker's first line they
/// would wake it for every page; the script adds them when it first reads.
enum ChromiumActionHook {
    static let source = #"""
(()=>{const g=globalThis,a=g.chrome&&chrome.action;if(!a||g.__yabActionWatch)return;const icons=new Map(),tell=t=>{try{__yabExtensionBridge(JSON.stringify({op:'action.changed',tabId:Number.isInteger(t)?t:null}))}catch(_){}};g.__yabActionWatch={icons,tell};for(const m of['setBadgeText','setBadgeBackgroundColor','setBadgeTextColor','setTitle','setPopup','enable','disable']){const o=a[m]?.bind(a);if(!o)continue;a[m]=(...x)=>{const d=x[0],t=typeof d==='number'?d:d?.tabId,r=o(...x);Promise.resolve(r).then(()=>tell(t),()=>tell(t));return r}}const largest=v=>{if(!v||typeof v!=='object'||'width'in v)return v;const k=Object.keys(v).sort((x,y)=>Number(y)-Number(x));return k.length?v[k[0]]:null};const encode=async b=>{const n=new Uint8Array(await b.arrayBuffer());if(n.length>150000)return null;let s='';for(let i=0;i<n.length;i+=0x8000)s+=String.fromCharCode(...n.subarray(i,i+0x8000));return'data:image/png;base64,'+btoa(s)};const png=async s=>{const w=s.width,h=s.height;if(!w||!h||w>256||h>256)return null;const c=new OffscreenCanvas(w,h),x=c.getContext('2d');if(s instanceof ImageData)x.putImageData(s,0,0);else if(s.data)x.putImageData(new ImageData(new Uint8ClampedArray(s.data),w,h),0,0);else x.drawImage(s,0,0);return encode(await c.convertToBlob({type:'image/png'}))};const capture=async d=>{const i=largest(d?.imageData);if(i)return png(i);const p=largest(d?.path);if(typeof p!=='string'||!p)return null;const r=await fetch(chrome.runtime.getURL(p.replace(/^\//,'')));const b=await r.blob();if(b.type==='image/png')return encode(b);return png(await createImageBitmap(b))};const setIcon=a.setIcon?.bind(a);if(setIcon)a.setIcon=(d,cb)=>{const r=setIcon(d,cb),k=Number.isInteger(d?.tabId)?d.tabId:-1;capture(d).then(u=>{if(u)icons.set(k,u);else icons.delete(k);tell(d?.tabId)},()=>{icons.delete(k);tell(d?.tabId)});return r}})();
"""#
}

/// Chrome tells runtime.onInstalled "install" once, when an id first comes
/// into a profile; "update" (with previousVersion) when it goes in over a
/// copy of the same id, the move to a store install among them; nothing when
/// it is turned off and on, as the action hook's reload does
/// (LazyEventDispatchUtil keeps the pending event from OnExtensionWillBeInstalled
/// to the first OnExtensionLoaded; RuntimeEventRouter::DispatchOnInstalledEvent).
/// Extensions open their welcome page on "install".
///
/// One the list brings into Chromium from WebKit was installed there long
/// ago, its welcome seen then, yet Chromium has never seen its id and says
/// "install". Its worker (and only its: ChromiumExtensionSync.bring) is told
/// that one as the update it is, as WebKit's shim tells one brought in from
/// another browser (ExtensionInstallWord, feedback #135). Every other reason
/// goes through as Chromium says it, and the extension's tabs are its own.
enum ChromiumArrivalHook {
    static let mark = "__yabBroughtIn"
    static let source = #"""
(()=>{const g=globalThis,r=g.chrome&&chrome.runtime,e=r&&r.onInstalled;if(!e||g.__yabBroughtIn)return;g.__yabBroughtIn=1;const add=e.addListener.bind(e),remove=e.removeListener.bind(e),has=e.hasListener.bind(e),told=new Map(),put=(k,v)=>{try{Object.defineProperty(e,k,{value:v,configurable:true,writable:true})}catch(_){e[k]=v}};const tell=f=>{if(typeof f!=='function')return f;let w=told.get(f);if(!w){w=function(d){return f.call(this,d&&d.reason==='install'?{...d,reason:'update',previousVersion:r.getManifest().version}:d)};told.set(f,w)}return w};put('addListener',f=>add(tell(f)));put('removeListener',f=>{const w=told.get(f);told.delete(f);return remove(w||f)});put('hasListener',f=>has(told.get(f)||f))})();
"""#
}
