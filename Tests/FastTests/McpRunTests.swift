import Foundation
import Testing
@testable import Fast

// Keep every use of McpRun's session context in the existing serialized
// suite, including tests in McpToolsTests.swift.
extension McpToolsTests {
    static func words(_ result: [String: Any]) -> String {
        (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    static func tool(_ name: String, _ input: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": "tab: t1"]], "isError": false]
    }

    @Test func pendingPromiseIsAnError() {
        let result = McpRun.run("await new Promise(() => {})", tool: Self.tool)
        #expect(result["isError"] as? Bool == true)
        #expect(Self.words(result).contains("unresolved promise"))
    }

    @Test func pendingPromiseCannotResumeOnNextRun() {
        _ = McpRun.run("keep.secret = 42; await new Promise(r => keep.resume = r); tab('t1').click('e1')", tool: Self.tool)
        var actions = 0
        let next = McpRun.run("if (keep.resume) keep.resume(); return typeof keep.secret") { _, _ in
            actions += 1
            return Self.tool("", [:])
        }
        #expect(next["isError"] as? Bool == false)
        #expect(Self.words(next).hasPrefix("undefined"))
        #expect(actions == 0)
    }

    @Test func awaitedToolsAndKeepStillWork() {
        let result = McpRun.run("keep.answer = 41; await tab('t1').click('e1'); return await Promise.resolve(keep.answer + 1)", tool: Self.tool)
        #expect(result["isError"] as? Bool == false)
        #expect(Self.words(result).hasPrefix("42"))
        let next = McpRun.run("return keep.answer", tool: Self.tool)
        #expect(Self.words(next).hasPrefix("41"))
    }

    @Test func failuresDoNotBecomeSuccess() {
        for code in ["throw new Error('bad step')", "await Promise.reject(new Error('bad step'))", "return )"] {
            let result = McpRun.run(code, tool: Self.tool)
            #expect(result["isError"] as? Bool == true)
        }
        #expect(McpRun.run("return 'ok'", tool: Self.tool)["isError"] as? Bool == false)
    }

    @Test func outputIsBoundedWhileLoggingAndResets() {
        let result = McpRun.run("for (let i=0;i<10000;i++) console.log('😀'.repeat(100))", outputLimit: 256, tool: Self.tool)
        let metadata = result["structuredContent"] as? [String: Any]
        #expect(metadata?["outputCharacters"] as? Int == 256)
        #expect(metadata?["truncated"] as? Bool == true)
        #expect(Self.words(result).count < 400)
        let next = McpRun.run("return 'ok'", outputLimit: 256, tool: Self.tool)
        #expect((next["structuredContent"] as? [String: Any])?["truncated"] as? Bool == false)
        #expect(Self.words(next).hasPrefix("ok"))
    }

    @Test func invalidBudgetDoesNotRunTools() {
        var actions = 0
        let result = McpRun.run("tab('t1').click('e1')", outputLimit: 0) { _, _ in actions += 1; return [:] }
        #expect(result["isError"] as? Bool == true)
        #expect(actions == 0)
    }

    @Test func errorsAlsoRespectOutputBudget() {
        let result = McpRun.run("console.log('x'.repeat(1000)); throw new Error('failure '.repeat(10000))", outputLimit: 256, tool: Self.tool)
        #expect(result["isError"] as? Bool == true)
        #expect(Self.words(result).hasPrefix("Error: failure"))
        #expect(Self.words(result).count < 400)
        #expect((result["structuredContent"] as? [String: Any])?["outputCharacters"] as? Int == 256)
    }

    @Test func toolBudgetAndApprovalErrorsRemain() {
        var actions = 0
        let result = McpRun.run("for(let i=0;i<500;i++) tab('t1').click('e1')") { _, _ in actions += 1; return Self.tool("", [:]) }
        #expect(result["isError"] as? Bool == true)
        #expect(actions == 200)
        let approval = McpRun.run("tab('t1').click('e1')") { _, _ in
            ["content": [["type": "text", "text": "status: needs_user"]], "isError": true]
        }
        #expect(approval["isError"] as? Bool == true)
        #expect(Self.words(approval).contains("status: needs_user"))
    }
}

extension McpToolsTests {
    @Test func nativeToolsAreFunctionsReturningParsedJSON() {
        var calls: [(String, [String: Any])] = []
        let result = McpRun.run("""
        const theme = native_context('theme').settings[0].value;
        native_actions('engine');
        native_apply({ action: 'settings.set.theme', target: { kind: 'application', id: 'app' }, arguments: { value: 'dark' }, requestId: 'r1' });
        native_undo('c1');
        return theme;
        """) { name, input in
            calls.append((name, input))
            let text = name == "native_context" ? #"{"settings":[{"id":"theme","value":"system"}]}"# : "{}"
            return ["content": [["type": "text", "text": text]], "isError": false]
        }
        #expect(result["isError"] as? Bool == false)
        #expect(Self.words(result).hasPrefix("system"))
        #expect(calls.map(\.0) == ["native_context", "native_actions", "native_apply", "native_undo"])
        #expect(calls[0].1["query"] as? String == "theme")
        #expect(calls[1].1["query"] as? String == "engine")
        #expect(calls[2].1["requestId"] as? String == "r1")
        #expect(calls[3].1["changeId"] as? String == "c1")
    }

    @Test func nativeApplyFollowsItsOperationUntilTheYes() {
        var calls: [String] = []
        let result = McpRun.run("return native_apply({ action: 'a', requestId: 'r' }).status") { name, input in
            calls.append(name)
            let status = calls.count < 3 ? "needs_user" : "verified"
            return ["content": [["type": "text", "text": #"{"status":"\#(status)","operationId":"OP1"}"#]], "isError": false]
        }
        #expect(Self.words(result).hasPrefix("verified"))
        #expect(calls == ["native_apply", "native_operation", "native_operation"])
        #expect((result["structuredContent"] as? [String: Any])?["waitingOperation"] == nil)
    }

    /// `yab exec` exited 0 on a change still waiting, and the yes that came later did nothing.
    @Test func nativeApplyStillWaitingIsANeedsUserErrorThatKeepsItsOperation() {
        var operations: [[String: Any]] = []
        let result = McpRun.run("native_apply({ action: 'mail.connect', requestId: 'r' })") { name, input in
            if name == "native_operation" { operations.append(input) }
            return ["content": [["type": "text", "text": #"{"status":"running","operationId":"OP1"}"#]], "isError": false]
        }
        #expect(CliExec.status(result) == 3)
        #expect(Self.words(result).contains("operationId: OP1"))
        #expect(operations.count == 3 && operations.allSatisfy { $0["operationId"] as? String == "OP1" && $0["seconds"] as? Int == 10 })
        #expect((result["structuredContent"] as? [String: Any])?["waitingOperation"] as? String == "OP1")
    }
}
