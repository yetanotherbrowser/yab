import Foundation
import Testing
@testable import Fast

/// Words queued with ⌘Enter behind a running Claude Code, then a message
/// sent now with Enter (#1029, #1030). Claude Code's stdin is a file here,
/// so nothing reaches a provider.
@MainActor
struct ChatQueueTests {
    private func running() throws -> (Agents, Agents.Session, () -> Void) {
        let suite = "chat-queue-" + UUID().uuidString
        let settings = UserDefaults(suiteName: suite)!
        let consent = ProviderConsent(settings: settings, history: [])
        consent.grant("claude")
        let stdin = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        FileManager.default.createFile(atPath: stdin.path, contents: Data())
        let agents = Agents()
        let session = Agents.Session(id: suite, cli: "claude", name: "Claude", prompt: "First", state: .running)
        session.providerPermit = consent.permit("claude")
        session.input = try FileHandle(forWritingTo: stdin)
        agents.register(session)
        return (agents, session, {
            try? session.input?.close()
            try? FileManager.default.removeItem(at: stdin)
            settings.removePersistentDomain(forName: suite)
        })
    }

    @Test func aMessageSentNowIsShownWithItsOwnWordsAndWhatWentWithIt() throws {
        let (agents, session, done) = try running()
        defer { done() }
        agents.followUp(session.id, "Q1", queue: true)
        agents.followUp(session.id, "Q2", queue: true)
        agents.followUp(session.id, "S: please do this now", with: [.quote("the line")])
        let asked = try #require(session.items.last { $0.kind == .asked })
        #expect(asked.text == "S: please do this now")
        #expect(asked.detail == ChatAttachment.labels(tabs: [], files: [], quotes: ["the line"]).joined(separator: "\n"))
        #expect(session.sent[asked.id] == [.quote("the line")])
        #expect(session.queue == ["Q1", "Q2"])
        #expect(session.saying == ["Q1", "Q2"])
        #expect(session.carrying == [[], []] && session.attaching == [[], []])
        #expect(session.sends == 1, "sent, and heard back at once, it follows them down")
    }

    @Test func queueingIsNotSendingButTheQueueLettingOneGoIs() throws {
        let (agents, session, done) = try running()
        defer { done() }
        agents.followUp(session.id, "Q1", queue: true)
        agents.followUp(session.id, "Q2", queue: true)
        #expect(session.sends == 0, "queued words do not move the transcript")
        // The turn ends: the queue lets Q1 go and Claude Code says it back at once (Agents.turned).
        agents.hear(["type": "result", "subtype": "success", "is_error": false, "result": "Done.", "session_id": "S"], on: session)
        #expect(session.items.last { $0.kind == .asked }?.text == "Q1")
        #expect(session.queue == ["Q2"] && session.saying == ["Q2"])
        #expect(session.sends == 1, "sent from the queue, it follows them down")
    }
}
