import Foundation
import Testing
@testable import Fast

@MainActor
struct OpenCodeTests {
    @Test func opencodeModelsAreIdsOneALine() {
        let text = """
        opencode/claude-sonnet-5-5
        opencode-go/glm-5.3-flash
        openrouter/~z-ai/glm-latest
        openrouter/anthropic/claude-sonnet-5-5

        not a model
        opencode/claude-sonnet-5-5
        """
        let models = OpenCodeRunner.parseModels(text)
        #expect(models.map(\.model) == ["opencode/claude-sonnet-5-5", "opencode-go/glm-5.3-flash",
                                        "openrouter/~z-ai/glm-latest", "openrouter/anthropic/claude-sonnet-5-5"])
        #expect(models.allSatisfy { $0.cli == "opencode" && $0.about.isEmpty && $0.efforts.isEmpty })
        #expect(models[0].name == "Claude Sonnet 5 5")
        #expect(models[1].name == "Glm 5.3 Flash")
        #expect(models[2].name == "Glm Latest")
    }

    @Test func opencodeModelsReadANSIColorsAndMarginsAway() {
        let models = OpenCodeRunner.parseModels("\u{1B}[1mopencode/glm-5.3-flash\u{1B}[0m  \n")
        #expect(models.map(\.model) == ["opencode/glm-5.3-flash"])
    }

    /// The provider part of an id, as a row reads it: which part of the
    /// plan the model comes from, apart from the plan's own name.
    @Test func opencodeModelIdsSayTheirProvider() {
        #expect(OpenCodeRunner.providerName("opencode-go/glm-5.3-flash") == "opencode-go")
        #expect(OpenCodeRunner.providerName("opencode/beam-free") == "opencode")
        #expect(OpenCodeRunner.providerName("openrouter/z-ai/glm-5.3-flash") == "openrouter/z-ai")
        #expect(OpenCodeRunner.providerName("openrouter/~z-ai/glm-latest") == "openrouter/z-ai")
        #expect(OpenCodeRunner.providerName("opencode") == "opencode")
    }

    @Test func opencodeRunsOnItsOwnPlanWords() {
        #expect(AgentPlan.opencode.cli == "opencode")
        #expect(AgentSetupModel.plan("opencode") == "OpenCode")
        #expect(AgentSetupModel.tool("opencode") == "OpenCode CLI")
        #expect(FieldAnswer.mark("opencode") == "brand.opencode")
        #expect(WelcomeConnect.needs("opencode").hasPrefix("OpenCode"))
        #expect(!AgentSetupModel.skilled("opencode"))
        #expect(AgentPlan.connectable.map(\.cli).contains("opencode"))
        #expect(AgentSetupModel.binary("opencode", in: Shell.Found(claude: nil, codex: nil, opencode: "/oc", env: [:])) == "/oc")
        #expect(ModelDefaults.Work.tasks.refusal("opencode") == nil)
        #expect(ModelDefaults.Work.drafts.refusal("opencode") == nil)
        #expect(ModelDefaults.Work.commands.refusal("opencode") == nil)
        #expect(OpenCodeRunner.unavailable(textOnly: false, unattended: false, fork: false) == nil)
        #expect(OpenCodeRunner.unavailable(textOnly: false, unattended: true, fork: false) == nil)
        #expect(OpenCodeRunner.unavailable(textOnly: false, unattended: false, fork: true) != nil)
    }

    @Test func opencodeKeepsOtherProvidersCredentialsOutOfItsEnvironment() {
        let env = OpenCodeRunner.environment(["HOME": "/test", "PATH": "/bin", "OPENCODE_API_KEY": "test-only",
            "CLAUDE_CODE_OAUTH_TOKEN": "test-only", "ANTHROPIC_API_KEY": "test-only", "CODEX_HOME": "/other",
            "OPENAI_API_KEY": "test-only", "CURSOR_AUTH_TOKEN": "test-only"])
        #expect(env == ["HOME": "/test", "PATH": "/bin"])
    }

    /// The no-tools helper a text-only run launches with: an agent with
    /// every tool turned off.
    @Test func theHelperConfigTurnsEveryToolOff() throws {
        let config = try JSONSerialization.jsonObject(with: Data(OpenCodeRunner.helperConfig.utf8)) as? [String: Any]
        let helper = (config?["agent"] as? [String: Any])?["helper"] as? [String: Any]
        #expect(helper?["mode"] as? String == "primary")
        #expect(helper?["build"] as? Bool == true)
        #expect((helper?["tools"] as? [String: Any])?["*"] as? Bool == false)
    }

    @Test func theBrowserOnlyConfigLimitsToolsToYabBrowser() throws {
        let config = try JSONSerialization.jsonObject(with: Data(OpenCodeRunner.browserOnlyConfig.utf8)) as? [String: Any]
        #expect(config?["default_agent"] as? String == "browser")
        let browser = (config?["agent"] as? [String: Any])?["browser"] as? [String: Any]
        #expect(browser?["mode"] as? String == "primary")
        let tools = browser?["tools"] as? [String: Any]
        #expect(tools?["*"] as? Bool == false)
        #expect(tools?["yab-browser_*"] as? Bool == true)
        #expect(tools?["yab_browser_*"] as? Bool == true)
    }

    @Test func opencodeSessionEnvironmentSetsConfigPerAccessModeAndStripsProviderKeys() {
        let base = [
            "HOME": "/test",
            "PATH": "/bin",
            "OPENCODE_API_KEY": "test-only",
            "OPENCODE_CONFIG_CONTENT": "{\"stale\":true}",
            "CLAUDE_CODE_OAUTH_TOKEN": "test-only",
            "ANTHROPIC_API_KEY": "test-only",
            "CODEX_HOME": "/other",
            "OPENAI_API_KEY": "test-only",
            "CURSOR_AUTH_TOKEN": "test-only",
        ]

        let textOnlyEnv = OpenCodeRunner.sessionEnvironment(base, textOnly: true, full: false)
        #expect(textOnlyEnv["HOME"] == "/test")
        #expect(textOnlyEnv["PATH"] == "/bin")
        #expect(textOnlyEnv["OPENCODE_API_KEY"] == nil)
        #expect(textOnlyEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(textOnlyEnv["ANTHROPIC_API_KEY"] == nil)
        #expect(textOnlyEnv["CODEX_HOME"] == nil)
        #expect(textOnlyEnv["OPENAI_API_KEY"] == nil)
        #expect(textOnlyEnv["CURSOR_AUTH_TOKEN"] == nil)
        #expect(textOnlyEnv["OPENCODE_CONFIG_CONTENT"] == OpenCodeRunner.helperConfig)

        let browserOnlyEnv = OpenCodeRunner.sessionEnvironment(base, textOnly: false, full: false)
        #expect(browserOnlyEnv["HOME"] == "/test")
        #expect(browserOnlyEnv["PATH"] == "/bin")
        #expect(browserOnlyEnv["OPENCODE_API_KEY"] == nil)
        #expect(browserOnlyEnv["OPENCODE_CONFIG_CONTENT"] == OpenCodeRunner.browserOnlyConfig)

        let fullEnv = OpenCodeRunner.sessionEnvironment(base, textOnly: false, full: true)
        #expect(fullEnv["HOME"] == "/test")
        #expect(fullEnv["PATH"] == "/bin")
        #expect(fullEnv["OPENCODE_API_KEY"] == nil)
        #expect(fullEnv["OPENCODE_CONFIG_CONTENT"] == nil)
    }

    @Test func opencodeStoredCredentialsIgnoreEmptyAndZeroCounts() {
        let table = """
        ┌ Credentials ~/.local/share/opencode/auth.json
        │ OpenCode  api     stored
        │ Anthropic oauth   stored
        └ 2 credentials stored
        """
        #expect(OpenCodeRunner.hasStoredCredentials(table))
        #expect(OpenCodeRunner.hasStoredCredentials("\u{1B}[32mOpenCode\u{1B}[0m  \u{1B}[2mstored\u{1B}[0m\n"))
        #expect(!OpenCodeRunner.hasStoredCredentials("No authenticated integrations"))
        #expect(!OpenCodeRunner.hasStoredCredentials("0 credentials stored"))
        #expect(!OpenCodeRunner.hasStoredCredentials("No credentials stored"))
        #expect(!OpenCodeRunner.hasStoredCredentials("└ 0 credentials stored"))
        #expect(!OpenCodeRunner.hasStoredCredentials("└ No credentials stored"))
        #expect(!OpenCodeRunner.hasStoredCredentials("No stored credentials"))
        #expect(!OpenCodeRunner.hasStoredCredentials(""))
    }

    /// OpenCode's ACP has no "ask" mode: a text-only run takes its
    /// no-tools helper through session/set_config_option first, then
    /// prompts, and its words carry OpenCode's own id and name.
    @Test @MainActor func opencodeACPHasNoAskModeRoundTrip() {
        @MainActor final class Wire {
            var lines: [[String: Any]] = []
            lazy var server = CursorServer(write: { [unowned self] data in
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { lines.append(object) }
            }, name: "OpenCode", askMode: nil)
            func reply(_ result: [String: Any]) -> [CursorServer.Heard] {
                server.heard(["jsonrpc": "2.0", "id": lines.last?["id"] ?? 0, "result": result])
            }
        }
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [], textOnly: true)
        wire.server.say("text only")
        _ = wire.reply(["protocolVersion": 1])
        #expect(wire.lines.last?["method"] as? String == "session/new")
        #expect(wire.reply(["sessionId": "ses_1"]).isEmpty)
        #expect(wire.lines.last?["method"] as? String == "session/set_config_option")
        let args = wire.lines.last?["params"] as? [String: Any]
        #expect(args?["configId"] as? String == "mode")
        #expect(args?["value"] as? String == CursorServer.helperMode)
        let events = wire.reply([:])
        guard case .ready("ses_1") = events.first else { Issue.record("no conversation"); return }
        #expect(wire.lines.last?["method"] as? String == "session/prompt")
        #expect(!wire.lines.contains { $0["method"] as? String == "session/set_mode" })
        let heard = wire.server.heard(["method": "session/update", "params": ["sessionId": "ses_1", "update": [
            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hi"]]]])
        guard case .delta(let id, "hi", false) = heard.first else { Issue.record("no answer"); return }
        #expect(id.hasPrefix("opencode."))
        let tool = wire.server.heard(["method": "session/update", "params": ["sessionId": "ses_1", "update": [
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run"]]])
        guard case .tool(let item) = tool.first else { Issue.record("no tool"); return }
        #expect(item.id.hasPrefix("opencode.tool."))
        #expect(item.name == "Run")
        // A tool OpenCode asks about is turned down, as a text run promises.
        let ask = wire.server.heard(["id": 7, "method": "session/request_permission", "params": [
            "sessionId": "ses_1", "toolCall": ["title": "Write a file"], "options": [
                ["optionId": "yes", "name": "Allow once", "kind": "allow_once"]]]])
        guard case .permission(let key, let title, _, _) = ask.first else { Issue.record("no permission"); return }
        #expect(title == "Write a file")
        wire.server.reply(key, option: nil)
        let outcome = (wire.lines.last?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "cancelled")
    }

    @Test @MainActor func cursorStillSpeaksWithItsOwnName() {
        @MainActor final class Wire {
            var lines: [[String: Any]] = []
            lazy var server = CursorServer { [unowned self] data in
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { lines.append(object) }
            }
            func reply(_ result: [String: Any]) -> [CursorServer.Heard] {
                server.heard(["jsonrpc": "2.0", "id": lines.last?["id"] ?? 0, "result": result])
            }
        }
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [], textOnly: true)
        _ = wire.reply(["protocolVersion": 1])
        _ = wire.reply(["sessionId": "C1"])
        #expect(wire.lines.contains { ($0["method"] as? String) == "session/set_mode" })
        _ = wire.reply([:])
        wire.server.say("say")
        let heard = wire.server.heard(["method": "session/update", "params": ["sessionId": "C1", "update": [
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run"]]])
        guard case .tool(let item) = heard.first else { Issue.record("no tool"); return }
        #expect(item.id.hasPrefix("cursor.tool."))
        #expect(item.name == "Run")
    }

    /// The quiet memory turn stays out of an OpenCode chat: its prompt is
    /// never put down as a user's, its words grow no answer, and only its
    /// end gets through to close the turn.
    @Test @MainActor func theQuietMemoryTurnStaysOutOfAnOpenCodeChat() throws {
        let fixture = IsolatedProviderConsent("opencode")
        defer { fixture.close() }
        @MainActor final class Wire {
            var lines: [[String: Any]] = []
            lazy var server = CursorServer(write: { [unowned self] data in
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { lines.append(object) }
            }, name: "OpenCode", askMode: nil)
            func reply(_ result: [String: Any]) -> [CursorServer.Heard] {
                server.heard(["jsonrpc": "2.0", "id": lines.last?["id"] ?? 0, "result": result])
            }
        }
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [])
        _ = wire.reply(["protocolVersion": 1])
        guard case .ready = wire.reply(["sessionId": "ses_1"]).first else { Issue.record("no conversation"); return }
        let agents = Agents()
        let session = Agents.Session(id: "quiet-" + UUID().uuidString.prefix(6), cli: "opencode", name: "OpenCode", prompt: "Fix it", state: .running)
        session.providerPermit = try #require(fixture.consent.permit("opencode"))
        session.cursor = wire.server
        session.quiet = true
        session.items = [ChatItem(id: "q1", kind: .asked, text: "Fix it", state: .done)]
        session.remembering = true

        // The extraction prompt is told to the CLI, but never shows as yours.
        agents.send(session, Agents.extractionPrompt(session))
        let promptId = wire.lines.last?["id"] ?? 0
        #expect(session.items.map(\.id) == ["q1"])
        #expect(wire.lines.last?["method"] as? String == "session/prompt")
        #expect(session.result.isEmpty)

        // Its reply says nothing in the chat either.
        agents.hear(["method": "session/update", "params": ["sessionId": "ses_1", "update": [
            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Kept a short episodic entry"]]]], on: session)
        #expect(session.items.map(\.id) == ["q1"])
        #expect(session.result.isEmpty)

        // The tool call of the quiet turn says nothing in the chat either.
        agents.hear(["method": "session/update", "params": ["sessionId": "ses_1", "update": [
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "remember"]]], on: session)
        #expect(session.items.map(\.id) == ["q1"])
        #expect(session.result.isEmpty)

        // A permission ask during the quiet turn is cancelled without an alert or chat item.
        agents.hear(["id": 9, "method": "session/request_permission", "params": [
            "sessionId": "ses_1", "toolCall": ["title": "Write a file"], "options": [
                ["optionId": "yes", "name": "Allow once", "kind": "allow_once"]]]], on: session)
        let outcome = (wire.lines.last?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "cancelled")
        #expect(session.cursorAlert == nil)
        #expect(session.items.map(\.id) == ["q1"])
        #expect(session.result.isEmpty)

        // Its end does get through: the stdin it closes is how the quiet
        // turn's process goes, and its exit ends the remembering.
        let pipe = Pipe()
        session.input = pipe.fileHandleForWriting
        let reader = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        agents.hear(["jsonrpc": "2.0", "id": promptId, "result": [:]], on: session)
        var byte: UInt8 = 0
        #expect(read(reader, &byte, 1) == 0)
    }

    @Test @MainActor func theQuietMemoryTurnFailureClosesInputWithoutFailingSession() throws {
        let fixture = IsolatedProviderConsent("opencode")
        defer { fixture.close() }
        @MainActor final class Wire {
            var lines: [[String: Any]] = []
            lazy var server = CursorServer(write: { [unowned self] data in
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { lines.append(object) }
            }, name: "OpenCode", askMode: nil)
            func reply(_ result: [String: Any]) -> [CursorServer.Heard] {
                server.heard(["jsonrpc": "2.0", "id": lines.last?["id"] ?? 0, "result": result])
            }
        }
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [])
        _ = wire.reply(["protocolVersion": 1])
        guard case .ready = wire.reply(["sessionId": "ses_1"]).first else { Issue.record("no conversation"); return }
        let agents = Agents()
        let session = Agents.Session(id: "quiet-fail-" + UUID().uuidString.prefix(6), cli: "opencode", name: "OpenCode", prompt: "Fix it", state: .done)
        session.providerPermit = try #require(fixture.consent.permit("opencode"))
        session.cursor = wire.server
        session.quiet = true
        session.items = [ChatItem(id: "q1", kind: .asked, text: "Fix it", state: .done)]
        session.remembering = true

        agents.send(session, Agents.extractionPrompt(session))
        let promptId = wire.lines.last?["id"] ?? 0
        session.result = "Original answer"
        let pipe = Pipe()
        session.input = pipe.fileHandleForWriting
        let reader = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)

        agents.hear(["jsonrpc": "2.0", "id": promptId, "error": ["code": -32001, "message": "memory extraction failed"]], on: session)
        var byte: UInt8 = 0
        #expect(read(reader, &byte, 1) == 0)
        #expect(session.input == nil)
        #expect(session.result == "Original answer")
        #expect(session.state == .done)
    }

    @Test @MainActor func opencodeDoesNotRetryModel() {
        let agents = Agents()
        let session = Agents.Session(id: "retry-" + UUID().uuidString.prefix(6), cli: "opencode", name: "OpenCode", prompt: "Hi", state: .running)
        session.model = "opencode/glm-5.3-flash"
        #expect(!agents.retryModel(session, "model_not_found"))
        #expect(session.model == "opencode/glm-5.3-flash")
        #expect(session.modelRetries == 0)
    }

    @Test func preferredFallsBackToOpenCodeWhenOnlyOpenCodeIsFound() {
        let found = Shell.Found(claude: nil, codex: nil, cursor: nil, gemini: nil, opencode: "/opt/homebrew/bin/opencode", env: [:])
        #expect(Agents.preferred(connected: [], found: found) == "opencode")
    }
}
