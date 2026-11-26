import AppKit
import SwiftUI
import Testing
@testable import Fast

/// The chat column is the window's own surface, not the page's: with no
/// tab in front it stands beside the empty state, a task's answer is
/// there to read, and its question is answered in its field rather than
/// held in the corner (#1008).
@MainActor
@Suite(.serialized)
struct ChatEmptyWindowTests {

    // MARK: where a question is answered

    private func makeSession(_ id: String, cli: String = "claude") throws -> Agents.Session {
        Agents.shared.benchTask(id, state: .running)
        let session = try #require(Agents.shared.session(id))
        session.cli = cli
        return session
    }

    @Test func aChatsQuestionIsAnsweredInTheColumnWithNoTabInFront() throws {
        let browser = Browser(windowID: UUID())
        let session = try makeSession("empty-window-ask-" + UUID().uuidString)
        defer {
            session.permit = nil
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.letGo(); browser.dropSpare()
        }
        session.permit = AgentPermit(kind: .mailRead, session: session.id, detail: "Looks for: boarding pass")
        // The column away: the corner holds the question.
        #expect(Agents.shared.corneredAll(in: browser).contains(.chat(session.id)))
        // The column out with that chat, no tab in front: its field says
        // it, the corner doesn't.
        browser.chatShown = session.id
        browser.chatOpen = true
        #expect(!Agents.shared.corneredAll(in: browser).contains(.chat(session.id)),
                "the column drawn in an empty window is the question's home")
        // Another chat in the column: the question waits in the corner.
        browser.chatShown = "another-chat"
        #expect(Agents.shared.corneredAll(in: browser).contains(.chat(session.id)))
        browser.chatOpen = false
        #expect(Agents.shared.corneredAll(in: browser).contains(.chat(session.id)))
    }

    @Test func aTaskThatEndsInAnEmptyWindowIsReadOnlyWhenItsChatIsShown() throws {
        let browser = Browser(windowID: UUID())
        let held = (Agents.shared.browser, AgentNotices.shared.browser)
        Agents.shared.browser = browser
        AgentNotices.shared.browser = browser
        let shown = try makeSession("empty-window-shown-" + UUID().uuidString)
        let away = try makeSession("empty-window-away-" + UUID().uuidString)
        defer {
            shown.permit = nil; away.permit = nil
            Agents.shared.browser = held.0
            AgentNotices.shared.browser = held.1
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.letGo(); browser.dropSpare()
        }
        shown.result = "Aurora, Beacon, Compass."
        // The column out with its chat, no tab in front: you are looking
        // at the answer, so no toast, and it is read.
        browser.chatShown = shown.id
        browser.chatOpen = true
        Agents.shared.taskEnded(shown, .done)
        #expect(shown.read, "the answer was in sight")
        #expect(!browser.toaster.shown, "no toast for what you are looking at")

        // The column closed: the corner says it, and it stays unread.
        away.result = "More names."
        browser.chatOpen = false
        Agents.shared.taskEnded(away, .done)
        #expect(!away.read, "unseen until its chat is opened")
        #expect(browser.toaster.shown, "the corner says a task is done")
    }

    // MARK: the mount

    /// The real window body off screen, with no tab in front: what
    /// App.swift draws is what is laid out, so the mount itself is
    /// checked, as ChatLaunchToggleTests checks the native frames.
    @MainActor
    private final class Fixture {
        let id = UUID()
        let browser: Browser
        let window: NSWindow
        let host: NSHostingView<ContentView>
        private let held: (Browser?, Browser?, Bool?)
        private let widest: CGFloat

        init(width: CGFloat = 1000) throws {
            try #require(Store.testing && Store.unitTests && Store.settings !== UserDefaults.standard)
            _ = NSApplication.shared
            browser = Browser(windowID: id)
            held = (Agents.shared.browser, AgentNotices.shared.browser, Agents.assumedInTests)
            Agents.shared.browser = browser
            AgentNotices.shared.browser = browser
            // Show Chat needs an agent to offer.
            Agents.assumedInTests = true
            widest = ChatLook.widest
            // As after relaunch: the room unmeasured, so the test sees the
            // empty window lay the column out for itself.
            ChatLook.widest = .infinity
            host = NSHostingView(rootView: ContentView(browser: browser))
            // Titled: the body's strip puts a titlebar accessory on the
            // window, which AppKit refuses on a borderless one.
            window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: width, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // The body's own dress(window) registers the same pair; going
            // first keeps the fixture the one entry that counts.
            BrowserWindows.shared.register(window, for: browser)
            window.contentView = host
        }

        func layout() {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
        }

        func settle() async throws {
            for _ in 0..<300 {
                layout()
                if !browser.chatMoving { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("chat movement did not finish")
        }

        /// The column's frame in the window, its air included.
        func columnRect() throws -> CGRect {
            let column = try #require(browser.chatColumnView)
            return column.convert(column.bounds, to: host)
        }

        /// What the fitted column is drawn at in this room.
        func fitted() -> CGFloat { max(ChatLook.least, min(browser.chatWidth, ChatLook.widest)) }

        func close() {
            Agents.shared.browser = held.0
            AgentNotices.shared.browser = held.1
            Agents.assumedInTests = held.2
            ChatLook.widest = widest
            window.contentView = nil
            window.close()
            BrowserWindows.shared.forgetForTests(browser)
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.dropSpare()
            for suffix in Set([""] + browser.spaces.map({ "-" + $0.id.uuidString })) {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)\(suffix).json"))
            }
            try? FileManager.default.removeItem(at: Store.file("spaces-window-\(id.uuidString).json"))
        }
    }

    @Test(arguments: [Flank.left, .right])
    func showChatDrawsTheColumnBesideTheEmptyState(flank: Flank) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        browser.prefs.sideFlank = flank
        fixture.layout()
        browser.toggleChat()
        try await fixture.settle()
        try #require(browser.chatOpen && !browser.chatMoving)
        let rect = try fixture.columnRect()
        #expect(rect.width > 0 && !rect.isNull)
        // The room measured: the empty state says how wide the column may
        // be, as a page does, so a wide column cannot overflow a narrow
        // window.
        #expect(ChatLook.widest < .infinity)
        #expect(abs(rect.width - (fixture.fitted() + Backdrop.inset)) < 1,
                "the column keeps its width beside the empty state")
        #expect(ChatLook.widest <= fixture.host.bounds.width - browser.sideShown - DevLook.pageBeside - DevRoom.Rim(card: true).gap + 1,
                "the empty state keeps the page's own room beside the column")
        // Beside the empty state, not over it: the column keeps its half.
        if browser.chatLeads {
            #expect(rect.maxX < fixture.host.bounds.width / 2)
        } else {
            #expect(rect.minX > fixture.host.bounds.width / 2)
        }
    }

    @Test func theColumnStaysThroughTheLastTabsCloseAndTheFirstTabOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        browser.toggleChat()
        try await fixture.settle()
        let column = try #require(browser.chatColumnView, "the column must mount with no tab in front")
        #expect(column.shown)

        // The first tab opens: the page takes the place the empty state
        // kept, and the column is not rebuilt around it.
        let tab = browser.open(URL(string: "about:blank#empty-window-chat")!, foreground: true)
        try await fixture.settle()
        #expect(browser.chatColumnView === column, "the column is the same host beside a page")
        #expect(column.shown && browser.chatOpen)

        // The last tab closes with the chat out: the column stays.
        browser.close(tab)
        try await fixture.settle()
        #expect(browser.active == nil && browser.chatOpen)
        #expect(browser.chatColumnView === column, "closing the last tab must not hide the chat")
        #expect(column.shown)
        fixture.layout()
        #expect(abs(try fixture.columnRect().width - (fixture.fitted() + Backdrop.inset)) < 1)
    }

    @Test func aQuestionClickOpensTheColumnOfAnEmptyWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        let session = try makeSession("empty-window-click-" + UUID().uuidString)
        defer { session.permit = nil }
        session.permit = AgentPermit(kind: .mailRead, session: session.id, detail: "Looks for: boarding pass")
        fixture.layout()
        // Hidden column: the question waits in the corner.
        #expect(Agents.shared.corneredAll(in: browser).contains(.chat(session.id)))
        // The notification's click, with no tab in front (#1008).
        AgentNotices.shared.show(chat: session.id)
        try await fixture.settle()
        #expect(browser.chatOpen && browser.chatShown == session.id)
        #expect(browser.chatColumnView?.shown == true, "the question's home is drawn, not just remembered")
    }

    @Test func aWideColumnClampsToFitANarrowEmptyWindow() async throws {
        let fixture = try Fixture(width: 900)
        defer { fixture.close() }
        let browser = fixture.browser
        browser.chatWidth = ChatLook.most
        fixture.layout()
        browser.toggleChat()
        try await fixture.settle()
        let rect = try fixture.columnRect()
        #expect(ChatLook.widest < ChatLook.most, "the empty window measures its room so a 620pt column clamps")
        #expect(rect.width < ChatLook.most, "the drawn column must not overflow a narrow empty window")
        #expect(rect.minX >= 0 && rect.maxX <= fixture.host.bounds.width + 1)
    }

    @Test(arguments: [false, true])
    func emptyWindowFieldRoomClearsChatWhenBothFitAndStaysInWindowWhenNarrower(chatLeads: Bool) {
        let margins = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let chatRoom: CGFloat = 336

        // 960pt: empty card is narrower than the box, but the window can
        // hold both the box and the chat column without overlap.
        let (lead960, trail960) = ContentView.emptyWindowFieldRoom(
            in: 960, side: chatLeads ? 0 : 220, far: chatLeads ? 220 : 0,
            margins: margins, chatRoom: chatRoom, chatLeads: chatLeads
        )
        if chatLeads {
            #expect(lead960 >= margins.leading + chatRoom, "box clears leading chat column")
        } else {
            #expect(trail960 >= margins.trailing + chatRoom, "box clears trailing chat column")
        }
        #expect(lead960 >= 0 && trail960 >= 0)
        #expect(960 - lead960 - trail960 >= Omnibox.compactWidth + 2 * Omnibox.margin)

        // 780pt: narrower than chat + compact box; stays inside [0, 780].
        let (lead780, trail780) = ContentView.emptyWindowFieldRoom(
            in: 780, side: chatLeads ? 0 : 220, far: chatLeads ? 220 : 0,
            margins: margins, chatRoom: chatRoom, chatLeads: chatLeads
        )
        #expect(lead780 >= 0 && trail780 >= 0)
        #expect(lead780 + trail780 <= 780 - Omnibox.compactWidth - 2 * Omnibox.margin + 0.5)
    }
}
