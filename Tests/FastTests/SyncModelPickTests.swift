import Foundation
import SyncKit
import Testing
@testable import Fast

/// A chat's model and effort picked on the iPhone (ModelPick): the list a
/// Mac publishes, a chat's head, and words that carry a pick.
@Suite(.serialized)
@MainActor
struct SyncModelPickTests {
    private func withOpenCodeSyncState(connected: Bool, _ work: () throws -> Void) rethrows {
        let settings = Store.settings
        let keys = ["agents.opencode.models", OpenCodeRunner.connectionKey,
                    "agents.explicit-connections.v1", "agents.revoked-connections.v1",
                    "agents.consent-migrated.v1", "agents.connection-generation.opencode"]
        let previous = keys.map { settings.object(forKey: $0) }
        let previousHidden = ModelDefaults.shared.hidden
        let previousShell = Shell.cached
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { settings.set(value, forKey: key) } else { settings.removeObject(forKey: key) }
            }
            ModelDefaults.shared.hidden = previousHidden
            Shell.cached = previousShell
        }
        settings.set("opencode/glm-5.3-flash\nopencode-go/claude-sonnet-5-5\n", forKey: keys[0])
        settings.set(connected, forKey: keys[1])
        Shell.cached = Shell.Found(claude: nil, codex: nil, cursor: nil, gemini: nil,
                                   opencode: "/opt/homebrew/bin/opencode", env: [:])
        var allowed = Set(settings.stringArray(forKey: keys[2]) ?? [])
        var revoked = Set(settings.stringArray(forKey: keys[3]) ?? [])
        allowed.insert("opencode"); revoked.remove("opencode")
        settings.set(Array(allowed), forKey: keys[2])
        settings.set(Array(revoked), forKey: keys[3])
        settings.set(UUID().uuidString, forKey: keys[5])
        try work()
    }
    private let models = [
        SyncMacModel(cli: "claude", model: "opus", name: "Claude Opus", about: "For long, hard tasks.",
                     efforts: ["low", "medium", "high", "xhigh", "max"]),
        SyncMacModel(cli: "codex", model: "gpt-6", name: "GPT-6", about: "", efforts: ["low", "medium", "high"]),
    ]

    @Test func theMacPublishesItsModels() throws {
        let fields = SyncChats.capability(device: "mac", models: models)
        let record = Record(collection: OpenOnMac.capability, id: "mac", fields: fields)
        #expect(ModelPick.supports(record, device: "mac"))
        #expect(ModelPick.models(record, device: "mac") == models)
        let first = try #require(fields[ModelPick.modelsField]?.array?.first?.object)
        #expect(first["cli"]?.string == "claude" && first["model"]?.string == "opus" && first["name"]?.string == "Claude Opus")
        #expect(first["efforts"]?.array?.compactMap(\.string) == ["low", "medium", "high", "xhigh", "max"])
        // Another Mac's record, or one without models, offers no pick.
        #expect(!ModelPick.supports(record, device: "other"))
        let none = Record(collection: OpenOnMac.capability, id: "mac", fields: SyncChats.capability(device: "mac"))
        #expect(!ModelPick.supports(none, device: "mac") && ModelPick.models(none, device: "mac").isEmpty)
        // A row that isn't a model of a known agent is skipped.
        #expect(SyncMacModel(.object(["cli": "mac", "model": "x"])) == nil)
        #expect(SyncMacModel.plan("claude") == "Claude" && SyncMacModel.plan("codex") == "ChatGPT")
        #expect(SyncMacModel.effortTitle("xhigh") == "Extra high" && SyncMacModel.effortTitle("low") == "Low")
        #expect(SyncMacModel.effortTitle("max") == AgentModels.effortTitle("max"))
    }

    @Test func theOfferedListIsThePickersOwn() {
        let every = SyncChats.every()
        for model in AgentModels.claude {
            #expect(every.contains(SyncMacModel(cli: "claude", model: model.model, name: model.name, about: model.about, efforts: model.efforts)))
        }
        #expect(SyncChats.offered().allSatisfy { every.contains($0) })
    }

    @Test func aChatsHeadSaysItsEffort() throws {
        var chat = SyncChat(id: "a:x", device: "mac", title: "T", state: "done", answer: "", cli: "codex", model: "gpt-6",
                            started: 1, updated: 2)
        #expect(chat.fields["effort"] == nil)
        chat.effort = "high"
        let read = try #require(SyncChat(Record(collection: SyncCollection.chat, id: chat.id, fields: chat.fields)))
        #expect(read.cli == "codex" && read.model == "gpt-6" && read.effort == "high")
    }

    @Test func wordsCarryAPick() throws {
        let fields = SyncSend.fields(device: "mac", chat: "a:one", text: "Go", choice: nil, kind: nil, project: nil, at: 1,
                                     model: "opus", effort: "max")
        let record = Record(collection: SyncChats.send, id: "s", fields: fields)
        let words = try #require(SyncChats.waiting([record], device: "mac").first)
        #expect(words.model == "opus" && words.effort == "max")
        #expect(SyncSend(record)?.model == "opus" && SyncSend(record)?.effort == "max")
        #expect(ChatCommand.refusal(record) == nil)
        let plain = SyncSend.fields(device: "mac", chat: "a:one", text: "Go", choice: nil, kind: nil, project: nil, at: 1)
        #expect(plain["model"] == nil && plain["effort"] == nil)
    }

    @Test func aPickIsFittedToWhatTheMacHas() {
        // Known model and effort: as picked; the model names its agent.
        #expect(SyncChats.fit(cli: nil, model: "gpt-6", effort: "high", among: models) == ("codex", "gpt-6", "high"))
        // An effort the model lacks: the most it takes short of it.
        #expect(SyncChats.fit(cli: "codex", model: "gpt-6", effort: "max", among: models) == ("codex", "gpt-6", "high"))
        #expect(SyncChats.fit(cli: "codex", model: "gpt-6", effort: "bogus", among: models) == ("codex", "gpt-6", nil))
        // An unknown model, or one of another agent: the chat keeps its own.
        #expect(SyncChats.fit(cli: "claude", model: "nope", effort: "high", among: models) == ("claude", nil, "high"))
        #expect(SyncChats.fit(cli: "claude", model: "gpt-6", effort: nil, among: models) == ("claude", nil, nil))
        #expect(SyncChats.fit(cli: nil, model: "nope", effort: "high", among: models) == (nil, nil, nil))
    }

    @Test func aPickForAChatThisMacDoesntHaveStillFailsAsBefore() {
        let words = SyncChats.Words(id: "s", chat: "a:missing-\(UUID().uuidString)", text: "Go", kind: "agent", project: nil,
                                    choice: nil, at: Date(), model: "opus", effort: "high")
        #expect(SyncCenter().say(words).reason == "That chat isn't on this Mac any more.")
    }

    @Test func opencodeModelsAppearInEveryAndOfferedOnlyWhenConnectedAndUnhidden() {
        let flash = SyncMacModel(cli: "opencode", model: "opencode/glm-5.3-flash", name: "Glm 5.3 Flash", about: "opencode/glm-5.3-flash")
        let sonnet = SyncMacModel(cli: "opencode", model: "opencode-go/claude-sonnet-5-5", name: "Claude Sonnet 5 5", about: "opencode-go/claude-sonnet-5-5")
        withOpenCodeSyncState(connected: false) {
            let every = SyncChats.every()
            #expect(every.contains(flash) && every.contains(sonnet))
            let offeredDisconnected = SyncChats.offered()
            #expect(!offeredDisconnected.contains(flash) && !offeredDisconnected.contains(sonnet))
        }
        withOpenCodeSyncState(connected: true) {
            let offered = SyncChats.offered()
            #expect(offered.contains(flash) && offered.contains(sonnet))
            ModelDefaults.shared.hidden.insert(flash.id)
            let filtered = SyncChats.offered()
            #expect(!filtered.contains(flash) && filtered.contains(sonnet))
        }
    }

    @Test func incomingOpenCodeModelStartsNewChatOnThatModel() throws {
        try withOpenCodeSyncState(connected: true) {
            let inferredRecord = Record(collection: SyncChats.send, id: "s-inferred-" + UUID().uuidString,
                                        fields: SyncSend.fields(device: "mac", chat: nil, text: "Check this", choice: nil,
                                                                kind: .agent, project: nil, at: 1, model: "opencode/glm-5.3-flash"))
            let inferredWords = try #require(SyncChats.waiting([inferredRecord], device: "mac").first)
            let inferredResult = SyncCenter().say(inferredWords)
            #expect(inferredResult.reason == nil)
            let inferredMade = try #require(inferredResult.made)
            #expect(inferredMade.hasPrefix("a:"))
            let inferredID = String(inferredMade.dropFirst(2))
            defer {
                _ = Agents.shared.stop(inferredID)
                Chats.shared.remove(inferredID)
            }
            let inferredSession = try #require(Agents.shared.session(inferredID))
            #expect(inferredSession.cli == "opencode")
            #expect(inferredSession.model == "opencode/glm-5.3-flash")
            #expect(!inferredSession.full && !inferredSession.textOnly && inferredSession.fromPhone)

            let explicitRecord = Record(collection: SyncChats.send, id: "s-explicit-" + UUID().uuidString,
                                        fields: SyncSend.fields(device: "mac", chat: nil, text: "Check this too", choice: nil,
                                                                kind: .agent, project: nil, at: 2, agent: .opencode,
                                                                model: "opencode-go/claude-sonnet-5-5"))
            let explicitWords = try #require(SyncChats.waiting([explicitRecord], device: "mac").first)
            let explicitResult = SyncCenter().say(explicitWords)
            #expect(explicitResult.reason == nil)
            let explicitMade = try #require(explicitResult.made)
            #expect(explicitMade.hasPrefix("a:"))
            let explicitID = String(explicitMade.dropFirst(2))
            defer {
                _ = Agents.shared.stop(explicitID)
                Chats.shared.remove(explicitID)
            }
            let explicitSession = try #require(Agents.shared.session(explicitID))
            #expect(explicitSession.cli == "opencode")
            #expect(explicitSession.model == "opencode-go/claude-sonnet-5-5")
            #expect(!explicitSession.full && !explicitSession.textOnly && explicitSession.fromPhone)
        }
    }

    @Test func incomingOpenCodeModelSwitchesExistingSavedChatAndStaysBrowserOnly() throws {
        try withOpenCodeSyncState(connected: true) {
            let chatID = "opencode-sync-" + UUID().uuidString
            let saved = Chat(id: chatID, title: "OpenCode chat", began: .here, cli: "opencode",
                             model: "opencode/glm-5.3-flash", thread: "ses_sync",
                             items: [ChatItem(id: "q1", kind: .asked, text: "Hi", state: .done)],
                             state: "done", answer: "Hello", started: Date(), updated: Date(), textOnly: false)
            Chats.shared.keep(saved)
            defer {
                _ = Agents.shared.stop(chatID)
                Chats.shared.remove(chatID)
            }
            let fields = SyncSend.fields(device: "mac", chat: "a:\(chatID)", text: "Try another", choice: nil,
                                         kind: nil, project: nil, at: 3, model: "opencode-go/claude-sonnet-5-5")
            let record = Record(collection: SyncChats.send, id: "s-switch-" + UUID().uuidString, fields: fields)
            let words = try #require(SyncChats.waiting([record], device: "mac").first)
            let result = SyncCenter().say(words)
            #expect(result.reason == nil)
            let session = try #require(Agents.shared.session(chatID))
            #expect(session.cli == "opencode")
            #expect(session.model == "opencode-go/claude-sonnet-5-5")
            #expect(Chats.shared.chat(chatID)?.model == "opencode-go/claude-sonnet-5-5")
            #expect(!session.full && !session.textOnly)
            let env = OpenCodeRunner.sessionEnvironment([:], textOnly: session.textOnly, full: session.full)
            #expect(env["OPENCODE_CONFIG_CONTENT"] == OpenCodeRunner.browserOnlyConfig)
        }
    }

    @Test func opencodeSyncModelsDistinguishSameNameAcrossProviders() throws {
        try withOpenCodeSyncState(connected: true) {
            Store.settings.set("opencode/claude-sonnet-5-5\nopenrouter/anthropic/claude-sonnet-5-5\nopenrouter/~z-ai/glm-latest\n",
                               forKey: "agents.opencode.models")
            let record = Record(collection: OpenOnMac.capability, id: "mac",
                                fields: SyncChats.capability(device: "mac", models: SyncChats.offered()))
            let roundTripped = ModelPick.models(record, device: "mac")

            let direct = try #require(roundTripped.first { $0.model == "opencode/claude-sonnet-5-5" })
            let routed = try #require(roundTripped.first { $0.model == "openrouter/anthropic/claude-sonnet-5-5" })
            let tilde = try #require(roundTripped.first { $0.model == "openrouter/~z-ai/glm-latest" })

            #expect(direct.name == "Claude Sonnet 5 5" && routed.name == "Claude Sonnet 5 5")
            #expect(direct.about == "opencode/claude-sonnet-5-5")
            #expect(routed.about == "openrouter/anthropic/claude-sonnet-5-5")
            #expect(direct.detail == "opencode/claude-sonnet-5-5" && routed.detail == "openrouter/anthropic/claude-sonnet-5-5")
            #expect(direct.detail != routed.detail)
            #expect(direct.choiceLabel == "Claude Sonnet 5 5 · opencode")
            #expect(routed.choiceLabel == "Claude Sonnet 5 5 · openrouter/anthropic")
            #expect(direct.choiceLabel != routed.choiceLabel)
            #expect(tilde.choiceLabel == "Glm Latest · openrouter/z-ai")

            let emptyAbout = SyncMacModel(cli: "opencode", model: "openrouter/~z-ai/glm-latest", name: "Glm Latest", about: "")
            #expect(emptyAbout.detail == "openrouter/~z-ai/glm-latest")
            #expect(emptyAbout.choiceLabel == "Glm Latest · openrouter/z-ai")

            let claude = SyncMacModel(cli: "claude", model: "opus", name: "Claude Opus", about: "For long, hard tasks.")
            let codex = SyncMacModel(cli: "codex", model: "gpt-6", name: "GPT-6", about: "")
            #expect(claude.detail == "For long, hard tasks." && claude.choiceLabel == "Claude Opus")
            #expect(codex.detail.isEmpty && codex.choiceLabel == "GPT-6")
        }
    }
}
