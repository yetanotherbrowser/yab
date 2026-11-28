import Foundation
import Testing
import SyncKit
@testable import Fast

@MainActor
struct GeminiRunnerTests {
    static func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    /// One of Yab's tools as the CLI names it.
    static let yabTool = "mcp_\(Mcp.name)_open"

    static func initialize(_ stream: inout GeminiStream, id: String = "G1", tools: [String] = []) throws -> [GeminiStream.Event] {
        stream.receive(try line(["event": "init", "conversation_id": id,
                                 "init": ["tools": tools, "permission_mode": "request-review", "model": "gemini-fixture"]]))
    }

    static func result(_ stream: inout GeminiStream, input: Int = 10, output: Int = 3,
                       status: String = "SUCCESS", id: String = "G1") throws -> GeminiStream.Result? {
        let events = stream.receive(try line(["event": "result", "result": ["conversation_id": id, "status": status,
            "response": "Answer", "usage": ["input_tokens": input, "output_tokens": output, "total_tokens": input + output]]]))
        guard case .result(let result) = events.first else { return nil }
        return result
    }

    @Test func fragmentedUTF8AndTwoTurnsUseCumulativeUsageOnce() throws {
        var stream = GeminiStream()
        let prompt = try stream.prompt("Привет")
        let sent = try JSONSerialization.jsonObject(with: prompt) as? [String: Any]
        #expect(sent?["event"] as? String == "user")
        #expect(sent?["type"] == nil) // Never Claude control or vision blocks.
        _ = try Self.initialize(&stream)
        let step = try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 2,
            "state": "ACTIVE", "step_type": "agent_response", "text_delta": "Привет"]])
        var events: [GeminiStream.Event] = []
        for byte in step { events += stream.receive(Data([byte])) }
        guard case .step(let item) = events.first else { Issue.record("No streamed text"); return }
        #expect(item.text == "Привет")
        _ = stream.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 2,
            "state": "DONE", "step_type": "agent_response", "text_delta": "!"]]))
        let first = try #require(try Self.result(&stream))
        #expect(first.succeeded && first.usage?.input == 10 && first.usage?.output == 3)
        _ = try stream.prompt("Remember the first answer")
        let second = try #require(try Self.result(&stream, input: 25, output: 8))
        #expect(second.succeeded && second.usage?.input == 15 && second.usage?.output == 5)
        #expect(stream.end(code: 0).isEmpty)
    }

    @Test func pendingTurnRejectsConcurrentInputAndVision() throws {
        var stream = GeminiStream()
        #expect(throws: GeminiStream.Failure.self) { try stream.prompt("look", attachments: 1) }
        #expect(!stream.active)
        _ = try stream.prompt("one")
        #expect(throws: GeminiStream.Failure.self) { try stream.prompt("two") }
    }

    @Test func resumeRequiresExactConversation() throws {
        var stream = GeminiStream(conversation: "G1")
        _ = try stream.prompt("resume")
        let events = try Self.initialize(&stream, id: "G2")
        guard case .failed = events.first else { Issue.record("Wrong conversation accepted"); return }
        #expect(stream.broken)
    }

    @Test func resumedUsageStartsUnknownInsteadOfCountingHistoryAgain() throws {
        var stream = GeminiStream(conversation: "G1")
        _ = try stream.prompt("resume"); _ = try Self.initialize(&stream)
        #expect(try Self.result(&stream, input: 100)?.usage == nil)
        _ = try stream.prompt("next")
        #expect(try Self.result(&stream, input: 115, output: 8)?.usage?.input == 15)
    }

    @Test func selectedModelMustBeAcknowledgedExactly() throws {
        var stream = GeminiStream(model: "gemini-selected")
        _ = try stream.prompt("hello")
        _ = try Self.initialize(&stream)
        #expect(stream.broken)
    }

    @Test func foreignStepAndResultFailClosed() throws {
        for result in [true, false] {
            var stream = GeminiStream()
            _ = try stream.prompt("one"); _ = try Self.initialize(&stream)
            if result { _ = try Self.result(&stream, id: "G2") }
            else {
                _ = stream.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G2",
                    "step_index": 0, "state": "DONE", "step_type": "agent_response"]]))
            }
            #expect(stream.broken)
        }
    }

    @Test func softDeniedToolCannotBecomeSuccess() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("read the page"); _ = try Self.initialize(&stream, tools: [Self.yabTool])
        _ = stream.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "DONE", "step_type": "tool", "tool_name": Self.yabTool, "tool_info": ["error": ["type": "permission_denied", "message": "Denied"]]]]))
        let result = try #require(try Self.result(&stream))
        #expect(!result.succeeded && result.error != nil)
        _ = try stream.prompt("next")
        #expect(try Self.result(&stream)?.succeeded == true)
    }

    @Test func splitStderrDenialIsStickyWhileStructuredMCPErrorIsRecoverable() throws {
        var denied = GeminiStream(yabTools: true)
        _ = try denied.prompt("do the task"); _ = try Self.initialize(&denied, tools: [Self.yabTool])
        denied.diagnostic("headless mode cannot ")
        denied.diagnostic("prompt for approval, auto-denied")
        #expect(try Self.result(&denied)?.succeeded == false)

        var recovered = GeminiStream(yabTools: true)
        _ = try recovered.prompt("do the task"); _ = try Self.initialize(&recovered, tools: [Self.yabTool])
        let events = recovered.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "DONE", "step_type": "tool", "tool_name": Self.yabTool, "tool_info": ["output": ["isError": true, "content": []]]]]))
        #expect(events.contains { if case .step(let item) = $0 { return item.state == .failed }; return false })
        #expect(try Self.result(&recovered)?.succeeded == true)
        #expect(recovered.end(code: 0).isEmpty)
    }

    @Test func interruptedStatusesNeverCountAsDone() throws {
        for status in ["CANCELED", "INTERRUPTED", "ERROR", "WAITING", "INVALID", "RUNNING", "future-status"] {
            var stream = GeminiStream()
            _ = try stream.prompt("one"); _ = try Self.initialize(&stream)
            #expect(try Self.result(&stream, status: status)?.succeeded == false)
        }
    }

    @Test func malformedAndTruncatedStreamsFail() throws {
        var malformed = GeminiStream()
        #expect(!malformed.receive(Data("oops\n".utf8)).isEmpty && malformed.broken)
        var truncated = GeminiStream()
        _ = try truncated.prompt("one"); _ = try Self.initialize(&truncated)
        _ = truncated.receive(Data("{\"event\":".utf8))
        #expect(!truncated.end(code: 0).isEmpty && truncated.broken)
        var noResult = GeminiStream()
        _ = try noResult.prompt("one"); _ = try Self.initialize(&noResult)
        #expect(!noResult.end(code: 0).isEmpty)
    }

    @Test func controlMessagesAndBypassInitAreRejected() throws {
        var stream = GeminiStream()
        _ = try stream.prompt("one")
        _ = stream.receive(try Self.line(["event": "control_request", "request": ["subtype": "can_use_tool"]]))
        #expect(stream.broken)
        var bypass = GeminiStream()
        _ = bypass.receive(try Self.line(["event": "init", "conversation_id": "G1",
            "init": ["tools": [], "permission_mode": "always-proceed"]]))
        #expect(bypass.broken)
    }

    @Test func backwardsUsageAndUnfinishedToolAreFailures() throws {
        var stream = GeminiStream()
        _ = try stream.prompt("one"); _ = try Self.initialize(&stream)
        _ = try Self.result(&stream)
        _ = try stream.prompt("two")
        _ = try Self.result(&stream, input: 2)
        #expect(stream.broken)
        var unfinished = GeminiStream(yabTools: true)
        _ = try unfinished.prompt("one"); _ = try Self.initialize(&unfinished, tools: [Self.yabTool])
        _ = unfinished.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "ACTIVE", "step_type": "tool", "tool_name": Self.yabTool]]))
        #expect(try Self.result(&unfinished)?.succeeded == false)
    }

    @Test func softDenialWithZeroExitIsNotSuccess() throws {
        // The CLI says SUCCESS and exits 0 after a denial it only wrote to
        // stderr: the turn still failed.
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("click Buy"); _ = try Self.initialize(&stream, tools: [Self.yabTool])
        stream.diagnostic("tool call soft-denied by policy")
        let result = try #require(try Self.result(&stream))
        #expect(result.status == "SUCCESS" && !result.succeeded)
        #expect(stream.end(code: 0).isEmpty) // A clean close, but the result above already failed.
    }

    @Test func textRunAcceptsRegistryButRefusesEveryToolExecution() throws {
        // A real 1.4.4 init lists 60 tools even though the selected agent
        // has none. Ordinary answers must survive that registry metadata.
        for tools in [["ask_custom_permission", "run_command"], ["view_file", "read_url_content"], [Self.yabTool], ["invoke_subagent"]] {
            var stream = GeminiStream()
            _ = try stream.prompt("hello")
            guard case .initialized = try Self.initialize(&stream, tools: tools).first else {
                Issue.record("Registry \(tools) rejected"); continue
            }
            #expect(try Self.result(&stream)?.succeeded == true)
        }
        for tool in ["ask_custom_permission", "run_command", "view_file", "invoke_subagent", Self.yabTool] {
            var stream = GeminiStream()
            _ = try stream.prompt("hello"); _ = try Self.initialize(&stream)
            let events = stream.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
                "state": "ACTIVE", "step_type": "tool", "tool_name": tool]]))
            guard case .failed = events.first else { Issue.record("Tool step \(tool) accepted"); continue }
            #expect(stream.broken)
            #expect(try Self.result(&stream) == nil) // A later SUCCESS cannot erase it.
        }
    }

    @Test func toolRunAcceptsOnlyYabsTools() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("open the page")
        guard case .initialized = try Self.initialize(&stream, tools: [Self.yabTool]).first else { Issue.record("Yab tool refused"); return }
        let events = stream.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "DONE", "step_type": "tool", "tool_name": "write_to_file"]]))
        guard case .failed = events.first else { Issue.record("Native tool step accepted"); return }
        #expect(GeminiSupport.isYabTool("mcp_\(Mcp.name)_click") && GeminiSupport.isYabTool("\(Mcp.name)/click"))
        #expect(GeminiSupport.isYabTool("mcp__yab_browser__click"))
        #expect(!GeminiSupport.isYabTool("run_command") && !GeminiSupport.isYabTool("mcp_other_click"))
        #expect(!GeminiSupport.isYabTool("mcp_\(Mcp.name)_") && !GeminiSupport.isYabTool(Mcp.name))
    }

    @Test func geminiIsExplicitAndNeverAnsweredByAnotherProvider() {
        #expect(GeminiSupport.launchRefusal("gemini") == nil) // a text run
        #expect(GeminiSupport.launchRefusal("gemini", textOnly: false) == nil) // a task, with Yab's tools
        #expect(GeminiSupport.launchRefusal("gemini", textOnly: false, remote: true) == nil)
        #expect(GeminiSupport.launchRefusal("gemini", textOnly: false, tools: false) == GeminiSupport.noTools)
        #expect(GeminiSupport.launchRefusal("gemini", textOnly: false, remote: true, tools: false) == GeminiSupport.fromPhone)
        #expect(GeminiSupport.launchRefusal("future-agent") != nil)
        #expect(GeminiSupport.launchRefusal("claude") == nil)
        #expect(GeminiSupport.launchRefusal("codex") == nil)
        // Offered at Connect, with no terminal skill; not signed in here, it
        // writes no helper's words, and no other plan takes over its chats.
        #expect(AgentSetupModel.clis.contains("gemini"))
        #expect(!AgentSetup.connected("gemini"))
        #expect(GeminiAccount.shared.ready || !PlanText.agents.contains("gemini"))
        #expect(AgentModels.find("gemini", "sonnet") == nil)
        #expect(AgentSetupModel.name("gemini") == "Gemini")
        #expect(AgentSetupModel.tool("gemini") == "Antigravity CLI")
        let session = Agents.Session(id: UUID().uuidString, cli: "gemini", name: "Gemini", prompt: "hello", state: .running)
        Agents.shared.hear(["type": "system", "session_id": "claude-thread"], on: session)
        #expect(session.thread == nil)
    }

    @Test func geminiIsOfferedAtConnectWithoutToolsOrHelpers() {
        #expect(AgentPlan.clis.contains("gemini"))
        let gemini = AgentPlan.gemini
        #expect(gemini.name == "Gemini" && gemini.group == "Gemini Plan" && gemini.mark == "brand.gemini")
        #expect(gemini.connects && !gemini.skilled && gemini.tools == GeminiSupport.toolsProven)
        #expect(AgentPlan.connectable.map(\.cli).contains("gemini"))
        #expect(AgentPlan.claude.connects && AgentPlan.claude.tools && AgentPlan.cursor.connects)
        var found = Shell.Found(claude: "/c", codex: "/x", env: [:])
        found.gemini = "/agy"
        #expect(AgentSetupModel.binary("gemini", in: found) == "/agy")
        // Every kind of work, as every plan.
        #expect(ModelDefaults.Work.tasks.refusal("gemini") == nil)
        #expect(ModelDefaults.Work.drafts.refusal("gemini") == nil)
        #expect(ModelDefaults.Work.commands.refusal("gemini") == nil)
        #expect(ModelDefaults.Work.tasks.refusal("claude") == nil)
    }

    /// #373: a sign-in that never lands ends by the clock, saying why and what to press.
    @Test func aSignInThatNeverLandsSaysWhyAndHowToRetry() {
        let words = GeminiAccount.gaveUp(.signingIn, said: "Error: Please sign in to view available models.", limit: 300)
        #expect(words.contains("wasn't signed in within 5 minutes") && words.contains("Please sign in") && words.contains("Press Sign In"))
        #expect(GeminiAccount.gaveUp(.signingIn, said: nil, limit: 8).contains("within 8 seconds"))
        #expect(GeminiAccount.gaveUp(.installing, said: nil, limit: 300).contains("Set Up again"))
        #expect(GeminiAccount.waitLimit <= 300)
    }

    @Test func iPhoneStartsGeminiAsAskedNeverAnotherPlan() {
        // An explicit Gemini request from the iPhone starts Gemini, strict:
        // never the default in its place.
        #expect(ChatAgent(rawValue: "gemini") == .gemini)
        var asked: (cli: String?, strict: Bool)?
        let words = SyncChats.Words(id: "s1", chat: nil, text: "hello", kind: "agent", project: nil, choice: nil, at: Date(), cli: "gemini")
        let (reason, made) = SyncChats.startAgent(words) { _, cli, strict in asked = (cli, strict); return "x" }
        #expect(reason == nil && made != nil && asked?.cli == "gemini" && asked?.strict == true)
        // One this Mac doesn't know is still refused, never started on the default.
        var started = false
        let unknown = SyncChats.Words(id: "s2", chat: nil, text: "hello", kind: "agent", project: nil, choice: nil, at: Date(), cli: "future-agent")
        #expect(SyncChats.startAgent(unknown) { _, _, _ in started = true; return "x" }.reason == ChatAgent.invalid && !started)
    }

    @Test func modelsBecomePickerRows() {
        let rows = GeminiModels.rows("gemini-3-pro   Gemini 3 Pro\ngemini-3-flash  Gemini 3 Flash\n")
        #expect(rows.map(\.id) == ["gemini:gemini-3-pro", "gemini:gemini-3-flash"])
        #expect(rows.allSatisfy { $0.cli == "gemini" && !$0.vision && $0.efforts == GeminiModels.efforts })
        #expect(GeminiSupport.title("gemini-3-pro-preview") == "Gemini 3 Pro Preview")
    }

    @Test func modelCatalogComesFromCLIAndExcludesOtherProviders() {
        let models = GeminiSupport.models("gemini-one-high   Gemini One (High)\nclaude-opus   Claude\ngemini-one-high duplicate\ngemini-two-medium  Gemini Two (Medium)\nnoise\n")
        #expect(models.map(\.id) == ["gemini-one-high", "gemini-two-medium"])
        #expect(models.map(\.name) == ["Gemini One (High)", "Gemini Two (Medium)"])
        let other = GeminiSupport.models("Available models:\n• Gemini 3 Pro (gemini-3-pro)\n  gemini-3-flash\nNo models? Sign in.\n")
        #expect(other.map(\.id) == ["gemini-3-pro", "gemini-3-flash"])
        #expect(other.map(\.name) == ["Gemini 3 Pro", "Gemini 3 Flash"])
    }

    static func config(root: URL, binary: String = "/not-launched", conversation: String? = nil,
                       model: String? = "gemini-fixture", inherited: [String: String]? = nil,
                       mcpArgs: [String]? = nil, workspace: String = "workspace") -> GeminiRunner.Configuration {
        GeminiRunner.Configuration(binary: binary, profile: root.appendingPathComponent("profile"),
            workspace: root.appendingPathComponent(workspace), model: model, conversation: conversation,
            command: "/yab", mcpArgs: mcpArgs, brief: "Answer in Yab.",
            environment: inherited ?? ["PATH": "/usr/bin:/bin", "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), "GEMINI_API_KEY": "fixture-do-not-use", "AGY_ADC_AUTH": "true",
                          "ANTIGRAVITY_GEMINI_DIR": "/foreign/config", "GOOGLE_GEMINI_BASE_URL": "https://invalid.example"])
    }

    /// Runs the profile's gate as the CLI's hook does: the call on stdin,
    /// its decision on stdout.
    static func gate(_ home: URL, _ call: [String: Any]) throws -> String? {
        let hooks = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".gemini/config/hooks.json"))) as? [String: Any])
        let before = try #require(((hooks["yab-gate"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first)
        #expect(before["matcher"] as? String == "*")
        let command = try #require((before["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        let child = Process(), output = Pipe(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", command]; child.standardOutput = output; child.standardInput = input
        try child.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["toolCall": call, "stepIdx": 3]))
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        let decision = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
        #expect(child.terminationStatus == 0)
        return decision?["decision"] as? String
    }

    @Test func settingsOmitRetiredUnsandboxedCategoryWithoutRelaxingNativeDenials() throws {
        // files() only serializes Data. No directory, profile, CLI or tool runs.
        let root = URL(fileURLWithPath: "/inert-gemini-938", isDirectory: true)
        let home = root.appendingPathComponent("profile/home")
        let text = Self.config(root: root)
        let task = Self.config(root: root, mcpArgs: ["mcp", "--socket", "/fixture", "--session", "S938", "--inner"])
        func settings(_ config: GeminiRunner.Configuration) throws -> Data {
            let files = try config.files(home: home)
            return try #require(files.first { $0.path == ".gemini/antigravity-cli/settings.json" }?.data)
        }
        let data = try settings(text)
        #expect(try settings(task) == data, "Text and tool runs must retain identical shared policy")
        let decoded = try JSONSerialization.jsonObject(with: data)
        let json = try #require(decoded as? [String: Any])
        let policy = try #require(json["permissions"] as? [String: Any])
        let deny = try #require(policy["deny"] as? [String])
        #expect(deny == ["read_file(*)", "write_file(*)", "command(*)", "read_url(*)", "execute_url(*)", "invoke_subagent(*)"])
        // The installed parser rejects the category, not just its wildcard.
        #expect(!deny.contains { $0.lowercased().hasPrefix("unsandboxed") })
        #expect(policy["allow"] as? [String] == ["mcp(\(Mcp.name)/*)"])
        #expect((policy["ask"] as? [String])?.isEmpty == true)
        #expect(GeminiSupport.isYabTool(GeminiSupport.dispatcher, arguments: ["ServerName": Mcp.name, "ToolName": "open"]))
        #expect(!GeminiSupport.isYabTool(GeminiSupport.dispatcher, arguments: ["ServerName": "other", "ToolName": "open"]))
        for native in ["run_command", "view_file", "write_to_file", "invoke_subagent"] {
            #expect(!GeminiSupport.isYabTool(native))
        }
    }

    @Test func settingsMigrationReplacesManagedListsAndPreservesUnknownKeys() throws {
        let before = Data("""
        {
          "theme": "dark",
          "custom": {"enabled": true, "values": [1, "keep", null]},
          "permissions": {
            "deny": ["command(git push)", "unsandboxed(*)", "command(*)", "unsandboxed", "unsandboxed(*)", "command(*)"],
            "allow": ["command(*)", "mcp(other/read)", "mcp(\(Mcp.name)/*)", "mcp(\(Mcp.name)/*)"],
            "ask": ["mcp(other/write)", "mcp(other/write)"],
            "custom": {"keep": true}
          }
        }
        """.utf8)
        let expected = Data("""
        {
          "theme": "dark",
          "custom": {"enabled": true, "values": [1, "keep", null]},
          "permissions": {
            "deny": ["read_file(*)", "write_file(*)", "command(*)", "read_url(*)", "execute_url(*)", "invoke_subagent(*)"],
            "allow": ["mcp(\(Mcp.name)/*)"],
            "ask": [],
            "custom": {"keep": true}
          }
        }
        """.utf8)
        let after = try GeminiRunner.Configuration.settings(before)
        let actual = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        let wanted = try #require(try JSONSerialization.jsonObject(with: expected) as? [String: Any])
        #expect(NSDictionary(dictionary: actual).isEqual(to: wanted))
        #expect(try GeminiRunner.Configuration.settings(after) == after)
        // An already configured file keeps its original whitespace and key order.
        #expect(try GeminiRunner.Configuration.settings(expected) == expected)
    }

    @Test(arguments: [#"{"theme":"dark"}"#, #"{"theme":"dark","permissions":{"custom":true}}"#])
    func settingsMigrationAddsMissingPolicyWithoutReplacingOtherSettings(_ contents: String) throws {
        let before = Data(contents.utf8)
        let after = try GeminiRunner.Configuration.settings(before)
        let object = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        let policy = try #require(object["permissions"] as? [String: Any])
        #expect(object["theme"] as? String == "dark")
        #expect(policy["custom"] as? Bool == (contents.contains("custom") ? true : nil))
        #expect(policy["deny"] as? [String] == GeminiRunner.Configuration.denied)
        #expect(policy["allow"] as? [String] == ["mcp(\(Mcp.name)/*)"])
        #expect(policy["ask"] as? [String] == [])
    }

    @Test(arguments: ["", "{", "[]", "null", #"{"theme":"dark","permissions":null}"#, #"{"permissions":[]}"#,
                      #"{"permissions":{"deny":[1]}}"#, #"{"permissions":{"allow":null}}"#,
                      #"{"permissions":{"ask":{}}}"#])
    func invalidSettingsRecoverToFreshPolicy(_ contents: String) throws {
        #expect(try GeminiRunner.Configuration.settings(Data(contents.utf8)) == GeminiRunner.Configuration.settings(nil))
    }

    @Test func signInAndTurnsResetSavedGrantsAndWriteOnlyWhenChanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let login = root.appendingPathComponent("login")
        let home = root.appendingPathComponent("profile/home")
        let file = home.appendingPathComponent(GeminiRunner.Configuration.settingsPath)
        let backup = file.appendingPathExtension("bak")
        let fm = FileManager.default
        try fm.createDirectory(at: login.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = Data(#"{"theme":"dark","permissions":{"deny":["unsandboxed(*)"],"ask":["mcp(other/write)"]}}"#.utf8)
        try before.write(to: file)
        let env = ["HOME": login.path, "PATH": "/usr/bin:/bin"]
        let signIn = Self.config(root: root, model: nil, inherited: env)
        _ = try signIn.prepare()
        let after = try Data(contentsOf: file)
        #expect(after == (try GeminiRunner.Configuration.settings(before)))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let text = Self.config(root: root, inherited: env)
        let task = Self.config(root: root, inherited: env,
            mcpArgs: ["mcp", "--socket", "/fixture", "--session", "S938", "--inner"], workspace: "task")
        for config in [signIn, text, task] { _ = try config.prepare() }
        #expect(try Data(contentsOf: file) == after)
        #expect(try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == date)
        for config in [signIn, text, task] {
            var saved = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
            var policy = try #require(saved["permissions"] as? [String: Any])
            policy["allow"] = ["command(*)", "mcp(other/*)"]
            policy["ask"] = ["read_file(*)"]
            saved["permissions"] = policy
            try JSONSerialization.data(withJSONObject: saved).write(to: file)
            _ = try config.prepare()
            #expect(try Data(contentsOf: file) == after)
        }
        #expect(!fm.fileExists(atPath: backup.path))
    }

    @Test(arguments: ["", "{", "[]", "null", #"{"theme":"dark","permissions":null}"#, #"{"permissions":[]}"#,
                      #"{"permissions":{"deny":[1]}}"#, #"{"permissions":{"allow":"keep this"},"theme":"dark"}"#,
                      #"{"permissions":{"ask":{}}}"#])
    func prepareBacksUpMalformedSettingsAndRecoversOnce(_ contents: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-settings-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let login = root.appendingPathComponent("login")
        let file = root.appendingPathComponent("profile/home").appendingPathComponent(GeminiRunner.Configuration.settingsPath)
        let backup = file.appendingPathExtension("bak")
        let fm = FileManager.default
        try fm.createDirectory(at: login.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data(contents.utf8)
        try malformed.write(to: file)
        let env = ["HOME": login.path, "PATH": "/usr/bin:/bin"]
        let signIn = Self.config(root: root, model: nil, inherited: env)
        _ = try signIn.prepare()
        let fresh = try GeminiRunner.Configuration.settings(nil)
        #expect(try Data(contentsOf: file) == fresh)
        #expect(try Data(contentsOf: backup) == malformed)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [file, backup] { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        let text = Self.config(root: root, inherited: env)
        let task = Self.config(root: root, inherited: env,
            mcpArgs: ["mcp", "--socket", "/fixture", "--session", "S938", "--inner"], workspace: "task")
        for config in [signIn, text, task] { _ = try config.prepare() }
        #expect(try Data(contentsOf: file) == fresh)
        #expect(try Data(contentsOf: backup) == malformed)
        for url in [file, backup] {
            #expect(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == date)
        }
    }

    @Test func malformedSettingsAreKeptWhenBackupIsASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-settings-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let login = root.appendingPathComponent("login")
        let file = root.appendingPathComponent("profile/home").appendingPathComponent(GeminiRunner.Configuration.settingsPath)
        let backup = file.appendingPathExtension("bak")
        let target = root.appendingPathComponent("keep")
        let fm = FileManager.default
        try fm.createDirectory(at: login.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("{".utf8), kept = Data("keep".utf8)
        try malformed.write(to: file)
        try kept.write(to: target)
        try fm.createSymbolicLink(at: backup, withDestinationURL: target)
        let config = Self.config(root: root, inherited: ["HOME": login.path, "PATH": "/usr/bin:/bin"])
        #expect(throws: GeminiStream.Failure.self) { try config.prepare() }
        #expect(try Data(contentsOf: file) == malformed)
        #expect(try Data(contentsOf: target) == kept)
    }

    @Test func privateProfileHasYabsAgentNoServersAndNoInheritedCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Self.config(root: root)
        let prepared = try config.prepare()
        let home = root.appendingPathComponent("profile/home").resolvingSymlinksInPath()
        #expect(prepared.env["HOME"] == home.path)
        #expect(prepared.env["GEMINI_API_KEY"] == nil && prepared.env["AGY_ADC_AUTH"] == nil)
        #expect(prepared.env["GOOGLE_GEMINI_BASE_URL"] == nil)
        #expect(prepared.env["ANTIGRAVITY_GEMINI_DIR"] == home.appendingPathComponent(".gemini").path)
        #expect(prepared.cwd.lastPathComponent == "workspace")
        let mcp = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".gemini/config/mcp_config.json"))) as? [String: Any])
        #expect((mcp["mcpServers"] as? [String: Any])?.isEmpty == true)
        let settings = try String(contentsOf: home.appendingPathComponent(".gemini/antigravity-cli/settings.json"), encoding: .utf8)
        #expect(settings.contains("command(*)") && settings.contains("invoke_subagent(*)") && settings.contains("read_url(*)"))
        // The gate: nothing but a call to Yab's own server goes on.
        #expect(try Self.gate(home, ["name": "run_command", "args": ["CommandLine": "touch /tmp/x"]]) == "deny")
        #expect(try Self.gate(home, ["name": "view_file", "args": ["AbsolutePath": "/etc/hosts"]]) == "deny")
        #expect(try Self.gate(home, ["name": "invoke_subagent", "args": [:]]) == "deny")
        #expect(try Self.gate(home, ["name": GeminiSupport.dispatcher, "args": ["ServerName": "other", "ToolName": "open"]]) == "deny")
        #expect(try Self.gate(home, ["name": GeminiSupport.dispatcher, "args": ["ToolName": "open"]]) == "deny")
        #expect(try Self.gate(home, ["name": "mcp_other_click", "args": [:]]) == "deny")
        #expect(try Self.gate(home, ["name": GeminiSupport.dispatcher, "args": ["ServerName": Mcp.name, "ToolName": "open"]]) == "allow")
        #expect(try Self.gate(home, ["name": "mcp_\(Mcp.name)_open", "args": [:]]) == "allow")
        let agent = try String(contentsOf: home.appendingPathComponent(".gemini/config/agents/yab.md"), encoding: .utf8)
        #expect(agent.contains("tools: []") && agent.contains("subagent: false") && agent.contains("commandExecutionPolicy: off"))
        #expect(agent.contains("Answer in Yab."))
        #expect(agent.contains("inheritMcp: false"))
        #expect(config.arguments.contains("--agent") && !config.arguments.contains("--dangerously-skip-permissions"))
        #expect(config.arguments[config.arguments.firstIndex(of: "--agent")! + 1] == GeminiSupport.agentName)
        #expect(!FileManager.default.fileExists(atPath: prepared.cwd.appendingPathComponent(".agents").path))
        let resumed = Self.config(root: root, conversation: "G1")
        #expect(resumed.arguments.suffix(2) == ["--conversation", "G1"])
        _ = try resumed.prepare()
        // A workspace that grew its own agent config is not carried on.
        try FileManager.default.createDirectory(at: prepared.cwd.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: prepared.cwd.appendingPathComponent(".agents/rules.md"))
        #expect(throws: GeminiStream.Failure.self) { try resumed.prepare() }
        // Yab's tools belong to a session.
        #expect(throws: GeminiStream.Failure.self) { try Self.config(root: root, mcpArgs: ["mcp"]).prepare() }
    }

    /// A task: this session's server and agent in its own workspace, the
    /// shared profile's files the same bytes as a chat's.
    @Test func aTaskGetsItsOwnServerAndAgentInItsOwnWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-tools-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("profile/home")
        let text = Self.config(root: root)
        _ = try text.prepare()
        let shared = [".gemini/antigravity-cli/settings.json", ".gemini/config/mcp_config.json", ".gemini/config/hooks.json", ".gemini/config/yab-gate.sh"]
        let before = try shared.map { try Data(contentsOf: home.appendingPathComponent($0)) }
        let textAgent = try Data(contentsOf: home.appendingPathComponent(".gemini/config/agents/yab.md"))
        let args = ["mcp", "--socket", "/s", "--session", "S1", "--inner"]
        let task = GeminiRunner.Configuration(binary: "/not-launched", profile: root.appendingPathComponent("profile"),
            workspace: root.appendingPathComponent("task"), model: "gemini-fixture", conversation: nil,
            command: "/yab", mcpArgs: args, brief: "Work in Yab's tabs.", environment: ["PATH": "/usr/bin"])
        let prepared = try task.prepare()
        #expect(task.arguments[task.arguments.firstIndex(of: "--agent")! + 1] == GeminiSupport.toolAgentName)
        // Two chats at once never undo each other's profile.
        #expect(try shared.map { try Data(contentsOf: home.appendingPathComponent($0)) } == before)
        #expect(try Data(contentsOf: home.appendingPathComponent(".gemini/config/agents/yab.md")) == textAgent)
        // Nothing of the session's in the shared profile.
        let profileMcp = try String(contentsOf: home.appendingPathComponent(".gemini/config/mcp_config.json"), encoding: .utf8)
        #expect(!profileMcp.contains("S1"))
        let servers = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: prepared.cwd.appendingPathComponent(".agents/mcp_config.json"))) as? [String: Any])?["mcpServers"] as? [String: Any])
        #expect(servers.count == 1)
        let yab = try #require(servers[Mcp.name] as? [String: Any])
        #expect(yab["command"] as? String == "/yab" && yab["args"] as? [String] == args)
        let agent = try String(contentsOf: prepared.cwd.appendingPathComponent(".agents/agents/\(GeminiSupport.toolAgentName).md"), encoding: .utf8)
        #expect(agent.contains("name: \(GeminiSupport.toolAgentName)") && agent.contains("tools: []"))
        #expect(agent.contains("inheritMcp: true") && !agent.contains("  - \(GeminiSupport.dispatcher)"))
        #expect(agent.contains("subagent: false") && agent.contains("commandExecutionPolicy: off") && agent.contains("Work in Yab's tabs."))
        // Carried on: the same files are fine, anything else is not.
        let resumed = GeminiRunner.Configuration(binary: "/not-launched", profile: root.appendingPathComponent("profile"),
            workspace: root.appendingPathComponent("task"), model: "gemini-fixture", conversation: "G1",
            command: "/yab", mcpArgs: args, brief: "Work in Yab's tabs.", environment: ["PATH": "/usr/bin"])
        _ = try resumed.prepare()
        try Data("{}".utf8).write(to: prepared.cwd.appendingPathComponent(".agents/hooks.json"))
        #expect(throws: GeminiStream.Failure.self) { try resumed.prepare() }
    }

    /// Antigravity calls MCP tools through its dispatcher: Yab's are shown
    /// by their own names; one to another server stops the turn.
    @Test func dispatcherCallsToYabAreStepsAndToOthersStopTheTurn() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("open the page")
        _ = try Self.initialize(&stream, tools: ["run_command", GeminiSupport.dispatcher, "view_file"])
        let events = stream.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "ACTIVE", "step_type": "tool", "tool_name": GeminiSupport.dispatcher,
            "tool_info": ["parameters": ["ServerName": Mcp.name, "ToolName": "open", "Arguments": "{\"url\":\"https://example.com\"}"]]]]))
        guard case .step(let item) = events.first else { Issue.record("Yab's call refused: \(events)"); return }
        #expect(item.name == "open" && item.detail.contains("example.com") && item.state == .running)
        // Its later update may leave the arguments out.
        let done = stream.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "DONE", "step_type": "tool", "tool_name": GeminiSupport.dispatcher, "tool_info": ["output": "Opened"]]]))
        guard case .step(let finished) = done.first else { Issue.record("Done update refused"); return }
        #expect(finished.name == "open" && finished.state == .done)
        #expect(try Self.result(&stream)?.succeeded == true)
        var other = GeminiStream(yabTools: true)
        _ = try other.prompt("open the page"); _ = try Self.initialize(&other)
        let stray = other.receive(try Self.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "ACTIVE", "step_type": "tool", "tool_name": GeminiSupport.dispatcher,
            "tool_info": ["parameters": ["ServerName": "filesystem", "ToolName": "read"]]]]))
        guard case .failed = stray.first else { Issue.record("Another server's call accepted"); return }
        #expect(GeminiSupport.shownName("mcp_\(Mcp.name)_click", arguments: nil) == "click")
    }

    static func until(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test func processTransportTwoTurnsResumeAndStopChildWhileToolWaits() async throws {
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("gemini"))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-transport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let binary = temp.appendingPathComponent("fixture")
        try #"""
        #!/usr/bin/python3
        import json, os, subprocess, sys
        from pathlib import Path
        args = sys.argv[1:]
        conversation = args[args.index('--conversation') + 1] if '--conversation' in args else 'G1'
        def emit(event):
            print(json.dumps(event), flush=True)
        assert args[args.index('--agent') + 1] == 'yab'
        emit({'event':'init','conversation_id':conversation,'init':{'tools':[],'permission_mode':'request-review','model':args[args.index('--model') + 1]}})
        turns = 0
        for line in sys.stdin:
            event = json.loads(line)
            assert event['event'] == 'user'
            assert isinstance(event['message']['content'], str)
            text = event['message']['content']
            turns += 1
            if text == 'hold':
                emit({'event':'step_update','step_update':{'conversation_id':conversation,'step_index':turns,'step_type':'agent_response','state':'ACTIVE','text_delta':'thinking'}})
                child = subprocess.Popen(['/bin/sleep', '60'])
                Path('child.pid').write_text(str(child.pid))
                child.wait()
                continue
            remembered = Path('remembered')
            answer = remembered.read_text() if text == 'remember' else text
            if text != 'remember':
                remembered.write_text(text)
            emit({'event':'result','result':{'conversation_id':conversation,'status':'SUCCESS','response':answer,'usage':{'input_tokens':turns * 10, 'output_tokens':turns, 'total_tokens':turns * 11}}})
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let root = temp
        var events: [GeminiStream.Event] = []
        var results: [GeminiStream.Result] { events.compactMap { if case .result(let result) = $0 { return result }; return nil } }
        let runner = GeminiRunner { events.append($0) }
        defer { runner.stop() }
        try runner.start(Self.config(root: root, binary: binary.path), permit: permit)
        try runner.send("apple")
        try await Self.until { results.count == 1 }
        try runner.send("remember")
        try await Self.until { results.count == 2 }
        #expect(results.map(\.response) == ["apple", "apple"])
        #expect(results.map { $0.usage?.input } == [10, 10])
        runner.close()
        try await Self.until { !runner.running }
        let resumed = GeminiRunner(conversation: "G1") { events.append($0) }
        defer { resumed.stop() }
        try resumed.start(Self.config(root: root, binary: binary.path, conversation: "G1"), permit: permit)
        try resumed.send("remember")
        try await Self.until { results.count == 3 }
        #expect(results.last?.response == "apple")
        try resumed.send("hold")
        let pidFile = root.appendingPathComponent("workspace/child.pid")
        try await Self.until { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        resumed.stop()
        try await Self.until { kill(pid, 0) != 0 }
        #expect(!resumed.running)
        #expect(results.count == 3) // Stop cannot deliver a late Done.
        #expect(!events.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func aRevokedPermitCannotPrepareOrStartTheTransport() throws {
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("gemini"))
        fixture.consent.revoke("gemini")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-denied-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [GeminiStream.Event] = []
        let runner = GeminiRunner { events.append($0) }
        defer { runner.stop() }
        #expect(throws: GeminiStream.Failure.self) {
            try runner.start(Self.config(root: root, binary: "/fixture/must-not-run"), permit: permit)
        }
        #expect(!runner.running && events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

extension GeminiRunnerTests {
    /// The isolation probe's real transcripts (scripts/gemini/isolation_probe.py),
    /// when a run hands them in: each `NAME.ndjson` with its stderr, read by
    /// Yab's stream for a text run, must end as `NAME.expect` says. A
    /// denial the CLI reported as SUCCESS with exit 0 must still fail.
    @Test func recordedTranscriptsEndAsExpected() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/GeminiRegistry")
        let folder = ProcessInfo.processInfo.environment["YAB_GEMINI_TRANSCRIPTS"] ?? fixtures.path
        let dir = URL(fileURLWithPath: folder)
        for expect in try FileManager.default.contentsOfDirectory(atPath: folder) where expect.hasSuffix(".expect") {
            let name = String(expect.dropLast(".expect".count))
            let wanted = try String(contentsOf: dir.appendingPathComponent(expect), encoding: .utf8)
            var stream = GeminiStream()
            _ = try stream.prompt("probe")
            stream.diagnostic((try? String(contentsOf: dir.appendingPathComponent(name + ".stderr"), encoding: .utf8)) ?? "")
            let events = stream.receive(try Data(contentsOf: dir.appendingPathComponent(name + ".ndjson"))) + stream.end(code: 0)
            let succeeded = events.contains { if case .result(let result) = $0 { return result.succeeded }; return false }
                && !events.contains { if case .failed = $0 { return true }; return false }
            #expect(succeeded == (wanted == "success"), "\(name): \(events)")
        }
    }
}
