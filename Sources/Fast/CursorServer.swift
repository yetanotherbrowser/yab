import Foundation

/// An agent's Agent Client Protocol, JSON-RPC over newline-delimited stdio.
/// Cursor first; OpenCode's `opencode acp` speaks the same protocol. No
/// login, force flag or permission policy is changed by this client.
@MainActor
final class CursorServer {
    /// The provider's name, in every word people read.
    private let name: String
    /// The read-only mode a text-only run is set to before its prompt, or
    /// nil when the provider has no mode worth setting (OpenCode has no
    /// "ask"; its session/new answer is taken as it comes).
    private let askMode: String?
    enum Heard {
        case ready(String)
        case delta(item: String, words: String, thinking: Bool)
        case tool(ChatItem)
        case permission(id: String, title: String, detail: String, options: [Option])
        case ended
        case failed(String)
    }

    struct Option: Equatable {
        let id: String
        let title: String
    }

    private enum Pending { case initialize, session, mode, prompt }
    private let write: (Data) -> Void
    private var next = 0
    private var pending: [Int: Pending] = [:]
    private var opening: (thread: String?, cwd: String, mcp: [[String: Any]])?
    private var waiting: [String] = []
    private var requests: [String: Any] = [:]
    private var permissions: [String: [Option]] = [:]
    private var loading = false
    private var busy = false
    private let streamID = UUID().uuidString
    private var turn = 0
    private var textOnly = false
    private(set) var thread: String?

    init(write: @escaping (Data) -> Void, name: String = "Cursor", askMode: String? = "ask") {
        self.write = write
        self.name = name
        self.askMode = askMode
    }

    func open(thread: String?, cwd: String, mcp: [[String: Any]], textOnly: Bool = false) {
        self.textOnly = textOnly
        opening = (thread, cwd, mcp)
        request("initialize", ["protocolVersion": 1,
            "clientInfo": ["name": "yab", "version": "1"],
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]], .initialize)
    }

    /// ACP has one prompt at a time. The caller queues messages mid-turn.
    func say(_ text: String) {
        guard thread != nil, !busy, !loading else { waiting.append(text); return }
        prompt(text)
    }

    func cancel() {
        guard let thread else { return }
        send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": thread]])
    }

    /// Only a choice presented by this exact request can be returned.
    /// Persistent permissions are intentionally never offered.
    func reply(_ key: String, option: String?) {
        guard let id = requests.removeValue(forKey: key),
              let offered = permissions.removeValue(forKey: key) else { return }
        let outcome: [String: Any]
        if let option, offered.contains(where: { $0.id == option }) {
            outcome = ["outcome": "selected", "optionId": option]
        } else { outcome = ["outcome": "cancelled"] }
        send(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
    }

    func heard(_ message: [String: Any]) -> [Heard] {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                guard method == "session/request_permission", let thread,
                      params["sessionId"] as? String == thread, busy, !loading else {
                    send(["jsonrpc": "2.0", "id": id,
                          "error": ["code": -32601, "message": "Yab does not provide this client capability."]])
                    return []
                }
                let options = (params["options"] as? [[String: Any]] ?? []).compactMap { raw -> Option? in
                    guard ["allow_once", "reject_once"].contains(raw["kind"] as? String ?? ""),
                          let id = raw["optionId"] as? String, let name = raw["name"] as? String else { return nil }
                    return Option(id: id, title: name)
                }
                let key = UUID().uuidString
                requests[key] = id
                permissions[key] = options
                guard !options.isEmpty else { reply(key, option: nil); return [] }
                let tool = params["toolCall"] as? [String: Any] ?? [:]
                var detail = Self.text(tool["content"])
                if let input = tool["rawInput"], JSONSerialization.isValidJSONObject(input),
                   let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]) {
                    detail += (detail.isEmpty ? "" : "\n\n") + String(decoding: data, as: UTF8.self)
                }
                return [.permission(id: key, title: tool["title"] as? String ?? "\(name) asks for permission",
                                    detail: detail, options: options)]
            }
            guard method == "session/update", !loading, params["sessionId"] as? String == thread,
                  busy, let update = params["update"] as? [String: Any] else { return [] }
            switch update["sessionUpdate"] as? String {
            case "agent_message_chunk", "agent_thought_chunk":
                guard let content = update["content"] as? [String: Any], content["type"] as? String == "text",
                      let text = content["text"] as? String else { return [] }
                let thinking = update["sessionUpdate"] as? String == "agent_thought_chunk"
                return [.delta(item: "\(name.lowercased()).\(streamID).\(turn).\(thinking ? "thinking" : "answer")", words: text, thinking: thinking)]
            case "tool_call", "tool_call_update":
                guard let id = update["toolCallId"] as? String else { return [] }
                let status = update["status"] as? String ?? "in_progress"
                return [.tool(ChatItem(id: "\(name.lowercased()).tool.\(streamID)." + id, kind: .tool,
                    name: update["title"] as? String ?? "\(name) tool", text: Self.text(update["content"]),
                    state: status == "failed" ? .failed : status == "completed" ? .done : .running))]
            default: return []
            }
        }
        guard let id = message["id"] as? Int, let what = pending.removeValue(forKey: id) else { return [] }
        if let error = message["error"] as? [String: Any] {
            busy = false
            let words = error["message"] as? String ?? "\(name) turned the request down."
            if error["code"] as? Int == -32000 {
                return [.failed("\(name) needs you to sign in again. Sign in from Settings › AI › Models, then try again.")]
            }
            return [.failed(words)]
        }
        guard let result = message["result"] as? [String: Any] else {
            return [.failed("Cursor answered in a way Yab can't read. Try again.")]
        }
        switch what {
        case .initialize:
            guard result["protocolVersion"] as? Int == 1, let opening else {
                return [.failed("This \(name) is too old for Yab. Update it, then try again.")]
            }
            var params: [String: Any] = ["cwd": opening.cwd, "mcpServers": opening.mcp]
            loading = opening.thread != nil
            if let thread = opening.thread {
                guard (result["agentCapabilities"] as? [String: Any])?["loadSession"] as? Bool == true else {
                    return [.failed("\(name) can't pick this chat up again. Start a new chat.")]
                }
                params["sessionId"] = thread
            }
            request(loading ? "session/load" : "session/new", params, .session)
        case .session:
            guard let id = opening?.thread ?? result["sessionId"] as? String, !id.isEmpty else {
                return [.failed("\(name) didn't start the chat. Try again.")]
            }
            thread = id
            opening = nil
            if textOnly {
                guard let askMode else { return ready(id) }
                loading = true
                request("session/set_mode", ["sessionId": id, "modeId": askMode], .mode)
                return []
            }
            return ready(id)
        case .mode:
            guard let thread else { return [.failed("\(name) didn't start the chat. Try again.")] }
            return ready(thread)
        case .prompt:
            busy = false
            for key in Array(requests.keys) { reply(key, option: nil) }
            return [.ended]
        }
        return []
    }

    private func ready(_ id: String) -> [Heard] {
        loading = false
        if !waiting.isEmpty { prompt(waiting.removeFirst()) }
        return [.ready(id)]
    }

    private func prompt(_ text: String) {
        guard let thread else { return }
        busy = true
        turn += 1
        request("session/prompt", ["sessionId": thread, "prompt": [["type": "text", "text": text]]], .prompt)
    }

    private func request(_ method: String, _ params: [String: Any], _ kind: Pending) {
        next += 1
        pending[next] = kind
        send(["jsonrpc": "2.0", "id": next, "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        write(data)
    }

    private static func text(_ content: Any?) -> String {
        (content as? [[String: Any]] ?? []).compactMap { block in
            let value = block["content"] as? [String: Any] ?? block
            return value["type"] as? String == "text" ? value["text"] as? String : nil
        }.joined(separator: "\n")
    }
}
