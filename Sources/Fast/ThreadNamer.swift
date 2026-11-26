import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Who names a day's thread (docs/day-threads.md): the cheap model of the AI
// you connected in Yab, yours first (Claude's Haiku kept warm, Codex's fast
// one at low effort), as ⌘-click folders are named (LinkFolders); Apple
// Intelligence on the Mac only when none is connected or none answers;
// otherwise the name its pages' titles give (DayThreads.fallbackName) and no
// line. No tools: a page's title can say anything (PlanText).
//
// A test world asks none of them unless told: YAB_THREAD_AGENTS names the
// plans to ask, YAB_THREAD_MAC=1 lets the Mac's model answer, and
// YAB_THREAD_STAND stands in for every answer ("Topic|Doing|Done|Line").

@MainActor
final class ThreadNamer {
    static let shared = ThreadNamer()

    /// Names asked for and answered, for the bench.
    private(set) var asked = 0
    private(set) var answered = 0
    private(set) var by: [String: Int] = [:]

    private lazy var claude = WarmClaude(room: "agent/thread-names", idle: 300, turns: 40, env: ["MAX_THINKING_TOKENS": "0"]) {
        ["--model", "haiku", "--settings", #"{"alwaysThinkingEnabled":false}"#, "--append-system-prompt", DayThreads.instructions
            + "\n" + DayThreads.lines + "\nEach message is a new stretch of browsing, unrelated to the ones before."]
    }

    /// The thread's four lines from the first that answers, or nil.
    func name(_ prompt: String, done: @escaping (DayThreads.Naming?) -> Void) {
        asked += 1
        Task { @MainActor in
            let naming = await self.naming(prompt)
            if naming != nil { self.answered += 1 }
            done(naming)
        }
    }

    private func naming(_ prompt: String) async -> DayThreads.Naming? {
        if let stand {
            let parts = stand.components(separatedBy: "|")
            by["stand", default: 0] += 1
            return DayThreads.Naming(topic: parts[0], doing: parts.count > 1 ? parts[1] : parts[0],
                                     done: parts.count > 2 ? parts[2] : parts[0], line: parts.count > 3 ? parts[3] : "")
        }
        for cli in agents {
            if let said = await agent(cli, prompt), let naming = DayThreads.naming(said) {
                by[cli, default: 0] += 1
                return naming
            }
        }
        guard macAllowed, let naming = await ThreadNamer.mac(prompt) else { return nil }
        by["mac", default: 0] += 1
        return naming
    }

    /// The AI you connected, yours first; in a test world only those named.
    private var agents: [String] {
        guard Store.testing else {
            return LinkFolders.order(preferred: Agents.preferred, connected: ["claude", "codex"].filter(AgentSetup.connected))
        }
        return (ProcessInfo.processInfo.environment["YAB_THREAD_AGENTS"] ?? "").split(separator: ",").map(String.init)
            .filter(["claude", "codex"].contains)
    }

    private var macAllowed: Bool {
        FormModel.ready && (!Store.testing || ProcessInfo.processInfo.environment["YAB_THREAD_MAC"] == "1")
    }

    private var stand: String? {
        Store.testing ? ProcessInfo.processInfo.environment["YAB_THREAD_STAND"].flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    private func agent(_ cli: String, _ prompt: String) async -> String? {
        if cli == "claude" { return await claude.ask(prompt, within: 40) }
        guard cli == "codex" else { return nil }
        guard let permit = ProviderConsent.shared.permit("codex") else { return nil }
        let found = await AgentLaunch.environment()
        guard permit.valid, let launch = AgentLaunch.resolve(cli, in: found) else { return nil }
        let codex = launch.binary
        let room = Store.file("agent/thread-names")
        try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        let env = launch.env
        let out = room.appendingPathComponent("name-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = PlanText.codexArgs(DayThreads.instructions + "\n" + DayThreads.lines + "\n\n" + prompt, out: out.path, model: LinkFolders.codexModel, effort: "low")
        _ = await Shell.timed("/bin/bash", ["-c", "exec \"$0\" \"$@\" </dev/null", codex] + args, env: env, limit: 60, in: room, permit: permit)
        return try? String(contentsOf: out, encoding: .utf8)
    }

    nonisolated static func mac(_ prompt: String) async -> DayThreads.Naming? {
        guard FormModel.ready else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: DayThreads.instructions)
            guard let answer = try? await session.respond(to: String(prompt.prefix(3_000)), generating: ThreadNaming.self,
                                                          options: GenerationOptions(sampling: .greedy)) else { return nil }
            let said = "Topic: \(answer.content.topic)\nDoing: \(answer.content.doing)\nDone: \(answer.content.done)\nLine: \(answer.content.line)"
            return DayThreads.naming(said)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct ThreadNaming {
    @Guide(description: "Two to four words, a noun phrase naming what the pages were about")
    var topic: String
    @Guide(description: "What the person was doing, starting with a verb ending in -ing, three to seven words")
    var doing: String
    @Guide(description: "The same in the past tense")
    var done: String
    @Guide(description: "One plain sentence of what happened or what they found, only facts the pages show")
    var line: String
}
#endif
