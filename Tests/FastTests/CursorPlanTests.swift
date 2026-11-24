import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor
struct CursorPlanTests {
    @Test func cursorIsAPlanInTheCommonConnectionAndDefaults() {
        #expect(AgentSetupModel.clis.contains("cursor"))
        #expect(AgentSetupModel.plan("cursor") == "Cursor")
        #expect(Agents.preferred(connected: [], found: Shell.Found(claude: nil, codex: nil, cursor: "/cursor", env: [:])) == "cursor")
        #expect(AgentSetupModel.install("cursor").contains("cursor.com/install"))
        #expect(ModelDefaults.Work.tasks.plans.contains("cursor"))
        #expect(ModelDefaults.Work.commands.plans.contains("cursor"))
        #expect(Agents.preferred(connected: ["cursor"], found: Shell.Found(claude: nil, codex: nil, cursor: "/cursor", env: [:])) == "cursor")
    }

    /// #273: only Cursor connected, Claude Code installed for other work.
    @Test func cursorOnlyAutoNeverPicksAPlanThatIsNotConnected() {
        let found = Shell.Found(claude: "/claude", codex: nil, cursor: "/cursor", env: [:])
        let preferred = Agents.preferred(connected: ["cursor"], found: found)
        #expect(preferred == "cursor")
        // Tasks and commands: Auto is Cursor's, and says so.
        #expect(ModelDefaults.autoDetail(.tasks, writer: nil, preferred: preferred) == "Cursor")
        #expect(ModelDefaults.autoDetail(.commands, writer: nil, preferred: preferred) == "Cursor")
        #expect(ModelDefaults.autoTrouble(.tasks, writer: nil) == nil)
        // Form drafts: nobody writes them, and Auto says so, never "Claude Sonnet".
        let writer = ModelDefaults.draftWriter(chosen: nil, connected: [])
        #expect(writer == nil)
        #expect(ModelDefaults.autoDetail(.drafts, writer: writer, preferred: preferred) != "Claude Sonnet")
        #expect(ModelDefaults.autoTrouble(.drafts, writer: writer) != nil)
        #expect(ModelDefaults.autoDetail(.drafts, writer: "cursor", preferred: preferred) == "Cursor")
        // A Claude model chosen earlier doesn't bring Claude back unconnected.
        #expect(ModelDefaults.draftWriter(chosen: "claude", connected: []) == nil)
        #expect(ModelDefaults.draftWriter(chosen: "codex", connected: ["claude", "codex"]) == "codex")
        #expect(ModelDefaults.draftWriter(chosen: "cursor", connected: ["codex"]) == "codex")
        #expect(ModelDefaults.autoDetail(.drafts, writer: "codex", preferred: "codex") == "ChatGPT")
    }

    /// #273: Cursor is in every default's list; where it can't do the
    /// work it is there greyed, with why.
    @Test func cursorIsInEveryDefaultsListOrSaysWhyNot() {
        for work in ModelDefaults.Work.allCases {
            #expect(work.plans.contains("cursor"))
        }
        #expect(ModelDefaults.Work.tasks.refusal("cursor") == nil)
        #expect(ModelDefaults.Work.commands.refusal("cursor") == nil)
        #expect(ModelDefaults.Work.drafts.refusal("cursor") == nil)
        #expect(ModelDefaults.Work.drafts.refusal("claude") == nil)
        #expect(ModelDefaults.Work.drafts.refusal("codex") == nil)
    }

    /// #273: each plan's empty part of the list names its own plan.
    @Test func emptyPlanWordsNameTheirOwnPlan() {
        #expect(ModelField.emptyWords("claude", allHidden: true).hasPrefix("Claude's"))
        #expect(ModelField.emptyWords("cursor", allHidden: true).hasPrefix("Cursor's"))
        #expect(ModelField.emptyWords("codex", allHidden: false) == "ChatGPT's models show here after its first task.")
        #expect(!ModelField.emptyWords("claude", allHidden: false).contains("ChatGPT"))
        #expect(!ModelField.emptyWords("cursor", allHidden: false).contains("ChatGPT"))
        for cli in AgentSetupModel.clis {
            #expect(!ModelField.emptyWords(cli, allHidden: true).contains("\u{2014}"))
        }
    }

    /// #273: an app icon's mark is cut to its own square, measured, so a
    /// full-bleed icon (Cursor's) and one with the usual margin come out
    /// the same size, and a faint shadow doesn't count.
    @Test func appIconsAreCutToTheirOwnSquare() {
        func icon(fill: CGFloat, shadow: Bool) -> NSImage {
            NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
                let inset = rect.width * (1 - fill) / 2
                if shadow {
                    NSColor.black.withAlphaComponent(0.25).setFill()
                    NSRect(x: inset, y: inset - 12, width: rect.width - 2 * inset, height: 20).fill()
                }
                NSColor.black.setFill()
                rect.insetBy(dx: inset, dy: inset).fill()
                return true
            }
        }
        let usual = AgentIcons.square(icon(fill: 0.8, shadow: true))
        let full = AgentIcons.square(icon(fill: 1, shadow: false))
        #expect(abs(usual.size.width - 205) <= 2)
        #expect(usual.size.width == usual.size.height)
        #expect(full.size.width == 256)
        #expect(full.size.height == 256)
    }

    @Test func unauthenticatedCursorStatusIsNotSuccess() async throws {
        let fixture = IsolatedProviderConsent("cursor")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("cursor"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-status-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "#!/bin/sh\necho '{\"isAuthenticated\":false}'\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let who = await CursorRunner.identify(binary: file.path, env: ["PATH": "/usr/bin:/bin"], permit: permit)
        #expect(!who.signedIn)
    }

    @Test func modelCatalogUsesIdsFromTheCliAndStripsTerminalFormatting() {
        let models = CursorRunner.parseModels("Available models\n\u{1B}[36mcomposer-2\u{1B}[0m - Composer 2 (current, default)\ngpt-6 - GPT-6\ngpt-6 - Duplicate\nTip: use --model <id> - not a model\n")
        #expect(models.map(\.model) == ["composer-2", "gpt-6"])
        #expect(models.first?.name == "Composer 2")
        #expect(models.allSatisfy { $0.cli == "cursor" })
    }

    @Test func officialStatusSurvivesPassiveReadsAndFailuresClearIt() async throws {
        let fixture = IsolatedProviderConsent("cursor")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("cursor"))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-status-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("cursor")
        let status = home.appendingPathComponent("status.json")
        let exit = home.appendingPathComponent("exit")
        try """
        #!/usr/bin/python3
        import pathlib,sys
        root=pathlib.Path(__file__).parent
        if sys.argv[1:]==['models']:
            print('composer-2.5 - Composer 2.5')
        else:
            sys.stdout.write((root/'status.json').read_text())
            sys.exit(int((root/'exit').read_text()))
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let found = Shell.Found(claude: nil, codex: nil, cursor: binary.path, env: env)
        let plans = PlanAccounts(settings: fixture.settings, consent: fixture.consent)
        // Presence of guessed items is not a login before official status.
        #expect(!(await PlanAccounts.read("cursor", env: env, keychain: { _ in true })).signedIn)
        for (body, code) in [(#"{"isAuthenticated":false}"#, 0), ("invalid JSON", 0), (#"{"isAuthenticated":true}"#, 1)] {
            try #"{"isAuthenticated":true,"userInfo":{"email":"cursor@example.test"}}"#.write(to: status, atomically: true, encoding: .utf8)
            try "0".write(to: exit, atomically: true, encoding: .utf8)
            #expect(await CursorRunner.identify(binary: binary.path, env: env, permit: permit).signedIn)
            let passive = (await PlanAccounts.read("cursor", env: env, keychain: { _ in false }))
            #expect(passive.signedIn && passive.email == "cursor@example.test")
            await plans.look(found)
            #expect(!plans.signedOut.contains("cursor"))
            #expect(plans.usual["cursor"]?.email == "cursor@example.test")
            try body.write(to: status, atomically: true, encoding: .utf8)
            try String(code).write(to: exit, atomically: true, encoding: .utf8)
            #expect(!(await CursorRunner.identify(binary: binary.path, env: env, permit: permit)).signedIn)
            #expect(!(await PlanAccounts.read("cursor", env: env, keychain: { _ in true })).signedIn)
            await plans.look(found)
            #expect(plans.signedOut.contains("cursor"))
        }
        let unrelated = ["HOME": home.appendingPathComponent("another-home").path, "PATH": "/usr/bin:/bin"]
        #expect(!(await PlanAccounts.read("cursor", env: unrelated, keychain: { _ in true })).signedIn)
    }

    @Test func aRevokedPermitDoesNotAskTheCursorCliForStatus() async throws {
        let fixture = IsolatedProviderConsent("cursor")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("cursor"))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-denied-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("cursor")
        let marker = home.appendingPathComponent("launched")
        try "#!/bin/sh\ntouch \"$HOME/launched\"\necho '{\"isAuthenticated\":true}'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        fixture.consent.revoke("cursor")
        let who = await CursorRunner.identify(binary: binary.path, env: ["HOME": home.path, "PATH": "/usr/bin:/bin"], permit: permit)
        #expect(!who.signedIn && who.email == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!fixture.consent.allows("cursor"))
    }

    @Test func cursorOAuthLinkIsOpenedByTheCommonSignInFlow() {
        let url = Agents.signInURL(in: "Open: https://cursor.com/loginDeepControl?challenge=fixture&uuid=fixture&mode=login&redirectTarget=cli\n")
        #expect(url?.host == "cursor.com")
        #expect(Agents.signInURL(in: "https://cursor.com/docs\n") == nil)
    }

    @Test func textOnlyHasNoMcpAndDeniesNativeTools() throws {
        let room = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-text-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: room) }
        try CursorRunner.prepareTools(in: room, command: "/yab", args: [], textOnly: true)
        let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: room.appendingPathComponent(".cursor/mcp.json"))) as? [String: Any]
        #expect((mcp?["mcpServers"] as? [String: Any])?.isEmpty == true)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: room.appendingPathComponent(".cursor/cli.json"))) as? [String: Any]
        let denied = (config?["permissions"] as? [String: Any])?["deny"] as? [String]
        #expect(denied == ["Shell(*)", "Read(**)", "Write(**)", "WebFetch(*)", "Mcp(*:*)"])
    }
    @Test func anEditedTextPolicyIsNeverSilentlyTrusted() throws {
        let room = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: room) }
        try CursorRunner.prepareTools(in: room, command: "/yab", args: [], textOnly: true)
        let file = room.appendingPathComponent(".cursor/cli.json")
        let edited = Data(#"{"permissions":{"allow":["Shell(*)"],"deny":[]}}"#.utf8)
        try edited.write(to: file)
        #expect(throws: (any Error).self) { try CursorRunner.prepareTools(in: room, command: "/yab", args: [], textOnly: true) }
        #expect(try Data(contentsOf: file) == edited)
    }

    @Test func everyPlanSaysItselfFromOneTable() {
        // Connect's plans are the table's, less Gemini, which signs in from its own row.
        #expect(AgentPlan.connectable.map(\.cli) == AgentSetupModel.clis)
        #expect(AgentPlan.all.map(\.name) == ["Claude", "ChatGPT", "Cursor", "Gemini", "OpenCode"])
        // One mark for Cursor everywhere a plan's mark shows.
        #expect(FieldAnswer.mark("cursor") == "brand.cursor")
        #expect(FieldAnswer.mark("claude") == "brand.claude")
        #expect(FieldAnswer.mark("mac") == "brand.apple.intelligence")
        #expect(AgentPlan.cursor.group == "Cursor Plan")
        // Plan names in copy, joined as a sentence lists them.
        #expect(AgentSetupModel.names(["claude", "codex", "cursor"]) == "Claude, ChatGPT, and Cursor")
        #expect(AgentSetupModel.list(["Claude", "ChatGPT", "Cursor"], or: true) == "Claude, ChatGPT, or Cursor")
        #expect(WelcomeConnect.needs("cursor").hasPrefix("Cursor"))
        // Cursor runs inside Yab: no skill, no How to Ask, no API key.
        #expect(AgentSetupModel.skilled("claude") && AgentSetupModel.skilled("codex"))
        #expect(!AgentSetupModel.skilled("cursor"))
        #expect(AgentPlan.isPlan("cursor") && !AgentPlan.isPlan("mac") && !AgentPlan.isPlan(nil))
        let found = Shell.Found(claude: "/c", codex: nil, cursor: "/k", env: [:])
        #expect(AgentSetupModel.binary("cursor", in: found) == "/k")
        #expect(AgentSetupModel.binary("codex", in: found) == nil)
        // Cursor writes drafts too (PlanText), from the same table.
        #expect(ModelDefaults.Work.drafts.refusal("cursor") == nil)
        #expect(ModelDefaults.Work.drafts.refusal("claude") == nil && ModelDefaults.Work.tasks.refusal("cursor") == nil)
    }

    @Test func cursorModelsSayNothingTheHeadAlreadySays() {
        let models = CursorRunner.parseModels("composer-2.5 - Composer 2.5\ngpt-5.4-nano - GPT-5.4 Nano\n")
        #expect(models.allSatisfy { $0.about.isEmpty })
    }

}
