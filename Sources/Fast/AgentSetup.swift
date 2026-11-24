import Foundation
import Security

// Putting yab where agents look for it: the `yab` command on the PATH, a
// skill in Claude Code and in Codex that says "run `yab guide`", and yab's
// tools in each as an MCP server. One click in Settings › Agents, or
// `yab setup`, and taken back the same way, removing only what was put.
//
// Everything here is a file written or a CLI asked, so it runs as well from
// the command line with no browser open as from the settings page. Status is
// read from the files alone, without starting anything, so the page can ask
// as often as it draws.

enum AgentSetup {
    /// The development build answers to its own names everywhere, so trying
    /// it never overwrites the yab someone uses.
    static var command: String { Store.development ? "yab-dev" : "yab" }
    /// One name for the skill and the MCP server, with "browser" in it: an
    /// agent often sees only names (a skill's in its list, a deferred tool's
    /// mcp__yab-browser__click) and "yab" alone tells it nothing.
    static var skill: String { command + "-browser" }
    static var server: String { skill }

    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    /// HOME first, so a test can point all of it at a folder of its own.
    static var home: URL {
        if AgentFixture.requested {
            return AgentFixture.discovery()?.env["HOME"].map { URL(fileURLWithPath: $0) } ?? Store.file("invalid-agent-fixture-home")
        }
        if let set = ProcessInfo.processInfo.environment["HOME"], !set.isEmpty { return URL(fileURLWithPath: set) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The account's own home, whatever HOME says.
    private static var realHome: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    /// Whether this copy may put itself where agents look. Everything written
    /// names this binary, so only an app someone keeps may: yab in
    /// /Applications or ~/Applications, signed by its team, and yab Dev in
    /// its bundle wherever it was built, under names of its own. Never a bare
    /// binary or a copy in a temporary folder, a test run however it was
    /// started: one renamed into a scratch folder took the yab command for
    /// itself and left it naming a file that was gone. A HOME of a test's
    /// own takes anything, since nothing real is written there.
    static var mayInstall: Bool {
        if home.standardizedFileURL.path != URL(fileURLWithPath: realHome).standardizedFileURL.path { return true }
        // A test world keeps to itself, even from inside an app bundle: a
        // probe with YAB_PROBE set, launched with the real HOME, still
        // rewrote the command every time it opened.
        if Store.testing { return false }
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard path.contains(".app/Contents/MacOS/") else { return false }
        if ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"].contains(where: { path.hasPrefix($0) }) { return false }
        if Store.development { return true }
        guard ["/Applications/", realHome + "/Applications/"].contains(where: { path.hasPrefix($0) }) else { return false }
        return signedByTeam
    }

    /// Signed with a team's certificate rather than ad hoc.
    private static var signedByTeam: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return false }
        return (info[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }

    /// What a copy that may not install says instead.
    static let notInstalled = "This copy of Yab isn't an installed app, so it doesn't put itself where agents look."

    static var shim: URL { home.appendingPathComponent(".local/bin/\(command)") }
    static var claudeSkill: URL { home.appendingPathComponent(".claude/skills/\(skill)/SKILL.md") }
    static var claudeConfig: URL { home.appendingPathComponent(".claude.json") }
    /// Codex reads skills from here, shared with other agents that follow
    /// the same convention.
    static var codexSkill: URL { home.appendingPathComponent(".agents/skills/\(skill)/SKILL.md") }
    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    private static let mark = "# Put here by yab › Settings › Agents; remove it there."

    // MARK: - status

    struct Status: Equatable {
        var command = false
        var claude = false
        var codex = false
        var cursor = false
        var opencode = false
        /// GeminiAccount owns Google sign-in separately from skill installation.
        var gemini = false
        /// The skills on disk say other than this build's: older, or worded
        /// before a change that kept the version, as the name's capital.
        var stale = false
    }

    static func status() -> Status {
        var status = Status()
        status.cursor = CursorRunner.connected
        status.opencode = OpenCodeRunner.connected
        status.command = (try? String(contentsOf: shim, encoding: .utf8))?.contains("\"\(executable)\"") == true
        let claudeServer = (readJSON(claudeConfig)?["mcpServers"] as? [String: Any])?[server] as? [String: Any]
        status.claude = FileManager.default.fileExists(atPath: claudeSkill.path) && claudeServer?["command"] as? String == executable
        let toml = ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        status.codex = FileManager.default.fileExists(atPath: codexSkill.path)
            && section(in: toml).map { toml[$0].contains { $0.contains("\"\(executable)\"") } } == true
        status.stale = [claudeSkill, codexSkill].contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text != skillText + "\n"
        }
        return status
    }

    /// Where each piece stands, for Settings › Developers: there or not,
    /// this copy's or another's, and what one button there would put right.
    struct Pieces: Equatable {
        enum Command: Equatable { case missing, ours, otherCopy, foreign }
        enum Agent: Equatable { case missing, ours, stale, otherCopy }
        var command = Command.missing
        /// Our line in the shell's file, which puts the command's folder on
        /// the PATH of new terminals.
        var pathLine = false
        var claude = Agent.missing
        var codex = Agent.missing
    }

    static func pieces() -> Pieces {
        var pieces = Pieces()
        if let text = try? String(contentsOf: shim, encoding: .utf8) {
            pieces.command = !text.contains(mark) ? .foreign : text.contains("\"\(executable)\"") ? .ours : .otherCopy
        }
        if let file = shellFile(ProcessInfo.processInfo.environment["SHELL"]) {
            pieces.pathLine = (try? String(contentsOf: file, encoding: .utf8))?.contains(pathLine) == true
        }
        func skill(_ url: URL) -> (there: Bool, stale: Bool) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (false, false) }
            return (true, text != skillText + "\n")
        }
        // Claude Code's tools: this binary, another yab's, or none.
        let claudeCommand = ((readJSON(claudeConfig)?["mcpServers"] as? [String: Any])?[server] as? [String: Any])?["command"] as? String
        let claudeSkill = skill(Self.claudeSkill)
        if claudeCommand == executable, claudeSkill.there { pieces.claude = claudeSkill.stale ? .stale : .ours }
        else if let claudeCommand, ours(claudeCommand) { pieces.claude = .otherCopy }
        let toml = ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let codexSkill = skill(Self.codexSkill)
        if let table = section(in: toml) {
            if toml[table].contains(where: { $0.contains("\"\(executable)\"") }), codexSkill.there { pieces.codex = codexSkill.stale ? .stale : .ours }
            else if toml[table].contains(where: ours) { pieces.codex = .otherCopy }
        }
        return pieces
    }

    /// `pieces()` off the main thread, for the same reason as `read()`.
    static func readPieces() async -> Pieces {
        await Task.detached(priority: .userInitiated) { pieces() }.value
    }

    /// What another MCP client (Cursor, Zed, Windsurf) is given to find
    /// Yab's tools: this binary, told to serve them.
    static var mcpConfig: String {
        let config: [String: Any] = ["mcpServers": [server: ["command": executable, "args": ["mcp"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `status()` off the main thread: a heavy user's ~/.claude.json runs
    /// to megabytes, tens of milliseconds to parse, and Connect reads it
    /// while its ring turns.
    /// You connected it in Yab: its skill is in place. Only then do Yab's
    /// own helpers that nobody asks each time (form drafts, mail replies
    /// written ahead) run that agent; a file looked at, nothing run.
    @MainActor
    static func connected(_ cli: String) -> Bool { ProviderConsent.shared.allows(cli) }

    static func read() async -> Status {
        await Task.detached(priority: .userInitiated) { status() }.value
    }

    /// Whether a shell would find the command: its folder on the PATH given.
    static func onPath(_ path: String?) -> Bool {
        let folder = shim.deletingLastPathComponent().path
        return (path ?? "").split(separator: ":").contains { $0 == folder || $0 == folder + "/" }
    }

    // MARK: - the command

    /// A two-line script rather than a link: run through a link, the binary
    /// would not know it is inside yab.app, whose bundle says which yab it
    /// is and so which socket to speak to.
    static func installCommand() -> String? {
        guard mayInstall else { return notInstalled }
        let body = Self.shimBody
        do {
            if let existing = try? String(contentsOf: shim, encoding: .utf8), !existing.contains(mark) {
                return "\(shim.path) is someone else's, left as it is."
            }
            try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            for name in retired.commands {
                let old = shim.deletingLastPathComponent().appendingPathComponent(name)
                if (try? String(contentsOf: old, encoding: .utf8))?.contains("# Put here by Fast › Settings › Agents") == true {
                    try? FileManager.default.removeItem(at: old)
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// YAB_CLI says this launch is the command's: with no words, or with
    /// ones it doesn't know, it answers in the terminal rather than opening
    /// a second browser.
    static var shimBody: String { """
    #!/bin/sh
    \(mark)
    YAB_CLI=1 exec "\(executable)" "$@"

    """ }

    /// A command put there by an older yab, rewritten the way this one writes it;
    /// one put there under an older name, as Fast's `fast`, put under this one.
    static func refreshCommand() {
        guard mayInstall else { return }
        guard let existing = try? String(contentsOf: shim, encoding: .utf8) else {
            let folder = shim.deletingLastPathComponent()
            if retired.commands.contains(where: { name in
                (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).map { $0.contains("# Put here by Fast › Settings › Agents") && ours($0) } == true
            }) { _ = installCommand() }
            return
        }
        guard existing.contains(mark), existing != shimBody else { return }
        try? shimBody.write(to: shim, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    }

    static func removeCommand() {
        removePathLine()
        guard let existing = try? String(contentsOf: shim, encoding: .utf8), existing.contains(mark) else { return }
        try? FileManager.default.removeItem(at: shim)
    }

    // MARK: - the PATH

    /// The file a new terminal of this shell reads, where a line can put
    /// the command's folder on the PATH: zsh's and bash's; other shells
    /// are left to the person.
    static func shellFile(_ shell: String?) -> URL? {
        switch URL(fileURLWithPath: shell ?? "/bin/zsh").lastPathComponent {
        case "zsh": return home.appendingPathComponent(".zshrc")
        case "bash": return home.appendingPathComponent(".bash_profile")
        default: return nil
        }
    }

    static var pathLine: String { "export PATH=\"$HOME/.local/bin:$PATH\" \(mark)" }

    /// The command's folder on the PATH of every new terminal, when the
    /// login shell's PATH doesn't have it yet: one line, marked as ours, at
    /// the end of the shell's file.
    static func addPathLine(_ found: Shell.Found) -> String? {
        guard mayInstall, !onPath(found.env["PATH"]), let file = shellFile(ProcessInfo.processInfo.environment["SHELL"]) else { return nil }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard let added = withPathLine(text) else { return nil }
        return writeLines(added.components(separatedBy: "\n"), file)
    }

    /// Our line taken out of whichever file has it, every other line kept.
    static func removePathLine() {
        for file in [shellFile("zsh"), shellFile("bash")].compactMap({ $0 }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(mark) else { continue }
            _ = writeLines(withoutPathLine(text).components(separatedBy: "\n"), file)
        }
    }

    /// A shell file's text with our line at its end, after a blank one;
    /// nil when it has it already.
    static func withPathLine(_ text: String) -> String? {
        guard !text.contains(mark) else { return nil }
        if text.isEmpty { return pathLine + "\n" }
        return (text.hasSuffix("\n") ? text : text + "\n") + "\n" + pathLine + "\n"
    }

    /// The text as it was before withPathLine: our line and the blank one
    /// put before it gone.
    static func withoutPathLine(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { $0.contains(mark) && $0.contains("PATH") }) else { return text }
        lines.remove(at: at)
        if at > 0, lines[at - 1].isEmpty, at == lines.count || lines[at].isEmpty { lines.remove(at: at - 1) }
        return lines.joined(separator: "\n")
    }

    // MARK: - the skill

    static var skillText: String { """
    ---
    name: \(skill)
    version: \(Guide.skillVersion)
    description: Use Yab on this Mac for browser tasks that need the user's signed-in sites, an explicitly selected tab, browsing history or Yab settings. Supports delegated tasks and direct browser tools.
    ---

    # Yab

    Work in agent tabs so the user can keep browsing. Use a user's existing tab only when they
    explicitly ask to work there. A site name alone is not permission to take over their tab.

    Choose how to work:

    - **Delegate a task** when you want a result from Yab's agent:
      `\(command) "Find the unread message from Alex in Slack and summarize it" --access browser`.
      This starts a separate AI run using the plan selected in Yab.
    - **Drive tabs yourself** with the \(server) MCP tools: `open`, `snapshot`, `click`, `type`.
      Read `\(command) guide mcp` for the workflow and the offered schemas for exact arguments.
    - **Use a shell without MCP**: `\(command) exec 'const t = open("https://example.com"); return t.snapshot()'`.
      Exec runs browser tools directly, without another model. `exec --help` lists its limits.

    A delegated task prints `session <id>`, progress and its answer. Exit 3 means it needs the user:
    tell them what is waiting. For a question, ask them, then run
    `\(command) session resume SESSION_ID "their answer"`. Sign-ins and approvals may need Yab.
    `session list` finds task ids; `session steer SESSION_ID "new direction"` redirects a task;
    `session stop SESSION_ID` stops it. Keep the user informed while a task runs.

    Use `--access browser` for website work. Request `--access full` only when files or the terminal
    are needed, with full file paths. Use `--no-person` only when nobody can answer requests.

    Read a snapshot before acting; don't guess refs. Read the site's skill when offered.
    Only send, post, pay or delete when asked. Respect refusals. Use `sign_in` for saved passwords;
    hand captchas and sign-ins you cannot complete to the user with `handoff`.
    Control Yab through its tools, not Computer Use, AppleScript or desktop keystrokes.

    For Yab settings, inspect `native_context` and `native_actions`, then use a listed action with
    `native_apply`. Use `\(command) guide` for more examples and `\(command) guide setup` for setup.
    If the command is missing, the user can install it in Settings › Developers.
    If agents are disabled, ask the user to enable Let agents use Yab there.
    """ }

    private static func writeSkill(_ url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (skillText + "\n").write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func removeSkill(_ url: URL) {
        guard (try? String(contentsOf: url, encoding: .utf8))?.contains("name: \(skill)\n") == true else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Only the skill files, newer: what an update does quietly for someone
    /// who set up before.
    static func refreshSkills() {
        guard mayInstall else { return }
        refreshCommand()
        let now = status()
        // A Codex table from before its tools were let through: written again.
        let toml = ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if now.codex, let ours = section(in: toml), !toml[ours].contains(where: { $0.contains("default_tools_approval_mode") }) { _ = addCodex() }
        // Set up by an older build, under an older name: set up again under
        // this one, which takes the old away.
        if !now.codex, retired.servers.contains(where: { name in
            section(in: toml, named: name).map { toml[$0].contains(where: ours) } == true
        }) { _ = addCodex() }
        // Claude Code's own config is moved only by its CLI, which never
        // runs at launch: that waits for a task's start (moveRetiredClaude).
        guard now.stale else { return }
        if now.claude || FileManager.default.fileExists(atPath: claudeSkill.path) { _ = writeSkill(claudeSkill) }
        if now.codex || FileManager.default.fileExists(atPath: codexSkill.path) { _ = writeSkill(codexSkill) }
    }

    // MARK: - Claude Code

    @MainActor private static var movedRetired = false

    /// Set up by an older build under an older name: set up again under
    /// this one, which takes the old away. Claude Code's CLI does it, so
    /// only as a task you asked for starts, never by itself.
    @MainActor static func moveRetiredClaude(_ found: Shell.Found, permit: ProviderLaunchPermit? = nil) async {
        guard let permit = permit ?? ProviderConsent.shared.permit("claude"), permit.valid else { return }
        guard !movedRetired, mayInstall, found.claude != nil else { return }
        movedRetired = true
        let stale = await Task.detached(priority: .utility) { !status().claude && !retiredClaudeServers().isEmpty }.value
        guard permit.valid else { movedRetired = false; return }
        if stale { _ = await addClaude(found, permit: permit) }
    }

    /// Its own CLI keeps its config; asked rather than written behind its back.
    static var localClaudeSetupArguments: [[String]] {
        ([server] + retired.servers).map { ["mcp", "remove", "--scope", "user", $0] }
            + [["mcp", "add", "--scope", "user", server, "--", executable, "mcp"]]
    }
    static func addClaude(_ found: Shell.Found, permit: ProviderLaunchPermit? = nil, localSetup: LocalAgentSetupPermit? = nil) async -> String? {
        guard let claude = found.claude else { return "Claude Code isn't installed." }
        // A caller retains its original Connect attempt. Local registration
        // uses only its narrower permit and never borrows account authority.
        let permit = localSetup == nil ? permit : nil
        guard localSetup?.valid == true || permit?.valid == true else { return ProviderConsent.refusal }
        guard mayInstall else { return notInstalled }
        if let trouble = ProviderLaunchPermit.atomic({
            guard localSetup?.valid == true || permit?.valid == true else { return ProviderConsent.refusal }
            return writeSkill(claudeSkill)
        }) { return trouble }
        // Whatever an older yab, or a yab elsewhere, put under this name.
        _ = await Shell.run(claude, ["mcp", "remove", "--scope", "user", server], env: found.env, permit: permit, localSetup: localSetup)
        let (code, _) = await Shell.run(claude, ["mcp", "add", "--scope", "user", server, "--", executable, "mcp"], env: found.env, permit: permit, localSetup: localSetup)
        guard localSetup?.valid == true || permit?.valid == true else { return ProviderConsent.refusal }
        guard code == 0 else { return "Claude Code didn't take Yab's tools (claude mcp add failed)." }
        for name in retiredClaudeServers() {
            _ = await Shell.run(claude, ["mcp", "remove", "--scope", "user", name], env: found.env, permit: permit, localSetup: localSetup)
        }
        guard localSetup?.valid == true || permit?.valid == true else { return ProviderConsent.refusal }
        ProviderLaunchPermit.atomic {
            if localSetup?.valid == true || permit?.valid == true { retireSkills() }
        }
        return nil
    }

    static func removeClaude(_ found: Shell.Found, disconnect: ProviderDisconnectPermit? = nil) async {
        if let disconnect { guard disconnect.commit({ removeSkill(claudeSkill) }) else { return } }
        else { removeSkill(claudeSkill) }
        if let claude = found.claude {
            _ = await Shell.run(claude, ["mcp", "remove", "--scope", "user", server], env: found.env,
                                disconnect: disconnect?.bound(to: claude))
        }
    }

    // MARK: - Codex

    /// Its config is TOML the person edits by hand too: only our table is
    /// touched, every other line kept as it was.
    static func addCodex() -> String? {
        guard mayInstall else { return notInstalled }
        if let trouble = writeSkill(codexSkill) { return trouble }
        var lines = ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        for name in retired.servers {
            if let range = section(in: lines, named: name), lines[range].contains(where: { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("command") && ours(line)
            }) { lines.removeSubrange(range) }
        }
        retireSkills()
        let table = [
            "[mcp_servers.\(server)]",
            "command = \"\(executable)\"",
            "args = [\"mcp\"]",
            "tool_timeout_sec = 900",
            // Without it Codex asks before every tool of ours, and refuses
            // them all when it may not ask (approval_policy = "never").
            "default_tools_approval_mode = \"approve\"",
        ]
        if let range = section(in: lines) {
            lines.replaceSubrange(range, with: table + [""])
        } else {
            while lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += table + [""]
        }
        return writeLines(lines, codexConfig)
    }

    static func removeCodex() {
        removeSkill(codexSkill)
        guard var lines = (try? String(contentsOf: codexConfig, encoding: .utf8))?.components(separatedBy: "\n"),
              let range = section(in: lines) else { return }
        lines.removeSubrange(range)
        _ = writeLines(lines, codexConfig)
    }

    /// Our table's lines: its header, and everything up to the next table
    /// that isn't one of its own (`[mcp_servers.yab-browser.env]` is).
    private static func section(in lines: [String], named name: String = server) -> Range<Int>? {
        // However it is written: bare or quoted, and a line of a file saved
        // with Windows line ends.
        let names = [name, "\"\(name)\""]
        func clean(_ line: String) -> String { line.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let start = lines.firstIndex(where: { line in names.contains { clean(line) == "[mcp_servers.\($0)]" } }) else { return nil }
        var end = start + 1
        while end < lines.count {
            let line = clean(lines[end])
            if line.hasPrefix("["), !names.contains(where: { line.hasPrefix("[mcp_servers.\($0).") }) { break }
            end += 1
        }
        // A comment that heads the next table is that table's, not ours.
        while end > start + 1, clean(lines[end - 1]).hasPrefix("#") { end -= 1 }
        return start..<end
    }

    private static func writeLines(_ lines: [String], _ url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - what older builds put

    /// Names older builds put where agents look: Fast's, before it was yab,
    /// and yab's MCP server before it took the skill's name. Taken away when
    /// this one sets up, so an agent isn't offered two browsers, and only
    /// where they name a Fast or a yab app.
    private static var retired: (servers: [String], skills: [String], commands: [String]) {
        Store.development
            ? (["yab-dev", "fast-dev"], ["fast-dev-browser"], ["fast-dev"])
            : (["yab", "fast"], ["fast-browser"], ["fast"])
    }

    /// A line or a command that names a Fast or a yab app's own binary.
    private static func ours(_ text: String) -> Bool {
        guard let range = text.range(of: ".app/Contents/MacOS/") else { return false }
        let binary = text[range.upperBound...].prefix { $0 != "\"" }
        return ["Fast", "yab"].contains(String(binary))
    }

    /// The retired servers in Claude Code's config that are ours.
    private static func retiredClaudeServers() -> [String] {
        let servers = readJSON(claudeConfig)?["mcpServers"] as? [String: Any] ?? [:]
        return retired.servers.filter { name in
            ((servers[name] as? [String: Any])?["command"] as? String).map(ours) == true
        }
    }

    private static func retireSkills() {
        for name in retired.skills {
            for root in [".claude/skills", ".agents/skills"] {
                let file = home.appendingPathComponent("\(root)/\(name)/SKILL.md")
                guard (try? String(contentsOf: file, encoding: .utf8))?.contains("name: \(name)\n") == true else { continue }
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            }
        }
    }

    // MARK: - all at once

    /// What Set Up does: the command, and every agent found. The troubles,
    /// one line each, or none.
    static func setUp(_ found: Shell.Found, only: Set<String>? = nil, localSetup: LocalAgentSetupPermit? = nil,
                      permits: [String: ProviderLaunchPermit]? = nil) async -> [String] {
        var troubles: [String] = []
        guard mayInstall else { return [notInstalled] }
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }
        if wanted("command"), let trouble = ProviderLaunchPermit.atomic({
            guard permits == nil || permits?.values.contains(where: { $0.valid }) == true else { return ProviderConsent.refusal }
            return installCommand() ?? addPathLine(found)
        }) { troubles.append(trouble) }
        if wanted("claude"), found.claude != nil || only != nil,
           let trouble = await addClaude(found, permit: permits?["claude"], localSetup: localSetup) { troubles.append(trouble) }
        if wanted("codex"), found.codex != nil || only != nil {
            if found.codex == nil { troubles.append("Codex isn't installed.") }
            else if let trouble = ProviderLaunchPermit.atomic({
                guard permits == nil || permits?["codex"]?.valid == true else { return ProviderConsent.refusal }
                return addCodex()
            }) { troubles.append(trouble) }
        }
        if wanted("cursor"), found.cursor != nil || only != nil {
            if found.cursor == nil { troubles.append("Cursor isn't installed.") }
            else { ProviderLaunchPermit.atomic {
                if permits == nil || permits?["cursor"]?.valid == true { Store.settings.set(true, forKey: CursorRunner.connectionKey) }
                else { troubles.append(ProviderConsent.refusal) }
            } }
        }
        if wanted("opencode"), found.opencode != nil || only != nil {
            if found.opencode == nil { troubles.append("OpenCode isn't installed.") }
            else { ProviderLaunchPermit.atomic {
                if permits == nil || permits?["opencode"]?.valid == true { Store.settings.set(true, forKey: OpenCodeRunner.connectionKey) }
                else { troubles.append(ProviderConsent.refusal) }
            } }
        }
        return troubles
    }

    static func remove(_ found: Shell.Found, only: Set<String>? = nil, disconnects: [String: ProviderDisconnectPermit]? = nil) async {
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }
        func commit(_ cli: String, _ work: () -> Void) {
            if let disconnects { _ = disconnects[cli]?.commit(work) } else { work() }
        }
        if wanted("claude"), disconnects == nil || disconnects?["claude"]?.valid == true {
            await removeClaude(found, disconnect: disconnects?["claude"])
        }
        if wanted("codex") { commit("codex") { removeCodex() } }
        if wanted("cursor") { commit("cursor") { Store.settings.removeObject(forKey: CursorRunner.connectionKey) } }
        if wanted("opencode") { commit("opencode") { Store.settings.removeObject(forKey: OpenCodeRunner.connectionKey) } }
        if wanted("command") {
            ProviderLaunchPermit.atomic {
                guard disconnects == nil || (disconnects?.isEmpty == false && disconnects?.values.allSatisfy({ $0.valid }) == true) else { return }
                removeCommand()
            }
        }
    }
}
