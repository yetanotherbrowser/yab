import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
struct GeminiDefaultTests {
    @Test @MainActor func everyProviderIsOfferedAtConnect() {
        #expect(AgentSetupModel.clis == ["claude", "codex", "cursor", "gemini"])
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
        for cli in ["claude", "codex", "cursor", "gemini"] {
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

    @Test @MainActor func coldLaunchWithOnlyGeminiConnectedStaysOnGemini() {
        let defaults = ModelDefaults.shared, consent = ProviderConsent.shared, account = GeminiAccount.shared
        let oldShell = Shell.cached
        let oldAccount = (account.binary, account.signedIn, account.enabled, account.models.map(\.model).joined(separator: "\n"))
        let oldChoices = ModelDefaults.Work.allCases.map { defaults[$0] }
        let modelKeys = ModelDefaults.Work.allCases.flatMap { work in
            ["cli", "model", "effort", "source"].map { "models.\(work.rawValue).\($0)" }
        } + ["models.chats.configured"]
        let savedModels = modelKeys.map { Store.settings.object(forKey: $0) }
        let consentKeys = ["agents.explicit-connections.v1", "agents.revoked-connections.v1", "agents.consent-migrated.v1"]
            + AgentPlan.clis.map { "agents.connection-generation." + $0 }
        let savedConsent = consentKeys.map { Store.settings.object(forKey: $0) }
        defer {
            for cli in AgentPlan.clis { consent.revoke(cli) }
            for (key, value) in zip(consentKeys, savedConsent) { Store.settings.set(value, forKey: key) }
            Shell.cached = oldShell
            account.enabled = oldAccount.2
            account.pretend(binary: oldAccount.0, signedIn: oldAccount.1, models: oldAccount.3)
            for (work, choice) in zip(ModelDefaults.Work.allCases, oldChoices) { defaults[work] = choice }
            for (key, value) in zip(modelKeys, savedModels) { Store.settings.set(value, forKey: key) }
        }
        for cli in AgentPlan.clis { consent.revoke(cli) }
        consent.grant("gemini")
        Shell.cached = nil
        account.enabled = true
        account.pretend(binary: nil, signedIn: nil, models: "")
        for work in ModelDefaults.Work.allCases { defaults[work] = ModelChoice() }

        #expect(account.available)
        #expect(AgentModels.here("gemini"))
        #expect(Agents.preferred == "gemini")
        #expect(defaults.automatic(.chats) == "gemini")
        #expect(defaults.pick(.chats).cli == "gemini")
        #expect(defaults.pick(.tasks).cli == "gemini")

        // A file-only shell scan that missed agy in a custom login PATH must not fall back to Claude.
        Shell.cached = Shell.Found(claude: "/fixture/claude", gemini: nil, env: [:])
        #expect(account.available)
        #expect(AgentModels.here("gemini"))
        #expect(Agents.preferred == "gemini")
        #expect(defaults.automatic(.chats) == "gemini")

        // Once a check verifies Gemini is signed out, Auto stops picking it.
        account.pretend(binary: "/fixture/agy", signedIn: false, models: "")
        #expect(!account.available)
        #expect(!AgentModels.here("gemini"))
        #expect(defaults.automatic(.chats) != "gemini")
    }

}
