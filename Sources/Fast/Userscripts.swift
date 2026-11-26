import AppKit
import UniformTypeIdentifiers
import WebKit

/// Userscripts Yab reads and keeps itself (docs/userscripts.md): a
/// `.user.js` opened in a tab is a Keep card over the page, not text and
/// not Tampermonkey's install page; a kept one runs in a content world of
/// its own with a GM API answered here, sits in Site Controls' Boosts
/// with its menu commands, and takes updates quietly unless they ask for
/// more, which waits for Update in its row.
@MainActor
final class Userscripts: ObservableObject {
    static let shared = Userscripts()

    struct Record: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var version: String
        var enabled: Bool
        var profiles: AddonProfiles? = nil
        /// Where it was installed from, and where updates are looked for.
        var source: String?
        var installed: Date
        var updated: Date
        /// The script and its pinned files, hashed: a new one is a new version.
        var revision: String
        var checked: Date?
        /// A newer version that asks for more, waiting for Update.
        var pending: Pending?
        /// Moved from Tampermonkey (or a backup): said in Settings once.
        var moved: String?
    }
    struct Pending: Codable, Equatable {
        var version: String
        var rights: [String]
        var revision: String
    }
    /// A `.user.js` read, shown on its card in a tab: tried in that tab
    /// only, or not yet.
    struct Offer: Identifiable {
        let id = UUID()
        let tabID: UUID
        let url: URL
        var script: Userscript
        var facts: String?
        var tried = false
        /// Its @require and @resource files are fetched and pinned.
        var ready = false
        var problem: String?
        /// The kept one's version, when this replaces it.
        var replaces: String?
    }
    /// A menu command a page registered, while that page is open.
    struct Command: Identifiable, Equatable {
        let id: String
        let caption: String
    }

    @Published private(set) var records: [Record] = []
    @Published private(set) var offers: [UUID: Offer] = [:]
    /// By tab, by script: what the page registered with GM_registerMenuCommand.
    @Published private(set) var commands: [UUID: [String: [Command]]] = [:]
    @Published private(set) var trouble: String?
    /// Scripts' uncaught errors, newest last, for the bench and Fix.
    private(set) var errors: [String: [String]] = [:]
    /// Requests refused for going to a host not on the card.
    private(set) var refused: [String: [String]] = [:]
    private(set) var scripts: [String: Userscript] = [:]
    let root: URL
    /// Addresses let through to load as they are, once (Use Tampermonkey).
    private var passing: Set<URL> = []
    /// One per launch: the page world's handler is reachable by the page,
    /// so its calls carry this.
    private let token = UUID().uuidString
    private var made: [String: (key: String, script: WKUserScript)] = [:]
    private var everMade: Set<ObjectIdentifier> = []
    private var everMadeScripts: [WKUserScript] = []
    private var handlers = NSMapTable<WKUserContentController, NSMutableSet>.weakToStrongObjects()
    private var values: [String: [String: Any]] = [:]
    private var valueTurns: [String: Int] = [:]
    private var notices: [String: Date] = [:]

    init(root: URL = Store.file("userscripts")) {
        self.root = root
        reload()
        Task { [weak self] in await self?.watchUpdates() }
    }

    // MARK: - the library

    private var index: URL { root.appendingPathComponent("index.json") }
    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func reload() {
        trouble = nil
        guard let data = try? Data(contentsOf: index) else { records = []; scripts = [:]; return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { records = try decoder.decode([Record].self, from: data) }
        catch { trouble = error.localizedDescription; return }
        var read: [String: Userscript] = [:]
        for record in records {
            if let script = try? load(folder(record.id)) { read[record.id] = script }
        }
        scripts = read
        do { try migrateProfiles() } catch { trouble = error.localizedDescription }
    }

    private func migrateProfiles() throws {
        guard records.contains(where: { $0.profiles == nil }) else { return }
        var changed = records
        for at in changed.indices where changed[at].profiles == nil {
            let profiles = AddonProfiles(legacy: changed[at].enabled, signIns: AddonProfiles.existing)
            // Preserve what scripts already kept in every existing profile.
            let old = valuesFile(changed[at].id, in: nil)
            if FileManager.default.fileExists(atPath: old.path) {
                for key in profiles.enabled.keys where key != AddonProfiles.key(nil) {
                    let file = valuesFile(changed[at].id, in: UUID(uuidString: key))
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: old, to: file)
                    }
                }
            }
            changed[at].profiles = profiles
        }
        try save(changed)
    }

    func records(in signIn: UUID?) -> [Record] {
        records.compactMap { record in
            guard record.profiles?.contains(signIn) ?? true else { return nil }
            var local = record
            local.enabled = record.enabled && (record.profiles?.isEnabled(in: signIn) ?? true)
            return local
        }
    }
    func isEnabled(_ id: String, in signIn: UUID?) -> Bool {
        records(in: signIn).contains { $0.id == id && $0.enabled }
    }

    private func save(_ changed: [Record]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(changed).write(to: index, options: .atomic)
        records = changed
    }

    /// A script folder: the file as fetched, and its pinned files by hash.
    private func load(_ folder: URL) throws -> Userscript {
        var script = try Userscript.read(String(contentsOf: folder.appendingPathComponent("script.user.js"), encoding: .utf8))
        if let data = try? Data(contentsOf: folder.appendingPathComponent("files.json")),
           let files = try? JSONDecoder().decode([Userscript.File].self, from: data) {
            for var file in files {
                file.text = (try? String(contentsOf: folder.appendingPathComponent("files/" + file.sha256), encoding: .utf8)) ?? ""
                if file.name.isEmpty { script.requires.append(file) } else { script.resources.append(file) }
            }
        }
        return script
    }

    private func write(_ script: Userscript, to folder: URL) throws {
        let files = folder.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try script.source.write(to: folder.appendingPathComponent("script.user.js"), atomically: true, encoding: .utf8)
        for file in script.requires + script.resources {
            try file.text.write(to: files.appendingPathComponent(file.sha256), atomically: true, encoding: .utf8)
        }
        let listed = (script.requires + script.resources).map { file -> Userscript.File in var bare = file; bare.text = ""; return bare }
        try JSONEncoder().encode(listed).write(to: folder.appendingPathComponent("files.json"), options: .atomic)
        // What it is, in words, beside the code: where it came from and
        // what was pinned, as a boost's BOOST.md says its request.
        var about = "---\nname: \(script.name)\nversion: \(script.version)\n"
        for file in script.requires + script.resources { about += "pinned: \(file.url) sha256:\(file.sha256)\n" }
        about += "---\n\n" + (script.summary.isEmpty ? script.name : script.summary) + "\n"
        try about.write(to: folder.appendingPathComponent("BOOST.md"), atomically: true, encoding: .utf8)
    }

    static func revision(_ script: Userscript) -> String {
        Userscript.sha256(Data((script.source + (script.requires + script.resources).map(\.sha256).joined()).utf8))
    }

    func record(_ id: String) -> Record? { records.first { $0.id == id } }
    func on(_ url: URL?, in signIn: UUID? = nil) -> [Record] {
        guard let url else { return [] }
        return records(in: signIn).filter { scripts[$0.id]?.matches(url) == true }
    }
    var tampermonkey: Installed? { tampermonkey(in: nil) }
    func tampermonkey(in signIn: UUID?) -> Installed? {
        Extensions.instance(signIn).installed.first { $0.enabled && ($0.name.lowercased().contains("tampermonkey") || $0.name.lowercased().contains("violentmonkey")) }
    }

    // MARK: - install

    /// A navigation Yab takes as a userscript to install: a main-frame
    /// `.user.js` (Greasy Fork, OpenUserJS, a raw file, one dropped on the
    /// window), unless it was let through to Tampermonkey. Answers the
    /// script's own address, or nil to let the navigation be.
    func takes(_ url: URL) -> URL? {
        // Tampermonkey's rule sends a clicked `.user.js` to its install
        // page before Yab hears of the click: WebKit applies an extension's
        // redirect in the page, ahead of the navigation policy. The script
        // is read back out of the page's address.
        let script = Self.behindTampermonkey(url) ?? url
        guard ["http", "https", "file"].contains(script.scheme?.lowercased() ?? ""),
              script.path.lowercased().hasSuffix(".user.js") else { return nil }
        if passing.remove(url) != nil { return nil }
        return Boosts.shared.safeMode ? nil : script
    }

    /// Tampermonkey's install page, the script's address after `#url=` as
    /// its rule writes it, unencoded (Chrome's `\0`).
    nonisolated static let tampermonkeyInstall = "https://www.tampermonkey.net/script_installation.php#url="

    nonisolated static func behindTampermonkey(_ url: URL) -> URL? {
        guard url.host()?.lowercased() == "www.tampermonkey.net", url.path == "/script_installation.php",
              let hash = url.fragment, hash.hasPrefix("url=") else { return nil }
        return URL(string: String(hash.dropFirst(4)))
    }

    /// Read the file and show its card over the tab's page. A file the
    /// person chose (`add`) that isn't a userscript says so in the corner
    /// and leaves the page be.
    func offer(_ url: URL, in tab: Tab, browser: Browser, chosen: Bool = false) {
        Task {
            do {
                let text = try await Self.fetch(url)
                guard Userscript.looks(text) else {
                    if chosen {
                        browser.toaster.pop("\(url.lastPathComponent) isn’t a userscript: it has no ==UserScript== block.", mark: "exclamationmark.triangle")
                        return
                    }
                    // Only named like one: shown as the file it is.
                    passing.insert(url); tab.go(to: url); return
                }
                var script = try Userscript.read(text)
                let kept = records.first { $0.id == script.id }
                let offer = Offer(tabID: tab.id, url: url, script: script,
                                  facts: ["Userscript" + (script.version.isEmpty ? "" : " " + script.version), Userscript.from(url)].compactMap { $0 }.joined(separator: " · "),
                                  replaces: kept?.version)
                offers[tab.id] = offer
                // Greasy Fork's numbers while the pinned files come in.
                let read = script
                Task { [weak self] in
                    if let facts = await Self.facts(url, script: read), self?.offers[tab.id]?.id == offer.id { self?.offers[tab.id]?.facts = facts }
                }
                var problem: String?
                do { script = try await Self.pin(script) }
                catch { problem = error.localizedDescription }
                let only = script.onlyTampermonkey
                if !only.isEmpty { problem = "Uses \(BoostPackage.list(only)), which only Tampermonkey answers." }
                guard offers[tab.id]?.id == offer.id else { return }
                offers[tab.id]?.script = script
                offers[tab.id]?.problem = problem
                offers[tab.id]?.ready = true
            } catch {
                offers[tab.id] = nil
                browser.toaster.pop("Couldn't read this userscript: " + error.localizedDescription, mark: "exclamationmark.triangle")
            }
        }
    }

    /// Add Userscript… in the Boosts list, or a file dropped on it: the
    /// chosen `.user.js` gets the card a `.user.js` opened in a tab gets,
    /// over the page in front, with its Try and Keep.
    func add(_ file: URL, browser: Browser, tab: Tab? = nil) {
        guard let tab = tab ?? browser.active else { browser.open(file, foreground: true); return }
        offer(file, in: tab, browser: browser, chosen: true)
    }

    /// The `.js` file among those dropped on the list, if any.
    nonisolated static func dropped(_ urls: [URL]) -> URL? {
        urls.first { $0.isFileURL && $0.pathExtension.lowercased() == "js" }
    }

    /// The open panel for Add Userscript…: one `.user.js` or `.js` file.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.javaScript]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a userscript (.user.js)"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The card goes; the page is as it was. A tried script leaves with a reload.
    func dismiss(_ tab: Tab) {
        guard let offer = offers.removeValue(forKey: tab.id) else { return }
        if offer.tried {
            arm(tab)
            tab.reloadForChange(.userscript)
        }
    }

    /// The file goes to Tampermonkey's own install page:
    /// straight there, as its rule would send it, since the rule's redirect
    /// would otherwise come back here as the install page (`takes`).
    /// Violentmonkey takes the file itself.
    func useTampermonkey(_ tab: Tab) {
        guard let offer = offers.removeValue(forKey: tab.id) else { return }
        let to = tampermonkey(in: AddonProfiles.of(tab))?.name.lowercased().contains("tampermonkey") == true && offer.url.scheme != "file"
            ? URL(string: Self.tampermonkeyInstall + offer.url.absoluteString) ?? offer.url : offer.url
        passing.insert(to)
        tab.go(to: to)
    }

    /// Try: the script in this tab only, on the first page it is for.
    func tryOut(_ tab: Tab, browser: Browser) async {
        guard var offer = offers[tab.id], offer.ready, offer.problem == nil else { return }
        var target = tab
        if let url = tab.address, !offer.script.matches(url) {
            // The first matching tab there is, else its first site, opened.
            if let open = allTabs.first(where: { AddonProfiles.of($0) == AddonProfiles.of(tab) && !$0.shy && !$0.isDev && $0.address.map(offer.script.matches) == true }) {
                target = open
            } else if let site = Self.firstPage(offer.script) {
                target = browser.open(site, foreground: true, from: tab)
            }
            if let owner = BrowserWindows.shared.browsers.first(where: { $0.tabs.contains { $0 === target } }) {
                if owner.active?.id != target.id { owner.focus(target) }
            }
        }
        if target !== tab { offers[tab.id] = nil }
        offer.tried = true
        offers[target.id] = Offer(tabID: target.id, url: offer.url, script: offer.script, facts: offer.facts, tried: true, ready: true, problem: nil, replaces: offer.replaces)
        arm(target)
        if !target.page.isLoading, target.address.map(offer.script.matches) == true {
            let inPage = offer.script.inPage
            // On Chromium a script in the page's world talks through its
            // bridge, which only a new document has: a reload runs it.
            if inPage, target.builtPage is ChromiumPage { target.reloadForChange(.userscript); return }
            _ = try? await BoostJavaScript.evaluate(source(offer.script, id: offer.script.id, inPage: inPage, signIn: AddonProfiles.of(target)), on: target.page, world: pageWorld(offer.script.id, inPage: inPage))
        }
    }

    /// An address the script's patterns name: https://www.youtube.com/.
    nonisolated static func firstPage(_ script: Userscript) -> URL? {
        for pattern in script.matches + script.includes {
            guard case .site(let host)? = Userscript.scope(pattern) else { continue }
            let scheme = pattern.hasPrefix("http://") ? "http" : "https"
            let named = pattern.range(of: "://").map { String(pattern[$0.upperBound...].prefix { $0 != "/" }) } ?? ""
            let exact = !named.contains("*") && !named.isEmpty ? named : host
            if let url = URL(string: scheme + "://" + exact + "/") { return url }
        }
        return nil
    }

    /// Keep ⌘↩: saved for every tab its `@match` covers. Only the card's
    /// own button and keys call this; agents never keep.
    func keep(_ tab: Tab) async {
        guard let offer = offers[tab.id], offer.ready, offer.problem == nil else { return }
        do {
            var profiles = record(offer.script.id)?.profiles ?? AddonProfiles(signIn: AddonProfiles.of(tab), enabled: true)
            if let old = scripts[offer.script.id], !offer.script.more(than: old).isEmpty {
                profiles.enabled = profiles.enabled.mapValues { _ in false }
            }
            profiles.setEnabled(true, in: AddonProfiles.of(tab))
            try store(offer.script, source: offer.url.absoluteString, enabled: true, profiles: profiles)
            offers[tab.id] = nil
            if !offer.tried, let url = tab.address, offer.script.matches(url) { tab.reloadForChange(.userscript) }
            refreshTabs()
        } catch { offers[tab.id]?.problem = error.localizedDescription }
    }

    /// Writes a script as kept, its old version into history.
    @discardableResult
    func store(_ script: Userscript, source: String?, enabled: Bool, moved: String? = nil, values seed: [String: Any]? = nil, profiles: AddonProfiles? = nil) throws -> Record {
        let id = script.id
        let folder = folder(id)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("script.user.js").path), let old = record(id) {
            let history = folder.appendingPathComponent("history/" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + " " + old.version, isDirectory: true)
            try? FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: folder.appendingPathComponent("script.user.js"), to: history.appendingPathComponent("script.user.js"))
        }
        try write(script, to: folder)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("pending"))
        if let seed {
            // Moved from another manager's storage, read off its page: an
            // IndexedDB Date or a NaN would raise in JSONSerialization here
            // and on every page the script runs on after (SafeJSON).
            let seed = SafeJSON.keepable(seed)
            values[cacheKey(id, in: nil)] = seed
            try? JSONSerialization.data(withJSONObject: seed).write(to: folder.appendingPathComponent("values.json"), options: .atomic)
        }
        var changed = records
        let now = Date()
        let scope = profiles ?? record(id)?.profiles ?? AddonProfiles(signIn: nil, enabled: enabled)
        let record = Record(id: id, name: script.name, version: script.version, enabled: scope.enabled.values.contains(true), profiles: scope,
                            source: source ?? record(id)?.source, installed: record(id)?.installed ?? now, updated: now,
                            revision: Self.revision(script), checked: now, pending: nil, moved: moved ?? record(id)?.moved)
        if let at = changed.firstIndex(where: { $0.id == id }) { changed[at] = record } else { changed.append(record) }
        try save(changed)
        scripts[id] = script
        made = made.filter { !$0.key.hasPrefix(id + "/") }
        return record
    }

    func setEnabled(_ id: String, _ on: Bool, in signIn: UUID? = nil) {
        guard let at = records.firstIndex(where: { $0.id == id }) else { return }
        var changed = records
        var profiles = changed[at].profiles ?? AddonProfiles(legacy: changed[at].enabled, signIns: AddonProfiles.existing)
        profiles.setEnabled(on, in: signIn)
        changed[at].profiles = profiles
        changed[at].enabled = profiles.enabled.values.contains(true)
        do { try save(changed) } catch { trouble = error.localizedDescription; return }
        refreshTabs(reloading: id, profile: AddonProfiles.key(signIn))
    }

    func delete(_ id: String, in signIn: UUID? = nil) {
        if let at = records.firstIndex(where: { $0.id == id }), var profiles = records[at].profiles {
            guard profiles.contains(signIn) else { return }
            profiles.remove(signIn)
            if !profiles.enabled.isEmpty {
                var changed = records; changed[at].profiles = profiles
                changed[at].enabled = profiles.enabled.values.contains(true)
                do { try save(changed) } catch { trouble = error.localizedDescription; return }
                try? FileManager.default.removeItem(at: valuesFile(id, in: signIn))
                values[cacheKey(id, in: signIn)] = nil
                made[cacheKey(id, in: signIn)] = nil
                valueTurns[cacheKey(id, in: signIn)] = nil
                refreshTabs(reloading: id, profile: AddonProfiles.key(signIn))
                return
            }
        }
        let script = scripts[id]
        do {
            try save(records.filter { $0.id != id })
            try? FileManager.default.removeItem(at: folder(id))
            scripts[id] = nil; values = values.filter { !$0.key.hasPrefix(id + "/") }; made = made.filter { !$0.key.hasPrefix(id + "/") }
        } catch { trouble = error.localizedDescription; return }
        for tab in allTabs where AddonProfiles.of(tab) == signIn && script.map({ s in tab.address.map(s.matches) == true }) == true { tab.reloadForChange(.userscript) }
        refreshTabs()
    }

    /// Versions kept before this one, newest first.
    func forget(signIn: UUID) {
        for id in records(in: signIn).map(\.id) { delete(id, in: signIn) }
    }

    func history(_ id: String) -> [(date: String, version: String, url: URL)] {
        let folder = folder(id).appendingPathComponent("history", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { entry in
            let parts = entry.lastPathComponent.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (String(parts[0].prefix(10)), parts[1], entry.appendingPathComponent("script.user.js"))
        }.sorted { $0.url.path > $1.url.path }
    }

    func restore(_ id: String, from file: URL) async {
        guard let text = try? String(contentsOf: file, encoding: .utf8), var script = try? Userscript.read(text) else { return }
        do {
            script = try await Self.pin(script)
            try store(script, source: nil, enabled: record(id)?.enabled ?? true)
            refreshTabs(reloading: id)
        } catch { trouble = error.localizedDescription }
    }

    // MARK: - fetching

    nonisolated static func fetch(_ url: URL, limit: Int = 5_000_000) async throws -> String {
        if url.isFileURL {
            return try String(contentsOf: url, encoding: .utf8)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("text/javascript, text/plain, */*", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Userscript.Invalid("\(url.host() ?? url.absoluteString) answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        guard data.count <= limit else { throw Userscript.Invalid("\(url.lastPathComponent) is larger than \(limit / 1_000_000) MB.") }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// `@require` and `@resource` files fetched and pinned by SHA-256. A
    /// `#sha256=` or `#md5=` the author gave is checked too, where it can be.
    nonisolated static func pin(_ script: Userscript) async throws -> Userscript {
        var script = script
        var requires: [Userscript.File] = []
        for address in script.requireURLs {
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw Userscript.Invalid("Can't include \(address): only web addresses.")
            }
            let text: String
            do { text = try await fetch(url) } catch { throw Userscript.Invalid("Couldn't fetch \(Userscript.describe(require: address)): \(error.localizedDescription)") }
            let sha = Userscript.sha256(Data(text.utf8))
            if let fragment = url.fragment, let wanted = fragment.range(of: #"sha256=([0-9a-f]{64})"#, options: .regularExpression) {
                guard fragment[wanted].dropFirst(7) == sha else { throw Userscript.Invalid("\(Userscript.describe(require: address)) isn't the file its author pinned.") }
            }
            requires.append(Userscript.File(name: "", url: address, sha256: sha, text: text))
        }
        var resources: [Userscript.File] = []
        for (name, address) in script.resourceSpecs {
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let text = (try? await fetch(url)) ?? ""
            let ext = url.pathExtension.lowercased()
            let mime = ["css": "text/css", "json": "application/json", "svg": "image/svg+xml", "js": "text/javascript", "html": "text/html"][ext] ?? "text/plain"
            resources.append(Userscript.File(name: name, url: address, sha256: Userscript.sha256(Data(text.utf8)), text: text, mime: mime))
        }
        script.requires = requires
        script.resources = resources
        return script
    }

    /// "Userscript 3.2.0 · greasyfork.org · 39,091 installs · updated Sep 6":
    /// Greasy Fork's own numbers where it has the script.
    nonisolated static func facts(_ url: URL, script: Userscript) async -> String? {
        var parts = ["Userscript" + (script.version.isEmpty ? "" : " " + script.version)]
        if let from = Userscript.from(url) { parts.append(from) }
        if let id = Userscript.greasyForkID(url), let api = URL(string: "https://api.greasyfork.org/en/scripts/\(id).json"),
           let text = try? await fetch(api, limit: 2_000_000), let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            if let installs = value["total_installs"] as? Int {
                parts.append(installs.formatted() + (installs == 1 ? " install" : " installs"))
            }
            if let when = (value["code_updated_at"] as? String).flatMap({ ISO8601DateFormatter.fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }) {
                let format = Calendar.current.isDate(when, equalTo: Date(), toGranularity: .year) ? AppDates.dateTime.month(.abbreviated).day() : AppDates.dateTime.month(.abbreviated).day().year()
                parts.append("updated " + when.formatted(format))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - running

    func world(_ id: String, inPage: Bool) -> WKContentWorld { inPage ? .page : Self.world(id) }
    /// The same world through a tab's page, on either engine.
    func pageWorld(_ id: String, inPage: Bool) -> PageWorld { inPage ? .page : .named("yab-us-" + id) }
    private static var worlds: [String: WKContentWorld] = [:]
    static func world(_ id: String) -> WKContentWorld {
        if let world = worlds[id] { return world }
        let world = WKContentWorld.world(name: "yab-us-" + id)
        worlds[id] = world; return world
    }

    private func cacheKey(_ id: String, in signIn: UUID?) -> String { id + "/" + AddonProfiles.key(signIn) }
    func valuesFile(_ id: String, in signIn: UUID?) -> URL {
        guard let signIn else { return folder(id).appendingPathComponent("values.json") }
        return folder(id).appendingPathComponent("profiles/" + signIn.uuidString + "/values.json")
    }
    private func storedValues(_ id: String, in signIn: UUID? = nil) -> [String: Any] {
        let key = cacheKey(id, in: signIn)
        if let known = values[key] { return known }
        let read = (try? Data(contentsOf: valuesFile(id, in: signIn)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        values[key] = read
        return read
    }
    func values(of id: String, in signIn: UUID? = nil) -> [String: Any] { storedValues(id, in: signIn) }

    private static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    func source(_ script: Userscript, id: String, inPage: Bool, signIn: UUID? = nil) -> String {
        UserscriptRuntime.source(script, id: id, values: script.storesValues || script.uses("GM_getValue") || script.uses("GM.getValue") ? storedValues(id, in: signIn) : [:],
                                 inPage: inPage, token: token, appVersion: Self.appVersion)
    }

    private func userScript(_ script: Userscript, id: String, signIn: UUID?) -> WKUserScript {
        let inPage = script.inPage
        let cache = cacheKey(id, in: signIn)
        let key = Self.revision(script) + ":\(valueTurns[cache] ?? 0)"
        if let made = made[cache], made.key == key { return made.script }
        let time: WKUserScriptInjectionTime = script.runAt == "document-start" ? .atDocumentStart : .atDocumentEnd
        let made = WKUserScript(source: source(script, id: id, inPage: inPage, signIn: signIn), injectionTime: time, forMainFrameOnly: script.noframes, in: world(id, inPage: inPage))
        self.made[cache] = (key, made)
        everMade.insert(ObjectIdentifier(made))
        everMadeScripts.append(made)
        return made
    }

    /// Called every time a tab is armed (Tab.arm), after the boosts: the
    /// scripts that can run on the site it is going to, and the one on
    /// trial in it. Nothing in private tabs or Developer Mode.
    func attach(to controller: WKUserContentController, tab: Tab, host: String?, document: Bool = true) {
        var wanted: [(String, Bool, WKUserScript)] = []
        if !Boosts.shared.safeMode, !tab.shy, !tab.isDev {
            let trial = offers[tab.id].flatMap { $0.tried ? $0.script : nil }
            for record in records(in: AddonProfiles.of(tab)) where record.enabled && record.id != trial?.id {
                guard let script = scripts[record.id], script.mayRun(on: host) else { continue }
                wanted.append((record.id, script.inPage, userScript(script, id: record.id, signIn: AddonProfiles.of(tab))))
            }
            if let trial { wanted.append((trial.id, trial.inPage, userScript(trial, id: trial.id, signIn: AddonProfiles.of(tab)))) }
        }
        // A new document: the old one's commands are gone with it.
        if document, commands[tab.id] != nil { commands[tab.id] = nil }
        relay(controller, wanted.map { ($0.0, $0.1) })
        let scripts = controller.userScripts.map { $0 }
        let have = scripts.filter { everMade.contains(ObjectIdentifier($0)) }
        guard have.map(ObjectIdentifier.init) != wanted.map({ ObjectIdentifier($0.2) }) else { return }
        if !have.isEmpty {
            let others = scripts.filter { !everMade.contains(ObjectIdentifier($0)) }
            controller.removeAllUserScripts()
            let kept = Set(controller.userScripts.map(ObjectIdentifier.init))
            for script in others where !kept.contains(ObjectIdentifier(script)) { controller.addUserScript(script) }
        }
        wanted.forEach { controller.addUserScript($0.2) }
    }

    /// A new document: the old one's commands are gone with it.
    func newDocument(_ tab: Tab) { if commands[tab.id] != nil { commands[tab.id] = nil } }

    /// A tab told again what its scripts are, on either engine.
    func arm(_ tab: Tab) {
        if let chromium = tab.builtPage as? ChromiumPage { chromium.refreshFeatureScripts() }
        else if let web = tab.webKitOnly("WebKit userscript runtime", build: false) {
            attach(to: web.configuration.userContentController, tab: tab, host: PageScripts.host(of: tab.address))
        }
    }

    /// A Chromium tab's scripts, for every document: a link's navigation
    /// asks nobody first, and each script tests its own address. A script in
    /// the page's world can't hold a relay there (`window.webkit` is no thing
    /// to show a site), so a small one in its own world carries its calls.
    func chromiumScripts(for tab: Tab) -> (scripts: [PageScriptRegistration], relays: [(id: String, inPage: Bool)]) {
        guard !Boosts.shared.safeMode, !tab.shy, !tab.isDev else { return ([], []) }
        var chosen: [Userscript] = []
        let trial = offers[tab.id].flatMap { $0.tried ? $0.script : nil }
        for record in records(in: AddonProfiles.of(tab)) where record.enabled && record.id != trial?.id {
            if let script = scripts[record.id] { chosen.append(script) }
        }
        if let trial { chosen.append(trial) }
        var made: [PageScriptRegistration] = []
        var relays: [(id: String, inPage: Bool)] = []
        for script in chosen {
            let id = script.id, inPage = script.inPage
            relays.append((id, inPage))
            let atEnd = script.runAt != "document-start"
            if inPage {
                made.append(PageScriptRegistration(source: UserscriptRuntime.bridge(id, token: token), world: pageWorld(id, inPage: false), atEnd: false, mainOnly: script.noframes))
            }
            let source = UserscriptRuntime.source(script, id: id, values: script.storesValues || script.uses("GM_getValue") || script.uses("GM.getValue") ? storedValues(id, in: AddonProfiles.of(tab)) : [:],
                                                  inPage: inPage, token: token, appVersion: Self.appVersion, piped: inPage)
            made.append(PageScriptRegistration(source: source, world: pageWorld(id, inPage: inPage), atEnd: atEnd, mainOnly: script.noframes))
        }
        return (made, relays)
    }

    /// A script's call from its page on a Chromium tab.
    func heard(_ id: String, inPage: Bool, message: PageScriptMessage, tab: Tab, _ reply: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            reply(["error": "Invalid userscript request."], nil); return
        }
        let found = owner(of: tab).map { (tab, $0) }
        Task {
            do {
                let value = try await call(id, inPage: inPage, op: op, args: body["args"] as? [String: Any] ?? [:],
                                           token: body["token"] as? String, frame: message.frame.url, main: message.frame.isMain, found: found)
                reply(["value": value ?? NSNull()], nil)
            } catch { reply(["error": error.localizedDescription], nil) }
        }
    }
    private func owner(of tab: Tab) -> Browser? {
        (BrowserWindows.shared.browsers + [Agents.shared.browser].compactMap { $0 }).first { ($0.tabs + $0.parkedTabs).contains { $0 === tab } }
    }

    /// One handler per script's world; in the page's world, one per script.
    private func relay(_ controller: WKUserContentController, _ wanted: [(String, Bool)]) {
        let names = Set(wanted.map { $0.0 + ($0.1 ? "@page" : "") })
        if let had = handlers.object(forKey: controller), had as? Set<String> == names { return }
        for case let name as String in handlers.object(forKey: controller) ?? NSMutableSet() {
            let inPage = name.hasSuffix("@page"), id = inPage ? String(name.dropLast(5)) : name
            controller.removeScriptMessageHandler(forName: UserscriptRuntime.handler(id, inPage: inPage), contentWorld: world(id, inPage: inPage))
        }
        for (id, inPage) in wanted {
            // A popup can inherit a handler in a copied controller; WebKit throws on a second one.
            controller.removeScriptMessageHandler(forName: UserscriptRuntime.handler(id, inPage: inPage), contentWorld: world(id, inPage: inPage))
            controller.addScriptMessageHandler(Relay(id: id, inPage: inPage), contentWorld: world(id, inPage: inPage), name: UserscriptRuntime.handler(id, inPage: inPage))
        }
        handlers.setObject(NSMutableSet(set: names), forKey: controller)
    }

    /// Every open tab armed again; one script's pages reloaded when it was
    /// turned on, off or changed.
    func refreshTabs(reloading id: String? = nil, profile: String? = nil) {
        for tab in allTabs {
            if let profile, AddonProfiles.key(AddonProfiles.of(tab)) != profile { continue }
            if let chromium = tab.builtPage as? ChromiumPage { chromium.refreshFeatureScripts() }
            else if let web = tab.webKitOnly("WebKit userscript runtime", build: false) {
                attach(to: web.configuration.userContentController, tab: tab, host: PageScripts.host(of: tab.address), document: false)
            } else { continue }
            if let id, let script = scripts[id], tab.address.map(script.matches) == true, !tab.shy, !tab.isDev { tab.reloadForChange(.userscript) }
        }
    }

    private var allTabs: [Tab] {
        var seen: Set<UUID> = []
        return (BrowserWindows.shared.browsers + [Agents.shared.browser].compactMap { $0 })
            .flatMap { $0.tabs + $0.parkedTabs }.filter { seen.insert($0.id).inserted }
    }
    fileprivate func tab(of web: WKWebView?) -> (Tab, Browser)? {
        guard let web else { return nil }
        for browser in BrowserWindows.shared.browsers + [Agents.shared.browser].compactMap({ $0 }) {
            if let tab = (browser.tabs + browser.parkedTabs).first(where: { $0.webKitOnly("WebKit userscript runtime", build: false) === web }) { return (tab, browser) }
        }
        return nil
    }

    func closed(_ tab: Tab) {
        offers[tab.id] = nil
        commands[tab.id] = nil
    }

    // MARK: - the GM API, answered

    private final class Relay: NSObject, WKScriptMessageHandlerWithReply {
        let id: String
        let inPage: Bool
        init(id: String, inPage: Bool) { self.id = id; self.inPage = inPage }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
                    replyHandler(["error": "Invalid userscript request."], nil); return
                }
                let frame = message.frameInfo.request.url
                Task {
                    do {
                        let value = try await Userscripts.shared.call(self.id, inPage: self.inPage, op: op, args: body["args"] as? [String: Any] ?? [:],
                                                                      token: body["token"] as? String, frame: frame, main: message.frameInfo.isMainFrame,
                                                                      found: Userscripts.shared.tab(of: message.webView))
                        replyHandler(["value": value ?? NSNull()], nil)
                    } catch { replyHandler(["error": error.localizedDescription], nil) }
                }
            }
        }
    }

    private func call(_ id: String, inPage: Bool, op: String, args: [String: Any], token: String?, frame: URL?, main: Bool, found: (Tab, Browser)?) async throws -> Any? {
        guard let found, !found.0.shy, !found.0.isDev else { throw Userscript.Invalid("This page can't use userscripts.") }
        let (tab, browser) = found
        let trial = offers[tab.id].flatMap { $0.tried && $0.script.id == id ? $0.script : nil }
        guard let script = trial ?? (isEnabled(id, in: AddonProfiles.of(tab)) ? scripts[id] : nil) else { throw Userscript.Invalid("This userscript is off.") }
        if inPage { guard token == self.token else { throw Userscript.Invalid("Not this userscript's call.") } }
        guard let frame, script.matches(frame) else { throw Userscript.Invalid("This page isn't one of the script's.") }
        switch op {
        case "set":
            guard let key = args["key"] as? String, !key.isEmpty, key.count <= 1000 else { throw Userscript.Invalid("GM_setValue needs a key.") }
            let signIn = AddonProfiles.of(tab)
            let keyInProfile = cacheKey(id, in: signIn)
            var state = storedValues(id, in: signIn)
            let removed = args["remove"] as? Bool == true
            if removed { state[key] = nil } else { state[key] = args["value"] ?? NSNull() }
            guard JSONSerialization.isValidJSONObject(state), let data = try? JSONSerialization.data(withJSONObject: state), data.count <= 5_000_000 else {
                throw Userscript.Invalid("A userscript keeps at most 5 MB of values.")
            }
            values[keyInProfile] = state
            valueTurns[keyInProfile, default: 0] += 1
            let file = valuesFile(id, in: signIn)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            // Other tabs running it hear the change (GM_addValueChangeListener, remote).
            let call = "window.__yabUserscripts && window.__yabUserscripts[\(BoostScript.json(id))] && window.__yabUserscripts[\(BoostScript.json(id))].changed(\(BoostScript.json(key)), \(BoostScript.json(args["value"] ?? NSNull())), \(removed))"
            for other in allTabs where AddonProfiles.of(other) == signIn && isEnabled(id, in: signIn) && other !== tab && other.address.map(script.matches) == true {
                other.builtPage?.run(call, in: pageWorld(id, inPage: script.inPage), gesture: false) { _ in }
            }
            return true
        case "menu":
            guard main else { return false }
            var mine = commands[tab.id]?[id] ?? []
            let command = args["id"] as? String ?? ""
            if args["op"] as? String == "add" {
                let caption = String((args["caption"] as? String ?? "").prefix(120))
                guard !caption.isEmpty, mine.count < 40 else { return false }
                mine.removeAll { $0.id == command }
                mine.append(Command(id: command, caption: caption))
            } else {
                mine.removeAll { $0.id == command }
            }
            commands[tab.id, default: [:]][id] = mine
            return true
        case "notify":
            let text = String((args["text"] as? String ?? "").prefix(160))
            guard browser.activeID == tab.id, Date().timeIntervalSince(notices[id] ?? .distantPast) >= 10, !text.isEmpty else { return false }
            notices[id] = Date()
            browser.toaster.pop(text, mark: "puzzlepiece.extension")
            return true
        case "open":
            guard let url = (args["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw Userscript.Invalid("GM_openInTab opens web addresses only.")
            }
            _ = browser.open(url, foreground: args["background"] as? Bool != true, from: tab)
            return true
        case "clipboard":
            let text = String((args["text"] as? String ?? "").prefix(1_000_000))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return true
        case "download":
            guard let url = (args["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw Userscript.Invalid("GM_download takes web addresses only.")
            }
            if let chromium = tab.builtPage as? ChromiumPage { chromium.startDownload(url) }
            else if let web = tab.webKitOnly("WebKit userscript runtime", build: false) {
                web.startDownload(using: URLRequest(url: url)) { [weak browser] download in browser?.keep(download) }
            }
            return true
        case "error":
            let line = (frame.host() ?? "") + ": " + String((args["message"] as? String ?? "").prefix(300))
            errors[id, default: []].append(line)
            if errors[id]!.count > 20 { errors[id]!.removeFirst() }
            return true
        case "xhr":
            return try await request(args, script: script, id: id, inPage: inPage, frame: frame, tab: tab)
        default:
            throw Userscript.Invalid("Yab doesn't answer \(op).")
        }
    }

    // MARK: - GM_xmlhttpRequest

    /// Whether a script may reach a host: its own sites, the page's own,
    /// the hosts on its card, or any with `@connect *`.
    nonisolated static func allows(_ host: String, script: Userscript, page: String?) -> Bool {
        let host = host.lowercased()
        if script.anyHost { return true }
        if let page, host == page.lowercased() { return true }
        return Userscript.covered(host, by: script.sites + script.hosts) || script.everywhere && page.map { Userscript.siteOf($0) == Userscript.siteOf(host) } == true
    }

    /// Whether the person's cookies go along: to the script's own sites and
    /// the page's, and to hosts it declared (the card says "with your
    /// sign-in"); never from a script in the page's own world, which the
    /// page itself could call.
    nonisolated static func signs(_ host: String, script: Userscript, page: String?, inPage: Bool) -> Bool {
        guard !inPage else { return false }
        let host = host.lowercased()
        if let page, Userscript.siteOf(host) == Userscript.siteOf(page.lowercased()) { return true }
        return Userscript.covered(host, by: script.sites + script.signedHosts)
    }

    private func request(_ args: [String: Any], script: Userscript, id: String, inPage: Bool, frame: URL, tab: Tab) async throws -> [String: Any] {
        guard let address = args["url"] as? String, let url = URL(string: address), let host = url.host(),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Userscript.Invalid("GM_xmlhttpRequest takes web addresses.") }
        guard Self.allows(host, script: script, page: frame.host()) else {
            refused[id, default: []].append(host)
            throw Userscript.Invalid("\(host) isn't on this script's card, so the request wasn't sent. Its header would need @connect \(host).")
        }
        let method = (args["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"].contains(method) else { throw Userscript.Invalid("GM_xmlhttpRequest can't send \(method).") }
        let timeout = min(max((args["timeout"] as? Double ?? 0) / 1000, 0), 120)
        var request = URLRequest(url: url, timeoutInterval: timeout > 0 ? timeout : 60)
        request.httpMethod = method
        for (field, value) in args["headers"] as? [String: Any] ?? [:] {
            let lower = field.lowercased()
            guard !["cookie", "host", "content-length", "connection"].contains(lower) else { continue }
            request.setValue("\(value)", forHTTPHeaderField: field)
        }
        if let data = args["data"] as? String, method != "GET", method != "HEAD" {
            guard data.utf8.count <= 10_000_000 else { throw Userscript.Invalid("The request is larger than 10 MB.") }
            request.httpBody = Data(data.utf8)
        }
        let anonymous = args["anonymous"] as? Bool == true
        let page = frame.host()
        let signs = { (target: URL) in !anonymous && Self.signs(target.host() ?? "", script: script, page: page, inPage: inPage) }
        if !anonymous, !inPage, tab.engineKind == .chromium { await (try? ChromiumDRMCookies.of(tab))?.current(for: url) }
        let cookies: [HTTPCookie] = anonymous || inPage ? [] : await withCheckedContinuation { done in
            tab.store.httpCookieStore.getAllCookies { done.resume(returning: $0) }
        }
        func sign(_ request: inout URLRequest) {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            guard let target = request.url, signs(target) else { return }
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies.filter { AgentRead.sent($0, to: target) }) { request.setValue(value, forHTTPHeaderField: field) }
        }
        sign(&request)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        let guide = Redirects(allow: { Self.allows($0.host() ?? "", script: script, page: page) }, sign: { var next = $0; sign(&next); return next })
        let session = URLSession(configuration: config, delegate: guide, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw Userscript.Invalid("The request timed out.") }
        guard data.count <= 20_000_000 else { throw Userscript.Invalid("The answer is larger than 20 MB.") }
        if let final = response.url, signs(final) { AgentRead.take(response, of: request.url == final ? request : { var r = request; r.url = final; sign(&r); return r }(), into: tab.store) }
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).compactMap { key, value -> String? in
            guard let key = key as? String else { return nil }
            return key.lowercased() + ": " + "\(value)"
        }.sorted().joined(separator: "\r\n")
        let status = http?.statusCode ?? 200
        var out: [String: Any] = ["status": status, "statusText": HTTPURLResponse.localizedString(forStatusCode: status).capitalized,
                                  "headers": headers, "finalUrl": response.url?.absoluteString ?? address, "mime": response.mimeType ?? ""]
        out["text"] = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if args["binary"] as? Bool == true { out["base64"] = data.base64EncodedString() }
        return out
    }

    /// Redirects followed only to hosts the script may reach, with the
    /// cookies of where they go, or none.
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let allow: (URL) -> Bool
        let sign: (URLRequest) -> URLRequest
        init(allow: @escaping (URL) -> Bool, sign: @escaping (URLRequest) -> URLRequest) { self.allow = allow; self.sign = sign }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, allow(url) else { completionHandler(nil); return }
            completionHandler(sign(request))
        }
    }

    /// A command the page registered, chosen in Site Controls or ⌘T.
    func run(_ command: String, of id: String, in tab: Tab) {
        guard isEnabled(id, in: AddonProfiles.of(tab)) || offers[tab.id]?.tried == true,
              let page = tab.builtPage, let script = scripts[id] ?? offers[tab.id]?.script else { return }
        let call = "window.__yabUserscripts && window.__yabUserscripts[\(BoostScript.json(id))] ? window.__yabUserscripts[\(BoostScript.json(id))].menu(\(BoostScript.json(command))) : false"
        page.run(call, in: pageWorld(id, inPage: script.inPage)) { _ in }
    }

    /// Off on this site: turned off, as Site Controls' toggle does.
    func turnOff(_ id: String, in signIn: UUID? = nil) { setEnabled(id, false, in: signIn) }

    // MARK: - updates

    private func watchUpdates() async {
        try? await Task.sleep(for: .seconds(Store.testing ? 3600 * 24 : 90))
        while !Task.isCancelled {
            await checkUpdates()
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// Once a day for each kept script with an update address; `force`
    /// checks every one now.
    @discardableResult
    func checkUpdates(force: Bool = false) async -> [String: String] {
        var said: [String: String] = [:]
        for record in records {
            guard let kept = scripts[record.id], kept.updateURL ?? kept.downloadURL != nil else { continue }
            guard force || record.checked.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { continue }
            do { said[record.id] = try await check(record.id) }
            catch { said[record.id] = "error: " + error.localizedDescription }
        }
        return said
    }

    /// "same", "applied", "held" (asks for more) or "none" (no newer version).
    func check(_ id: String) async throws -> String {
        guard let kept = scripts[id], let record = record(id) else { return "none" }
        defer { if let at = records.firstIndex(where: { $0.id == id }) { var changed = records; changed[at].checked = Date(); try? save(changed) } }
        let meta = kept.updateURL ?? kept.downloadURL!
        let head = try Userscript.read(try await Self.fetch(meta))
        guard Userscript.newer(head.version, than: record.version) else { return "none" }
        if let pending = record.pending, pending.version == head.version { return "held" }
        let full = kept.downloadURL ?? meta
        var fresh = full == meta && head.source.count > 0 && Userscript.looks(head.source) && !meta.path.hasSuffix(".meta.js") ? head : try Userscript.read(try await Self.fetch(full))
        fresh = try await Self.pin(fresh)
        guard fresh.id == id else { throw Userscript.Invalid("The new version is another script.") }
        let more = fresh.more(than: kept)
        if more.isEmpty {
            // Same rights: in quietly; pages that ran the old one keep it until their next load.
            try store(fresh, source: record.source, enabled: record.enabled)
            refreshTabs()
            return "applied"
        }
        let pending = folder(id).appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.removeItem(at: pending)
        try write(fresh, to: pending)
        guard let at = records.firstIndex(where: { $0.id == id }) else { return "held" }
        var changed = records
        changed[at].pending = Pending(version: fresh.version, rights: more, revision: Self.revision(fresh))
        try save(changed)
        // The dot Site Controls' button shows for extensions that came in quietly.
        Extensions.shared.dotQuietly()
        return "held"
    }

    /// Update in the row: the waiting version, its rights already said there.
    func applyPending(_ id: String, in signIn: UUID? = nil) async {
        guard let record = record(id), record.pending != nil, let fresh = try? load(folder(id).appendingPathComponent("pending", isDirectory: true)) else { return }
        do {
            var profiles = record.profiles ?? AddonProfiles(signIn: signIn, enabled: record.enabled)
            profiles.enabled = profiles.enabled.mapValues { _ in false }
            profiles.setEnabled(record.profiles?.isEnabled(in: signIn) ?? record.enabled, in: signIn)
            try store(fresh, source: record.source, enabled: record.enabled, profiles: profiles)
            refreshTabs(reloading: id)
        } catch { trouble = error.localizedDescription }
    }

    // MARK: - keys

    /// ⌘↩ keeps, Escape closes the card (or undoes a try).
    func key(_ event: NSEvent, browser: Browser) -> Bool {
        guard let tab = browser.active, let offer = offers[tab.id], !tab.typing else { return false }
        // From the page, or nothing in particular: never from the field.
        let responder = event.window?.firstResponder
        guard responder === event.window || responder == nil || tab.builtPage.map({ page in (responder as? NSView)?.isDescendant(of: page) == true }) == true else { return false }
        let rest = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if [36, 76].contains(event.keyCode), rest == .command {
            if offer.ready, offer.problem == nil { Task { await keep(tab) } }
            return true
        }
        if event.keyCode == 53, rest.isEmpty { dismiss(tab); return true }
        return false
    }
}

extension ISO8601DateFormatter {
    /// Greasy Fork's dates carry milliseconds.
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()
}
