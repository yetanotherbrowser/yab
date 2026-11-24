import Foundation
import Testing
@testable import Fast

@MainActor
struct CursorServerTests {
    @MainActor final class Wire {
        var lines: [[String: Any]] = []
        lazy var server = CursorServer { [unowned self] data in
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { lines.append(object) }
        }
        func reply(_ result: [String: Any]) -> [CursorServer.Heard] {
            server.heard(["jsonrpc": "2.0", "id": lines.last?["id"] ?? 0, "result": result])
        }
        func ready(thread: String? = nil) {
            server.open(thread: thread, cwd: "/test", mcp: [["name": "yab", "command": "/yab", "args": ["mcp"], "env": []]])
            _ = reply(["protocolVersion": 1, "agentCapabilities": ["loadSession": true]])
            _ = reply(["sessionId": "C1"])
        }
        func update(_ values: [String: Any], thread: String = "C1") -> [CursorServer.Heard] {
            server.heard(["method": "session/update", "params": ["sessionId": thread, "update": values]])
        }
    }

    @Test func initializeThenSessionThenPrompt() {
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [["name": "yab", "command": "/yab", "args": ["mcp"], "env": []]])
        wire.server.say("hello")
        #expect(wire.lines.count == 1)
        #expect(wire.lines[0]["method"] as? String == "initialize")
        let capability = (wire.lines[0]["params"] as? [String: Any])?["clientCapabilities"] as? [String: Any]
        #expect(capability?["terminal"] as? Bool == false)
        _ = wire.reply(["protocolVersion": 1])
        #expect(wire.lines.last?["method"] as? String == "session/new")
        let args = wire.lines.last?["params"] as? [String: Any]
        #expect((args?["mcpServers"] as? [[String: Any]])?.first?["command"] as? String == "/yab")
        let events = wire.reply(["sessionId": "C1"])
        guard case .ready("C1") = events.first else { Issue.record("no conversation"); return }
        #expect(wire.lines.last?["method"] as? String == "session/prompt")
        let prompt = (wire.lines.last?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        #expect(prompt?.first?["text"] as? String == "hello")
    }

    @Test func textCommandsWaitForTheReadOnlyModeBeforePrompting() {
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [], textOnly: true)
        wire.server.say("text only")
        _ = wire.reply(["protocolVersion": 1])
        #expect(wire.reply(["sessionId": "C1"]).isEmpty)
        #expect(wire.lines.last?["method"] as? String == "session/set_mode")
        #expect((wire.lines.last?["params"] as? [String: Any])?["modeId"] as? String == "ask")
        _ = wire.reply([:])
        #expect(wire.lines.last?["method"] as? String == "session/prompt")
    }

    @Test func resumeDoesNotReplayOldMessagesOrStartANewChat() {
        let wire = Wire()
        wire.server.open(thread: "C1", cwd: "/test", mcp: [])
        wire.server.say("continue")
        _ = wire.reply(["protocolVersion": 1, "agentCapabilities": ["loadSession": true]])
        #expect(wire.lines.last?["method"] as? String == "session/load")
        #expect(wire.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "old"]]).isEmpty)
        _ = wire.reply([:])
        #expect(wire.server.thread == "C1")
        #expect(!wire.lines.contains { $0["method"] as? String == "session/new" })
        let heard = wire.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "new"]])
        guard case .delta(_, "new", false) = heard.first else { Issue.record("no new text"); return }
        #expect(wire.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "other"]], thread: "other").isEmpty)
    }

    @Test func theModelAskedForGoesThroughSetConfigOption() {
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [], model: "opencode-go/glm-5.3-flash")
        wire.server.say("hello")
        _ = wire.reply(["protocolVersion": 1])
        _ = wire.reply(["sessionId": "C1"])
        #expect(wire.lines.last?["method"] as? String == "session/set_config_option")
        var args = wire.lines.last?["params"] as? [String: Any]
        #expect(args?["sessionId"] as? String == "C1")
        #expect(args?["configId"] as? String == "model")
        #expect(args?["value"] as? String == "opencode-go/glm-5.3-flash")
        let events = wire.reply([:])
        guard case .ready("C1") = events.first else { Issue.record("no conversation"); return }
        #expect(wire.lines.last?["method"] as? String == "session/prompt")
        let prompt = (wire.lines.last?["params"] as? [String: Any])?["prompt"] as? [[String: Any]]
        #expect(prompt?.first?["text"] as? String == "hello")
    }

    @Test func aServerWithNoModelSendsNoConfigOption() {
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [])
        _ = wire.reply(["protocolVersion": 1])
        let events = wire.reply(["sessionId": "C1"])
        guard case .ready("C1") = events.first else { Issue.record("no conversation"); return }
        #expect(!wire.lines.contains { $0["method"] as? String == "session/set_config_option" })
    }

    @Test func aTextOnlyRunTakesTheNoToolsHelperThenTheModel() {
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [], textOnly: true, model: "opencode-go/glm-5.3-flash")
        wire.server.say("text only")
        _ = wire.reply(["protocolVersion": 1])
        _ = wire.reply(["sessionId": "C1"])
        #expect(wire.lines.last?["method"] as? String == "session/set_config_option")
        var args = wire.lines.last?["params"] as? [String: Any]
        #expect(args?["configId"] as? String == "mode")
        #expect(args?["value"] as? String == CursorServer.helperMode)
        _ = wire.reply([:])
        #expect(wire.lines.last?["method"] as? String == "session/set_config_option")
        args = wire.lines.last?["params"] as? [String: Any]
        #expect(args?["configId"] as? String == "model")
        #expect(args?["value"] as? String == "opencode-go/glm-5.3-flash")
        _ = wire.reply([:])
        #expect(wire.lines.last?["method"] as? String == "session/prompt")
    }

    @Test func permissionsRequireAnExactOnceOnlyChoice() {
        let wire = Wire()
        wire.ready()
        wire.server.say("read")
        let events = wire.server.heard(["id": "p1", "method": "session/request_permission", "params": [
            "sessionId": "C1", "toolCall": ["title": "Read a file"], "options": [
                ["optionId": "yes", "name": "Allow once", "kind": "allow_once"],
                ["optionId": "forever", "name": "Always", "kind": "allow_always"],
                ["optionId": "no", "name": "Reject", "kind": "reject_once"]]]])
        guard case .permission(let key, _, _, let options) = events.first else { Issue.record("permission missing"); return }
        #expect(options.map(\.id) == ["yes", "no"])
        #expect(wire.lines.last?["method"] as? String == "session/prompt")
        wire.server.reply(key, option: "forever")
        let outcome = (wire.lines.last?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "cancelled")
        let count = wire.lines.count
        wire.server.reply(key, option: "yes")
        #expect(wire.lines.count == count)
    }

    @Test func noFilesystemOrTerminalClientCapabilities() {
        let wire = Wire()
        wire.ready()
        let result = wire.server.heard(["id": 99, "method": "fs/read_text_file", "params": ["sessionId": "C1", "path": "/private"]])
        #expect(result.isEmpty)
        #expect((wire.lines.last?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(wire.lines.last?["result"] == nil)
    }

    @Test func completionCancelsOutstandingPermissionAndCancelIsANotification() {
        let wire = Wire()
        wire.ready()
        wire.server.say("hello")
        let promptID = wire.lines.last?["id"] as? Int ?? 0
        _ = wire.server.heard(["id": 94, "method": "session/request_permission", "params": ["sessionId": "C1", "toolCall": [:], "options": [["optionId": "yes", "name": "Yes", "kind": "allow_once"]]]])
        wire.server.cancel()
        #expect(wire.lines.last?["method"] as? String == "session/cancel")
        #expect(wire.lines.last?["id"] == nil)
        let events = wire.server.heard(["id": promptID, "result": ["stopReason": "cancelled"]])
        guard case .ended = events.first else { Issue.record("turn did not end"); return }
        #expect(wire.lines.last?["id"] as? Int == 94)
        let outcome = (wire.lines.last?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "cancelled")
    }

    @Test func authFailureDoesNotStartLoginOrRetryAnotherAgent() {
        let wire = Wire()
        wire.server.open(thread: nil, cwd: "/test", mcp: [])
        _ = wire.reply(["protocolVersion": 1])
        let count = wire.lines.count
        let heard = wire.server.heard(["id": wire.lines.last?["id"] ?? 0, "error": ["code": -32000, "message": "Authentication required"]])
        guard case .failed(let message) = heard.first else { Issue.record("failure missing"); return }
        #expect(message.contains("Settings › AI › Models"))
        #expect(wire.lines.count == count)
        #expect(!wire.lines.contains { $0["method"] as? String == "authenticate" })
        #expect(CursorRunner.unavailable(textOnly: true, unattended: false, fork: false) == nil)
        #expect(CursorRunner.unavailable(textOnly: false, unattended: true, fork: false) == nil)
        #expect(CursorRunner.unavailable(textOnly: false, unattended: false, fork: true) != nil)
        #expect(CursorRunner.unavailable(textOnly: false, unattended: false, fork: false) == nil)
        #expect(AgentSetupModel.plan("cursor") == "Cursor")
        #expect(AgentModels.find("cursor", nil)?.cli == "cursor")
        #expect(AgentSetupModel.binary("cursor", in: Shell.Found(claude: "/claude", codex: "/codex", cursor: "/cursor", env: [:])) == "/cursor")
    }

    @Test func sessionUsesCursorStreamAndDeclinesUnattendedPermissions() {
        let wire = Wire()
        wire.ready()
        wire.server.say("read")
        let session = Agents.Session(id: "cursor-test-" + UUID().uuidString, cli: "cursor", name: "Cursor", prompt: "read", state: .running)
        session.quiet = true
        session.cursor = wire.server
        Agents.shared.hear(["method": "session/update", "params": ["sessionId": "C1", "update": [
            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Cursor answer"]]]], on: session)
        #expect(session.result == "Cursor answer")
        #expect(session.items.last?.text == "Cursor answer")
        Agents.shared.hear(["id": 71, "method": "session/request_permission", "params": ["sessionId": "C1", "toolCall": ["title": "Run a command"], "options": [["optionId": "once", "name": "Allow once", "kind": "allow_once"]]]], on: session)
        let outcome = (wire.lines.last?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "cancelled")
        #expect(session.cursorAlert == nil)
    }

    @Test func cursorDoesNotReceiveOtherProvidersCredentialsOrEndpointOverrides() {
        let env = CursorRunner.environment(["HOME": "/test", "PATH": "/bin", "CURSOR_API_KEY": "test-only",
            "CURSOR_AUTH_TOKEN": "test-only", "CURSOR_BASE_URL": "https://wrong.invalid", "CLAUDE_CODE_OAUTH_TOKEN": "test-only",
            "ANTHROPIC_API_KEY": "test-only", "CODEX_HOME": "/other", "OPENAI_API_KEY": "test-only"])
        #expect(env == ["HOME": "/test", "PATH": "/bin"])
    }

    @Test func projectToolsAreExactAndAnEditedConfigIsNeverOverwritten() throws {
        let room = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-tools-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: room) }
        try CursorRunner.prepareTools(in: room, command: "/yab", args: ["mcp", "--session", "C1"])
        let file = room.appendingPathComponent(".cursor/mcp.json")
        let data = try Data(contentsOf: file)
        try CursorRunner.prepareTools(in: room, command: "/yab", args: ["mcp", "--session", "C1"])
        let same = try Data(contentsOf: file)
        #expect(data == same)
        let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = config?["mcpServers"] as? [String: Any]
        #expect(servers?.count == 1)
        #expect((servers?[Mcp.name] as? [String: Any])?["command"] as? String == "/yab")
        let edited = Data("{\"mcpServers\":{\"other\":{\"command\":\"keep\"}}}".utf8)
        try edited.write(to: file)
        #expect(throws: (any Error).self) { try CursorRunner.prepareTools(in: room, command: "/yab", args: ["mcp"]) }
        let kept = try Data(contentsOf: file)
        #expect(kept == edited)
        #expect(Agents.workingFolder(cli: "cursor", id: "test", full: true, folder: NSHomeDirectory()) != URL(fileURLWithPath: NSHomeDirectory()))
    }

    @Test func aResumedProcessDoesNotAppendToThePreviousAnswer() {
        let first = Wire()
        first.ready()
        first.server.say("first")
        let old = first.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "First answer"]])
        guard case .delta(let oldID, _, _) = old.first else { Issue.record("first answer missing"); return }
        let resumed = Wire()
        resumed.ready(thread: "C1")
        resumed.server.say("second")
        let next = resumed.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Second answer"]])
        guard case .delta(let newID, _, _) = next.first else { Issue.record("resumed answer missing"); return }
        #expect(oldID != newID)
        let session = Agents.Session(id: "cursor-resume-test", cli: "cursor", name: "Cursor", prompt: "", state: .running)
        session.quiet = true
        session.items = [ChatItem(id: oldID, kind: .message, text: "First answer", state: .done)]
        session.cursor = resumed.server
        Agents.shared.hear(["method": "session/update", "params": ["sessionId": "C1", "update": [
            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Second answer"]]]], on: session)
        #expect(session.items.filter { $0.kind == .message }.map(\.text) == ["First answer", "Second answer"])
    }
}
