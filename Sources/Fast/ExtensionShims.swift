import AppKit
import WebKit
import Combine
import NaturalLanguage
import UserNotifications
import IOKit.pwr_mgt
import CryptoKit
import SQLite3

// The Chrome APIs WebKit doesn't have, filled in by the browser itself.
//
// Safari's extension engine covers tabs, storage, scripting, request rules,
// cookies, menus, alarms and messaging. Chrome extensions also reach for
// bookmarks, history, downloads, the side panel, offscreen documents, tab
// groups and OAuth, and fall over when those are undefined.
//
// So when an extension is installed, a small script is put at the front of
// its background and of every page it ships: `chrome.bookmarks` and the rest
// are defined there, and every call becomes a native message to this app,
// which answers from its own bookmarks, history and downloads. To the
// extension it looks like Chrome. The files are changed after the store's
// signature has been checked, and only by adding.

@available(macOS 15.4, *)
@MainActor
enum ExtensionShims {
    /// The name native messages to the browser itself go to.
    nonisolated static let application = "yab"
    nonisolated static let file = "yab-shim.js"
    /// The part of it a content script runs, in every frame of every page,
    /// for each extension: up to where the shim returns for one
    /// (`inContent`), less what only a worker or the extension's own pages
    /// do, 22 KB of 134. All of it in each of those worlds made a page with
    /// twenty frames and thirteen extensions weigh 199 MB where the
    /// extensions alone took 93.
    nonisolated static let content = "yab-content.js"
    /// yab's passkey patch, put first in every script an extension runs in
    /// a page's own world (see Passkeys.swift, and `first` in the script).
    nonisolated static let passkeys = "yab-passkeys.js"
    /// requestIdleCallback, which WebKit lacks, put first only in a script
    /// an extension runs in a page's own world that calls it (Proton Pass's
    /// elements.js, NordPass's passkeys.js); see extension-idle.js.
    nonisolated static let idle = "yab-idle.js"
    nonisolated static let idlePage = PageScript.load("extension-idle")
    /// An AudioContext started with the page's next click or key, as
    /// Chrome starts one in a page that has had one, put first only in a
    /// script an extension runs in a page's own world that makes one
    /// (Transpose's player-main.js, feedback #271); see extension-audio.js.
    nonisolated static let audio = "yab-audio.js"
    nonisolated static let audioPage = PageScript.load("extension-audio")
    /// Beside a prepared extension: each late file (`late`) and the files of
    /// the package it holds, so a later prepare starts from those again.
    nonisolated static let lateList = ".yab-late"
    /// A content script heavier than this, in KB, waits for the page's first
    /// frames (`late`). YAB_LATE_CONTENT_KB=0 never makes one wait.
    /// Tests only (YAB_LATE_MARK=1): a late file says on the page's root
    /// that it ran, `data-yab-late="files/failed"` (evals/extensions/nordpass_late.py).
    nonisolated static let lateMark = ProcessInfo.processInfo.environment["YAB_LATE_MARK"] == "1"
    nonisolated static let lateKB: Int = ProcessInfo.processInfo.environment["YAB_LATE_CONTENT_KB"].flatMap { Int($0) } ?? 1024
    /// A frame inside the page waits until it is in sight (YAB_LATE_FRAMES:
    /// `seen`, or `drawn` for its own frames only, as the page's).
    nonisolated static let lateSeen = ProcessInfo.processInfo.environment["YAB_LATE_FRAMES"] != "drawn"
    /// The shim once per extension, in a first entry of its own, rather
    /// than before the files of each (YAB_SHIM_ONCE=0 for each).
    nonisolated static let shimOnce = ProcessInfo.processInfo.environment["YAB_SHIM_ONCE"] != "0"
    /// An extension's DOMContentLoaded listeners in its own world run after
    /// the page's first frame (extension-shims.js; YAB_CONTENT_DCL=now: at once).
    nonisolated static let dclLate = ProcessInfo.processInfo.environment["YAB_CONTENT_DCL"] != "now"
    /// A wallet's relay waits for the page's first frames too (`late`): a
    /// document_start script in the extension's world over `lateKB`, beside
    /// one of its own in the page's world over the same sites
    /// (YAB_LATE_RELAY=0: as WebKit runs it).
    nonisolated static let lateRelay = ProcessInfo.processInfo.environment["YAB_LATE_RELAY"] != "0"
    /// A late file lets the page draw between the files it holds: NordPass's
    /// classifier.js and content.js (3.6 and 4.0 MB) ran in one task of
    /// 210-250 ms just after a new tab's first frame (m4), now in two.
    /// YAB_LATE_YIELD=0: in one, as before.
    nonisolated static let lateYield = ProcessInfo.processInfo.environment["YAB_LATE_YIELD"] != "0"
    /// A document_idle script waits for the page's first frames from this
    /// size, in KB: Chrome runs idle ones once the page is idle, after its
    /// first paint, where WebKit runs them as the document ends, before it
    /// (Grammarly's 388 KB in every frame). YAB_LATE_IDLE_KB=1024: as document_end.
    nonisolated static let lateIdleKB: Int = ProcessInfo.processInfo.environment["YAB_LATE_IDLE_KB"].flatMap { Int($0) } ?? min(lateKB, 100)
    /// A worker that keeps calling extension APIs stays, as in Chrome (the
    /// shim's `yab.keep`, ExtensionKeep). YAB_WORKER_KEEP=0: WebKit's own
    /// rule, a worker let go after 30 s without events.
    nonisolated static let keepWorkers = ProcessInfo.processInfo.environment["YAB_WORKER_KEEP"] != "0"
    /// YAB_PORT_TRACE=1: the shim counts every port opened and closed, and
    /// says where from (a diagnosis, evals/extensions/nordpass_idle.py).
    nonisolated static let portTrace = ProcessInfo.processInfo.environment["YAB_PORT_TRACE"] == "1"
    /// A content script's port that WebKit ends at once ("Tab not found",
    /// a page open before its extension loaded) is said to have ended a
    /// little later each time (extension-shims.js). YAB_PORT_SLOW=0: at once.
    nonisolated static let portSlow = ProcessInfo.processInfo.environment["YAB_PORT_SLOW"] != "0"
    nonisolated static var lateSetting: String { "late\(lateKB)\(lateMark)stub\(lateSeen)\(shimOnce)dcl\(dclLate)relay\(lateRelay)yield\(lateYield)idle\(lateIdleKB)keep\(keepWorkers)locks\(ownLocks)trace\(portTrace)slow\(portSlow)scope\(shimScope)" }
    /// The extension's own pages and worker get Yab's navigator.locks: on
    /// macOS 26.4 and 26.5 WebKit ends the process of one that asks for a
    /// Web Lock ("Received an invalid message 'WebLockRegistryProxy_
    /// RequestLock'", then AuxiliaryProcessProxy::terminate), and
    /// 1Password's worker asks for one for each tab it fills (feedback #140,
    /// renderer-2's log 2026-10-17). 26.7.1 takes the request (m4), and
    /// keeps WebKit's own; 26.6 isn't known, and gets Yab's. YAB_OWN_LOCKS=1
    /// or 0 to choose.
    nonisolated static let ownLocks: Bool = {
        switch ProcessInfo.processInfo.environment["YAB_OWN_LOCKS"] {
        case "1": return true
        case "0": return false
        default:
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return os.majorVersion == 26 && os.minorVersion < 7
        }
    }()

    /// One file that runs `files` after the page's first two frames, rather
    /// than before its first one. NordPass puts 7.4 MB (classifier.js and
    /// content.js) into every frame at document_end; a new tab's process
    /// compiled and ran it before it drew anything, and a tab opened in 515
    /// ms against 124 with no extension (evals/stand, 2026-10-12). Chrome's
    /// document_idle is later than WebKit's, which is document_end.
    ///
    /// Only an entry run at document_end or idle, in the extension's own
    /// world, over `lateKB`, of a Manifest V3 extension (its files are
    /// web-accessible to the stub only there). The stub fetches each file
    /// from the package and runs it with an indirect eval, at the top level
    /// of the extension's world as WebKit would have; content worlds take
    /// eval whatever the page's CSP says (probed 2026-10-12). Parsing the
    /// files inside the late file instead (wrapped as functions) cost the
    /// passwords profile 5.5 s of CPU a move, and went. A hidden page waits
    /// until it is shown, as its frames do; a frame WebKit holds frames
    /// back from gets a second instead; a frame inside the page waits until
    /// it is in sight (`lateSeen`): a hidden ad frame never needs a
    /// password manager.
    /// The shim's entries (`shimOnce`): first, at document_start, where the
    /// extension's own entries in its world run, each frame reached once.
    /// One entry over all of them, in every frame if any one of them was,
    /// put the shim's world into every frame of every page for an
    /// extension whose wide entry is the top frame's alone and whose
    /// all-frames entry is for its own site (Capital One Shopping): a
    /// world, its bindings and the shim's run in each ad and widget frame,
    /// with nothing of the extension's after it. So the entries are kept
    /// by reach (all frames, about:blank, as a fallback), a pattern a wider
    /// one already takes is left to it, and the extension's own
    /// exclusions are kept where all of a reach's entries share them.
    /// YAB_SHIM_SCOPE=0: one entry over all, as before.
    nonisolated static func shimEntries(for own: [[String: Any]]) -> [[String: Any]] {
        let keys = ["all_frames", "match_about_blank", "match_origin_as_fallback"]
        func reach(_ entry: [String: Any]) -> [Bool] { keys.map { entry[$0] as? Bool == true } }
        guard shimScope else {
            var matches: [String] = []
            for entry in own {
                for match in entry["matches"] as? [String] ?? [] where !matches.contains(match) { matches.append(match) }
            }
            var shimEntry: [String: Any] = ["js": [content], "matches": matches, "run_at": "document_start"]
            for key in keys where own.contains(where: { $0[key] as? Bool == true }) { shimEntry[key] = true }
            return [shimEntry]
        }
        var groups: [(reach: [Bool], matches: [String], excludes: [[String]])] = []
        for entry in own {
            let r = reach(entry)
            let index = groups.firstIndex { $0.reach == r } ?? {
                groups.append((r, [], []))
                return groups.count - 1
            }()
            for match in entry["matches"] as? [String] ?? [] where !groups[index].matches.contains(match) {
                groups[index].matches.append(match)
            }
            groups[index].excludes.append(((entry["exclude_matches"] as? [String]) ?? []).sorted())
        }
        // Wider first: a frame both reach takes the shim from the wider one.
        groups.sort { a, b in
            let wa = a.reach.filter { $0 }.count, wb = b.reach.filter { $0 }.count
            return wa != wb ? wa > wb : a.reach.lexicographicallyPrecedes(b.reach) { $0 && !$1 }
        }
        func covers(_ wider: [String], _ match: String) -> Bool {
            if wider.contains(match) || wider.contains("<all_urls>") { return true }
            let web = match.hasPrefix("http://") || match.hasPrefix("https://") || match.hasPrefix("*://")
            return web && wider.contains("*://*/*")
        }
        // What a reach leaves out: only what every one of its entries does.
        let excludes = groups.map { group -> [String] in
            guard let first = group.excludes.first, group.excludes.allSatisfy({ $0 == first }) else { return [] }
            return first
        }
        var out: [[String: Any]] = []
        for (index, group) in groups.enumerated() {
            // A wider reach that leaves nothing out takes this one's frames.
            let wider = groups.indices.prefix(index).filter { w in
                excludes[w].isEmpty && zip(groups[w].reach, group.reach).allSatisfy { $0 || !$1 }
            }
            let matches = group.matches.filter { match in !wider.contains { covers(groups[$0].matches, match) } }
            guard !matches.isEmpty else { continue }
            var entry: [String: Any] = ["js": [content], "matches": matches, "run_at": "document_start"]
            for (key, on) in zip(keys, group.reach) where on { entry[key] = true }
            if !excludes[index].isEmpty { entry["exclude_matches"] = excludes[index] }
            out.append(entry)
        }
        return out
    }
    nonisolated static let shimScope = ProcessInfo.processInfo.environment["YAB_SHIM_SCOPE"] != "0"

    nonisolated static func late(_ files: [String], runAt: String?, in folder: URL, manifestV3: Bool = true, relay: Bool = false, entry: Int = 0) -> String? {
        guard manifestV3, lateKB > 0, !files.isEmpty,
              runAt == nil || runAt == "document_end" || runAt == "document_idle" || (relay && lateRelay && runAt == "document_start")
        else { return nil }
        var size = 0
        for name in files {
            guard let url = inside(name, of: folder), let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            size += source.utf8.count
        }
        guard size > (runAt == nil || runAt == "document_idle" ? lateIdleKB : lateKB) * 1024 else { return nil }
        let mark = lateMark ? "document.documentElement.setAttribute(\"data-yab-late\", count + \"/\" + failed);" : ""
        let schedule = """
          const soon = () => setTimeout(go, 0);
          const drawn = () => {
            requestAnimationFrame(() => requestAnimationFrame(soon));
            setTimeout(() => { if (document.visibilityState === "visible") soon(); }, 1000);
          };
          const seen = () => {
            if (\(lateSeen) && window !== window.top && typeof IntersectionObserver === "function") {
              const watch = new IntersectionObserver((entries) => {
                if (!entries.some((e) => e.isIntersecting)) return;
                watch.disconnect();
                drawn();
              });
              watch.observe(document.documentElement);
            } else drawn();
          };
          if (document.visibilityState === "visible") seen();
          else document.addEventListener("visibilitychange", function shown() {
            if (document.visibilityState !== "visible") return;
            document.removeEventListener("visibilitychange", shown);
            seen();
          });
        """
        let list = String(data: (try? JSONSerialization.data(withJSONObject: files.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        // The extension's own getURL and fetch, taken now, before any of
        // its code can replace them.
        return """
        (() => {
          const files = \(list), count = files.length;
          const api = globalThis.chrome || globalThis.browser, getURL = api.runtime.getURL.bind(api.runtime);
          // WebKit injects manifest scripts again when a context restarts.
          // Keep one run per manifest entry in this document's world: a
          // second Fathom root mounts another portal into the same controls.
          const mark = Symbol.for("yab.lateContent"), key = getURL("yab-late-\(entry).js");
          if (!globalThis[mark]) Object.defineProperty(globalThis, mark, { value: new Set() });
          const ran = globalThis[mark];
          const take = globalThis.fetch.bind(globalThis), run = (0, eval);
          const frame = globalThis.requestAnimationFrame.bind(globalThis), later = globalThis.setTimeout.bind(globalThis);
          const between = () => new Promise((next) => document.visibilityState === "visible" ? frame(() => later(next, 0)) : later(next, 0));
          let done = false;
          const go = async () => {
            if (done || ran.has(key)) return;
            done = true;
            ran.add(key);
            let failed = 0;
            const texts = files.map((f) => take(getURL(f)).then((r) => r.text()));
            for (let i = 0; i < count; i++) {
              let text;
              try { text = await texts[i]; } catch (e) { failed++; setTimeout(() => { throw e; }); continue; }
              try { run(text + "\\n//# sourceURL=" + getURL(files[i])); } catch (e) { failed++; setTimeout(() => { throw e; }); }
              \(lateYield ? "if (i < count - 1) await between();" : "")
            }
            \(mark)
          };
        \(schedule)
        })();

        """
    }

    /// A content script's match as an origin a web-accessible resource
    /// takes: its path made `/*` ("https://www.director.ai/?*" →
    /// "https://www.director.ai/*").
    /// An entry's web sites, files left out, in one order: what tells a
    /// wallet's relay beside its provider (`lateRelay`), whichever way an
    /// earlier prepare left the file patterns.
    nonisolated static func sites(_ matches: Any?) -> [String] {
        ((matches as? [String]) ?? []).filter { !$0.hasPrefix("file:") }.sorted()
    }

    nonisolated static func originPattern(_ match: String) -> String {
        guard let scheme = match.range(of: "://") else { return match }
        let rest = match[scheme.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return match + "/*" }
        return String(match[..<slash]) + "/*"
    }

    /// The first line of a worker that already carries the shim.
    nonisolated static let marker = "/* yab: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    nonisolated static let ender = "/* yab: end of shim */"
    /// What an extension added while yab was still called Fast carries:
    /// the shim under the old names, which asks for a browser named
    /// "fast" that nothing answers now, so every one of them showed an
    /// error. Taken off wherever it was put (see `unFast`).
    nonisolated static let fastFiles = ["fast-shim.js", "fast-passkeys.js"]
    nonisolated static let fastMarker = "/* Fast: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    nonisolated static let fastEnder = "/* Fast: end of shim */"

    // MARK: - at install

    /// Written beside a prepared extension: which shim it carries. The same
    /// one needs nothing redone, which matters at launch, preparing reads
    /// every script and page an extension ships.
    nonisolated static let stamp = ".yab-shim"
    /// Bumped when `prepare` changes what it does to a manifest, so an
    /// extension prepared by an earlier yab is prepared again.
    nonisolated static let revision = "manifest-20"
    nonisolated static let version: String = {
        SHA256.hash(data: Data((script + contentScript + PasskeyRelay.page + idlePage + audioPage + revision + lateSetting).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            + (webKitDropsWasmKeyword ? "-safari18" : "") + (Store.testing ? "-test" : "")
    }()

    /// `fresh`: a package just unpacked or copied in. What only yab writes
    /// beside an extension, which permissions it added and which shim it
    /// carries, is yab's to say, never the package's: anything by those
    /// names that came inside it goes before a word of it is read.
    nonisolated static func prepare(_ folder: URL, fresh: Bool = false) throws {
        let files = FileManager.default
        if fresh {
            for name in [stamp, ".yab-added", givenPolicyFile, lateList, ExtensionRuleBudget.leftOffFile, ExtensionRuleBudget.countsFile] { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        }
        let stampURL = folder.appendingPathComponent(stamp)
        let fast = files.fileExists(atPath: folder.appendingPathComponent(".fast-shim").path)
        if !fast, (try? String(contentsOf: stampURL, encoding: .utf8)) == version { return }
        if fast {
            unFast(folder)
            unFastRegistered(folder.lastPathComponent)
        }
        defer { try? version.write(to: stampURL, atomically: true, encoding: .utf8) }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw Crx.Refused.unpack }

        // Its scripts in eight bits a character, before anything is read
        // from them or made of them: every page process holds a copy of each
        // content script in the app's memory (ScriptNarrow).
        ScriptNarrow.narrow(folder: folder, except: [file, content, passkeys, idle, audio])
        let script = shim(for: folder)
        try script.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try contentShim(for: folder).write(to: folder.appendingPathComponent(content), atomically: true, encoding: .utf8)
        try PasskeyRelay.page.write(to: folder.appendingPathComponent(passkeys), atomically: true, encoding: .utf8)
        try idlePage.write(to: folder.appendingPathComponent(idle), atomically: true, encoding: .utf8)
        try audioPage.write(to: folder.appendingPathComponent(audio), atomically: true, encoding: .utf8)
        fillEmptyScripts(in: folder)
        mendWorkerWindow(in: folder)
        let idlers = idleCallers(in: folder)
        let players = audioCallers(in: folder)

        // Native messaging is how the shim reaches the browser; user scripts
        // are carried out through WebKit's registered content scripts, which
        // need scripting. What is added is written down, so the extension is
        // described by what it asked for, not by what yab gave it.
        var permissions = manifest["permissions"] as? [Any] ?? []
        let asked = Set(permissions.compactMap { $0 as? String })
        var added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".yab-added")))) as? [String] ?? []
        for needed in ["nativeMessaging"] + (asked.contains("userScripts") ? ["scripting"] : []) where !asked.contains(needed) {
            permissions.append(needed)
            added.append(needed)
        }
        manifest["permissions"] = permissions
        mendExternallyConnectable(&manifest)
        mendEmptyContentScripts(&manifest)
        mendAccessibleResources(&manifest)
        mendActionCommands(&manifest)
        mendPopup(&manifest, in: folder)
        mendWasmPolicy(&manifest, in: folder)
        ExtensionRuleMends.mendRuleSets(in: folder, manifest: &manifest)
        if let data = try? JSONSerialization.data(withJSONObject: Array(Set(added)).sorted()) {
            try? data.write(to: folder.appendingPathComponent(".yab-added"))
        }

        // The background, whichever kind it is, gets the shim first. A
        // service worker gets it written at the top of its own file: that
        // holds whether WebKit runs it as a worker or as a page, as a classic
        // script or a module, where a wrapper importing it would not.
        if var background = manifest["background"] as? [String: Any] {
            // A manifest is not a way out of its own package: a worker path
            // that resolves outside the folder, or is a link, is left alone.
            if let worker = background["service_worker"] as? String,
               let path = inside(worker, of: folder) {
                if var source = try? String(contentsOf: path, encoding: .utf8) {
                    // Already carrying one: take the old one off, so a newer
                    // yab puts its newer shim in its place. Fast's too, and
                    // its import, found under yab's in a worker from then.
                    var shed = true
                    while shed {
                        shed = false
                        for (start, end) in [(marker, ender), (fastMarker, fastEnder)] where source.hasPrefix(start) {
                            guard let range = source.range(of: end) else { continue }
                            source = String(source[range.upperBound...]).trimmingPrefix("\n").description
                            shed = true
                        }
                        for name in [file] + fastFiles {
                            let line = "import \"/\(name)\";\n"
                            if source.hasPrefix(line) { source.removeFirst(line.count); shed = true }
                        }
                    }
                    // A copy from before there was an end marker: it ends
                    // where its function does, the first `})();` that
                    // starts a line.
                    while source.hasPrefix(marker), let end = source.range(of: "\n})();\n") {
                        source = String(source[end.upperBound...])
                    }
                    // A module's imports run before its own first line, so
                    // the shim written above them comes too late for code
                    // that reads the APIs as it loads (Claude's reads
                    // tabGroups.Color). Imported first, it runs first; the
                    // copy above then finds itself already there.
                    let first = "import \"/\(file)\";\n"
                    if source.hasPrefix(first) { source.removeFirst(first.count) }
                    let module = background["type"] as? String == "module"
                    try (marker + "\n" + script + "\n" + ender + "\n" + (module ? first : "") + source).write(to: path, atomically: true, encoding: .utf8)
                }
            }
            // MV3 packages can carry scripts for Firefox and a worker for
            // Chrome. Safari defaults to the scripts' window, where worker
            // globals such as Wappalyzer's `close` collide with Window.close.
            // Prefer the worker while retaining the cross-browser fallback.
            if (manifest["manifest_version"] as? Int) == 3,
               background["service_worker"] is String,
               background["scripts"] is [String],
               background["preferred_environment"] == nil {
                background["preferred_environment"] = ["service_worker", "document"]
            }
            // Scripts, alone or beside a worker, need the shim if WebKit
            // selects a background page.
            if var scripts = background["scripts"] as? [String] {
                scripts.removeAll { fastFiles.contains($0) }
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        // Content scripts too, there only the sendMessage mend applies. One
        // that runs in the page's own world has yab's passkey patch before
        // it: a password manager's there keeps a reference to
        // navigator.credentials as it finds it, and that has to be yab's,
        // not WebKit's (see Passkeys.swift).
        mendFileOnlyContentCSS(&manifest)
        let lateURL = folder.appendingPathComponent(lateList)
        let lateBefore = fresh ? [:] : ((try? JSONSerialization.jsonObject(with: Data(contentsOf: lateURL))) as? [String: [String]] ?? [:])
        var lateNow: [String: [String]] = [:]
        if var entries = manifest["content_scripts"] as? [[String: Any]] {
            // An earlier prepare's entry of the shim alone (`shimOnce`).
            entries.removeAll { ($0["js"] as? [String]) == [content] && ($0["css"] as? [Any] ?? []).isEmpty }
            // A wallet's page-world provider and its relay in its own world
            // (MetaMask: inpage.js and contentscript.js, 1.3 MB of SES and
            // LavaMoat whose run took 70-85 ms of a new tab's start on m4,
            // docs/evidence/night-extensions-2026-10-14.md). The provider
            // stays at document_start, so a page finds it as it loads; the
            // relay may come after the first frames: the two shake hands
            // over postMessage whichever starts first, and what the page
            // asked meanwhile waits in the provider's stream.
            let startsInPage = Set(entries.compactMap { entry -> [String]? in
                guard (entry["world"] as? String)?.uppercased() == "MAIN", (entry["run_at"] as? String) == "document_start" else { return nil }
                return sites(entry["matches"])
            })
            // A late file is fetched from the package, which is reachable only
            // from the sites listed for it; WebKit before macOS 26.7 refuses a
            // file:// pattern there and with it the whole list (MetaMask's
            // relay never ran on renderer-2). So a late entry is for web
            // sites, and its files run on files as before, in a twin entry
            // of the file patterns alone, which a later prepare keeps as it
            // is (an entry for files alone is never late).
            var twins: [[String: Any]] = []
            var mapped = entries.enumerated().map { index, entry -> [String: Any] in
                var entry = entry
                // "file://*/*", every file in Chrome, said as a manifest
                // WebKit takes says it (Bitwarden's "file:///*").
                for key in ["matches", "exclude_matches"] {
                    guard let list = entry[key] as? [Any] else { continue }
                    entry[key] = list.map { item -> Any in
                        guard let text = item as? String, text.hasPrefix("file://*/") else { return item }
                        return "file:///" + text.dropFirst("file://*/".count)
                    }
                }
                if var js = entry["js"] as? [String] {
                    // An earlier prepare's late file stands for the files it holds.
                    js = js.flatMap { lateBefore[$0] ?? [$0] }
                    js.removeAll { fastFiles.contains($0) || $0 == file }
                    let main = (entry["world"] as? String)?.uppercased() == "MAIN"
                    // The page's own world has no extension APIs: the shim
                    // returns there at once, but was still read in every
                    // frame (two copies a page for NordPass). Only what
                    // runs in the extension's world gets it, as scripts
                    // registered later do (registerContentScripts in it).
                    // Once per extension (`shimOnce`), it is in an entry of
                    // its own, first, added below.
                    if main || shimOnce {
                        js.removeAll { $0 == content }
                    } else if !js.contains(content) {
                        js.insert(content, at: 0)
                    }
                    let relay = !sites(entries[index]["matches"]).isEmpty && startsInPage.contains(sites(entries[index]["matches"]))
                    // A button without a popup dispatches onClicked, commonly
                    // followed by tabs.sendMessage. There is no readiness
                    // barrier between that event and a deferred content file.
                    // Keep its listeners at the manifest's injection point.
                    let action = manifest["action"] as? [String: Any]
                    let contentAction = action != nil && ((action?["default_popup"] as? String) ?? "").isEmpty
                    if !main, !contentAction, !sites(entry["matches"]).isEmpty, let late = late(js.filter { $0 != content }, runAt: entry["run_at"] as? String, in: folder,
                                              manifestV3: (manifest["manifest_version"] as? Int) == 3, relay: relay, entry: index) {
                        let name = "yab-late-\(index).js"
                        if (try? late.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil {
                            lateNow[name] = js.filter { $0 != content }
                            let matches = entry["matches"] as? [String] ?? []
                            let files = matches.filter { $0.hasPrefix("file:") }
                            if !files.isEmpty, files.count < matches.count {
                                var twin = entry
                                twin["matches"] = files
                                twin["js"] = js
                                twins.append(twin)
                                entry["matches"] = matches.filter { !$0.hasPrefix("file:") }
                            }
                            js = (js.contains(content) ? [content] : []) + [name]
                        }
                    }
                    if main {
                        if !js.contains(passkeys) { js.insert(passkeys, at: 0) }
                        if !js.contains(idle), js.contains(where: { idlers.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }) {
                            js.insert(idle, at: 0)
                        }
                        if !js.contains(audio), js.contains(where: { players.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }) {
                            js.insert(audio, at: 0)
                        }
                    }
                    entry["js"] = js
                }
                return entry
            }
            mapped += twins
            // The shim before anything of the extension's runs in its world:
            // an entry of its own, at document_start, wherever one of the
            // extension's in that world may run. The shim returns at once in
            // a world that already has it, but each copy was read; Bitwarden
            // and 1Password carry two such entries in every frame.
            let own = mapped.filter { ($0["world"] as? String)?.uppercased() != "MAIN" && !(($0["js"] as? [String]) ?? []).isEmpty }
            if shimOnce, !own.isEmpty {
                mapped.insert(contentsOf: shimEntries(for: own), at: 0)
            }
            manifest["content_scripts"] = mapped
            // A stub reads its files from the package, as the page's own
            // fetch would: they are made reachable from where it runs, and
            // from there only (the origins of the entry's matches). WebKit
            // names the package by a random address of its own, so a site
            // can't look for them to tell the extension is there.
            if !lateBefore.isEmpty || !lateNow.isEmpty, (manifest["manifest_version"] as? Int) == 3 {
                var accessible = (manifest["web_accessible_resources"] as? [Any] ?? []).filter { item in
                    guard let resources = (item as? [String: Any])?["resources"] as? [String] else { return true }
                    return !lateBefore.values.contains(resources.map { "/" + $0 }) && !lateBefore.values.contains(resources)
                }
                for (name, held) in lateNow.sorted(by: { $0.key < $1.key }) {
                    guard let index = Int(name.dropFirst("yab-late-".count).dropLast(".js".count)), index < entries.count else { continue }
                    // Web sites only (files have the twin above): one pattern
                    // WebKit refuses, Chrome's file://*/* (MetaMask's) or a
                    // file:// one at all before macOS 26.7, and the whole list
                    // is refused, and the stub's fetch with it.
                    let origins = (entries[index]["matches"] as? [String] ?? ["<all_urls>"])
                        .filter { !$0.hasPrefix("file:") }
                        .map(originPattern)
                    accessible.append(["resources": held, "matches": Array(NSOrderedSet(array: origins)) as? [String] ?? origins] as [String: Any])
                }
                manifest["web_accessible_resources"] = accessible.isEmpty ? nil : accessible
            }
        }

        for name in lateBefore.keys where lateNow[name] == nil {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
        if lateNow.isEmpty {
            try? files.removeItem(at: lateURL)
        } else if let data = try? JSONSerialization.data(withJSONObject: lateNow, options: [.sortedKeys]) {
            try data.write(to: lateURL, options: .atomic)
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)

        // Every page it ships, popup, options, background page, side panel.
        let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  ["html", "htm"].contains(url.pathExtension.lowercased()),
                  var html = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            if fast {
                let before = html
                for name in fastFiles { html = html.replacingOccurrences(of: "<script src=\"/\(name)\"></script>", with: "") }
                if html != before { try? html.write(to: url, atomically: true, encoding: .utf8) }
            }
            html = try ExtensionPageModules.join(html, page: url, folder: folder)
            if html.contains(file) {
                try html.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            let tag = "<script src=\"/\(file)\"></script>"
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Chrome's policy for a Manifest V3 extension's pages, when it names
    /// none: its own scripts, and WebAssembly. WebKit's has no WebAssembly
    /// ("script-src 'self'"), so a package that compiles some was refused
    /// at the first module. LINE keeps its encryption in a WebAssembly
    /// build in its sandbox page (ltsmSandbox.html) and its app waited on
    /// that page for good: the window opened blank (#395). A package that
    /// ships WebAssembly or sandbox pages (where Chrome allows it too) and
    /// names no policy for its pages gets Chrome's.
    nonisolated static let chromePagesPolicy = "script-src 'self' 'wasm-unsafe-eval'; object-src 'self';"

    nonisolated static func mendWasmPolicy(_ manifest: inout [String: Any], in folder: URL,
                                           dropsWasmKeyword: Bool = webKitDropsWasmKeyword) {
        guard (manifest["manifest_version"] as? Int) == 3 else { return }
        restoreGivenPagesPolicy(&manifest, in: folder)
        let given = manifest["content_security_policy"]
        guard given == nil || given is [String: Any] else { return }
        var policy = given as? [String: Any] ?? [:]
        if policy["extension_pages"] == nil {
            let sandboxed = !(((manifest["sandbox"] as? [String: Any])?["pages"] as? [Any]) ?? []).isEmpty
            guard sandboxed || shipsWasm(folder) else { return }
            policy["extension_pages"] = chromePagesPolicy
        }
        if dropsWasmKeyword, let pages = policy["extension_pages"] as? String, let mended = wasmPolicyForSafari18(pages) {
            // What the package said is kept beside it, so a Mac whose WebKit
            // takes the keyword again (Safari 26) gets the package's own back.
            let record: [String: Any] = ["given": given ?? NSNull()]
            if let data = try? JSONSerialization.data(withJSONObject: record) {
                try? data.write(to: folder.appendingPathComponent(givenPolicyFile))
            }
            policy["extension_pages"] = mended
        }
        manifest["content_security_policy"] = policy
    }

    /// Safari 18's WebKit (its 621 branch, what macOS 15 runs until Safari 26
    /// is installed) reads no keyword in a Manifest V3 extension's script-src,
    /// 'wasm-unsafe-eval' included (WebKit bug 290153, fixed in Safari 26).
    /// With script-src naming no way to compile, every WebAssembly module is
    /// refused: Bitwarden opens on "WebAssembly is not supported on your
    /// browser" and nothing else (#566, #593, both on macOS 15.7).
    /// `YAB_EXT_WASM_KEYWORD=dropped` or `kept` says it for a test.
    nonisolated static let webKitDropsWasmKeyword: Bool = {
        switch ProcessInfo.processInfo.environment["YAB_EXT_WASM_KEYWORD"] {
        case "dropped": return true
        case "kept": return false
        default: break
        }
        let version = Bundle(for: WKWebView.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard let major = Int(version.prefix(while: \.isNumber)) else { return false }
        return major % 1000 < 622
    }()

    /// Where `mendWasmPolicy` keeps the package's own policy when it wrote
    /// another one for Safari 18.
    nonisolated static let givenPolicyFile = ".yab-pages-policy"

    nonisolated private static func restoreGivenPagesPolicy(_ manifest: inout [String: Any], in folder: URL) {
        let file = folder.appendingPathComponent(givenPolicyFile)
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let given = record["given"] else { return }
        manifest["content_security_policy"] = given is NSNull ? nil : given
        try? FileManager.default.removeItem(at: file)
    }

    /// The same policy said so Safari 18 compiles WebAssembly: Safari 18
    /// checks WebAssembly against script-src (or default-src) alone, so
    /// script-src's sources move to script-src-elem, which still decides
    /// every script the pages load, script-src-attr keeps inline handlers
    /// out and worker-src keeps workers to the same sources. What is given
    /// up, on Safari 18 only, is the refusal of eval, which a Manifest V2
    /// extension could ask for in Chrome too. A policy with default-src, or
    /// whose script-src names no WebAssembly, is left as it is.
    nonisolated static func wasmPolicyForSafari18(_ policy: String) -> String? {
        var directives = policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        func name(_ directive: String) -> String { String(directive.split(whereSeparator: \.isWhitespace).first ?? "").lowercased() }
        let names = Set(directives.map(name))
        guard !names.contains("default-src"), let index = directives.firstIndex(where: { name($0) == "script-src" }) else { return nil }
        let sources = directives[index].split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
        guard sources.contains(where: { $0.lowercased() == "'wasm-unsafe-eval'" }) else { return nil }
        let kept = sources.filter { !["'wasm-unsafe-eval'", "'unsafe-eval'"].contains($0.lowercased()) }
        let said = kept.isEmpty ? "'none'" : kept.joined(separator: " ")
        var replacing: [String] = []
        if !names.contains("script-src-elem") { replacing.append("script-src-elem " + said) }
        if !names.contains("script-src-attr") { replacing.append("script-src-attr 'none'") }
        if !names.contains("worker-src") && !names.contains("child-src") { replacing.append("worker-src " + said) }
        directives.replaceSubrange(index...index, with: replacing)
        return directives.joined(separator: "; ") + ";"
    }

    nonisolated private static func shipsWasm(_ folder: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        for case let file as URL in files where file.pathExtension.lowercased() == "wasm" { return true }
        return false
    }

    /// The scripts and stylesheets a package ships empty get a line break.
    /// macOS 15's WebKit reads an empty file as no text and no error, and
    /// scripting.executeScript and insertCSS then record that missing error:
    /// an exception on the main thread, and Yab quit as an extension
    /// injected an empty file (crash #97, #98; newer WebKit reads it as an
    /// empty string). A line break runs and styles as nothing does.
    nonisolated static func fillEmptyScripts(in folder: URL) {
        let kinds: Set<String> = ["js", "mjs", "cjs", "css"]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else { return }
        for case let file as URL in files where kinds.contains(file.pathExtension.lowercased()) {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 0
            else { continue }
            try? Data("\n".utf8).write(to: file)
        }
    }

    /// `getBackgroundPage() === window`, the test of code that runs in a
    /// background page and a worker both for being the background. Chrome's
    /// worker has no getBackgroundPage, so the test stops there; WebKit's
    /// has, and the worker has no `window`: the comparison throws. Eagle's
    /// logger asks it as its worker imports it, through `browser`, and the
    /// throw ended the imports: no "Save to Eagle" row, and no save reached
    /// the app (row 1001). WebKit's namespaces don't let the function be
    /// taken away, so the comparison reads `globalThis.window` instead:
    /// the same object in a page, undefined in the worker.
    nonisolated static let windowCompare = try! NSRegularExpression(pattern: #"getBackgroundPage\(\)(\s*[!=]==?\s*)window(?![\w$.])"#)

    nonisolated static func mendWorkerWindow(in folder: URL) {
        let kinds: Set<String> = ["js", "mjs", "cjs"]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return }
        for case let url as URL in files where kinds.contains(url.pathExtension.lowercased()) && url.lastPathComponent != file {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let text = try? String(contentsOf: url, encoding: .utf8), text.contains("getBackgroundPage")
            else { continue }
            let mended = mendWindowCompare(text)
            if mended != text { try? mended.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    nonisolated static func mendWindowCompare(_ text: String) -> String {
        windowCompare.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: "getBackgroundPage()$1globalThis.window")
    }

    /// `"content_scripts": []`, as FontPulse ships it: Chrome reads no
    /// scripts, WebKit lists "Empty or invalid `content_scripts` manifest
    /// entry" and the extension wears a warning triangle in Settings for
    /// nothing (feedback #140's set). An empty list goes.
    nonisolated static func mendEmptyContentScripts(_ manifest: inout [String: Any]) {
        if let entries = manifest["content_scripts"] as? [Any], entries.isEmpty { manifest["content_scripts"] = nil }
    }

    /// `externally_connectable` that lets nobody in, as Rabby Wallet's
    /// `{"ids": []}`, means in Chrome what no entry means for web pages:
    /// none of them may connect. WebKit calls such an entry invalid and
    /// lists the error, and the extension wears a warning triangle in
    /// Settings for a manifest Chrome takes as it is (feedback #107). An
    /// entry with no site it can use and no extension id is taken out;
    /// `<all_urls>`, which Chrome refuses there too, is left out of its
    /// matches. Anything else stays as written.
    nonisolated static func mendExternallyConnectable(_ manifest: inout [String: Any]) {
        guard let entry = manifest["externally_connectable"] else { return }
        guard var dictionary = entry as? [String: Any] else {
            manifest["externally_connectable"] = nil
            return
        }
        let nonEmpty = { (key: String) in ((dictionary[key] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty } }
        // Chrome treats an omitted port as `:*`; WebKit accepts the former.
        let matches = nonEmpty("matches").filter { $0 != "<all_urls>" }.map {
            $0.replacingOccurrences(of: #"^((?:https?|\*)://[^/:]+):\*/"#, with: "$1/", options: .regularExpression)
        }
        let ids = nonEmpty("ids")
        guard !matches.isEmpty || !ids.isEmpty else {
            manifest["externally_connectable"] = nil
            return
        }
        if dictionary["matches"] != nil {
            if matches.isEmpty { dictionary["matches"] = nil } else { dictionary["matches"] = matches }
        }
        manifest["externally_connectable"] = dictionary
    }

    /// The sites whose pages may talk to the extension, from a manifest
    /// `mendExternallyConnectable` has been through: its
    /// externally_connectable matches (ExtensionExternal.swift).
    nonisolated static func externalPages(of manifest: [String: Any]) -> [String] {
        ((manifest["externally_connectable"] as? [String: Any])?["matches"] as? [Any] ?? [])
            .compactMap { $0 as? String }.filter { !$0.isEmpty && $0 != "<all_urls>" }
    }

    /// Chrome permits a shortcut-less action command and supplies its label
    /// from the action. WebKit reports that entry as an invalid command, and
    /// requires a description when the shortcut is present.
    nonisolated static func mendActionCommands(_ manifest: inout [String: Any]) {
        guard var commands = manifest["commands"] as? [String: Any] else { return }
        if commands["_execute_action"] != nil {
            commands["_execute_browser_action"] = nil
        }
        if var action = commands["_execute_action"] as? [String: Any] {
            let keys = action["suggested_key"] as? [String: Any] ?? [:]
            if keys.isEmpty {
                commands["_execute_action"] = nil
            } else if (action["description"] as? String)?.isEmpty != false {
                action["description"] = (manifest["action"] as? [String: Any])?["default_title"] as? String
                    ?? manifest["name"] as? String ?? "Activate extension"
                commands["_execute_action"] = action
            }
        }
        if commands.isEmpty { manifest["commands"] = nil } else { manifest["commands"] = commands }
    }

    /// What WebKit is told the button's popup is: a stand-in beside the page
    /// (popup.html → popup.yab-action.html), never loaded, while Yab opens
    /// the page itself at its own address (Extensions.popupURL). WebKit takes
    /// any page at its popup's path for its own popup and sends it no
    /// events (see Extensions.popupCopy); a page loaded from a copy under
    /// another name heard them, but said that name: Rabby's popup takes
    /// itself for a popup only at "/popup.html", named its port to the
    /// worker nothing at "/popup.yab-popup.html", and the worker, taking it
    /// for a website, never said it was ready: "Rabby failed to start"
    /// (feedback #107). With the stand-in, the page is at its own address
    /// and hears everything. Popups set later are told to WebKit the same
    /// way (`action.setPopup` in the script).
    nonisolated static let actionStandIn = ".yab-action"

    nonisolated static func standIn(_ path: String) -> String {
        guard !path.isEmpty, !path.contains(actionStandIn), !path.contains("://") else { return path }
        let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }).map { String(path[$0...]) } ?? ""
        let bare = String(path.dropLast(query.count))
        let ext = (bare as NSString).pathExtension
        return (ext.isEmpty ? bare + actionStandIn : (bare as NSString).deletingPathExtension + actionStandIn + "." + ext) + query
    }

    nonisolated static func unStandIn(_ path: String) -> String { path.replacingOccurrences(of: actionStandIn, with: "") }

    nonisolated static func mendPopup(_ manifest: inout [String: Any], in folder: URL) {
        for key in ["action", "browser_action"] {
            guard var action = manifest[key] as? [String: Any], let path = action["default_popup"] as? String, !path.isEmpty,
                  !path.contains("://") else { continue }
            let original = unStandIn(path)
            let bare = original.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? original
            // A file of the extension's own, inside its folder.
            guard let source = inside(bare, of: folder), FileManager.default.fileExists(atPath: source.path) else { continue }
            let named = standIn(original)
            let standInBare = named.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? named
            let target = folder.appendingPathComponent(standInBare.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            guard target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { continue }
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
            action["default_popup"] = named
            manifest[key] = action
        }
    }

    /// A file pattern among the sites a web-accessible resource may be
    /// loaded from, Chrome's "file://*/*" or "file:///*": WebKit refuses
    /// it, and with it the whole `web_accessible_resources` entry, so no
    /// page can load any of them. Eagle lists "file://*/*" beside
    /// "<all_urls>" for each of its in-page windows, and lost them all,
    /// with a warning on its card. The file patterns go; an entry that had
    /// only those goes with them.
    nonisolated static func mendAccessibleResources(_ manifest: inout [String: Any]) {
        guard let entries = manifest["web_accessible_resources"] as? [Any] else { return }
        let isFile = { (item: Any) in (item as? String)?.lowercased().hasPrefix("file:") == true }
        guard entries.contains(where: { (($0 as? [String: Any])?["matches"] as? [Any])?.contains(where: isFile) == true }) else { return }
        manifest["web_accessible_resources"] = entries.compactMap { entry -> Any? in
            guard var dictionary = entry as? [String: Any], let matches = dictionary["matches"] as? [Any],
                  matches.contains(where: isFile) else { return entry }
            let others = matches.filter { !isFile($0) }
            if others.isEmpty, dictionary["extension_ids"] == nil { return nil }
            dictionary["matches"] = others
            return dictionary
        }
    }

    /// WebKit rejects a CSS-only content script when all its matches are
    /// file URLs. Keep HTTP(S) entries intact; file URL injection still
    /// needs a separate permission-aware implementation.
    nonisolated static func mendFileOnlyContentCSS(_ manifest: inout [String: Any]) {
        guard let entries = manifest["content_scripts"] as? [[String: Any]] else { return }
        manifest["content_scripts"] = entries.compactMap { entry -> [String: Any]? in
            guard entry["js"] == nil,
                  let css = entry["css"] as? [String], !css.isEmpty,
                  let matches = entry["matches"] as? [String],
                  matches.contains(where: { $0.lowercased().hasPrefix("file:") })
            else { return entry }
            let supported = matches.filter { !$0.lowercased().hasPrefix("file:") }
            guard !supported.isEmpty else { return nil }
            var adjusted = entry
            adjusted["matches"] = supported
            return adjusted
        }
    }

    /// Fast's own files beside an extension go, and what Fast added to its
    /// permissions is kept as yab's addition, so the extension is still
    /// described by what it asked for. The scripts and pages that name
    /// Fast's shim are mended where `prepare` goes through them.
    nonisolated static func unFast(_ folder: URL) {
        let files = FileManager.default
        let fastAdded = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".fast-added")))) as? [String] ?? []
        let addedURL = folder.appendingPathComponent(".yab-added")
        let added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: addedURL))) as? [String] ?? []
        if let data = try? JSONSerialization.data(withJSONObject: Array(Set(added + fastAdded)).sorted()) {
            try? data.write(to: addedURL)
        }
        for name in [".fast-shim", ".fast-added"] + fastFiles {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
        // The user scripts it saved and their worlds move to where yab
        // reads them; the files made from them are made again, since the
        // ones there were made for Fast's shim.
        let old = folder.appendingPathComponent("_fast", isDirectory: true)
        guard files.fileExists(atPath: old.path) else { return }
        let new = folder.appendingPathComponent("_yab", isDirectory: true)
        try? files.createDirectory(at: new, withIntermediateDirectories: true)
        for name in ["userscripts.json", "worlds.json"] where !files.fileExists(atPath: new.appendingPathComponent(name).path) {
            try? files.moveItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name))
        }
        try? files.removeItem(at: old)
    }

    /// Scripts the extension registered in a page's own world are kept by
    /// WebKit across launches, and Fast's named its patch by the old name
    /// in each. WebKit can't load one naming a file that is gone, nor take
    /// it off when the extension asks to, so the extension's own register
    /// then fails on the same id (React Developer Tools). The old name is
    /// taken out of what WebKit keeps, before WebKit opens it.
    nonisolated static func unFastRegistered(_ id: String) {
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let files = FileManager.default
        let stores = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit/\(bundle)/WebExtensions", isDirectory: true)
        for store in (try? files.contentsOfDirectory(at: stores, includingPropertiesForKeys: nil)) ?? [] {
            let file = store.appendingPathComponent(id).appendingPathComponent("RegisteredContentScripts.db")
            guard files.fileExists(atPath: file.path) else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            var rows: [(String, Data)] = []
            var read: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT key, script FROM registered_scripts", -1, &read, nil) == SQLITE_OK {
                while sqlite3_step(read) == SQLITE_ROW {
                    guard let key = sqlite3_column_text(read, 0), let bytes = sqlite3_column_blob(read, 1) else { continue }
                    rows.append((String(cString: key), Data(bytes: bytes, count: Int(sqlite3_column_bytes(read, 1)))))
                }
            }
            sqlite3_finalize(read)
            for (key, data) in rows {
                guard var script = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let js = script["js"] as? [String], js.contains(where: fastFiles.contains)
                else { continue }
                script["js"] = js.filter { !fastFiles.contains($0) }
                guard let mended = try? JSONSerialization.data(withJSONObject: script) else { continue }
                var write: OpaquePointer?
                guard sqlite3_prepare_v2(db, "UPDATE registered_scripts SET script = ? WHERE key = ?", -1, &write, nil) == SQLITE_OK else { continue }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                _ = mended.withUnsafeBytes { sqlite3_bind_blob(write, 1, $0.baseAddress, Int32(mended.count), transient) }
                sqlite3_bind_text(write, 2, key, -1, transient)
                sqlite3_step(write)
                sqlite3_finalize(write)
            }
        }
    }

    /// A path a package names, resolved and kept inside the folder it came
    /// in: `..` in a manifest is not a way out of the package. Nor is a
    /// symbolic link, which a folder install keeps as it is: the worker is
    /// read through it and written back over it as a regular file, so a
    /// link to a file elsewhere would put that file's bytes in the package.
    /// A folder on the way that is a link is caught by where it resolves.
    nonisolated static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    /// The shim as far as a content script goes in it: up to where it
    /// returns for one, and closed there. Nothing after that line is reached
    /// in a content script, and nothing before it names a function declared
    /// after it, so it runs the same.
    nonisolated static func contentPart(of script: String) -> String {
        guard let end = script.range(of: "if (inContent) return;") else { return script }
        // And without the blocks at its top level only a worker or the
        // extension's own pages go into: `if (worker …) {` or
        // `if (!inContent …) {` through the `}` at the same depth.
        let whole = String(script[..<end.lowerBound]) + "})();\n"
        var kept: [Substring] = []
        var skipping: String?
        for line in script[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            if let close = skipping {
                if line == close { skipping = nil }
                // An else would need the block's other half: kept whole.
                else if line.hasPrefix(close + " else") { return whole }
                continue
            }
            let bare = line.drop { $0 == " " }
            if bare.hasPrefix("if (worker") || bare.hasPrefix("if (!inContent"), bare.hasSuffix("{"), !bare.contains("}") {
                skipping = String(repeating: " ", count: line.count - bare.count) + "}"
                continue
            }
            kept.append(line)
        }
        return skipping == nil ? kept.joined(separator: "\n") + "})();\n" : whole
    }

    /// Generated after contentPart's pruning, with no compression or renamed
    /// identifiers. Only the same three content-world switches are bound here.
    nonisolated static func contentShim(for folder: URL) -> String {
        contentScript.replacingOccurrences(of: "__YAB_DCL_LATE__", with: dclLate && !blocks(folder) ? "true" : "false")
            .replacingOccurrences(of: "__YAB_PORT_TRACE__", with: portTrace ? "true" : "false")
            .replacingOccurrences(of: "__YAB_PORT_SLOW__", with: portSlow ? "true" : "false")
    }

    /// The scripts it ships that call requestIdleCallback, as paths inside
    /// the folder without a leading slash: in a page's own world they get
    /// `idle` first (the manifest's here, the registered and executed ones
    /// in the shim). Not yab's own files, nor the shim at a worker's top.
    nonisolated static func idleCallers(in folder: URL) -> Set<String> {
        callers(of: "requestIdleCallback", in: folder)
    }

    /// The scripts it ships that make an AudioContext: in a page's own
    /// world they get `audio` first, as `idle` above.
    nonisolated static func audioCallers(in folder: URL) -> Set<String> {
        callers(of: "AudioContext", in: folder)
    }

    nonisolated static func callers(of word: String, in folder: URL) -> Set<String> {
        var found = Set<String>()
        let root = folder.standardizedFileURL.path + "/"
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", ![file, content, passkeys, idle, audio].contains(url.lastPathComponent),
                  url.standardizedFileURL.path.hasPrefix(root),
                  var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.hasPrefix(marker), let end = text.range(of: ender) { text = String(text[end.upperBound...]) }
            if text.contains(word) { found.insert(String(url.standardizedFileURL.path.dropFirst(root.count))) }
        }
        return found
    }

    /// The shim as this extension gets it: with the events its code mentions
    /// `chrome.tabs.onUpdated`, `e.runtime.onInstalled`, so its worker
    /// can take their listeners late (see the end of the script).
    /// An ad blocker's work as the document loads hides ads: kept where it
    /// is, not after the first frame (`dclLate`), or an ad would show for a
    /// frame. Blockers.isBlocker: one Yab knows, or 10,000 request rules.
    nonisolated static func blocks(_ folder: URL) -> Bool {
        Blockers.isBlocker(folder.lastPathComponent, folder: folder)
    }

    nonisolated static func shim(for folder: URL) -> String {
        var found = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", url.lastPathComponent != file, url.lastPathComponent != content,
                  var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Not the shim's own words, in a worker that already carries it.
            if text.hasPrefix(marker), let end = text.range(of: ender) { text = String(text[end.upperBound...]) }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
        }
        let list = (try? JSONSerialization.data(withJSONObject: found.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // And the scripts it ships, so its worker can be told at once that
        // one isn't there (see importScripts in the script).
        var scripts: [String] = []
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = all?.nextObject() as? URL {
            guard url.pathExtension == "js" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            // An empty one is marked: there is nothing to run in it.
            let empty = ((try? String(contentsOf: url, encoding: .utf8)) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((empty ? "-" : "") + path)
        }
        let shipped = (try? JSONSerialization.data(withJSONObject: scripts.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let idlers = (try? JSONSerialization.data(withJSONObject: idleCallers(in: folder).sorted(), options: .withoutEscapingSlashes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let players = (try? JSONSerialization.data(withJSONObject: audioCallers(in: folder).sorted(), options: .withoutEscapingSlashes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return script.replacingOccurrences(of: "__YAB_EVENTS__", with: list)
            .replacingOccurrences(of: "__YAB_IDLE__", with: idlers)
            .replacingOccurrences(of: "__YAB_AUDIO__", with: players)
            .replacingOccurrences(of: "__YAB_WARM__", with: ProcessInfo.processInfo.environment["YAB_CONTENT_WARM"] == "0" ? "false" : "true")
            .replacingOccurrences(of: "__YAB_SCRIPTS__", with: shipped)
            .replacingOccurrences(of: "__YAB_CHROME__", with: Crx.chromeVersion)
            .replacingOccurrences(of: "__YAB_VERBOSE__", with: Store.testing ? "true" : "false")
            .replacingOccurrences(of: "__YAB_DCL_LATE__", with: dclLate && !blocks(folder) ? "true" : "false")
            .replacingOccurrences(of: "__YAB_KEEP__", with: keepWorkers ? "true" : "false")
            .replacingOccurrences(of: "__YAB_PORT_TRACE__", with: portTrace ? "true" : "false")
            .replacingOccurrences(of: "__YAB_PORT_SLOW__", with: portSlow ? "true" : "false")
            .replacingOccurrences(of: "__YAB_LOCKS__", with: ownLocks ? "true" : "false")
    }

    /// Defines only what is missing, so the day WebKit implements an API,
    /// WebKit's is the one used.
    nonisolated static let script = PageScript.load("extension-shims")
        .replacingOccurrences(of: "__YAB_FILE_SYSTEM__", with: PageScript.load("legacy-file-system"))
    nonisolated static let contentScript = PageScript.load("extension-content.min")

    // MARK: - answering

    /// Remembered per extension: the side panel it set, and whether its
    /// button should open it.
    static var panelPath: [String: String] = [:]
    static var panelEnabled: [String: Bool] = [:]
    static var panelTabPath: [String: [Int: String]] = [:]
    static var panelTabEnabled: [String: [Int: Bool]] = [:]
    static var panelOnClick: Set<String> = []
    /// The extensions' own session rules where Yab split one ("dnr.originals").
    static var sessionRules: [String: [String: Any]] = [:]
    /// Offscreen documents, one per extension, as Chrome allows.
    static var offscreen: [String: WKWebView] = [:] {
        // One closed or replaced leaves the window it was seated in
        // (ExtensionCapture.seat), and goes.
        didSet {
            for (id, page) in oldValue where offscreen[id] !== page && page.window != nil { page.removeFromSuperview() }
        }
    }

    /// Its process gone, a document is gone, as in Chrome. Kept, it stayed
    /// listed with no one in it, so its worker never made another: every
    /// message went unanswered until Yab was quit, and Superhuman Mail,
    /// whose database is there, stayed broken through reloads.
    private final class OffscreenWatch: NSObject, WKNavigationDelegate {
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let id = ExtensionShims.offscreen.first(where: { $0.value === webView })?.key else { return }
            FeedbackDiagnostics.shared.record(.offscreenFailed, extensionID: id)
            ExtensionShims.offscreen[id] = nil
        }
    }
    private static let offscreenWatch = OffscreenWatch()

    /// A context going away takes its document with it, even when its worker
    /// cannot call closeDocument. Another sign-in may run the same id.
    static func closeOffscreen(_ id: String, in controller: WKWebExtensionController) {
        guard let page = offscreen[id], page.configuration.webExtensionController === controller else { return }
        page.stopLoading()
        // Removing the entry also removes a recorder's page from its seat.
        if offscreen[id] === page { offscreen[id] = nil }
    }

    nonisolated static func downloadsFromOffscreen(_ url: URL, extensionID: String) -> Bool {
        extensionID == "mpiodijhokgodhhofbcjdecpffjipkle" && url.scheme == "blob"
    }
    /// One voice for every extension that reads aloud.
    static let speaker = NSSpeechSynthesizer()

    /// Chrome accepts either a package path or runtime.getURL(path).
    /// A remote or another extension's page must never acquire this context.
    static func offscreenURL(_ path: String, base: URL) -> URL? {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host,
              url.port == base.port, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static var menuGenerations: [String: String] = [:]

    static func clearMenus(_ id: String) {
        Store.settings.removeObject(forKey: "extensions.menus.\(id)")
        menuGenerations[id] = UUID().uuidString
    }

    static func answer(_ message: Any, from context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let body = message as? [String: Any], let api = body["api"] as? String else {
            return ["error": "Not a Yab message"]
        }
        let args = body["args"] as? [Any] ?? []
        do {
            return ["value": try await run(api, args, context: context, owner: owner) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    /// The families whose answers leave the extension's own origin: what the
    /// browser knows about the person using it. WebKit keeps no permission
    /// object for them, they are the APIs this shim exists to supply, so the
    /// gate reads the names the extension's own manifest asked for.
    private static let gates: [String: String] = [
        "bookmarks": "bookmarks",
        "history": "history",
        "downloads": "downloads",
        "sessions": "sessions",
        "topSites": "topSites",
        "browsingData": "browsingData",
        "readingList": "readingList",
        "userScripts": "userScripts",
        "identity": "identity",
        "pageCapture": "pageCapture",
        "contentSettings": "contentSettings",
        "debugger": "debugger",
        "tabCapture": "tabCapture",
        "desktopCapture": "desktopCapture",
        "proxy": "proxy",
        "favicon": "favicon",
    ]

    /// What this extension asked for: the names in its manifest and any
    /// optional ones granted since. The checks inside the shim are a
    /// courtesy to honest code, the shim runs beside the extension's own,
    /// so the one that counts is here. The manifest is the one WebKit
    /// already holds, not the file read again on every call.
    static func allowed(_ id: String, context: WKWebExtensionContext) -> Set<String> {
        let asked = (context.webExtension.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        return Set(asked + (Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []))
    }

    private static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let browser = owner.browser else { throw Unsupported(what: "No browser window") }
        let first = args.first
        let id = context.uniqueIdentifier

        // A site's own cookies on an extension's request (ExtensionFetch).
        if api.hasPrefix("sitefetch.") { return try await ExtensionFetch.run(api, args, context: context) }

        if api.hasPrefix("setting.") {
            // A browser setting (chrome.privacy…) belongs to the family its
            // name starts with, and only an extension that asked for that
            // family may read or change it, as in Chrome.
            let name = api.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let family = String(name.prefix(while: { $0 != "." }))
            guard !family.isEmpty, allowed(id, context: context).contains(family) else {
                throw Unsupported(what: "The extension never asked for \u{201C}\(family)\u{201D}")
            }
            return try setting(api, first as? [String: Any] ?? [:], extension: id, owner: owner)
        }

        // What leaves this app is answered here, not in the injected script:
        // the shim runs beside the extension's own code, so its checks stop
        // only the honest. A family this extension never asked for is an
        // error, the way Chrome answers a call to an API it lacks.
        // `tabs.describe` is the one call inside a family WebKit does own
        // where the permission guards reading a tab rather than moving or
        // selecting it. WebKit keeps that permission, optional grants
        // included, so it is asked.
        if api == "tabs.describe", !context.hasPermission(.tabs) {
            throw Unsupported(what: "The extension never asked for \u{201C}tabs\u{201D}")
        }
        if let needed = gates[String(api.prefix(while: { $0 != "." }))], !allowed(id, context: context).contains(needed) {
            throw Unsupported(what: "The extension never asked for \u{201C}\(needed)\u{201D}")
        }
        if api.hasPrefix("contentSettings.") {
            return try ExtensionContentSettings.run(api, args, extensionID: id)
        }
        if api.hasPrefix("omnibox.") {
            return try ExtensionOmnibox.shared.run(api, args, context: context)
        }
        if api.hasPrefix("debugger.") {
            return try await ExtensionDebugger.shared.run(api, args, context: context, owner: owner)
        }

        switch api {
        // MARK: bookmarks
        case "bookmarks.getTree":
            return [root(browser.bookmarks.roots)]
        case "bookmarks.getSubTree":
            guard let key = first as? String else { return [] }
            if key == "0" { return [root(browser.bookmarks.roots)] }
            if key == "1" { return [bar(browser.bookmarks.roots)] }
            return find(key, in: browser.bookmarks.roots).map { [node($0.node, parent: $0.parent, index: $0.index, deep: true)] } ?? []
        case "bookmarks.getChildren":
            let key = first as? String ?? "1"
            if key == "0" { return [bar(browser.bookmarks.roots, deep: false)] }
            let kids = key == "1" ? browser.bookmarks.roots : (find(key, in: browser.bookmarks.roots)?.node.children ?? [])
            return kids.enumerated().map { node($1, parent: key, index: $0, deep: false) }
        case "bookmarks.get":
            let keys = (first as? [String]) ?? (first as? String).map { [$0] } ?? []
            return keys.compactMap { key in
                find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
            }
        case "bookmarks.getRecent":
            // Newest first by when each was kept; those with no day, as if
            // the list's end were the newest.
            let count = (first as? Int) ?? 10
            let sites = flat(browser.bookmarks.roots).filter { !$0.node.isFolder }.enumerated()
            return sites.sorted { a, b in
                let x = a.element.node.added ?? .distantPast, y = b.element.node.added ?? .distantPast
                return x != y ? x > y : a.offset > b.offset
            }.prefix(count).map { node($0.element.node, parent: $0.element.parent, index: $0.element.index, deep: false) }
        case "bookmarks.search":
            let query = (first as? String) ?? ((first as? [String: Any])?["query"] as? String) ?? ""
            let wantURL = (first as? [String: Any])?["url"] as? String
            let wantTitle = (first as? [String: Any])?["title"] as? String
            let words = query.lowercased().split(separator: " ").map(String.init)
            return flat(browser.bookmarks.roots).filter { hit in
                let n = hit.node
                if let wantURL, n.url != wantURL { return false }
                if let wantTitle, n.title != wantTitle { return false }
                let hay = (n.title + " " + (n.url ?? "")).lowercased()
                return words.allSatisfy { hay.contains($0) }
            }.map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.create":
            let spec = first as? [String: Any] ?? [:]
            let title = spec["title"] as? String ?? ""
            let parent = (spec["parentId"] as? String).flatMap(UUID.init(uuidString:))
            let made: Bookmark
            if let url = (spec["url"] as? String).flatMap(URL.init(string:)) {
                made = browser.bookmarks.insert(.site(title, url), into: parent)
            } else {
                made = browser.bookmarks.insert(.folder(title, []), into: parent)
            }
            return node(made, parent: parent?.uuidString ?? "1", index: 0, deep: false)
        case "bookmarks.update":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            let changes = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            browser.bookmarks.update(uuid, title: changes["title"] as? String, url: changes["url"] as? String)
            return find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.move":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            let target = (args.count > 1 ? args[1] as? [String: Any] : nil)?["parentId"] as? String
            browser.bookmarks.move(uuid, into: target.flatMap(UUID.init(uuidString:)))
            return find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.remove", "bookmarks.removeTree":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            browser.bookmarks.remove(uuid)
            return nil

        // MARK: history
        case "history.search":
            let spec = first as? [String: Any] ?? [:]
            let text = spec["text"] as? String ?? ""
            let start = (spec["startTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? Date().addingTimeInterval(-24 * 3600)
            let end = (spec["endTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture
            let limit = spec["maxResults"] as? Int ?? 100
            return browser.history.everything(matching: text)
                .filter { $0.last >= start && $0.last <= end }
                .sorted { $0.last > $1.last }
                .prefix(limit)
                .map(visit)
        case "history.getVisits":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            return browser.history.everything().filter { $0.url.absoluteString == url }.map { trace in
                ["id": trace.key, "visitId": "1", "visitTime": trace.last.timeIntervalSince1970 * 1000,
                 "referringVisitId": "0", "transition": "link"]
            }
        case "history.addUrl":
            if let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) {
                browser.history.record(url, title: "")
            }
            return nil
        case "history.deleteUrl":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            for trace in browser.history.everything() where trace.url.absoluteString == url {
                browser.history.forget(trace.key)
            }
            return nil
        case "history.deleteRange":
            let spec = first as? [String: Any] ?? [:]
            let start = Date(timeIntervalSince1970: (spec["startTime"] as? Double ?? 0) / 1000)
            let end = Date(timeIntervalSince1970: (spec["endTime"] as? Double ?? 0) / 1000)
            for trace in browser.history.everything() where trace.last >= start && trace.last <= end {
                browser.history.forget(trace.key)
            }
            return nil
        case "history.deleteAll":
            browser.history.forget()
            return nil

        // MARK: downloads
        case "downloads.filenameListening":
            ExtensionDownloads.owner = owner
            ExtensionDownloads.listensForFilename(first as? Bool == true, extension: id, owner: owner)
            return nil
        case "downloads.filenameSuggestion":
            let spec = first as? [String: Any] ?? [:]
            if let request = spec["request"] as? String {
                ExtensionDownloads.filenameSuggestion(request, by: id, owner: owner, filename: spec["filename"] as? String)
            }
            return nil
        case "downloads.download":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No url to download") }
            // A blob belongs to the WKWebView which created it. SingleFile's
            // default save creates one in its offscreen document, not in the
            // active website; downloading it from the website loses the file.
            let source = downloadsFromOffscreen(url, extensionID: id) ? offscreen[id] : nil
            // Any extension's blob is its own pages', not the website's in
            // front: a page saver's MHTML made in its own tab, its offscreen
            // document or wherever it was made, downloaded through a page
            // of the same extension.
            let own = url.scheme == "blob" && URL(string: String(url.absoluteString.dropFirst(5)))?.host() == context.baseURL.host()
                ? (browser.everyTab.lazy.filter { $0.address?.host() == context.baseURL.host() }.compactMap { $0.webKitOnly("Legacy WebKit extension source", build: false) }.first as WKWebView?) ?? offscreen[id]
                : nil
            guard let web = source ?? own ?? browser.active?.webKitOnly("Legacy WebKit extension source", build: false) ?? browser.tabs.lazy.compactMap { $0.webKitOnly("Legacy WebKit extension source", build: false) }.first else {
                throw Unsupported(what: "No page to download through")
            }
            let name = spec["filename"] as? String
            if let name, DownloadRequest.relativeFilename(name) == nil {
                throw Unsupported(what: "Invalid relative download filename")
            }
            ExtensionDownloads.owner = owner
            // Its delegate set in WebKit's own call, before WebKit asks where
            // it goes: awaited, the answer came after the question, and every
            // other download of a burst waited for a place for ever.
            let download: WKDownload = await withCheckedContinuation { done in
                web.startDownload(using: URLRequest(url: url)) { download in
                    MainActor.assumeIsolated {
                        if let name { browser.downloadNames[ObjectIdentifier(download)] = name }
                        ExtensionDownloads.asking(download, by: id)
                        browser.keep(download)
                    }
                    done.resume(returning: download)
                }
            }
            return ExtensionDownloads.started(download, by: id)
        case "downloads.search":
            return ExtensionDownloads.search(first as? [String: Any] ?? [:], loot: browser.loot)
        case "downloads.open", "downloads.show":
            guard let index = first as? Int, let item = ExtensionDownloads.item(index), !item.filename.isEmpty else {
                throw Unsupported(what: "Invalid download id")
            }
            let file = URL(fileURLWithPath: item.filename)
            if api == "downloads.open" {
                guard item.state == "complete" else { throw Unsupported(what: "Download must be complete") }
                NSWorkspace.shared.open(file)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
            return nil
        case "downloads.showDefaultFolder":
            NSWorkspace.shared.open(browser.prefs.downloads)
            return nil
        case "downloads.erase":
            return ExtensionDownloads.erase(first as? [String: Any] ?? [:], loot: browser.loot)
        case "downloads.pause":
            try await ExtensionDownloads.pause(first as? Int ?? -1, hoard: browser.hoard)
            return nil
        case "downloads.resume":
            try ExtensionDownloads.resume(first as? Int ?? -1, hoard: browser.hoard)
            return nil
        case "downloads.cancel":
            ExtensionDownloads.cancel(first as? Int ?? -1, hoard: browser.hoard, browser: browser)
            return nil
        case "downloads.removeFile":
            try ExtensionDownloads.removeFile(first as? Int ?? -1)
            return nil
        case "downloads.getFileIcon":
            let options = (args.count > 1 ? args[1] : nil) as? [String: Any] ?? [:]
            return try ExtensionDownloads.icon(first as? Int ?? -1, size: options["size"] as? Int ?? 32)
        // Yab has no shelf to hide (its button stays where it lives), and
        // nothing it downloads is held back as dangerous.
        case "downloads.setUiOptions", "downloads.setShelfEnabled", "downloads.acceptDanger":
            return nil
        // What happened since the shim last asked (onCreated, onChanged,
        // onErased): the answer waits for something to (ExtensionDownloads).
        case "downloads.events":
            ExtensionDownloads.owner = owner
            let spec = first as? [String: Any] ?? [:]
            if spec["stop"] as? Bool == true { ExtensionDownloads.unheard(id); return nil }
            if spec["now"] as? Bool == true { return ExtensionDownloads.now }
            return await ExtensionDownloads.events(after: spec["after"] as? Int, worker: spec["worker"] as? Bool == true, extension: id, owner: owner)

        // MARK: pageCapture, a tab as MHTML (ExtensionPageCapture)
        case "pageCapture.save":
            guard let index = first as? Int else { throw Unsupported(what: "No tab to save") }
            return try await ExtensionPageCapture.save(tabIndex: index, owner: owner)

        // MARK: proxy, the password its onAuthRequired gives (ExtensionProxy)
        case "proxy.credentials":
            let spec = first as? [String: Any] ?? [:]
            guard let host = spec["host"] as? String, let port = spec["port"] as? Int,
                  let user = spec["username"] as? String, let password = spec["password"] as? String else { return nil }
            ExtensionProxy.credentials(host: host, port: port, username: user, password: password)
            return nil

        // MARK: capture, through Yab's own share (ExtensionCapture)
        case "desktopCapture.choose":
            let spec = first as? [String: Any] ?? [:]
            return await ExtensionCapture.choose(spec["sources"] as? [String] ?? [], tabIndex: spec["tabIndex"] as? Int,
                                                 request: spec["request"] as? Int ?? 0, context: context, owner: owner, browser: browser)
        case "desktopCapture.cancel":
            ExtensionCapture.cancel(first as? Int ?? 0)
            return nil
        case "tabCapture.streamId":
            guard let index = first as? Int else { throw Unsupported(what: "No tab to capture") }
            return try ExtensionCapture.tabStream(tabIndex: index, context: context, owner: owner)

        // MARK: declarativeNetRequest, the extension's own rules where Yab
        // split one WebKit refuses (the shim's `toWebKit`): session ones
        // for this run, dynamic ones kept as WebKit keeps the rules.
        case "dnr.originals":
            let spec = first as? [String: Any] ?? [:]
            let kind = spec["kind"] as? String ?? ""
            let key = "extensions.dnr.originals.\(id).\(kind)"
            let lasting = kind == "updateDynamicRules"
            if let set = spec["set"] as? [String: Any] {
                if lasting { Store.settings.set(set.isEmpty ? nil : set, forKey: key) } else { sessionRules[key] = set.isEmpty ? nil : set }
                return nil
            }
            return (lasting ? Store.settings.dictionary(forKey: key) : sessionRules[key]) ?? [:]
        // A dynamic or session rule's redirect to a data: address, which
        // WebKit refuses: a file of its bytes the rule redirects to instead.
        case "dnr.redirect":
            guard let url = first as? String else { return nil }
            return ExtensionRuleMends.redirectFile(url, in: Extensions.folder(for: id))

        // MARK: side panel
        case "sidePanel.setOptions":
            let options = first as? [String: Any] ?? [:]
            let tabID = options["tabId"] as? Int
            if options["tabId"] != nil && (tabID == nil || tabID! < 0) {
                throw Unsupported(what: "Invalid side panel tabId")
            }
            if let path = options["path"] as? String {
                guard offscreenURL(path, base: context.baseURL) != nil else {
                    throw Unsupported(what: "Side panel path must be in its extension")
                }
                if let tabID { panelTabPath[id, default: [:]][tabID] = path }
                else { panelPath[id] = path }
            }
            if let enabled = options["enabled"] as? Bool {
                if let tabID { panelTabEnabled[id, default: [:]][tabID] = enabled }
                else { panelEnabled[id] = enabled }
                if !enabled { owner.closePanels(id, tabID: tabID) }
            }
            owner.panelOptionsChanged()
            return nil
        case "sidePanel.getOptions":
            let tabID = (first as? [String: Any])?["tabId"] as? Int
            return ["enabled": panelIsEnabled(id, tabID: tabID),
                    "path": pathForPanel(context, tabID: tabID) ?? ""]
        case "sidePanel.getLayout":
            return ["side": (BrowserWindows.shared.activeBrowser ?? browser).chatLeads ? "left" : "right"]
        case "sidePanel.setPanelBehavior":
            if let on = (first as? [String: Any])?["openPanelOnActionClick"] as? Bool {
                if on { panelOnClick.insert(id) } else { panelOnClick.remove(id) }
            }
            return nil
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": panelOnClick.contains(id)]
        case "sidePanel.open":
            let tabID = (first as? [String: Any])?["tabId"] as? Int
            guard panelIsEnabled(id, tabID: tabID) else { throw Unsupported(what: "Side panel is disabled") }
            openPanel(context, owner: owner, tabID: tabID)
            return nil

        // MARK: offscreen, a page with a DOM for a worker that has none
        case "offscreen.createDocument":
            FeedbackDiagnostics.shared.record(.offscreenStarted, extensionID: id)
            var ready = false
            defer { if !ready { FeedbackDiagnostics.shared.record(.offscreenFailed, extensionID: id) } }
            guard offscreen[id] == nil else { throw Unsupported(what: "Only a single offscreen document may be created.") }
            guard let path = (first as? [String: Any])?["url"] as? String,
                  let configuration = context.webViewConfiguration,
                  let controller = context.webExtensionController
            else { throw Unsupported(what: "No page for the offscreen document") }
            guard let url = offscreenURL(path, base: context.baseURL) else {
                throw Unsupported(what: "The offscreen document must belong to this extension")
            }
            // An extension that may capture gets Yab's share in it, on a
            // copy: the configuration is every one of its pages'.
            let armed = (configuration.copy() as? WKWebViewConfiguration) ?? configuration
            let relay = ExtensionCapture.arm(armed, for: context)
            // Sound plays there with no click, as in Chrome, where an
            // offscreen document is made to play it (AUDIO_PLAYBACK, and
            // a recorder's or Volume Master's playback of what it hears):
            // nobody can click a page no one sees.
            armed.mediaTypesRequiringUserActionForPlayback = []
            let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: armed)
            page.navigationDelegate = offscreenWatch
            relay?.page = page
            // A recorder's page hears and plays sound: WebKit starts no
            // media, an AudioContext included, in a page in no window.
            if relay != nil { ExtensionCapture.seat(page) }
            page.load(URLRequest(url: url))
            offscreen[id] = page
            func checkPage() throws {
                guard offscreen[id] === page, context.webExtensionController === controller else {
                    throw Unsupported(what: "The offscreen document was closed")
                }
            }
            // Answered once the page has loaded, as Chrome does: the worker's
            // next line is a message to it, and a page still loading has no
            // one listening yet. Chrome sets no deadline; this one is long:
            // Rabby's page, with its hardware wallets' frames to load, now
            // and then took more than the five seconds this was, and its
            // worker took the refusal as an uncaught error.
            do {
                for _ in 0..<1500 {
                    try Task.checkCancellation()
                    try checkPage()
                    var complete = false
                    if !page.isLoading, page.url == url {
                        complete = (try? await page.evaluateJavaScript("document.readyState === 'complete'")) as? Bool == true
                    }
                    try checkPage()
                    if complete {
                        ready = true
                        FeedbackDiagnostics.shared.record(.offscreenReady, extensionID: id)
                        return nil
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try checkPage()
                let state = (try? await page.evaluateJavaScript("document.readyState")) as? String ?? "?"
                try checkPage()
                throw Unsupported(what: "The offscreen document could not load (\(page.isLoading ? "loading" : "loaded"), \(state)\(page.url == url ? "" : ", elsewhere"))")
            } catch {
                page.stopLoading()
                if offscreen[id] === page { offscreen[id] = nil }
                throw error
            }
        case "offscreen.closeDocument":
            if let controller = context.webExtensionController { closeOffscreen(id, in: controller) }
            return nil
        case "offscreen.hasDocument":
            return offscreen[id] != nil

        // MARK: fonts, what the Mac has; the page's own fonts stay the page's
        case "fontSettings.getFontList":
            return NSFontManager.shared.availableFontFamilies.map { ["fontId": $0, "displayName": $0] }
        case "fontSettings.getFont":
            return ["fontId": "", "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFontSize":
            return ["pixelSize": 16, "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFixedFontSize":
            return ["pixelSize": 13, "levelOfControl": "not_controllable"]
        case "fontSettings.getMinimumFontSize":
            return ["pixelSize": 0, "levelOfControl": "not_controllable"]
        case _ where api.hasPrefix("fontSettings.set") || api.hasPrefix("fontSettings.clear"):
            return nil

        // MARK: management, only itself
        case "management.getSelf", "management.get":
            let found = context.webExtension
            return ["id": id, "name": found.displayName ?? "", "shortName": found.displayShortName ?? "",
                    "version": found.version ?? "", "description": found.displayDescription ?? "",
                    "enabled": true, "type": "extension", "installType": (owner.installed.first(where: { $0.id == id })?.source != nil || id.hasPrefix("local-")) ? "development" : "normal",
                    "mayDisable": true, "offlineEnabled": true, "isApp": false, "hostPermissions": [], "permissions": []]
        case "management.getAll":
            return []
        case "management.setEnabled", "management.uninstallSelf":
            throw Unsupported(what: "Extensions are turned on and off in Settings › Extensions")

        // MARK: developer tools
        case "devtools.openResource":
            // An extension's DevTools panel asking to show a file at a line
            // (React's "view source"): in the card's Sources, on the page
            // the card is looking at. Chrome counts lines and columns from 0.
            let number = { (index: Int) in (args.count > index ? args[index] as? NSNumber : nil)?.intValue ?? 0 }
            guard let url = first as? String, let place = DevPlace("\(url):\(number(1) + 1):\(number(2) + 1)") else {
                throw Unsupported(what: "No file to show")
            }
            guard let front = owner.front, front.inspected != nil else { throw Unsupported(what: "Developer Tools aren't open") }
            front.revealSource(place)
            return nil

        // MARK: language
        case "i18n.detectLanguage":
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(first as? String ?? "")
            let guesses = recognizer.languageHypotheses(withMaximum: 3)
            return ["isReliable": (guesses.values.max() ?? 0) > 0.6,
                    "languages": guesses.sorted { $0.value > $1.value }.map { ["language": $0.key.rawValue, "percentage": Int($0.value * 100)] }]
        case "runtime.getContexts":
            // The extension's own pages that Chrome would list: its worker,
            // its popup while it is up, its side panels, its offscreen document. Bitwarden
            // asks for these to know where to send its messages.
            let filter = first as? [String: Any] ?? [:]
            let types = filter["contextTypes"] as? [String]
            let urls = filter["documentUrls"] as? [String]
            var found: [[String: Any]] = []
            func add(_ type: String, _ url: URL?) {
                guard types == nil || types!.contains(type) else { return }
                let address = url?.absoluteString ?? ""
                guard urls == nil || urls!.contains(address) else { return }
                found.append([
                    "contextType": type, "contextId": "\(id)-\(type)", "tabId": -1, "windowId": -1,
                    "frameId": type == "BACKGROUND" ? -1 : 0, "documentUrl": address,
                    "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "",
                    "incognito": false,
                ])
            }
            if context.webExtension.hasBackgroundContent {
                let manifest = context.webExtension.manifest["background"] as? [String: Any] ?? [:]
                let script = manifest["service_worker"] as? String ?? manifest["page"] as? String
                add("BACKGROUND", script.map { context.baseURL.appendingPathComponent($0) })
            }
            if ExtensionPopup.shared.extensionID == id { add("POPUP", ExtensionPopup.shared.view?.url) }
            for page in owner.panelContexts(id) {
                let url = page.web.url
                guard types == nil || types!.contains("SIDE_PANEL"),
                      urls == nil || urls!.contains(url?.absoluteString ?? "") else { continue }
                found.append([
                    "contextType": "SIDE_PANEL", "contextId": page.contextID,
                    "tabId": page.targetTabID ?? -1, "windowId": -1, "frameId": 0,
                    "documentUrl": url?.absoluteString ?? "",
                    "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "",
                    "incognito": false,
                ])
            }
            if let page = offscreen[id] { add("OFFSCREEN_DOCUMENT", page.url) }
            return found

        // MARK: notifications, the Mac's own
        case "notifications.create":
            let named = first as? String
            let options = (named == nil ? first : (args.count > 1 ? args[1] : nil)) as? [String: Any] ?? [:]
            let key = named ?? UUID().uuidString
            let center = UNUserNotificationCenter.current()
            // Never asked for here: shown only where macOS lets Yab say
            // things already (Settings › AI › Agents offers Allow…).
            guard await MailNotifySystem().permission() == .allowed else { return key }
            let content = UNMutableNotificationContent()
            content.title = options["title"] as? String ?? (context.webExtension.displayName ?? "")
            content.body = options["message"] as? String ?? ""
            content.subtitle = context.webExtension.displayName ?? ""
            try? await center.add(UNNotificationRequest(identifier: "\(id).\(key)", content: content, trigger: nil))
            return key
        case "notifications.clear":
            if let key = first as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(id).\(key)"])
            }
            return true
        case "notifications.getAll":
            return [String: Any]()
        case "notifications.getPermissionLevel":
            return await MailNotifySystem().permission() == .allowed ? "granted" : "denied"
        case "notifications.update":
            return false

        // MARK: clipboard
        // Words its content script or its page in a site's frame copied
        // after the click's moment, which WebKit refuses there and Chrome
        // allows an extension that asked (extension-shims.js, "Copying in
        // a website's tab"; register 1019).
        case "clipboard.write":
            guard context.hasPermission(.clipboardWrite) else {
                throw Unsupported(what: "The extension never asked for \u{201C}clipboardWrite\u{201D}")
            }
            guard let text = first as? String else { throw Unsupported(what: "clipboard.write needs the words") }
            let board = NSPasteboard.general
            board.clearContents()
            return board.setString(text, forType: .string)

        // MARK: speech
        case "tts.speak":
            let options = (args.count > 1 ? args[1] : nil) as? [String: Any] ?? [:]
            if !(options["enqueue"] as? Bool ?? false) { speaker.stopSpeaking() }
            if let voice = options["voiceName"] as? String,
               let match = NSSpeechSynthesizer.availableVoices.first(where: { NSSpeechSynthesizer.attributes(forVoice: $0)[.name] as? String == voice }) {
                speaker.setVoice(match)
            }
            if let rate = options["rate"] as? Double { speaker.rate = Float(180 * rate) }
            speaker.startSpeaking(first as? String ?? "")
            return nil
        case "tts.stop":
            speaker.stopSpeaking()
            return nil
        case "tts.pause":
            speaker.pauseSpeaking(at: .immediateBoundary)
            return nil
        case "tts.resume":
            speaker.continueSpeaking()
            return nil
        case "tts.isSpeaking":
            return speaker.isSpeaking
        case "tts.getVoices":
            return NSSpeechSynthesizer.availableVoices.map { voice -> [String: Any] in
                let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
                return ["voiceName": attributes[.name] as? String ?? voice.rawValue,
                        "lang": (attributes[.localeIdentifier] as? String ?? "").replacingOccurrences(of: "_", with: "-"),
                        "remote": false, "eventTypes": ["start", "end"]]
            }

        // MARK: the worker, up before a page talks to it
        // A test run's word that a worker started (the timeline of
        // evals/extensions/onepassword_profile.py).
        case "background.started":
            owner.trace(id, "worker started")
            return nil
        case "background.wake":
            guard context.webExtension.hasBackgroundContent else { return nil }
            owner.trace(id, "a page woke the worker")
            // WebKit sometimes fails to start a worker again after unloading
            // it, and then never tries again: every message waits for ever.
            // Tried twice more, then the extension is taken up afresh.
            for attempt in 0..<3 {
                // WebKit never calls back after some failed starts; eight
                // seconds without an answer counts as a failure.
                let error: Error? = await withCheckedContinuation { done in
                    var finished = false
                    let finish: (Error?) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        done.resume(returning: result)
                    }
                    context.loadBackgroundContent { error in MainActor.assumeIsolated { finish(error) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(Unsupported(what: "no answer from WebKit")) }
                }
                guard error != nil else { return nil }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
            }
            owner.revive(id, because: "its worker wouldn't start")
            return nil
        // Whether this extension was loaded before in this run of the
        // browser ("reload"), or installed before it started ("launch"):
        // an "install" then is no install (see the shim).
        // Its own runtime.reload(): done, unless it keeps reloading itself.
        case "runtime.mayReload":
            guard owner.contexts[id] === context else { return false }
            let allowed = owner.mayReload(id)
            if allowed { clearMenus(id) }
            return allowed
        // A generation prevents an old worker's delayed write from putting
        // definitions back after an update or reload cleared them.
        case "menus.save":
            guard owner.contexts[id] === context,
                  args.count > 1, let generation = args[1] as? String,
                  generation == menuGenerations[id], let text = first as? String else { return nil }
            Store.settings.set(ExtensionMenuStore.encode(text, version: context.webExtension.version ?? ""),
                               forKey: "extensions.menus.\(id)")
            return nil
        case "menus.load":
            guard owner.contexts[id] === context else { return nil }
            if menuGenerations[id] == nil { menuGenerations[id] = UUID().uuidString }
            let key = "extensions.menus.\(id)"
            let saved = Store.settings.string(forKey: key)
                .flatMap { ExtensionMenuStore.decode($0, version: context.webExtension.version ?? "") }
            if saved == nil { Store.settings.removeObject(forKey: key) }
            return ["items": saved ?? "[]", "generation": menuGenerations[id]!]
        case "background.loadedBefore":
            // "quiet": started on its first use after a launch that left it
            // asleep (ExtensionLaunch): Chrome would have told it nothing.
            if owner.startedLate(id) { return "quiet" }
            return owner.startedBefore(id) ?? false
        // What the worker listens for, its own listeners, and the events it
        // was woken for with none (see the shim's stand-ins).
        case "background.listeners":
            owner.heard(id, events: (first as? [String]) ?? [], idle: (args.count > 1 ? args[1] : nil) as? [String: Int] ?? [:])
            return nil
        // A page found the worker gone though WebKit believes it runs (see
        // the shim's ping).
        case "background.revive":
            owner.revive(id, because: "its worker stopped answering")
            return nil

        // MARK: what went wrong inside
        case "debug.error":
            // Its own code's, but for a rule or user script WebKit refused,
            // which is Yab's to answer for.
            let text = first as? String ?? "?"
            owner.noteError(text, for: id, own: !text.hasPrefix("declarativeNetRequest:") && !text.hasPrefix("userScripts:"))
            return nil

        // MARK: rules that match every address (ExtensionRuleBudget)
        // What WebKit takes and each rule set's count, for the shim to
        // keep the enabled sets, dynamic and session rules under it.
        case "dnr.budget":
            let folder = Extensions.folder(for: id)
            return ["limit": ExtensionRuleBudget.limit, "sets": ExtensionRuleBudget.counts(in: folder)]
        // Sets the shim kept off ([ids]), and ones the extension itself
        // turned off since ([ids]): the row says how many are off.
        case "dnr.leftOff":
            let add = (first as? [String]) ?? []
            let remove = Set((args.count > 1 ? args[1] : nil) as? [String] ?? [])
            owner.rulesLeftOff(id, adding: add, removing: remove)
            return nil

        // MARK: the button's popup
        case "action.popup":
            let path = first as? String ?? ""
            let index = args.dropFirst().first as? Int ?? -1
            if index >= 0, owner.visibleTabs.indices.contains(index) {
                owner.popupPaths[id, default: [:]][owner.visibleTabs[index].id.uuidString] = path
            } else {
                owner.popupPaths[id, default: [:]]["*"] = path
                owner.popupPaths[id] = owner.popupPaths[id]?.filter { $0.key == "*" }
            }
            // The stand-in WebKit is told of next (mendPopup), there before it is.
            let page = (URL(string: path, relativeTo: context.baseURL)?.absoluteURL).flatMap { $0.host == context.baseURL.host ? $0.path : nil }
            if let page, !page.isEmpty, page != "/", !page.contains(actionStandIn) {
                let folder = Extensions.folder(for: id)
                if let source = inside(page, of: folder) {
                    let target = folder.appendingPathComponent(standIn(page).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                    if target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                       !FileManager.default.fileExists(atPath: target.path) {
                        try? FileManager.default.copyItem(at: source, to: target)
                    }
                }
            }
            return nil

        // A press its worker held while starting, for a listener that
        // never came: the extension chose a popup, which opens (the
        // shim's holdClicks).
        case "action.pressHeld":
            owner.pressHeld(id)
            return nil

        // MARK: registered content scripts, for the spare (ContentWarm)
        case "scripting.registered":
            ContentWarm.registered(first as? [[String: Any]] ?? [], for: id)
            return nil

        // MARK: user scripts
        case "userScripts.file":
            return try userScriptFile(first as? [String: Any] ?? [:], in: Extensions.folder(for: id))
        case "userScripts.list":
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: Extensions.folder(for: id).appendingPathComponent("_yab/userscripts.json")))) ?? []
        case "userScripts.save":
            let folder = Extensions.folder(for: id).appendingPathComponent("_yab", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scripts = first as? [[String: Any]] ?? []
            try JSONSerialization.data(withJSONObject: scripts).write(to: folder.appendingPathComponent("userscripts.json"), options: .atomic)
            // Files no saved script is written in any more, once a moment
            // has passed, one being injected right now is left alone.
            let keep = Set(scripts.compactMap { try? userScriptFile($0, in: Extensions.folder(for: id)) })
            // Those of before, in _yab/, all go: none is injected from there now.
            let files = { (dir: URL) in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            for file in files(folder).filter({ $0.lastPathComponent.hasPrefix("us-") })
                + files(folder.deletingLastPathComponent()).filter({ $0.lastPathComponent.hasPrefix(userScriptPrefix) && !keep.contains($0.lastPathComponent) }) {
                let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 999
                if age > 60 { try? FileManager.default.removeItem(at: file) }
            }
            return nil
        case "userScripts.world", "userScripts.worlds":
            let url = Extensions.folder(for: id).appendingPathComponent("_yab/worlds.json")
            var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            if api == "userScripts.worlds" { return worlds }
            let props = first as? [String: Any] ?? [:]
            let world = props["worldId"] as? String ?? ""
            worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
            if props["reset"] as? Bool != true { worlds.append(props) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: worlds).write(to: url, options: .atomic)
            return nil

        // MARK: permissions yab grants itself
        case "permissions.granted":
            return Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
        case "permissions.ask":
            // One permissions.request, one card, as in Chrome: the sites it
            // doesn't hold, yab's own permissions it lacks, and WebKit's.
            // Figma asks for every site with pageCapture, scripting and
            // clipboardWrite, and got two cards in a row, one saying only
            // "pageCapture". WebKit's are given here too: its own request
            // asked again in a card of its own, and outside a click's moment
            // it throws where Chrome carries the click with a message
            // (NordPass's copy button, register 1019).
            let strings = { (index: Int) -> [String] in args.indices.contains(index) ? args[index] as? [String] ?? [] : [] }
            let sites = strings(0).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
            let ours = strings(1)
            let theirs = strings(2).map { WKWebExtension.Permission(rawValue: $0) }
            // As in Chrome: only what the manifest named, from the start or
            // for later. What was agreed to at install still describes the
            // extension; it can't ask later for something it never named.
            let manifest = context.webExtension.manifest
            let named = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
            let patterns = context.webExtension.allRequestedMatchPatterns.union(context.webExtension.optionalPermissionMatchPatterns)
            let webKit = context.webExtension.optionalPermissions.union(context.webExtension.requestedPermissions)
            guard ours.allSatisfy(named.contains), theirs.allSatisfy(webKit.contains),
                  sites.allSatisfy({ site in patterns.contains { $0.matches(site) } }) else {
                throw Unsupported(what: "Only permissions specified in the manifest may be requested.")
            }
            let missing = theirs.filter { !context.hasPermission($0) }.map(\.rawValue)
            let wanted = ours + missing
            guard !sites.isEmpty || !wanted.isEmpty else { return true }
            // Unticked when it was added, back when a box left unticked kept
            // it from the extension: kept from it without asking again.
            let choices = Extensions.choices(id)
            guard !(sites.map(\.string) + wanted).contains(where: { choices[$0] == false }) else { return false }
            let picks = Dictionary(sites.map { ($0.string, true) }, uniquingKeysWith: { a, _ in a })
            guard owner.admits(choices: picks, for: id) else { return false }
            if !sites.isEmpty || !wanted.allSatisfy(Extensions.quiet.contains) {
                guard await owner.ask(wants: Extensions.wants(sites: sites, permissions: wanted), context: context) else { return false }
                // Again, before anything is given: the room may have gone while the card waited.
                guard owner.admits(choices: picks, for: id) else { return false }
            }
            if !ours.isEmpty {
                let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
                Store.settings.set(Array(Set(had + ours)).sorted(), forKey: "extensions.granted.\(id)")
            }
            // Kept, so they are still given after a relaunch, as in Chrome.
            for permission in missing { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission)) }
            Extensions.choose(Dictionary(missing.map { ($0, true) }, uniquingKeysWith: { a, _ in a }), for: id)
            if !sites.isEmpty { owner.give(sites: sites, to: context) }
            return true
        case "permissions.remove":
            let gone = Set((first as? [String]) ?? [])
            let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
            Store.settings.set(had.filter { !gone.contains($0) }, forKey: "extensions.granted.\(id)")
            return true

        // MARK: favicon, chrome-extension://<id>/_favicon/ (ExtensionFavicon)
        case "favicon.get":
            let page = (first as? String).flatMap { URL(string: $0) }
            return ExtensionFavicon.dataURL(for: page, size: (args.dropFirst().first as? NSNumber)?.intValue ?? 16)

        // MARK: tabs, by where they are in the window
        case "tabs.describe":
            let visible = owner.visibleTabs
            return ((first as? [Int]) ?? []).map { index -> Any in
                guard visible.indices.contains(index) else { return NSNull() }
                return ["url": visible[index].address?.absoluteString ?? "", "title": visible[index].title]
            }
        case "tabs.move", "tabs.discard", "tabs.activate":
            let visible = owner.visibleTabs
            guard let from = first as? Int, visible.indices.contains(from) else { throw Unsupported(what: "No tab there") }
            let tab = visible[from]
            switch api {
            case "tabs.move":
                let wanted = args.dropFirst().first as? Int ?? -1
                let target = visible[wanted < 0 || wanted >= visible.count ? visible.count - 1 : wanted]
                if let index = browser.tabs.firstIndex(where: { $0.id == target.id }) { browser.move(tab, to: index) }
            case "tabs.discard":
                if tab.id != browser.activeID { browser.sleep(tab) }
            default:
                // A tab of another space: that space first (ExtensionTab.activate).
                if !browser.tabs.contains(where: { $0.id == tab.id }), let space = browser.spaceHolding(tab.id) {
                    browser.switchSpace(to: space)
                }
                browser.select(tab)
            }
            return nil

        // MARK: search
        case "search.query":
            let spec = first as? [String: Any] ?? [:]
            guard let url = Engine.destination(for: spec["text"] as? String ?? "") else { return nil }
            switch spec["disposition"] as? String {
            case "NEW_TAB", "NEW_WINDOW": browser.open(url, foreground: true)
            default: browser.visit(url)
            }
            return nil

        // MARK: idle
        case "idle.queryState":
            let threshold = (first as? Double) ?? 60
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
               session["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
            let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            return quiet >= threshold ? "idle" : "active"
        case "idle.getAutoLockDelay":
            return 0

        // MARK: power
        case "power.requestKeepAwake":
            let display = (first as? String) == "display"
            if let old = awake[id] { IOPMAssertionRelease(old) }
            var assertion: IOPMAssertionID = 0
            let kind = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            if IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn), "An extension in Yab" as CFString, &assertion) == kIOReturnSuccess {
                awake[id] = assertion
                releaseOnQuit()
            }
            return nil
        case "power.releaseKeepAwake":
            if let old = awake.removeValue(forKey: id) { IOPMAssertionRelease(old) }
            return nil
        case "power.reportActivity":
            // One per extension, declared again each time: a known id
            // updates the assertion in place instead of adding one.
            var assertion = active[id] ?? 0
            if IOPMAssertionDeclareUserActivity("An extension in Yab" as CFString, kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess {
                active[id] = assertion
                releaseOnQuit()
            }
            return nil

        // MARK: browsing data
        case "browsingData.settings":
            return ["options": ["since": 0], "dataToRemove": [:], "dataRemovalPermitted": [
                "cache": true, "cookies": true, "history": true, "downloads": true, "localStorage": true,
                "indexedDB": true, "serviceWorkers": true, "cacheStorage": true, "fileSystems": true, "webSQL": true,
            ]]
        case let api where api.hasPrefix("browsingData."):
            let options = first as? [String: Any] ?? [:]
            let what: [String: Bool]
            if api == "browsingData.remove" {
                what = (args.dropFirst().first as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
            } else {
                let key = String(api.dropFirst("browsingData.remove".count))
                what = [key.prefix(1).lowercased() + key.dropFirst(): true]
            }
            try await clear(what, options: options, browser: browser)
            return nil

        // MARK: sessions, the tabs you closed
        case "sessions.getRecentlyClosed":
            let limit = (first as? [String: Any])?["maxResults"] as? Int ?? 25
            return browser.ghosts.reversed().prefix(limit).map { ghost in
                ["lastModified": Int(Date().timeIntervalSince1970),
                 "tab": ["sessionId": ghost.id.uuidString, "url": ghost.url.absoluteString, "title": ghost.title,
                         "index": ghost.index, "windowId": 1, "active": false, "pinned": false, "highlighted": false,
                         "incognito": false, "selected": false, "discarded": false, "autoDiscardable": true, "groupId": -1]] as [String: Any]
            }
        case "sessions.getDevices":
            return []
        case "sessions.restore":
            let ghost = (first as? String).flatMap { key in browser.ghosts.first { $0.id.uuidString == key } } ?? browser.ghosts.last
            guard let ghost else { throw Unsupported(what: "Nothing to restore") }
            browser.reopen(ghost)
            return ["lastModified": Int(Date().timeIntervalSince1970),
                    "tab": ["url": ghost.url.absoluteString, "title": ghost.title, "index": ghost.index, "windowId": 1]]

        // MARK: top sites, the most visited in history
        case "topSites.get":
            var visits: [String: (url: URL, title: String, count: Int)] = [:]
            for trace in browser.history.everything() {
                guard let host = trace.url.host() else { continue }
                visits[host, default: (trace.url, trace.title, 0)].count += 1
            }
            return visits.values.sorted { $0.count > $1.count }.prefix(10).map {
                ["url": $0.url.absoluteString, "title": $0.title]
            }

        // MARK: reading list, none kept
        case "readingList.query", "readingList.addEntry", "readingList.removeEntry", "readingList.updateEntry":
            return try ExtensionReadingList.run(api, args)

        // MARK: system
        case "system.cpu.getInfo":
            return ["numOfProcessors": ProcessInfo.processInfo.processorCount, "archName": "arm64",
                    "modelName": "Apple silicon", "features": [], "processors": [], "temperatures": []]
        case "system.memory.getInfo":
            return ["capacity": Double(ProcessInfo.processInfo.physicalMemory), "availableCapacity": Double(ProcessInfo.processInfo.physicalMemory) / 2]
        case "system.storage.getInfo":
            return []
        case "system.display.getInfo":
            return NSScreen.screens.enumerated().map { index, screen in
                let f = screen.frame, v = screen.visibleFrame
                return ["id": String(index), "name": screen.localizedName, "isPrimary": index == 0, "isInternal": index == 0,
                        "isEnabled": true, "dpiX": 96 * screen.backingScaleFactor, "dpiY": 96 * screen.backingScaleFactor,
                        "rotation": 0, "bounds": ["left": f.minX, "top": f.minY, "width": f.width, "height": f.height],
                        "workArea": ["left": v.minX, "top": v.minY, "width": v.width, "height": v.height]] as [String: Any]
            }

        // MARK: tab groups, there are none
        case "tabGroups.query", "tabGroups.get", "tabGroups.update", "tabGroups.move", "tabGroups.group", "tabGroups.ungroup", "tabGroups.membership":
            // The folders are the shared sign-in's row's: a space's own
            // sign-in's extensions see none of them (ExtensionSignIns).
            guard owner.signIn == nil else {
                if api == "tabGroups.query" { return [Any]() }
                throw Unsupported(what: "No group with id.")
            }
            return try ExtensionGroups.shared.run(api, args, context: context)

        // MARK: identity
        case "identity.launchWebAuthFlow":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No authorization url") }
            // Chrome's silent check (interactive: false): the page loads
            // out of sight, and only a redirect that comes by itself is the
            // answer; a page that wants a hand is "interaction required".
            let interactive = spec["interactive"] as? Bool ?? false
            let timeout = (spec["timeoutMsForNonInteractive"] as? Double).map { $0 / 1000 } ?? 60
            return try await ExtensionAuth.run(url, extension: id, browser: browser, interactive: interactive, timeout: timeout).absoluteString
        case "identity.getProfileUserInfo":
            return ["email": "", "id": ""]
        case "identity.removeCachedAuthToken", "identity.clearAllCachedAuthTokens":
            return nil
        case "identity.getAuthToken":
            // Chrome mints this token from the Google account signed into
            // Chrome. Google's own sign-in page won't stand in: it answers
            // an extension's client id with Chrome's chromiumapp.org
            // redirect "redirect_uri_mismatch" before anyone signs in
            // (evals/extensions/identity_probe.py, Save to Google Drive,
            // 2026-10-21), so there is nothing to build it on.
            throw Unsupported(what: "Sign in with Google isn't available for extensions in Yab")

        default:
            throw Unsupported(what: "\(api) isn't available in Yab")
        }
    }

    // MARK: - the side panel

    /// A user script as a file WebKit can inject: its code, inline, or read
    /// from the extension's own files, inside a block that leaves at once
    /// on a page its globs rule out and, for Chrome's USER_SCRIPT world,
    /// gives the code a `chrome` whose messages are marked as a user
    /// script's. Named by what is in it, so a changed script is a new file
    /// and never a stale one WebKit has already read.
    static func userScriptFile(_ script: [String: Any], in folder: URL) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String,
                      // One of the extension's own files, and nothing outside
                      // its folder: a name is resolved before it is read.
                      let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        // A script moved to Yab's own userscripts runs there, not here too.
        if UserscriptMove.movedOut(code) { code = "" }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage({ __yabUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
              connect: (info) => runtime.connect({ ...(info || {}), name: "yab-us:" + ((info && info.name) || "") }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* yab: a user script (chrome.userScripts) */
        yab_user_script: {
          const __yabHref = location.href;
          const __yabGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
          const __yabIn = \#(json(script["includeGlobs"] ?? [])), __yabOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__yabIn.length && !__yabIn.some((g) => __yabGlob(g).test(__yabHref))) || __yabOut.some((g) => __yabGlob(g).test(__yabHref))) break yab_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        // At the extension's root, where Chrome's inline code runs from: a
        // relative import() in it, Surfingkeys' import('./api.js') for its
        // advanced settings, finds the extension's file (feedback #196).
        let name = userScriptPrefix + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return name
    }

    /// The start of every user script file's name, at the extension's root.
    static let userScriptPrefix = "yab-userscript-"

    /// Keep-awake assertions, one per extension that asked.
    static var awake: [String: IOPMAssertionID] = [:]

    /// User-activity assertions from power.reportActivity, one per extension.
    static var active: [String: IOPMAssertionID] = [:]

    /// What an extension holds on the Mac's sleep goes with it, as in
    /// Chrome: turned off, removed, updated or restarted.
    static func releasePower(for id: String) {
        if let old = awake.removeValue(forKey: id) { IOPMAssertionRelease(old) }
        if let old = active.removeValue(forKey: id) { IOPMAssertionRelease(old) }
    }

    private static var quitWatch: NSObjectProtocol?

    private static func releaseOnQuit() {
        guard quitWatch == nil else { return }
        quitWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for id in Set(awake.keys).union(active.keys) { releasePower(for: id) }
            }
        }
    }

    /// chrome.privacy and chrome.proxy: what each extension set, kept across
    /// launches as Chrome keeps it. yab acts on one of them, an
    /// extension turning the browser's own offer to save passwords off,
    /// which is how every password manager asks Chrome to step aside.
    private static func setting(_ api: String, _ details: [String: Any], extension id: String, owner: Extensions) throws -> Any? {
        let parts = api.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1]
        var mine = Extensions.settings(for: id)
        switch parts[0] {
        case "setting.set":
            if name == ExtensionProxy.settingName, let error = ExtensionProxy.settingError(details["value"]) {
                throw Unsupported(what: error)
            }
            mine[name] = details["value"]
        case "setting.clear":
            mine[name] = nil
        default:
            let value = mine[name] ?? defaultSetting(name, owner: owner)
            return ["value": value ?? NSNull(), "levelOfControl": mine[name] != nil ? "controlled_by_this_extension" : "controllable_by_this_extension"]
        }
        Extensions.setSettings(mine, for: id)
        owner.objectWillChange.send()
        if name == ExtensionProxy.settingName { ExtensionProxy.set(by: id, cleared: parts[0] == "setting.clear") }
        if name == ExtensionProxy.webRTCName { ExtensionProxy.refresh() }
        return nil
    }

    private static func defaultSetting(_ name: String, owner: Extensions) -> Any? {
        switch name {
        case "privacy.services.passwordSavingEnabled": return owner.browser?.prefs.savesPasswords ?? true
        case "privacy.network.webRTCIPHandlingPolicy": return "default"
        // Yab's own anti-phishing list (SafeBrowsing.swift), opt-in.
        case "privacy.services.safeBrowsingEnabled": return SafeBrowsing.on
        case "privacy.websites.doNotTrackEnabled", "privacy.websites.adMeasurementEnabled",
             "privacy.websites.fledgeEnabled", "privacy.websites.topicsEnabled",
             "privacy.services.safeBrowsingExtendedReportingEnabled": return false
        case "proxy.settings": return ["mode": "system"]
        default: return true
        }
    }

    /// chrome.browsingData, from what WebKit and yab keep.
    private static func clear(_ what: [String: Bool], options: [String: Any], browser: Browser) async throws {
        let since = Date(timeIntervalSince1970: (options["since"] as? Double ?? 0) / 1000)
        let origins = (options["origins"] as? [String])?.compactMap { URL(string: $0)?.host() }
        var types = Set<String>()
        let map: [String: [String]] = [
            "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
            "cacheStorage": [WKWebsiteDataTypeFetchCache], "appcache": [WKWebsiteDataTypeOfflineWebApplicationCache],
            "cookies": [WKWebsiteDataTypeCookies], "localStorage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage],
            "indexedDB": [WKWebsiteDataTypeIndexedDBDatabases], "serviceWorkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
            "webSQL": [WKWebsiteDataTypeWebSQLDatabases], "fileSystems": [WKWebsiteDataTypeFileSystem],
        ]
        for (key, on) in what where on { types.formUnion(map[key] ?? []) }
        let store = Store.websites
        if !types.isEmpty {
            if let origins {
                let records = await store.dataRecords(ofTypes: types)
                let hit = records.filter { record in origins.contains { $0 == record.displayName || $0.hasSuffix("." + record.displayName) } }
                await store.removeData(ofTypes: types, for: hit)
            } else {
                await store.removeData(ofTypes: types, modifiedSince: since)
            }
        }
        if what["history"] == true, origins == nil {
            for trace in browser.history.everything() where trace.last >= since { browser.history.forget(trace.key) }
        }
    }

    static func defaultPanel(_ context: WKWebExtensionContext) -> String? {
        (context.webExtension.manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    static func pathForPanel(_ context: WKWebExtensionContext, tabID: Int?) -> String? {
        let id = context.uniqueIdentifier
        if let tabID, let path = panelTabPath[id]?[tabID] { return path }
        return panelPath[id] ?? defaultPanel(context)
    }

    static func panelIsEnabled(_ id: String, tabID: Int?) -> Bool {
        if let tabID, let enabled = panelTabEnabled[id]?[tabID] { return enabled }
        return panelEnabled[id] ?? true
    }

    static func openPanel(_ context: WKWebExtensionContext, owner: Extensions, tabID: Int? = nil) {
        guard let browser = BrowserWindows.shared.activeBrowser ?? owner.browser else { return }
        owner.openPanel(context.uniqueIdentifier, in: browser, tabID: tabID)
    }

    // MARK: - bookmarks, as Chrome shapes them

    private typealias Hit = (node: Bookmark, parent: String, index: Int)

    private static func flat(_ nodes: [Bookmark], parent: String = "1") -> [Hit] {
        nodes.enumerated().flatMap { index, n -> [Hit] in
            [(n, parent, index)] + flat(n.children ?? [], parent: n.id.uuidString)
        }
    }

    private static func find(_ key: String, in nodes: [Bookmark]) -> Hit? {
        flat(nodes).first { $0.node.id.uuidString == key }
    }

    private static func node(_ n: Bookmark, parent: String, index: Int, deep: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": n.id.uuidString, "parentId": parent, "index": index, "title": n.title,
                                  "dateAdded": (n.added?.timeIntervalSince1970 ?? 0) * 1000, "syncing": false]
        if let url = n.url { out["url"] = url }
        if n.isFolder {
            out["dateGroupModified"] = 0
            if deep {
                out["children"] = (n.children ?? []).enumerated().map { node($1, parent: n.id.uuidString, index: $0, deep: true) }
            }
        }
        return out
    }

    private static func bar(_ roots: [Bookmark], deep: Bool = true) -> [String: Any] {
        var out: [String: Any] = ["id": "1", "parentId": "0", "index": 0, "title": "Bookmarks", "dateAdded": 0,
                                  "folderType": "bookmarks-bar", "syncing": false]
        if deep { out["children"] = roots.enumerated().map { node($1, parent: "1", index: $0, deep: true) } }
        return out
    }

    private static func root(_ roots: [Bookmark]) -> [String: Any] {
        ["id": "0", "title": "", "dateAdded": 0, "syncing": false, "children": [bar(roots)]]
    }

    private static func visit(_ trace: History.Trace) -> [String: Any] {
        ["id": trace.key, "url": trace.url.absoluteString, "title": trace.title,
         "lastVisitTime": trace.last.timeIntervalSince1970 * 1000, "visitCount": trace.count, "typedCount": 0]
    }
}

/// chrome.identity.launchWebAuthFlow: a tab for the provider's sign-in, and
/// the moment it tries to go to https://<id>.chromiumapp.org/, that address
/// is the answer and the tab goes. Browser asks `intercept` about every
/// navigation; nothing is ever loaded from chromiumapp.org.
@MainActor
enum ExtensionAuth {
    private static var waiting: [String: (tab: Tab.ID, finish: (Result<URL, Error>) -> Void)] = [:]
    private static var watch: AnyCancellable?

    struct Declined: LocalizedError {
        var errorDescription: String? { "The user did not approve access." }
    }

    struct InteractionRequired: LocalizedError {
        var errorDescription: String? { "User interaction required." }
    }

    /// `interactive`: Chrome opens the page for the user; otherwise it loads
    /// it out of sight and takes only a redirect that comes by itself,
    /// within `timeout` (timeoutMsForNonInteractive), failing with
    /// "interaction required" past it. Claude for Chrome asks silently first
    /// (prompt=none, 15 s), then with the user if that fails.
    static func run(_ url: URL, extension id: String, browser: Browser, interactive: Bool = true, timeout: TimeInterval = 60) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            waiting[id]?.finish(.failure(Declined()))
            let tab = interactive ? browser.open(url, foreground: true) : browser.benchOpen(url)
            waiting[id] = (tab.id, { result in continuation.resume(with: result) })
            // Closing the tab is saying no.
            watch = browser.changes(\.tabs).sink { tabs in
                for (key, entry) in waiting where !tabs.contains(where: { $0.id == entry.tab }) {
                    waiting[key] = nil
                    entry.finish(.failure(Declined()))
                }
            }
            if !interactive {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak tab] in
                    guard let entry = waiting[id], let tab, entry.tab == tab.id else { return }
                    waiting[id] = nil
                    entry.finish(.failure(InteractionRequired()))
                    browser.close(tab)
                }
            }
        }
    }

    /// The extension an OAuth redirect address belongs to: Chrome's
    /// https://<id>.chromiumapp.org/..., which getRedirectURL gives, or the
    /// extension's own chrome-extension://<id>/... page, which Claude for
    /// Chrome names as its redirect_uri (oauth_callback.html).
    static func flowExtension(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        switch url.scheme?.lowercased() {
        case "https" where host.hasSuffix(".chromiumapp.org"): return String(host.dropLast(".chromiumapp.org".count))
        // The extension's own page as the redirect (Claude for Chrome's
        // oauth_callback.html): handed over only to a flow the extension
        // started through launchWebAuthFlow; a sign-in it opened as a tab
        // of its own (tabs.create) loads that page and reads the code
        // itself, as in Chrome.
        case Extensions.scheme, Extensions.formerScheme: return waiting[host] != nil ? host : nil
        default: return nil
        }
    }

    /// An installed extension's https://<id>.chromiumapp.org/ address with
    /// no launchWebAuthFlow waiting for it: a sign-in the extension opened
    /// as a tab of its own (tabs.create), as Figma's does (feedback #348).
    /// In Chrome the tab goes there, nothing answers, and the extension,
    /// watching the tab's address (tabs.onUpdated), takes the code from it
    /// and closes the tab. Here a page's script going there failed with the
    /// tab put back on the page before, and the extension never saw it:
    /// Browser's `fail` has the tab say this address (Tab.stand).
    static func ownTabRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        // Any sign-in's: one installed in a space with its own sign-ins
        // too, whose extensions aren't the shared ones.
        return waiting[id] == nil && Extensions.all.contains { $0.contexts[id] != nil }
    }

    /// True when the address is an extension's OAuth redirect, which is then
    /// handed over and never loaded.
    ///
    /// Any page can go to an address shaped like one of these, and what it
    /// carries would be delivered as the flow's answer: only the tab the
    /// flow was started in may finish it, or a window that tab's page
    /// opened, since some providers finish the sign-in in a popup.
    static func intercept(_ url: URL, browser: Browser, from page: any PageHandle) -> Bool {
        guard let id = flowExtension(of: url) else { return false }
        guard let entry = waiting[id], let from = browser.tab(owning: page),
              from.id == entry.tab || from.opener == entry.tab
        else { return false }
        waiting.removeValue(forKey: id)
        entry.finish(.success(url))
        // The popup, when the answer came in one, goes with the flow's tab:
        // left behind, it would hold a redirect that never loads.
        if from.id != entry.tab { browser.close(from) }
        if let tab = browser.tabs.first(where: { $0.id == entry.tab }) { browser.close(tab) }
        return true
    }
}
