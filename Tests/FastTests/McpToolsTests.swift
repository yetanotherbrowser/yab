import Foundation
import Testing
@testable import Fast

// The parts of `yab mcp` that need no browser: `run`'s code driving a
// made-up set of tools (McpRun), and which addresses carry someone's
// details away (Mcp.personal). One at a time: a run's context is the
// server's own, as `yab mcp` takes one call at a time.
@Suite(.serialized)
struct McpToolsTests {
    /// Tools that answer as the browser would, and remember being called.
    final class Tools {
        var calls: [(String, [String: Any])] = []
        func call(_ name: String, _ input: [String: Any]) -> [String: Any] {
            calls.append((name, input))
            let page = "tab: ab12 · Settings · https://example.com/\n\ne3 button \"Save changes\"\ne4 link \"Next\" href=/2"
            switch name {
            case "open", "snapshot": return ["content": [["type": "text", "text": page]], "isError": false]
            case "click" where input["ref"] as? String == "e9": return ["content": [["type": "text", "text": "stale ref e9, take a new snapshot"]], "isError": true]
            default: return ["content": [["type": "text", "text": "Clicked (a real click landed on it).\nNothing on the page changed."]], "isError": false]
            }
        }
    }

    static func text(_ got: [String: Any]) -> String {
        (got["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }

    /// Every tool says what it does to the world (MCP's annotations), as
    /// clients ask before acting on it and directories list it by them.
    @Test func everyToolSaysWhatItDoesToTheWorld() throws {
        let click = Mcp.tool("click", "Click.")
        let annotations = try #require(click["annotations"] as? [String: Any])
        #expect(click["title"] as? String == "Click")
        #expect(annotations["readOnlyHint"] as? Bool == false)
        #expect(annotations["destructiveHint"] as? Bool == true)
        #expect((Mcp.tool("text", "Read.")["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        // One left out of the table says the worst of itself.
        #expect((Mcp.tool("made_up", "?")["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == true)

        // Every tool is said once, in the registry, with its hint.
        let named = Mcp.registry.map(\.name)
        #expect(named.count > 60)
        #expect(Set(named).count == named.count)
        #expect(Set(named) == Set(Mcp.hints.keys))
        for (name, hint) in Mcp.hints {
            #expect(!(hint.reads && hint.destroys), "\(name) can't both only read and destroy")
            #expect(!hint.title.isEmpty && hint.title != name, "\(name) needs a title")
        }
    }

    @Test func methodsAreTheTools() {
        let tools = Tools()
        let got = McpRun.run("const t = open('https://example.com/'); t.click(t.find('Save')); t.type('e5', 'Ada', {submit: true}); return t.id") { tools.call($0, $1) }
        #expect(got["isError"] as? Bool == false)
        #expect(Self.text(got).hasPrefix("ab12"))
        #expect(tools.calls.map(\.0) == ["open", "snapshot", "click", "type"])
        #expect(tools.calls[2].1["ref"] as? String == "e3")
        #expect(tools.calls[3].1["submit"] as? Bool == true)
    }

    @Test func aFailedStepThrowsWithTheToolsWords() {
        let tools = Tools()
        let got = McpRun.run("const t = tab('ab12'); try { t.click('e9') } catch (e) { console.log('caught: ' + e.message) } t.click('e9')") { tools.call($0, $1) }
        #expect(got["isError"] as? Bool == true)
        #expect(Self.text(got).contains("caught: stale ref e9"))
    }

    @Test func coordinateAndRefDragsUseTheSameTool() {
        let tools = Tools()
        let got = McpRun.run("const t = tab('ab12'); t.drag({x: 120, y: 240}, {x: 360, y: 240}); t.drag('e4', {dx: 30, dy: -5}); t.drag('e4', 'e5')") { tools.call($0, $1) }
        #expect(got["isError"] as? Bool == false)
        #expect(tools.calls.map(\.0) == ["drag", "drag", "drag"])
        #expect(tools.calls[0].1["x"] as? Int == 120)
        #expect(tools.calls[0].1["toX"] as? Int == 360)
        #expect(tools.calls[0].1["ref"] == nil)
        #expect(tools.calls[1].1["ref"] as? String == "e4")
        #expect(tools.calls[1].1["dy"] as? Int == -5)
        #expect(tools.calls[2].1["to"] as? String == "e5")
    }

    @Test func aMethodThatIsntThereSaysWhatIs() {
        let got = McpRun.run("open('https://example.com/').waitForTimeout(100)") { Tools().call($0, $1) }
        #expect(got["isError"] as? Bool == true)
        #expect(Self.text(got).contains("a tab has no waitForTimeout; it has: id, snapshot"))
    }

    @Test func aRunStopsAtItsBudget() {
        let got = McpRun.run("const t = tab('ab12'); for (let i = 0; i < 500; i++) t.press('Tab')") { Tools().call($0, $1) }
        #expect(got["isError"] as? Bool == true)
        #expect(Self.text(got).contains("more than 200 steps"))
    }

    @Test func anEmailInTheQueryIsSeen() {
        #expect(Mcp.personal("http://127.0.0.1:8751/steal?task=x&email=ada%40example.org")?.0 == "ada@example.org")
        #expect(Mcp.personal("https://track.example/?to=ada@example.org")?.1 == "track.example")
        #expect(Mcp.personal("https://shop.example/?phone=%2B44%2020%207946%200958")?.0.hasPrefix("+44") == true)
    }

    @Test func idsAndFragmentsAreNotDetails() {
        #expect(Mcp.personal("https://x.com/someone/status/1839204817731234567") == nil)
        #expect(Mcp.personal("https://www.amazon.com/dp/B0CX23V2ZK?th=1&psc=1&qid=1727182000") == nil)
        #expect(Mcp.personal("https://mail.google.com/mail/u/0/#search/from%3Abob%40example.com") == nil)
        #expect(Mcp.personal("https://example.com/orders?id=11453981234") == nil)
    }

    // A Yab of another build than `yab mcp`, which doesn't know what it is
    // asked: seen 2026-09-28, a browser from the 25th and eval, said only
    // "unknown".

    @Test func anOlderBrowserIsNamedWithBothBuilds() {
        let said = Wire.stranger("agent-eval", mcp: true, ours: "/Applications/yab.app", our: "202609281919",
                                 theirs: "/Users/ada/Desktop/yab.app", their: "202609251159")
        #expect(said == "The Yab that's running (/Users/ada/Desktop/yab.app, build 202609251159) is older than this yab mcp (/Applications/yab.app, build 202609281919) and doesn't know eval yet: ask the user to quit that Yab and open /Applications/yab.app, then try again.")
        let same = Wire.stranger("agent-eval", mcp: true, ours: "/Applications/yab.app", our: "202609281919",
                                 theirs: "/Applications/yab.app", their: "202609251159")
        #expect(same.contains("older than its copy on disk now (build 202609281919)"))
        #expect(same.contains("quit Yab and open it again"))
    }

    @Test func aNewerBrowserAsksForANewerMcp() {
        let said = Wire.stranger("agent-old", mcp: true, ours: "/Applications/yab.app", our: "202609251159",
                                 theirs: "/Users/ada/Desktop/yab.app", their: "202609281919")
        #expect(said.hasPrefix("This yab mcp (/Applications/yab.app, build 202609251159) is older than the Yab that's running"))
        #expect(said.contains("no longer takes old"))
    }

    @Test func aBrowserOfNoKnownBuildIsStillSaidSo() {
        let said = Wire.stranger("agent-eval", mcp: false, ours: nil, our: nil, theirs: nil, their: nil)
        #expect(said == "The Yab that's running doesn't know eval: it's another build than this yab command, an older one most likely. Ask the user to quit Yab and open the Yab this one belongs to, then try again.")
    }

    @Test func unknownFromTheSocketBecomesTheseWords() throws {
        let status: [String: Any] = ["pid": 1, "app": "/Users/ada/Desktop/yab.app", "build": "202609251159"]
        // A browser from before these words: "unknown" alone.
        let old = try Self.browser(status: status, else: ["error": "unknown"])
        let got = Wire.ask(old, ["do": "agent-eval", "id": "ab12", "js": "1+1"])
        let said = got["error"] as? String ?? ""
        #expect(said.contains("doesn't know eval"))
        #expect(said.contains("(/Users/ada/Desktop/yab.app, build 202609251159)"))
        #expect(got["unknown"] as? String == "agent-eval")
        // One since, naming the verb.
        let new = try Self.browser(status: status, else: Bench.unknown("agent-eval"))
        #expect((Wire.ask(new, ["do": "agent-eval"])["error"] as? String ?? "").contains("doesn't know eval"))
        // What it knows passes as it came.
        #expect(Wire.ask(old, ["do": "app-status"])["build"] as? String == "202609251159")
    }

    /// A browser on a socket of its own, for a few calls: it answers
    /// app-status with `status` and everything else with `other`.
    static func browser(status: [String: Any], else other: [String: Any]) throws -> String {
        let path = NSTemporaryDirectory() + "yab-stranger-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(fd, 8) == 0)
        let answers = (try JSONSerialization.data(withJSONObject: status), try JSONSerialization.data(withJSONObject: other))
        Thread {
            while true {
                let peer = accept(fd, nil, nil)
                guard peer >= 0 else { return }
                var line = Data(), byte: UInt8 = 0
                while read(peer, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
                let asked = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                var out = asked?["do"] as? String == "app-status" ? answers.0 : answers.1
                out.append(0x0A)
                _ = out.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
                close(peer)
            }
        }.start()
        return path
    }

    /// A stateful mock browser socket that mimics `agent-attach` and `ContextConsent.preflight`.
    final class MockBrowser: @unchecked Sendable {
        let path: String
        private let fd: Int32
        private let lock = NSLock()
        private var stopped = false
        private var nextID = 0
        private var liveSessions: Set<String> = []
        private var _attachCount = 0
        private var _attachMailFlags: [Bool] = []
        private var _failAttach = false
        private var _overrideError: String?
        private var _askOnce = false
        private var _restartOnAsk = false
        private var _openCalls = 0

        var attachCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _attachCount
        }
        var attachMailFlags: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return _attachMailFlags
        }
        var openCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _openCalls
        }
        var failAttach: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failAttach }
            set { lock.lock(); _failAttach = newValue; lock.unlock() }
        }
        var overrideError: String? {
            get { lock.lock(); defer { lock.unlock() }; return _overrideError }
            set { lock.lock(); _overrideError = newValue; lock.unlock() }
        }
        var askOnce: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _askOnce }
            set { lock.lock(); _askOnce = newValue; lock.unlock() }
        }
        var restartOnAsk: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _restartOnAsk }
            set { lock.lock(); _restartOnAsk = newValue; lock.unlock() }
        }

        init() throws {
            path = NSTemporaryDirectory() + "yab-mcp-reattach-\(UUID().uuidString.prefix(8)).sock"
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EMFILE) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let room = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { sun in
                sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 && listen(fd, 16) == 0 else {
                close(fd)
                try? FileManager.default.removeItem(atPath: path)
                try #require(bound == 0)
                return
            }
            Thread { [weak self] in
                while let self {
                    self.lock.lock()
                    let isStopped = self.stopped
                    self.lock.unlock()
                    if isStopped { return }
                    let peer = accept(self.fd, nil, nil)
                    guard peer >= 0 else { return }
                    var line = Data(), byte: UInt8 = 0
                    while read(peer, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
                    let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                    let reply = self.handle(req)
                    var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
                    out.append(0x0A)
                    _ = out.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
                    close(peer)
                }
            }.start()
        }

        func restart() {
            lock.lock()
            liveSessions.removeAll()
            lock.unlock()
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
            shutdown(fd, SHUT_RDWR)
            close(fd)
            try? FileManager.default.removeItem(atPath: path)
        }

        private func handle(_ req: [String: Any]) -> [String: Any] {
            lock.lock()
            defer { lock.unlock() }
            let verb = req["do"] as? String ?? ""
            if verb == "agent-attach" {
                _attachCount += 1
                _attachMailFlags.append(req["mail"] as? Bool == true)
                if _failAttach { return ["error": "Yab isn't running."] }
                nextID += 1
                let id = "s\(nextID)"
                liveSessions.insert(id)
                return ["session": id]
            }
            if let sid = req["session"] as? String {
                if !liveSessions.contains(sid) {
                    return ["error": ContextConsent.unavailable]
                }
                if let err = _overrideError {
                    return ["error": err]
                }
            }
            switch verb {
            case "agent-tabs":
                return ["tabs": [["id": "t1", "whose": "yours", "title": "Example", "url": "https://example.com"]]]
            case "agent-detach":
                if let sid = req["session"] as? String { liveSessions.remove(sid) }
                return ["ok": true]
            case "agent-caps":
                return ["messages": true]
            case "open":
                _openCalls += 1
                if _restartOnAsk {
                    _restartOnAsk = false
                    liveSessions.removeAll()
                    return ["error": "this waits for the person's yes; asking them now", "asking": true, "chat": req["session"] as? String ?? ""]
                }
                return ["id": "t1", "title": "Example", "url": req["url"] as? String ?? ""]
            case "click":
                if _askOnce {
                    _askOnce = false
                    return ["asking": true, "tab": "t1"]
                }
                return ["done": "mouse"]
            case "handoff-wait":
                // Mimics Bench.handleHandoffWait: if a replacement session polled for
                // a missing chat after restart, Yab returns state: "done".
                if let chat = req["chat"] as? String, !liveSessions.contains(chat) {
                    return ["state": "done"]
                }
                return ["error": "no pending question"]
            case "agent-mail-triage":
                return ["text": "Inbox clear."]
            default:
                return ["ok": true]
            }
        }
    }

    private func withCleanMcp(_ socket: String, _ body: () -> Void) {
        Mcp.resetSessionStateForTesting()
        defer { Mcp.resetSessionStateForTesting() }
        Mcp.within(["--socket", socket]) {
            body()
        }
    }

    @Test func reattachesAfterBrowserRestart() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            let first = Mcp.call("tabs", [:])
            #expect(first["isError"] as? Bool == false)
            #expect(Mcp.session == "s1")
            #expect(mock.attachCount == 1)

            Mcp.named = true
            mock.restart()

            let second = Mcp.call("tabs", [:])
            #expect(second["isError"] as? Bool == false)
            #expect(Self.text(second).contains("https://example.com"))
            #expect(Mcp.session == "s2")
            #expect(Mcp.named == false)
            #expect(mock.attachCount == 2)

            // Subsequent calls reuse the new handle without reattaching again.
            let third = Mcp.call("tabs", [:])
            #expect(third["isError"] as? Bool == false)
            #expect(Mcp.session == "s2")
            #expect(mock.attachCount == 2)
        }
    }

    @Test func capsReattachesAfterRestartAndDoesNotCacheErrors() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            #expect(Mcp.call("tabs", [:])["isError"] as? Bool == false)
            #expect(Mcp.session == "s1")

            // Restart with attach failing: caps returns an error without caching it.
            mock.restart()
            mock.failAttach = true
            let failedCaps = Mcp.caps
            #expect(failedCaps["error"] != nil)
            #expect(Mcp.session == "s1")

            // Once Yab is back, the very next caps read is not poisoned: it reattaches to s2 and succeeds.
            mock.failAttach = false
            let recoveredCaps = Mcp.caps
            #expect(recoveredCaps["messages"] as? Bool == true)
            #expect(Mcp.session == "s2")
        }
    }

    @Test func doesNotReattachExplicitSession() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            Mcp.session = "pinned-session"
            let got = Mcp.call("tabs", [:])
            #expect(got["isError"] as? Bool == true)
            #expect(Self.text(got) == ContextConsent.unavailable)
            #expect(Mcp.session == "pinned-session")
            #expect(mock.attachCount == 0)
        }
    }

    @Test func doesNotReattachInnerOrAssistantSession() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            Mcp.inner = true
            Mcp.session = "inner-session"
            let gotInner = Mcp.call("tabs", [:])
            #expect(gotInner["isError"] as? Bool == true)
            #expect(Self.text(gotInner) == ContextConsent.unavailable)
            #expect(mock.attachCount == 0)

            Mcp.inner = false
            Mcp.assistant = "asst-1"
            Mcp.session = "asst-session"
            let gotAsst = Mcp.call("tabs", [:])
            #expect(gotAsst["isError"] as? Bool == true)
            #expect(Self.text(gotAsst) == ContextConsent.unavailable)
            #expect(mock.attachCount == 0)

            // Assistant mode without a session must not mint an external session.
            Mcp.session = nil
            _ = Mcp.call("tabs", [:])
            #expect(Mcp.session == nil)
            #expect(mock.attachCount == 0)
        }
    }

    @Test func doesNotReattachOnExpiredOrClearedSession() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            #expect(Mcp.call("tabs", [:])["isError"] as? Bool == false)
            #expect(Mcp.session == "s1")
            #expect(mock.attachCount == 1)

            mock.overrideError = "This task's permission expired. Start a new task."
            let expired = Mcp.call("tabs", [:])
            #expect(expired["isError"] as? Bool == true)
            #expect(Self.text(expired) == "This task's permission expired. Start a new task.")
            #expect(Mcp.session == "s1")
            #expect(mock.attachCount == 1)

            mock.overrideError = "This context was cleared. Start a new task."
            let cleared = Mcp.call("tabs", [:])
            #expect(cleared["isError"] as? Bool == true)
            #expect(Self.text(cleared) == "This context was cleared. Start a new task.")
            #expect(Mcp.session == "s1")
            #expect(mock.attachCount == 1)
        }
    }

    @Test func keepsStaleSessionWhenReattachFailsSoNextCallRecovers() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            #expect(Mcp.call("tabs", [:])["isError"] as? Bool == false)
            #expect(Mcp.session == "s1")

            mock.restart()
            mock.failAttach = true
            let failed = Mcp.call("tabs", [:])
            #expect(failed["isError"] as? Bool == true)
            #expect(Mcp.session == "s1")

            mock.failAttach = false
            let recovered = Mcp.call("tabs", [:])
            #expect(recovered["isError"] as? Bool == false)
            #expect(Mcp.session == "s2")
        }
    }

    @Test func patientStopsOnHandoffWaitErrorInsteadOfRetryingAsAllowed() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            #expect(Mcp.call("tabs", [:])["isError"] as? Bool == false)
            mock.askOnce = true
            let got = Mcp.patient(["do": "click", "id": "t1", "ref": "e1"])
            #expect(got["error"] as? String == "no pending question")
            #expect(got["allowed"] == nil)
        }
    }

    @Test func restartDuringApprovalWaitDoesNotReattachOrBypassPrompt() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            #expect(Mcp.call("tabs", [:])["isError"] as? Bool == false)
            #expect(Mcp.session == "s1")
            #expect(mock.attachCount == 1)

            // `open` asks for permission, then Yab restarts before `handoff-wait` polls.
            // `handoff-wait` must not reattach (which would hit Yab's missing-chat `state: "done"` branch).
            mock.restartOnAsk = true
            let got = Mcp.patient(["do": "open", "url": "https://unfamiliar.example/"])
            #expect(got["error"] as? String == ContextConsent.unavailable)
            #expect(got["allowed"] == nil)
            #expect(mock.openCalls == 1)
            #expect(mock.attachCount == 1)
            #expect(Mcp.session == "s1")

            // A fresh call after the aborted wait still recovers cleanly.
            let next = Mcp.call("tabs", [:])
            #expect(next["isError"] as? Bool == false)
            #expect(Mcp.session == "s2")
            #expect(mock.attachCount == 2)
        }
    }

    @Test func reattachPreservesMailTaintAcrossRestart() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            #expect(Mcp.call("tabs", [:])["isError"] as? Bool == false)
            #expect(mock.attachMailFlags == [false])

            let mail = Mcp.ask(["do": "agent-mail-triage"])
            #expect(mail["error"] == nil)

            mock.restart()
            #expect(Mcp.call("tabs", [:])["isError"] as? Bool == false)
            #expect(Mcp.session == "s2")
            #expect(mock.attachMailFlags == [false, true])
        }
    }

    @Test func taskStatusUnavailableDoesNotReattachCallerSession() throws {
        let mock = try MockBrowser()
        defer { mock.stop() }
        withCleanMcp(mock.path) {
            #expect(Mcp.call("tabs", [:])["isError"] as? Bool == false)
            #expect(Mcp.session == "s1")
            #expect(mock.attachCount == 1)

            let status = Mcp.call("task_status", ["session": "dead-bg-task"])
            #expect(status["isError"] as? Bool == true)
            #expect(Self.text(status) == ContextConsent.unavailable)
            #expect(Mcp.session == "s1")
            #expect(mock.attachCount == 1)
        }
    }
}
