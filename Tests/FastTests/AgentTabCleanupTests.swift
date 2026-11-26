import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentTabCleanupTests {
    @MainActor private final class World {
        var now: TimeInterval = 100
        var choice = AgentTabsAfter.fifteenMinutes
        var browsers: [Browser] = []
        var tasks: [String: Agents.Session] = [:]
        var answers: [(Bool?) -> Void] = []
        var holdAnswers = false
        var unsaved: Bool? = false
        var inspections = 0

        lazy var cleanup = AgentTabCleanup(browsers: { [unowned self] in browsers },
                                          session: { [unowned self] in tasks[$0] },
                                          clock: { [unowned self] in now },
                                          choice: { [unowned self] in choice },
                                          inspect: { [unowned self] _, answer in
            inspections += 1
            if holdAnswers { answers.append(answer) } else { answer(unsaved) }
        }, automatic: false)

        func browser() -> Browser {
            let browser = Browser(windowID: UUID())
            browser.lay([])
            browser.activeID = nil
            browsers.append(browser)
            return browser
        }

        func task(state: Agents.State = .done, cli: String = "codex") -> Agents.Session {
            let task = Agents.Session(id: UUID().uuidString, cli: cli, name: "Cleanup", prompt: "", state: state)
            if !state.live { task.ended = Date() }
            tasks[task.id] = task
            return task
        }

        func tab(_ task: Agents.Session, in browser: Browser, shy: Bool = false) -> Tab {
            let tab = Tab(shy: shy, bench: true)
            tab.agent = task.id
            tab.restore(url: URL(string: "https://cleanup.example.test/\(tab.id)")!, title: "Result")
            browser.lay(browser.tabs + [tab])
            return tab
        }

        func advance(_ seconds: TimeInterval = 901) { now += seconds; cleanup.sweep() }

        func dispose() {
            for browser in browsers {
                for tab in browser.everyTab { tab.close() }
                if let id = browser.windowID {
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                }
            }
        }
    }

    @Test func nativeSettingReadsThePersistedChoiceAndRejectsInvalidValues() throws {
        let w = World(); defer { w.dispose() }
        let previous = Store.settings.object(forKey: AgentTabsAfter.key)
        defer { Store.settings.set(previous, forKey: AgentTabsAfter.key); AgentTabCleanup.shared.settingChanged() }
        let browser = w.browser()
        let setting = try #require(NativeSetting.all.first { $0.id == "agents-cleanup" })
        try setting.write(browser.prefs, .string("oneHour"))
        #expect(setting.read(browser.prefs) == .string("oneHour"))
        #expect(setting.saved == .string("oneHour"))
        #expect(AgentTabsAfter.saved == .oneHour)
        #expect(throws: (any Error).self) { try setting.write(browser.prefs, .string("invalid")) }
        #expect(setting.read(browser.prefs) == .string("oneHour"))
    }

    @Test func closesOnlyAfterTheChosenWaitAndRemembersThePage() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.cleanup.schedule(task)
        w.advance(899)
        #expect(browser.tabs.contains { $0 === tab })
        w.advance(1)
        #expect(!browser.tabs.contains { $0 === tab })
        #expect(browser.ghosts.last?.url == tab.address)
        #expect(w.inspections == 1)
    }

    @Test func neverAndChangingTheIntervalCancelOldAnswers() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.holdAnswers = true
        w.cleanup.schedule(task)
        w.advance()
        #expect(w.answers.count == 1)
        w.choice = .never; w.cleanup.settingChanged()
        w.answers.removeFirst()(false)
        w.advance(10000)
        #expect(browser.tabs.contains { $0 === tab })
        w.choice = .oneHour; w.cleanup.settingChanged()
        w.holdAnswers = false
        w.advance(3599)
        #expect(browser.tabs.contains { $0 === tab })
        w.advance(1)
        #expect(!browser.tabs.contains { $0 === tab })
    }

    @Test func allWindowsAndBothSplitHalvesAreProtectedUntilAfterLeaving() {
        let w = World(); defer { w.dispose() }
        let first = w.browser(), second = w.browser(), task = w.task()
        let a = w.tab(task, in: first), b = w.tab(task, in: second), c = w.tab(task, in: second)
        first.activeID = a.id
        second.activeID = b.id
        second.stagePair = Pair(first: b.id, second: c.id)
        w.cleanup.schedule(task)
        w.advance(10000)
        #expect(first.tabs.count == 1)
        #expect(second.tabs.count == 2)
        first.activeID = nil; second.activeID = nil; second.stagePair = nil
        w.cleanup.lookAround()
        w.advance(899)
        #expect(first.tabs.count == 1 && second.tabs.count == 2)
        w.advance(1)
        #expect(first.tabs.isEmpty && second.tabs.isEmpty)
    }

    @Test func unreadResultGetsAFullWaitAfterItIsRead() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        tab.unread = AgentFeed.Unread(session: task.id)
        w.cleanup.schedule(task)
        w.advance(10000)
        #expect(w.inspections == 0)
        tab.unread = nil
        w.cleanup.lookAround()
        w.advance(899)
        #expect(browser.tabs.count == 1)
        w.advance(1)
        #expect(browser.tabs.isEmpty)
    }

    @Test(arguments: ["pin", "kept", "handoff", "draft", "typing", "audio", "pip"])
    func protectedTabsAreNeverClosedOrPutDown(_ reason: String) {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        switch reason {
        case "pin": tab.pin = "R"
        case "kept": tab.kept = true
        case "handoff": tab.handoff = "Sign in"
        case "draft": tab.draft = true
        case "typing": tab.typing = true
        case "audio": tab.noisy = true
        default: tab.pictureInPicture = true
        }
        w.cleanup.schedule(task)
        w.advance(10000)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(w.inspections == 0)
    }

    @Test(arguments: [true, nil] as [Bool?])
    func anUnsavedOrUnansweredFormIsPreserved(_ result: Bool?) {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.unsaved = result
        w.cleanup.schedule(task)
        w.advance()
        #expect(browser.tabs.contains { $0 === tab })
        w.unsaved = false
        w.advance(899)
        #expect(browser.tabs.count == 1)
        w.advance(1)
        #expect(browser.tabs.isEmpty)
    }

    @Test func aPageThatCannotSayTwiceIsClosedButAnUnsentFormNever() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let unsure = w.tab(task, in: browser)
        w.unsaved = nil
        w.cleanup.schedule(task)
        w.advance()
        #expect(browser.tabs.contains { $0 === unsure })
        w.advance(899)
        #expect(browser.tabs.contains { $0 === unsure })
        w.advance(1)
        #expect(!browser.tabs.contains { $0 === unsure })

        let other = w.task(), draft = w.tab(other, in: browser)
        w.unsaved = true
        w.cleanup.schedule(other)
        for _ in 0..<5 { w.advance() }
        #expect(browser.tabs.contains { $0 === draft })
    }

    @Test func aPageStuckLoadingHoldsItsTabForOneIntervalOnly() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        tab.pretendLoading(true)
        w.cleanup.schedule(task)
        w.advance(899)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(w.inspections == 0)
        w.advance(1)
        w.advance(899)
        #expect(browser.tabs.contains { $0 === tab })
        w.advance(1)
        #expect(!browser.tabs.contains { $0 === tab })
    }

    @Test func aPageThatFinishesLoadingStartsAFreshWait() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        tab.pretendLoading(true)
        w.cleanup.schedule(task)
        w.advance(600)
        tab.pretendLoading(false)
        w.cleanup.lookAround()
        w.advance(899)
        #expect(browser.tabs.contains { $0 === tab })
        w.advance(1)
        #expect(!browser.tabs.contains { $0 === tab })
    }

    @Test func resumingTheTaskInvalidatesThePendingFormAnswer() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.holdAnswers = true
        w.cleanup.schedule(task)
        w.advance()
        task.state = .running
        w.answers.removeFirst()(false)
        #expect(browser.tabs.contains { $0 === tab })
        task.state = .done; task.ended = Date().addingTimeInterval(1)
        w.cleanup.schedule(task)
        w.holdAnswers = false
        w.advance(899)
        #expect(browser.tabs.count == 1)
        w.advance(1)
        #expect(browser.tabs.isEmpty)
    }

    @Test func aTabSeenDuringTheFormCheckCannotBeClosedByItsOldAnswer() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.holdAnswers = true
        w.cleanup.schedule(task); w.advance()
        browser.activeID = tab.id; w.cleanup.lookAround()
        browser.activeID = nil; w.cleanup.lookAround()
        w.answers.removeFirst()(false)
        #expect(browser.tabs.contains { $0 === tab })
    }

    @Test func keepingATabAdoptsItAndInvalidatesPendingCleanup() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.holdAnswers = true
        w.cleanup.schedule(task); w.advance()
        Folders.shared.keep([tab], in: browser)
        w.answers.removeFirst()(false)
        #expect(tab.agent == nil && !tab.bench)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(tab.keepable)
    }

    @Test func aGuestsUserTabIsPreserved() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let yours = Tab()
        yours.guest = task.id
        browser.lay(browser.tabs + [yours])
        w.cleanup.schedule(task)
        w.advance(100000)
        #expect(browser.tabs.contains { $0 === yours })
    }

    /// `yab mcp` stays attached while its client runs, for hours: each of
    /// its tabs goes the chosen wait after the agent last did something there.
    @Test func anAttachedAgentsTabGoesAfterItLastActedThere() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), external = w.task(state: .attached, cli: "external")
        let idle = w.tab(external, in: browser), busy = w.tab(external, in: browser)
        w.cleanup.lookAround()
        w.advance(600)
        w.cleanup.acted(busy)
        w.advance(300)
        #expect(!browser.tabs.contains { $0 === idle })
        #expect(browser.tabs.contains { $0 === busy })
        w.advance(599)
        #expect(browser.tabs.contains { $0 === busy })
        w.advance(1)
        #expect(!browser.tabs.contains { $0 === busy })
        #expect(external.state == .attached)
    }

    @Test func aTabTheCleanupClosedSaysSoWhenAskedFor() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), external = w.task(state: .attached, cli: "external")
        let tab = w.tab(external, in: browser), kept = w.tab(external, in: browser)
        let ref = String(tab.id.uuidString.prefix(8)).lowercased()
        #expect(w.cleanup.closedNote(ref) == nil)
        w.cleanup.lookAround()
        w.advance(600)
        w.cleanup.acted(kept)
        w.advance(300)
        #expect(!browser.tabs.contains { $0 === tab })
        let note = w.cleanup.closedNote(ref)
        #expect(note?.hasPrefix("Yab closed tab “\(ref)”") == true)
        #expect(note?.contains("after 15 min without a call there") == true)
        #expect(note?.hasSuffix("open it again") == true)
        // A tab still open, and one nobody closed, are as before.
        #expect(w.cleanup.closedNote(String(kept.id.uuidString.prefix(8))) == nil)
        #expect(w.cleanup.closedNote("") == nil)
    }

    @Test func anAttachedAgentThatLeavesGivesItsTabsAFreshWait() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), external = w.task(state: .attached, cli: "external")
        let tab = w.tab(external, in: browser)
        w.cleanup.lookAround()
        w.advance(600)
        external.state = .done
        external.ended = Date()
        w.cleanup.schedule(external)
        w.advance(899)
        #expect(browser.tabs.contains { $0 === tab })
        w.advance(1)
        #expect(!browser.tabs.contains { $0 === tab })
    }

    @Test func anAttachedAgentsTabIsFoundWithoutBeingScheduled() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), external = w.task(state: .attached, cli: "external")
        let tab = w.tab(external, in: browser)
        w.advance(1)
        w.advance(900)
        #expect(!browser.tabs.contains { $0 === tab })
    }

    @Test func aScriptsAttachedSessionKeepsItsTabs() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser()
        let script = Agents.Session(id: Agents.script, cli: "external", name: "Script", prompt: "", state: .attached)
        w.tasks[script.id] = script
        let tab = w.tab(script, in: browser)
        w.cleanup.lookAround()
        w.advance(100000)
        #expect(browser.tabs.contains { $0 === tab })
    }

    @Test func parkedPagesAreClosedWithoutSwitchingSpaces() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser), original = browser.spaceID, other = UUID()
        browser.lay([])
        browser.parked[other] = Parked(tabs: [tab], active: tab.id)
        w.cleanup.schedule(task); w.advance()
        #expect(browser.parked[other]?.tabs.isEmpty == true)
        #expect(browser.spaceID == original)
        #expect(browser.ghosts.last?.url == tab.address)
    }

    @Test func immediateSubagentCleanupStillProtectsVisibleTabs() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let seen = w.tab(task, in: browser), hidden = w.tab(task, in: browser)
        browser.activeID = seen.id
        w.cleanup.schedule(task, immediate: true)
        #expect(browser.tabs.contains { $0 === seen })
        #expect(!browser.tabs.contains { $0 === hidden })
        // Closed because the subagent finished, not for a wait it never had.
        let gone = w.cleanup.closedNote(String(hidden.id.uuidString.prefix(8)))
        #expect(gone?.contains("when the subagent that opened it finished") == true)
        #expect(gone?.contains("min") == false)
        browser.activeID = nil; w.cleanup.lookAround(); w.advance()
        #expect(browser.tabs.isEmpty)
        // The one kept while seen waited the full interval before it went.
        #expect(w.cleanup.closedNote(String(seen.id.uuidString.prefix(8)))?.contains("after 15 min without a call there") == true)
    }

    @Test func privatePagesLeaveNoRecentlyClosedEntry() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        _ = w.tab(task, in: browser, shy: true)
        let count = browser.ghosts.count
        w.cleanup.schedule(task); w.advance()
        #expect(browser.tabs.isEmpty)
        #expect(browser.ghosts.count == count)
    }

    @Test func pinningAnAgentPageAdoptsItPermanently() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.cleanup.schedule(task)
        browser.pin(tab)
        #expect(tab.agent == nil && !tab.bench && tab.pin != nil)
        w.advance(10000)
        #expect(browser.tabs.contains { $0 === tab })
    }

    @Test func reopeningAnAutomaticallyClosedPageMakesItYours() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.cleanup.schedule(task); w.advance()
        browser.reopen()
        let restored = browser.active
        #expect(restored?.address == tab.address)
        #expect(restored?.agent == nil && restored?.bench == false)
        w.advance(10000)
        #expect(browser.tabs.contains { $0 === restored })
    }

    @Test func aFolderLookPostponesItsFinishedTabs() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        w.cleanup.schedule(task)
        w.advance(899)
        task.looked = task.looked.addingTimeInterval(1)
        w.cleanup.lookAround()
        w.advance(899)
        #expect(browser.tabs.contains { $0 === tab })
        w.advance(1)
        #expect(browser.tabs.isEmpty)
    }

    @Test func aFormPermissionKeepsThePage() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        let tab = w.tab(task, in: browser)
        tab.permit = AgentPermit(kind: .use, session: task.id, detail: "Use this page")
        w.cleanup.schedule(task); w.advance(10000)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(w.inspections == 0)
    }

    private func waited(_ tab: Tab, in browser: Browser) -> String? {
        var state: String?
        Bench().agentCommand("handoff-wait", ["do": "handoff-wait", "id": tab.id.uuidString, "seconds": 0], browser: browser) {
            state = $0["state"] as? String
        }
        return state
    }

    @Test(arguments: ["keep", "pin", "choices"])
    func keepingOrPinningAnAskingTabTellsTheAgentItWasTaken(_ how: String) {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task(state: .running)
        let tab = w.tab(task, in: browser)
        defer { Agents.taken.remove(tab.id) }
        if how == "choices" { tab.choices = ["A", "B"] } else { tab.handoff = "Sign in" }
        switch how {
        case "pin": browser.pin(tab)
        default: Folders.shared.keep([tab], in: browser)
        }
        #expect(tab.agent == nil && tab.handoff == nil)
        #expect(waited(tab, in: browser) == "taken")
        // Said once: a later wait in that tab hears the plain state.
        #expect(waited(tab, in: browser) == "done")
    }

    @Test func anAnsweredHandoffIsStillDoneAndAQuietKeepIsNotTaken() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task(state: .running)
        let asked = w.tab(task, in: browser), quiet = w.tab(task, in: browser)
        asked.handoff = "Sign in"
        asked.handoff = nil
        #expect(waited(asked, in: browser) == "done")
        Folders.shared.keep([quiet], in: browser)
        #expect(!Agents.taken.contains(quiet.id))
    }

    @Test func realPageInspectionProtectsDraftsAndSilentVideo() async throws {
        _ = NSApplication.shared
        let tab = Tab(bench: true)
        let web = tab.page
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 480, height: 270),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        defer { tab.close(); window.close() }
        web.navigate(html:"<form><input id='draft'></form><video muted id='movie'></video>", base: URL(string: "https://cleanup.example.test"))
        var ready = false
        for _ in 0..<100 {
            if (try? await web.run("document.readyState === 'complete' && !!document.getElementById('draft')")) as? Bool == true { ready = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(ready)
        func busy() async -> Bool? {
            await withCheckedContinuation { go in AgentTabCleanup.pageIsBusy(tab) { go.resume(returning: $0) } }
        }
        #expect(await busy() == false)
        _ = try await web.run("document.getElementById('draft').value='Unsent'; document.getElementById('draft').dispatchEvent(new Event('input',{bubbles:true})); true")
        #expect(await busy() == true)
        _ = try await web.run("document.getElementById('draft').value=''; document.getElementById('draft').dispatchEvent(new Event('input',{bubbles:true})); true")
        _ = try await web.call("""
          const canvas=document.createElement('canvas');canvas.width=320;canvas.height=180;
          const paint=canvas.getContext('2d');
          const draw=setInterval(()=>{paint.fillStyle='red';paint.fillRect(0,0,320,180)},33);
          const movie=document.getElementById('movie');movie.srcObject=canvas.captureStream(30);
          await Promise.race([movie.play(),new Promise((_,reject)=>setTimeout(()=>reject(new Error('video did not start')),5000))]);
          clearInterval(draw);return !movie.paused;
          """, in: .page)
        #expect(await busy() == true)
        _ = try await web.call("""
          document.getElementById('movie').pause();
          const frame=document.createElement('iframe');
          frame.srcdoc="<input id=inside>";
          await new Promise(resolve=>{frame.onload=resolve;document.body.appendChild(frame)});
          frame.contentDocument.getElementById('inside').value='Unsent in a frame';
          return true;
          """, in: .page)
        #expect(await busy() == true)
        _ = try await web.call("""
          document.querySelector('iframe').remove();
          const frame=document.createElement('iframe');frame.sandbox='';frame.srcdoc='<input>';
          await new Promise(resolve=>{frame.onload=resolve;document.body.appendChild(frame)});
          return true;
          """, in: .page)
        // An embed nobody is in (an ad, a player, a captcha) doesn't hold
        // the page; one holding the focus can't be read, so it can't say.
        #expect(await busy() == false)
        let focused = try await web.run("const f=document.querySelector('iframe'); f.focus(); document.activeElement === f")
        #expect(focused as? Bool == true)
        #expect(await busy() == nil)
    }

    /// `yab --no-person` every few minutes (a watcher): nobody comes to see
    /// its tick, so the tick can't hold the tab past the chosen wait.
    @Test func aRunWithNobodyThereIsPutAwayDespiteItsTick() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser(), task = w.task()
        task.person = "none"
        let tab = w.tab(task, in: browser)
        tab.unread = AgentFeed.Unread(session: task.id)
        w.cleanup.schedule(task)
        w.advance(899)
        #expect(browser.tabs.contains { $0 === tab })
        w.advance(1)
        #expect(!browser.tabs.contains { $0 === tab })
    }

    /// The next run takes over the tab a finished one left on the same
    /// page instead of opening another: one tab, not a pile.
    @Test func aFinishedAgentsTabOnTheSamePageIsTakenOver() {
        let w = World(); defer { w.dispose() }
        let browser = w.browser()
        func left(_ address: String) -> Tab {
            let tab = Tab(bench: true, configuration: Web.configuration(store: Spaces.store(for: browser.spaceID)))
            tab.agent = UUID().uuidString
            tab.restore(url: URL(string: address)!, title: "Telegram")
            browser.lay(browser.tabs + [tab])
            return tab
        }
        let telegram = URL(string: "https://web.telegram.org/a/")!
        _ = left("https://web.telegram.org/k/")
        let ticked = left("https://web.telegram.org/a/")
        ticked.unread = AgentFeed.Unread(session: ticked.agent!)
        let shown = left("https://web.telegram.org/a/")
        browser.activeID = shown.id
        let bench = Bench()
        #expect(bench.leftover(telegram, space: nil, session: "next", in: browser) == nil)
        browser.activeID = nil
        #expect(bench.leftover(telegram, space: nil, session: "next", in: browser) === shown)
        #expect(bench.leftover(telegram, space: nil, session: shown.agent, in: browser) == nil)
        #expect(bench.leftover(telegram, space: nil, session: nil, in: browser) == nil)
    }
}
