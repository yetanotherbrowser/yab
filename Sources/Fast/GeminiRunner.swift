import Foundation

/// Gemini through Google's Antigravity CLI (`agy`), signed in with the
/// person's own Google account. Its protocol is its own, not Claude's
/// control protocol. What it may do is gated here (docs/gemini.md): a chat
/// with no tools reaches none; a task reaches Yab's browser tools and
/// nothing else of the Mac (no shell, files, web or subagents), through
/// that session's own MCP server, declared in its own workspace.
enum GeminiSupport {
    /// A task's run reaches Yab's MCP tools and nothing native: the policy
    /// denies shell, file, web and subagent tools, the pre-tool gate
    /// (`gate`) lets through only calls to Yab's server, and the stream
    /// stops any other tool step (docs/gemini.md, "What is proven").
    nonisolated static let toolsProven = true
    /// A run with no tools reaches none: signed-in 1.4.4 transcripts in
    /// docs/evidence/gemini-init-registry-2026-10-21 (asked for a shell, a
    /// file and a page it ran none; the pre-tool gate denied a tool).
    nonisolated static let toolsOffProven = true
    /// The primary agent Yab writes into its profile for a run with no tools.
    nonisolated static let agentName = "yab"
    /// A task's primary agent, written into that session's own workspace
    /// (`.agents/agents/`), never the profile every chat shares.
    nonisolated static let toolAgentName = "yab-tools"
    /// Antigravity calls every MCP tool through one dispatcher tool, the
    /// server and the tool named in the call's arguments.
    nonisolated static let dispatcher = "call_mcp_tool"
    /// The dispatcher exposes the schemas, but the CLI also knows native
    /// browser tools with different argument names. Keep this contract in
    /// the session's agent across fresh turns and cold conversation resumes.
    nonisolated static let browserToolGuide = """

    Yab browser tool contract:
    Call only this workspace's yab-browser MCP tools through call_mcp_tool. Read each tool's exact schema before calling it; native browser tool names and arguments are different.
    Use open with url, then text with tab to read a page. The text result is already the page's contents. Once it contains the information the user requested, answer from it and stop; do not call snapshot or eval to read the same text again.
    open uses an agent tab even when the same URL or domain is already open. Inspect or work in an existing user tab only when the user explicitly refers to it or gives it as the task's target; do not search their tabs by domain to choose where to work. Read an explicitly given user tab with text or snapshot. Never call eval in that tab; eval is only for tabs this session opened and owns. For eval the required arguments are tab and js, never expr or code. Never close a user's tab.
    For a button, use snapshot, then click with both tab and ref, then read the changed page with text. If snapshot says e1 button, the click tool's arguments are {"tab":"the returned tab id","ref":"e1"}. Put these arguments inside call_mcp_tool's Arguments field; never call click with empty Arguments {}, an element index, element_id or a native browser tool's parameter names. open requires url; snapshot and text require tab. Native browser tools, shell, files, other MCP servers and subagents remain unavailable. A denied call is not permission to bypass these rules.
    """
    nonisolated static let noTools = "Gemini can answer and chat in Yab, but it can't use Yab's tools yet."
    nonisolated static let fromPhone = "Gemini isn't available for chats and tasks from iPhone yet."
    nonisolated static let notSetUp = "Gemini isn't set up on this Mac. Set it up in Settings › AI › Models."
    /// Asked for this Mac's files and terminal: Gemini keeps to the browser.
    nonisolated static let noMac = "Gemini works in Yab through its browser tools, not this Mac's files and terminal. "
        + "For a task that needs them, ask Claude, ChatGPT or Cursor."

    /// Why a session can't start on `cli`, or nil. An explicit provider
    /// never falls through to another one: a Gemini session Yab can't run
    /// fails, it is not answered by Claude.
    nonisolated static func launchRefusal(_ cli: String, textOnly: Bool = true, remote: Bool = false,
                                          tools: Bool = toolsProven) -> String? {
        switch cli {
        case "claude", "codex", "cursor": return nil
        case "gemini":
            if !textOnly && !tools { return remote ? fromPhone : noTools }
            return nil
        default: return "Yab cannot start the requested agent: \(cli)."
        }
    }

    /// The pre-tool gate of every Gemini run in Yab's profile (hooks.json):
    /// a call to Yab's own MCP server goes on (Yab's cards then decide what
    /// needs the person), anything else is denied before it runs. A run
    /// with no tools has no Yab server, so nothing gets through. The hook
    /// is told `{"toolCall": {"name", "args"}}` on stdin.
    nonisolated static var gate: String {
        let server = Mcp.name, under = server.replacingOccurrences(of: "-", with: "_")
        let named = ["mcp_\(server)_", "mcp__\(server)__", "\(server)__", "\(server)/", "\(server):", "\(server)_",
                     "mcp_\(under)_", "mcp__\(under)__", "\(under)__", "\(under)_"].map { "'\($0)'?*" }.joined(separator: "|")
        return """
        #!/bin/sh
        # Yab's gate for Gemini: only Yab's own MCP server's tools run.
        input=$(cat)
        field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
        allow() { printf '%s\\n' '{"decision":"allow"}'; exit 0; }
        name=$(field toolCall.name)
        case "$name" in
          \(dispatcher))
            for key in ServerName serverName server_name server; do
              [ "$(field "toolCall.args.$key")" = '\(server)' ] && allow
            done ;;
          \(named)) allow ;;
        esac
        printf '%s\\n' '{"decision":"deny","reason":"Yab gives Gemini only its own browser tools."}'

        """
    }

    /// Yab's browser launcher, `open` and $BROWSER first on every agy run's
    /// PATH (Configuration.prepare): a page agy opens is written to
    /// $YAB_GEMINI_PAGE when the run gives one, and otherwise goes nowhere.
    /// Never to the Mac's default browser: signed out, `agy -p /usage` (and
    /// any `-p` run) opens Google's sign-in there itself and waits a minute
    /// for it, a sign-in nobody in Yab can finish (#2038).
    nonisolated static let launcherScript = """
    #!/bin/sh
    for url in "$@"; do
      case "$url" in
        https://*)
          if [ -n "$YAB_GEMINI_PAGE" ]; then printf '%s\\n' "$url" > "$YAB_GEMINI_PAGE"; fi
          exit 0 ;;
      esac
    done
    exit 1

    """
    /// The launcher's folder in the profile, relative to its HOME.
    nonisolated static let launcherPath = ".gemini/config/yab-launcher"

    /// Yab's own Gemini profile, shared by every Yab
    /// copy on this Mac so one sign-in serves them all. Google keeps the
    /// sign-in in the login keychain; this folder holds only what Yab
    /// writes (settings, its agent, no MCP servers of the person's) and
    /// each chat's empty workspace.
    nonisolated static var profile: URL {
        if AgentFixture.requested { return Store.file("unsupported-gemini-fixture") }
        if let given = ProcessInfo.processInfo.environment["YAB_GEMINI_PROFILE"], !given.isEmpty {
            return URL(fileURLWithPath: given, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yab Gemini", isDirectory: true)
    }

    /// The CLI's environment in that profile: nothing inherited that could
    /// carry another sign-in, endpoint, plugin or configuration.
    nonisolated static func environment(_ base: [String: String], profile: URL = profile) -> [String: String] {
        var env = base.filter { ["PATH", "LANG", "LC_ALL", "TMPDIR", "USER", "LOGNAME", "SHELL", "TERM", "__CF_USER_TEXT_ENCODING"].contains($0.key) }
        let home = profile.appendingPathComponent("home")
        // 1.4.7 ignores the directory overrides for agents and policy. Keep
        // the existing private HOME, with Library/Keychains linked to the
        // real login home by prepareKeychain before any CLI can start.
        env["HOME"] = home.path
        env["ANTIGRAVITY_GEMINI_DIR"] = home.appendingPathComponent(".gemini").path
        env["ANTIGRAVITY_APP_DATA_DIR"] = profile.appendingPathComponent("app-data").path
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        return env
    }

    /// Antigravity 1.4.7 only loads the private policy through HOME. Never
    /// give Security.framework a missing or a new login keychain there.
    /// Only this link in Yab's profile is written, never its target.
    nonisolated static func prepareKeychain(profile: URL, loginHome: String) throws {
        let fm = FileManager.default
        let canonical = profile.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(profile.lastPathComponent)
        let library = canonical.appendingPathComponent("home/Library")
        guard library.resolvingSymlinksInPath().path == library.path else {
            throw GeminiStream.Failure("Gemini's private home changed. Yab left it untouched and didn't start Gemini.")
        }
        let link = library.appendingPathComponent("Keychains")
        let target = URL(fileURLWithPath: loginHome).appendingPathComponent("Library/Keychains").resolvingSymlinksInPath()
        guard fm.fileExists(atPath: target.path) else {
            throw GeminiStream.Failure("Yab couldn't find this Mac's login keychain folder. Gemini didn't start.")
        }
        try fm.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let kept = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            guard kept == target.path else { throw GeminiStream.Failure("Gemini's keychain link changed. Yab left it untouched and didn't start Gemini.") }
        } else if fm.fileExists(atPath: link.path) {
            throw GeminiStream.Failure("Gemini's private profile contains a separate keychain folder. Yab left it untouched. Contact support before signing in.")
        } else {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        }
        guard link.resolvingSymlinksInPath().path == target.path else {
            throw GeminiStream.Failure("Yab couldn't use this Mac's login keychain folder. Gemini didn't start.")
        }
    }

    /// Whether a tool the CLI offers or runs is one of Yab's: its MCP
    /// server's, in the spellings MCP hosts use. Anything else (a shell,
    /// files, the web, a subagent) is native and never allowed.
    nonisolated static func isYabTool(_ name: String, arguments: [String: Any]? = nil) -> Bool {
        let server = Mcp.name
        if name == dispatcher { return arguments.map { called($0).server == server } ?? false }
        let under = server.replacingOccurrences(of: "-", with: "_")
        let prefixes = ["mcp_\(server)_", "mcp__\(server)__", "\(server)__", "\(server)/", "\(server):", "\(server)_",
                        "mcp_\(under)_", "mcp__\(under)__", "\(under)__", "\(under)_"]
        return prefixes.contains { name.hasPrefix($0) && name.count > $0.count }
    }

    /// The server and tool a dispatcher call names, in the spellings seen.
    nonisolated static func called(_ arguments: [String: Any]) -> (server: String?, tool: String?) {
        let pick = { (keys: [String]) in keys.lazy.compactMap { arguments[$0] as? String }.first }
        return (pick(["ServerName", "serverName", "server_name", "server"]), pick(["ToolName", "toolName", "tool_name", "tool", "name"]))
    }

    /// A Yab tool's own name, as its chat shows it: "open", not
    /// "mcp_yab-browser_open" or the dispatcher's.
    nonisolated static func shownName(_ name: String, arguments: [String: Any]?) -> String {
        if name == dispatcher { return arguments.flatMap { called($0).tool } ?? "tool" }
        let server = Mcp.name, under = server.replacingOccurrences(of: "-", with: "_")
        for prefix in ["mcp__\(server)__", "mcp_\(server)_", "\(server)__", "\(server)/", "\(server):", "\(server)_",
                       "mcp__\(under)__", "mcp_\(under)_", "\(under)__", "\(under)_"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    /// The primary agent has no native tools. Tasks inherit their own
    /// workspace's MCP server; text runs inherit none. It is not callable
    /// as a subagent, runs no commands, and its body is the system prompt.
    nonisolated static func agentFile(tools: [String], brief: String, name: String = agentName, inheritMcp: Bool = false) -> String {
        let list = tools.isEmpty ? "tools: []" : "tools:\n" + tools.map { "  - " + $0 }.joined(separator: "\n")
        return """
        ---
        name: \(name)
        description: Yab's agent. Answers in Yab with only the tools Yab gives it.
        \(list)
        inheritMcp: \(inheritMcp)
        mainAgent: true
        subagent: false
        commandExecutionPolicy: off
        ---
        \(brief)

        """
    }

    /// The CLI's `models` output, not a hardcoded list of subscriptions.
    /// A row is a line with a `gemini-…` id anywhere in it ("gemini-3-pro
    /// Gemini 3 Pro", "• Gemini 3 Pro (gemini-3-pro)"); the rest of the
    /// line is its name.
    nonisolated static func models(_ output: String) -> [(id: String, name: String)] {
        var seen = Set<String>()
        let edge = CharacterSet(charactersIn: "()[]`'\",:*|•-–> ").union(.whitespaces)
        return output.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let at = words.firstIndex(where: { word in
                let id = word.trimmingCharacters(in: edge)
                return id.hasPrefix("gemini-") && id.count > 7
                    && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }
            }) else { return nil }
            let id = words[at].trimmingCharacters(in: edge)
            guard seen.insert(id).inserted else { return nil }
            var rest = words
            rest.remove(at: at)
            let name = rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "`'\",:*|•-–> ").union(.whitespaces))
            return (id, name.isEmpty || name.lowercased().hasPrefix("gemini-") ? title(id) : name)
        }
    }

    /// "gemini-3-pro-preview" as the picker says it: "Gemini 3 Pro Preview".
    nonisolated static func title(_ id: String) -> String {
        id.split(separator: "-").map { part in
            part.first?.isNumber == true ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }
}

/// Incremental NDJSON decoding. A result's counters cover the entire process,
/// while permission denials remain failures even when the provider says SUCCESS.
struct GeminiStream {
    struct Usage: Equatable {
        var input = 0, output = 0, thinking = 0, cached = 0, total = 0

        init(_ object: [String: Any] = [:]) {
            input = object["input_tokens"] as? Int ?? 0
            output = object["output_tokens"] as? Int ?? 0
            thinking = object["thinking_tokens"] as? Int ?? 0
            cached = object["cache_read_tokens"] as? Int ?? 0
            total = object["total_tokens"] as? Int ?? 0
        }

        func delta(after prior: Usage) -> Usage? {
            let values = [input - prior.input, output - prior.output, thinking - prior.thinking,
                          cached - prior.cached, total - prior.total]
            guard values.allSatisfy({ $0 >= 0 }) else { return nil }
            var delta = Usage()
            delta.input = values[0]; delta.output = values[1]; delta.thinking = values[2]
            delta.cached = values[3]; delta.total = values[4]
            return delta
        }
    }

    struct Result: Equatable {
        let conversation: String
        let status: String
        let response: String
        let error: String?
        /// Unknown on the first resumed turn: the CLI may include historical
        /// counters, so treating them as fresh usage would double-count it.
        let usage: Usage?
        var succeeded: Bool { status == "SUCCESS" && error == nil }
    }

    enum Event: Equatable {
        case initialized(String, model: String?, tools: [String])
        case step(ChatItem)
        case result(Result)
        case failed(String)
    }

    private var buffer = Data()
    private(set) var conversation: String?
    private(set) var active = false
    private(set) var broken = false
    private(set) var authenticationRequired = false
    private var cumulative = Usage()
    private var failure: String?
    private var diagnosticTail = ""
    /// Only unconsumed diagnostics participate in denial detection. Keep the
    /// full tail separately so a later nonzero exit still explains itself.
    private var diagnosticScan = ""
    private var steps: [Int: ChatItem] = [:]
    /// A dispatcher step's arguments, by step, once its first update said them.
    private var dispatched: [Int: [String: Any]] = [:]
    private var completedSteps = Set<Int>()
    private var deniedNativeSteps = Set<Int>()
    private let expected: String?
    private let expectedModel: String?
    /// Whether Yab's MCP tools were given. Native execution always fails;
    /// init's registry is not the selected text agent's effective tool list.
    private let yabTools: Bool
    private var baselineKnown: Bool
    private let run = UUID().uuidString
    private var turn = 0
    static let maxLine = 8 * 1024 * 1024

    init(conversation: String? = nil, model: String? = nil, yabTools: Bool = false) {
        expected = conversation
        expectedModel = model
        self.yabTools = yabTools
        baselineKnown = conversation == nil
    }

    mutating func prompt(_ text: String, attachments: Int = 0) throws -> Data {
        guard !broken, !active else { throw Failure("Wait for Gemini's result before sending another turn.") }
        guard attachments == 0 else { throw Failure("Gemini attachments are not supported by this text transport.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("A text prompt is required.") }
        active = true; failure = nil; diagnosticTail = ""; diagnosticScan = ""; steps = [:]; dispatched = [:]; completedSteps = []; deniedNativeSteps = []; turn += 1
        var line = try JSONSerialization.data(withJSONObject: ["event": "user", "message": ["content": text]])
        line.append(0x0A)
        return line
    }

    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    mutating func receive(_ data: Data) -> [Event] {
        guard !broken else { return [] }
        buffer.append(data)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.count <= Self.maxLine else { return events + fail("Gemini returned an oversized event.") }
            if line.isEmpty { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                return events + fail("Gemini returned invalid stream JSON.")
            }
            events += receive(object)
            if broken { return events }
        }
        if buffer.count > Self.maxLine { return events + fail("Gemini returned an oversized event.") }
        return events
    }

    mutating func end(code: Int32) -> [Event] {
        guard !broken else { return [] }
        if authenticationRequired { return fail("Antigravity CLI requires Google sign-in.") }
        if let failure, !(failure == Self.permissionFailure && !active && recoveredNativeDenial(diagnosticScan)) {
            return fail(failure)
        }
        guard buffer.isEmpty else { return fail("Gemini closed an incomplete stream event.") }
        guard !active, conversation != nil, code == 0 else {
            let reason = code == 0 ? "Gemini stopped before returning a complete answer." : "Gemini stopped before it finished (exit code \(code))."
            let diagnostic = diagnosticTail.trimmingCharacters(in: .whitespacesAndNewlines)
            return fail(reason + (diagnostic.isEmpty ? " Try again, or check Antigravity CLI in Terminal." : "\n" + diagnostic))
        }
        return []
    }

    /// stderr is diagnostic, never an instruction or an approval request.
    /// A soft denial is sticky for this turn, even if the CLI exits zero.
    mutating func diagnostic(_ line: String) {
        let text = diagnosticScan + line
        let lower = text.lowercased()
        if ["authentication required", "not signed in", "sign in", "login required", "no credentials"].contains(where: lower.contains) {
            authenticationRequired = true
        }
        if Self.denial(text), failure == nil { failure = Self.permissionFailure }
        diagnosticScan = String(text.suffix(2000))
        diagnosticTail = String((diagnosticTail + line).suffix(2000))
    }

    private static func denial(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["auto-denied", "soft-denied", "permission denied", "permission_denied", "requires approval", "headless mode cannot prompt"].contains(where: text.contains)
    }

    private static let permissionFailure = "Gemini could not complete a tool because permission was denied."

    /// A hook denial whose native step was already confirmed may arrive on
    /// stderr before or after stdout's result. It cannot erase a Yab tool error.
    private func recoveredNativeDenial(_ text: String) -> Bool {
        let denials = text.split(separator: "\n").map(String.init).filter(Self.denial)
        let names = deniedNativeSteps.compactMap { steps[$0]?.name }
        return !denials.isEmpty && !names.isEmpty && denials.allSatisfy { line in
            line.contains("Yab gives Gemini only its own browser tools") || names.contains { line.contains($0) }
        }
    }

    private mutating func fail(_ message: String) -> [Event] {
        broken = true; active = false
        let diagnostic = diagnosticTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return [.failed(message + (diagnostic.isEmpty || message.contains(diagnostic) ? "" : "\n" + diagnostic))]
    }

    private mutating func receive(_ event: [String: Any]) -> [Event] {
        switch event["event"] as? String {
        case "init":
            guard conversation == nil, let id = event["conversation_id"] as? String, !id.isEmpty,
                  expected == nil || expected == id, let info = event["init"] as? [String: Any],
                  let tools = info["tools"] as? [String], info["permission_mode"] as? String == "request-review" else {
                return fail("Gemini returned an unexpected conversation or permission mode.")
            }
            // Antigravity 1.4.4 reports its full registry here even for
            // tools: []. This is metadata, not a grant to execute tools:
            // the policy denies native tools, the pre-tool gate lets only
            // Yab's server through, and a tool step that isn't Yab's fails
            // the turn below, in a run with Yab's tools or without.
            if let expectedModel, info["model"] as? String != expectedModel {
                return fail("Antigravity CLI did not acknowledge the selected Gemini model.")
            }
            conversation = id
            return [.initialized(id, model: info["model"] as? String, tools: tools)]
        case "step_update":
            guard active, let info = event["step_update"] as? [String: Any],
                  let id = conversation, info["conversation_id"] as? String == id,
                  let index = info["step_index"] as? Int, index >= 0,
                  let type = info["step_type"] as? String,
                  let state = info["state"] as? String,
                  ["ACTIVE", "DONE"].contains(state) || (state == "ERROR" && type == "tool") else {
                return fail("Gemini returned a step outside the active conversation.")
            }
            guard !completedSteps.contains(index) else { return [] }
            if info["subagent_info"] != nil { return fail("Gemini subagents are not supported in browser-only mode.") }
            if state != "ACTIVE" { completedSteps.insert(index) }
            guard type == "agent_response" || type == "tool" else { return [] }
            var item = steps[index] ?? ChatItem(id: "gemini.\(run).\(turn).\(index)", kind: type == "tool" ? .tool : .message)
            if let delta = info["text_delta"] as? String { item.text += delta }
            if type == "tool" {
                let tool = info["tool_info"] as? [String: Any] ?? [:]
                let called = info["tool_name"] as? String ?? tool["name"] as? String ?? "tool"
                let parameters = (tool["parameters"] ?? tool["args"] ?? tool["arguments"]) as? [String: Any]
                // The dispatcher's arguments come with its first update; a
                // later one of the same step may leave them out.
                let known = parameters ?? dispatched[index]
                guard yabTools, GeminiSupport.isYabTool(called, arguments: known) else {
                    // The CLI emits ACTIVE before Yab's pre-tool hook can
                    // deny a native call. Let it read that denial and recover
                    // with our MCP tools. A successful native execution or
                    // another server's call still stops the run.
                    let native = called != GeminiSupport.dispatcher && !called.hasPrefix("mcp_")
                        && !GeminiSupport.isYabTool(called, arguments: known)
                    if yabTools, native {
                        let error = tool["error"] as? [String: Any] ?? [:]
                        let detail = [error["type"] as? String, error["message"] as? String, tool["output"] as? String]
                            .compactMap { $0 }.joined(separator: " ")
                        let denied = Self.denial(detail) || detail.contains("Yab gives Gemini only its own browser tools")
                        if state == "ACTIVE" || denied {
                            item.name = called
                            item.text = "Yab blocked this built-in tool. Use Yab's browser tools instead."
                            item.state = state == "ACTIVE" ? .running : .failed
                            steps[index] = item
                            if denied { deniedNativeSteps.insert(index) }
                            return [.step(item)]
                        }
                    }
                    return fail("Gemini tried a tool Yab didn't give it (\(GeminiSupport.shownName(called, arguments: known))), so Yab stopped it.")
                }
                if called == GeminiSupport.dispatcher, let parameters { dispatched[index] = parameters }
                item.name = GeminiSupport.shownName(called, arguments: known)
                // What the tool was given: the dispatcher's own Arguments, else all of them.
                let given = known.flatMap { $0["Arguments"] ?? $0["arguments"] ?? (called == GeminiSupport.dispatcher ? nil : $0) }
                    .map { ($0 as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? $0 }
                if let given, JSONSerialization.isValidJSONObject(given),
                   let data = try? JSONSerialization.data(withJSONObject: given, options: [.sortedKeys]) {
                    item.detail = String(decoding: data, as: UTF8.self)
                }
                let error = tool["error"] as? [String: Any]
                let output = tool["output"] as? String ?? ""
                let structured = tool["output"] as? [String: Any]
                    ?? (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
                let structuredText = (structured?["content"] as? [[String: Any]] ?? [])
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                let outputText = output.isEmpty ? structuredText : output
                let stepFailed = state == "ERROR" || error != nil || structured?["isError"] as? Bool == true
                let errorDetail = [error?["type"] as? String, error?["message"] as? String].compactMap { $0 }.joined(separator: " ")
                let denied = Self.denial(errorDetail) || (stepFailed && Self.denial(outputText))
                if stepFailed { item.state = .failed }
                if denied { failure = "Gemini could not complete a tool." }
                if !outputText.isEmpty { item.text = String(outputText.suffix(ChatItem.outputKept)) }
                if let message = error?["message"] as? String { item.text = message }
            }
            if item.state != .failed { item.state = state == "DONE" ? .done : .running }
            steps[index] = item
            return [.step(item)]
        case "result":
            // Authentication and malformed-input errors can arrive without init.
            guard active, let info = event["result"] as? [String: Any], let status = info["status"] as? String else {
                return fail("Gemini returned an unexpected result.")
            }
            guard let id = conversation, info["conversation_id"] as? String == id else {
                return fail(info["error"] as? String ?? "Gemini returned a result for another conversation.")
            }
            let used = Usage(info["usage"] as? [String: Any] ?? [:])
            guard let delta = used.delta(after: cumulative) else { return fail("Gemini's cumulative usage went backwards.") }
            let reportedUsage = baselineKnown ? delta : nil
            baselineKnown = true
            cumulative = used; active = false
            // A denied native call may be retried through Yab. A permission-denied
            // Yab tool or the CLI's own error remains a failed result.
            let recovered = failure == Self.permissionFailure && recoveredNativeDenial(diagnosticScan)
            let error = info["error"] as? String ?? (recovered ? nil : failure)
            let response = info["response"] as? String ?? ""
            // This result consumed the diagnostics seen so far, including
            // a confirmed native denial recovered through Yab. New stderr
            // after it must still be able to fail the final process outcome.
            failure = nil
            diagnosticScan = ""
            let unfinished = steps.values.contains { $0.state == .running }
            return [.result(Result(conversation: id, status: status, response: response,
                                   error: error ?? (unfinished ? "Gemini left a step unfinished." : nil), usage: reportedUsage))]
        default:
            return fail("Gemini returned an unsupported stream event.")
        }
    }
}

/// One Gemini turn as a process: the CLI in Yab's profile, started as
/// Yab's own primary agent, told one message as stream-json and read back
/// as provider-neutral events. It does not install a CLI, sign in, touch
/// tokens or the person's own ~/.gemini, or let the model approve anything.
@MainActor
final class GeminiRunner {
    struct Configuration {
        let binary: String
        /// Yab's Gemini profile (GeminiSupport.profile).
        var profile: URL = GeminiSupport.profile
        /// This chat's own empty folder, the CLI's working directory.
        let workspace: URL
        let model: String?
        var effort: String? = nil
        let conversation: String?
        /// Yab's own binary, the MCP server's command.
        let command: String
        /// Agents.mcpArgs(session) for a run with Yab's tools (a task); nil
        /// for a run with none (a text chat, a helper's words).
        let mcpArgs: [String]?
        /// The system prompt, the body of Yab's agent.
        var brief = ""
        let environment: [String: String]

        /// The CLI's catalog includes effort-pinned IDs. An explicit different
        /// effort asks for that same family at the requested effort; agy rejects
        /// contradictory pinned-ID/effort flags. Keep the person's saved choice.
        var launchModel: String? {
            guard let model, model.hasPrefix("gemini-"), let effort,
                  ["low", "medium", "high", "xhigh", "max"].contains(effort),
                  let pinned = ["low", "medium", "high", "xhigh", "max"].first(where: { model.hasSuffix("-" + $0) }),
                  pinned != effort else { return model }
            return String(model.dropLast(pinned.count + 1))
        }

        var arguments: [String] {
            var args = ["--input-format", "stream-json", "--output-format", "stream-json", "--disable-slash-commands",
                        "--agent", mcpArgs == nil ? GeminiSupport.agentName : GeminiSupport.toolAgentName]
            if let launchModel { args += ["--model", launchModel] }
            if let effort { args += ["--effort", effort] }
            if let conversation { args += ["--conversation", conversation] }
            return args
        }

        /// Natives no run of Yab's may use, whatever its agent lists.
        /// Antigravity rejects the retired unsandboxed category (including
        /// its bare spelling); command(*) already denies those commands.
        static let denied = ["read_file(*)", "write_file(*)", "command(*)", "read_url(*)", "execute_url(*)", "invoke_subagent(*)"]
        static let settingsPath = ".gemini/antigravity-cli/settings.json"
        /// The gate script's place in the profile, relative to its HOME.
        static let gatePath = ".gemini/config/yab-gate.sh"

        private static func json(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        }

        private static func settingsObject(_ data: Data) -> [String: Any]? {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["permissions"] == nil || object["permissions"] is [String: Any] else { return nil }
            let policy = object["permissions"] as? [String: Any] ?? [:]
            guard ["deny", "allow", "ask"].allSatisfy({ policy[$0] == nil || policy[$0] is [String] }) else { return nil }
            return object
        }

        /// Replace Yab's permission lists, including any CLI-saved grants.
        /// Keep unknown keys and unchanged bytes when already set up.
        static func settings(_ data: Data?) throws -> Data {
            let original = data.flatMap { settingsObject($0) } ?? [:]
            var object = original
            var policy = original["permissions"] as? [String: Any] ?? [:]
            policy["deny"] = denied
            policy["allow"] = ["mcp(\(Mcp.name)/*)"]
            policy["ask"] = [String]()
            object["permissions"] = policy
            if let data, NSDictionary(dictionary: object).isEqual(to: original) { return data }
            return try json(object)
        }

        /// What Yab writes into the profile every chat shares. The same
        /// bytes for a run with Yab's tools and one without, so two chats at
        /// once never undo each other: the policy (natives denied, Yab's
        /// server allowed), no MCP servers of the profile's own, the gate
        /// before every tool, and for a run with no tools Yab's text agent.
        /// `home` is the profile's HOME, for the gate's path.
        func files(home: URL, settings: Data? = nil) throws -> [(path: String, data: Data)] {
            let gate = home.appendingPathComponent(Self.gatePath).path
            var made: [(String, Data)] = [
                (Self.settingsPath, try Self.settings(settings)),
                (".gemini/config/mcp_config.json", try Self.json(["mcpServers": [String: Any]()])),
                (Self.gatePath, Data(GeminiSupport.gate.utf8)),
                (GeminiSupport.launcherPath + "/open", Data(GeminiSupport.launcherScript.utf8)),
                (GeminiSupport.launcherPath + "/browser", Data(GeminiSupport.launcherScript.utf8)),
                (".gemini/config/hooks.json", try Self.json(["yab-gate": [
                    "PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "/bin/sh \"\(gate)\"", "timeout": 5]]]],
                ]])),
            ]
            // A task's agent lives in its own workspace (workspaceFiles).
            if mcpArgs == nil {
                made.append((".gemini/config/agents/\(GeminiSupport.agentName).md", Data(GeminiSupport.agentFile(tools: [], brief: brief).utf8)))
            }
            return made
        }

        /// What a run with Yab's tools writes into its own workspace, which
        /// no other chat uses: this session's Yab MCP server, and its agent,
        /// which inherits only that workspace's MCP server. The dispatcher
        /// is added by Antigravity through inheritMcp, not a native component
        /// that can be resolved in tools: (1.4.7 rejects call_mcp_tool there).
        func workspaceFiles() throws -> [(path: String, data: Data)] {
            guard let mcpArgs else { return [] }
            let servers: [String: Any] = [Mcp.name: ["command": command, "args": mcpArgs]]
            return [
                (".agents/mcp_config.json", try Self.json(["mcpServers": servers])),
                (".agents/agents/\(GeminiSupport.toolAgentName).md",
                 Data(GeminiSupport.agentFile(tools: [], brief: brief + GeminiSupport.browserToolGuide, name: GeminiSupport.toolAgentName, inheritMcp: true).utf8)),
            ]
        }

        /// Writes Yab's files and the workspace, then reads them back: a
        /// symlink or a file that isn't what Yab wrote refuses the run.
        /// The policy and the gate are the boundary; the stream's tool guard
        /// (GeminiStream.yabTools) stops a tool that slips past them.
        func prepare() throws -> (env: [String: String], cwd: URL) {
            guard model?.isEmpty != true else { throw GeminiStream.Failure("Gemini needs a model name.") }
            if let effort, !GeminiModels.efforts.contains(effort) {
                throw GeminiStream.Failure("This Gemini model supports Low, Medium or High effort. Choose one in the model picker and try again.")
            }
            if let mcpArgs {
                guard GeminiSupport.toolsProven else { throw GeminiStream.Failure(GeminiSupport.noTools) }
                guard mcpArgs.contains("--session"), mcpArgs.contains("--socket") else {
                    throw GeminiStream.Failure("Gemini's Yab tools must belong to its session.")
                }
            }
            let fm = FileManager.default
            // macOS's /var and /tmp aliases are normal: canonicalize the
            // parents once; anything linked inside is refused below.
            let profile = profile.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(profile.lastPathComponent, isDirectory: true)
            let home = profile.appendingPathComponent("home", isDirectory: true)
            let cwd = workspace.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(workspace.lastPathComponent, isDirectory: true)
            for folder in [home.appendingPathComponent(".gemini/antigravity-cli"), home.appendingPathComponent(".gemini/config/agents"),
                           home.appendingPathComponent(GeminiSupport.launcherPath), cwd] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            for folder in [profile, home] { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            try GeminiSupport.prepareKeychain(profile: profile,
                loginHome: environment["HOME"] ?? ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
            guard cwd.resolvingSymlinksInPath().path == cwd.path else {
                throw GeminiStream.Failure("Gemini's workspace isn't Yab's, so it didn't start.")
            }
            // The workspace holds only what Yab put there: nothing for a run
            // with no tools, this session's server and agent for a task. A
            // chat whose workspace grew anything else is not carried on.
            let ours = try workspaceFiles()
            let agents = cwd.appendingPathComponent(".agents", isDirectory: true)
            if fm.fileExists(atPath: agents.path) {
                let allowed = Set(ours.map(\.path) + (ours.isEmpty ? [] : [".agents/agents"]))
                let found = (fm.enumerator(atPath: agents.path)?.allObjects as? [String] ?? []).map { ".agents/" + $0 }
                if found.contains(where: { !allowed.contains($0) }) {
                    throw GeminiStream.Failure("Gemini's workspace changed, so Yab didn't carry on this chat.")
                }
            }
            if !ours.isEmpty {
                try fm.createDirectory(at: agents.appendingPathComponent("agents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let settingsFile = home.appendingPathComponent(Self.settingsPath)
            guard settingsFile.resolvingSymlinksInPath().path == settingsFile.path else {
                throw GeminiStream.Failure("Gemini's settings in Yab's profile aren't Yab's, so it didn't start.")
            }
            let settings = fm.fileExists(atPath: settingsFile.path) ? try Data(contentsOf: settingsFile) : nil
            if let settings, Self.settingsObject(settings) == nil {
                let backup = settingsFile.appendingPathExtension("bak")
                guard backup.resolvingSymlinksInPath().path == backup.path else {
                    throw GeminiStream.Failure("Gemini's settings in Yab's profile aren't Yab's, so it didn't start.")
                }
                try settings.write(to: backup, options: .atomic)
            }
            for (base, made) in [(home, try files(home: home, settings: settings)), (cwd, ours)] {
                for (path, data) in made {
                    let file = base.appendingPathComponent(path)
                    if path != Self.settingsPath || data != settings {
                        try data.write(to: file, options: .atomic)
                    }
                    guard file.resolvingSymlinksInPath().path == file.path, try Data(contentsOf: file) == data else {
                        throw GeminiStream.Failure("Gemini's settings in Yab's profile aren't Yab's, so it didn't start.")
                    }
                }
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.appendingPathComponent(Self.gatePath).path)
            let launcher = home.appendingPathComponent(GeminiSupport.launcherPath)
            for name in ["open", "browser"] {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.appendingPathComponent(name).path)
            }
            // Every page agy opens goes through Yab's launcher (see
            // launcherScript), whatever PATH the agy copy's folder adds.
            var env = AgentCopies.environment(for: binary, base: GeminiSupport.environment(environment, profile: profile))
            env["PATH"] = launcher.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["BROWSER"] = launcher.appendingPathComponent("browser").path
            env["YAB_GEMINI_PAGE"] = nil
            return (env, cwd)
        }
    }

    private(set) var stream: GeminiStream
    private var process: Process?
    private var input: FileHandle?
    private let receive: (GeminiStream.Event) -> Void
    private var generation = UUID()
    var running: Bool { process?.isRunning == true }
    /// The process, for whoever stops the session (Agents.stop).
    var child: Process? { process }
    /// Once, when the turn is over: its process gone and every event
    /// delivered, or stopped. The exit code, or -1 when stopped.
    var exited: ((Int32) -> Void)?
    private var over = false

    private func exit(_ code: Int32) {
        guard !over else { return }
        over = true
        exited?(code)
    }

    init(conversation: String? = nil, receive: @escaping (GeminiStream.Event) -> Void) {
        stream = GeminiStream(conversation: conversation)
        self.receive = receive
    }

    private var permission: ProviderLaunchPermit?
    func start(_ config: Configuration, permit: ProviderLaunchPermit? = nil) throws {
        guard let permit, permit.valid else { throw GeminiStream.Failure(ProviderConsent.refusal) }
        permission = permit
        guard process == nil else { throw GeminiStream.Failure("Gemini is already running.") }
        over = false
        stream = GeminiStream(conversation: config.conversation, model: config.launchModel, yabTools: config.mcpArgs != nil)
        let prepared = try config.prepare()
        let child = Process(), out = Pipe(), errors = Pipe(), incoming = Pipe()
        child.executableURL = ProcessLaunch.executableURL(config.binary)
        child.arguments = config.arguments; child.environment = prepared.env; child.currentDirectoryURL = prepared.cwd
        child.standardOutput = out; child.standardError = errors; child.standardInput = incoming
        let generation = UUID(); self.generation = generation
        let errorFD = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(errorFD, F_SETFL, fcntl(errorFD, F_GETFL) | O_NONBLOCK)
        let drained = DispatchGroup()
        // One reader drains diagnostics before stdout. Separate readers can
        // deliver SUCCESS before an already-written soft-denial on stderr.
        // Both EOFs precede the exit callback and its final transport check.
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { drained.leave() }
            let handles = [errors.fileHandleForReading, out.fileHandleForReading]
            defer { handles.forEach { try? $0.close() } }
            var polls = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while polls.contains(where: { $0.fd >= 0 }) {
                let ready = poll(&polls, nfds_t(polls.count), -1)
                if ready < 0 { if errno == EINTR { continue }; break }
                for index in polls.indices where polls[index].fd >= 0 && polls[index].revents != 0 {
                    let count = bytes.withUnsafeMutableBytes { read(polls[index].fd, $0.baseAddress, $0.count) }
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    if count <= 0 { polls[index].fd = -1; continue }
                    let data = Data(bytes.prefix(count))
                    if index == 1, polls[0].fd >= 0 {
                        // A diagnostic can become readable after poll returned
                        // but before this terminal stdout event was read.
                        while true {
                            let count = bytes.withUnsafeMutableBytes { read(errorFD, $0.baseAddress, $0.count) }
                            if count <= 0 { break }
                            let diagnostic = Data(bytes.prefix(count))
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.generation == generation else { return }
                                self.stream.diagnostic(String(decoding: diagnostic, as: UTF8.self))
                            }
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == generation else { return }
                        if index == 0 { self.stream.diagnostic(String(decoding: data, as: UTF8.self)) }
                        else { self.deliver(self.stream.receive(data)) }
                    }
                }
            }
        }
        child.terminationHandler = { [weak self] ended in
            drained.notify(queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.deliver(self.stream.end(code: ended.terminationStatus))
                    self.process = nil; self.input = nil
                    self.exit(ended.terminationStatus)
                }
            }
        }
        do { guard try permit.start(child) else { throw GeminiStream.Failure(ProviderConsent.refusal) } }
        catch {
            try? out.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            throw error
        }
        process = child
        input = incoming.fileHandleForWriting
        _ = fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func send(_ text: String, attachments: Int = 0) throws {
        guard permission?.valid == true, let input, process?.isRunning == true else { throw GeminiStream.Failure("Gemini is not running.") }
        try input.write(contentsOf: stream.prompt(text, attachments: attachments))
    }

    func close() { try? input?.close(); input = nil }

    func stop() {
        generation = UUID() // queued output belongs to the stopped turn
        close()
        if let process { Shell.end(process, grace: 3) }
        process = nil
        exit(-1)
    }

    /// One answer with no tools, for Yab's own helpers (PlanText): Yab's
    /// text agent in the shared profile, a workspace of the helper's own,
    /// the words in one message. "" when it fails or takes past `limit`.
    static func once(binary: String, message: String, model: String? = nil, environment: [String: String],
                     room: String, limit: Double = 120, permit: ProviderLaunchPermit? = nil) async -> String {
        final class Heard { var answer = ""; var over = false }
        let heard = Heard()
        return await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            let runner = GeminiRunner { event in
                if case .result(let result) = event, result.succeeded { heard.answer = result.response }
            }
            let finish = { (words: String) in
                guard !heard.over else { return }
                heard.over = true
                done.resume(returning: words)
            }
            runner.exited = { code in finish(code == 0 ? heard.answer : "") }
            let config = Configuration(binary: binary, workspace: GeminiSupport.profile.appendingPathComponent("helpers/" + room, isDirectory: true),
                                       model: model, conversation: nil, command: "", mcpArgs: nil,
                                       brief: Agents.instructions(textOnly: true, full: false, remembering: false), environment: environment)
            do {
                try runner.start(config, permit: permit)
                try runner.send(message)
                runner.close()
            } catch {
                runner.stop()
                finish("")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                MainActor.assumeIsolated { if !heard.over { runner.stop() } }
            }
        }
    }

    private func deliver(_ events: [GeminiStream.Event]) {
        for event in events {
            receive(event)
            if case .failed = event { stop(); return }
        }
    }
}
