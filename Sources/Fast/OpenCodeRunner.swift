import Foundation

/// OpenCode is a connected AI plan. Its CLI owns authentication and billing,
/// and its turns run through `opencode acp`, the Agent Client Protocol.
@MainActor
enum OpenCodeRunner {
    nonisolated static let connectionKey = "agents.opencode.connected"
    nonisolated static var connected: Bool { Store.settings.bool(forKey: connectionKey) }
    static var available: Bool { connected && Shell.cached?.opencode != nil }
    static var chatClis: [String] { AgentSetupModel.clis }
    static var models: [AgentModel] {
        parseModels(Store.settings.string(forKey: "agents.opencode.models") ?? "")
    }
    /// Where OpenCode shows its plan's usage; it doesn't tell its CLI.
    static let usage = URL(string: "https://opencode.ai")!
    private static var refreshed = Date.distantPast

    static func refresh(binary: String, env: [String: String], permit: ProviderLaunchPermit) async {
        guard permit.valid else { return }
        guard Date().timeIntervalSince(refreshed) > 300 else { return }
        refreshed = Date()
        let result = await Shell.timed(binary, ["models"], env: environment(env), permit: permit)
        guard permit.valid, result.code == 0, !parseModels(result.output).isEmpty else { return }
        AgentSetupModel.shared.objectWillChange.send()
        Store.settings.set(result.output, forKey: "agents.opencode.models")
    }

    /// `opencode models` prints one id a line, `provider/model`, where the
    /// provider may itself carry slashes or a `~` mark. The model's own
    /// name, after the last slash, is what people read.
    static func parseModels(_ text: String) -> [AgentModel] {
        let plain = text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        var seen: Set<String> = []
        return plain.components(separatedBy: .newlines).compactMap { line in
            let id = line.trimmingCharacters(in: .whitespaces)
            guard id.contains("/"), id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._~:/-]*$"#, options: .regularExpression) != nil,
                  seen.insert(id).inserted else { return nil }
            return AgentModel(cli: "opencode", model: id, name: Self.modelName(id), about: "", efforts: [])
        }
    }

    /// "opencode/glm-5.3-flash" reads "GLM-5.3-Flash": the part after the
    /// provider, its dashes spaced, each word headed by a capital.
    static func modelName(_ id: String) -> String {
        let own = id.components(separatedBy: "/").last ?? id
        return own.components(separatedBy: ["-", "_"]).map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    typealias Identity = (signedIn: Bool, email: String?, plan: String?)
    private static var identities: [String: Identity] = [:]

    /// Passive reads reuse only the official CLI's verified public answer.
    /// `opencode auth list` names every provider with a stored credential;
    /// it prints no secret, and nothing here asks it to.
    static func identity(env: [String: String]) -> Identity {
        identities[identityKey(env)] ?? (false, nil, nil)
    }

    private static func identityKey(_ env: [String: String]) -> String {
        URL(fileURLWithPath: env["HOME"] ?? AgentSetup.home.path).standardizedFileURL.path
    }

    static func identify(binary: String, env: [String: String], permit: ProviderLaunchPermit? = nil) async -> Identity {
        guard let permit = permit ?? ProviderConsent.shared.permit("opencode") ?? ProviderConsent.shared.connectionPermit("opencode"), permit.valid else { return (false, nil, nil) }
        let key = identityKey(env)
        let result = await Shell.timed(binary, ["auth", "list"], env: environment(env), permit: permit)
        guard permit.valid else { return (false, nil, nil) }
        let who: Identity = (result.code == 0 && result.output.lowercased().contains("stored"), nil, nil)
        identities[key] = who
        if who.signedIn { await refresh(binary: binary, env: env, permit: permit) }
        guard permit.valid else { return (false, nil, nil) }
        return who
    }

    static func environment(_ base: [String: String]) -> [String: String] {
        let providerKeys = ["CLAUDE", "ANTHROPIC_", "CODEX_", "OPENAI_", "CURSOR_", "OPENCODE_"]
        return base.filter { key, _ in !providerKeys.contains(where: key.hasPrefix) }
    }

    /// One answer with no tools, for Yab's own helpers (PlanText): ACP, as
    /// a text command runs, in a room of the helper's own. OpenCode's ACP
    /// has no "ask" mode; a tool it wants is turned down instead. "" when
    /// it fails or takes past `limit`.
    static func once(binary: String, message: String, model: String? = nil, environment base: [String: String],
                     room: URL, limit: Double = 120, permit: ProviderLaunchPermit? = nil) async -> String {
        guard let permit, permit.valid else { return "" }
        try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        final class Heard { var answer = ""; var over = false; var buffer = Data() }
        let heard = Heard()
        let process = Process(), input = Pipe(), out = Pipe()
        // OpenCode's ACP takes no model flag: its session's own default runs.
        let args = ["acp"]
        Agents.throughShell(process, binary, args)
        process.environment = environment(base)
        process.currentDirectoryURL = room
        process.standardInput = input
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let writer = input.fileHandleForWriting
        let server = CursorServer(name: "OpenCode", askMode: nil) { try? writer.write(contentsOf: $0) }
        return await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            let finish = { (words: String) in
                guard !heard.over else { return }
                heard.over = true
                out.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { Shell.end(process, grace: 2) }
                done.resume(returning: words)
            }
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard !heard.over else { return }
                        if data.isEmpty { finish(""); return }
                        heard.buffer.append(data)
                        while let newline = heard.buffer.firstIndex(of: 0x0A) {
                            let line = Data(heard.buffer[..<newline])
                            heard.buffer.removeSubrange(...newline)
                            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                            for event in server.heard(message) {
                                switch event {
                                case .delta(_, let words, let thinking): if !thinking { heard.answer += words }
                                case .permission(let id, _, _, _): server.reply(id, option: nil)
                                case .ended: finish(heard.answer)
                                case .failed: finish("")
                                default: break
                                }
                            }
                        }
                    }
                }
            }
            do { guard try permit.start(process) else { finish(""); return } } catch { finish(""); return }
            server.open(thread: nil, cwd: room.path, mcp: [], textOnly: true)
            server.say(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                MainActor.assumeIsolated { finish("") }
            }
        }
    }

    static func unavailable(textOnly: Bool, unattended: Bool, fork: Bool) -> String? {
        if fork { return "OpenCode can't carry this chat into a new one. Start a new chat on your OpenCode plan." }
        return nil
    }
}
