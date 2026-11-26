import AppKit
import IOKit.ps
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process, a hundred to three
// hundred megabytes, running its timers, holding its sockets, for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So, with Put idle tabs to sleep on in Settings, a tab
// left alone for four hours gives its page back, and keeps what it takes to
// come back exactly where it was: its history, its scroll position, and a
// picture to show while the page is rebuilt underneath (see Tab.sleep). Four
// hours is Chrome's Memory Saver at its middle setting, and like Memory
// Saver the timer is off until turned on: a page put
// down costs a wait and sometimes what it held, and a tab loaded again on
// return is what people wrote in about. Memory running out (below) does the
// urgent work whatever the switch says.
//
// Four hours of the Mac awake, that is: a lid closed over lunch is no time
// spent away from a tab, or every tab would go at the first look after it
// (AwakeClock).
//
// A tab you keep coming back to, switched to more than fifteen times, never
// goes on the timer (Chrome's medium setting, its TabRevisitTracker, uses the same rule):
// a mail or a chat looked at all day is wanted awake, however long the gap
// since the last look. Memory running short may still take it, after the
// tabs nobody comes back to. The count goes with the tab across launches.
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs and kept ones in any space
// (those are put down by hand, with ⌘W), a tab playing sound, on a call,
// sending a download, holding its video out in the little window, holding
// something typed or picked and not sent, waiting on a window it opened, a
// sign-in, to answer, a site allowed to send notifications, which says
// nothing once put down, or a site on the list kept awake (AwakeSites:
// WhatsApp, Slack, Gmail and the like from the start, Chrome's "Always
// keep these sites active").
//
// When macOS says memory is out, critical, the heaviest page nobody is
// looking at goes, and the next a moment later, until macOS stops saying
// so, rather than every hidden tab at once. It
// takes only what Chrome and DuckDuckGo take: never a tab seen in the last
// ten minutes or heard in the last minute (Chrome's protection times,
// DuckDuckGo's ten minutes), never a pin, a kept row or a site kept awake,
// which both leave alone whatever the memory; a site allowed to send
// notifications goes last. When nothing older is left, nothing goes, and
// macOS swaps, as it does under Chrome. Memory short, "warning", puts
// nothing down, as neither of them does: a Mac with 8 GB sits there all
// day. macOS says the level once, as it comes, so while it is above normal
// relief looks again every few seconds, for when it turns
// critical. A page that doesn't answer whether it holds a draft is taken at
// what it said last; one stuck in a loop never answers, and was once all
// relief waited on, minutes of memory out with nothing put down
// (evals/lowram).
//
// The last few tabs you were on are none of these: going back and forth
// between a list and a page opened from it, or between two documents, has
// to find each one where you left it, scrolled and as it was, never loaded
// again. Neither the timer nor a page grown heavy puts them down, nor
// memory running short; memory out takes them only after every other tab
// has gone, the one left longest ago first, before macOS starts ending
// processes itself (feedback #44).
//
// Saving power (Settings › Tabs › Energy Saver, when the person turned it
// on and it holds), the four hours are one. Chrome's Energy Saver throttles
// background pages and puts none to sleep; Yab shortens the wait to an hour
// as well, a page asleep being one that spends nothing at all.

extension Browser {
    /// How long a tab has to go without being looked at: four hours, one
    /// while saving power, or `sleep.after` in seconds, for the bench and
    /// the measurements.
    static var sleepAfter: TimeInterval { sleepAfter(set: Store.settings.double(forKey: "sleep.after"), thrift: Thrift.on) }

    static let usualSleepAfter: TimeInterval = 4 * 3600
    static let thriftSleepAfter: TimeInterval = 3600

    static func sleepAfter(set: TimeInterval, thrift: Bool) -> TimeInterval {
        let usual = set > 0 ? set : usualSleepAfter
        return thrift ? min(usual, thriftSleepAfter) : usual
    }

    /// A tab switched to more than this many times never sleeps on the
    /// timer (Chrome's medium setting, its TabRevisitTracker).
    static let keepRevisited = 15

    /// How long a tab is left alone before memory running out can take it:
    /// Chrome's ten minutes (kNonVisiblePagesUrgentProtectionTime) and
    /// DuckDuckGo's (tabInactivityPeriod). Memory short never takes one.
    static let seenGrace: TimeInterval = 10 * 60
    /// How long after a tab stops playing sound it still counts as playing,
    /// Chrome's minute (kTabAudioProtectionTime): a song between tracks, a
    /// call between rings.
    static let heardGrace: TimeInterval = 60

    /// While memory stays short, how often relief looks again. macOS says so
    /// once, as it comes, and may then say nothing for an hour on a Mac that
    /// lives at "warning"; meanwhile a tab passes its ten minutes alone, or
    /// half a minute goes by since the last one went. Chrome looks every
    /// five seconds too.
    static let lookEvery: TimeInterval = 5
    /// How long a tab that could not be put down, holding a draft or not
    /// answering, is left before it is asked again in the same stretch.
    static let reaskAfter: TimeInterval = 2 * 60
    /// How long a page has to say whether it holds a draft, and to draw its
    /// picture. A page stuck in a loop, or paged out to disk, never says,
    /// and nothing else could go while it was waited for (evals/lowram,
    /// stuck.sh: four minutes of memory out with not a tab put down).
    static let pageAnswer: TimeInterval = 1.5

    /// What a hand may put down all the same, Put Tab to Sleep in its menu:
    /// a pin or a kept row is yours to put down, as ⌘W does, and so is a
    /// page that takes long to load: its load stops, and it loads again
    /// when it is woken (register row 906).
    static let byHand: Set<String> = ["pinned", "kept", "a site kept awake", "may send notifications", "still loading"]
    /// What memory running out may take, after everything free and only
    /// after ten minutes alone: a site allowed to send notifications says
    /// nothing once put down, but it is a page, not a pin; nor does an
    /// agent's tab, loaded again when its agent reads it.
    static let lastToGo: Set<String> = ["may send notifications", "a bench tab"]

    /// What keeps a tab awake by your own choice: put down by hand, or
    /// for being stuck, as any tab is.
    static let chosen: Set<String> = ["pinned", "kept", "a site kept awake"]

    /// How many of the tabs you were last on stay awake (`recentlyUsed`).
    static let keepRecent = 5

    /// The tab on screen was another: the one left is the one most recently
    /// used. A short list, a few more than are kept, so a closed tab in it
    /// leaves enough behind.
    func noteLeft(_ id: Tab.ID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.keepRecent * 3 { recent.removeLast(recent.count - Self.keepRecent * 3) }
    }

    /// The last few tabs you were on, the one just left first, the one on
    /// screen aside: what you go back and forth between.
    func recentlyUsed() -> [Tab.ID] {
        let open = Set((tabs + parkedTabs).map(\.id))
        return Array(recent.lazy.filter { $0 != self.activeID && open.contains($0) }.prefix(Self.keepRecent))
    }

    /// Started once, at launch.
    func watchForSleep() {
        let every = min(60, max(5, Browser.sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                // Asked afresh: a draft held last time may be sent by now.
                if !self.relieving { self.passedOver = [] }
                self.relieve(assuming: event.contains(.critical) ? 4 : 2)
            }
        }
        source.resume()
        pressure = source

        // Going over to saving power puts down at once what has already
        // gone an hour unwatched, rather than at the next minute's look.
        Thrift.watch(self) { [weak self] on in
            if on { self?.sleepIdle() }
        }

        // Pictures of sleeping tabs are for this run only: a tab brought
        // back from the last session has no page and no picture of one.
        // Once, not with every window: another window's sleeping tabs keep theirs.
        guard !Self.picturesCleared else { return }
        Self.picturesCleared = true
        Tab.disk.async { try? FileManager.default.removeItem(at: Tab.pictures) }
    }

    private static var picturesCleared = false

    /// The window is gone: its looks stop with it, or every closed window
    /// leaves four timers and an ear for memory running for good.
    func stopWatching() {
        stoppedWatching = true
        dozing?.invalidate(); dozing = nil
        pressure?.cancel(); pressure = nil
        nextLook?.cancel(); nextLook = nil
        Thrift.unwatch(self)
        stuck.stop()
    }

    /// Memory short: the heaviest tab that can sleep goes to sleep, and a
    /// moment later macOS is asked again, while it is critical. Short and
    /// not critical, one tab left alone for ten minutes, kept and pinned
    /// ones never, and no other for half a minute: every page put down is a
    /// page to wait for.
    func relieve(assuming assumed: Int = 1) {
        // Whatever Put idle tabs to sleep says: that switch is the timer's.
        guard !relieving, !stoppedWatching else { return }
        let level = Pressure.level ?? assumed
        guard level > 1 else {
            passedOver = []
            passedOverSince = nil
            nextLook?.cancel()
            nextLook = nil
            return
        }
        // Short, not out: nothing is put down (see the top of this file),
        // only looked at again, for when it is out.
        guard level >= 4 else {
            lookAgain()
            return
        }
        let now = AwakeClock.now
        if let since = passedOverSince, now - since >= Self.reaskAfter {
            passedOver = []
            passedOverSince = nil
        }
        guard let heaviest = relief(now: now) else {
            lookAgain()
            return
        }
        relieving = true
        sleep(heaviest, waiving: Self.lastToGo, urgent: true, reason: .memoryCritical) { [weak self] said in
            guard let self else { return }
            // Holding a draft, say, or not answering: not asked again for a
            // couple of minutes.
            if said != "asleep" {
                passedOver.insert(heaviest.id)
                if passedOverSince == nil { passedOverSince = AwakeClock.now }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                relieving = false
                relieve()
            }
        }
    }

    /// Memory still short and nothing to put down just now: look again in a
    /// moment, and on, until macOS says it is not.
    private func lookAgain() {
        guard nextLook == nil else { return }
        let look = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.nextLook = nil
                self?.relieve()
            }
        }
        nextLook = look
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookEvery, execute: look)
    }

    /// The tab memory running out puts down next, nil when none may go:
    /// only one left alone ten minutes, never a pin, a kept row or a site
    /// kept awake. `now` on the awake clock.
    func relief(now: TimeInterval) -> Tab? {
        let used = recentlyUsed()
        let able = (tabs + parkedTabs).filter { !passedOver.contains($0.id) && $0.idle(at: now) >= Self.seenGrace }
        let older = able.filter { !used.contains($0.id) }
        // Heaviest by what its sleep gives back: a process two tabs share,
        // an opener and the window it opened, halved between them, since
        // one of them asleep leaves it running (PageProcesses).
        let shares = PageProcesses.shares()
        func weight(_ tab: Tab) -> UInt64 {
            tab.builtPage.flatMap { shares?[ObjectIdentifier($0)] } ?? tab.weight
        }
        func heaviestOf(_ some: [Tab]) -> Tab? {
            some.map { ($0, weight($0)) }.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.idle(at: now) < b.0.idle(at: now) }?.0
        }
        let free = older.filter { awake(because: $0) == nil }
        // The tabs nobody keeps coming back to first, then those somebody does.
        if let one = heaviestOf(free.filter { !$0.revisited }) ?? heaviestOf(free) { return one }
        // Then a site allowed to send notifications.
        if let site = heaviestOf(older.filter { Self.lastToGo.contains(awake(because: $0) ?? "") }) { return site }
        // Then, nothing else left, the tabs you were just on, the one left
        // longest ago first.
        return used.reversed().lazy.compactMap { id in able.first { $0.id == id } }.first {
            let reason = awake(because: $0)
            return reason == nil || Self.lastToGo.contains(reason ?? "")
        }
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs else { return }
        let idle = idleTabs(within: given ?? Browser.sleepAfter, now: AwakeClock.now)
        for tab in idle where tab.builtPage?.engine != .chromium { self.sleep(tab, reason: .idle) }
        // Chromium pages answer the draft probe through one helper: 130 at
        // once all missed `pageAnswer` and none slept ("not answering").
        // A few at a time, each batch after the last has answered.
        sleepInTurn(idle.filter { $0.builtPage?.engine == .chromium })
    }

    private func sleepInTurn(_ tabs: [Tab], width: Int = 6) {
        guard !tabs.isEmpty else { return }
        let batch = tabs.prefix(width), rest = Array(tabs.dropFirst(width))
        var left = batch.count
        for tab in batch {
            self.sleep(tab, reason: .idle) { [weak self] _ in
                left -= 1
                if left == 0 { self?.sleepInTurn(rest, width: width) }
            }
        }
    }

    /// The tabs `sleepIdle` puts down, the one left longest first, never one
    /// you keep coming back to. `now` on the awake clock, so a Mac asleep
    /// counts for nothing.
    func idleTabs(within wait: TimeInterval, now: TimeInterval) -> [Tab] {
        let used = recentlyUsed()
        return (tabs + parkedTabs)
            .filter { $0.idle(at: now) >= wait && !$0.revisited && !used.contains($0.id) && awake(because: $0) == nil }
            .sorted { $0.idle(at: now) > $1.idle(at: now) }
    }

    private static var notedChromiumSleep = false

    /// Why a tab has to stay awake, nil when nothing keeps it. A waived
    /// reason is skipped here so it cannot hide another protection.
    func awake(because tab: Tab, forAgentReload: Bool = false, waiving: Set<String> = []) -> String? {
        if tab.id == activeID, !waiving.contains("on screen") { return "on screen" }
        if stagePair?.contains(tab.id) == true { return "on screen, beside the tab in front" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let page = tab.builtPage else { return "no page" }
        if tab.loading, !waiving.contains("still loading") { return "still loading" }
        if tab.noisy { return "playing sound" }
        if let heard = tab.heardAt, Date().timeIntervalSince(heard) < Self.heardGrace { return "played sound a moment ago" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if tab.pictureInPicture { return "its video is in picture in picture" }
        if tab.documentPiP.showing { return "its document is out" }
        let capture = page.captureStatus
        if capture.camera != .none || capture.microphone != .none { return "on a call" }
        if page.engine == .chromium, capture.screen != .none { return "on a call" }
        if downloading.contains(where: { $0.page === page }) { return "downloading" }
        // A chat's answer or a builder's page still coming (ChatBusy).
        if tab.chatBusy != nil { return "answering" }
        // A sign-in window hands its answer back to the page that opened it.
        if active?.opener == tab.id { return "the page on screen came from it" }
        // Nor while that window is open anywhere, behind another tab or out
        // in a small window, and still at its sign-in (Tab.waits): the
        // answer comes back to a page that is gone.
        let opened: (Tab) -> Bool = { $0.opener == tab.id && $0.waits(for: tab) }
        if tabs.contains(where: opened) || outside.contains(where: opened) { return "a window it opened is still open" }
        // Audible and native discard are now available on own CEF. They
        // do not establish screen capture/PiP or authenticated draft safety.
        if page.engine == .chromium,
           (page as? any PageSleepActivity)?.sleepActivityUnavailable != false {
            if !Self.notedChromiumSleep {
                Self.notedChromiumSleep = true
                print("YAB_PAGE_UNAVAILABLE chromium automatic sleep: capture and draft activity are not verified")
            }
            return "page activity unavailable"
        }
        // An agent's tab is its to read, after everything above that keeps
        // any page awake: memory out takes one its agent left alone ten
        // minutes (`lastToGo`), and reading it again wakes it (feedback
        // #131: 60 of them, 20 GB, never one put down).
        if tab.bench && !(forAgentReload && tab.worker != nil), !waiving.contains("a bench tab") { return "a bench tab" }
        // Only a hand, or a page grown huge or stuck, puts a pin down. A pin
        // in a space not on screen stays awake too: the chat pinned in
        // another space is the one you come back to after hours (feedback
        // #78).
        if tab.pin != nil, !waiving.contains("pinned") { return "pinned" }
        // A kept row is a pin with its title (Kept.swift), and the Arc
        // import puts Arc's pinned tabs there: kept the same way. Not a
        // live folder's own row (Tab.placedByFolder): the folder put it
        // there asleep, nobody chose to keep it, and once opened and left
        // it goes as today's tabs go (the timer, grown heavy, memory out).
        // Kept, every pull request opened from the folder stayed loaded for
        // the whole session, whatever it grew to and however short memory
        // was.
        if tab.kept, !tab.placedByFolder, !waiving.contains("kept") { return "kept" }
        if !waiving.contains("a site kept awake"), AwakeSites.shared.keeps(tab.address) { return "a site kept awake" }
        // A site that may send notifications: in any space, since a space
        // out of sight is exactly where they matter.
        if !waiving.contains("may send notifications"), SiteNotices.allowed(tab) { return "may send notifications" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go, looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    ///
    /// A page that doesn't answer in `pageAnswer` is taken at what it said
    /// last (Forms' `draft`): holding a draft, it stays; otherwise memory out
    /// (`urgent`) puts it down, and anything less leaves it for next time.
    /// Memory out puts pages down with no picture: drawing one wakes the page
    /// and takes memory just when there is none, and Chrome keeps none.
    /// Quit with a task still going on (Headless.linger): down at once,
    /// with no picture and nothing asked, as quitting would have ended it.
    func putDown(quitting tab: Tab) {
        pageTranslation.forget(tab)
        tab.sleep(picture: nil)
        tab.peek?.sleep(picture: nil)
    }

    /// `waiving` names the reasons to stay awake the caller may set aside:
    /// a hand's (`byHand`), memory running out's (`lastToGo`), a swollen or
    /// stuck page's (`chosen`).
    func sleep(_ tab: Tab, waiving: Set<String> = [], urgent: Bool = false, byHand: Bool = false, excluding group: Set<Tab.ID> = [], reason: FeedbackDiagnostics.SleepReason = .other, done: ((String) -> Void)? = nil) {
        let page = tab.builtPage.flatMap { $0.engine == .chromium ? $0 : nil }
        let revision = tab.engineNavigationRevision
        let requestedVisit = byHand && activeID == tab.id ? tab.visits : nil
        let visitsAtRequest = tab.visits
        let keeps = { [weak self] (tab: Tab) -> String? in
            guard let self else { return "page changed" }
            if let owner = tab.delegate as? Browser, owner !== self { return "page changed" }
            if let page {
                guard !tab.gone, tab.builtPage === page, tab.engineNavigationRevision == revision else { return "page changed" }
            }
            var skipped = waiving
            if let requestedVisit, tab.visits == requestedVisit { skipped.insert("on screen") }
            if let reason = self.awake(because: tab, waiving: skipped) { return reason }
            // An automatic decision belongs to this visit. Draft and picture
            // replies from before a return cannot put the document just used down.
            if !byHand, tab.visits != visitsAtRequest { return "visited while checking sleep" }
            return nil
        }
        if let reason = keeps(tab) {
            done?(reason)
            return
        }
        let down = { [weak self, weak tab] (picture: Data?) in
            guard let self, let tab else { return }
            if let reason = keeps(tab) {
                done?(reason)
                return
            }
            if byHand, tab.id == self.activeID {
                // Detach only after the draft and snapshot checks succeed.
                // The row stays, with no neighboring sleeping page woken.
                self.leaveForSleep(tab, excluding: group)
            }
            self.pageTranslation.forget(tab)
            tab.sleep(picture: picture, reason: byHand ? .manual : reason, maySleep: { keeps(tab) == nil }) { accepted in
                guard accepted else { done?(keeps(tab) ?? "native discard refused"); return }
                tab.peek?.sleep(picture: nil, reason: byHand ? .manual : reason)
                WrappedLedger.shared.add(.tabsSlept)
                if byHand { self.rememberSession() }
                done?("asleep")
            }
        }
        tab.unsaved(within: Self.pageAnswer) { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed == true || (typed == nil && tab.draft) {
                done?("holding something typed or picked")
                return
            }
            // Not answering by now is no reason to stay awake when it has
            // stopped answering for good (`Tab.deaf`): it would never go.
            if typed == nil, !urgent, tab.deaf == nil {
                done?("not answering")
                return
            }
            if let reason = keeps(tab) {
                done?(reason)
                return
            }
            // Not answering, and memory out: its process ended by name first,
            // as a stuck page's is (Stuck.swift), since closing the view of a
            // page that never answers is a request it never reads. Not when
            // another tab's page shares the process.
            // A page that stopped answering holds every page in its process
            // with it: ended whoever shares it.
            if typed == nil, let web = tab.builtPage, web.engine == .webKit, let pid = web.contentProcess, tab.deaf != nil
                || !(tabs + parkedTabs).contains(where: { $0 !== tab && $0.builtPage?.contentProcess == pid }) {
                web.killContent()
            }
            if urgent || (typed == nil && tab.deaf != nil) { return down(nil) }
            tab.readChromiumPlace { [weak tab] in
                tab?.snapshot(within: Self.pageAnswer) { picture in down(picture) }
            }
        }
    }
}

/// Seconds the Mac has been awake since it started: a clock that stands
/// still while it sleeps, for how long a tab has gone unwatched. The wall
/// clock moves on through a night with the lid closed, and every tab would
/// count the night as time left alone.
enum AwakeClock {
    static var now: TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }

    /// A moment on the wall clock, on this one: as long before now as it
    /// was, the Mac awake all the while. Before it started, it is a number
    /// below zero, and still as long ago.
    static func since(_ when: Date, now: TimeInterval = AwakeClock.now, wall: Date = Date()) -> TimeInterval {
        now - max(0, wall.timeIntervalSince(when))
    }
}

/// How short memory is, as macOS rates it: 1 normal, 2 warning, 4 critical.
/// Asked of the kernel each time rather than remembered from the event, so
/// a relief that has done its job stops. Nil if the kernel won't say.
enum Pressure {
    /// For the bench and tests: a level to act on instead of the kernel's.
    nonisolated(unsafe) static var forced: Int?

    static var level: Int? {
        if let forced { return forced }
        // A unit test's memory is the farm Mac's, not the case it tests:
        // a Mac swapping under other jobs turned Auto's Chromium tabs into
        // WebKit ones (EngineRules.memoryTight) and failed engine and save
        // tests by the hour. A test that is about memory forces its level.
        if Store.unitTests { return 1 }
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
}

/// Saving power: Settings › Tabs › Energy Saver holding now, below 20%
/// on battery or unplugged, as the person picked (off unless they did).
/// Chromium's Energy Saver is the same choice and the same rule
/// (EnergySaver), so both engines start and stop saving together.
/// macOS Low Power Mode alone starts neither, as in Chromium.
@MainActor
enum Thrift {
    private(set) static var on = false
    /// For the bench: saving power whatever the setting and the battery say.
    static var forced = false {
        didSet {
            look()
            ChromiumEnergySaver.tell()
        }
    }
    /// Everyone told of a change, each owner its own: one gone stops hearing.
    private static var watchers: [(owner: () -> AnyObject?, changed: (Bool) -> Void)] = []
    private static var battery: CFRunLoopSource?

    static func watch(_ owner: AnyObject, _ changed: @escaping (Bool) -> Void) {
        watchers.removeAll { $0.owner() == nil || $0.owner() === owner }
        watchers.append(({ [weak owner] in owner }, changed))
        // Every change to any power source, a percent gone, a cable in or
        // out, delivered on the main run loop. One source for every watcher.
        if battery == nil, let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { Thrift.look() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            battery = source
        }
        look()
    }

    static func unwatch(_ owner: AnyObject) {
        watchers.removeAll { $0.owner() == nil || $0.owner() === owner }
    }

    static func look() {
        let choice = EnergySaver.current
        var now = forced
        // The power source is read only for a choice that weighs it.
        if !now, choice != .off {
            let power = Power.now()
            now = choice.saves(onBattery: power.onBattery, percent: power.percent)
        }
        guard now != on else { return }
        on = now
        for watcher in watchers where watcher.owner() != nil { watcher.changed(now) }
    }
}

/// Where the Mac's power comes from and how full its battery is, as
/// Chromium reads them: the providing source, and the first battery's
/// current capacity over its full one, in whole percent.
enum Power {
    static func now() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let from = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return (false, nil) }
        let onBattery = from == kIOPMBatteryPowerKey
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (onBattery, nil) }
        for source in list {
            guard let about = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let left = about[kIOPSCurrentCapacityKey] as? Int,
                  let full = about[kIOPSMaxCapacityKey] as? Int, full > 0
            else { continue }
            return (onBattery, left * 100 / full)
        }
        return (onBattery, nil)
    }
}
