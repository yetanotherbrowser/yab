import Foundation

// `yab mail read|file` and `yab files search|read`: the user's mail threads
// and their files from a terminal, for a script or an agent's shell. Each is
// the MCP tool of the same name called once (Mcp.once), so its words, its
// refusals and the person's yes for mail are the tool's: a file comes with
// its path on this Mac, fetched first when it isn't here yet.
//
//     yab mail read 19a2f0c4e1b2d3a4
//     yab mail file 19a2f0c4e1b2d3a4 2 --path   → /Users/…/files/…/clip.mov
//     yab files search lease
//     yab files read mail.me@example.com|19a…|1 --path

enum CliFiles {
    /// Whether `yab mail …` is one of these and not a task: a verb and then
    /// a thread's id, as mail_search and mail_read say them ("account|id",
    /// or Gmail's hex). "yab mail read my latest email" is a task.
    static func mailWords(_ words: [String]) -> Bool {
        guard words.count >= 2, ["read", "file"].contains(words[0].lowercased()) else { return false }
        return threadish(words[1])
    }

    /// Whether `yab files …` is one of these: `search` and its words, or
    /// `read` and an id or a path files_search gave.
    static func filesWords(_ words: [String]) -> Bool {
        guard let verb = words.first?.lowercased() else { return false }
        if verb == "search" { return true }
        guard verb == "read", words.count >= 2 else { return false }
        let id = words[1]
        return id.hasPrefix("mail.") || id.hasPrefix("/") || id.hasPrefix("~")
    }

    static func threadish(_ word: String) -> Bool {
        guard !word.contains(where: \.isWhitespace) else { return false }
        if word.contains("|") { return true }
        return word.count >= 8 && word.allSatisfy(\.isHexDigit)
    }

    /// What the call is, from the words after `mail` or `files`: the tool
    /// and its arguments, whether only the path is wanted, or why not.
    static func call(_ noun: String, _ words: [String]) -> (tool: String, input: [String: Any], path: Bool)? {
        var plain: [String] = []
        var from: String?, limit: Double?
        var path = false
        var skip = false
        for (i, word) in words.enumerated() {
            if skip { skip = false; continue }
            switch word {
            case "--path": path = true
            case "--from": from = words[safe: i + 1]; skip = true
            case "--limit": limit = words[safe: i + 1].flatMap(Double.init); skip = true
            default: plain.append(word)
            }
        }
        guard let verb = plain.first?.lowercased() else { return nil }
        let rest = Array(plain.dropFirst())
        switch (noun, verb) {
        case ("mail", "read"):
            guard let thread = rest.first else { return nil }
            return ("mail_read", ["thread": thread], false)
        case ("mail", "file"):
            guard let thread = rest.first else { return nil }
            var input: [String: Any] = ["thread": thread]
            let which = rest.dropFirst().joined(separator: " ")
            if let index = Int(which) { input["index"] = Double(index) } else if !which.isEmpty { input["name"] = which }
            return ("mail_file", input, path)
        case ("files", "search"):
            var input: [String: Any] = ["query": rest.joined(separator: " ")]
            if let from { input["from"] = from }
            if let limit { input["limit"] = limit }
            return ("files_search", input, false)
        case ("files", "read"):
            guard let id = rest.first else { return nil }
            return ("files_read", ["id": id], path)
        default:
            return nil
        }
    }

    /// The path a file's answer gives on its own line ("path: …").
    static func path(in text: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix("path: ") }.map { String($0.dropFirst(6)) }
    }

    static func run(_ noun: String, _ args: [String]) -> Never {
        let words = Cli.unsocketed(args)
        guard let (tool, input, wantsPath) = call(noun, words) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        let result = Mcp.once(tool, input, args: args)
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if result["isError"] as? Bool == true {
            FileHandle.standardError.write(Data((text + "\n").utf8))
            exit(1)
        }
        if wantsPath {
            guard let path = path(in: text) else {
                FileHandle.standardError.write(Data((text + "\n").utf8))
                exit(1)
            }
            print(path)
        } else {
            print(text)
        }
        exit(0)
    }

    static var usage: String {
        let c = AgentSetup.command
        return """
        usage: \(c) mail read THREAD                 a thread of your mail, its files listed (inline pictures too)
               \(c) mail file THREAD [N|NAME] [--path]  a file of a thread: its path on this Mac (fetched if need be) and its words
               \(c) files search [WORDS] [--from downloaded|mail|sent] [--limit N]
               \(c) files read ID|PATH [--path]      a file Files lists: its path and its words
        """
    }
}
