import AppKit
import Testing
@testable import Fast

// Under QuestionKeysTests, which owns Questions.shared: two of these put a
// question up, and a suite beside them would answer it.
extension QuestionKeysTests {
    /// A new window (⌘N) that showed a question, or went into full screen,
    /// is let go once closed: nothing keeps it, and it leaves the window
    /// server's list instead of staying there off screen (#1046). A window
    /// that did neither is ClosedWindowTests'.
    @MainActor @Suite(.serialized)
    struct ClosedWindowReleaseTests {
        /// The window a test opened, held weakly, and what its windows left.
        private final class Opened {
            weak var window: NSWindow?
            var ids: [UUID] = []
            var names: [String] = []

            func tidy() {
                for id in ids {
                    Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
                    Store.settings.removeObject(forKey: "window.\(id.uuidString).fullscreen")
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                    try? FileManager.default.removeItem(at: Store.file("spaces-window-\(id.uuidString).json"))
                }
                for name in names { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
            }
        }

        private final class Gone {
            weak var browser: Browser?
            init(_ browser: Browser) { self.browser = browser }
        }

        /// ⌘N in a Yab that is up, and the window once its views have it.
        /// Nothing strong to the window is handed back.
        private func open(_ opened: Opened, on screen: NSScreen) async throws -> Browser {
            // A Yab that is up has drawn its first window. Until then
            // Startup.watch keeps the first window dressed, and in a test
            // process, never shown by the window server, for good.
            Startup.mark("window")
            let visible = screen.visibleFrame
            let frame = NSRect(x: visible.minX + 40, y: visible.maxY - 640, width: 900, height: 600)
            let browser = BrowserWindows.shared.newWindow(frame: frame)
            let window = try #require(BrowserWindows.shared.window(for: browser))
            if let id = browser.windowID { opened.ids.append(id) }
            opened.names.append(window.frameAutosaveName)
            opened.window = window
            // WindowSetup and QuestionHost hand the window to the views' state
            // from the main queue, which runs only while the test is suspended:
            // turning the run loop from inside the test never runs it, and the
            // window would close before its views ever held it. dress(_:)
            // hides the title, the last thing that turn does.
            for _ in 0..<60 where window.titleVisibility != .hidden { try await Task.sleep(for: .milliseconds(50)) }
            #expect(window.titleVisibility == .hidden, "the window's views never dressed it")
            try await Task.sleep(for: .milliseconds(100))
            return browser
        }

        /// Closes the window, as its close button does: whether it is let go
        /// and gone from the window server's list.
        private func close(_ opened: Opened) async throws -> Bool {
            let number = opened.window?.windowNumber
            autoreleasepool { opened.window?.close() }
            let gone = { opened.window == nil && !(number.map(Self.listed) ?? false) }
            for _ in 0..<60 where !gone() { try await Task.sleep(for: .milliseconds(50)) }
            return gone()
        }

        /// Whether the window server still lists a window by this number.
        private static func listed(_ number: Int) -> Bool {
            let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            return all.contains { $0[kCGWindowNumber as String] as? Int == number }
        }

        /// A question asked over the window, answered before it closes: the
        /// stand that showed it does not keep the window.
        @Test func aClosedWindowThatShowedAQuestionIsLetGo() async throws {
            guard let screen = TestScreen.screen else { return }
            _ = NSApplication.shared
            let opened = Opened()
            defer { opened.tidy() }
            _ = try await open(opened, on: screen)
            let number = try #require(opened.window).windowNumber
            // Asked of this window, not of whichever is in front then.
            var question = Question(title: "Continue?", yes: "Continue")
            question.window = number
            let answer = Task { await Questions.shared.ask(question) }
            for _ in 0..<40 where !Questions.shared.shownIn.contains(number) { try await Task.sleep(for: .milliseconds(50)) }
            #expect(Questions.shared.shownIn.contains(number), "the question's card never came up in the window")
            Questions.shared.answer(false)
            _ = await answer.value
            // The card goes as the views next turn, after the answer: closed
            // before that, it would be closed with the card up.
            for _ in 0..<40 where Questions.shared.shownIn.contains(number) { try await Task.sleep(for: .milliseconds(50)) }
            #expect(!Questions.shared.shownIn.contains(number), "the answered question's card never went")
            #expect(try await close(opened), "the closed window is still kept")
        }

        /// The same with the card still up as the window closes.
        @Test func aWindowClosedWithAQuestionUpIsLetGo() async throws {
            guard let screen = TestScreen.screen else { return }
            _ = NSApplication.shared
            let opened = Opened()
            defer { opened.tidy() }
            _ = try await open(opened, on: screen)
            let number = try #require(opened.window).windowNumber
            // Asked of this window, not of whichever is in front then.
            var question = Question(title: "Continue?", yes: "Continue")
            question.window = number
            let answer = Task { await Questions.shared.ask(question) }
            for _ in 0..<40 where !Questions.shared.shownIn.contains(number) { try await Task.sleep(for: .milliseconds(50)) }
            #expect(Questions.shared.shownIn.contains(number), "the question's card never came up in the window")
            let letGo = try await close(opened)
            Questions.shared.answer(false)
            _ = await answer.value
            #expect(letGo, "the closed window is kept while its card is up")
            #expect(!Questions.shared.shownIn.contains(number), "the closed window is still counted as showing the card")
        }

        /// A window let go, the next one may be made at its address. That one
        /// goes into full screen as any other, and the browser of the window
        /// that was there does not.
        @Test func aWindowAtAFreedWindowsAddressGoesIntoFullScreen() async throws {
            guard let screen = TestScreen.screen else { return }
            _ = NSApplication.shared
            let opened = Opened()
            defer { opened.tidy() }
            // Where malloc puts the next window is its own: open and close
            // until one is made where a freed one was. Every window on the
            // way is checked the same, so a run where none lands there
            // still checks the rest.
            var freed: [UInt: Gone] = [:]
            var atAFreedAddress = false
            for _ in 0..<80 {
                let browser = try await open(opened, on: screen)
                let address = UInt(bitPattern: Unmanaged.passUnretained(try #require(opened.window)).toOpaque())
                let before = freed[address]?.browser
                atAFreedAddress = freed[address] != nil
                // What AppKit posts as the window goes into full screen, each
                // will with its did: AppKit holds events back from a will to
                // its did, so a will left open holds them for the process.
                NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: opened.window)
                NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: opened.window)
                try await Task.sleep(for: .milliseconds(100))
                #expect(browser.fullScreen, "the window never went into full screen (at a freed window's address: \(atAFreedAddress))")
                #expect(before?.fullScreen != true, "the browser of the window let go went into full screen in its place")
                NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: opened.window)
                NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: opened.window)
                try await Task.sleep(for: .milliseconds(100))
                guard try await close(opened) else {
                    Issue.record("the closed window that went into full screen is still kept")
                    return
                }
                if atAFreedAddress { return }
                freed[address] = Gone(browser)
            }
        }
    }
}
