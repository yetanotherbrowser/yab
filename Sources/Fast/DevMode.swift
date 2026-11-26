import AppKit
import SwiftUI
import WebKit

// Developer Mode can be chosen for any HTTP(S) site. A page on this Mac's
// own server, localhost:3000, may be a
// page being made. yab asks, the first time one of a server's pages loads
// (a card hanging from its tab, as a site asking for the camera does), in
// the row, never in a small window or a pop-up, nor on a page a site
// elsewhere sent the tab to, a sign-in's answer to a command, and
// keeps the answer for that tab, host and port; the menu and ⌃D turn it on
// or off after. A local page's tab says its port after its name either
// way. With the mode on its card always has the address band, whether or
// not the address bar is asked for: the whole address from the band's
// start, and on the right "2 errors" when the page has any, Measure and the
// developer tools. The band is the mode's, not the address bar: back,
// forward and reload stay where the layout keeps them, in the column or at
// the row's far end, unless the address bar is up too. The word opens the
// Developer Tools card (DevTools.swift) on the page's errors (⌥⌘K), under
// the page or beside it: the errors and warnings the page has logged since
// it loaded, and its requests. The page makes room for the card, it is
// never laid over it, and it is resized once, when the card has arrived
// (StageView.hold, as for Split View).
//
// Nothing is sent anywhere. A row can be copied for an agent, as Markdown
// with its secrets taken out, or shown in WebKit's console in the card.
//
// The page is heard by a script in its own world, where its console and its
// fetch are, since yab's world can't see them being called. It hands what it
// heard over to a bridge in yab's world as a string in a DOM event, the way
// the passkeys bridge does (Passkeys.swift): a handler in the page's world
// would put `window.webkit` on every page there is, which sites read as an
// app's embedded web view (see Web.world).
//
// Built for a page that logs a million errors in a loop: in the page one
// dictionary lookup a call, the same words (numbers aside) folded into one
// row with a count, a stack taken only for a row's first time, at most 500
// kinds kept and the rest only counted, and one batch handed over every
// quarter of a second. Here a batch is parsed off the main thread and
// applied in one change.

enum DevSide: String {
    case bottom, right, left

    /// Beside the page, on either side of it.
    var beside: Bool { self != .bottom }
}

extension Address {
    /// A server on this Mac: localhost, a name under .localhost or .test,
    /// the loopback. Not the rest of the local network, where the servers
    /// are as often someone's printer as one's own work.
    static func isLocal(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test")
            || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

extension Tab {
    /// A page on this Mac's own server.
    var isLocal: Bool { Address.isLocal(address) }
    /// Only web pages can opt into Developer Mode.
    var canDev: Bool { DevSites.name(address) != nil }
    /// A site explicitly chosen for Developer Mode in this tab.
    var isDev: Bool {
        // The page's server, kept apart from its address (Tab.devServer):
        // a link to another page of the web doesn't run whoever asks.
        let server = Narrow.addressFlags ? devServer : DevSites.name(address)
        return server.map { DevSites.on(tab: id, name: $0) } ?? false
    }

    /// Sent to this page by a site elsewhere, not by you (DevSites.sentFromAfar).
    var sentFromAfar: Bool {
        let list = webKitOnly("WebKit developer document relay", build: false)?.backForwardList
        return DevSites.sentFromAfar(page: address, setOut: list?.currentItem?.initialURL,
                                     before: list?.backItem?.url, yabSent: sentLocal)
    }

    /// A page that isn't local heard while the card is out over it, this
    /// document and the ones after it; a local page always is.
    func listenDev(_ on: Bool) {
        devListening = on && !isLocal
        if devListening { hearPage() }
    }

    func hearPage() {
        guard devListening, !isLocal, let page = builtPage else { return }
        if devLog.heardFrom == nil { devLog.heardFrom = Date() }
        page.run(DevRelay.anywhere, in: .page) { _ in }
    }

    /// The port its server listens on, written out even when it is the
    /// scheme's own.
    var devPort: Int? {
        guard isLocal, let url = address else { return nil }
        return url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

// MARK: - asked, not assumed

/// Developer Mode, chosen for a tab's web host and port, and kept. The
/// server list remembers answers to automatic offers and supports the
/// explicit bulk controls in Settings. A page's choice never enables
/// another tab.
@MainActor
enum DevSites {
    private static let key = "devSites"
    private static var kept: [String: Bool] = Store.settings.dictionary(forKey: key) as? [String: Bool] ?? [:]
    private static let tabsKey = "devTabSites"
    private static var tabs: [String: [String]] = Store.settings.dictionary(forKey: tabsKey) as? [String: [String]] ?? [:]
    /// Asked this launch, answered Not Now or still up: not asked again
    /// until yab is opened next.
    static var asked: Set<String> = []

    /// A web host and port, preserving the keys already kept for local servers.
    static func name(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    /// On, off, or never answered.
    static func choice(_ url: URL?) -> Bool? { name(url).flatMap { kept[$0] } }

    static func on(tab: Tab.ID, name: String) -> Bool { tabs[tab.uuidString]?.contains(name) == true }

    static func set(tab: Tab.ID, name: String, _ on: Bool) {
        let id = tab.uuidString
        var sites = Set(tabs[id] ?? [])
        if on { sites.insert(name) } else { sites.remove(name) }
        tabs[id] = sites.isEmpty ? nil : sites.sorted()
        // A tab choice refreshes the server's remembered answer. Settings
        // can also choose it with no open tabs; new tabs never inherit it.
        kept[name] = tabs.values.contains { $0.contains(name) }
        save()
    }

    private static func save() {
        Store.settings.set(tabs, forKey: tabsKey)
        Store.settings.set(kept, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Sent to this Mac's server by a site elsewhere, not by you: a sign-in
    /// handing its answer to a command's own little server (codex login,
    /// gcloud auth login). Its redirects set out from elsewhere, or the page
    /// before it is elsewhere and yab didn't send the tab to this server.
    static func sentFromAfar(page: URL?, setOut: URL?, before: URL?, yabSent: String?) -> Bool {
        afar(setOut) || afar(before) && yabSent != name(page)
    }

    /// A site on the web, not on this Mac and not one of yab's own pages.
    private static func afar(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !Address.isLocal(url)
    }

    /// The remembered server choices, including servers with no open tab.
    /// Read the same answer Settings writes, rather than counting tab grants.
    static var servers: [(name: String, on: Bool)] {
        kept.map { (name: $0.key, on: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Said whenever a server's choice changes, from wherever.
    static let changed = Notification.Name("yab.devSites")

    static func set(name: String, _ on: Bool, tabs ids: [Tab.ID] = []) {
        kept[name] = on
        if on {
            for id in ids {
                tabs[id.uuidString] = Array(Set(tabs[id.uuidString] ?? []).union([name])).sorted()
            }
        } else {
            removeTabs(for: name)
        }
        save()
    }

    /// Never chosen again: its next page asks, as the first one did.
    static func forget(_ name: String) {
        kept[name] = nil
        removeTabs(for: name)
        asked.remove(name)
        save()
    }

    private static func removeTabs(for name: String) {
        for id in Array(tabs.keys) {
            let sites = tabs[id, default: []].filter { $0 != name }
            tabs[id] = sites.isEmpty ? nil : sites
        }
    }
}

extension Browser {
    var canToggleDevMode: Bool { active?.canDev == true }

    /// This tab's mode, from the menu, command field or ⌃D.
    @discardableResult
    func toggleDevMode() -> Bool {
        guard let tab = active, tab.canDev else { return false }
        setDevMode(tab, !tab.isDev)
        return true
    }

    /// The popover belongs to this tab, even if its split neighbour has
    /// the same host and port. Keep the choice when this tab returns here.
    func setDevMode(_ tab: Tab, _ on: Bool) {
        guard let name = DevSites.name(tab.address) else { return }
        DevSites.set(tab: tab.id, name: name, on)
        tab.objectWillChange.send()
        if !on, tab.measuring { tab.measuring = false }
        objectWillChange.send()
    }

    /// On or off for a server by name (Settings › Developers' list), its
    /// open pages drawn again for it.
    static func setDevMode(server name: String, _ on: Bool) {
        let ids = BrowserWindows.shared.browsers.flatMap { browser in
            browser.everyTab.filter { DevSites.name($0.address) == name }.map(\.id)
        }
        DevSites.set(name: name, on, tabs: ids)
        redraw(server: name, on)
    }

    /// Forgotten (Settings › Developers): off for now, and its next page
    /// asks again.
    static func forgetDevMode(server name: String) {
        DevSites.forget(name)
        redraw(server: name, false)
    }

    private static func redraw(server name: String, _ on: Bool) {
        for browser in BrowserWindows.shared.browsers {
            for other in browser.everyTab where DevSites.name(other.address) == name {
                other.objectWillChange.send()
                if !on, other.measuring { other.measuring = false }
            }
            browser.objectWillChange.send()
        }
    }

    /// A local page loaded whose server was never asked about: the card,
    /// hanging from its tab. Not Now leaves it unasked, for next time.
    func offerDevMode(_ tab: Tab) {
        guard prefs.offerDevMode, tab.isLocal, DevSites.choice(tab.address) == nil, let name = DevSites.name(tab.address),
              !DevSites.asked.contains(name), !tab.asks.contains(where: { $0.kind == .devMode }) else { return }
        // Not in a small window or a pop-up, a look or a sign-in, and not on
        // a page a site elsewhere sent you to: codex login's "Signed in", on
        // its own little server, is no page being made. Asked next time.
        guard !tab.popup, !outside.contains(where: { $0 === tab }), !tab.sentFromAfar else { return }
        DevSites.asked.insert(name)
        ask(PageAsk(kind: .devMode, host: name), on: tab) { [weak self, weak tab] reply, _ in
            guard case .yes = reply, let self, let tab, DevSites.name(tab.address) == name else { return }
            self.setDevMode(tab, true)
        }
    }
}

// MARK: - what the page said

@MainActor
final class DevLog: ObservableObject {
    enum Level: String { case error, warning }

    /// One kind of message: every time the page said the same words, the
    /// numbers in them aside, is this one row, counted.
    struct Entry: Identifiable, Equatable {
        let id: String
        let level: Level
        let text: String
        let stack: String
        let source: String
        var count: Int
        var last: Date
    }

    struct Request: Identifiable, Equatable {
        let id: Int
        let method: String
        let url: String
        let status: Int
        let ms: Int
        let kind: String
        let failure: String?
        let requestBody: String?
        let responseBody: String?
        let headers: [String: String]
        /// When it was sent, in milliseconds since 1970 on the page's clock:
        /// the same moment WebKit's Network has for it, which tells it from
        /// others to the same address there (DevTools.match).
        var sent: Double? = nil

        var failed: Bool { status == 0 ? failure != nil : status >= 400 }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var requests: [Request] = []
    /// Kinds not kept, past the most a page may have, only counted.
    @Published private(set) var dropped = 0
    @Published private(set) var since = Date()

    var errors: Int { counts.errors }
    var warnings: Int { counts.warnings }

    /// How many kinds of error and warning there are, apart from the rows:
    /// the band's word watches only this, and is left alone while a page in
    /// a loop only raises the count of a row it already has.
    final class Counts: ObservableObject {
        @Published fileprivate(set) var errors = 0
        @Published fileprivate(set) var warnings = 0
        @Published fileprivate(set) var requests = 0
    }
    let counts = Counts()

    /// The page's requests kept, the latest.
    static let keptRequests = 300

    private var index: [String: Int] = [:]
    private var nextRequest = 0
    /// The rows as last heard, not yet shown: a batch that only raises
    /// counts waits here, and the rows are shown at most once a second.
    private var heard: [Entry]?
    private var showing: DispatchWorkItem?
    /// How often a count alone is shown going up.
    static let countEvery: TimeInterval = 1
    /// Counts pages, so a batch parsed for the page before is dropped.
    private var page = 0

    /// When the page's own script began to hear this document, for a page
    /// heard only once the card is out; nil for one heard from its start.
    var heardFrom: Date?
    /// What the inspector handed over from before that, by row: added to
    /// what the page's script counts from then on.
    private var earlyCounts: [String: Int] = [:]
    /// Each message taken, by its row and when it was said, with how many
    /// of its repeats: the inspector hands its whole console over again
    /// every time it connects, and each is counted once.
    private var earlyTaken: [String: Int] = [:]

    /// Said before the card listened, as WebKit's inspector keeps it and
    /// hands it over when it connects. Only what came between the document
    /// starting and the page's own script starting: the rest the script
    /// hears itself, and would be counted twice.
    func early(level: String, text: String, source: String, line: Int, at millis: Double, copy: Int = 0, stack: String) {
        guard let heardFrom, let kind: Level = level == "error" ? .error : level == "warning" ? .warning : nil else { return }
        let at = Date(timeIntervalSince1970: millis / 1000)
        guard at >= since.addingTimeInterval(-1), at < heardFrom else { return }
        let key = kind.rawValue + "|" + String(text.prefix(300)).replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        // By its whole words, not the row's: a loop says "item 1", "item 2"
        // in the same millisecond, two messages.
        let said = kind.rawValue + "|" + text + "@" + String(millis)
        guard copy >= earlyTaken[said, default: 0] else { return }
        earlyTaken[said] = copy + 1
        earlyCounts[key, default: 0] += 1
        var entries = heard ?? self.entries
        if let at = index[key] {
            entries[at].count += 1
        } else {
            index[key] = entries.count
            let place = source.isEmpty ? "" : line > 0 ? "\(source):\(line)" : source
            entries.append(Entry(id: key, level: kind, text: String(text.prefix(4000)), stack: stack, source: place, count: 1, last: at))
            let errors = entries.lazy.filter { $0.level == .error }.count
            if counts.errors != errors { counts.errors = errors }
            if counts.warnings != entries.count - errors { counts.warnings = entries.count - errors }
        }
        show(entries)
    }

    /// A new document: what the last one said is gone with it.
    func reset() {
        page += 1
        heardFrom = nil
        earlyCounts = [:]
        earlyTaken = [:]
        index = [:]
        heard = nil
        showing?.cancel()
        showing = nil
        guard !entries.isEmpty || !requests.isEmpty || dropped != 0 else { since = Date(); return }
        entries = []
        requests = []
        dropped = 0
        since = Date()
        if counts.errors != 0 { counts.errors = 0 }
        if counts.warnings != 0 { counts.warnings = 0 }
        if counts.requests != 0 { counts.requests = 0 }
    }

    /// A batch, as the page's script wrote it. Parsed away from the main
    /// thread: a page failing a request after another can hand over a few
    /// hundred kilobytes at a time.
    nonisolated func hear(_ json: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let batch = Batch.parse(json) else { return }
            await self?.apply(batch)
        }
    }

    private func apply(_ batch: Batch) {
        var entries = heard ?? self.entries
        var changed = false
        var added = false
        for group in batch.groups {
            if let at = index[group.key] {
                let count = group.count + (earlyCounts[group.key] ?? 0)
                if entries[at].count != count {
                    entries[at].count = count
                    entries[at].last = group.last
                    changed = true
                }
            } else if let text = group.text {
                index[group.key] = entries.count
                entries.append(Entry(id: group.key, level: group.level, text: text, stack: group.stack ?? "",
                                     source: group.source ?? "", count: group.count, last: group.last))
                changed = true
                added = true
            }
        }
        // A new kind is shown at once; only counts going up wait, and are
        // shown once a second: a page in a loop raises one count thousands
        // of times a second, and the list would be drawn again for each.
        if added {
            show(entries)
        } else if changed {
            heard = entries
            if showing == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let waiting = heard else { return }
                    show(waiting)
                }
                showing = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.countEvery, execute: work)
            }
        }
        if added {
            let errors = entries.lazy.filter { $0.level == .error }.count
            if counts.errors != errors { counts.errors = errors }
            if counts.warnings != entries.count - errors { counts.warnings = entries.count - errors }
        }
        if !batch.requests.isEmpty {
            var requests = self.requests
            for heard in batch.requests {
                requests.append(heard.request(id: nextRequest))
                nextRequest += 1
            }
            if requests.count > Self.keptRequests { requests.removeFirst(requests.count - Self.keptRequests) }
            self.requests = requests
            if counts.requests != requests.count { counts.requests = requests.count }
        }
        if batch.dropped != dropped { dropped = batch.dropped }
        if !batch.streams.isEmpty {
            for (url, events) in Dictionary(grouping: batch.streams, by: \.url) { heardStream?(url, events.map(\.event)) }
        }
    }

    /// Where an EventSource's events go: the tab's Network (DevNet.swift).
    var heardStream: ((String, [NetResource.Event]) -> Void)?

    private func show(_ entries: [Entry]) {
        heard = nil
        showing?.cancel()
        showing = nil
        self.entries = entries
    }

    /// A batch from the page, parsed.
    struct Batch: Sendable {
        struct Group: Sendable {
            let key: String
            let level: Level
            let count: Int
            let last: Date
            let text: String?
            let stack: String?
            let source: String?
        }
        struct Heard: Sendable {
            let method, url, kind: String
            let status, ms: Int
            let failure, requestBody, responseBody: String?
            let headers: [String: String]
            let sent: Double?

            func request(id: Int) -> Request {
                Request(id: id, method: method, url: url, status: status, ms: ms, kind: kind, failure: failure,
                        requestBody: requestBody, responseBody: responseBody, headers: headers, sent: sent)
            }
        }

        var groups: [Group] = []
        var requests: [Heard] = []
        var dropped = 0
        /// What EventSources said, by the stream's address.
        var streams: [(url: String, event: NetResource.Event)] = []

        static func parse(_ json: String) -> Batch? {
            guard let data = json.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            var batch = Batch()
            batch.dropped = body["x"] as? Int ?? 0
            for raw in body["g"] as? [[String: Any]] ?? [] {
                guard let key = raw["k"] as? String, let level = (raw["v"] as? String).flatMap(Level.init) else { continue }
                let last = Date(timeIntervalSince1970: (raw["l"] as? Double ?? 0) / 1000)
                batch.groups.append(Group(key: key, level: level, count: raw["n"] as? Int ?? 1, last: last,
                                          text: raw["t"] as? String, stack: raw["s"] as? String, source: raw["o"] as? String))
            }
            for raw in body["s"] as? [[String: Any]] ?? [] {
                guard let url = raw["u"] as? String else { continue }
                batch.streams.append((url, NetResource.Event(id: raw["i"] as? String ?? "", type: raw["t"] as? String ?? "message",
                                                             data: raw["d"] as? String ?? "", wall: (raw["w"] as? NSNumber)?.doubleValue ?? 0)))
            }
            for raw in body["r"] as? [[String: Any]] ?? [] {
                guard let url = raw["u"] as? String else { continue }
                batch.requests.append(Heard(
                    method: raw["m"] as? String ?? "GET", url: url, kind: raw["k"] as? String ?? "fetch",
                    status: raw["st"] as? Int ?? 0, ms: raw["ms"] as? Int ?? 0,
                    failure: raw["e"] as? String, requestBody: raw["q"] as? String, responseBody: raw["r"] as? String,
                    headers: raw["h"] as? [String: String] ?? [:], sent: raw["t"] as? Double
                ))
            }
            return batch
        }
    }
}

/// The bridge's messages, heard.
final class DevRelay: NSObject, PageScriptReceiving {
    static let name = "yabDev"
    weak var log: DevLog?

    /// The most a batch may be, in the bridge's UTF-16 units.
    static let most = 4_000_000

    /// Any page can raise the bridge's event, so what it hands over is taken
    /// only from the main frame of a page on this Mac's own server, or of
    /// one heard while the card is out over it (Tab.hearPage), and no larger
    /// than the bridge lets through (RelayGuard).
    func receive(_ message: PageScriptMessage) {
        guard message.frame.isMain, let json = message.body as? NSString, json.length < Self.most else { return }
        let frame = message.frame
        MainActor.assumeIsolated {
            guard let log, RelayGuard.local(frame.origin) || log.heardFrom != nil else { return }
            log.hear(json as String)
        }
    }

    /// In the page's own world: its console, its errors and its requests,
    /// heard where they happen. Leaves every page that isn't on this Mac's
    /// own server at its first line.
    static let page = PageScript.load("dev-mode-page")

    /// The same, for a page that isn't local, put in while the Developer
    /// Tools card is out over it: heard from then on, and never twice.
    static let anywhere: String = {
        let check = "if (!(h === 'localhost' || /\\.localhost$/.test(h) || /\\.test$/.test(h) || h === '127.0.0.1' || h === '[::1]' || h === '::1')) return;"
        precondition(page.contains(check))
        return page.replacingOccurrences(of: check, with: "if (window.__yabDevHeard) return; Object.defineProperty(window, '__yabDevHeard', { value: true });")
    }()

    /// In yab's world: the page's batches, handed on.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__yabDevBridged) return;
      window.__yabDevBridged = true;
      window.addEventListener('yab:dev', function (e) {
        if (typeof e.detail === 'string' && e.detail.length < \(most)) handler.postMessage(e.detail);
      });
    })();
    """
}

// MARK: - the browser's side

extension Browser {
    /// The tab in front is on this Mac's own server, with its band up.
    var devFront: Tab? {
        guard let tab = toolsFront, tab.isDev else { return nil }
        return tab
    }

    /// ⌥⌘K, and the word in the band: the card on the page's errors, or
    /// away if it is on yab's lists already.
    func toggleDevSheet() {
        if devOpen, !devPane.isWebKit { closeDevTools(); return }
        if devOpen { pickDevPane(.errors) } else { openDevTools(.errors) }
    }

    /// Where the card is now: the side chosen, but under the page in a
    /// window too narrow to have it beside.
    var devSide: DevSide {
        prefs.devSide.beside && !DevLook.fitsBeside(devRoomWidth) ? .bottom : prefs.devSide
    }

    /// The card to the other side, under the page or beside it.
    func setDevSide(_ side: DevSide) {
        let detached = devDetached
        if detached { devFloating.hide(); devDetached = false }
        DevMemory.detached = false
        if side != prefs.devSide { moveDev(open: devOpen || devComing, side: side) }
        if detached { showWebPane() }
    }

    /// Hold the page first, then let its room and the card move on the
    /// same SwiftUI curve. WebKit tracks the room's current size, without
    /// starting a second curve for each intermediate layout.
    func moveDev(open: Bool, side: DevSide) {
        devMoves += 1
        let move = devMoves
        let pace: Reshape.Pace = open == devOpen ? .reshape : open ? .arrive : .depart
        devMoving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            // Overtaken in that frame (put away again, another tab in front):
            // the later move is the one that stands.
            guard devMoves == move else { return }
            Reshape.pace = pace
            withAnimation(pace.animation, completionCriteria: .removed) {
                devOpen = open
                prefs.devSide = side
            } completion: { [self] in
                guard devMoves == move, devMoving else { return }
                // The native coordinator retains its final viewport until
                // WebKit's paint commits, even after this motion is over.
                devMoving = false
                Reshape.pace = .reshape
            }
        }
    }

    /// A row shown in WebKit's inspector, in the card: the console for a
    /// message, Elements otherwise.
    func showInInspector(console: Bool) {
        pickDevPane(console ? .console : .elements)
    }

    /// What a test world copied last, for the bench to read.
    static var benchCopied = ""

    /// Copied as Markdown for an agent to read, and said so; or not, where
    /// the button pressed says it itself (Measure's Copied).
    func copyForAgent(_ text: String, _ what: String?) {
        // A test world copies to a board of its own, never over yours.
        let board = Store.testing ? NSPasteboard(name: NSPasteboard.Name("yab-bench")) : NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        if Store.testing { Browser.benchCopied = text }
        if let what { announce(what, mark: "doc.on.doc") }
    }
}

// MARK: - a stack, read

extension DevLog {
    /// One line of a stack as WebKit writes it, `name@address:line:column`,
    /// said the short way: the file and line, then the function. The page's
    /// own server is left out of the address, it says nothing.
    nonisolated static func frame(_ line: String, page: URL?) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        var name = ""
        var place = trimmed
        if let at = trimmed.firstIndex(of: "@") {
            name = String(trimmed[..<at])
            place = String(trimmed[trimmed.index(after: at)...])
        } else if trimmed.hasPrefix("at ") {
            place = String(trimmed.dropFirst(3))
        }
        if let page, let scheme = page.scheme, let host = page.host() {
            let origin = "\(scheme)://\(host)" + (page.port.map { ":\($0)" } ?? "")
            place = place.replacingOccurrences(of: origin + "/", with: "")
            place = place.replacingOccurrences(of: origin, with: "")
        }
        if place.isEmpty { return name }
        return name.isEmpty || name == "global code" ? place : "\(place) · \(name)"
    }

    /// The stack's lines, the page's own first: those in node_modules and
    /// the framework's are what the page's own code went through.
    nonisolated static func frames(_ stack: String) -> (own: [String], all: [String]) {
        let all = stack.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let own = all.filter { !$0.contains("node_modules") && !$0.contains("react-dom") && !$0.contains("[native code]") }
        return (own, all)
    }
}

// MARK: - what is copied

enum DevCopy {
    /// An error, as an agent can act on it: the words, where it was said,
    /// its stack, how often, and on which page.
    @MainActor static func entry(_ entry: DevLog.Entry, page: URL?) -> String {
        var out = "## \(entry.level == .error ? "Error" : "Warning") on \(where_(page))\n\(clean(entry.text))\n"
        let (own, all) = DevLog.frames(entry.stack)
        if !all.isEmpty {
            out += "\n"
            let shown = Array((own.isEmpty ? all : own).prefix(8))
            for frame in shown { out += "  at \(DevLog.frame(frame, page: page))\n" }
            if all.count > shown.count { out += "  … \(all.count - shown.count) more frames\n" }
        } else if !entry.source.isEmpty {
            out += "\n  at \(DevLog.frame(entry.source, page: page))\n"
        }
        out += "\n\(entry.count == 1 ? "Once" : "\(entry.count.formatted()) times") since the page loaded\n"
        return out
    }

    /// A request, with what went and what came back, its secrets out.
    @MainActor static func request(_ request: DevLog.Request, page: URL?) -> String {
        var out = "## \(request.method) \(clean(path(request.url))) → \(request.status == 0 ? "failed" : String(request.status)) (\(request.ms) ms)\n"
        out += "Page: \(where_(page))\n"
        if let failure = request.failure { out += "Error: \(clean(failure))\n" }
        let headers = request.headers.sorted { $0.key < $1.key }
        if !headers.isEmpty {
            out += "\n"
            for (key, value) in headers { out += "\(key): \(secret(key) ? "[removed]" : clean(value))\n" }
        }
        if let body = request.requestBody, !body.isEmpty { out += "\n\(clean(trim(body)))\n" }
        if let body = request.responseBody, !body.isEmpty { out += "\n→ \(clean(trim(body)))\n" }
        return out
    }

    /// The request again from a terminal, without its secrets.
    @MainActor static func curl(_ request: DevLog.Request) -> String {
        // A token in the address is out too: the copy can go anywhere, and
        // whoever runs it again has the page to take it from.
        let url = clean(request.url)
        var parts = [request.method == "GET" ? "curl \(quote(url))" : "curl -X \(request.method) \(quote(url))"]
        for (key, value) in request.headers.sorted(by: { $0.key < $1.key }) where !secret(key) {
            parts.append("-H \(quote("\(key): \(value)"))")
        }
        if let body = request.requestBody, !body.isEmpty { parts.append("--data \(quote(body))") }
        return parts.joined(separator: " \\\n  ")
    }

    /// The page by its server, port and path: localhost:3000/cart.
    static func where_(_ page: URL?) -> String {
        guard let page, let host = page.host() else { return "the page" }
        let port = page.port.map { ":\($0)" } ?? ""
        let path = page.path() == "/" ? "" : page.path()
        return host + port + path
    }

    private static func path(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        let query = parsed.query().map { "?" + $0 } ?? ""
        return parsed.path() + query
    }

    private static func trim(_ text: String) -> String {
        guard text.count > 8192 else { return text }
        return String(text.prefix(4000)) + "\n… \(((text.count - 8000) / 1024).formatted()) KB cut …\n" + String(text.suffix(4000))
    }

    private static func secret(_ header: String) -> Bool {
        let name = header.lowercased()
        return name == "cookie" || name == "authorization" || name == "proxy-authorization"
            || name.contains("api-key") || name.contains("token") || name.contains("secret")
    }

    /// What looks like a key or a token, and a token in an address, out.
    static func clean(_ text: String) -> String {
        var out = text
        let patterns = [
            #"(sk|pk|rk)-[A-Za-z0-9_\-]{16,}"#, #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"AKIA[0-9A-Z]{16}"#,
            #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "[looks like a key]", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"([?&#](?:token|code|access_token|id_token|key|secret|password)=)[^&#\s"]+"#,
                                       with: "$1…", options: [.regularExpression, .caseInsensitive])
        return out
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - the tab's port

/// ":3000" after a local page's name. On hover the cross takes this lane;
/// an agent's face stays at the end of the tab, clear of both.
/// Tape round the open tab of a page on this Mac's own server, as Arc
/// marks one: yellow, with black laid over it in dashes, so a dev tab is
/// never taken for the live site.
struct DevTape: View {
    static let yellow = Color(nsColor: NSColor(srgbRed: 0.98, green: 0.8, blue: 0.13, alpha: 1))

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        shape.strokeBorder(Self.yellow, lineWidth: 1.5)
            .overlay(shape.strokeBorder(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
            .allowsHitTesting(false)
    }
}

struct DevPort: View {
    @ObservedObject var tab: Tab
    let hovering: Bool
    let gap: CGFloat
    /// The speaker is at the tab's end too, in the row of tabs; the
    /// column's stands beside the mark (SideSpeaker).
    var speaker = true
    /// The row's cross takes a kept tab put down out of the kept
    /// (TabEnd.crossable): it is there under the pointer on that tab too.
    var unkeeps = false
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wide enough for the longest valid port, :65535.
    /// ":3000" whole, at a tab title's size: 42 at 12.5.
    static var lane: CGFloat { (42 * SidebarTypography.current / 12.5).rounded(.up) }

    /// The port gives its place to the cross under the pointer, wherever
    /// the row has one: a kept tab put down has none, but in the column,
    /// where the cross takes it out of the kept. Left out, that cross was
    /// drawn over the port.
    static func yields(hovering: Bool, working: Bool, putDown: Bool, unkeeps: Bool) -> Bool {
        hovering && (working || !putDown || unkeeps)
    }

    /// A face, ring or speaker keeps the tab's final 15-point slot.
    private var endTaken: Bool { tab.worker != nil || tab.spinning || (speaker && (tab.noisy || tab.muted)) }
    private var clear: CGFloat { endTaken ? 15 + gap : 0 }

    var body: some View {
        if let port = tab.devPort {
            Text(":\(String(port))")
                .font(.system(size: SidebarTypography.current))
                .foregroundStyle(Palette.faint(on: tone))
                .lineLimit(1)
                .fixedSize()
                .frame(width: Self.lane, alignment: .trailing)
                .opacity(Self.yields(hovering: hovering, working: tab.worker != nil, putDown: tab.putDown, unkeeps: unkeeps) ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .accessibilityLabel("Local port \(port)")
                .padding(.trailing, clear)
        }
    }
}

// MARK: - the band's word and door

/// On a local page's band: Measure, the developer tools, and before them
/// the errors in words when there are any, which open the tools too. A
/// page with none says nothing: all is well is what a quiet band means.
struct DevBandDoors: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var log: DevLog.Counts
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 2) {
            let errors = log.errors
            if !browser.devOpen, errors > 0 {
                Button { browser.toggleDevSheet() } label: {
                    HStack(spacing: 4) {
                        Text(errors == 1 ? "1 error" : "\(errors.formatted()) errors")
                            .foregroundStyle(DevLook.red)
                            .contentTransition(.numericText(value: Double(errors)))
                        Symbol("chevron.up", size: 9, weight: .semibold)
                            .foregroundStyle(Palette.muted(on: tone))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.yab(.quiet, .small))
                .focusable(false)
                .keyTip("Show Errors and Network", shortcut: "Errors and Network")
                .animation(Motion.quick, value: errors)
            }
            // Rulers over the page (Measure.swift).
            Door(icon: "ruler", on: tab.measuring, help: "Measure", shortcut: "Measure") {
                browser.toggleMeasure()
            }
            // The tools: the sheet here, WebKit's inspector from its head.
            Door(icon: "chevron.left.forwardslash.chevron.right", on: browser.devOpen, help: "Developer Tools", shortcut: "Developer Tools") {
                browser.developerTools()
            }
        }
    }
}

enum DevLook {
    static let red = Color(nsColor: .systemRed)
    static let amber = Color(nsColor: .systemOrange)
    static let padding: CGFloat = 8
    /// The card's size: its height under the page, its width beside it.
    /// Room for WebKit's Elements, its tree and its styles side by side.
    static let height: CGFloat = 320
    static let width: CGFloat = 500
    /// Beside the page only where the page keeps this much: in a narrower
    /// window the card goes under it whatever side was chosen.
    static let pageBeside: CGFloat = 400
    static let narrowest: CGFloat = 460

    /// Its width beside a page in `room` points: 500, or as wide as its
    /// edge was dragged, less in a window that would leave the page under
    /// 400.
    static func width(in room: CGFloat, wanted: CGFloat? = nil) -> CGFloat {
        max(narrowest, min(wanted ?? width, room - pageBeside))
    }

    static func fitsBeside(_ room: CGFloat) -> Bool { room - pageBeside >= narrowest }

    /// Its height under a page in `room` points: 320, less in a short
    /// window, where the page keeps more than half. Dragged higher, as
    /// Chrome's DevTools is, the page still keeps 160.
    static func height(in room: CGFloat, wanted: CGFloat? = nil) -> CGFloat {
        guard let wanted else { return max(200, min(height, (room * 0.45).rounded())) }
        return max(200, min(wanted, room - 160))
    }
}

// MARK: - the room: the page and the sheet

/// The page and, when it is out, the sheet: under the page or beside it,
/// in from the card's edges, the page taking what is left. Laid out in one
/// pass; moved by SwiftUI on the curve the page is carried on.
struct DevRoom: Layout {
    var open: Bool
    var side: DevSide
    var rim: Rim
    /// The card's height under the page and its width beside it, where its
    /// edge was dragged (DevSize).
    var height: CGFloat? = nil
    var width: CGFloat? = nil
    private var inset: CGFloat { rim.inset }
    private var gap: CGFloat { rim.gap }

    /// Where the sheet stands and its corners. On the backdrop it is a card
    /// as the page is: out to the same edges, the backdrop's air between the
    /// two, and the card's corners, which go round with the window's own at
    /// the bottom right as the page's do. With the page edge to edge, in
    /// full screen, in from the edges instead.
    struct Rim: Equatable {
        let inset: CGFloat
        let gap: CGFloat
        let corner: CGFloat

        init(card: Bool) {
            inset = card ? 0 : Backdrop.inset
            gap = Backdrop.inset
            corner = card ? Backdrop.corner : Radius.control
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let page = subviews.first else { return }
        guard subviews.count > 1 else {
            page.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let sheet = subviews[1]
        var pageRect = bounds
        var sheetRect: CGRect
        switch side {
        case .bottom:
            let height = DevLook.height(in: bounds.height, wanted: self.height)
            let room = height + gap + inset
            if open { pageRect.size.height = max(120, bounds.height - room) }
            sheetRect = CGRect(x: bounds.minX + inset, y: bounds.maxY - inset - height,
                               width: bounds.width - 2 * inset, height: height)
        case .right:
            let width = DevLook.width(in: bounds.width, wanted: self.width)
            let room = width + gap + inset
            if open { pageRect.size.width = max(0, bounds.width - room) }
            sheetRect = CGRect(x: bounds.maxX - inset - width, y: bounds.minY + inset,
                               width: width, height: bounds.height - 2 * inset)
        case .left:
            let width = DevLook.width(in: bounds.width, wanted: self.width)
            let room = width + gap + inset
            if open {
                pageRect.origin.x += room
                pageRect.size.width = max(0, bounds.width - room)
            }
            sheetRect = CGRect(x: bounds.minX + inset, y: bounds.minY + inset,
                               width: width, height: bounds.height - 2 * inset)
        }
        page.place(at: pageRect.origin, proposal: ProposedViewSize(pageRect.size))
        sheet.place(at: sheetRect.origin, proposal: ProposedViewSize(sheetRect.size))
    }
}

// MARK: - the card

/// Developer Tools: yab's lists, or WebKit's inspector docked in the card
/// (DevTools.swift). The dock stays in the card while it is out, seen only
/// on a WebKit pane, so moving between panes loads nothing again.
struct DevSheet: View {
    /// Not watched: the browser changes all the time and the card needs
    /// nothing of it but to call it; what it shows is handed in.
    let browser: Browser
    @ObservedObject var tab: Tab
    /// Not watched here either: the head watches the counts, each pane its
    /// rows, so a page in a loop redraws the one row whose count went up.
    let log: DevLog
    let pane: DevPane
    /// The panels extensions added to the inspector, for the head.
    let panels: [DevPanel]
    /// What the list of what went wrong shows (DevIssues).
    let filter: IssueFilter
    let side: DevSide
    /// Out, or on its way in or away: faded and a little toward its edge.
    let shown: Bool
    /// Concentric with the corner it sits in (DevRoom.Rim).
    let corner: CGFloat
    /// The Fixed-width font code is set in (DevMono).
    @ObservedObject private var mono = DevMono.shared

    var body: some View {
        VStack(spacing: 0) {
            DevHead(browser: browser, tab: tab, deviceOn: tab.device != nil, consoleCounts: tab.devModel(ConsoleLog.self).counts, side: side, pane: pane, panels: panels)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            ZStack {
                let chromium = tab.usesChromiumDev
                InspectorDockView(dock: browser.inspectorDock)
                    .opacity(pane.isWebKit && !chromium ? 1 : 0)
                    .allowsHitTesting(pane.isWebKit && !chromium)
                if chromium {
                    // Waits for its row of tabs to be put away (chromiumDevReady).
                    ChromiumDevHost(page: tab.chromiumDev?.page)
                        .opacity(tab.chromiumDevReady > 0 ? 1 : 0)
                } else if !pane.isWebKit {
                    DevKeyHost {
                        switch pane {
                        case .console: DevConsolePane(browser: browser, tab: tab, log: tab.devModel(ConsoleLog.self), panel: browser.consolePanel)
                        case .network: DevNetPane(browser: browser, tab: tab, log: tab.netLog, panel: browser.netPanel, side: side)
                        case .security: DevSecurity(browser: browser, tab: tab, log: log)
                        case .recorder: DevRecorder(browser: browser, tab: tab, recorder: tab.recorder)
                        case .elements, .sources, .performance, .memory, .application, .audit, .layers:
                            DevWorkbenchHost(browser: browser, model: tab.devModel(DevWorkbench.self), pane: pane)
                        default: DevIssues(browser: browser, tab: tab, log: log, filter: filter, wide: side == .bottom)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            DevDrawerHost(browser: browser, tab: tab, drawer: browser.toolDrawer)
        }
        .overlay(alignment: .top) { DevOverlays(browser: browser, state: browser.devCommand) }
        .font(.system(size: 12))
        .foregroundStyle(Palette.ink)
        // The room DevRoom gives it, whatever its head or panes would like.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .modifier(DevPaper(corner: corner))
        // Where it stands in the window, for the bench (probe's dev.card).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { browser.devCard = $0 }
        // Its edge, in the air between it and the page.
        .overlay(alignment: side == .bottom ? .top : side == .left ? .trailing : .leading) {
            if !browser.devDetached {
                DevEdge(browser: browser, side: side)
                    .offset(x: side == .left ? Backdrop.inset : side == .right ? -Backdrop.inset : 0,
                            y: side == .bottom ? -Backdrop.inset : 0)
            }
        }
        // To the other side it doesn't travel: the one here fades where it
        // is and a new one comes up there, while only the page moves. Carried
        // across, its list would be laid out again on every frame. A new
        // Fixed-width font lays it out again too, as Chromium's DevTools does.
        .id("\(side)|\(mono.family)")
        .transition(.opacity)
        .opacity(shown ? 1 : 0)
        .offset(x: shown || side == .bottom ? 0 : side == .left ? -24 : 24, y: shown || side.beside ? 0 : 24)
        .allowsHitTesting(shown)
        // Network's beat, whichever pane is up (DevNetBridge.swift).
        .onAppear { browser.netBeat() }
    }
}

struct DevQuiet: View {
    let words: String

    var body: some View {
        Text(words)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where the card's edge was dragged: its height under the page, its width
/// beside it, kept for the next time it comes out; and how high the room is
/// they share, read as a drag starts.
final class DevSize: ObservableObject {
    static let shared = DevSize()
    @Published var height: CGFloat? = (Store.settings.object(forKey: "dev.height") as? Double).map { CGFloat($0) }
    @Published var width: CGFloat? = (Store.settings.object(forKey: "dev.width") as? Double).map { CGFloat($0) }
    var room: CGFloat = 800
}

/// The card's edge toward the page, in the air between the two, dragged
/// as the chat's column and a split's divider are (ChatEdge, SplitDivider):
/// nothing drawn at rest, under the pointer the resize cursor and a short
/// grip. A real view (EdgeHandle): a SwiftUI strip on the card's edge lost
/// the pointer to WebKit's inspector and Network's table under it. The
/// page is held while it is dragged and takes its new size once, when the
/// edge is let go; a double click puts the card back at its usual size.
/// Kept for the next time it comes out.
private struct DevEdge: View {
    let browser: Browser
    let side: DevSide
    @State private var hovering = false
    @State private var from: CGFloat?

    var body: some View {
        let across = side == .bottom
        ZStack {
            Capsule()
                .fill(Palette.ink.opacity(from != nil ? 0.5 : 0.28))
                .frame(width: across ? 28 : 3, height: across ? 3 : 28)
                .opacity(hovering || from != nil ? 1 : 0)
                .animation(Motion.quick, value: hovering || from != nil)
            EdgeHandle(
                changed: { travel in
                    let size = DevSize.shared
                    if from == nil {
                        from = side == .bottom ? DevLook.height(in: size.room, wanted: size.height)
                                               : DevLook.width(in: browser.devRoomWidth, wanted: size.width)
                        browser.devSizing = true
                    }
                    let start = from ?? 0
                    // Within what the room allows, so what is kept is what
                    // was seen.
                    switch side {
                    case .bottom: size.height = DevLook.height(in: size.room, wanted: (start + travel).rounded())
                    case .right: size.width = DevLook.width(in: browser.devRoomWidth, wanted: (start - travel).rounded())
                    case .left: size.width = DevLook.width(in: browser.devRoomWidth, wanted: (start + travel).rounded())
                    }
                },
                ended: { _, _ in
                    from = nil
                    browser.settleDevSize(side)
                },
                doubled: {
                    let size = DevSize.shared
                    if side == .bottom { size.height = nil } else { size.width = nil }
                    browser.settleDevSize(side)
                },
                hover: { hovering = $0 },
                vertical: across
            )
        }
        .frame(width: across ? nil : Backdrop.inset, height: across ? Backdrop.inset : nil)
        .frame(maxWidth: across ? .infinity : nil, maxHeight: across ? nil : .infinity)
    }
}

extension Browser {
    /// The card's edge let go: its size kept, and the page given its new
    /// one, a frame on.
    func settleDevSize(_ side: DevSide) {
        let size = DevSize.shared
        if side == .bottom { Store.settings.set(size.height.map(Double.init), forKey: "dev.height") }
        else { Store.settings.set(size.width.map(Double.init), forKey: "dev.width") }
        DispatchQueue.main.async { [self] in
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { devSizing = false }
        }
    }

    /// The page shares the room with a card of ours, the chat's column or
    /// the developer tools, or with the other half of a pair: in full
    /// screen with the tabs away it is a card too, in by the same inset,
    /// rather than a square edge against theirs. Only a page alone has the
    /// screen edge to edge; two halves keep the space's color round and
    /// between them, as Chromium's split keeps its inset in full screen
    /// (MultiContentsView::kSplitViewContentInset) and Arc's does
    /// (register 2551).
    var pageShared: Bool { chatOpen || (devOpen && toolsFront != nil) || stagePair != nil }
}

/// The page card's paper (Paper): the ground, solid white or the dark
/// page's, its short shadow and hairline, so the card reads as a second
/// page on the backdrop, not glass the page shows through.
///
/// The card's face is its own ground, inside its one clip: the paper's
/// ground keeps a point clear of the edge, as under a page, so that the
/// edge is cut once (docs/page-corners.md).
private struct DevPaper: ViewModifier {
    let corner: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous)) // design: concentric with the window's corner, DevRoom.Rim
            .background { Paper(corner: corner, dark: scheme == .dark, band: nil, moving: false).padding(-1) }
    }
}
