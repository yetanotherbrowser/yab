import Combine
import CryptoKit
import SwiftUI
import WebKit

// A site's own icon, for the tabs that are set to wear one.
//
// WebKit doesn't hand these over, so the page is asked what it declares and
// the best of those is fetched once and kept as a small PNG next to the
// history. A tab brought back from yesterday's session has its icon before it
// has a page; a tab on a site never seen before shows a letter until the icon
// arrives, which is a second or so.

@MainActor
final class Favicons {
    static let shared = Favicons()

    /// Called with a host and its icon whenever one arrives, so every tab on
    /// that host can put it on at once.
    var arrived: ((String, NSImage) -> Void)?
    /// Menus and kept pages can update their marks without replacing the
    /// tab loader's arrival callback.
    let changes = PassthroughSubject<String, Never>()

    /// The icons drawn lately, as many as Dia keeps: a year of browsing
    /// left thousands, every one held until quit.
    private var memory = Held(limit: 1_000)
    private var absentOnDisk: Set<String> = []
    private(set) var busy: Set<String> = []
    /// Cold tabs can bring hundreds of sites back at once. Their small,
    /// cookie-free icon lookups share four places, without waking pages.
    private var guesses: [(page: URL, again: Bool)] = []
    private var queued: Set<String> = []
    private var guessing = 0
    static let guessLimit = 4
    /// A bitmap brought from the other browser takes precedence over a
    /// generic front-page icon found while its import was still reading.
    private var frontPageIcons: Set<String> = []
    /// What each host's pages named and couldn't be had this session, by
    /// the address named first, "" for a page naming none (only the root
    /// file guessed). Not the host alone: a bot check's page (Dribbble's)
    /// names nothing and its root file is missing, and the page it reloads
    /// into a moment later names the icon (`asks`).
    private var missed: [String: Set<String>] = [:]
    /// Hosts whose front page, asked with no tab of theirs open, had no icon
    /// this session. Kept apart from `missed`: a page of the site once
    /// signed in may well declare one (Calendar's sign-in has none).
    private var unfound: Set<String> = []
    /// The address each kept icon was fetched for, as read off its file:
    /// "" for one a front page offered (`fetch(host:)`), a page naming none
    /// gave, an import brought, or Yab kept before it wrote this down.
    private var sources: [String: String] = [:]
    /// Kept icons a page of their site asked after this session and got no
    /// other for, offline say: worn as they are until the next launch,
    /// not asked after on every load.
    private var rechecked: Set<String> = []
    /// Icons a page names that aren't its site's, by their address, for the
    /// session: a Sheet's on docs.google.com, a pull request's state on
    /// github.com, Calendar's new day. Worn by that page's tab only, never
    /// kept, never put on the site's other tabs.
    private var own = Held(limit: 300)
    private var ownFailed: Set<String> = []
    /// The icon each tab wears that its page named for itself (`wearOwn`),
    /// one per tab: an icon arriving for the site
    /// goes on the site's tabs that wear the site's, not over these. A
    /// Notion tab wearing its page's icon took the next one kept for
    /// notion.so, the other Notion tab's.
    private let worn = NSMapTable<Tab, NSImage>.weakToWeakObjects()
    /// Each tab's latest ask (`fetch(for:)`), as Chromium drops a download
    /// its page's newer icons replaced: what an older ask brings in late
    /// is not worn over a newer one's.
    private let asked = NSMapTable<Tab, NSNumber>.weakToStrongObjects()

    /// The icon each page last wore, by its address (`page`), as Chromium's
    /// history keeps one per page URL (FaviconService's icon mapping, page
    /// URL to icon URL) and finds a page's by its address before the page
    /// is in, the host's only for a page with none (fallback_to_host).
    /// Kept by host alone, Docs, Sheets and Slides, all on docs.google.com,
    /// had one icon between them: a slideshow's sleeping or restored tab,
    /// its pin, its row under the field and in the history wore the Docs
    /// icon until the page had loaded (R2600). This session's, ahead of
    /// the disk's (`pageTable`).
    private var pageMemory = Held(limit: 1_000)
    /// On disk (`pagesFile`): each page's picture by the hash of its bytes,
    /// one file for the many pages wearing the same; oldest first.
    private var pageNames: [String: String]?
    private var pageOrder: [String] = []
    /// Worn and not yet on disk: written together a moment later, so a
    /// page changing its icon every second writes once in a while.
    private var pagesPending: [String: NSImage] = [:]
    private var pagesSaving = false
    private let keepsPages: Bool
    nonisolated static let pageLimit = 2_000
    nonisolated static let pagesDelay: Double = 3

    init(keepsPages: Bool = true) {
        self.keepsPages = keepsPages
    }

    /// Whether a tab wears the icon its page named for itself, not its
    /// site's (`worn`).
    func wearsOwn(_ tab: Tab) -> Bool {
        guard let image = worn.object(forKey: tab) else { return false }
        return image === tab.icon
    }

    /// Icons in memory, those asked for least lately let go past `limit`.
    /// Only the copy here goes: the file stays, read again when its site
    /// is next drawn.
    struct Held {
        let limit: Int
        private var images: [String: (image: NSImage, used: UInt64)] = [:]
        private var clock: UInt64 = 0

        init(limit: Int) { self.limit = limit }

        var count: Int { images.count }

        subscript(key: String) -> NSImage? {
            mutating get {
                guard let hit = images[key] else { return nil }
                clock += 1
                images[key]?.used = clock
                return hit.image
            }
            set {
                guard let newValue else { images[key] = nil; return }
                clock += 1
                images[key] = (newValue, clock)
                if images.count > limit { trim() }
            }
        }

        mutating func remove(where gone: (String) -> Bool) {
            for key in images.keys where gone(key) { images[key] = nil }
        }

        /// Down to nine tenths of the limit at once, not one at every
        /// arrival past it.
        private mutating func trim() {
            let drop = images.count - limit * 9 / 10
            for key in images.sorted(by: { $0.value.used < $1.value.used }).prefix(drop).map(\.key) { images[key] = nil }
        }
    }

    nonisolated private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }
    nonisolated private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }

    /// Whether the chrome is dark right now. A site that declares an icon
    /// for `prefers-color-scheme: dark` is asked for that one, and it is
    /// kept apart from the light one, so switching looks switches icons.
    static var dark: Bool {
        // No app in unit tests: the light icon.
        guard let app = NSApp else { return false }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The name an icon is kept under: the host, with a suffix for the dark
    /// variant a site offered. Sites without one keep one file for both.
    private static func key(_ host: String, dark: Bool) -> String { dark ? host + "@dark" : host }

    /// The name a page's icon is kept under: its host, and its port when
    /// the address names one other than its scheme's. Each port on a host
    /// is a site of its own, as every browser keys its origins: a NAS's
    /// services on 192.168.1.2:8080 and :9000, localhost's servers. Under
    /// the host alone the first one seen was kept for all of them, and the
    /// others' icons were worn by their own tab only, never kept, so after
    /// a restart their tabs came back with another's (feedback #1459).
    nonisolated static func site(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased()
        let usual = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        guard let port = url.port, port != usual else { return host }
        return "\(host):\(port)"
    }

    /// What is already known for a page, nothing fetched: the icon it last
    /// wore (`pageIcon`), its site's (`site`) for a page never seen.
    func cached(page url: URL) -> NSImage? {
        pageIcon(url) ?? Favicons.site(url).flatMap(cached)
    }

    /// The name a page's icon is kept under: its site and its path, as
    /// Chrome maps a page URL, without the scheme, the query and the
    /// fragment (a slide's #slide=, a mailbox's #inbox), which name the
    /// same page. Nil for an address that is not a web page's.
    nonisolated static func page(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, let site = site(url) else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? ""
        return site + (path.isEmpty ? "/" : path)
    }

    /// The icon a page last wore, nil for one never seen (or seen only in a
    /// private tab). In the dark, its dark variant when it wore one.
    func pageIcon(_ url: URL) -> NSImage? {
        guard let page = Favicons.page(url) else { return nil }
        if Favicons.dark, let hit = pagePicture(Favicons.key(page, dark: true)) { return hit }
        return pagePicture(page)
    }

    private func pagePicture(_ key: String) -> NSImage? {
        if let hit = pageMemory[key] { return hit }
        guard let name = pageTable()[key] else { return nil }
        let shelf = "pages/" + name
        if let hit = memory[shelf] { return hit }
        // Read when first drawn, as `listed` icons are: a session of two
        // hundred tabs coming back reads no file before its first frame.
        let image = NSImage(byReferencing: Favicons.pagesFolder.appendingPathComponent(name + ".png"))
        memory[shelf] = image
        return image
    }

    /// The icon a page's tab wears now, kept as that page's: on its tab
    /// asleep or after a restart, its pin, its rows. A private tab's is
    /// kept nowhere.
    func remember(_ image: NSImage, page url: URL, dark: Bool, shy: Bool) {
        guard !shy, let page = Favicons.page(url) else { return }
        let key = Favicons.key(page, dark: dark)
        if pageMemory[key] === image { return }
        pageMemory[key] = image
        guard keepsPages else { return }
        pagesPending[key] = image
        guard !pagesSaving else { return }
        pagesSaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Favicons.pagesDelay) { [weak self] in
            Task { await self?.savePages() }
        }
    }

    /// A site's pages forget what they wore, for the site's icon asked
    /// again (Refresh Site Icon) to go on all of them; every site's with
    /// none named (the history cleared).
    func forgetPages(of site: String? = nil) {
        func of(_ key: String) -> Bool { site.map { key.hasPrefix($0 + "/") } ?? true }
        pageMemory.remove(where: of)
        pagesPending = pagesPending.filter { !of($0.key) }
        var table = pageTable()
        let gone = table.keys.filter(of)
        guard !gone.isEmpty else { return }
        let names = Set(gone.compactMap { table.removeValue(forKey: $0) })
        pageOrder.removeAll(where: of)
        pageNames = table
        writePages(table, dropped: names)
    }

    nonisolated private static var pagesFolder: URL { folder.appendingPathComponent("pages", isDirectory: true) }
    nonisolated private static var pagesFile: URL { folder.appendingPathComponent("pages.json") }

    /// Pages and their pictures' names, read once.
    private func pageTable() -> [String: String] {
        if let pageNames { return pageNames }
        var pairs: [[String]] = []
        if keepsPages {
            pairs = MainBudget.chunk("favicon.pages") {
                (try? Data(contentsOf: Favicons.pagesFile)).flatMap { try? JSONDecoder().decode([[String]].self, from: $0) } ?? []
            }
        }
        var table: [String: String] = [:]
        var order: [String] = []
        for pair in pairs where pair.count == 2 && table.updateValue(pair[1], forKey: pair[0]) == nil {
            order.append(pair[0])
        }
        pageNames = table
        pageOrder = order
        return table
    }

    /// What was worn lately, written: each picture once under the hash of
    /// its bytes, then the table, on the queue site icons are written on.
    func savePages() async {
        let batch = pagesPending
        pagesPending = [:]
        let named = batch.isEmpty ? [] : await withCheckedContinuation { (done: CheckedContinuation<[(String, String)], Never>) in
            Favicons.writing.async { done.resume(returning: Favicons.file(pages: batch)) }
        }
        filed(named)
        if pagesPending.isEmpty {
            pagesSaving = false
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Favicons.pagesDelay) { [weak self] in
                Task { await self?.savePages() }
            }
        }
    }

    /// Quitting: what was worn and not yet written, now, and waited for.
    func savePagesNow() {
        let batch = pagesPending
        pagesPending = [:]
        guard keepsPages, !batch.isEmpty else { return }
        filed(Favicons.writing.sync { Favicons.file(pages: batch) })
        Favicons.writing.sync {}
    }

    /// The pictures written, put in the table, and the table written.
    private func filed(_ named: [(String, String)]) {
        var table = pageTable()
        var dropped: Set<String> = []
        var changed = false
        for (key, name) in named {
            let old = table.updateValue(name, forKey: key)
            guard old != name else { continue }
            changed = true
            if let old { dropped.insert(old); pageOrder.removeAll { $0 == key } }
            pageOrder.append(key)
        }
        // The pages worn longest ago go past the limit, as Chromium's history
        // lets its favicons go with the visits.
        while pageOrder.count > Favicons.pageLimit {
            if let old = table.removeValue(forKey: pageOrder.removeFirst()) { dropped.insert(old) }
        }
        pageNames = table
        if changed { writePages(table, dropped: dropped) }
    }

    private func writePages(_ table: [String: String], dropped: Set<String>) {
        let pairs = pageOrder.compactMap { key in table[key].map { [key, $0] } }
        let gone = dropped.subtracting(table.values)
        Favicons.writing.async {
            try? FileManager.default.createDirectory(at: Favicons.folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(pairs) { try? data.write(to: Favicons.pagesFile, options: .atomic) }
            for name in gone { try? FileManager.default.removeItem(at: Favicons.pagesFolder.appendingPathComponent(name + ".png")) }
        }
    }

    /// Each page's picture as a PNG named for its bytes, written unless
    /// one of that name is there. On `writing`.
    nonisolated private static func file(pages batch: [String: NSImage]) -> [(String, String)] {
        try? FileManager.default.createDirectory(at: pagesFolder, withIntermediateDirectories: true)
        var named: [(String, String)] = []
        for (key, image) in batch {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let name = SHA256.hash(data: png).prefix(12).map { String(format: "%02x", $0) }.joined()
            let file = pagesFolder.appendingPathComponent(name + ".png")
            guard FileManager.default.fileExists(atPath: file.path) || (try? png.write(to: file, options: .atomic)) != nil else { continue }
            named.append((key, name))
        }
        return named
    }

    /// What is already known, and nothing fetched. In the dark, the dark
    /// variant when there is one, the ordinary icon otherwise.
    func cached(_ host: String) -> NSImage? {
        if Favicons.dark, let hit = known(Favicons.key(host, dark: true)) { return hit }
        return known(host)
    }

    /// For the bench (evals/favicons/cache.py): how many icons are held in
    /// memory and kept on disk. `touch`: that many kept icons are first
    /// asked for and drawn at a row's size, as a long session's tabs, field
    /// rows and history list would, one site after another.
    func census(touch: Int = 0) -> [String: Any] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Favicons.folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        if touch > 0 {
            let canvas = NSImage(size: NSSize(width: 16, height: 16))
            for file in files.prefix(touch) {
                guard let image = known(file.deletingPathExtension().lastPathComponent) else { continue }
                canvas.lockFocus()
                image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                canvas.unlockFocus()
            }
        }
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ["memory": memory.count, "files": files.count, "bytes": bytes, "listed": listed?.count ?? -1]
    }

    /// The kept icons' file names, read once: a session of two hundred
    /// tabs coming back opened and read a file for each of its sites (two in
    /// the dark) before the window's first frame. Listed, a site with none
    /// costs nothing, and one with an icon is read when it is first drawn
    /// (YAB_LAUNCH_ICON_LIST=0 opens each, as before).
    private lazy var listed: Set<String>? = Startup.flag("ICON_LIST")
        ? (try? FileManager.default.contentsOfDirectory(atPath: Favicons.folder.path)).map(Set.init) : nil

    private func known(_ key: String) -> NSImage? {
        if let hit = memory[key] { return hit }
        guard !absentOnDisk.contains(key) else { return nil }
        if let listed {
            guard listed.contains(key + ".png") else {
                absentOnDisk.insert(key)
                return nil
            }
            let image = NSImage(byReferencing: Favicons.file(key))
            memory[key] = image
            return image
        }
        guard let image = MainBudget.chunk("favicon.disk", { NSImage(contentsOf: Favicons.file(key)) }) else {
            absentOnDisk.insert(key)
            return nil
        }
        memory[key] = image
        return image
    }

    nonisolated private static func fresh(_ key: String) -> Bool {
        guard let stamp = try? file(key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(stamp) < 7 * 86_400
    }

    private func source(_ key: String) -> String {
        if let hit = sources[key] { return hit }
        let read = Favicons.source(of: Favicons.file(key)) ?? ""
        sources[key] = read
        return read
    }

    /// Where a kept icon came from, written on its file beside the picture.
    nonisolated private static let sourceName = "dev.serafim.yab.icon-source"

    nonisolated static func mark(_ file: URL, source: String) {
        let bytes = Array(source.utf8)
        _ = file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return setxattr(path, sourceName, bytes, bytes.count, 0, 0)
        }
    }

    nonisolated static func source(of file: URL) -> String? {
        file.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, sourceName, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            guard getxattr(path, sourceName, &bytes, size, 0, 0) == size else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// The look changed: every tab puts on the icon that goes with it, and
    /// asks again for one where the site may have a variant not yet seen.
    func relook(_ tabs: [Tab]) {
        missed = [:]
        absentOnDisk = []
        if listed != nil { listed = (try? FileManager.default.contentsOfDirectory(atPath: Favicons.folder.path)).map(Set.init) }
        for tab in tabs {
            guard tab.address?.host() != nil else { continue }
            // Yab's own pages, mail's and a task's, keep their own marks.
            tab.adoptIcon()
            fetch(for: tab)
        }
    }

    /// An icon from somewhere else, another browser's cache, at import,
    /// kept as if the site had handed it over, unless one is already here.
    func adopt(_ data: Data, for host: String) async {
        guard cached(host) == nil || frontPageIcons.contains(host),
              let image = await Favicons.square(data) else { return }
        // A live page may have supplied its own icon while decoding.
        guard cached(host) == nil || frontPageIcons.contains(host) else { return }
        memory[host] = image
        absentOnDisk.remove(host)
        listed?.insert(host + ".png")
        sources[host] = ""
        frontPageIcons.remove(host)
        Favicons.keep(image, for: host)
        arrived?(host, image)
        changes.send(host)
    }

    /// An async icon answer belongs to the document that requested it.
    /// A new navigation retires that ownership even on the same host.
    func navigationStarted(for tab: Tab) {
        asked.setObject(NSNumber(value: (asked.object(forKey: tab)?.intValue ?? 0) &+ 1), forKey: tab)
        worn.removeObject(forKey: tab)
    }

    /// Asks the page which icon it wants to be known by and does what
    /// `plan` says: wears the kept one, fetches the page's for its tab, or
    /// fetches it and keeps it as the site's. Asking is a glance at the
    /// page's head; the kept icon is worn meanwhile. `changed`: the page's
    /// script changed its icons after it loaded (IconRelay).
    func fetch(for tab: Tab, changed: Bool = false, tries: Int = 0) {
        // Until commit the live DOM is still the previous document's.
        // Reading it under the destination's URL would cache that old icon
        // as the new page's, even after retiring earlier request tickets.
        guard !tab.awaitingDocumentMetadata,
              let url = tab.address, let host = Favicons.site(url),
              url.scheme?.hasPrefix("http") == true
        else { return }
        tab.countIconFetchStarted()
        let dark = Favicons.dark
        let ticket = (asked.object(forKey: tab)?.intValue ?? 0) &+ 1
        asked.setObject(NSNumber(value: ticket), forKey: tab)
        // In Yab's world, where IconRelay wrote down the icons the page
        // came with, for `set`.
        tab.page.run(Favicons.probe, in: .yab, gesture: false) { [weak self, weak tab] result in
            MainActor.assumeIsolated {
                guard let self, let tab, self.latest(ticket, of: tab) else { return }
                let declared = ((try? result.get()) as? [[String: String]]) ?? []
                // In the dark, a dark variant the site offers is its own
                // icon, kept apart from the light one.
                let offersDark = declared.contains { Favicons.media($0["media"]) == .dark }
                let wantDark = dark && offersDark
                let key = Favicons.key(host, dark: wantDark)
                let candidates = Favicons.rank(declared, page: url, dark: wantDark)
                // A page that declares none, a PDF or an error, names only
                // the file at the root every site is guessed to have.
                let names = declared.isEmpty ? nil : candidates.first?.absoluteString
                // One the page's script put in after it loaded is its own
                // state, Notion's page icon, even asked at the load's end:
                // it doesn't take the place of the icon kept for the site.
                let scripted = changed || (names != nil && declared.contains {
                    $0["set"] == "1" && $0["href"].flatMap { Favicons.address($0)?.absoluteString } == names
                })
                // The kept icon's file, where it came from and its age are
                // read off the main thread, and the plan made back on it.
                let inMemory = self.memory[key]
                let readImage = inMemory == nil && !self.absentOnDisk.contains(key)
                let knownSource = self.sources[key]
                Task { [weak self, weak tab] in
                    let disk = await Favicons.look(key, image: readImage, source: knownSource == nil)
                    guard let self, let tab, self.latest(ticket, of: tab), tab.address.flatMap(Favicons.site) == host else { return }
                    var kept = self.memory[key] ?? inMemory
                    if kept == nil, readImage {
                        if let image = disk.image { self.memory[key] = image; kept = image } else { self.absentOnDisk.insert(key) }
                    }
                    let source = self.sources[key] ?? knownSource ?? disk.source ?? ""
                    self.sources[key] = source
                    self.follow(Favicons.plan(kept: kept != nil, source: source, fresh: disk.fresh, names: names,
                                              changed: scripted, shy: tab.shy, rechecked: self.rechecked.contains(key)),
                                tab: tab, url: url, host: host, key: key, dark: wantDark, kept: kept, candidates: candidates,
                                names: names, changed: changed, tries: tries, ticket: ticket)
                }
            }
        }
    }

    /// Whether `ticket` is the tab's latest ask (`asked`).
    private func latest(_ ticket: Int, of tab: Tab) -> Bool {
        asked.object(forKey: tab)?.intValue == ticket
    }

    /// The kept icon's file read as `known` reads it, where it came from as
    /// `source` reads it, and whether it is under a week old, off the main
    /// thread. Only what is asked for is read.
    nonisolated static func look(_ key: String, image: Bool, source: Bool) async -> (image: NSImage?, source: String?, fresh: Bool) {
        await Task.detached(priority: .utility) { () -> (NSImage?, String?, Bool) in
            MainBudget.chunk("favicon.look") {
                let file = Favicons.file(key)
                return (image ? NSImage(contentsOf: file) : nil, source ? (Favicons.source(of: file) ?? "") : nil, Favicons.fresh(key))
            }
        }.value
    }

    /// What `plan` said, done for the tab.
    private func follow(_ plan: Plan, tab: Tab, url: URL, host: String, key: String, dark: Bool, kept: NSImage?,
                        candidates: [URL], names: String?, changed: Bool, tries: Int, ticket: Int) {
        // The page no longer names an icon of its own: the site's goes on
        // it, kept now or arriving (`worn`).
        if plan != .own { worn.removeObject(forKey: tab) }
        switch plan {
        case .wear:
            tab.icon = kept
            tab.countIconLoaded()
            // The page's too, for its tab and rows before it is next in:
            // the site's icon may become another page's (`plan`'s week).
            if let kept { remember(kept, page: url, dark: dark, shy: tab.shy) }
        case .own:
            self.wearOwn(candidates, on: tab, at: url, dark: dark, otherwise: kept, refresh: changed, ticket: ticket)
        case .keep:
            guard !self.busy.contains(host) else {
                // Another icon of the site on its way, a front
                // page's offer say: asked again once it is in,
                // for what it is.
                guard tries < 5 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.fetch(for: tab, changed: changed, tries: tries + 1)
                }
                return
            }
            guard Favicons.asks(missed: self.missed[host], names: names, changed: changed) else { return }
            self.busy.insert(host)
            Task { [weak self, weak tab, weak web = tab.page] in
                guard let self else { return }
                await self.download(candidates, host: host, key: key, source: names ?? "", refresh: true, page: web)
                // The site's new icon is this page's: worn and kept as its
                // own, over what the page wore before (`arrived` leaves a
                // page wearing what it last wore).
                guard let tab, self.latest(ticket, of: tab), tab.address.flatMap(Favicons.page) == Favicons.page(url),
                      let image = self.memory[key] else { return }
                tab.icon = image
                tab.countIconLoaded()
                self.remember(image, page: url, dark: dark, shy: tab.shy)
            }
        }
    }

    enum Plan: Equatable {
        /// The kept icon.
        case wear
        /// The page's, fetched for its tab only.
        case own
        /// The page's, fetched and kept as the site's, for its every tab,
        /// its bookmark and its row under the field.
        case keep
    }

    /// What a page's tab wears, from what the page names first (`names`,
    /// nil for none) and what is kept for its site: the address that was
    /// fetched for (`source`, "" when no page named it), and whether it is
    /// under a week old. The page's icon becomes the site's only where the
    /// site has none, or one a front page offered (Drive's G), or one a
    /// week old, and never from a private tab or a script's change after
    /// load. Otherwise a page naming another icon wears it on its own tab:
    /// a pull request's state on github.com, a Sheet's on docs.google.com,
    /// Calendar's new day, a private page's unread count.
    ///
    /// An icon written into the page (`data:`, or a `blob:` its script
    /// made) is that page's alone, even where the site has none kept:
    /// Notion's emoji is one page's, and kept for notion.so it would go on
    /// every Notion tab, its bookmarks and its row under the field.
    nonisolated static func plan(kept: Bool, source: String, fresh: Bool, names: String?,
                                 changed: Bool, shy: Bool, rechecked: Bool) -> Plan {
        if let names, Favicons.written(names) { return .own }
        guard kept else { return shy ? .own : .keep }
        // A root icon still ages when the page has no <link>. A PDF or
        // error page must not replace a named site icon with that root.
        if !shy, !changed, !rechecked,
           (names != nil && (source.isEmpty || !fresh)) || (names == nil && source.isEmpty && !fresh) { return .keep }
        guard let names else { return .wear }
        return source == names && !changed ? .wear : .own
    }

    /// Whether a page's icon is fetched to be kept, given what its site's
    /// pages named and missed this session (`missed`, "" for a page naming
    /// none). Not again for a name that missed: a quiet browser doesn't ask
    /// a site over and over for an icon it hasn't got. But a page naming an
    /// icon is asked even after one naming none missed the root file: a
    /// bot check's page (Dribbble's AWS one) or a sign-in's names nothing,
    /// and the page it lets through names the site's icon. A script's
    /// change after load (`changed`) is always asked.
    nonisolated static func asks(missed: Set<String>?, names: String?, changed: Bool) -> Bool {
        changed || !(missed ?? []).contains(names ?? "")
    }

    /// A page's own icon on its tab alone, fetched once a session for every
    /// page that names it; the kept one if it can't be had. A private tab's
    /// is fetched for it and kept nowhere.
    ///
    /// One already had this session is worn again without asking, a
    /// script's change too: a page that switches between two icons (an
    /// unread count, a timer's) is followed at every switch, as Chromium
    /// and Arc follow it, and fetches each only once. `refresh`, a
    /// script's change, asks again for one that failed.
    private func wearOwn(_ candidates: [URL], on tab: Tab, at page: URL, dark: Bool, otherwise kept: NSImage?, refresh: Bool = false,
                         ticket: Int) {
        guard let first = candidates.first else { return }
        // An icon written into the page is its own address, up to a
        // quarter of a megabyte: held by its hash instead.
        let address = Favicons.inline(first) ? "data#\(first.absoluteString.hashValue)" : first.absoluteString
        if let hit = own[address] { wear(hit, own: true, on: tab, page: page, dark: dark); return }
        guard refresh || !ownFailed.contains(address) else {
            if let kept { wear(kept, own: false, on: tab) }
            return
        }
        let shy = tab.shy
        Task { [weak self, weak tab, weak web = tab.page] in
            let image = await Favicons.first(of: candidates, page: web, refresh: refresh)
            guard let self else { return }
            if !shy {
                if let image {
                    own[address] = image
                    ownFailed.remove(address)
                } else {
                    if ownFailed.count >= 1_000 { ownFailed.removeAll(keepingCapacity: true) }
                    ownFailed.insert(address)
                }
            }
            // Still on that page, and nothing newer asked for since.
            guard let tab, latest(ticket, of: tab), let now = tab.address,
                  Favicons.page(now) == Favicons.page(page) else { return }
            if let image { wear(image, own: true, on: tab, page: page, dark: dark) } else if let kept { wear(kept, own: false, on: tab) }
        }
    }

    /// `page`: the page that named it, which keeps it as its own
    /// (`remember`). One that couldn't be had keeps what it wore.
    private func wear(_ image: NSImage, own: Bool, on tab: Tab, page: URL? = nil, dark: Bool = false) {
        tab.icon = image
        tab.countIconLoaded()
        if own { worn.setObject(image, forKey: tab) } else { worn.removeObject(forKey: tab) }
        if own, let page { remember(image, page: page, dark: dark, shy: tab.shy) }
    }

    /// A site's icon with no page of it open to ask: the icons its front
    /// page declares, read from the page's own markup rather than run, and
    /// ranked as a tab's are, so it is the crisp one, not the 16-pixel
    /// file at the root, which comes last. For the rows under the field: a
    /// place offered there wears its own icon, not a letter, even before it
    /// has ever been open. Once per site: kept on disk after, and a site
    /// without one is not asked again this session. `again`: asked even
    /// with one kept, which stays if nothing is found.
    func fetch(host: String, again: Bool = false) {
        guard let page = URL(string: "https://\(host)/") else { return }
        fetch(page: page, again: again)
    }

    /// A cold tab's front page, on the same scheme and port as the tab.
    /// No path, query, fragment or credentials from the restored page goes
    /// into the request. A custom or private tab never calls this path.
    func fetch(page: URL, again: Bool = false) {
        guard let page = Favicons.front(of: page), let host = Favicons.site(page),
              again || cached(host) == nil, !busy.contains(host), !queued.contains(host),
              again || (missed[host] == nil && !unfound.contains(host))
        else { return }
        queued.insert(host)
        guesses.append((page, again))
        guessNext()
    }

    /// An explicit refresh asks only for the site's public origin, never
    /// wakes its tab, and keeps custom marks and private pages untouched.
    static func canRefresh(_ tab: Tab) -> Bool {
        guard !tab.shy, tab.customMark == nil, let page = tab.address else { return false }
        return front(of: page) != nil
    }

    func refresh(_ tab: Tab) {
        guard Self.canRefresh(tab), let page = tab.address else { return }
        if let site = Favicons.site(page) { forgetPages(of: site) }
        fetch(page: page, again: true)
    }

    private func guessNext() {
        while guessing < Favicons.guessLimit, !guesses.isEmpty {
            let (page, again) = guesses.removeFirst()
            guard let host = Favicons.site(page) else { continue }
            queued.remove(host)
            // An import may have adopted this site's bitmap while its
            // lookup waited behind the other cold tabs. Waiting guesses
            // don't reserve busy: a page waking up gets to go first.
            guard !busy.contains(host), again || cached(host) == nil else { continue }
            busy.insert(host)
            guessing += 1
            Task {
                defer { guessing -= 1; busy.remove(host); guessNext() }
                let (declared, landed) = await Favicons.declared(on: page, refresh: again)
                guard again || cached(host) == nil else { return }
                await download(Favicons.offered(declared, page: page, landed: landed) + Favicons.signedOut(host),
                               host: host, key: host, source: "", guessed: true, replace: again, refresh: again)
            }
        }
    }

    nonisolated static func front(of url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// An icon at an address known beforehand, kept under a name of its
    /// own: Docs, Sheets and Slides share docs.google.com, whose front page
    /// fetched with no cookies offers Drive's.
    func fetch(_ icon: URL, as key: String) {
        guard cached(key) == nil, !busy.contains(key), !unfound.contains(key) else { return }
        busy.insert(key)
        Task { await download([icon], host: key, key: key, source: icon.absoluteString, guessed: true) }
    }

    /// The icon of a site whose front page, fetched with no cookies, names
    /// none of its own: Calendar sends it to Workspace's page, and Settings'
    /// tables (skills, Buttons on Sites) showed its letter. Its own icon,
    /// today's date on it as its tab wears, until a page of it is open.
    nonisolated static func signedOut(_ host: String) -> [URL] {
        switch host {
        case "calendar.google.com":
            let day = Calendar.current.component(.day, from: Date())
            return [URL(string: "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_\(day).ico")].compactMap { $0 }
        default: return []
        }
    }

    /// The icons a front page fetched with no tab of it open offers for the
    /// host asked, best first. A front page that sends a browser without
    /// cookies to another host, a sign-in (accounts.google.com) or a page
    /// about the product (workspace.google.com for Drive), declares that
    /// host's icon: Drive and Calendar kept Google's G that way, and their
    /// tabs wore it for a week. From another host only an icon whose
    /// address names the site is taken, Maps' on www.google.com, Notion's on
    /// notion.com for notion.so, and the asked host's own /favicon.ico,
    /// which is Drive's; Calendar has none, and takes its own from
    /// signedOut until a page of it is open.
    nonisolated static func offered(_ declared: [[String: String]], page: URL, landed: URL?) -> [URL] {
        guard let asked = page.host()?.lowercased(), let there = landed?.host()?.lowercased(),
              bare(asked) != bare(there)
        else { return rank(declared, page: page, dark: false) }
        let name = words(bare(asked).split(separator: ".").first.map(String.init) ?? "")
        let named = name.joined().count < 3 ? [] : declared.filter { entry in
            guard let url = entry["href"].flatMap({ Favicons.address($0) }) else { return false }
            return name.isSubset(of: words(url.host() ?? "")) || name.isSubset(of: words(url.lastPathComponent))
        }
        return rank(named, page: page, dark: false)
    }

    /// A host's or a file name's words, cut wherever there is no letter:
    /// maps15_bnuw3a_32dp.ico has maps in it, apple-touch-icon.png has no
    /// app, so an app. host sent to a sign-in elsewhere takes nothing of it.
    nonisolated static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init))
    }

    /// A host without its www., the same site either way.
    nonisolated static func bare(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Once, for what was kept before `offered`: Google's G under the hosts
    /// of its products. An icon two of Google's hosts keep byte for byte is
    /// that G, and goes, but where it is the host's own (`sharedG`). The
    /// products Yab asks after at launch are asked again now, each keeping
    /// what it had if its front page still offers nothing. The hosts whose
    /// G went, for their tabs to take it off.
    @discardableResult
    func tidy(settings: UserDefaults = Store.settings) -> Set<String> {
        guard !settings.bool(forKey: Favicons.tidied) else { return [] }
        settings.set(true, forKey: Favicons.tidied)
        var gone: Set<String> = []
        for key in Favicons.sharedG(in: Favicons.folder) {
            try? FileManager.default.removeItem(at: Favicons.file(key))
            listed?.remove(key + ".png")
            memory[key] = nil
            sources[key] = nil
            absentOnDisk.insert(key)
            gone.insert(key.hasSuffix("@dark") ? String(key.dropLast(5)) : key)
        }
        for host in History.knownHosts where host.hasSuffix(".google.com") {
            fetch(host: host, again: true)
        }
        return gone
    }

    static let tidied = "icons.googleTidied"

    /// Once a day, a little after launch: the icons of sites long gone from
    /// the disk (`stale`). `keep`: the sites of every tab, open, kept or
    /// pinned, every bookmark's, and those the field knows from the start;
    /// `visited`: each site's last visit. The listing, the dates and the
    /// removing are off the main thread. How many went.
    @discardableResult
    func prune(keep: [URL], visited: [String: Date], settings: UserDefaults = Store.settings, now: Date = Date()) async -> Int {
        if let last = settings.object(forKey: Favicons.pruned) as? Date, now.timeIntervalSince(last) < 86_400 { return 0 }
        settings.set(now, forKey: Favicons.pruned)
        let hosts = Set(keep.compactMap(Favicons.site) + History.knownHosts)
        let folder = Favicons.folder
        let gone = await Task.detached(priority: .utility) { () -> [String] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let dated = files.filter { $0.pathExtension == "png" }.map {
                (key: $0.deletingPathExtension().lastPathComponent,
                 date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now)
            }
            let gone = Favicons.stale(dated, keep: hosts, visited: visited, now: now)
            for key in gone { try? FileManager.default.removeItem(at: Favicons.file(key)) }
            return gone
        }.value
        for key in gone {
            listed?.remove(key + ".png")
            memory[key] = nil
            sources[key] = nil
            absentOnDisk.insert(key)
        }
        return gone.count
    }

    static let pruned = "icons.pruned"
    nonisolated static let staleDays: Double = 90

    /// Which kept icons go: those last fetched over `staleDays` ago, of a
    /// site not visited since then and not in `keep`. Sites are matched
    /// without "www." and a dark variant goes with its site.
    nonisolated static func stale(_ files: [(key: String, date: Date)], keep: Set<String>, visited: [String: Date], now: Date) -> [String] {
        func site(_ key: String) -> String { bare(key.hasSuffix("@dark") ? String(key.dropLast(5)) : key) }
        let kept = Set(keep.map(site))
        let since = now.addingTimeInterval(-staleDays * 86_400)
        return files.filter { file in
            let host = site(file.key)
            // History keeps a visit under the host alone (Address.pretty).
            let visit = visited[host] ?? host.split(separator: ":").first.flatMap { visited[String($0)] }
            return file.date < since && !kept.contains(host) && (visit ?? .distantPast) < since
        }.map(\.key)
    }

    /// The icons kept for Google's hosts that are the G they share: the
    /// same bytes under two hosts or more, a G drawn from one file. Not the
    /// G of google.com and its sign-in pages, whose own icon it is.
    nonisolated static func sharedG(in folder: URL) -> [String] {
        func host(_ key: String) -> String { key.hasSuffix("@dark") ? String(key.dropLast(5)) : key }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var keys: [Data: [String]] = [:]
        for file in files where file.pathExtension == "png" {
            let key = file.deletingPathExtension().lastPathComponent
            guard host(key) == "google.com" || host(key).hasSuffix(".google.com"),
                  let data = try? Data(contentsOf: file)
            else { continue }
            keys[data, default: []].append(key)
        }
        let owners: Set<String> = ["google.com", "www.google.com", "accounts.google.com", "myaccount.google.com"]
        return keys.values.filter { $0.count > 1 }.joined().filter { !owners.contains(host($0)) }.sorted()
    }

    /// Public icon lookups never share a cookie jar with other small fetches
    /// (including private artwork). Keep the ordinary in-memory HTTP cache.
    private static let publicFetcher: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// The icons a page's markup declares, as the probe would find them:
    /// each `<link>` whose rel names an icon, its address made whole; and
    /// the address the page came from in the end.
    private static func declared(on page: URL, refresh: Bool = false) async -> ([[String: String]], URL?) {
        var request = URLRequest(url: page, cachePolicy: refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
                                 timeoutInterval: 8)
        // No cookies, not even the ones its own redirects set: in Europe
        // Maps sent through Google's consent page with them landed there,
        // on Google's G, and without them comes back to Maps.
        request.httpShouldHandleCookies = false
        // The page a browser is sent, not the one a script is.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await publicFetcher.data(for: request),
              let html = String(data: data.prefix(1_000_000), encoding: .utf8)
        else { return ([], nil) }
        let base = response.url ?? page
        let found = await Task.detached(priority: .utility) { () -> [[String: String]] in
            guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
                  let attribute = try? NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
            else { return [] }
            var out: [[String: String]] = []
            let whole = NSRange(html.startIndex..., in: html)
            for match in tag.matches(in: html, range: whole) {
                guard let range = Range(match.range, in: html) else { continue }
                let text = String(html[range])
                var fields: [String: String] = [:]
                for pair in attribute.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let name = Range(pair.range(at: 1), in: text) else { continue }
                    let value = (2...4).lazy.compactMap { Range(pair.range(at: $0), in: text) }.first.map { String(text[$0]) } ?? ""
                    fields[text[name].lowercased()] = value.replacingOccurrences(of: "&amp;", with: "&")
                }
                let rel = (fields["rel"] ?? "").lowercased()
                guard rel.contains("icon"), let href = fields["href"],
                      let url = URL(string: href, relativeTo: base)?.absoluteURL
                else { continue }
                out.append([
                    "href": url.absoluteString, "rel": rel,
                    "sizes": (fields["sizes"] ?? "").lowercased(),
                    "type": (fields["type"] ?? "").lowercased(),
                    "media": (fields["media"] ?? "").lowercased(),
                ])
            }
            return out
        }.value
        return (found, response.url)
    }

    enum Scheme { case any, light, dark }

    /// What a `media` attribute says about the scheme, if anything.
    nonisolated static func media(_ value: String?) -> Scheme {
        let text = (value ?? "").lowercased()
        if text.contains("prefers-color-scheme") {
            if text.contains("dark") { return .dark }
            if text.contains("light") { return .light }
        }
        return .any
    }

    /// The first of the candidates that is a picture, kept as the site's
    /// and put on its every tab. `source`: the address the page named, ""
    /// for a front page's offer or a page that named none, which the next
    /// page that names one asks after again. `guessed`: a front page's
    /// offer (`fetch(host:)`), not a page's own.
    private func download(_ candidates: [URL], host: String, key: String, source: String, guessed: Bool = false, replace: Bool = true, refresh: Bool = false,
                          page: (any PageHandle)? = nil) async {
        defer { busy.remove(host) }
        // An icon written into a page is that page's (`plan`), and never
        // the site's: not on disk, not on its other tabs.
        let candidates = candidates.filter { !Favicons.written($0.absoluteString) }
        guard let image = await Favicons.first(of: candidates, page: page, refresh: refresh) else {
            // Not asked again this session: hammering a site for an icon it
            // doesn't have is exactly the kind of thing a quiet browser
            // doesn't do. A front page's offer only stops the guessing: a
            // page of the site may name one. One kept stays worn.
            if guessed {
                unfound.insert(host)
            } else if known(key) != nil {
                rechecked.insert(key)
            } else {
                // The root file is the last of every page's candidates, so
                // a page naming one missed the guess too.
                missed[host, default: []].formUnion(source.isEmpty ? [""] : [source, ""])
            }
            return
        }
        // A browser import or a live page is more specific than a cold
        // front-page guess that was already in flight when it arrived.
        guard replace || cached(key) == nil else { return }
        memory[key] = image
        absentOnDisk.remove(key)
        listed?.insert(key + ".png")
        sources[key] = source
        if guessed { frontPageIcons.insert(key) } else { frontPageIcons.remove(key) }
        Favicons.keep(image, for: key, from: source)
        arrived?(host, image)
        changes.send(host)
    }

    private static func first(of candidates: [URL], page: (any PageHandle)? = nil, refresh: Bool = false) async -> NSImage? {
        for candidate in candidates {
            if Favicons.inline(candidate) {
                if let data = Favicons.inlineBytes(candidate.absoluteString), let image = await Favicons.square(data) { return image }
                continue
            }
            // A blob: exists only in its page, which reads it for Yab.
            if Favicons.written(candidate.absoluteString) {
                if let page, let data = await Favicons.fromPage(candidate, in: page), let image = await Favicons.square(data) { return image }
                continue
            }
            var request = URLRequest(url: candidate, cachePolicy: refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
                                     timeoutInterval: 8)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await publicFetcher.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count > 60, data.count < 2_000_000
            else { continue }
            if let image = await Favicons.square(data) { return image }
        }
        // A site behind a bot check (ChatGPT's Cloudflare) answers a fetch
        // with no cookies by its challenge page, 403, for its icons too
        // (feedback #150): the page that got through asks for its own, with
        // the cookie that let it through. Its own site's icons only.
        guard let page, let site = page.url?.host()?.lowercased() else { return nil }
        for candidate in candidates where candidate.host()?.lowercased() == site {
            guard let data = await Favicons.fromPage(candidate, in: page) else { continue }
            if let image = await Favicons.square(data) { return image }
        }
        return nil
    }

    /// An icon fetched by the page itself, in Yab's own script world: its
    /// cookies, not its scripts. Nil for an error, a refusal or a file not
    /// the size of an icon.
    private static func fromPage(_ icon: URL, in page: any PageHandle) async -> Data? {
        let script = """
        const r = await fetch(u, {credentials: 'include'});
        if (!r.ok) return null;
        const b = new Uint8Array(await r.arrayBuffer());
        if (b.length <= 60 || b.length >= 2000000) return null;
        let s = '';
        for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
        return btoa(s);
        """
        let answer = await withCheckedContinuation { (got: CheckedContinuation<Any?, Never>) in
            page.call(script, arguments: ["u": icon.absoluteString], in: .client, gesture: false) { got.resume(returning: try? $0.get()) }
        }
        guard let text = answer as? String else { return nil }
        return Data(base64Encoded: text)
    }

    /// Decoded and drawn into a square off the main thread, an .ico can hold
    /// a dozen sizes and take a moment to unpack. Nil for a picture that
    /// draws nothing: ChatGPT's favicon.svg colors its knot from a <style>
    /// (`:root { fill: #000 }`, white in the dark), which the Mac's SVG
    /// drawing ignores, so it came out empty, was kept as the site's icon
    /// and put on every tab of it, a pin wearing no mark at all (feedback
    /// #368). The next icon the page names is taken instead.
    static func square(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            if let glyph = Favicons.glyph(inSVG: data) {
                let side: CGFloat = 64
                let out = NSImage(size: NSSize(width: side, height: side))
                out.lockFocus()
                let text = glyph as NSString
                let font = NSFont.systemFont(ofSize: side * 0.82)
                let size = text.size(withAttributes: [.font: font])
                text.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: [.font: font])
                out.unlockFocus()
                return Favicons.blank(out) ? nil : out
            }
            guard let image = NSImage(data: data), image.isValid,
                  image.size.width > 0, image.size.height > 0
            else { return nil }
            let side: CGFloat = 64
            let out = NSImage(size: NSSize(width: side, height: side))
            out.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            let scale = min(side / image.size.width, side / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            image.draw(
                in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            out.unlockFocus()
            return Favicons.blank(out) ? nil : out
        }.value
    }

    /// Whether a picture draws nothing that can be seen: every pixel clear,
    /// or as good as, drawn small.
    nonisolated static func blank(_ image: NSImage) -> Bool {
        let side = 32
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return false }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        return !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 12 }
    }

    /// Once, for what was kept before `blank` was asked: the icons that draw
    /// nothing go from the disk and from memory, off the main thread, so a
    /// tab wearing one shows its letter and its page fetches the icon
    /// again. The hosts whose icon went.
    @discardableResult
    func unblank(settings: UserDefaults = Store.settings) async -> Set<String> {
        guard !settings.bool(forKey: Favicons.unblanked) else { return [] }
        settings.set(true, forKey: Favicons.unblanked)
        let folder = Favicons.folder
        let gone = await Task.detached(priority: .utility) { () -> [String] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var gone: [String] = []
            for file in files where file.pathExtension == "png" {
                guard let image = NSImage(contentsOf: file), Favicons.blank(image) else { continue }
                try? FileManager.default.removeItem(at: file)
                gone.append(file.deletingPathExtension().lastPathComponent)
            }
            return gone
        }.value
        var hosts: Set<String> = []
        for key in gone {
            listed?.remove(key + ".png")
            memory[key] = nil
            sources[key] = nil
            absentOnDisk.insert(key)
            hosts.insert(key.hasSuffix("@dark") ? String(key.dropLast(5)) : key)
        }
        return hosts
    }

    static let unblanked = "icons.blankTidied"

    private static let writing = DispatchQueue(label: "favicon.keep", qos: .utility)

    private static func keep(_ image: NSImage, for key: String, from source: String = "") {
        let folder = Favicons.folder
        let file = Favicons.file(key)
        // The encoding too: an import hands over hundreds at once.
        // Preserve arrival order when an imported bitmap supersedes a
        // front-page guess; the newer icon must also be the one on disk.
        writing.async {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? png.write(to: file, options: .atomic)) != nil, !source.isEmpty else { return }
            mark(file, source: source)
        }
    }

    /// Best first. A crisp icon around 32–64 pixels is what a tab wants; the
    /// touch icon is a fine second; the file at the root is the fallback every
    /// site has had since 1999.
    ///
    /// An icon written into the page itself (`data:`, or a canvas's `blob:`)
    /// is one its script drew for this page: Notion's page emoji, a count.
    /// It goes first, ahead of a touch icon the site serves every page, and
    /// costs no request to the site; a `data:` one only in a picture's types,
    /// and not over `inlineLimit`. One the page's
    /// script put in after it loaded (`set`, IconRelay's) goes before all:
    /// the page wants to be known by it now, the generic files are the
    /// site's.
    nonisolated static func rank(_ declared: [[String: String]], page: URL, dark: Bool) -> [URL] {
        var scored: [(URL, Int)] = []
        for entry in declared {
            guard let href = entry["href"], let url = Favicons.address(href) else { continue }
            let written = Favicons.written(href)
            guard inline(url) ? inlineType(href) != nil && href.utf8.count <= inlineLimit : written || url.scheme?.hasPrefix("http") == true
            else { continue }
            let rel = entry["rel"] ?? ""
            let sizes = entry["sizes"] ?? ""
            let type = entry["type"] ?? ""
            // An icon meant for the other scheme is the last resort; one
            // meant for this scheme comes first whatever its size.
            let scheme = media(entry["media"])
            if scheme == (dark ? .light : .dark) { continue }
            var score = 25
            if rel.contains("apple-touch") { score = 40 }
            if let px = sizes.split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 10
                case 24..<48: score = 45
                case 48..<128: score = 50
                case 128..<260: score = 42
                default: score = 20
                }
            }
            if sizes == "any" || type.contains("svg") || (!written && url.pathExtension.lowercased() == "svg") { score = 35 }
            if written { score = 60 }
            if scheme != .any { score += 40 }
            if entry["set"] == "1", !rel.contains("apple-touch"), !rel.contains("mask") { score += 100 }
            scored.append((url, score))
        }
        var list = scored.sorted { $0.1 > $1.1 }.map(\.0)
        if let front = front(of: page) {
            list.append(front.appendingPathComponent("favicon.ico"))
        }
        // The same address twice is a wasted request.
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }

    /// The longest icon written into a page that is taken, its address as
    /// long as its bytes: Notion's emoji is a few hundred.
    nonisolated static let inlineLimit = 256 * 1024
    nonisolated private static let inlineTypes: Set<String> = [
        "image/svg+xml", "image/png", "image/x-icon", "image/vnd.microsoft.icon", "image/gif", "image/jpeg", "image/webp",
    ]

    /// A `data:` address's picture type, nil for any other address or a
    /// type that isn't a picture an icon comes in (a page, a script).
    nonisolated static func inlineType(_ address: String) -> String? {
        guard address.prefix(5).lowercased() == "data:", let comma = address.firstIndex(of: ",") else { return nil }
        let head = address[address.index(address.startIndex, offsetBy: 5)..<comma].lowercased()
        let type = (head.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .removingPercentEncoding?.trimmingCharacters(in: .whitespaces) ?? ""
        return inlineTypes.contains(type) ? type : nil
    }

    nonisolated static func inline(_ url: URL) -> Bool { url.scheme?.lowercased() == "data" }

    /// Whether an icon's address is one its page wrote for itself: a
    /// `data:` picture, or a `blob:` its script made (a canvas's, Chrome and
    /// Arc wear it), which only that page can read. Never the site's.
    nonisolated static func written(_ address: String) -> Bool {
        let scheme = address.prefix(5).lowercased()
        return scheme == "data:" || scheme == "blob:"
    }

    /// A page's icon href as a URL. A `data:` one is often written bare
    /// (`<svg …>` with spaces and quotes) beside escapes it already has
    /// (`%F0%9F%9A%80`); URL(string:) escaping the bare characters escaped
    /// those `%` too, and the picture came back unreadable. Here only what
    /// isn't allowed is escaped and `%` stays, so reading undoes it exactly.
    nonisolated static func address(_ href: String) -> URL? {
        guard href.prefix(5).lowercased() == "data:" else { return URL(string: href) }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "%#")
        return href.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: $0) }
    }

    /// The bytes of an icon written into the page, read here and never
    /// fetched: base64 or percent-escaped, the fragment a browser ignores
    /// left off. Nil for one not a picture or over `inlineLimit`. The
    /// address as URL has it, which may have escaped what the page left
    /// bare (`<`, a space), three bytes for one.
    nonisolated static func inlineBytes(_ address: String) -> Data? {
        guard inlineType(address) != nil, address.utf8.count <= inlineLimit * 3,
              let comma = address.firstIndex(of: ",") else { return nil }
        let head = address[..<comma].lowercased()
        var body = address[address.index(after: comma)...]
        if let hash = body.firstIndex(of: "#") { body = body[..<hash] }
        guard let text = String(body).removingPercentEncoding else { return nil }
        let data: Data? = head.hasSuffix(";base64")
            ? Data(base64Encoded: text.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters)
            : Data(text.utf8)
        guard let data, !data.isEmpty, data.count <= inlineLimit else { return nil }
        return data
    }

    /// The one character an SVG is drawn of, an emoji in a `<text>`
    /// (`<svg ...><text y=".9em" font-size="90">🚀</text></svg>`), the way
    /// pages turn an emoji into an icon. The Mac's SVG drawing leaves text
    /// out, and such an icon came out empty: it is drawn as text instead.
    /// Nil for an SVG with shapes, or text of more than a few characters.
    nonisolated static func glyph(inSVG data: Data) -> String? {
        guard data.count < 8_192, let svg = String(data: data, encoding: .utf8), svg.contains("<svg"),
              let open = svg.range(of: "<text"), let start = svg[open.upperBound...].firstIndex(of: ">"),
              let close = svg.range(of: "</text>", range: start..<svg.endIndex)
        else { return nil }
        let shapes = ["<path", "<rect", "<circle", "<ellipse", "<polygon", "<polyline", "<line", "<image", "<use"]
        guard !shapes.contains(where: { svg.contains($0) }) else { return nil }
        var text = String(svg[svg.index(after: start)..<close.lowerBound])
        if text.contains("<") { text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression) }
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 3 else { return nil }
        return text
    }

    private static let probe = """
    (function () {
      var out = [], born = window.__yabIconBorn;
      var links = document.querySelectorAll('link[rel]');
      for (var i = 0; i < links.length; i++) {
        var l = links[i];
        var rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') < 0) continue;
        out.push({
          href: l.href,
          rel: rel,
          sizes: (l.getAttribute('sizes') || '').toLowerCase(),
          type: (l.getAttribute('type') || '').toLowerCase(),
          media: (l.getAttribute('media') || '').toLowerCase(),
          set: born && !born[l.href] ? '1' : ''
        });
      }
      return out;
    })();
    """
}

/// A page's icons changed by its script once it loaded, heard in Yab's
/// world and told when they settle: Calendar draws the day into its icon
/// after the page is up, Gmail and chats change theirs with what's unread.
/// Worn by that tab alone (`Favicons.plan`). Every change is told, as
/// Chrome's tab follows each one its page makes (FaviconDriver hears every
/// new list of icons from Blink): a timer's or a count's icon each second,
/// Notion's page icon as it goes from page to page without loading one.
/// It was told at most every 30 seconds, so a blinking icon wasn't fetched
/// with every blink; an icon had once this session is worn again from
/// memory instead (`Favicons.wearOwn`), and a page changing its icons
/// without pause is told at most every `settle` milliseconds.
/// The icons the page came with are written down (`__yabIconBorn`), for
/// the probe to tell them from those its script put in.
final class IconRelay: NSObject, PageScriptReceiving {
    static let name = "yabIcon"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard message.frame.isMain else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            if let snapshot = message.body as? [String: String],
               let title = snapshot["title"], let icon = snapshot["icon"] {
                tab.observedCountIcon(title: title, icon: icon)
            } else {
                Favicons.shared.fetch(for: tab, changed: true)
            }
        }
    }

    /// How long a change waits to be told, in milliseconds: a moment for it
    /// to settle, a page's new icon often coming in two steps (the old link
    /// out, the new one in).
    static let settle = 250

    static let script = """
    (function () {
      var h = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!h || window.__yabIcons || !document.head) return;
      window.__yabIcons = true;
      function icons() {
        var out = [], links = document.querySelectorAll('link[rel]');
        for (var i = 0; i < links.length; i++) {
          var rel = (links[i].getAttribute('rel') || '').toLowerCase();
          if (rel.indexOf('icon') >= 0) out.push(rel + ' ' + links[i].href + ' ' + (links[i].getAttribute('media') || ''));
        }
        return out.join('\\n');
      }
      function linked(nodes) {
        for (var i = 0; i < nodes.length; i++) if (nodes[i].nodeName === 'LINK') return true;
        return false;
      }
      var born = Object.create(null), first = document.querySelectorAll('link[rel]');
      for (var b = 0; b < first.length; b++) {
        if ((first[b].getAttribute('rel') || '').toLowerCase().indexOf('icon') >= 0) born[first[b].href] = true;
      }
      window.__yabIconBorn = born;
      // Observe title and icon together in the same mutation delivery, not
      // the engine's independently scheduled title event and icon download.
      // No settling delay: revoke permission before a new icon can be worn.
      var revision = 0, proof = '';
      function prove() {
        var icon = revision + ':' + icons();
        var now = JSON.stringify([document.title, icon]);
        if (now === proof) return;
        proof = now;
        h.postMessage({ title: document.title, icon: icon });
      }
      function iconLink(node) {
        return node.nodeName === 'LINK' && /icon/i.test(node.getAttribute('rel') || '');
      }
      function iconNodes(nodes) {
        for (var i = 0; i < nodes.length; i++) {
          if (iconLink(nodes[i]) || (nodes[i].querySelectorAll &&
              Array.prototype.some.call(nodes[i].querySelectorAll('link[rel]'), iconLink))) return true;
        }
        return false;
      }
      new MutationObserver(function (records) {
        for (var i = 0; i < records.length; i++) {
          var r = records[i];
          if (r.type === 'attributes' ? iconLink(r.target) ||
              (r.target.nodeName === 'LINK' && r.attributeName === 'rel' && /icon/i.test(r.oldValue || '')) :
              r.type === 'childList' && (iconNodes(r.addedNodes) || iconNodes(r.removedNodes))) {
            // Even rewriting the same href may replace a server-side icon's
            // bytes. That is not evidence that its image stayed unchanged.
            revision++;
            break;
          }
        }
        prove();
      }).observe(document.head, { childList: true, subtree: true, characterData: true,
        attributes: true, attributeOldValue: true, attributeFilter: ['href', 'rel', 'media', 'sizes', 'type'] });
      prove();
      var seen = icons(), timer = 0;
      function tell() {
        timer = 0;
        var now = icons();
        if (now === seen) return;
        seen = now;
        h.postMessage(1);
      }
      new MutationObserver(function (records) {
        if (timer) return;
        for (var i = 0; i < records.length; i++) {
          var r = records[i];
          if (r.type === 'attributes' ? r.target.nodeName === 'LINK' : linked(r.addedNodes) || linked(r.removedNodes)) {
            timer = setTimeout(tell, \(settle));
            return;
          }
        }
      }).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel', 'media'] });
    })();
    """
}

/// What stands for a page when there is no room for its title: the site's
/// icon if there is one, and a letter in a faint square until there is.
struct Mark: View {
    let icon: NSImage?
    let letter: String
    var size: CGFloat = 16
    var dim = false
    /// Its corner: a fifth of its side, or concentric with what it stands
    /// in (a tab across the top's, less the inset all round).
    var corner: CGFloat? = nil
    @Environment(\.tone) private var tone

    var body: some View {
        Group {
            if let icon {
                // A template is one of Change Icon's icons: in the ink.
                Image(nsImage: icon)
                    .renderingMode(icon.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner ?? size * 0.22, style: .continuous))
            } else {
                Text(letter)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(Palette.muted(on: tone))
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: corner ?? size * 0.22, style: .continuous)
                            .fill(Palette.ink.opacity(0.06))
                    )
            }
        }
        .opacity(dim ? 0.45 : 1)
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}

extension URLSession {
    /// One ephemeral session for the small fetches a page sets off (icons,
    /// search descriptions, a private tab's accent art). A session made per
    /// fetch and never invalidated kept its connections, and the browser
    /// ran out of files.
    static let ephemeralFetcher = URLSession(configuration: .ephemeral)
}
