import Foundation

// Yab's own helpers that write a few words on your plan, nobody asking each
// time (mail replies written ahead, a split's line, a split's rules, a post):
// one run with no tools, on the AI you connected, yours first, the other if
// yours fails. Claude Code with --tools "" and no MCP. Codex with your
// config, rules and every tool feature left out, read-only besides, so what
// a mail or a page says can't make it run, read or fetch anything: asked to
// read ~/.zshrc and fetch a page, codex-cli 0.157 answered "code-mode host
// is disabled" (2026-10-16). A run takes Codex about 5 s.

@MainActor
enum PlanText {
    /// The plans connected in Yab, yours first: the Chats default's plan
    /// (your provider, set at Connect), else Agents.preferred. Every plan
    /// writes them: Claude Code and Codex with no tools as below, Cursor in
    /// ACP's ask mode with every tool denied, Gemini as Yab's text agent.
    static var agents: [String] {
        let connected = AgentSetupModel.clis.filter { cli in
            AgentSetup.connected(cli) && (cli != "gemini" || GeminiSupport.toolsOffProven && GeminiAccount.shared.ready)
        }
        let yours = ModelDefaults.shared[.chats].cli
        return LinkFolders.order(preferred: yours.flatMap { connected.contains($0) ? $0 : nil } ?? Agents.preferred, connected: connected)
    }

    /// Whether any AI is connected to write with.
    static var any: Bool { !agents.isEmpty }

    /// Codex's features that give it tools, all off for a run of words.
    nonisolated static let codexOff = [
        "shell_tool", "unified_exec", "shell_snapshot", "code_mode_host", "browser_use", "browser_use_external",
        "computer_use", "in_app_browser", "view_image", "apps", "plugins", "multi_agent", "goals",
        "image_generation", "memories", "hooks", "skill_search", "sleep_tool", "tool_suggest", "chronicle",
    ]

    /// Codex's arguments for one run with no tools, the prompt last.
    nonisolated static func codexArgs(_ prompt: String, out: String, model: String?, effort: String) -> [String] {
        var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                    "-s", "read-only", "-c", #"web_search="disabled""#, "-c", "model_reasoning_effort=\"\(effort)\"", "-o", out]
        for feature in codexOff { args += ["--disable", feature] }
        if let model { args += ["-m", model] }
        return args + [prompt]
    }

    /// What the agent wrote, and which one wrote it; "" when none is
    /// connected, or none answered within `limit`. `claudeModel` names
    /// Claude's model; Codex runs its own at `codexEffort`, `codexModel`
    /// when given. `only` keeps to one agent.
    static func write(_ prompt: String, system: String, room: String, claudeModel: String = "sonnet",
                      codexModel: String? = nil, codexEffort: String = "low", limit: Double = 120,
                      only: String? = nil) async -> (text: String, cli: String?) {
        let permits = Dictionary(uniqueKeysWithValues: agents.compactMap { cli in ProviderConsent.shared.permit(cli).map { (cli, $0) } })
        return await write(prompt, system: system, room: room, claudeModel: claudeModel,
                           codexModel: codexModel, codexEffort: codexEffort, limit: limit,
                           agents: agents.filter { only == nil || $0 == only }, permits: permits)
    }

    /// Tidy is separately authorized. These permits never connect a provider
    /// for chat or background work, and use only the tool-free writer below.
    static func tidy(_ prompt: String, system: String, only: String) async -> (text: String, cli: String?) {
        _ = await Shell.find()
        let agents = TidyTabs.agents.filter { $0 == only }
        let permits = Dictionary(uniqueKeysWithValues: agents.map { cli in
            (cli, ProviderLaunchPermit.forTidy(cli))
        })
        return await write(prompt, system: system, room: "agent/tidy-tabs", claudeModel: "haiku",
                           codexModel: LinkFolders.codexModel, codexEffort: "low", limit: 45,
                           agents: agents, permits: permits)
    }

    private static func write(_ prompt: String, system: String, room: String, claudeModel: String,
                              codexModel: String?, codexEffort: String, limit: Double,
                              agents: [String], permits: [String: ProviderLaunchPermit]) async -> (text: String, cli: String?) {
        let found = await AgentLaunch.environment()
        let folder = Store.file(room)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for cli in agents {
            guard let permit = permits[cli], permit.valid else { continue }
            ConsentAudit.record("provider.helper")
            // The copy, account and environment a chat on it starts with.
            let launch = cli == "gemini" ? nil : AgentLaunch.resolve(cli, in: found)
            let env = launch?.env ?? found.env
            var text = ""
            if cli == "claude", let claude = launch?.binary {
                let ran = await Shell.timed("/bin/bash", ["-c", "exec \"$0\" \"$@\"", claude,
                    "-p", prompt, "--output-format", "json", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                    "--model", claudeModel, "--append-system-prompt", system,
                ], env: env, limit: limit, in: folder, permit: permit)
                text = (try? JSONSerialization.jsonObject(with: Data(ran.output.utf8)) as? [String: Any])?["result"] as? String ?? ""
            } else if cli == "codex", let codex = launch?.binary {
                let out = folder.appendingPathComponent("answer-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: out) }
                let args = codexArgs(system + "\n\n" + prompt, out: out.path, model: codexModel, effort: codexEffort)
                _ = await Shell.timed("/bin/bash", ["-c", "exec \"$0\" \"$@\" </dev/null", codex] + args, env: env, limit: limit, in: folder, permit: permit)
                text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            } else if cli == "gemini", let agy = found.gemini {
                text = await GeminiRunner.once(binary: agy, message: system + "\n\n" + prompt, environment: found.env,
                                               room: room.replacingOccurrences(of: "/", with: "-"), limit: limit, permit: permit)
            } else if cli == "cursor", let cursor = launch?.binary {
                text = await CursorRunner.once(binary: cursor, message: system + "\n\n" + prompt, environment: env,
                                               room: folder.appendingPathComponent("cursor", isDirectory: true), limit: limit, permit: permit)
            } else if cli == "opencode", let opencode = launch?.binary {
                text = await OpenCodeRunner.once(binary: opencode, message: system + "\n\n" + prompt, environment: env,
                                                 room: folder.appendingPathComponent("opencode", isDirectory: true), limit: limit, permit: permit)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, cli) }
        }
        return ("", nil)
    }
}

extension AgentSetupModel {
    /// Whether Claude or ChatGPT is connected to write Yab's own helpers'
    /// words (PlanText), as Settings shows it.
    var writes: Bool { !PlanText.agents.isEmpty }

    /// Who writes them, for the words that say so: "Claude", "ChatGPT",
    /// "Cursor" or "Gemini", yours first.
    var writer: String { Self.name(PlanText.agents.first ?? Agents.preferred) }
}

extension PlanText {
    /// "Claude" or "ChatGPT": who writes PlanText's words now.
    static var writer: String { AgentSetupModel.shared.writer }
}
