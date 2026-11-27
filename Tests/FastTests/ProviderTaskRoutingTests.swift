import Foundation
import Testing
import SyncKit
@testable import Fast

/// Every entry point that starts a task, on every provider: your Gemini or
/// your Cursor takes it with Yab's tools, as Claude and ChatGPT do, and no
/// other plan stands in unsaid (the X report of 2026-10-22, "signed in with
/// Gemini, the agent is using Claude", and the parity ask that followed).
@Suite(.serialized)
@MainActor
struct ProviderTaskRoutingTests {
    private static let keys = ["models.chats.cli", "models.chats.model", "models.chats.effort", "models.chats.configured",
                               "models.chats.source", "models.tasks.source", "models.commands.source",
                               "models.tasks.cli", "models.tasks.model", "models.tasks.effort",
                               "models.commands.cli", "models.commands.model", "models.commands.effort",
                               CursorRunner.connectionKey]

    /// The world: `provider` chosen at Connect and signed in, Claude Code on
    /// this Mac too (so a silent stand-in would be Claude), Tasks on Auto.
    private func world(_ provider: String, claudeHere: Bool = true, authorize: Bool = true,
                       additionalProviders: [String] = [], _ body: () throws -> Void) rethrows {
        let account = GeminiAccount.shared
        let old = (account.binary, account.signedIn, account.enabled, account.models.map(\.model).joined(separator: "\n"))
        let saved = Self.keys.map { Store.settings.object(forKey: $0) }
        let providers = Set([provider] + additionalProviders).sorted()
        let consentKeys = ["agents.explicit-connections.v1", "agents.revoked-connections.v1", "agents.consent-migrated.v1"]
            + providers.map { "agents.connection-generation." + $0 }
        let savedConsent = consentKeys.map { Store.settings.object(forKey: $0) }
        let consent = ProviderConsent.shared
        let oldTasks = ModelDefaults.shared[.tasks], oldChats = ModelDefaults.shared[.chats], oldShell = Shell.cached
        let oldCommands = ModelDefaults.shared[.commands]
        ModelDefaults.toolPlanHereInTests = claudeHere
        defer {
            for cli in providers { consent.revoke(cli) }
            for (key, value) in zip(consentKeys, savedConsent) { Store.settings.set(value, forKey: key) }
            ModelDefaults.toolPlanHereInTests = nil
            account.enabled = old.2
            account.pretend(binary: old.0, signedIn: old.1, models: old.3)
            ModelDefaults.shared[.tasks] = oldTasks
            ModelDefaults.shared[.chats] = oldChats
            ModelDefaults.shared[.commands] = oldCommands
            for (key, value) in zip(Self.keys, saved) { Store.settings.set(value, forKey: key) }
            Shell.cached = oldShell
        }
        for cli in providers {
            consent.revoke(cli)
            if authorize { consent.grant(cli) }
        }
        account.enabled = true
        account.pretend(binary: provider == "gemini" ? "/fixture/agy" : nil, signedIn: provider == "gemini",
                        models: "gemini-3.8-flash-medium")
        Store.settings.set(provider == "cursor", forKey: CursorRunner.connectionKey)
        ModelDefaults.shared[.chats] = ModelChoice(cli: provider)
        ModelDefaults.shared[.tasks] = ModelChoice()
        // No agy path: a Gemini session that got as far as launching fails
        // "not set up" instead of running anything.
        Shell.cached = Shell.Found(claude: claudeHere ? "/fixture/claude" : nil, codex: nil,
                                   cursor: provider == "cursor" ? "/fixture/cursor-agent" : nil, gemini: nil, env: [:])
        try body()
    }

    /// A run as the entry point starts it, kept from launching a process.
    private func started(_ make: (Agents) -> Agents.Session) -> Agents.Session {
        let agents = Agents()
        let session = make(agents)
        session.movable = false
        if session.state.live { session.turnPermit.revoke(); session.state = .failed }
        return session
    }

    private static let providers = ["gemini", "cursor"]

    /// With Yab's tools, browser only: no Mac grant asked, no text-only
    /// stand-in, no line saying another plan took it.
    private func expectAgent(_ session: Agents.Session, _ provider: String, _ entry: String) {
        #expect(session.cli == provider, "\(entry) on \(provider) ran on \(session.cli)")
        #expect(!session.textOnly, "\(entry) on \(provider) had no tools")
        #expect(!session.full && !session.awaitingMacAccess, "\(entry) on \(provider) reached for the Mac")
        #expect(session.handoverLine == nil, "\(entry) on \(provider) said \(session.handoverLine ?? "")")
        #expect(session.result != ModelDefaults.geminiUnattended && session.result != GeminiSupport.noTools,
                "\(entry) on \(provider) failed: \(session.result)")
    }

    /// ⌘T's words, Do It, the yab MCP `task` and `agent-run` without a cli:
    /// Agents.task and the bench both start `run` with no agent named.
    @Test func aTaskFromTheFieldRunsOnYourProviderWithTools() {
        for provider in Self.providers {
            world(provider) {
                let session = started { $0.run(prompt: "Find me a flight to Lisbon", cli: nil, access: "browser", resume: nil) }
                expectAgent(session, provider, "field task")
            }
        }
    }

    /// Routines' watch runs and boosts' own runs: quiet, with no agent named.
    @Test func routinesAndBoostsRunOnYourProvider() {
        for provider in Self.providers {
            world(provider) {
                let routine = started { $0.run(prompt: "Check my inbox", cli: nil, effort: "low", access: "browser", quiet: true,
                                               name: "Watching", resume: nil) }
                expectAgent(routine, provider, "routine")
                let boost = started { $0.run(prompt: "Make a boost that hides Shorts", cli: nil, access: "browser", quiet: true,
                                             name: "Boost", sealed: true, resume: nil) }
                expectAgent(boost, provider, "boost")
                let check = started { $0.run(prompt: "Report on this page", cli: nil, access: "text", quiet: true,
                                             name: "Boost check", sealed: true, resume: nil) }
                #expect(check.cli == provider && check.textOnly && check.result != ModelDefaults.geminiUnattended)
            }
        }
    }

    /// Page watches, boost review, boost services, routines with a plan of
    /// their own and the iPhone's tasks read the Tasks default and pass its
    /// plan on: it names your provider.
    @Test func theTasksDefaultNamesYourProvider() {
        for provider in Self.providers {
            world(provider) {
                let pick = ModelDefaults.shared.pick(.tasks)
                #expect(pick.cli == provider)
                let watch = started { $0.run(prompt: "Write the check again", cli: pick.cli, model: pick.model, effort: pick.effort,
                                             access: "browser", quiet: true, name: "Watch: price", resume: nil) }
                expectAgent(watch, provider, "page watch")
                #expect(ModelDefaults.shared.tasksNote == nil && ModelDefaults.shared.tasksLine(provider) == nil)
            }
        }
    }

    /// A task asked for by name (the yab MCP `task` with a cli, `agent-run
    /// --cli`, the iPhone choosing a model) stays on that plan.
    @Test func aProviderAskedForByNameStaysThatProvider() {
        for provider in Self.providers {
            world(provider, additionalProviders: ["claude"]) {
                let session = started { $0.run(prompt: "Do it", cli: provider, access: "browser", resume: nil, strict: true) }
                expectAgent(session, provider, "named task")
                let claude = started { $0.run(prompt: "Do it", cli: "claude", access: "browser", resume: nil, strict: true) }
                #expect(claude.cli == "claude" && claude.handoverLine == nil)
            }
        }
    }

    /// Subagents a task starts run on its plan, browser only.
    @Test func subagentsRunOnTheirTasksPlan() {
        for provider in Self.providers {
            world(provider) {
                let agents = Agents()
                let up = agents.run(prompt: "Compare three laptops", cli: provider, access: "browser", resume: nil, strict: true)
                up.state = .running
                up.thread = "T1"
                let (child, _) = agents.spawn(from: up.id, prompt: "Read the first review", profile: "default", name: "Reviews", minutes: 5)
                #expect(child?.cli == provider && child?.textOnly == false && child?.full == false)
                // fork_self is Claude Code's alone, as with Codex: said, nothing started.
                let (fork, why) = agents.spawn(from: up.id, prompt: "Carry on", profile: "fork_self", name: nil, minutes: 5)
                #expect(fork == nil && why?.contains("fork_self needs Claude Code") == true)
                for session in agents.sessions where session.state.live {
                    session.turnPermit.revoke()
                    session.state = .failed
                }
            }
        }
    }

    /// Just after launch, before the login shell answered: a connected
    /// Cursor still takes the first task (it fell to Claude, the e2e eval's
    /// first run of 2026-10-23).
    @Test func cursorTakesTheFirstTaskBeforeTheShellAnswered() {
        world("cursor") {
            Shell.cached = nil
            #expect(AgentModels.here("cursor"))
            #expect(ModelDefaults.shared.pick(.tasks).cli == "cursor")
            let session = started { $0.run(prompt: "Find me a flight to Lisbon", cli: nil, access: "browser", resume: nil) }
            expectAgent(session, "cursor", "first task")
        }
    }

    /// Gemini keeps to Yab's tools: asked for the Mac outright, it says so.
    @Test func geminiAskedForTheMacSaysItKeepsToTheBrowser() {
        world("gemini") {
            let session = started { $0.run(prompt: "Tidy my Downloads folder", cli: "gemini", access: "full", resume: nil, strict: true) }
            #expect(session.state == .failed && session.result == GeminiSupport.noMac)
        }
    }

    /// Connect: as the first plan, either takes the defaults never chosen,
    /// Tasks too, and says nothing of a stand-in (ConnectKeepsModelsTests has
    /// the rest of the rule).
    @Test func theFirstProviderConnectedPutsTasksOnIt() {
        for provider in Self.providers {
            world(provider, additionalProviders: AgentPlan.clis) {
                for cli in AgentPlan.clis where cli != provider { ProviderConsent.shared.revoke(cli) }
                for work in [ModelDefaults.Work.tasks, .chats, .commands] {
                    ModelDefaults.shared[work] = ModelChoice()
                    Store.settings.removeObject(forKey: "models.\(work.rawValue).source")
                }
                ModelDefaults.shared.useProvider(provider)
                #expect(ModelDefaults.shared[.tasks].cli == provider)
                #expect(ModelDefaults.shared[.chats].cli == provider && ModelDefaults.shared[.commands].cli == provider)
            }
        }
        let detail = AgentsIntro.words(flow: nil, chosen: ["gemini"]).detail
        #expect(detail.contains("tasks in your tabs") && !detail.contains("aren't available"))
        #expect(ModelDefaults.Work.tasks.refusal("gemini") == nil && ModelDefaults.Work.tasks.refusal("cursor") == nil)
        #expect(ModelDefaults.Work.drafts.refusal("gemini") == nil && ModelDefaults.Work.drafts.refusal("cursor") == nil)
    }

    /// Gemini alone on the Mac takes tasks too, tools and all.
    @Test func geminiAloneTakesTasksWithTools() {
        world("gemini", claudeHere: false) {
            #expect(ModelDefaults.shared.pick(.tasks).cli == "gemini")
            let session = started { $0.run(prompt: "What is on this page?", cli: nil, access: "browser", resume: nil) }
            expectAgent(session, "gemini", "Gemini alone")
            #expect(Agents.preferred(connected: ["gemini"], found: Shell.Found(claude: nil, codex: nil, cursor: nil, gemini: "/agy", env: [:])) == "gemini")
        }
    }

    @Test func installedSignedInDefaultsDoNotGrantTaskPermission() {
        for provider in Self.providers {
            world(provider, authorize: false) {
                let agents = Agents()
                let denied = agents.run(prompt: "Read this page", cli: provider, access: "browser", resume: nil, strict: true)
                #expect(denied.state == .failed && denied.result == ProviderConsent.refusal)
                #expect(!agents.sessions.contains { $0.id == denied.id })
                #expect(denied.process == nil && denied.server == nil && denied.input == nil)
                #expect(!ProviderConsent.shared.allows(provider))
            }
        }
    }

    /// The rule itself, both ways the flag can be.
    @Test func autoTasksFollowsYourProvider() {
        #expect(ModelDefaults.autoTasks(text: "codex", preferred: "claude", toolsHere: true) == ("claude", nil))
        #expect(ModelDefaults.autoTasks(text: "gemini", preferred: "codex", toolsHere: true, geminiTools: true) == ("gemini", nil))
        #expect(ModelDefaults.autoTasks(text: "cursor", preferred: "claude", toolsHere: true, cursorHere: true) == ("cursor", nil))
        #expect(ModelDefaults.autoTasks(text: "cursor", preferred: "claude", toolsHere: true, cursorHere: false) == ("claude", nil))
        #expect(ModelDefaults.autoTasks(text: "opencode", preferred: "claude", toolsHere: true, opencodeHere: true) == ("opencode", nil))
        #expect(ModelDefaults.autoTasks(text: "opencode", preferred: "claude", toolsHere: true, opencodeHere: false) == ("claude", nil))
        // A build whose Gemini has no tools still says who stood in.
        let standIn = ModelDefaults.autoTasks(text: "gemini", preferred: "codex", toolsHere: true, geminiTools: false)
        #expect(standIn.cli == "codex" && standIn.line?.hasSuffix("so ChatGPT took this task.") == true)
        let alone = ModelDefaults.autoTasks(text: "gemini", preferred: "claude", toolsHere: false, geminiTools: false)
        #expect(alone.cli == "gemini" && alone.line == ModelDefaults.geminiAloneLine)
        #expect(GeminiSupport.launchRefusal("gemini", textOnly: false, tools: false) == GeminiSupport.noTools)
        #expect(GeminiSupport.launchRefusal("gemini", textOnly: false, remote: true) == nil)
    }

    /// The iPhone's chats and tasks name all five plans.
    @Test func theIPhoneKnowsEveryPlan() {
        #expect(Set(ChatAgent.allCases.map(\.rawValue)) == Set(AgentPlan.clis))
        #expect(SyncMacModel.plan("gemini") == "Gemini" && SyncMacModel.plan("cursor") == "Cursor" && SyncMacModel.plan("opencode") == "OpenCode")
    }
}
