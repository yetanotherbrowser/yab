import AppKit
import Testing
@testable import Fast

/// #1009: a task started in one window keeps everything of itself there:
/// its origin binding, its done and ask notices. The bench is bound to
/// the first window (Bench.start at launch); the task here starts in the
/// second.
@MainActor @Suite(.serialized)
struct TaskOriginWindowTests {
    @MainActor private final class World {
        let first = Browser(windowID: UUID())
        let second = Browser(windowID: UUID())
        let windows: [NSWindow]
        let oldBrowser: Browser?

        init() {
            oldBrowser = Agents.shared.browser
            windows = [first, second].map {
                let window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 900, height: 650),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                BrowserWindows.shared.register(window, for: $0)
                return window
            }
            Agents.shared.browser = first
        }

        func dispose() {
            Agents.shared.browser = oldBrowser
            for window in windows { window.close() }
            for browser in [first, second] {
                for tab in browser.tabs + browser.parkedTabs { tab.close() }
                browser.dozing?.invalidate()
                browser.stuck.timer?.invalidate()
                browser.pressure?.cancel()
                browser.letGo()
                BrowserWindows.shared.forgetForTests(browser)
            }
        }
    }

    @Test func aTaskAskedInASecondWindowBindsItsOriginThere() throws {
        let w = World(); defer { w.dispose() }
        // Consent is not given in a unit-test world, so the run is refused
        // before anything launches; the origin binding is made all the same.
        let session = try #require(Agents.shared.task("Find the best flights to Lisbon next week", context: [], on: nil,
                                                     choice: ModelChoice(cli: "claude", model: nil, effort: nil), in: w.second))
        #expect(session.nativeWindowID == w.second.windowID)
        #expect(session.nativeOriginSpace == w.second.spaceID)
    }

    @Test func aFinishedTaskSaysItInTheWindowItBeganIn() throws {
        let w = World(); defer { w.dispose() }
        let id = "origin-done-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .running)
        let session = try #require(Agents.shared.session(id))
        session.title = "Two window task"
        session.nativeWindowID = w.second.windowID
        // The bound window in front: the task's work lives in the second.
        w.first.lay([Tab(bench: true)])
        w.first.activeID = w.first.tabs.first?.id
        Agents.shared.taskEnded(session, .done)
        #expect(w.second.toaster.shown)
        #expect(!w.first.toaster.shown)
    }

    @Test func anAskingTaskSaysItInTheWindowItBeganIn() throws {
        let w = World(); defer { w.dispose() }
        let id = "origin-asks-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .running)
        let session = try #require(Agents.shared.session(id))
        session.nativeWindowID = w.second.windowID
        // Its own tab in the second window, another one in front there.
        let tab = Tab(bench: true)
        tab.agent = id
        let front = Tab(bench: true)
        w.second.lay([tab, front])
        w.second.activeID = front.id
        w.first.lay([Tab(bench: true)])
        w.first.activeID = w.first.tabs.first?.id
        Agents.shared.taskAsks(tab, session)
        #expect(w.second.toaster.shown)
        #expect(!w.first.toaster.shown)
    }

    @Test func aSubagentFollowsItsTaskIntoTheWindowItBeganIn() throws {
        let w = World(); defer { w.dispose() }
        let root = "origin-root-" + UUID().uuidString
        Agents.shared.benchTask(root, state: .running)
        Agents.shared.session(root)?.nativeWindowID = w.second.windowID
        let sub = "origin-sub-" + UUID().uuidString
        Agents.shared.benchTask(sub, state: .running)
        Agents.shared.session(sub)?.parent = root
        #expect(Agents.shared.window(of: sub) === w.second)
    }

    @Test func workThatBeganNowhereKeepsNoWindowAndAClosedOneIsLetGo() throws {
        let w = World(); defer { w.dispose() }
        let external = Agents.shared.attach(name: "Outside task")
        defer { Agents.shared.detach(external.id) }
        #expect(Agents.shared.window(of: external.id) == nil)
        let routine = "origin-routine-" + UUID().uuidString
        Agents.shared.benchTask(routine, state: .running)
        #expect(Agents.shared.window(of: routine) == nil)
        let id = "origin-closed-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .running)
        Agents.shared.session(id)?.nativeWindowID = w.second.windowID
        #expect(Agents.shared.window(of: id) === w.second)
        w.windows.last?.close()
        #expect(Agents.shared.window(of: id) == nil)
    }

    @Test func secondWindowTaskTabsAreSeenByTabsChatPickAndLeftovers() throws {
        let w = World(); defer { w.dispose() }
        let id = "origin-tabs-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .running)
        let session = try #require(Agents.shared.session(id))
        session.nativeWindowID = w.second.windowID
        let tab = Tab(bench: true)
        tab.agent = id
        tab.handoff = "Which one?"
        tab.choices = ["A", "B"]
        w.second.lay([tab])
        w.first.lay([Tab(bench: true)])

        #expect(Agents.shared.tabs(of: session).map(\.id) == [tab.id])
        #expect(Agents.shared.chat(of: session).tabs.map(\.id) == [tab.id.uuidString])
        #expect(Agents.shared.pick(for: id)?.id == tab.id)
        #expect(Agents.shared.leftovers(id).map(\.id) == [tab.id])
    }

    @Test func anOnPageTaskFinishToastStaysInItsOriginWindow() throws {
        let w = World(); defer { w.dispose() }
        let id = "origin-inline-" + UUID().uuidString
        let session = Agents.Session(id: id, cli: "claude", name: "Claude", prompt: "Summarize", state: .running)
        session.task = false
        session.nativeWindowID = w.second.windowID
        Agents.shared.register(session)
        w.first.lay([Tab(bench: true)])
        w.first.activeID = w.first.tabs.first?.id
        w.second.lay([Tab(bench: true)])
        w.second.activeID = w.second.tabs.first?.id

        Agents.shared.finish(session, .done)
        #expect(w.second.toaster.shown)
        #expect(!w.first.toaster.shown)
    }

    @Test func aPrivateWindowTaskKeepsNoticesThereButBrowsesInANormalWindow() throws {
        let w = World(); defer { w.dispose() }
        let shy = Browser(windowID: UUID(), purpose: .privateOnly)
        let shyWindow = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 900, height: 650),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        shyWindow.isReleasedWhenClosed = false
        BrowserWindows.shared.register(shyWindow, for: shy)
        defer {
            shyWindow.close()
            for tab in shy.tabs + shy.parkedTabs { tab.close() }
            shy.dozing?.invalidate()
            shy.stuck.timer?.invalidate()
            shy.pressure?.cancel()
            shy.letGo()
            BrowserWindows.shared.forgetForTests(shy)
        }
        let id = "origin-private-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .running)
        let session = try #require(Agents.shared.session(id))
        session.nativeWindowID = shy.windowID
        #expect(Agents.shared.window(of: id) === shy)
        #expect(Agents.shared.browsingWindow(of: id) == nil)
        // Its done toast still lands in the private window where the user started it.
        Agents.shared.taskEnded(session, .done)
        #expect(shy.toaster.shown)
        #expect(!w.first.toaster.shown)
        // Pressing Done from the private window closes the task's tabs in the normal window.
        let work = Tab(bench: true)
        work.agent = id
        w.first.lay([work])
        #expect(Agents.shared.tabBrowser(of: id, from: shy) === w.first)
        Agents.shared.finish(id, in: shy, keepingTabs: false)
        #expect(w.first.tabs.isEmpty)
    }

    @Test func aPrivateWindowTaskDoneFollowsLiveNormalWindowWhenFirstCloses() throws {
        let w = World(); defer { w.dispose() }
        let shy = Browser(windowID: UUID(), purpose: .privateOnly)
        let shyWindow = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 900, height: 650),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        shyWindow.isReleasedWhenClosed = false
        BrowserWindows.shared.register(shyWindow, for: shy)
        defer {
            shyWindow.close()
            for tab in shy.tabs + shy.parkedTabs { tab.close() }
            shy.dozing?.invalidate()
            shy.stuck.timer?.invalidate()
            shy.pressure?.cancel()
            shy.letGo()
            BrowserWindows.shared.forgetForTests(shy)
        }
        // Keep the second normal window visible and close the launch-bound first window (#1119).
        w.windows[1].orderFront(nil)
        w.windows[0].close()

        let id = "origin-private-closed-first-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .running)
        let session = try #require(Agents.shared.session(id))
        session.nativeWindowID = shy.windowID

        let work = Tab(bench: true)
        work.agent = id
        w.second.lay([work])

        let host = Agents.shared.tabBrowser(of: id, from: shy)
        #expect(host === w.second)
        #expect(Agents.shared.leftovers(id, among: host.tabs).map(\.id) == [work.id])

        // Option + Done closes the private chat while keeping the work tab in the second normal window.
        shy.moveChat(open: true)
        Agents.shared.finish(id, in: shy, keepingTabs: true)
        #expect(!shy.chatOpen)
        #expect(w.second.tabs.map(\.id) == [work.id])

        // Plain Done closes both the private chat and the work tab in the second normal window.
        shy.moveChat(open: true)
        Agents.shared.finish(id, in: shy, keepingTabs: false)
        #expect(!shy.chatOpen)
        #expect(w.second.tabs.isEmpty)
    }
}
