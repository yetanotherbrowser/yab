import Foundation
import Darwin

/// Sign-in only: no session/new, model prompt, filesystem or tool permissions.
/// agy owns the loopback callback and tokens; Yab owns the launcher and tab.
@MainActor
final class GeminiACP {
    enum State: Equatable { case initializing, loggingOut, authenticating, authenticated, unsupported, failed(String), stopped }
    private(set) var state: State = .initializing
    private(set) var url: URL?
    private(set) var stderr = ""
    var changed: (() -> Void)?
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var pending = Data()
    private var diagnostic = Data()
    private var discardingDiagnostic = false
    private var opening: Task<Void, Never>?
    private var pageWatch: DispatchSourceFileSystemObject?
    private var readers: [Int32: DispatchSourceRead] = [:]
    private var switching = false
    private var page: URL?
    private var requestID = 0
    private var method = ""

    func start(binary: String, environment: [String: String], cwd: URL, page: URL,
               switching: Bool, permit: ProviderLaunchPermit, openingLimit: TimeInterval = 15) throws {
        GeminiSignInLog.shared.begin()
        self.switching = switching
        self.page = page
        // This bounds opening the sign-in, not the person's Google consent.
        // A missing launcher callback must become an error, never a retry loop.
        try watchPage(page)
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["acp"]
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        watch(output, diagnostic: false)
        watch(errors, diagnostic: true)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Reads and exit share the main queue. Drain the final reply
                // before exit, without waiting for a descendant to close an
                // inherited pipe. No success/exit race and no silent wait.
                self.drain(self.errors, diagnostic: true)
                self.drain(self.output, diagnostic: false)
                self.exited(code)
            }
        }
        do {
            guard try permit.start(process) else { stop(); throw GeminiStream.Failure("Gemini sign-in was canceled.") }
        } catch {
            log(error.localizedDescription)
            stop()
            throw GeminiStream.Failure("Antigravity couldn't start Google's sign-in. Try again.")
        }
        // The parent must not keep the child's output pipes open itself.
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        request("initialize", params: ["protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]]])
        opening = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(openingLimit)) }
            catch { return }
            guard let self, self.active, self.url == nil else { return }
            self.fail("Google's sign-in page didn't open. Try again.", reason: "noPage")
        }
    }

    private func watchPage(_ page: URL) throws {
        // The launcher uses > page, preserving this inode. File events
        // observe its writes even when agy sends no stdout while waiting
        // for Google. No terminal parsing or repeated URL polling.
        try Data().write(to: page)
        let descriptor = Darwin.open(page.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw GeminiStream.Failure("Yab couldn't open Google's sign-in. Try again.") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.capturePage() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        pageWatch = source
        source.resume()
    }

    private func watch(_ pipe: Pipe, diagnostic: Bool) {
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain(pipe, diagnostic: diagnostic) }
        }
        readers[fd] = reader
        reader.resume()
    }

    private func drain(_ pipe: Pipe, diagnostic: Bool) {
        let fd = pipe.fileHandleForReading.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN { fail("Antigravity couldn't complete Google's sign-in. Try again.", reason: "read") }
                return
            }
            let data = Data(bytes.prefix(count))
            if diagnostic { receivedDiagnostic(data) } else { received(data) }
            if count == 0 { readers.removeValue(forKey: fd)?.cancel(); return }
        }
    }

    private var active: Bool {
        switch state { case .initializing, .loggingOut, .authenticating: return true; default: return false }
    }

    private func request(_ method: String, params: [String: Any]) {
        guard active else { return }
        self.method = method; requestID += 1
        GeminiSignInLog.shared.append("Request: " + method)
        do {
            var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID, "method": method, "params": params])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch { fail("Antigravity couldn't start Google's sign-in. Try again.", reason: "write") }
    }

    private func received(_ data: Data) {
        guard active else { return }
        if data.isEmpty {
            if !pending.isEmpty {
                if state == .initializing { unsupported() }
                else { fail("Antigravity sent an incomplete sign-in response. Try again.", reason: "protocol") }
            }
            return
        }
        pending.append(data)
        guard pending.count <= 1_048_576 else { fail("Antigravity sent an invalid sign-in response. Try again.", reason: "protocol"); return }
        while let end = pending.firstIndex(of: 10), active {
            let line = pending.prefix(upTo: end)
            pending.removeSubrange(...end)
            if line.isEmpty { continue }
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
                if state == .initializing { unsupported() }
                else { fail("Antigravity sent an invalid sign-in response. Try again.", reason: "protocol") }
                return
            }
            // No agent requests are authorized during sign-in. Notifications
            // carry no state; only the matching response may advance it.
            if let requested = message["method"] as? String {
                if let id = message["id"], let reply = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "Not available during sign-in: " + requested]]) {
                    try? input.fileHandleForWriting.write(contentsOf: reply + Data([10]))
                }
                continue
            }
            guard message["id"] as? Int == requestID else { continue }
            if let error = message["error"] as? [String: Any] {
                if state == .initializing { unsupported(); return }
                let code = error["code"] as? Int
                // Keep provider text in local diagnostics, not OAuth URLs or
                // credentials in the card/feedback. The RPC code is retained.
                log(error["message"] as? String ?? "Authentication error")
                fail(method == "logout" ? "Antigravity couldn't sign out of the current account. Try again."
                     : "Antigravity couldn't complete Google's sign-in. Try again.", reason: method, code: code)
                return
            }
            guard let result = message["result"] as? [String: Any] else {
                if state == .initializing { unsupported() }
                else { fail("Antigravity sent an invalid sign-in response. Try again.", reason: "protocol") }
                return
            }
            switch state {
            case .initializing:
                guard result["protocolVersion"] as? Int == 1 else { unsupported(); return }
                if let info = result["agentInfo"] as? [String: Any] {
                    GeminiSignInLog.shared.append("Agent: " + (info["name"] as? String ?? "agy") + " " + (info["version"] as? String ?? "unknown"))
                }
                let methods = result["authMethods"] as? [[String: Any]] ?? []
                guard methods.contains(where: { $0["id"] as? String == "oauth-personal" }) else {
                    fail("This Antigravity version doesn't offer Google sign-in. Update Antigravity CLI and try again.", reason: "method"); return
                }
                if switching {
                    let capabilities = result["agentCapabilities"] as? [String: Any]
                    let auth = capabilities?["auth"] as? [String: Any]
                    // ACP v1 advertises capabilities as objects, including {}.
                    guard auth?["logout"] as? [String: Any] != nil else {
                        fail("This Antigravity version can't switch Google accounts. Update Antigravity CLI and try again.", reason: "logoutUnavailable"); return
                    }
                    state = .loggingOut; request("logout", params: [:])
                } else { authenticate() }
            case .loggingOut: authenticate()
            case .authenticating:
                capturePage()
                state = .authenticated; GeminiSignInLog.shared.append("Authenticate completed")
                opening?.cancel(); pageWatch?.cancel(); pageWatch = nil
                changed?()
            default: break
            }
        }
    }

    private func authenticate() {
        state = .authenticating
        request("authenticate", params: ["methodId": "oauth-personal"])
        changed?()
    }

    private func capturePage() {
        guard url == nil, state == .authenticating, let page,
              let text = try? String(contentsOf: page, encoding: .utf8), text.hasSuffix("\n"),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), GeminiLogin.allowed(url) else { return }
        self.url = url
        opening?.cancel()
        changed?()
    }

    private func receivedDiagnostic(_ data: Data) {
        if data.isEmpty {
            if !diagnostic.isEmpty, !discardingDiagnostic { log(String(decoding: diagnostic, as: UTF8.self)) }
            diagnostic.removeAll(); discardingDiagnostic = false
            return
        }
        diagnostic.append(data)
        while let end = diagnostic.firstIndex(of: 10) {
            let line = diagnostic.prefix(upTo: end)
            if !discardingDiagnostic {
                log(line.count <= 8192 ? String(decoding: line, as: UTF8.self) : "Antigravity diagnostic line omitted because it was too long.")
            }
            discardingDiagnostic = false
            diagnostic.removeSubrange(...end)
        }
        if diagnostic.count > 8192 {
            // Never log pieces of one oversized line: a credential's key
            // could be in the discarded piece and its value in the next.
            if !discardingDiagnostic { log("Antigravity diagnostic line omitted because it was too long.") }
            discardingDiagnostic = true
            diagnostic.removeAll()
        }
    }

    private func log(_ line: String) {
        let safe = Self.redacted(line)
        stderr = String((stderr + safe + "\n").suffix(4000))
        NSLog("Gemini sign-in: %@", safe)
        GeminiSignInLog.shared.append(safe)
        // Keep the typed event free of provider text. The bounded, redacted
        // log goes with feedback only when Include diagnostics is selected.

    }

    nonisolated static func redacted(_ text: String) -> String {
        var result = GeminiIdentity.plain(text)
        for pattern in [#"https?://[^\s]+"#, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+"#, #"/(?:Users|private|var)/[^\s]+"#,
                        #"4/[A-Za-z0-9_-]{10,2048}"#,
                        #"(?i)(bearer\s+\S+|(?:access_token|refresh_token|id_token|code|state)[\s\"':=]+[^\s,}]+)"#] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(result.prefix(2000))
    }

    private func exited(_ exitCode: Int32) {
        guard active else { return }
        if state == .initializing { unsupported() }
        else { fail("Antigravity closed its sign-in. Try again.", reason: "exit", code: Int(exitCode)) }
    }

    private func unsupported() {
        state = .unsupported; GeminiSignInLog.shared.append("Initialize unsupported; using legacy sign-in")
        shutdown(); changed?()
    }

    private func fail(_ message: String, reason: String, code: Int? = nil) {
        guard active else { return }
        state = .failed(message)
        GeminiSignInLog.shared.append("Sign-in failed: " + reason + (code.map { " (\($0))" } ?? ""))
        FeedbackDiagnostics.shared.record(.geminiRequestFailed, code: code, word: "signin." + reason)
        shutdown(); changed?()
    }

    private func shutdown() {
        opening?.cancel(); opening = nil
        pageWatch?.cancel(); pageWatch = nil
        process.terminationHandler = nil
        for reader in readers.values { reader.cancel() }
        readers.removeAll()
        try? input.fileHandleForWriting.close()
        if process.isRunning { Shell.end(process, grace: 1) }
    }

    func stop() { state = .stopped; shutdown() }
}

/// Recent sign-in stderr is an attachment, not arbitrary text in the typed
/// diagnostics schema. It never includes tokens, OAuth URLs or emails and
/// expires after five minutes. No file or credentials are read for feedback.
@MainActor
final class GeminiSignInLog {
    static let shared = GeminiSignInLog()
    private let clock: () -> Date
    private var lines = ""
    private var updated = Date.distantPast
    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    func begin() { lines = ""; updated = clock() }
    func append(_ line: String) {
        updated = clock()
        lines = String((lines + GeminiACP.redacted(line) + "\n").suffix(8192))
    }
    var recent: Data? {
        guard !lines.isEmpty, (0...300).contains(clock().timeIntervalSince(updated)) else { return nil }
        return Data(lines.utf8)
    }
}

/// Probes `agy acp` for the structured model catalog (`model` and per-model
/// `thought_level` config options). Returns nil when the CLI doesn't speak ACP
/// configOptions so `GeminiAccount.look` can fall back to `agy models`.
enum GeminiACPModels {
    struct Entry: Equatable, Sendable {
        let id: String
        let name: String
        let efforts: [String]
    }

    nonisolated static func flattenSelectOptions(_ raw: Any?) -> [[String: Any]] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.flatMap { entry -> [[String: Any]] in
            if entry["value"] is String { return [entry] }
            return entry["options"] as? [[String: Any]] ?? []
        }
    }

    nonisolated static func modelConfig(in options: [[String: Any]]) -> [String: Any]? {
        options.first { ($0["category"] as? String == "model" || $0["id"] as? String == "model") && $0["type"] as? String == "select" }
    }

    nonisolated static func thoughtLevels(in options: [[String: Any]]) -> [String] {
        guard let option = options.first(where: {
            ($0["category"] as? String == "thought_level" || $0["id"] as? String == "thought_level") && $0["type"] as? String == "select"
        }) else { return [] }
        var seen = Set<String>()
        return flattenSelectOptions(option["options"]).compactMap { entry in
            guard let value = entry["value"] as? String, !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    nonisolated static func geminiOptions(in modelConfig: [String: Any]) -> [(id: String, name: String)] {
        var seen = Set<String>()
        return flattenSelectOptions(modelConfig["options"]).compactMap { entry in
            guard let id = entry["value"] as? String, id.hasPrefix("gemini-"), id.count > 7,
                  seen.insert(id).inserted else { return nil }
            let rawName = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (id, rawName.isEmpty ? GeminiSupport.title(id) : rawName)
        }
    }

    static func probe(binary: String, env: [String: String], cwd: URL, limit: TimeInterval,
                      permit: ProviderLaunchPermit) async -> [Entry]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(binary: binary, env: env, cwd: cwd, limit: limit, permit: permit))
            }
        }
    }

    private nonisolated static func run(binary: String, env: [String: String], cwd: URL, limit: TimeInterval,
                                        permit: ProviderLaunchPermit) -> [Entry]? {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = ProcessLaunch.executableURL(binary)
        process.arguments = ["acp"]
        process.environment = env
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        guard (try? permit.start(process)) == true else { return nil }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            if process.isRunning { Shell.end(process, grace: 1) }
        }

        // Drain stderr so the child can never block on a full pipe.
        DispatchQueue.global(qos: .utility).async {
            let handle = errors.fileHandleForReading
            while (try? handle.read(upToCount: 4096))?.isEmpty == false {}
        }

        let deadline = Date().addingTimeInterval(max(1, limit))
        var requestID = 0
        var buffer = Data()
        let outFD = output.fileHandleForReading.fileDescriptor

        func writeJSON(_ object: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data); return true }
            catch { return false }
        }

        func readLine() -> Data? {
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    if line.isEmpty { continue }
                    return line
                }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 || !permit.valid { return nil }
                var pfd = pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(min(remaining * 1000, 500)))
                if ready < 0 { if errno == EINTR { continue }; return nil }
                if ready == 0 { continue }
                var chunk = [UInt8](repeating: 0, count: 16_384)
                let count = chunk.withUnsafeMutableBytes { Darwin.read(outFD, $0.baseAddress, $0.count) }
                if count <= 0 {
                    if count < 0 && errno == EINTR { continue }
                    return nil
                }
                buffer.append(contentsOf: chunk.prefix(count))
                if buffer.count > 1_048_576 { return nil }
            }
        }

        func call(_ method: String, params: [String: Any]) -> (result: [String: Any], updatedConfig: [[String: Any]]?)? {
            requestID += 1
            let wanted = requestID
            guard writeJSON(["jsonrpc": "2.0", "id": wanted, "method": method, "params": params]) else { return nil }
            var updatedConfig: [[String: Any]]?
            while let line = readLine() {
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["jsonrpc"] as? String == "2.0" else { return nil }
                if let requested = message["method"] as? String {
                    if let id = message["id"] {
                        _ = writeJSON(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not available during model probe: " + requested]])
                    } else if requested == "session/update",
                              let params = message["params"] as? [String: Any],
                              let update = params["update"] as? [String: Any],
                              update["sessionUpdate"] as? String == "config_option_update",
                              let opts = update["configOptions"] as? [[String: Any]] {
                        updatedConfig = opts
                    }
                    continue
                }
                guard message["id"] as? Int == wanted else { continue }
                if message["error"] != nil { return nil }
                guard let result = message["result"] as? [String: Any] else { return nil }
                return (result, updatedConfig)
            }
            return nil
        }

        guard let initReply = call("initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ]), initReply.result["protocolVersion"] as? Int == 1 else { return nil }

        guard let sessionReply = call("session/new", params: ["cwd": cwd.path, "mcpServers": [Any]()]),
              let sessionId = sessionReply.result["sessionId"] as? String, !sessionId.isEmpty,
              let configOptions = sessionReply.result["configOptions"] as? [[String: Any]],
              let modelOpt = modelConfig(in: configOptions) else { return nil }

        let listed = geminiOptions(in: modelOpt)
        guard !listed.isEmpty else { return nil }

        let modelConfigId = modelOpt["id"] as? String ?? "model"
        let currentModel = modelOpt["currentValue"] as? String
        var entries: [Entry] = []
        for item in listed {
            if item.id == currentModel {
                entries.append(Entry(id: item.id, name: item.name, efforts: thoughtLevels(in: configOptions)))
                continue
            }
            guard let switched = call("session/set_config_option", params: [
                "sessionId": sessionId,
                "configId": modelConfigId,
                "value": item.id,
            ]) else {
                guard permit.valid, deadline.timeIntervalSinceNow > 0 else { return nil }
                entries.append(Entry(id: item.id, name: item.name, efforts: GeminiModels.efforts))
                continue
            }
            let updated = switched.result["configOptions"] as? [[String: Any]] ?? switched.updatedConfig ?? []
            entries.append(Entry(id: item.id, name: item.name, efforts: thoughtLevels(in: updated)))
        }
        return entries
    }
}
