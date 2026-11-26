import AppKit

// `yab`, from a terminal, yours or an agent's.
//
// The same binary as the browser, reached through the two-line script
// Settings › Agents puts on the PATH. The first word says what is wanted;
// anything that isn't one of the words below is a task, handed to an agent
// the running browser starts, the way `aside "…"` is:
//
//     yab "find the unread message from Alex in Slack"
//     yab https://github.com/notifications
//     yab guide | session … | memory … | setup | remove
//
// None of it touches NSApplication. Memory is read straight from its folder,
// so it answers with the browser closed; a task wakes the browser if it
// has to (Wire.wake).

enum Cli {
    /// Whether a launch with these arguments is for here rather than the
    /// browser. Launched from Finder or by `open`, a Mac app gets nothing,
    /// or AppKit's own dashed flags, and so does the browser's own
    /// --arrival, so a first word without a dash is always someone typing,
    /// and so is one of the task's own flags (`yab --cli codex "…"`).
    static func wants(_ first: String?) -> Bool {
        guard let first else { return false }
        return !first.hasPrefix("-") || flags.contains(first)
    }

    private static let flags: Set = ["-h", "--help", "-V", "--version", "--cli", "-m", "--model", "--effort",
                                     "--access", "--permission", "--resume", "--socket", "--no-person", "--wait-person"]

    /// Words less where to reach Yab: `yab status --socket X` is still `status`.
    static func unsocketed(_ words: [String]) -> [String] {
        guard let at = words.firstIndex(of: "--socket") else { return words }
        var kept = words
        kept.removeSubrange(at..<min(at + 2, kept.count))
        return kept
    }

    /// The command a line runs: its first word when what follows fits it,
    /// else "" for a task ("yab help me write an email").
    static func command(_ args: [String]) -> String {
        let rest = Array(args.dropFirst())
        let words = unsocketed(rest)
        // A word of its own only when what follows fits it: "yab help me
        // write an email" and "yab remove the draft" are tasks.
        func fits(_ words: Set<String>) -> Bool { rest.isEmpty || words.contains(rest[0].lowercased()) || rest[0].hasPrefix("-") }
        let first = args.first ?? ""
        switch first {
        case "help", "version": return words.isEmpty ? first : ""
        case "status": return words.allSatisfy { $0 == "--json" } ? first : ""
        case "quit": return words.allSatisfy { $0 == "--force" } ? first : ""
        case "serve": return words.allSatisfy { ["--no-person", "--stop"].contains($0) } ? first : ""
        // "yab import chrome"; "yab import my contacts from gmail" is a task.
        case "import": return words.count <= 1 ? first : ""
        case "guide": return words.count <= 1 ? first : ""
        case "session", "sessions": return fits(["list", "resume", "steer", "queue", "stop"]) ? first : ""
        case "memory": return fits(["search", "list", "show", "read", "path", "setup"]) ? first : ""
        case "skills", "skill": return fits(["list", "show", "read", "path"]) ? first : ""
        case "every", "routines":
            // A routine only when what follows reads as one: "yab every
            // morning check my mail" is a task.
            let when = Routines.leading(rest) != nil
            return fits(["list", "remove", "run", "pause", "resume"]) || when ? "every" : ""
        case "mail": return rest.first?.lowercased() == "flush" || CliFiles.mailWords(words) ? first : ""
        // "yab files search lease"; "yab files from last week" is a task.
        case "files": return CliFiles.filesWords(words) ? first : ""
        // "yab settings show theme"; "yab settings make it dark" is a task.
        case "settings": return fits(CliSettings.verbs) ? first : ""
        case "setup", "remove": return words.allSatisfy { ["claude", "codex", "cursor", "command"].contains($0.lowercased()) } ? first : ""
        default: return first
        }
    }

    /// The word someone meant as a command, when a line that reached no
    /// command reads as a mistyped one rather than a task: a help flag after
    /// words (`yab feedback --help`), or one bare word that no task is
    /// written as, a joined name (`yab list-tabs`) or a command's near miss
    /// (`yab sesion`, `yab stauts`). Any other single word is a task
    /// (`yab continue`, `yab summarize`), whatever its case. Nil for a task,
    /// `yab list` and `yab stop ID` among them. Asked only of a bare `yab …` line: the words after `yab agent`
    /// or `yab session resume ID` are the task's own, and a one-word
    /// follow-up ("yes") is one.
    static func mistyped(_ args: [String]) -> String? {
        let words = unsocketed(args)
        guard let first = words.first, !first.hasPrefix("-") else { return nil }
        if words.dropFirst().contains(where: { $0 == "-h" || $0 == "--help" }) { return first }
        guard words.count == 1 else { return nil }
        let word = first.lowercased()
        if word.range(of: "^[a-z][a-z0-9]*([-_][a-z0-9]+)+$", options: .regularExpression) != nil { return first }
        if commandWords.contains(where: { nearMiss(word, of: $0) }) { return first }
        return nil
    }

    /// Every first word `command` or the agent answers, for near misses.
    static let commandWords: Set = ["help", "version", "status", "quit", "serve", "import", "guide", "session",
                                    "sessions", "memory", "skills", "skill", "every", "routines", "mail", "files",
                                    "settings", "setup", "remove", "agent", "exec", "plugin", "list", "stop", "steer", "queue"]

    /// A word one slip from `command` (two for a long one), and not it: a
    /// letter added, dropped, changed or two swapped. Beside a short
    /// command only a changed or swapped letter counts, so `email` stays a
    /// task beside `mail`, and `save` beside `serve`.
    static func nearMiss(_ word: String, of command: String) -> Bool {
        guard word != command, word.count >= 3 else { return false }
        let a = Array(word), b = Array(command)
        let shorter = min(a.count, b.count)
        let most = shorter >= 7 ? 2 : 1
        guard shorter >= 5 ? abs(a.count - b.count) <= most : a.count == b.count else { return false }
        // Edits, with a swap of two neighbors as one.
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count] <= most
    }

    static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let rest = Array(args.dropFirst())
        let first = args.first ?? ""
        let words = unsocketed(rest)
        let word = command(args)
        guard !args.isEmpty else { print(usage); exit(0) }
        switch word {
        case "mail":
            // A thread and its files (CliFiles), or the sends set for
            // later while yab itself is closed: the LaunchAgent's call
            // (MailLater).
            if rest.first?.lowercased() != "flush" { CliFiles.run("mail", rest) }
            exit(MailLater.flushHeadless())
        case "files":
            CliFiles.run("files", rest)
        case "settings":
            CliSettings.run(rest)
        case "-h", "--help", "help":
            print(usage)
            exit(0)
        case "-V", "--version", "version":
            print("Yab \(Guide.version)")
            exit(0)
        case "agent":
            AgentCLI.run(rest)
        case "exec":
            CliExec.run(rest)
        case "plugin":
            BoostCLI.run(rest)
        case "status":
            status(rest)
        case "serve":
            serve(rest)
        case "import":
            bring(rest)
        case "quit":
            let got = Wire.ask(Wire.socket(rest), ["do": "app-quit", "force": rest.contains("--force")])
            if let error = got["error"] as? String { fail(error) }
            print("Quitting.")
            exit(0)
        case "guide":
            guard let text = Guide.text(words.first) else {
                fail("No guide on \(words.first ?? ""). There are: mcp, setup.", code: 2)
            }
            print(text)
            exit(0)
        case "session", "sessions":
            session(rest)
        case "memory":
            memory(rest)
        case "skills", "skill":
            skills(rest)
        case "every":
            every(rest)
        case "setup":
            setup(words, removing: false)
        case "remove":
            setup(words, removing: true)
        case let first where first.hasPrefix("http://") || first.hasPrefix("https://"):
            openTab(first)
        default:
            if ((try? BoostLibrary(root: Store.file("boosts")).records()) ?? []).contains(where: { $0.id == first && $0.enabled }) { BoostCLI.run(args) }
            if let typo = mistyped(args) {
                fail("yab: no command \(typo); see yab help. A task is a sentence: yab \"what to do\"", code: 2)
            }
            AgentCLI.run(args, verbs: false)
        }
    }

    static var usage: String {
        let c = AgentSetup.command
        return """
        Use Yab from a terminal: delegate a task or drive browser tabs yourself.

        Start here:
          \(c) "Summarize my unread Slack messages" --access browser
          \(c) exec 'const t = open("https://example.com"); return t.snapshot()'
          \(c) guide                         examples and task/session reference
          \(c) guide mcp                     browser tools and tab ownership
          \(c) guide setup                   install or remove the command and integrations

        Commands (replace uppercase names with your values):
          \(c) session list [--json]          running and recent task ids
          \(c) session resume ID ["reply"]    continue a task, or follow its output
          \(c) session steer ID "direction"  redirect current work
          \(c) session queue ID "next task"  add work after the current request
          \(c) session stop ID               stop a task
          \(c) exec -f FILE.js [--json]       run browser steps; exec --help for all options
          \(c) mcp                           local stdio MCP server for an assistant
          \(c) settings [show [WORDS]]       Yab's settings, spaces and tabs; settings --help for changes
          \(c) memory search WORDS           search relevant remembered facts
          \(c) memory list                   list memory pages
          \(c) memory show FILE              read a page; memory path prints its folder
          \(c) memory setup                  ask an agent to build the user's memory
          \(c) skills list                   list site and system skills
          \(c) skills show NAME              read a skill; skills path prints its folder
          \(c) mail read THREAD              read mail and list its attachments
          \(c) mail file THREAD [N|NAME] [--path]  retrieve an attachment
          \(c) files search [WORDS]          find downloaded, attached or uploaded files
          \(c) files read ID_OR_PATH [--path]  print a file's path and extracted text
          \(c) every "weekdays 9:00" "task"  schedule a task while Yab is open
          \(c) every list                    list routine ids and schedules
          \(c) every run ID                  run a routine now
          \(c) every pause ID                pause a routine; every resume ID enables it
          \(c) every remove ID               remove a routine
          \(c) status [--json]               check whether Yab is running and what it is doing
          \(c) serve [--no-person]           keep Yab running in the background
          \(c) serve --stop                  stop Yab, including active tasks
          \(c) quit [--force]                quit hidden Yab; --force stops active tasks
          \(c) import [BROWSER]              list browsers or import sign-ins (user approval required)
          \(c) https://example.com           open a page in the user's window
          \(c) setup [claude|codex|cursor|command]   install integrations or just the command
          \(c) remove [claude|codex|cursor|command]  remove installed integrations
          \(c) --version                     print this app's version

        Task options:
          --cli claude|codex|cursor    choose the task's AI plan
          -m MODEL / --model MODEL    choose a model
          --effort low|medium|high|xhigh|max
          --access browser|full       browser tools, or files and terminal too (may need approval)
          --no-person                 refuse requests that need a person
          --wait-person MIN           wait for a sign-in/approval: 10 minutes in a terminal,
                                      0.25 minutes when another agent calls Yab
        Task exit codes: 0 done; 1 failed; 2 invalid usage; 3 needs the user; 130 stopped.
        Not every command has --help. Use guide for reference; exec --help has exec-specific help.
        """
    }

    /// A hidden Yab kept for agents for good: started so, or told so if it
    /// is running; with --no-person, nobody is at this Mac to sign in or
    /// say yes. --stop quits it.
    private static func serve(_ args: [String]) -> Never {
        let socket = Wire.socket(args)
        if args.contains("--stop") {
            let got = Wire.ask(socket, ["do": "app-quit", "force": true])
            if let error = got["error"] as? String { fail(Wire.running ? error : "Yab isn't running.") }
            print("Stopped.")
            exit(0)
        }
        guard Wire.allowed else { fail(Wire.offline()) }
        let nobody = args.contains("--no-person")
        var got = Wire.ask(socket, ["do": "app-serve", "nobody": nobody])
        if got["error"] != nil, !Wire.running {
            // Only the default world can be started from here, as Wire.wake does.
            guard socket == Wire.socket([]) else { fail("Nothing answers at \(socket). Start that Yab first.") }
            guard Wire.launch(socket, ["--headless", "--serve"] + (nobody ? ["--no-person"] : [])) else { fail("Yab didn't start.") }
            got = Wire.ask(socket, ["do": "app-status"])
        }
        if let error = got["error"] as? String { fail(error) }
        let pid = got["pid"] as? Int ?? 0
        print(got["hidden"] as? Bool == true
              ? "Yab is serving agents, hidden (pid \(pid))\(nobody ? ", with nobody to sign in or say yes" : ""). It stays until `\(AgentSetup.command) serve --stop`."
              : "Yab is open (pid \(pid)), and serves agents as long as it is.")
        exit(0)
    }

    /// Another browser's sign-ins into Yab, for someone who uses it from
    /// a terminal: its passwords and its cookies, what the welcome brings
    /// when Yab is opened. Only typed by a person: an agent that runs it
    /// is told to ask them.
    private static func bring(_ args: [String]) -> Never {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            fail("Ask the user to run `\(AgentSetup.command) import` in a terminal: it brings another browser's sign-ins into Yab.", code: 2)
        }
        let socket = Wire.socket(args)
        guard let name = unsocketed(args).first else {
            let got = Wire.ask(socket, ["do": "app-import"])
            if let error = got["error"] as? String { fail(error) }
            let browsers = got["browsers"] as? [String] ?? []
            print(browsers.isEmpty ? "No other browser on this Mac to bring sign-ins from."
                  : "From: \(browsers.joined(separator: ", ")). `\(AgentSetup.command) import \(browsers[0].lowercased())`")
            exit(0)
        }
        let found = Wire.ask(socket, ["do": "app-import", "source": name, "check": true])
        if let error = found["error"] as? String { fail(error) }
        let source = found["source"] as? String ?? name
        print("Bringing \(source)'s sign-ins into Yab. macOS may ask for \(source)'s key: Always Allow.")
        let got = Wire.ask(socket, ["do": "app-import", "source": source])
        if let error = got["error"] as? String { fail(error) }
        print("\(got["source"] as? String ?? name): \(got["passwords"] as? Int ?? 0) passwords, \(got["cookies"] as? Int ?? 0) cookies.")
        if let trouble = got["trouble"] as? String { print(trouble + ".") }
        exit(0)
    }

    /// Whether Yab is running, hidden for agents or open, and what it is
    /// doing, in a line.
    private static func status(_ args: [String]) -> Never {
        let got = Wire.ask(Wire.socket(args), ["do": "app-status"])
        // --json: what the app said, as an object, for a launcher to read.
        if args.contains("--json") {
            var said = got
            said["running"] = got["error"] == nil
            printJSON(said)
            exit(got["error"] == nil ? 0 : 1)
        }
        if let error = got["error"] as? String { print(error.hasPrefix("Yab isn't running") ? "Yab isn't running." : error); exit(1) }
        let pid = got["pid"] as? Int ?? 0
        let working = got["working"] as? Int ?? 0, waiting = got["waiting"] as? Int ?? 0
        var line = got["lingering"] as? Bool == true ? "Yab is finishing its tasks before it quits (pid \(pid))"
            : got["serving"] as? Bool == true && got["hidden"] as? Bool == true ? "Yab is serving agents, hidden (pid \(pid))"
            : got["hidden"] as? Bool == true ? "Yab is running hidden (pid \(pid))" : "Yab is open (pid \(pid))"
        line += working == 0 ? ", nothing running" : ", \(working) task\(working == 1 ? "" : "s") running"
        if waiting > 0 { line += ", \(waiting) waiting for you" }
        if got["nobody"] as? Bool == true { line += ", nobody at this Mac" }
        if got["hidden"] as? Bool == true, let after = got["quits_after"] as? Int, after > 0, let idle = got["idle"] as? Int, working == 0 {
            line += "; quits in \((max(0, after - idle) + 59) / 60)m unless used"
        }
        print(line + ".")
        if let room = got["room"] as? String, room != "seen" { print("Agent pages: \(room).") }
        exit(0)
    }

    private static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    /// `session list --json`: each session as a launcher lists it, from
    /// what the app says of its agents (Bench "agents").
    static func sessionsJSON(_ agents: [[String: Any]]) -> [[String: Any]] {
        agents.map { found in
            let prompt = found["prompt"] as? String ?? ""
            let title = (found["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Chat.title(from: prompt)
            let state = found["state"] as? String ?? ""
            return ["id": found["session"] as? String ?? "", "state": state, "agent": found["name"] as? String ?? "",
                    "cli": found["cli"] as? String ?? "", "title": title,
                    "started": (found["started"] as? String).map { $0 as Any } ?? NSNull(),
                    "finished": (found["finished"] as? String).map { $0 as Any } ?? NSNull(),
                    "waiting": found["waiting"] as? Bool ?? (state == "waiting")]
        }
    }

    private static func fail(_ text: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(code)
    }

    // MARK: - sessions

    private static func session(_ args: [String]) -> Never {
        let socket = Wire.socket(args)
        let json = args.contains("--json")
        let words = args.filter { $0 != "--socket" && $0 != socket && $0 != "--json" }
        let verb = words.first ?? "list"
        let id = words.dropFirst().first
        var said = Array(words.dropFirst(2))
        // Flags for the follow, not words for the agent.
        said.removeAll { $0 == "--no-person" }
        if let at = said.firstIndex(of: "--wait-person") { said.removeSubrange(at..<min(at + 2, said.count)) }
        let text = said.joined(separator: " ")
        switch verb {
        case "list" where json:
            let got = Wire.ask(socket, ["do": "agents"])
            if let error = got["error"] as? String { fail(error) }
            printJSON(sessionsJSON(got["agents"] as? [[String: Any]] ?? []))
            exit(0)
        case "list":
            AgentCLI.run(["list"] + passing(args, socket))
        case "steer", "queue":
            guard let id, !text.isEmpty else { fail("usage: \(AgentSetup.command) session \(verb) SESSION \"text\"", code: 2) }
            AgentCLI.run([verb, id, text] + passing(args, socket))
        case "stop":
            guard let id else { fail("usage: \(AgentSetup.command) session stop SESSION", code: 2) }
            AgentCLI.run(["stop", id] + passing(args, socket))
        case "resume":
            guard let id else { fail("usage: \(AgentSetup.command) session resume SESSION [\"follow-up\"]", code: 2) }
            if text.isEmpty { AgentCLI.follow(socket, id, person: AgentCLI.person(args), patience: AgentCLI.patience(args, person: AgentCLI.person(args))) }
            AgentCLI.run(["--resume", id, text] + passing(args, socket))
        default:
            fail("No session command \(verb). There are: list, resume, steer, queue, stop.", code: 2)
        }
    }

    private static func passing(_ args: [String], _ socket: String) -> [String] {
        var kept = args.contains("--socket") ? ["--socket", socket] : []
        if args.contains("--no-person") { kept.append("--no-person") }
        if let minutes = Wire.value(args, "--wait-person") { kept += ["--wait-person", minutes] }
        return kept
    }

    // MARK: - memory

    /// Read-only, like `aside memory`: writing is the agents' job, through
    /// `remember`, and the person's, in a text editor.
    private static func memory(_ args: [String]) -> Never {
        let verb = args.first ?? "list"
        let json = args.contains("--json")
        let words = args.dropFirst().filter { $0 != "--json" }
        switch verb {
        case "path":
            print(Memory.folder.path)
        case "setup":
            // What the new tab offers first: an agent that looks you up
            // everywhere it can and files what it finds.
            MainActor.assumeIsolated {
                AgentCLI.run(["--effort", "high", "--access", "browser", Agents.setUpMemoryPrompt] + args.dropFirst())
            }
        case "list":
            let files = Memory.files()
            if json {
                emit(files.map { path -> [String: Any] in
                    let url = Memory.folder.appendingPathComponent(path)
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    return ["file": path, "modified": date.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
                })
            } else if files.isEmpty {
                print("Nothing remembered yet.")
            } else {
                for path in files { print(path) }
            }
        case "show", "read":
            guard let name = words.first else { fail("usage: \(AgentSetup.command) memory show FILE", code: 2) }
            guard let body = Memory.read(name) else {
                fail("No \(name) in memory. There are: \(Memory.files().joined(separator: ", "))")
            }
            print(body)
        case "search":
            let query = words.joined(separator: " ")
            guard !query.isEmpty else { fail("usage: \(AgentSetup.command) memory search WORDS", code: 2) }
            let hits = Memory.search([query], limit: 12)
            if json {
                emit(hits.map { ["file": $0.file, "line": $0.line, "text": $0.text] })
            } else if hits.isEmpty {
                print("Nothing in memory about that.")
            } else {
                print(hits.map { "\($0.file):\($0.line)\n\($0.text)" }.joined(separator: "\n\n"))
            }
        default:
            // `yab memory some words` searches, as `yab agent memory` did.
            memory(["search"] + args)
        }
        exit(0)
    }

    private static func emit(_ value: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - skills

    // MARK: - routines

    private static func every(_ args: [String]) -> Never {
        let socket = Wire.socket(args)
        let words = args.filter { $0 != "--socket" && $0 != socket }
        let verb = words.first?.lowercased() ?? "list"
        func ask(_ request: [String: Any]) -> [String: Any] {
            let got = Wire.ask(socket, request)
            if let error = got["error"] as? String { fail(error) }
            return got
        }
        switch verb {
        case "list":
            let all = ask(["do": "agent-routines"])["routines"] as? [[String: Any]] ?? []
            if all.isEmpty { print("No routines. Add one: \(AgentSetup.command) every \"weekdays 9:00\" \"what to do\""); exit(0) }
            for routine in all {
                print("\(routine["id"] ?? "")  \(routine["when"] ?? "")  \(routine["prompt"] ?? "")")
                // What its row in Settings says: Off, Running now, how its last run went.
                if let status = routine["status"] as? String, !status.isEmpty { print("       \(status)") }
            }
            exit(0)
        case "pause", "resume":
            guard words.count > 1 else { fail("usage: \(AgentSetup.command) every \(verb) ID", code: 2) }
            _ = ask(["do": "agent-routine-turn", "id": words[1], "on": verb == "resume"])
            print(verb == "pause" ? "Paused: kept, not run." : "Resumed: it runs at its next time.")
            exit(0)
        case "remove", "run":
            guard words.count > 1 else { fail("usage: \(AgentSetup.command) every \(verb) ID", code: 2) }
            let got = ask(["do": verb == "remove" ? "agent-routine-remove" : "agent-routine-run", "id": words[1]])
            print(verb == "remove" ? "Removed." : "Running, session \(got["session"] ?? "")")
            exit(0)
        default:
            // The time in a word or a few: "weekdays 9:00" quoted, or not,
            // "every 3 days 9:00", "first monday 9:00".
            let (when, rest) = Routines.leading(words) ?? (words[0], Array(words.dropFirst()))
            let prompt = rest.joined(separator: " ")
            guard !prompt.isEmpty else { fail("usage: \(AgentSetup.command) every \"weekdays 9:00\" \"what to do\"", code: 2) }
            let got = ask(["do": "agent-routine-add", "when": when, "prompt": prompt])
            print("Routine \(got["id"] ?? "") set for \(got["when"] ?? when). It runs while Yab is open; what it finds comes to your new tab.")
            exit(0)
        }
    }

    private static func skills(_ args: [String]) -> Never {
        switch args.first ?? "list" {
        case "list":
            print(Skills.index())
        case "show", "read":
            guard let name = args.dropFirst().first, let skill = Skills.named(name) else {
                fail("usage: \(AgentSetup.command) skills show NAME. There are: \(Skills.all().map(\.name).joined(separator: ", "))", code: 2)
            }
            print("# \(skill.name)\n\n\(skill.body)")
        case "path":
            print(Skills.mine.path)
        default:
            fail("No skills command \(args.first ?? ""). There are: list, show, path.", code: 2)
        }
        exit(0)
    }

    // MARK: - a page

    /// In front of the person, the way a link from any other app opens.
    private static func openTab(_ url: String) -> Never {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let bundle = Bundle.main.bundlePath
        open.arguments = bundle.hasSuffix(".app") ? ["-a", bundle, url] : [url]
        LaunchJournal.record("cli.open", target: Bundle.main.bundleURL)
        do { try open.runValidated() } catch { fail(error.localizedDescription) }
        open.waitUntilExit()
        exit(open.terminationStatus)
    }

    // MARK: - setup

    private static func setup(_ args: [String], removing: Bool) -> Never {
        let known: Set = ["claude", "codex", "cursor", "command"]
        let asked = Set(args.map { $0.lowercased() })
        if let odd = asked.subtracting(known).first { fail("No \(odd) to set up. There are: claude, codex, cursor, command.", code: 2) }
        let only = asked.isEmpty ? nil : asked
        Task { @MainActor in
            let found = await Shell.find()
            if removing {
                await AgentSetup.remove(found, only: only)
                changed()
                print("Removed.")
                exit(0)
            }
            let localSetup = found.claude.map { LocalAgentSetupPermit.userSetupClaude(binary: $0) }
            defer { localSetup?.revoke() }
            let troubles = await AgentSetup.setUp(found, only: only, localSetup: localSetup)
            changed()
            // The browser listens only when allowed to; being set up is
            // asking for that.
            if only == nil || only?.contains("command") == true { allowAgents() }
            let status = AgentSetup.status()
            let c = AgentSetup.command
            print("""
            command  \(status.command ? "✓ \(AgentSetup.shim.path)" : "-")\(status.command && !AgentSetup.onPath(found.env["PATH"]) ? "  (add \(AgentSetup.shim.deletingLastPathComponent().path) to your PATH)" : "")
            claude   \(status.claude ? "✓ skill \(AgentSetup.skill), MCP \(AgentSetup.server)" : found.claude == nil ? "not installed" : "-")
            codex    \(status.codex ? "✓ skill \(AgentSetup.skill), MCP \(AgentSetup.server)" : found.codex == nil ? "not installed" : "-")
            """)
            for trouble in troubles { FileHandle.standardError.write(Data((trouble + "\n").utf8)) }
            if troubles.isEmpty { print("\nReady. New agent sessions will find Yab; try: \(c) guide") }
            exit(troubles.isEmpty ? 0 : 1)
        }
        dispatchMain()
    }

    /// Turns on the browser's socket: the setting, and a word to a browser
    /// already open to read it again.
    private static func allowAgents() {
        Store.settings.set(true, forKey: "bench")
        DistributedNotificationCenter.default().postNotificationName(
            Self.allowed, object: Bundle.main.bundleIdentifier, userInfo: nil, deliverImmediately: true)
    }

    /// A settings page showing what is set up reads it again.
    private static func changed() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.setUp, object: Bundle.main.bundleIdentifier, userInfo: nil, deliverImmediately: true)
    }

    static let allowed = Notification.Name("dev.serafim.fast.agents-allowed")
    static let setUp = Notification.Name("dev.serafim.fast.agents-set-up")
}
