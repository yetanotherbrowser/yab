import Foundation

// `yab settings`: each verb is the native_* MCP tool of the same name, so its checks and the person's yes are the tool's.

enum CliSettings {
    static let verbs: Set<String> = ["show", "actions", "apply", "undo", "operation"]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Call: Equatable {
        var tool: String
        var input: [String: AnyHashable]
        var json: Bool
        /// A session an earlier apply left waiting for the person (`--session`).
        var session: String? = nil
        /// Waits here for the person's yes: an apply, or an operation read that asked for no wait of its own.
        var waits: Bool {
            tool == "native_apply" || (tool == "native_operation" && input["seconds"] == nil && input["cancel"] == nil)
        }
    }

    /// The tool and its input, from the words after `settings`. `newID`
    /// names an apply that gave no --request-id.
    static func parse(_ args: [String], newID: () -> String = { UUID().uuidString }) throws -> Call {
        var plain: [String] = []
        var json = false
        var target: [String: AnyHashable]?
        var expected: String?, requestID: String?, seconds: Double?
        var cancel = false
        var session: String?
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw Failure(message: "\(flag) needs a value.") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--json": json = true
            case "--socket": i += 1
            case "--target":
                let parts = try value(arg).split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw Failure(message: "--target is KIND:ID, as settings show names it (space:ID, tab:ID).") }
                target = ["kind": parts[0], "id": parts[1]]
            case "--expect": expected = try value(arg)
            case "--request-id": requestID = try value(arg)
            case "--session": session = try value(arg)
            case "--seconds":
                guard let s = Double(try value(arg)), (0...10).contains(s) else { throw Failure(message: "--seconds must be 0 to 10.") }
                seconds = s
            case "--cancel": cancel = true
            default:
                guard !arg.hasPrefix("-") || arg == "-" else { throw Failure(message: "Unknown option: \(arg).") }
                plain.append(arg)
            }
            i += 1
        }
        var call = try call(plain, json: json, target: target, expected: expected, requestID: requestID,
                            seconds: seconds, cancel: cancel, newID: newID)
        guard session == nil || call.tool == "native_operation" else { throw Failure(message: "--session goes only with settings operation.") }
        call.session = session
        return call
    }

    private static func call(_ plain: [String], json: Bool, target: [String: AnyHashable]?, expected: String?, requestID: String?,
                             seconds: Double?, cancel: Bool, newID: () -> String) throws -> Call {
        let verb = plain.first?.lowercased() ?? "show"
        let rest = Array(plain.dropFirst())
        let query = rest.joined(separator: " ")
        switch verb {
        case "show":
            var input: [String: AnyHashable] = [:]
            if !query.isEmpty { input["query"] = query }
            if let target { input["target"] = target }
            return Call(tool: "native_context", input: input, json: json)
        case "actions":
            return Call(tool: "native_actions", input: query.isEmpty ? [:] : ["query": query], json: json)
        case "apply":
            guard let action = rest.first, rest.count <= 2 else { throw Failure(message: "usage: \(AgentSetup.command) settings apply ACTION ['{\"key\":value}']") }
            let arguments: [String: AnyHashable]
            if rest.count == 2 {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(rest[1].utf8))) as? [String: Any] else {
                    throw Failure(message: "Arguments must be one JSON object, as settings actions lists them.")
                }
                arguments = hashable(object)
            } else {
                arguments = [:]
            }
            var input: [String: AnyHashable] = ["action": action, "arguments": arguments,
                                                "target": target ?? ["kind": "application", "id": "app"],
                                                "requestId": requestID ?? newID()]
            if let expected { input["expectedVersion"] = expected }
            return Call(tool: "native_apply", input: input, json: json)
        case "undo":
            guard rest.count <= 1 else { throw Failure(message: "usage: \(AgentSetup.command) settings undo [CHANGE_ID]") }
            return Call(tool: "native_undo", input: rest.first.map { ["changeId": $0] } ?? [:], json: json)
        case "operation":
            guard rest.count == 1 else { throw Failure(message: "usage: \(AgentSetup.command) settings operation OPERATION_ID [--session ID] [--seconds N] [--cancel]") }
            var input: [String: AnyHashable] = ["operationId": rest[0]]
            if let seconds { input["seconds"] = seconds }
            if cancel { input["cancel"] = true }
            return Call(tool: "native_operation", input: input, json: json)
        default:
            throw Failure(message: "No settings verb \(verb). There are: \(verbs.sorted().joined(separator: ", ")).")
        }
    }

    private static func hashable(_ object: [String: Any]) -> [String: AnyHashable] {
        object.compactMapValues { value -> AnyHashable? in
            switch value {
            case let nested as [String: Any]: return hashable(nested)
            case let list as [Any]: return list.compactMap { ($0 as? [String: Any]).map(hashable) ?? ($0 as? AnyHashable) }
            default: return value as? AnyHashable
            }
        }
    }

    static func run(_ args: [String]) -> Never {
        if args.contains("-h") || args.contains("--help") { print(usage); exit(0) }
        let call: Call
        do {
            call = try parse(args)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n" + usage + "\n").utf8))
            exit(2)
        }
        Mcp.session = call.session
        let result = Mcp.within(args) { () -> [String: Any] in
            var result = Mcp.call(call.tool, call.input)
            if call.waits {
                // The yes is asked in this session, and a yes to a card whose session ended is refused.
                // A terminal waits as long as the confirmation lasts (NativeControl.decide).
                let limit = Date().addingTimeInterval(isatty(STDIN_FILENO) == 1 ? 300 : 15)
                var told = false
                while keeps(result), let id = operation(of: result), Date() < limit {
                    if !told, status(of: result) == "needs_user" {
                        told = true
                        FileHandle.standardError.write(Data("Waiting for your yes in Yab…\n".utf8))
                    }
                    result = Mcp.call("native_operation", ["operationId": id, "seconds": 10])
                }
            }
            // Still unanswered, after a wait or a read that asked for none: the card stays with its session.
            if keeps(result), let id = operation(of: result) { Mcp.leaveWaiting(id) }
            return result
        }
        let failed = result["isError"] as? Bool == true
        let text: String
        if call.json, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        } else {
            let words = CliExec.words(result)
            let elsewhere = call.tool == "native_undo" && failed && words.contains("not_found")
            text = words + (elsewhere ? "\nUndo reaches only this session's changes: apply and undo in one exec script, or apply the change's before value." : "")
        }
        try? (call.json || !failed ? FileHandle.standardOutput : FileHandle.standardError).write(contentsOf: Data((text + "\n").utf8))
        exit(exitCode(result))
    }

    /// The native result's own status says whether it is done: an apply still waiting for the person is 3.
    static func exitCode(_ result: [String: Any]) -> Int32 {
        guard result["isError"] as? Bool != true else { return CliExec.status(result) }
        if keeps(result) { return 3 }
        return status(of: result) == "unknown_outcome" ? 1 : 0
    }

    /// Not done yet, waiting for the person's yes or for them to finish (a Gmail sign-in): its session must stay.
    static func keeps(_ result: [String: Any]) -> Bool {
        result["isError"] as? Bool != true && ["needs_user", "running", "prepared"].contains(status(of: result) ?? "")
    }

    static func status(of result: [String: Any]) -> String? { native(result)?["status"] as? String }

    private static func operation(of result: [String: Any]) -> String? { native(result)?["operationId"] as? String }

    private static func native(_ result: [String: Any]) -> [String: Any]? {
        guard let data = CliExec.words(result).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static var usage: String {
        let c = AgentSetup.command
        return """
        usage: \(c) settings [show [WORDS]] [--target KIND:ID] [--json]   current settings, spaces and tabs
               \(c) settings actions [WORDS] [--json]                    what can be changed, with argument schemas
               \(c) settings apply ACTION ['{"key":value}'] [--target KIND:ID] [--expect VERSION] [--request-id ID] [--json]
               \(c) settings undo [CHANGE_ID] [--json]
               \(c) settings operation OPERATION_ID [--session ID] [--seconds N] [--cancel] [--json]
        The target defaults to the app (application:app). An apply that needs your yes waits for it in Yab; so does operation, unless given --seconds or --cancel.
        Undo reaches changes made in the same session: apply and undo inside one exec script.
        exit: 0 done · 1 refused or failed · 2 usage · 3 needs you in Yab
        """
    }
}
