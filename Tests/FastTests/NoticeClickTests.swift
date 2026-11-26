import Foundation
import Testing
@testable import Fast

/// An agent's question with no page in front: still asked, and its card
/// held in the window's corner, where a click on its notification finds it
/// (docs/chat-asks.md, "Finding you"; evals/mail/notice_click.py).
@MainActor
@Suite(.serialized)
struct NoticeClickTests {
    @MainActor private struct World {
        let browser: Browser
        let news: Tab
        let session: Agents.Session

        init(cli: String = "external") {
            browser = Browser(windowID: UUID())
            news = Tab(bench: true)
            news.restore(url: URL(string: "https://news.example.test/")!, title: "News")
            browser.lay([news])
            // A space with nothing in front: the tab is yours, not shown.
            browser.activeID = nil
            let id = "notice-click-" + UUID().uuidString
            Agents.shared.benchTask(id, state: .running)
            session = Agents.shared.session(id)!
            session.cli = cli
        }

        func dispose() {
            session.permit = nil
            for tab in browser.everyTab { tab.permit = nil; tab.handoff = nil; tab.close() }
        }
    }

    @Test func aSendWithNoTabInFrontStillHasATabToAskIn() {
        let w = World(); defer { w.dispose() }
        #expect(w.browser.active == nil)
        #expect(Agents.shared.askTab(for: w.session.id, in: w.browser) === w.news)
    }

    @Test func aPrivateTabInFrontIsStillNeverAskedIn() {
        let w = World(); defer { w.dispose() }
        let shy = Tab(shy: true, bench: true)
        w.browser.lay([w.news, shy])
        w.browser.activeID = shy.id
        #expect(Agents.shared.askTab(for: w.session.id, in: w.browser) == nil)
    }

    @Test func noTabTakesOneAnotherQuestionWaitsOn() {
        let w = World(); defer { w.dispose() }
        w.news.handoff = "Sign in"
        #expect(Agents.shared.askTab(for: w.session.id, in: w.browser) == nil)
    }

    @Test func aChatsQuestionIsInTheColumnOfAnEmptyWindow() {
        let w = World(cli: "claude"); defer { w.dispose() }
        w.session.permit = AgentPermit(kind: .mailRead, session: w.session.id, detail: "Looks for: boarding pass")
        // The column out with that chat and no page beside it: the column
        // is the window's, drawn beside the empty state too, so the
        // question is in its field and not held in the corner (#1008).
        w.browser.chatShown = w.session.id
        w.browser.chatOpen = true
        #expect(!Agents.shared.corneredAll(in: w.browser).contains(.chat(w.session.id)))
        w.browser.chatOpen = false
        #expect(Agents.shared.corneredAll(in: w.browser).contains(.chat(w.session.id)))
    }

    // A private window holds none of your agents' questions and calls you
    // to none of them; your normal window still does (#1520).
    @Test func aPrivateWindowSaysNothingOfYourAgents() {
        let w = World(); defer { w.dispose() }
        w.session.permit = AgentPermit(kind: .mailRead, session: w.session.id, detail: "Looks for: boarding pass")
        let shy = Browser(windowID: UUID(), purpose: .privateOnly)
        defer {
            shy.dozing?.invalidate()
            shy.stuck.timer?.invalidate()
            shy.pressure?.cancel()
            for tab in shy.tabs { tab.close() }
        }
        #expect(Agents.speaks(in: w.browser))
        #expect(Agents.shared.corneredAll(in: w.browser).contains(.chat(w.session.id)))
        #expect(!Agents.speaks(in: shy))
        #expect(Agents.shared.corneredAll(in: shy).isEmpty)
    }

    @Test func anotherAppsAgentsQuestionIsReadInTheCornerNotTheColumn() {
        let external = World(); defer { external.dispose() }
        #expect(!Agents.shared.columnHolds(external.session.id))
        let own = World(cli: "claude"); defer { own.dispose() }
        #expect(Agents.shared.columnHolds(own.session.id))
    }
}
