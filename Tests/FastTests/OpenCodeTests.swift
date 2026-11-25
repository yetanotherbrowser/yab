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
        #expect(item.name == "OpenCode tool")
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
        #expect(item.name == "Cursor tool")
    }
}
