import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
struct GeminiDefaultTests {
    @Test @MainActor func everyProviderIsOfferedAtConnect() {
        #expect(AgentSetupModel.clis == ["claude", "codex", "cursor", "gemini", "opencode"])
        #expect(AgentPlan.connectable.map(\.cli) == AgentSetupModel.clis)
    }

    @Test @MainActor func aNewChatsPickerChoiceSurvivesAnotherWindowAndReload() throws {
        let keys = ["models.chats.cli", "models.chats.model", "models.chats.effort", "models.chats.configured"]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        let oldTasks = ModelDefaults.shared[.tasks]
        let chats = ModelDefaults.Work(rawValue: "chats")
        let oldChats = chats.map { ModelDefaults.shared[$0] }
        defer {
            ModelDefaults.shared[.tasks] = oldTasks
            if let chats, let oldChats { ModelDefaults.shared[chats] = oldChats }
            for (key, value) in zip(keys, saved) { Store.settings.set(value, forKey: key) }
        }
        ModelDefaults.shared[.tasks] = ModelChoice(cli: "codex", model: "task-model")
        let first = Browser(windowID: UUID()), second = Browser(windowID: UUID())
        let chosen = ModelChoice(cli: "gemini", model: "gemini-3.8-flash-medium", effort: "high")
        ChatModelLine.choose(browser: first, chat: nil)
        let picker = try #require(first.modelPicker)
        picker.pick(chosen)
        #expect(second.chatAgent == "gemini")
        let work = try #require(ModelDefaults.Work(rawValue: "chats"))
        #expect(ModelDefaults()[work] == chosen)
        #expect(ModelDefaults.shared[.tasks].cli == "codex")
        #expect(work.refusal("gemini") == nil)
        #expect(ModelDefaults.Work.tasks.refusal("gemini") == nil)
    }

    @Test @MainActor func geminiAloneCountsAsConnectedWithoutAnotherPlan() {
        let account = GeminiAccount.shared
        let enabled = account.enabled
        account.enabled = true
        defer { account.enabled = enabled }
        let old = (account.binary, account.signedIn, account.models.map(\.model).joined(separator: "\n"))
        defer { account.pretend(binary: old.0, signedIn: old.1, models: old.2) }
        account.pretend(binary: "/fixture/agy", signedIn: true, models: "gemini-3.8-flash-medium")
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let setup = AgentSetupModel(status: AgentSetup.Status(), consent: fixture.consent)
        #expect(account.ready)
        #expect(setup.connected("gemini"))
        #expect(setup.anyConnected)
        #expect(!setup.arriving)
        fixture.consent.revoke("gemini")
        #expect(account.ready, "A CLI login does not itself grant Yab permission")
        #expect(!setup.connected("gemini") && !setup.anyConnected && setup.arriving)
    }
    @Test @MainActor func choosingAProviderReplacesThePreviousChoice() {
        let setup = AgentSetupModel.shared, previous = AgentSetupModel.shared.picks
        defer { setup.picks = previous }
        for cli in ["claude", "codex", "cursor", "gemini", "opencode"] {
            setup.selectProvider(cli)
            #expect(setup.picks == [cli])
        }
        let empty = AgentsIntro.words(flow: nil, chosen: [])
        #expect(!empty.enabled && empty.button == "Choose a Provider")
        #expect(AgentsIntro.words(flow: nil, chosen: ["gemini"]).button == "Continue")
        #expect(AgentsIntro.words(flow: nil, anyInstalled: false, chosen: ["gemini"], toInstall: "gemini").button == "Continue")
    }

    @Test @MainActor func autoTextWorkUsesOnlyGeminiAndItsToolsAreOn() {
        let account = GeminiAccount.shared
        let old = (account.binary, account.signedIn, account.enabled, account.models.map(\.model).joined(separator: "\n"))
        // A plan with tools on this Mac (GeminiTaskRoutingTests has the Mac with none).
        ModelDefaults.toolPlanHereInTests = true
        defer { ModelDefaults.toolPlanHereInTests = nil; account.enabled = old.2; account.pretend(binary: old.0, signedIn: old.1, models: old.3) }
        account.enabled = true
        account.pretend(binary: "/fixture/agy", signedIn: true, models: "gemini-3.8-flash-medium")
        #expect(ModelDefaults.shared.automatic(.chats) == "gemini")
        #expect(ModelDefaults.shared.automatic(.commands) == "gemini")
        // Tasks follow the Chats default (ProviderTaskRoutingTests), which is Auto here.
        #expect(GeminiSupport.toolsProven && GeminiSupport.toolsOffProven)
    }

}
