import Foundation
import Testing
@testable import Fast

/// A page that never arrived answers an agent at once, instead of a
/// script waiting out the bench's 25 s on a document that isn't there.
@MainActor
@Suite(.serialized)
struct AgentLoadFailureTests {
    private final class Reply {
        var value: [String: Any]?
    }

    @Test func pageThatNeverArrivedIsSaidAtOnce() throws {
        let browser = Browser(windowID: UUID())
        let tab = Tab(shy: true, bench: true, factory: .webKitOnly)
        let bench = Bench()
        browser.lay([])
        browser.activeID = nil
        tab.agent = Agents.script
        tab.setAddressOptimistically(URL(string: "https://app.no-such-host.invalid/")!)
        browser.lay([tab])
        defer {
            if let window = tab.built?.window, window.identifier == Bench.roomID { window.close() }
            tab.close()
            browser.lay([])
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }

        // Loaded or not yet failed: nothing to say.
        #expect(Bench.agentLoadFailure("snapshot", tab) == nil)

        tab.failure = PageLoadFailure.message(domain: "net", code: -105)
        let said = try #require(Bench.agentLoadFailure("snapshot", tab))
        #expect(said["code"] as? String == "PAGE_LOAD_FAILED")
        #expect(said["url"] as? String == "https://app.no-such-host.invalid/")
        let error = try #require(said["error"] as? String)
        #expect(error.contains("https://app.no-such-host.invalid/ didn't load: Nothing answers at this address"))
        #expect(error.contains(Bench.short(tab)))
        for verb in ["settle", "act", "press", "agent-eval", "agent-upload"] {
            #expect(Bench.agentLoadFailure(verb, tab) != nil, "\(verb) needs the page's document")
        }
        // The ways out stay open.
        for verb in ["nav", "agent-go", "agent-show", "handoff"] {
            #expect(Bench.agentLoadFailure(verb, tab) == nil, "\(verb) leaves the failed page")
        }
        // A memory stop keeps its own answer (agentMemoryStop).
        tab.failure = StuckWatch.memoryStopped
        #expect(Bench.agentLoadFailure("snapshot", tab) == nil)

        // Through the bench: answered before any script is sent.
        tab.failure = PageLoadFailure.message(domain: "net", code: -105)
        let reply = Reply()
        bench.agentCommand("snapshot", ["id": tab.id.uuidString, "session": Agents.script], browser: browser) { reply.value = $0 }
        #expect(reply.value?["code"] as? String == "PAGE_LOAD_FAILED")
    }
}
