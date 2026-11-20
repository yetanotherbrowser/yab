import Foundation
import Testing
@testable import Fast

// A `yab mcp` whose app an update replaced is refused by the browser for
// the rest of its client's chat (McpHandover): it hands the client to a
// server started from the copy at its path. What is handed over, and in what
// order. The update itself (Update.Swap's rename aside, move in and sweep,
// against BenchCaller) is run end to end in the pull request.
@Suite struct McpHandoverTests {
    static func line(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    static func ids(_ lines: [String]) -> [String] {
        lines.map { line in
            let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
            if let id = message["id"] { return "\(id)" }
            return message["method"] as? String ?? "?"
        }
    }

    @Test func callsWaitingInLineGoFirstThenEveryLineAsItCame() {
        let inbox = Inbox()
        var relayed: [String] = []
        var lines = [
            Self.line(["jsonrpc": "2.0", "id": 1, "method": "tools/call"]),
            Self.line(["jsonrpc": "2.0", "id": 2, "method": "tools/call"]),
        ]
        let after = [
            Self.line(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 3]]),
            "",
            Self.line(["jsonrpc": "2.0", "id": 3, "method": "tools/call"]),
        ]
        var handed = false
        inbox.read {
            if lines.isEmpty, !handed {
                handed = true
                inbox.handOver { relayed.append($0) }
                lines = after
            }
            return lines.isEmpty ? nil : lines.removeFirst()
        }
        // The two that waited, then the rest as sent: the new server keeps
        // its own line, cancellations included. Empty lines are not sent.
        #expect(Self.ids(relayed) == ["1", "2", "notifications/cancelled", "3"])
        #expect(relayed[2] == after[0])
        // This server has nothing left to answer.
        #expect(inbox.next() == nil)
    }

    @Test func theNewServerAnswersTheCallAndTheGreetingStaysHere() throws {
        // A stand-in for the new `yab mcp`: answers the greeting, keeps
        // quiet on notifications, and echoes every call back.
        let script = """
        read greeting; echo '{"jsonrpc":"2.0","id":0,"result":{"greeted":true}}'
        while read line; do case "$line" in *notifications/initialized*) ;; *) echo "$line";; esac; done
        """
        let said = Said()
        let greeting: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                       "params": ["clientInfo": ["name": "claude-code"]]]
        let next = try #require(McpHandover(executable: "/bin/sh", arguments: ["-c", script],
                                            greeting: greeting, client: said.add))
        let ended = Said()
        next.carry { ended.add(Data("ended".utf8)) }
        let call = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "open"]] as [String: Any]
        #expect(next.send(call))
        #expect(next.send(line: Self.line(["jsonrpc": "2.0", "id": 8, "method": "tools/list"])))
        next.finish()
        let deadline = Date().addingTimeInterval(5)
        while ended.text.isEmpty, Date() < deadline { usleep(10_000) }
        let lines = said.text.split(separator: "\n").map(String.init)
        // The client already has its answer to `initialize`: only the call
        // and what followed reach it.
        #expect(Self.ids(lines) == ["7", "8"])
        #expect(!said.text.contains("greeted"))
        #expect(ended.text == "ended")
    }

    @Test func noHandoverWithoutANewServer() {
        let greeting: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize"]
        // Nothing at the path, or a program that says nothing back.
        #expect(McpHandover(executable: "/nonexistent/yab", arguments: ["mcp"], greeting: greeting) { _ in } == nil)
        #expect(McpHandover(executable: "/usr/bin/true", arguments: [], greeting: greeting) { _ in } == nil)
    }

    @Test func codeUnchangedOnDiskIsNotHandedOver() throws {
        // The test runner's binary is what is at its path: a refusal it gets
        // is the browser's answer to a program that isn't Yab, and stays one.
        let path = try #require(Bundle.main.executablePath)
        #expect(!McpHandover.replacedOnDisk(path))
    }

    @Test func anotherFileAtThePathIsAReplacement() throws {
        // As after Update.Swap: the path names a file other than the one
        // this process runs, which the kernel still knows.
        let running = try #require(McpHandover.runningFile())
        var other = stat()
        #expect(stat("/bin/sh", &other) == 0)
        #expect(UInt64(other.st_ino) != running.inode)
        #expect(McpHandover.replacedOnDisk("/bin/sh"))
        // Nothing there: nothing to start in its place.
        #expect(!McpHandover.replacedOnDisk("/nonexistent/yab.app/Contents/MacOS/yab"))
    }
}

private final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
