import Foundation
import Testing
@testable import Fast

struct CliSettingsTests {
    @Test func showIsTheDefaultAndTakesWordsAndTarget() throws {
        #expect(try CliSettings.parse([]) == .init(tool: "native_context", input: [:], json: false))
        let show = try CliSettings.parse(["show", "tab", "sleep", "--json", "--target", "space:S1", "--socket", "/tmp/y.sock"])
        #expect(show == .init(tool: "native_context", input: ["query": "tab sleep", "target": ["kind": "space", "id": "S1"]], json: true))
        #expect(try CliSettings.parse(["actions", "engine"]).input == ["query": "engine"])
    }

    @Test func applyDefaultsToTheAppAndNamesItsRequest() throws {
        let apply = try CliSettings.parse(["apply", "site.set_engine", #"{"site":"github.com","value":"webKit"}"#]) { "R" }
        #expect(apply.tool == "native_apply")
        #expect(apply.input == ["action": "site.set_engine", "arguments": ["site": "github.com", "value": "webKit"],
                                "target": ["kind": "application", "id": "app"], "requestId": "R"])
        let retried = try CliSettings.parse(["apply", "settings.set.theme", #"{"value":"dark"}"#, "--request-id", "R1", "--expect", "v2"]) { "unused" }
        #expect(retried.input["requestId"] as? String == "R1" && retried.input["expectedVersion"] as? String == "v2")
    }

    @Test func undoAndOperationTakeTheirIds() throws {
        #expect(try CliSettings.parse(["undo"]).input == [:])
        #expect(try CliSettings.parse(["undo", "c1"]).input == ["changeId": "c1"])
        #expect(try CliSettings.parse(["operation", "o1", "--seconds", "5", "--cancel"]).input == ["operationId": "o1", "seconds": 5.0, "cancel": true])
    }

    @Test func refusesWhatItCannotSendAsIs() {
        for args in [["apply"], ["apply", "a", "not json"], ["apply", "a", "[1]"], ["apply", "a", "{}", "extra"], ["undo", "a", "b"],
                     ["operation"], ["operation", "o", "--seconds", "11"], ["show", "--target", "space"], ["show", "--bogus"], ["delete"]] {
            #expect(throws: CliSettings.Failure.self) { try CliSettings.parse(args) }
        }
    }

    @Test func anApplyStillWaitingForThePersonExitsThree() {
        func result(_ json: String, error: Bool = false) -> [String: Any] {
            ["content": [["type": "text", "text": json]], "isError": error]
        }
        #expect(CliSettings.exitCode(result(#"{"status":"needs_user","operationId":"A"}"#)) == 3)
        #expect(CliSettings.exitCode(result(#"{"status":"verified","operationId":"A"}"#)) == 0)
        #expect(CliSettings.exitCode(result(#"{"status":"unknown_outcome"}"#)) == 1)
        #expect(CliSettings.exitCode(result("Refused", error: true)) == 1)
        #expect(CliSettings.exitCode(result(#"{"settings":[]}"#)) == 0)
    }

    @Test func aLaterOperationRejoinsTheSessionTheApplyLeftWaiting() throws {
        let call = try CliSettings.parse(["operation", "OP1", "--session", "S1", "--seconds", "5"])
        #expect(call.tool == "native_operation")
        #expect(call.session == "S1")
        #expect(call.input["operationId"] as? String == "OP1")
        #expect(try CliSettings.parse(["show"]).session == nil)
    }

    @Test func anOperationReadGivenItsOwnWaitReturnsAfterIt() throws {
        #expect(try CliSettings.parse(["apply", "a"]).waits)
        #expect(try CliSettings.parse(["operation", "OP1", "--session", "S1"]).waits)
        #expect(try !CliSettings.parse(["operation", "OP1", "--seconds", "0"]).waits)
        #expect(try !CliSettings.parse(["operation", "OP1", "--cancel"]).waits)
        #expect(try !CliSettings.parse(["show"]).waits)
    }
}

/// A session `yab settings` left waiting for the person had no end.
@MainActor
struct LeftSessionTests {
    @Test func aLeftSessionEndsOnceUnusedAndACallStartsItsTimeAgain() {
        let agents = Agents.shared
        let session = agents.attach(name: "Left session " + UUID().uuidString)
        defer { agents.detach(session.id) }
        let start = Date()
        agents.leave(session.id, for: 60, now: start)
        agents.used(session.id, now: start.addingTimeInterval(50))
        agents.expireLeft(now: start.addingTimeInterval(70))
        #expect(session.state == .attached)
        agents.expireLeft(now: start.addingTimeInterval(50 + Mcp.keptFor))
        #expect(session.state != .attached)
        #expect(agents.leftUntil[session.id] == nil)
    }

    @Test func aSessionNobodyLeftIsNotEndedByTheClock() {
        let agents = Agents.shared
        let session = agents.attach(name: "Kept session " + UUID().uuidString)
        defer { agents.detach(session.id) }
        agents.used(session.id)
        agents.expireLeft(now: .distantFuture)
        #expect(session.state == .attached)
    }
}
