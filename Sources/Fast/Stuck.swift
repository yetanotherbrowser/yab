import AppKit

// A page that has hung out of sight, put down.
//
// A page's script can go round a loop it never leaves. In front of you that
// is a page that stopped moving, and you see it. Behind another tab nobody
// sees it: its process holds a whole core for hours, the fans come on, and
// nothing on screen says which page it is. Nothing in WebKit catches it
// either. Freezing a page, Chrome's answer, and slowing its timers stop the
// next task, never the one running; WebKit's own CPU limit is checked by a
// timer inside the very process that is stuck.
//
// So the browser watches from outside. Once a minute it reads how much CPU
// each tab out of sight has taken, a syscall that wakes no page. A tab that
// has used more than a quarter of a core for five minutes is asked something that
// takes no time at all; a page doing heavy work on purpose, an export, a
// build, keeps its main thread free and answers. One that fails to answer
// twice running is stuck, and is put to sleep without being asked anything
// more: its picture can't be drawn and it can't say whether it holds a draft,
// so it goes down with no picture, and comes back reloaded at its address,
// as any tab asleep does.
//
// The one thing that would make that a loss is something typed and not sent.
// The page says so itself while it is still answering (Forms.swift), so a
// stuck page known to hold a draft is left running, and asked about only
// when you come back to it: Wait, or Reload. Nothing in the sidebar says it
// before then; it's rare, and a word on a tab is one more thing to learn.
//
// What can never sleep never goes either: the tab on screen, sound, a call,
// a download, a video out in its window, an agent working in it. Pins, kept
// rows and sites kept awake do go: stuck is stuck, and a pin comes back
// exactly as any tab does. Grown heavy, they stay (`lighten`).
//
// The page in front can hang for a reason that isn't its own. Every page
// draws through one GPU process, WebKit's, and waits on it for some things:
// an audio session, a decoder, pixels read back. A GPU process that stops
// answering holds every page at once, each still on its main thread and
// spending nothing, and the window keeps the last picture it had. On
// 2026-10-08 a fresh one hung in AudioToolbox while it registered the Opus
// decoder for a new page (AudioComponentFindNext), and stayed there: a tab
// picked went on showing the one before it, X never loaded, and every page
// waited until the GPU process was ended by hand. WebKit started another at
// once, and the pages came back where they were.
//
// So while its window is on screen, the page in front is asked something
// that takes it no time, every fifteen seconds. Twice running without an
// answer, while it spent next to no CPU, it is waiting on another process,
// not working; if the GPU process spent next to none too, it isn't working
// for the page either, and it is ended, at most once in five minutes. A page
// spinning in its own script spends a core, and is left alone, as before.
// So is the GPU process while a call is on or a page plays sound, in any
// window: every call's sound, microphone and camera run through it, and a
// call it took down stayed silent until rejoined (feedback #398).

/// What the browser knows about each page process it is watching.
@MainActor
final class StuckWatch {
    /// Readings of a process's CPU time, oldest first, a window's worth.
    var seen: [Int32: [(at: Date, cpu: Double)]] = [:]
    /// How many times running a process failed to answer.
    var unanswered: [Int32: Int] = [:]
    /// Asks in flight, so an answer that comes late counts for nothing.
    var asking: Set<Int32> = []
    var timer: Timer?
    /// The quicker look at the agents' pages (`lookAtAgentPages`).
    var agentTimer: Timer?
    /// Pages ending, and when each tab's page last crashed, the last
    /// minute's worth (Dialogs.swift: a page that keeps crashing is not
    /// loaded again).
    let ends = PageEnds()
    /// Tabs whose process the browser itself is ending: their page is
    /// loaded again when it goes, and it isn't counted as a crash.
    var ending: Set<UUID> = []
    /// Tabs whose stuck page you stopped (`unstick`): when its process
    /// goes, the page stays stopped and says why, not loaded again.
    var halting: Set<UUID> = []
    /// Tabs whose page grew past the memory limit again after being loaded
    /// again for it: when its process goes, it stays stopped and says why.
    var outgrown: Set<UUID> = []
    /// The last of stop or reload pressed on each tab being asked
    /// (`unstick`), true for reload: a stop after a reload wins.
    var nudged: [UUID: Bool] = [:]
    /// What an agent is told with its next look at a tab (AgentPage).
    static var notices: [UUID: String] = [:]
    /// The persistent page overlay after the memory watcher stops a page.
    /// Agent tools check the same state before trying to read or reload it.
    static let memoryStopped = "This page kept taking more memory, so Yab stopped it"
    /// When an agent's page was last loaded again for its size: a page that
    /// grows straight back is left alone for ten minutes, not reloaded on
    /// every look.
    var reloaded: [UUID: Date] = [:]

    /// The page in front, asked whether it answers (`askFront`): asked now,
    /// failed answers in a row, and the processes as they were at the first
    /// of those asks.
    var frontAsking = false
    var frontStrikes = 0
    var frontLook: FrontLook?
    var frontTimer: Timer?

    func stop() {
        for clock in [timer, agentTimer, frontTimer] { clock?.invalidate() }
        timer = nil; agentTimer = nil; frontTimer = nil
    }
    /// Why the page in front wasn't asked the last time round, nil if it was.
    var frontSkip: String?
    struct FrontLook {
        let at: Date
        let page: Int32, pageCPU: Double
        let gpu: Int32, gpuCPU: Double, gpuBorn: UInt64
    }
    /// When the GPU process was last ended for holding the page in front:
    /// one process for every window, so once for all of them.
    static var gpuEnded: Date?

    /// A page out of sight bigger than this goes to sleep while memory is
    /// short, Chrome's Memory Saver for a page that has swollen: 1.5 GB,
    /// 1 GB on a Mac with 8 GB or less, or `memory.heavy` in MB for the
    /// bench.
    static var heavy: UInt64 {
        let set = Store.settings.double(forKey: "memory.heavy")
        if set > 0 { return UInt64(set) << 20 }
        return ProcessInfo.processInfo.physicalMemory <= 8 << 30 ? 1 << 30 : 1536 << 20
    }
    /// With memory to spare, as macOS says while its pressure is normal, a
    /// page is put down for its size only past a quarter of the Mac's
    /// memory, 4 GB on 16, about where WebKit ends a hidden page in Safari,
    /// or `memory.roomy` in MB for the bench. A Figma file or a YouTube tab
    /// of a gigabyte and a half came back loaded again ten minutes after it
    /// was left, on Macs that had the room to keep it (#446).
    static var roomy: UInt64 {
        let set = Store.settings.double(forKey: "memory.roomy")
        if set > 0 { return UInt64(set) << 20 }
        return max(heavy, ProcessInfo.processInfo.physicalMemory / 4)
    }
    /// The size past which a page out of sight goes, at macOS's pressure
    /// `level` (1 normal, 2 warning, 4 critical; nil when it won't say,
    /// taken as short).
    static func heavy(at level: Int?) -> UInt64 {
        (level ?? 2) >= 2 ? heavy : roomy
    }
    /// A page an agent works in, which can't be put to sleep under it, is
    /// loaded again past this: 2 GB, 1.5 GB with 8 GB or less, or
    /// `memory.agent` in MB.
    static var agentHeavy: UInt64 {
        let set = Store.settings.double(forKey: "memory.agent")
        if set > 0 { return UInt64(set) << 20 }
        return ProcessInfo.processInfo.physicalMemory <= 8 << 30 ? 1536 << 20 : 2 << 30
    }

    /// How long a page has to keep a core busy. Five minutes, a common
    /// wait before freezing a page out of sight, or `stuck.after` in
    /// seconds for the bench.
    static var window: TimeInterval {
        let set = Store.settings.double(forKey: "stuck.after")
        return set > 0 ? set : 5 * 60
    }
    /// How often to look, and to ask again. A minute, a fifth of the
    /// window when the bench shortens it.
    static var every: TimeInterval { min(60, max(2, window / 5)) }
    /// How long a page has to answer.
    static var patience: TimeInterval {
        let set = Store.settings.double(forKey: "stuck.patience")
        return set > 0 ? set : 10
    }
    /// A quarter of a core, on average, over the whole window. A page out
    /// of sight runs at background priority, and on a busy Mac a page stuck
    /// in a loop may get no more than a third of one; asking one that is only
    /// working costs nothing, it answers.
    static let share = 0.25
    /// Failed answers in a row that make a page stuck.
    static let strikes = 2
    /// How long a page you stopped or reloaded has to answer before its
    /// process is ended (`unstick`), or `stuck.nudge` in seconds for the
    /// bench.
    static var nudge: TimeInterval {
        let set = Store.settings.double(forKey: "stuck.nudge")
        return set > 0 ? set : 2
    }

    /// How often the page in front is asked, or `stuck.front` in seconds
    /// for the bench.
    static var frontEvery: TimeInterval {
        let set = Store.settings.double(forKey: "stuck.front")
        return set > 0 ? set : 15
    }
    /// Under this share of a core, a process is waiting, not working.
    static let waiting = 0.05
    /// The GPU process is ended no more often than this.
    static let gpuRest: TimeInterval = 5 * 60
}

extension Browser {
    /// Started once, at launch, beside the watch for sleep.
    func watchForStuck() {
        Self.watchReaching()
        MemoryCeiling.start()
        let timer = Timer(timeInterval: StuckWatch.every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookForStuck() }
        }
        timer.tolerance = StuckWatch.every / 4
        RunLoop.main.add(timer, forMode: .common)
        stuck.timer = timer
        // The agents' pages, more often: a page grows gigabytes a minute,
        // and one an agent drives is never put to sleep under it.
        let agents = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookAtAgentPages() }
        }
        agents.tolerance = 1
        RunLoop.main.add(agents, forMode: .common)
        stuck.agentTimer = agents
        let front = Timer(timeInterval: StuckWatch.frontEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.askFront() }
        }
        front.tolerance = StuckWatch.frontEvery / 4
        RunLoop.main.add(front, forMode: .common)
        stuck.frontTimer = front
    }

    /// The page in front, asked something that takes it no time, while its
    /// window is on screen, Yab in front or not, and nothing of the page's
    /// own holds it: its alert, or Developer Tools, which may have it paused.
    func askFront() {
        guard !stuck.frontAsking else { return }
        let window = BrowserWindows.shared.window(for: self), tab = active, web = tab?.builtPage
        let pid = web?.contentProcess, gpu = web?.gpuProcess
        // Why nothing is asked now, for the bench (`stuck`).
        stuck.frontSkip = devOpen ? "Developer Tools"
            : window?.occlusionState.contains(.visible) != true ? "window not on screen"
            : tab == nil || tab?.asleep == true || tab?.isBlank == true || web == nil ? "no page"
            : tab?.asks.contains(where: { [.alert, .confirm, .prompt].contains($0.kind) }) == true ? "the page's dialog"
            : pid == nil ? "no page process" : gpu == nil ? "no GPU process" : nil
        guard stuck.frontSkip == nil, let tab, let web, let pid, let gpu else {
            stuck.frontStrikes = 0
            return
        }
        if stuck.frontStrikes == 0 || stuck.frontLook?.page != pid || stuck.frontLook?.gpu != gpu {
            guard let cpu = Self.cpuTime(pid), let gpuCPU = Self.cpuTime(gpu), let born = PageProcessLife.started(gpu) else { return }
            stuck.frontStrikes = 0
            stuck.frontLook = StuckWatch.FrontLook(at: Date(), page: pid, pageCPU: cpu, gpu: gpu, gpuCPU: gpuCPU, gpuBorn: born)
        }
        stuck.frontAsking = true
        let asked = Date(), patience = StuckWatch.patience
        var answered = false
        web.run("1", gesture: false) { [weak self] _ in
            MainActor.assumeIsolated {
                answered = true
                self?.stuck.frontAsking = false
                self?.stuck.frontStrikes = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, !answered else { return }
                self.stuck.frontAsking = false
                // Called late, the main thread was held, and the answer may
                // be waiting behind it; another tab in front is another page.
                guard Date().timeIntervalSince(asked) < patience + 1, let tab, tab === self.active,
                      tab.builtPage?.contentProcess == pid
                else {
                    self.stuck.frontStrikes = 0
                    return
                }
                self.stuck.frontStrikes += 1
                if self.stuck.frontStrikes < StuckWatch.strikes {
                    self.askFront()
                } else if let look = self.stuck.frontLook {
                    self.stuck.frontStrikes = 0
                    self.judgeFront(look, tab)
                }
            }
        }
    }

    /// The page in front answered nothing twice running. Spending next to
    /// no CPU it was waiting; the GPU process spending next to none too
    /// wasn't working for it, and is ended. WebKit starts another, and the
    /// pages draw again where they were, a WebGL canvas or a video started
    /// over.
    private func judgeFront(_ look: StuckWatch.FrontLook, _ tab: Tab) {
        let span = Date().timeIntervalSince(look.at)
        guard span > 0, let cpu = Self.cpuTime(look.page), let gpuCPU = Self.cpuTime(look.gpu) else { return }
        let page = (cpu - look.pageCPU) / span, gpu = (gpuCPU - look.gpuCPU) / span
        let words = String(format: "page in front unanswered %.0f s, its process %d at %.0f%% of a core, the GPU process %d at %.0f%%",
                           span, look.page, page * 100, look.gpu, gpu * 100)
        guard page < StuckWatch.waiting, gpu < StuckWatch.waiting else {
            // Spinning and deaf this long is a page in its own loop: left to
            // spin, since nobody has reached for it, but known deaf, so
            // whatever you do to it next ends it first (Deaf.swift).
            Watchdog.note(words + (page >= StuckWatch.waiting ? ": spinning, known deaf" : ": working, left"))
            if page >= StuckWatch.waiting, tab.deaf == nil { tab.deaf = Date() }
            return
        }
        if let last = StuckWatch.gpuEnded, Date().timeIntervalSince(last) < StuckWatch.gpuRest {
            Watchdog.note(words + ": GPU process ended under five minutes ago, left")
            return
        }
        if let held = Self.gpuHolds() {
            Watchdog.note(words + ": \(held), left")
            return
        }
        StuckWatch.gpuEnded = Date()
        Watchdog.note(words + ": GPU process ended")
        PageProcessLife.end(look.gpu, born: look.gpuBorn)
    }

    /// What ending the GPU process would cut, in any window: a call, or a
    /// page's sound. WebKit plays every page's sound and runs every call's
    /// microphone and camera through that one process, and a call it took
    /// down stays silent until it is joined again (feedback #398, Meet
    /// silent a minute in, twice). A GPU process that is only slow comes
    /// back by itself; a call cut by Yab never does.
    static func gpuHolds(_ browsers: [Browser]? = nil) -> String? {
        for browser in browsers ?? BrowserWindows.shared.browsers {
            for tab in browser.everyTab + browser.outside where !tab.asleep {
                if tab.onCall { return "a call is on" }
                if let media = tab.builtPage?.captureStatus, media.camera != .none || media.microphone != .none {
                    return "a call is on"
                }
                if tab.noisy { return "a page plays sound" }
            }
        }
        return nil
    }

    /// Every page process an agent works in, weighed (`lighten`).
    func lookAtAgentPages() {
        var pages: [Int32: [Tab]] = [:]
        for tab in everyTab {
            guard let web = tab.builtPage, let pid = web.contentProcess else { continue }
            pages[pid, default: []].append(tab)
        }
        for (pid, group) in pages where group.contains(where: { $0.worker != nil }) {
            if lighten(pid, group) {
                stuck.seen[pid] = nil
                stuck.unanswered[pid] = nil
            }
        }
    }

    /// One look at every page out of sight.
    func lookForStuck() {
        let now = Date()
        // Pages by process: tabs a page opened can share one, and a process
        // is put down only when none of its pages has to stay.
        var pages: [Int32: [Tab]] = [:]
        for tab in tabs + parkedTabs {
            guard let web = tab.builtPage, let pid = web.contentProcess else { continue }
            pages[pid, default: []].append(tab)
        }
        for pid in Array(stuck.seen.keys) where pages[pid] == nil {
            stuck.seen[pid] = nil
            stuck.unanswered[pid] = nil
        }
        for (pid, group) in pages {
            if lighten(pid, group) {
                stuck.seen[pid] = nil
                stuck.unanswered[pid] = nil
                continue
            }
            guard group.allSatisfy({ mayPutDown($0) }), let cpu = Self.cpuTime(pid) else {
                stuck.seen[pid] = nil
                stuck.unanswered[pid] = nil
                continue
            }
            var seen = stuck.seen[pid] ?? []
            seen.append((now, cpu))
            // A window's worth and the one reading before it.
            while seen.count > 2, now.timeIntervalSince(seen[1].at) >= StuckWatch.window { seen.removeFirst() }
            stuck.seen[pid] = seen
            guard let first = seen.first else { continue }
            let span = now.timeIntervalSince(first.at)
            guard span >= StuckWatch.window * 0.95, (cpu - first.cpu) / span >= StuckWatch.share else {
                stuck.unanswered[pid] = nil
                continue
            }
            ask(pid, group)
        }
    }

    /// A page grown too big. Out of sight, it sleeps as any tab does, its
    /// picture kept, loaded again when you come back; nothing is said, as
    /// nothing is when a tab sleeps after four hours. One an agent works
    /// in is loaded again where it is, and the agent told with its next
    /// look, since a page gone from under it would leave it lost.
    private func lighten(_ pid: Int32, _ group: [Tab]) -> Bool {
        guard let size = Self.footprint(pid) else { return false }
        if group.contains(where: { $0.worker != nil }) {
            guard size > StuckWatch.agentHeavy else { return false }
            // Grown past the limit again within ten minutes of being loaded
            // again: it would only grow again. Left alone for those ten
            // minutes, one page an agent drove reached 39 GB (2026-10-22).
            let again = group.contains { stuck.reloaded[$0.id].map { Date().timeIntervalSince($0) < 600 } ?? false }
            // Under twice the limit, what keeps any page awake (on screen,
            // still loading, a download) keeps this one too; past it,
            // nothing does: a page that never finishes loading grew on.
            if !again, size < 2 * StuckWatch.agentHeavy, !group.allSatisfy({ mayReloadForMemory($0) }) { return false }
            let gb = String(format: "%.1f", Double(size) / Double(1 << 30))
            for tab in group {
                if again {
                    StuckWatch.notices[tab.id] = "The page grew to \(gb) GB of memory again after Yab loaded it again, so Yab stopped it. Don't open it again in this task; tell the user this page uses too much memory."
                    stuck.outgrown.insert(tab.id)
                } else {
                    StuckWatch.notices[tab.id] = "The page grew to \(gb) GB of memory, so Yab loaded it again at the same address: what you did on it before is gone, read it again."
                    stuck.ending.insert(tab.id)
                    stuck.reloaded[tab.id] = Date()
                }
            }
            Watchdog.note("agent page \(pid) at \(gb) GB: \(again ? "stopped" : "loaded again")")
            group.first?.builtPage?.killContent()
            return true
        }
        // Not one of the last few you were on, nor a pin, a kept row or a
        // site kept awake: grown heavy is no reason to reload what you go
        // back and forth between or chose to keep. Memory running out
        // still can, last (Sleep.swift).
        // Nor, while memory is plentiful, for a size the Mac has room for.
        let used = recentlyUsed(), limit = StuckWatch.heavy(at: Pressure.level)
        guard size > limit, group.allSatisfy({ mayLighten($0) && !used.contains($0.id) }) else { return false }
        Watchdog.note(String(format: "page %d out of sight at %.1f GB, past %.1f GB: %d tab%@ put to sleep",
                             pid, Double(size) / Double(1 << 30), Double(limit) / Double(1 << 30),
                             group.count, group.count == 1 ? "" : "s"))
        // A pin or a kept row grown this big goes too (`mayPutDown`).
        for tab in group { sleep(tab, waiving: Self.chosen, reason: .heavyPage) }
        return true
    }

    /// What a process holds in memory, as Activity Monitor's Memory says it.
    static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : nil
    }

    /// Whether a tab may be put down for being stuck: everything that keeps
    /// a tab awake keeps it, except being pinned, kept or a site kept awake.
    /// Nor while an agent works in it.
    func mayPutDown(_ tab: Tab) -> Bool {
        if tab.worker != nil { return false }
        let reason = awake(because: tab)
        // A page that went deaf while loading would never finish loading.
        if reason == "still loading", tab.deaf != nil { return true }
        return reason == nil || Self.chosen.contains(reason ?? "")
    }

    /// Whether a page grown heavy may be put to sleep: only one nothing
    /// keeps awake and left alone ten minutes, as for urgent memory relief.
    /// Switching through a few more tabs must not reload a document just
    /// left, even after it falls out of the last five used (#446).
    func mayLighten(_ tab: Tab) -> Bool {
        tab.worker == nil && tab.idle(at: AwakeClock.now) >= Self.seenGrace && awake(because: tab) == nil
    }

    /// An agent can reread a page after a memory reload, but cannot restore
    /// an ongoing call, a download or something typed and not sent.
    func mayReloadForMemory(_ tab: Tab) -> Bool {
        guard !tab.draft else { return false }
        let reason = awake(because: tab, forAgentReload: true)
        return reason == nil || Self.chosen.contains(reason ?? "")
    }

    /// Something that takes a page no time at all, unless its main thread is
    /// held. No answer in time is a strike; two running and the page is stuck.
    private func ask(_ pid: Int32, _ group: [Tab]) {
        guard !stuck.asking.contains(pid), let web = group.first?.builtPage else { return }
        stuck.asking.insert(pid)
        var answered = false
        web.run("1", gesture: false) { [weak self] _ in
            MainActor.assumeIsolated {
                answered = true
                self?.stuck.asking.remove(pid)
                self?.stuck.unanswered[pid] = nil
                // Answering again, it is no longer stuck.
                for tab in group where tab.stuckDraft { tab.stuckDraft = false }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + StuckWatch.patience) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !answered else { return }
                self.stuck.asking.remove(pid)
                let strikes = (self.stuck.unanswered[pid] ?? 0) + 1
                self.stuck.unanswered[pid] = strikes
                guard strikes >= StuckWatch.strikes else { return }
                self.putDownStuck(pid, group)
            }
        }
    }

    /// Asleep with no picture, or, holding a draft, left for you to decide.
    private func putDownStuck(_ pid: Int32, _ group: [Tab]) {
        // Looked again: you may have come back to it while it was asked.
        guard group.allSatisfy({ mayPutDown($0) && $0.builtPage?.contentProcess == pid }) else { return }
        if group.contains(where: \.draft) {
            for tab in group { tab.stuckDraft = true }
            return
        }
        stuck.seen[pid] = nil
        stuck.unanswered[pid] = nil
        // Its process ended by name first: closing the view of a page that
        // never answers is a request it never reads.
        group.first?.builtPage?.killContent()
        for tab in group {
            pageTranslation.forget(tab)
            tab.sleep(picture: nil, reason: .stuckPage)
        }
    }

    /// Coming back to a stuck page that holds a draft: the one question.
    func askIfStuck(_ tab: Tab?) {
        guard let tab, tab.stuckDraft, !tab.asks.contains(where: { $0.kind == .stuck }) else { return }
        var question = PageAsk(kind: .stuck, host: tab.address?.host() ?? "")
        question.message = PageAsk.draftLost
        ask(question, on: tab) { [weak self, weak tab] reply, _ in
            guard let self, let tab else { return }
            tab.stuckDraft = false
            guard case .yes = reply, let pid = tab.builtPage?.contentProcess else { return }
            self.stuck.seen[pid] = nil
            self.stuck.unanswered[pid] = nil
            // WebKit tells the browser the process went, and a tab in front
            // is loaded again from there (webViewWebContentProcessDidTerminate);
            // loaded here only if it said nothing.
            self.stuck.ending.insert(tab.id)
            tab.builtPage?.killContent()
        }
    }

    /// Stop or reload, by a door or a key, on a page that has stopped
    /// answering. WebKit hands both to the page's process, and one held by
    /// its own script in a loop never reads them: the cross did nothing and
    /// the arrow came back with the page still frozen. So the page is asked
    /// something that takes it no time; not answered in `nudge`, its process
    /// is ended, as browsers end a page that won't let go. A reload
    /// then loads it again at once; a stop leaves it stopped, saying so,
    /// with Reload on it. Nothing is asked while the page's own dialog or
    /// Developer Tools may be what holds it.
    func unstick(_ tab: Tab, reload: Bool) {
        guard let web = tab.builtPage, !tab.isBlank, !devOpen,
              !tab.asks.contains(where: { [.alert, .confirm, .prompt].contains($0.kind) }),
              let pid = web.contentProcess, let born = PageProcessLife.started(pid)
        else { return }
        stuck.nudged[tab.id] = reload
        var answered = false
        web.run("1", gesture: false) { _ in MainActor.assumeIsolated { answered = true } }
        // Known deaf already (Deaf.swift): no need to give it the time.
        let wait = tab.deaf != nil ? 0.3 : StuckWatch.nudge
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard !answered, let self, let tab, !tab.gone,
                      tab.builtPage?.contentProcess == pid, PageProcessLife.started(pid) == born
                else { return }
                let reload = self.stuck.nudged.removeValue(forKey: tab.id) ?? reload
                Watchdog.note("page \(pid) unanswered \(StuckWatch.nudge) s after \(reload ? "reload" : "stop"): ended")
                if reload { self.stuck.ending.insert(tab.id) } else { self.stuck.halting.insert(tab.id) }
                tab.builtPage?.killContent()
            }
        }
    }

    /// Leaving it unanswered is Wait: nothing waits on the tab in the sidebar.
    func leaveStuck(_ tab: Tab) {
        guard tab.asks.first?.kind == .stuck else { return }
        // A page that went deaf in front is asked again when next reached
        // for (Deaf.swift); one left with a draft, when next shown.
        let deaf = tab.deafAsked
        dismissAsk(tab)
        if !deaf { tab.stuckDraft = true }
    }

    /// The CPU a process has taken since it began, in seconds.
    static func cpuTime(_ pid: Int32) -> Double? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { return nil }
        return Double(info.ri_user_time + info.ri_system_time) * StuckWatch.tick
    }
}

extension StuckWatch {
    /// Mach time units to seconds: nanoseconds on Intel, not on Apple silicon.
    static let tick: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1e9
    }()
}
