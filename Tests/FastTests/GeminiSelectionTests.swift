import Foundation
import Testing
@testable import Fast

@MainActor
struct GeminiSelectionTests {
    @Test func catalogOffersOnlyLevelsAcceptedByTheInstalledGeminiCLI() {
        let rows = GeminiModels.rows("gemini-3.8-flash-high  Gemini Flash High\ngemini-3.8-flash-low  Gemini Flash Low")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.efforts == ["low", "medium", "high"] })
    }

    @Test(arguments: ["xhigh", "max", "future-effort"])
    func unsupportedSavedEffortFailsBeforeCreatingAProfile(effort: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unsupported-gemini-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = GeminiRunnerTests.config(root: root, model: "gemini-3.8-flash-high")
        config.effort = effort
        #expect(throws: GeminiStream.Failure.self) { try config.prepare() }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func explicitEffortKeepsTheSelectedFamilyWithoutContradictoryCLIFlags() {
        // agy 1.4.4 init: base+medium and pinned-high+high accepted;
        // pinned-high+medium rejected. The selected effort must survive.
        let cases: [(String?, String?, String?)] = [
            ("gemini-3.8-flash-high", "medium", "gemini-3.8-flash"),
            ("gemini-3.8-flash-medium", "high", "gemini-3.8-flash"),
            ("gemini-3.8-flash-high", "high", "gemini-3.8-flash-high"),
            ("gemini-3.8-flash-high", nil, "gemini-3.8-flash-high"),
            ("gemini-3.8-flash", "medium", "gemini-3.8-flash"),
            (nil, "medium", nil),
            ("gemini-3.8-flash-preview", "high", "gemini-3.8-flash-preview"),
            ("gemini-3.8-flash-high", "future-effort", "gemini-3.8-flash-high"),
        ]
        for (selected, effort, launched) in cases {
            var config = GeminiRunnerTests.config(root: FileManager.default.temporaryDirectory, model: selected)
            config.effort = effort
            let arguments = config.arguments
            let modelFlag = arguments.firstIndex(of: "--model").map { arguments[$0 + 1] }
            let effortFlag = arguments.firstIndex(of: "--effort").map { arguments[$0 + 1] }
            #expect(modelFlag == launched)
            #expect(effortFlag == effort)
            #expect(config.model == selected, "The stored user choice is unchanged")
        }
    }

    @Test func theProcessValidatesTheNormalizedInitModelExactly() async throws {
        let consent = IsolatedProviderConsent("gemini")
        defer { consent.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("login/Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/usr/bin/python3
        import json, sys
        def emit(event): print(json.dumps(event), flush=True)
        emit({'event':'init','conversation_id':'G1','init':{'model':'gemini-3.8-flash','tools':[],'permission_mode':'request-review'}})
        request=json.loads(sys.stdin.readline())
        emit({'event':'result','result':{'conversation_id':'G1','status':'SUCCESS','response':'MODEL_OK'}})
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var events: [GeminiStream.Event] = []
        var exited = false
        let runner = GeminiRunner { events.append($0) }
        runner.exited = { _ in exited = true }
        defer { runner.stop() }
        var config = GeminiRunner.Configuration(binary: binary.path, profile: root.appendingPathComponent("profile"),
            workspace: root.appendingPathComponent("workspace"), model: "gemini-3.8-flash-high", conversation: nil,
            command: "", mcpArgs: nil, environment: ["HOME": root.appendingPathComponent("login").path, "PATH": "/usr/bin:/bin"])
        config.effort = "medium"
        try runner.start(config, permit: consent.consent.permit("gemini"))
        try runner.send("Reply")
        runner.close()
        try await GeminiRunnerTests.until { exited }
        #expect(events.contains { if case .result(let result) = $0 { return result.succeeded }; return false })
        #expect(!events.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func acpProbeReturnsGroupedModelsWithPerModelEffortsAndSkipsOtherProviders() async throws {
        let consent = IsolatedProviderConsent("gemini")
        defer { consent.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-acp-models-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-acp")
        try #"""
        #!/usr/bin/python3
        import json, sys

        if len(sys.argv) > 1 and sys.argv[1] == "acp":
            models = [
                {"value": "gemini-4-neon", "name": "Gemini 4 Neon"},
                {"value": "gemini-4-argon", "name": "Gemini 4 Argon"},
                {"value": "gemini-pro-orchestrator-neon", "name": "Orchestrator (Neon)"},
                {"value": "claude-opus-5-5", "name": "Claude Opus 5.5"},
            ]
            efforts = {
                "gemini-4-neon": ["low", "medium", "high", "xhigh"],
                "gemini-4-argon": ["low", "medium", "high"],
                "gemini-pro-orchestrator-neon": [],
            }
            def config_for(model_id):
                opts = [{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": model_id, "options": models}]
                levels = efforts.get(model_id, [])
                if levels:
                    opts.append({"id": "thought_level", "name": "Thinking Level", "category": "thought_level", "type": "select",
                                 "currentValue": levels[-1], "options": [{"value": l, "name": l.title()} for l in levels]})
                return opts
            for line in sys.stdin:
                msg = json.loads(line)
                mid, method = msg.get("id"), msg.get("method")
                if method == "initialize":
                    print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1}}), flush=True)
                elif method == "session/new":
                    print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "S1", "configOptions": config_for("gemini-4-neon")}}), flush=True)
                elif method == "session/set_config_option":
                    val = msg["params"]["value"]
                    print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": {"configOptions": config_for(val)}}), flush=True)
            sys.exit(0)
        if len(sys.argv) > 1 and sys.argv[1] == "-p":
            print('{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"weekly","remaining_fraction":0.8}]}]}}}')
            sys.exit(0)
        sys.exit(1)
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let permit = try #require(consent.consent.permit("gemini"))
        let account = GeminiAccount(binary: binary.path)
        await account.look(fresh: true, permit: permit,
                           find: { _ in Shell.Found(claude: nil, gemini: binary.path, env: ["HOME": root.path, "PATH": "/usr/bin:/bin"]) },
                           profile: root.appendingPathComponent("profile"))
        #expect(account.ready)
        #expect(account.models.map(\.model) == ["gemini-4-neon", "gemini-4-argon", "gemini-pro-orchestrator-neon"])
        #expect(account.models.map(\.name) == ["Gemini 4 Neon", "Gemini 4 Argon", "Orchestrator (Neon)"])
        #expect(account.models.map(\.efforts) == [["low", "medium", "high", "xhigh"], ["low", "medium", "high"], []])
    }

    @Test func perModelEffortsRoundTripThroughPersistenceAndPrepare() throws {
        let original = [
            GeminiModels.model("gemini-4-neon", name: "Gemini 4 Neon", efforts: ["low", "medium", "high", "xhigh"]),
            GeminiModels.model("gemini-pro-orchestrator-neon", name: "Orchestrator (Neon)", efforts: []),
        ]
        let decoded = GeminiModels.decode(GeminiModels.encode(original))
        #expect(decoded == original)
        let legacy = GeminiModels.decode([["gemini-3.8-flash-high", "Gemini 3.8 Flash (High)"]])
        #expect(legacy.first?.efforts == GeminiModels.efforts)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-xhigh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("login/Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var neon = GeminiRunnerTests.config(root: root, model: "gemini-4-neon",
                                            inherited: ["HOME": root.appendingPathComponent("login").path, "PATH": "/usr/bin:/bin"])
        neon.effort = "xhigh"
        neon.supportedEfforts = ["low", "medium", "high", "xhigh"]
        _ = try neon.prepare()

        var orchestrator = GeminiRunnerTests.config(root: root, model: "gemini-pro-orchestrator-neon")
        orchestrator.effort = "low"
        orchestrator.supportedEfforts = []
        #expect(throws: GeminiStream.Failure.self) { try orchestrator.prepare() }
    }

    @Test func legacyPinnedGeminiModelResolvesToBaseFamily() {
        let account = GeminiAccount.shared
        let previous = account.models
        defer { account.pretend(binary: account.binary, signedIn: account.signedIn, models: previous.map { "\($0.model) \($0.name)" }.joined(separator: "\n")) }
        account.pretend(binary: "/fixture/agy", signedIn: true, models: "gemini-4-neon Gemini 4 Neon\ngemini-3.8-flash Gemini 3.8 Flash")
        let found = AgentModels.find("gemini", "gemini-4-neon-high")
        #expect(found?.model == "gemini-4-neon")
        #expect(found?.name == "Gemini 4 Neon")
    }
}
