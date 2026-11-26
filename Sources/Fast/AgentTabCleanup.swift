import AppKit
import WebKit

enum AgentTabsAfter: String, CaseIterable, Identifiable {
    case never, fifteenMinutes, oneHour

    var id: String { rawValue }
    static let key = "agents.tabs.cleanup"
    static var saved: Self { Store.settings.string(forKey: key).flatMap(Self.init) ?? .fifteenMinutes }

    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        }
    }

    var title: String {
        switch self {
        case .never: return "Never"
        case .fifteenMinutes: return "After 15 minutes"
        case .oneHour: return "After 1 hour"
        }
    }
}

/// One clock for finished agents, including tabs in other windows and
/// parked spaces. Sleep time does not count. A page is checked for drafts
/// only when due, and its ownership and task generation are checked again
/// when that asynchronous answer arrives. An agent that came on its own
/// through `yab mcp` stays attached for as long as its client runs, hours
/// or days: each of its tabs waits from the last thing it did there.
@MainActor
final class AgentTabCleanup {
    static let shared = AgentTabCleanup()
    /// Only isolated test apps may move the cleanup clock forward.
    private static var testOffset: TimeInterval = 0

    private struct Entry {
        let ended: Date
        let generation = UUID()
        var looked: Date
        let immediate: Bool
        var since: [Tab.ID: TimeInterval] = [:]
        var deferred: Set<Tab.ID> = []
        var protected: Set<Tab.ID> = []
        /// Since when a page has been loading: one that never finishes
        /// holds its tab for one interval, not for ever.
        var loading: [Tab.ID: TimeInterval] = [:]
        /// Checks in a row that couldn't say: the next one closes.
        var unsure: [Tab.ID: Int] = [:]
    }

    private var entries: [String: Entry] = [:]
    /// The agent tabs this cleanup closed, oldest first, at most 64: an
    /// agent that came back for one heard only "no tab", and couldn't tell
    /// Yab's tidying from the person closing it. Written only on a close.
    /// `after` is the wait it used; nil when a subagent's end closed it.
    private var closed: [(id: UUID, url: URL?, after: TimeInterval?)] = []
    private var checking: [Tab.ID: UUID] = [:]
    private var timer: Timer?
    private var revision = UUID()
    private let browsers: @MainActor () -> [Browser]
    private let session: @MainActor (String) -> Agents.Session?
    private let clock: @MainActor () -> TimeInterval
    private let choice: @MainActor () -> AgentTabsAfter
    private let inspect: @MainActor (Tab, @escaping (Bool?) -> Void) -> Void
    private let automatic: Bool

    init(browsers: @escaping @MainActor () -> [Browser] = {
        var all = BrowserWindows.shared.browsers
        if let browser = Agents.shared.browser, !all.contains(where: { $0 === browser }) { all.append(browser) }
        return all
    }, session: @escaping @MainActor (String) -> Agents.Session? = { Agents.shared.session($0) },
         clock: @escaping @MainActor () -> TimeInterval = { AwakeClock.now + (Store.testing ? AgentTabCleanup.testOffset : 0) },
         choice: @escaping @MainActor () -> AgentTabsAfter = { AgentTabsAfter.saved },
         inspect: @escaping @MainActor (Tab, @escaping (Bool?) -> Void) -> Void = { tab, answer in
             AgentTabCleanup.pageIsBusy(tab, answer)
         },
         automatic: Bool = true) {
        self.browsers = browsers
        self.session = session
        self.clock = clock
        self.choice = choice
        self.inspect = inspect
        self.automatic = automatic
    }

    /// Check silent video too: it needn't have set the tab's sound flag.
    static func pageIsBusy(_ tab: Tab, _ answer: @escaping (Bool?) -> Void) {
        guard let page = tab.builtPage else { answer(tab.draft); return }
        var answered = false
        let once: (Bool?) -> Void = { busy in
            guard !answered else { return }
            answered = true
            answer(busy)
        }
        if let web = page.webKit {
            web.evaluateInYab(PageScript.load("agent-cleanup")) { value in
                MainActor.assumeIsolated { once(value as? Bool) }
            }
        } else if let chromium = page as? ChromiumPage {
            Task { @MainActor in once(await chromium.agentCleanupBusy()) }
        } else {
            page.run(PageScript.load("agent-cleanup"), in: .yab, gesture: false) { result in once((try? result.get()) as? Bool) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once(nil) }
    }

    /// When a task's tabs may start their wait: its end, or for an attached
    /// agent the moment it came, its tabs then waiting from its last act.
    private func over(_ task: Agents.Session) -> Date? {
        guard !task.script, !task.quiet, !task.sealed else { return nil }
        if task.state == .attached { return task.began }
        return task.state.live ? nil : task.ended
    }

    func schedule(_ task: Agents.Session, immediate: Bool = false) {
        guard let ended = over(task) else { return }
        if entries[task.id]?.ended != ended {
            entries[task.id] = Entry(ended: ended, looked: task.looked, immediate: immediate)
        }
        lookAround()
        startClock()
        if immediate { sweep() }
    }

    /// A changed interval gets a fresh wait, including Never → enabled.
    /// Pending page answers from the previous setting cannot close anything.
    func settingChanged() {
        revision = UUID()
        checking.removeAll()
        let now = clock()
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            for tab in Array(entry.since.keys) { entry.since[tab] = now; entry.deferred.insert(tab) }
            entries[id] = entry
        }
        stopClock()
        startClock()
    }

    /// Called on tab and window changes even when there is nothing unread.
    /// Leaving a visible or otherwise protected tab starts a full wait.
    func lookAround() {
        let now = clock()
        let all = browsers()
        // An attached agent never ends while its client runs: its tabs are
        // found here, the first time they are seen.
        for browser in all {
            for tab in browser.everyTab where tab.bench {
                guard let id = tab.agent, entries[id] == nil, let task = session(id), task.state == .attached,
                      let came = over(task) else { continue }
                entries[id] = Entry(ended: came, looked: task.looked, immediate: false)
            }
        }
        for id in Array(entries.keys) {
            guard var entry = entries[id], let task = session(id),
                  over(task) == entry.ended else { entries[id] = nil; continue }
            let tabs = all.flatMap { browser in
                browser.everyTab.filter { $0.agent == id && $0.bench && $0.pin == nil && !$0.kept }.map { (browser, $0) }
            }
            guard !tabs.isEmpty else { entries[id] = nil; continue }
            let looked = task.looked != entry.looked
            entry.looked = task.looked
            let ids = Set(tabs.map { $0.1.id })
            entry.since = entry.since.filter { ids.contains($0.key) }
            entry.deferred.formIntersection(ids)
            entry.unsure = entry.unsure.filter { ids.contains($0.key) }
            entry.loading = Dictionary(uniqueKeysWithValues: tabs.compactMap { _, tab in
                tab.loading ? (tab.id, entry.loading[tab.id] ?? now) : nil
            })
            entries[id] = entry
            var protected: Set<Tab.ID> = []
            for (browser, tab) in tabs {
                let blocked = blocked(tab, in: browser)
                if blocked { protected.insert(tab.id) }
                if entry.since[tab.id] == nil || looked || blocked || entry.protected.contains(tab.id) {
                    entry.since[tab.id] = now
                    checking[tab.id] = nil
                }
                if looked || blocked || entry.protected.contains(tab.id) { entry.deferred.insert(tab.id) }
            }
            entry.protected = protected
            entries[id] = entry
        }
        if entries.isEmpty { stopClock() } else { startClock() }
    }

    /// An attached agent did something in its tab: that tab waits from now.
    func acted(_ tab: Tab) {
        guard tab.bench, let id = tab.agent, let task = session(id), task.state == .attached else { return }
        if entries[id] == nil { lookAround() }
        guard entries[id] != nil else { return }
        entries[id]?.since[tab.id] = clock()
        entries[id]?.deferred.insert(tab.id)
        checking[tab.id] = nil
    }

    func sweep() {
        lookAround()
        guard let interval = choice().seconds else { return }
        let now = clock(), setting = revision
        for browser in browsers() {
            for tab in browser.everyTab {
                guard let id = tab.agent, let entry = entries[id], let since = entry.since[tab.id],
                      checking[tab.id] == nil, !blocked(tab, in: browser),
                      now - since >= (entry.immediate && !entry.deferred.contains(tab.id) ? 0 : interval) else { continue }
                let request = UUID()
                checking[tab.id] = request
                inspect(tab) { [weak self, weak browser, weak tab] unsaved in
                    guard let self, let browser, let tab, checking[tab.id] == request else { return }
                    checking[tab.id] = nil
                    guard revision == setting, choice().seconds != nil,
                          let current = entries[id], current.generation == entry.generation,
                          current.since[tab.id] == since, tab.agent == id,
                          let task = session(id), over(task) == entry.ended,
                          task.looked == current.looked,
                          browser.everyTab.contains(where: { $0 === tab }), !blocked(tab, in: browser) else { return }
                    // A form left unsent always keeps the page. An unanswered
                    // check gets one more full wait, then counts as an answer:
                    // a hung page or a focused embed can't hold a tab for ever.
                    let unsure = unsaved == nil ? (current.unsure[tab.id] ?? 0) + 1 : 0
                    entries[id]?.unsure[tab.id] = unsure
                    guard unsaved == false || (unsaved == nil && unsure >= 2) else {
                        entries[id]?.since[tab.id] = clock()
                        entries[id]?.deferred.insert(tab.id)
                        return
                    }
                    let address = tab.shy ? nil : tab.address
                    let after: TimeInterval? = current.immediate && !current.deferred.contains(tab.id) ? nil : interval
                    browser.closeAgentTab(tab)
                    guard !browser.everyTab.contains(where: { $0 === tab }) else { return }
                    closed.append((tab.id, address, after))
                    if closed.count > 64 { closed.removeFirst(closed.count - 64) }
                }
            }
        }
    }

    /// What an agent asking for a tab by `ref` (a prefix of its id, as
    /// `find` takes it) is told when this cleanup closed it; nil otherwise.
    func closedNote(_ ref: String) -> String? {
        let ref = ref.lowercased()
        guard !ref.isEmpty, let gone = closed.last(where: { $0.id.uuidString.lowercased().hasPrefix(ref) }) else { return nil }
        let at = gone.url.map { ", at \($0.absoluteString)" } ?? ""
        guard let after = gone.after else {
            return "Yab closed tab “\(ref)”\(at), when the subagent that opened it finished: open it again"
        }
        let wait = after >= 3600 ? "\(Int(after / 3600)) h" : "\(Int(after / 60)) min"
        return "Yab closed tab “\(ref)”\(at), after \(wait) without a call there (Settings › Tabs › Close agent tabs): open it again"
    }

    private func blocked(_ tab: Tab, in browser: Browser) -> Bool {
        if !tab.bench || tab.pin != nil || tab.kept || tab.handoff != nil || tab.permit != nil { return true }
        // A tick waits for you to come and see; one a run with nobody there
        // (`yab --no-person`, a watcher every few minutes) left never would.
        if let unread = tab.unread, session(unread.session)?.unattended != true { return true }
        if browser.onScreen(tab.id) || tab.floating || browser.floating == tab.id || tab.pictureInPicture || tab.documentPiP.showing { return true }
        if (tab.loading && !stuck(tab)) || tab.noisy || tab.onCall || tab.typing || tab.draft { return true }
        if let guest = tab.guest, session(guest)?.state.live == true { return true }
        if let page = tab.builtPage {
            // Unknown adapters have no activity contract. Only the native
            // engines below have the busy probe used before automatic cleanup.
            guard page.webKit != nil || page is ChromiumPage else { return true }
            let capture = page.captureStatus
            if capture.camera != .none || capture.microphone != .none { return true }
            if browser.downloading.contains(where: { $0.page === page }) { return true }
        }
        let opened: (Tab) -> Bool = { $0.opener == tab.id && $0.waits(for: tab) }
        return browser.everyTab.contains(where: opened) || browser.outside.contains(where: opened)
    }

    private func stuck(_ tab: Tab) -> Bool {
        guard let id = tab.agent, let start = entries[id]?.loading[tab.id], let limit = choice().seconds else { return false }
        return clock() - start >= limit
    }

    private func startClock() {
        guard automatic, timer == nil, !entries.isEmpty, choice().seconds != nil else { return }
        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    /// Native probe fixture, without a provider account or a real task.
    static func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "agent-cleanup-preview requires a test run"] }
        if let value = (request["choice"] as? String).flatMap(AgentTabsAfter.init) { browser.prefs.agentTabsAfter = value }
        if let url = (request["url"] as? String).flatMap(URL.init(string:)) {
            let task = Agents.shared.attach(name: "Cleanup probe")
            let tab = browser.benchOpen(url)
            tab.agent = task.id
            if request["attached"] as? Bool != true {
                task.state = .done
                task.ended = Date()
                task.looked = Date()
                if request["unread"] as? Bool == true { tab.unread = AgentFeed.Unread(session: task.id) }
                shared.schedule(task)
            }
            return ["tab": tab.id.uuidString, "session": task.id]
        }
        if let id = (request["keep"] as? String).flatMap(UUID.init(uuidString:)), let tab = browser.everyTab.first(where: { $0.id == id }) {
            Folders.shared.keep([tab], in: browser)
        }
        if let id = (request["read"] as? String).flatMap(UUID.init(uuidString:)), let tab = browser.everyTab.first(where: { $0.id == id }) {
            AgentFeed.shared.read(tab)
        }
        if let seconds = request["advance"] as? Double { testOffset += max(0, seconds); shared.sweep() }
        return ["choice": browser.prefs.agentTabsAfter.rawValue,
                "tabs": browser.everyTab.map { ["id": $0.id.uuidString, "url": $0.address?.absoluteString ?? "", "agent": $0.agent ?? "", "bench": $0.bench,
                                               "unread": $0.unread != nil, "loading": $0.loading, "draft": $0.draft] as [String: Any] }]
    }
}
