import CryptoKit
import XCTest
@testable import YabPhone

/// The virtual Mac behaves as the Mac does in the prototype's chapters:
/// takes a task, walks its steps, asks for the code and the yes, checks the
/// yes's signature, finishes; sleeps and goes on when it wakes; breaks once
/// in the fail mode and goes on with Retry.
@MainActor
final class TasksVirtualMacTests: XCTestCase {
    private var world: World!
    private var events: [MacEvent] = []

    override func setUp() async throws {
        world = try World.load(named: "mira")
        events = []
    }

    /// The prototype's timings, a hundred times faster.
    private func fast(_ mode: MacScript.Mode = .online, wakeAfter: Double? = nil) -> MacScript {
        MacScript(mode: mode, stepSeconds: 0.02, slowSeconds: 0.03, takeSeconds: 0.01, paySeconds: 0.01, wakeAfter: wakeAfter)
    }

    private func mac(_ script: MacScript) -> VirtualMac {
        let mac = VirtualMac(script: script, definitions: world.taskDefinitions)
        mac.onEvent = { [weak self] in self?.events.append($0) }
        return mac
    }

    /// Waits until an event matching `match` has come.
    private func wait(_ what: String, timeout: TimeInterval = 5, _ match: (MacEvent) -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if events.contains(where: match) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("no \(what) in \(events)")
    }

    private func signed(_ request: YesRequest, task: TaskRun.ID, key: P256.Signing.PrivateKey) throws -> SignedYes {
        let digest = request.digest(task: task)
        return SignedYes(digest: digest, signature: try key.signature(for: digest).rawRepresentation)
    }

    func testLisbonWalksToTheCodeThenTheYesThenDone() async throws {
        let mac = mac(fast())
        let key = P256.Signing.PrivateKey()
        mac.trust(key.publicKey)
        mac.send(TaskOrder(id: "lisbon", words: "book the tap 18:35 to lisbon, window seat"))
        await wait("the code") { if case .needsCode = $0 { true } else { false } }
        guard case let .needsCode(_, code)? = events.last else { return XCTFail("the code comes last: \(events)") }
        XCTAssertEqual(code.title, "TAP sent a code to this \(DeviceWord.name)")
        XCTAssertEqual(code.line(task: "Lisbon flights"), "Your Mac is signing in to flytap.com for Lisbon flights")
        mac.giveCode("lisbon", code: "482 913")
        await wait("the yes") { if case .needsYes = $0 { true } else { false } }
        guard case let .needsYes(_, yes)? = events.last else { return XCTFail("the yes comes last: \(events)") }
        XCTAssertEqual(yes.title, "Pay €238.00 to TAP Air Portugal?")
        XCTAssertEqual(yes.facts.first, ["Out", "Tue, Oct 13 · ARN 18:35 → LIS 22:10 · nonstop"])
        mac.giveYes("lisbon", try signed(yes, task: "lisbon", key: key))
        await wait("done") { $0 == .done("lisbon") }
        // The prototype's order: taken, the steps, the code, signed in, the seat, the yes, Pay, done.
        let order: [String] = events.map {
            switch $0 {
            case .taken: "taken"
            case let .step(_, k): "step \(k)"
            case .needsCode: "code"
            case .codeRefused: "refused"
            case .needsYes: "yes"
            case .paying: "paying"
            case .done: "done"
            case .failed: "failed"
            case .stopped: "stopped"
            case .waits: "waits"
            case .presence: "presence"
            }
        }
        XCTAssertEqual(order, ["taken", "step 0", "step 1", "step 2", "code", "step 2", "step 3", "yes", "paying", "done"])
        XCTAssertTrue(mac.diary.contains("Signed in to flytap.com with the code from your \(DeviceWord.name)"), "\(mac.diary)")
        XCTAssertTrue(mac.diary.contains("Checked the Face ID signature from the \(DeviceWord.name)"), "\(mac.diary)")
    }

    func testAWrongCodeIsAskedForAgain() async throws {
        let mac = mac(fast())
        mac.send(TaskOrder(id: "lisbon", words: "book"))
        await wait("the code") { if case .needsCode = $0 { true } else { false } }
        events.removeAll()
        mac.giveCode("lisbon", code: "111111")
        await wait("the code again") { if case .needsCode = $0 { true } else { false } }
        XCTAssertFalse(events.contains(.step("lisbon", 3)), "a wrong code doesn't sign in")
        // It says so first, so the iPhone can tell the person the code didn't work.
        guard case .codeRefused("lisbon", let request)? = events.first else { return XCTFail("refused first: \(events)") }
        XCTAssertEqual(request.sender, "TAP")
        XCTAssertTrue(mac.diary.contains("The code didn’t work"), "\(mac.diary)")
    }

    func testAYesSignedByAnotherKeyPressesNothing() async throws {
        let mac = mac(fast())
        mac.trust(P256.Signing.PrivateKey().publicKey)
        mac.send(TaskOrder(id: "lisbon", words: "book"))
        await wait("the code") { if case .needsCode = $0 { true } else { false } }
        mac.giveCode("lisbon", code: "482913")
        await wait("the yes") { if case .needsYes = $0 { true } else { false } }
        guard case let .needsYes(_, yes)? = events.last else { return XCTFail() }
        mac.giveYes("lisbon", try signed(yes, task: "lisbon", key: P256.Signing.PrivateKey()))
        await wait("refused") { if case .failed = $0 { true } else { false } }
        XCTAssertFalse(events.contains(.paying("lisbon")))
        XCTAssertFalse(events.contains(.done("lisbon")))
    }

    func testAYesForOtherWordsPressesNothing() async throws {
        let mac = mac(fast())
        let key = P256.Signing.PrivateKey()
        mac.trust(key.publicKey)
        mac.send(TaskOrder(id: "lisbon", words: "book"))
        await wait("the code") { if case .needsCode = $0 { true } else { false } }
        mac.giveCode("lisbon", code: "482913")
        await wait("the yes") { if case .needsYes = $0 { true } else { false } }
        guard case var .needsYes(_, yes)? = events.last else { return XCTFail() }
        // Signed for €23.80: not what the Mac asked.
        yes.title = "Pay €23.80 to TAP Air Portugal?"
        mac.giveYes("lisbon", try signed(yes, task: "lisbon", key: key))
        await wait("refused") { if case .failed = $0 { true } else { false } }
        XCTAssertFalse(events.contains(.paying("lisbon")))
    }

    func testAsleepTheTaskWaitsAndGoesOnWhenTheMacWakes() async throws {
        let mac = mac(fast(.asleep))
        XCTAssertEqual(mac.presence, .asleep(since: "18:52"))
        mac.send(TaskOrder(id: "anna", words: "draft replies to anna"))
        await wait("waits") { $0 == .waits("anna") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(events.contains(.taken("anna")), "nothing moves while the Mac sleeps")
        mac.wake()
        await wait("done") { $0 == .done("anna") }
        XCTAssertEqual(events.first, .waits("anna"))
        XCTAssertTrue(events.contains(.presence(.awake)))
    }

    func testAsleepWakesOnItsOwnWhenTheWorldSaysWhen() async throws {
        let mac = mac(fast(.asleep, wakeAfter: 0.1))
        mac.send(TaskOrder(id: "lumen", words: "request a spot at lumen"))
        await wait("done", timeout: 5) { $0 == .done("lumen") }
        XCTAssertTrue(mac.presence.awake)
    }

    func testClaudesAnswerWaitsForTheMacToo() async throws {
        let mac = mac(fast(.asleep))
        var answered = false
        let waiting = Task { @MainActor in
            await mac.whenAwake()
            answered = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(answered)
        mac.wake()
        await waiting.value
        XCTAssertTrue(answered)
    }

    func testFailModeBreaksOnceAndRetryGoesOnFromTheSameStep() async throws {
        let mac = mac(fast(.fail))
        mac.send(TaskOrder(id: "lisbon", words: "book"))
        await wait("failed") { if case .failed = $0 { true } else { false } }
        guard case let .failed(_, failure)? = events.last else { return XCTFail() }
        XCTAssertEqual(failure.line, "Couldn’t open flytap.com · the page didn’t load")
        XCTAssertEqual(failure.lockTitle, "Couldn’t open flytap.com")
        XCTAssertEqual(events.filter { if case .step = $0 { true } else { false } }.last, .step("lisbon", 2))
        events.removeAll()
        mac.retry("lisbon")
        await wait("the code") { if case .needsCode = $0 { true } else { false } }
        XCTAssertEqual(events.first, .step("lisbon", 2), "again from the step where it stopped")
    }

    func testSlowSaysTheSameThingsLater() async throws {
        let quick = mac(fast())
        quick.send(TaskOrder(id: "anna", words: "draft"))
        await wait("done") { $0 == .done("anna") }
        let quickEvents = events
        events = []
        let slow = mac(fast(.slow))
        let start = Date()
        slow.send(TaskOrder(id: "anna", words: "draft"))
        await wait("done") { $0 == .done("anna") }
        XCTAssertEqual(events, quickEvents)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.08)
    }

    func testStopIsTheirOwnAndNotAFailure() async throws {
        let mac = mac(fast())
        mac.send(TaskOrder(id: "lumen", words: "request a spot"))
        await wait("a step") { $0 == .step("lumen", 0) }
        mac.stop("lumen")
        XCTAssertEqual(events.last, .stopped("lumen"))
        XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } }, "stopped by the person is no failure: \(events)")
        // Stopped means stopped: nothing more comes for it.
        let count = events.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events.count, count, "\(events)")
        // Retry still picks it up where it was.
        mac.retry("lumen")
        await wait("done") { $0 == .done("lumen") }
    }

    func testATaskWithNoStepsIsDoneOnceTaken() async throws {
        var bare = try XCTUnwrap(world.taskDefinitions.first { $0.id == "anna" })
        bare.id = "bare"
        bare.steps = []
        let mac = VirtualMac(script: fast(), definitions: world.taskDefinitions + [bare])
        mac.onEvent = { [weak self] in self?.events.append($0) }
        mac.send(TaskOrder(id: "bare", words: "nothing to do"))
        await wait("done") { $0 == .done("bare") }
        XCTAssertEqual(events, [.taken("bare"), .done("bare")])
    }

    func testFallingAsleepMidTaskItWaitsAtTheNextStep() async throws {
        let mac = mac(MacScript(mode: .online, stepSeconds: 0.05, takeSeconds: 0.01, paySeconds: 0.01))
        mac.send(TaskOrder(id: "anna", words: "draft"))
        await wait("a step") { $0 == .step("anna", 0) }
        mac.sleep()
        await wait("waits") { $0 == .waits("anna") }
        let steps = events.filter { if case .step = $0 { true } else { false } }.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(events.filter { if case .step = $0 { true } else { false } }.count, steps, "no step while it sleeps")
        mac.wake()
        await wait("done") { $0 == .done("anna") }
    }

    func testAWorldsScriptAndTheLaunchArgumentsPickTheMode() throws {
        let asleep = MacScript.load(world: try World.load(named: "mac-states"))
        XCTAssertEqual(asleep.mode, .asleep)
        XCTAssertEqual(asleep.asleepSince, "18:52")
        XCTAssertEqual(asleep.script("lisbon").expectedCode, "482913", "a world's script keeps the prototype's story")
        let failing = asleep.applying(arguments: ["-YabMac", "fail", "-YabMacWake", "3"])
        XCTAssertEqual(failing.mode, .fail)
        XCTAssertEqual(failing.wakeAfter, 3)
        let live = MacScript.load(world: try World.load(named: "tasks-live"))
        XCTAssertEqual(live.mode, .online)
        XCTAssertEqual(live.script("anna-post").yes?.kind, .post)
        XCTAssertEqual(live.script("drift").yes?.button, "Cancel with Face ID")
        XCTAssertEqual(MacScript.load(world: try World.load(named: "mira")).mode, .online)
    }
}
