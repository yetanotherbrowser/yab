import AppIntents
import CryptoKit
import XCTest
@testable import YabPhone

/// The desk turns what the Mac says into the Now line's words, plays the
/// haptics the prototype's table asks for, and keeps the Live Activity to
/// the words a locked iPhone may show.
@MainActor
final class TasksDeskTests: XCTestCase {
    /// The apps of the desks made here, kept for the length of the run; their
    /// Macs stop with each test so nothing of one test plays in the next.
    private var apps: [AppModel] = []

    override func tearDown() async throws {
        for app in apps { app.taskDesk.virtualMac?.halt() }
        apps = []
    }

    private func desk(world name: String = "mira", mode: MacScript.Mode = .online, signer: YesSigner? = nil) throws -> TaskDesk {
        let app = AppModel(world: try World.load(named: name))
        apps.append(app)
        let script = MacScript(mode: mode, stepSeconds: 0.02, slowSeconds: 0.03, takeSeconds: 0.01, paySeconds: 0.01)
        let desk = TaskDesk(app: app, script: script, signer: signer ?? StandInSigner(match: true), still: false, activities: false)
        desk.onScreen = { true }
        app.taskDesk = desk
        return desk
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, until: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if until() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("never: \(what)")
    }

    func testWordsPickTheStandInsTask() {
        let all: Set<String> = ["lisbon", "lumen", "anna"]
        XCTAssertEqual(TaskDesk.taskFor(words: "book the tap 18:35 to lisbon, window seat", among: all), "lisbon")
        XCTAssertEqual(TaskDesk.taskFor(words: "draft replies to anna", among: all), "anna")
        XCTAssertEqual(TaskDesk.taskFor(words: "request a spot at design systems night", among: all), "lumen")
        XCTAssertNil(TaskDesk.taskFor(words: "find me a cheap hotel", among: all))
        XCTAssertNil(TaskDesk.taskFor(words: "book a flight", among: ["anna"]))
        XCTAssertNil(TaskDesk.taskFor(words: "anything", among: []))
    }

    func testATaskFromWordsSaysSendingThenItsSteps() async throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        desk.send(words: "book the tap 18:35 to lisbon, window seat")
        XCTAssertEqual(app.nowItem?.subtitle, "Sending to your Mac")
        XCTAssertEqual(app.nowItem?.icon, .mark)
        await wait("running") { app.tasks.run("lisbon")?.status == .running }
        await wait("the code") { app.tasks.run("lisbon")?.status == .code }
        let item = try XCTUnwrap(app.nowItem)
        XCTAssertEqual(item.kind, .warn)
        XCTAssertEqual(item.subtitle, "Needs the code TAP sent you")
        XCTAssertEqual(item.action, "Enter Code")
        XCTAssertEqual(item.short, "Code")
        XCTAssertEqual(desk.codes["lisbon"]?.sender, "TAP")
    }

    func testTheWholeTaskWithTheCodeAndTheYes() async throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        let before = Haptics.played.count
        desk.send("lisbon", words: "book")
        await wait("the code") { app.tasks.run("lisbon")?.status == .code }
        // The code sheet grows out of the Now line.
        let line = CGRect(x: 12, y: 736, width: 378, height: 52)
        desk.tapNow(try XCTUnwrap(app.nowItem), action: "Enter Code", from: line)
        XCTAssertEqual(desk.sheet, .code("lisbon"))
        XCTAssertEqual(desk.sheetOrigin?.rect, line)
        desk.giveCode("lisbon", code: "482913")
        desk.closeSheet()
        await wait("the yes") { app.tasks.run("lisbon")?.status == .yes }
        XCTAssertEqual(app.nowItem?.subtitle, "Pay €238 to TAP?")
        XCTAssertEqual(app.nowItem?.action, "Review")
        desk.tapNow(try XCTUnwrap(app.nowItem), action: "Review", from: line)
        XCTAssertEqual(desk.sheet, .yes("lisbon"))
        await desk.approve("lisbon")
        await wait("done") { app.tasks.run("lisbon")?.status == .done }
        XCTAssertEqual(app.nowItem?.kind, .done)
        XCTAssertEqual(app.nowItem?.subtitle, "Booked · TAP, Oct 13 18:35, seat 14A")
        // Warning once per status (code, then the yes), success when signed; nothing else.
        let played = Haptics.played.dropFirst(before).map { "\($0.kind.rawValue) \($0.reason)" }
        XCTAssertEqual(played, ["warning needs you", "warning needs you", "success done"])
        // Opened, Done stops being said: the line goes.
        desk.openChat("lisbon", from: .nowLine(line))
        XCTAssertTrue(app.tasks.run("lisbon")?.seen ?? false)
        XCTAssertNil(app.nowItem)
    }

    func testFailedSaysWhatAndRetryGoesOn() async throws {
        let desk = try desk(mode: .fail)
        let app = try XCTUnwrap(desk.app)
        let before = Haptics.played.count
        desk.send("lisbon", words: "book")
        await wait("failed") { app.tasks.run("lisbon")?.status == .failed }
        let item = try XCTUnwrap(app.nowItem)
        XCTAssertEqual(item.subtitle, "Couldn’t open flytap.com · the page didn’t load")
        XCTAssertEqual(item.action, "Retry")
        XCTAssertEqual(Haptics.played.dropFirst(before).map(\.kind), [.error])
        desk.tapNow(item, action: "Retry", from: .zero)
        XCTAssertEqual(app.tasks.run("lisbon")?.status, .running)
        await wait("the code after Retry") { app.tasks.run("lisbon")?.status == .code }
    }

    func testTheMacAsleepTheTaskWaitsGrayAndGoesOnAfterItWakes() async throws {
        let desk = try desk(world: "mac-states", mode: .asleep)
        let app = try XCTUnwrap(desk.app)
        XCTAssertTrue(app.browser.macAsleep)
        desk.send(words: "draft replies to anna")
        let item = try XCTUnwrap(app.nowItem)
        XCTAssertEqual(item.kind, .wait)
        XCTAssertEqual(item.subtitle, "Waits for your Mac · asleep since 18:52")
        XCTAssertEqual(item.icon, .glyph(.macbook))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.tasks.run("anna")?.status, .waits)
        desk.virtualMac?.wake()
        XCTAssertFalse(app.browser.macAsleep)
        await wait("done after waking") { app.tasks.run("anna")?.status == .done }
        XCTAssertEqual(app.nowItem?.subtitle, "3 replies drafted · not posted")
    }

    func testTheNowLineOrderAcrossTasks() throws {
        let desk = try desk(world: "tasks-live")
        let app = try XCTUnwrap(desk.app)
        // tasks-live: Drift done, Lumen and Lisbon running, Replies to Anna waiting for a yes.
        let item = try XCTUnwrap(app.nowItem)
        XCTAssertEqual(item.title, "Post replies to Anna")
        XCTAssertEqual(item.subtitle, "Post 3 replies on Launch notes?")
        XCTAssertEqual(item.more, "+3")
        // Running: the latest one speaks.
        app.tasks.set("anna-post", status: .done)
        XCTAssertEqual(app.nowItem?.title, "Lisbon flights")
        XCTAssertEqual(app.nowItem?.more, "+3")
        app.tasks.set("lumen", status: .code, step: 1)
        XCTAssertEqual(app.nowItem?.title, "Design Systems Night")
        app.tasks.set("drift", status: .failed)
        XCTAssertEqual(app.nowItem?.title, "Design Systems Night", "a code comes before what failed")
        app.tasks.set("lisbon", status: .yes, step: 3)
        XCTAssertEqual(app.nowItem?.title, "Lisbon flights", "a yes comes first")
    }

    func testTheLiveActivityNeverNamesTheAmount() throws {
        let world = try World.load(named: "mira")
        let def = try XCTUnwrap(world.taskDefinitions.first { $0.id == "lisbon" })
        let script = MacScript.story["lisbon"]!
        func state(_ status: TaskStatus, _ step: Int) -> TaskActivityAttributes.ContentState? {
            TaskActivityContent.state(run: TaskRun(id: "lisbon", status: status, step: step), def: def, code: script.code,
                                      yes: script.yes, failure: script.failure, script: script)
        }
        let running = try XCTUnwrap(state(.running, 1))
        XCTAssertEqual(running.head, "On your Mac")
        XCTAssertEqual(running.title, "Comparing 4 direct flights")
        XCTAssertEqual(running.line, "TAP €238 · SAS €251 · KLM €212 with a stop")
        XCTAssertEqual(running.word, "4 direct")
        XCTAssertEqual(running.icon, "google")
        XCTAssertEqual(running.buttons.map(\.label), ["Stop"])
        let code = try XCTUnwrap(state(.code, 2))
        XCTAssertEqual(code.title, "TAP sent a code to this \(DeviceWord.name)")
        XCTAssertEqual(code.line, "Your Mac is signing in to flytap.com")
        XCTAssertEqual(code.buttons.map(\.label), ["Enter Code"])
        XCTAssertEqual(code.word, "Code")
        XCTAssertTrue(code.warn)
        let yes = try XCTUnwrap(state(.yes, 3))
        XCTAssertEqual(yes.title, "A payment needs you")
        XCTAssertEqual(yes.line, "The amount shows in Yab after Face ID")
        XCTAssertEqual(yes.buttons.map(\.label), ["Not Now", "Review"])
        for words in [yes.title, yes.line, yes.head, yes.word] {
            XCTAssertFalse(words.contains("€"), "no amount on a locked iPhone: \(words)")
            XCTAssertFalse(words.contains("TAP Air"), "no one paid on a locked iPhone: \(words)")
        }
        let done = try XCTUnwrap(state(.done, 3))
        XCTAssertEqual(done.title, "Booked TAP, seat 14A")
        XCTAssertEqual(done.line, "Confirmation in Mail · flight in Daybook")
        XCTAssertTrue(done.buttons.isEmpty)
        let failed = try XCTUnwrap(state(.failed, 2))
        XCTAssertEqual(failed.head, "Stopped")
        XCTAssertEqual(failed.title, "Couldn’t open flytap.com")
        XCTAssertEqual(failed.buttons.map(\.label), ["Retry"])
        // The Mac asleep: it stays up and says Waits, gray, never an alarm.
        let waits = try XCTUnwrap(TaskActivityContent.state(run: TaskRun(id: "lisbon", status: .waits, asleepSince: "18:52"), def: def,
                                                            code: nil, yes: nil, failure: nil, script: script))
        XCTAssertEqual(waits.word, "Waits")
        XCTAssertFalse(waits.warn)
        XCTAssertEqual(waits.line, "Asleep since 18:52. It starts when the Mac wakes.")
        XCTAssertNil(state(.stopped, 1), "stopped by the person: nothing left to say")
        // Not Now: the Lock Screen stops asking, Review stays.
        let later = try XCTUnwrap(TaskActivityContent.state(run: TaskRun(id: "lisbon", status: .yes, step: 3), def: def, code: nil,
                                                            yes: script.yes, failure: nil, script: script, later: true))
        XCTAssertEqual(later.buttons.map(\.label), ["Review"])
        XCTAssertEqual(later.line, "Not now. It waits for you in Yab.")
        // A refused code says so on the Lock Screen too.
        let refused = try XCTUnwrap(TaskActivityContent.state(run: TaskRun(id: "lisbon", status: .code, step: 2), def: def, code: script.code,
                                                              yes: nil, failure: nil, script: script, refused: true))
        XCTAssertEqual(refused.line, "That code didn’t work. Enter the newest one.")
        // A moving task's words hold 90 s without news; waiting ones until something changes.
        XCTAssertNotNil(TaskActivityController.staleDate(running))
        XCTAssertNil(TaskActivityController.staleDate(yes))
    }

    func testTheChatSaysTheStepsAsThePrototypeDoes() throws {
        let world = try World.load(named: "mira")
        let def = try XCTUnwrap(world.taskDefinitions.first { $0.id == "lisbon" })
        func rows(_ status: TaskStatus, _ step: Int) -> [String] {
            TaskTurns(run: TaskRun(id: "lisbon", status: status, step: step), def: def).rows.map { "\($0.kind) \($0.text)" }
        }
        // stepsDone: the steps reached, the one it works on live while it runs or is sent, the rest ticked.
        XCTAssertEqual(rows(.running, 1), ["done Opened google.com/travel/flights", "live Comparing 4 direct flights"])
        XCTAssertEqual(rows(.sending, 0), ["live Opening google.com/travel/flights"])
        XCTAssertEqual(rows(.code, 2), ["done Opened google.com/travel/flights", "done Compared 4 direct flights", "done Signed in to flytap.com"])
        XCTAssertEqual(rows(.failed, 2).count, 3)
        XCTAssertEqual(rows(.paying, 3).count, 4, "no extra row while it pays")
        XCTAssertEqual(rows(.done, 3).count, 4)
        XCTAssertEqual(rows(.waits, 0), [], "never taken: nothing happened yet")
        XCTAssertEqual(TaskChatSheet.line(.running), "Working · on your Mac")
        XCTAssertEqual(TaskChatSheet.line(.yes), "Waiting for you")
        XCTAssertEqual(TaskChatSheet.line(.done), "On your Mac · Claude")
        XCTAssertEqual(Metrics.TaskChat.foldDistance, 90, "the AI sheet's swipe")
    }

    func testTheTasksChatGrowsOutOfTheNowLine() throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .running, step: 1)
        let line = CGRect(x: 12, y: 736, width: 378, height: 52)
        desk.tapNow(try XCTUnwrap(app.nowItem), action: nil, from: line)
        // One owner: the tasks' sheet (TasksLayer), the chats' layer leaves the route to it.
        XCTAssertEqual(app.surfaces.chat, .task("lisbon"))
        XCTAssertEqual(desk.chatOrigin, .nowLine(line))
    }

    func testTaskConversationReturnsToTheChatsPageWithoutChangingItsConsent() throws {
        let before = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = before }
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .yes, step: 3)
        desk.setRequests("lisbon")
        let chat = try XCTUnwrap(app.chats.chats.first { $0.task == "lisbon" })
        app.openChat(chat.id)
        XCTAssertTrue(app.chatSheet.shown)
        XCTAssertEqual(app.chatSheet.chatID, chat.id)
        XCTAssertEqual(app.chatSheet.mode, .chat)
        XCTAssertEqual(app.surfaces.chat, .task("lisbon"))
        app.escapeSheet()
        XCTAssertFalse(app.chatSheet.shown, "down from a task conversation returns to New Tab's Chats page")
        XCTAssertNil(app.surfaces.chat)
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertEqual(app.tasks.run("lisbon")?.status, .yes, "leaving the chat cannot approve or stop a task")
        XCTAssertNotNil(desk.yeses["lisbon"])
        let line = CGRect(x: 12, y: 736, width: 378, height: 52)
        desk.tapNow(try XCTUnwrap(app.nowItem), action: "Review", from: line)
        XCTAssertEqual(desk.sheet, .yes("lisbon"), "the task still opens its actual consent sheet")
    }

    func testTaskFromNowOverTheChatsPageWithoutStoppingItsRun() throws {
        let before = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = before }
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .running, step: 1)
        app.openChats()
        XCTAssertFalse(app.chatSheet.shown, "Chats is New Tab's page, not the chat sheet")
        let line = CGRect(x: 12, y: 736, width: 378, height: 52)
        desk.openChat("lisbon", from: .nowLine(line))
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertEqual(app.surfaces.chat, .task("lisbon"))
        desk.foldChat()
        XCTAssertNil(app.surfaces.chat)
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertEqual(app.tasks.run("lisbon")?.status, .running)
    }

    func testATaskChatOwnsTheBackdropAfterAnotherSheet() throws {
        let before = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = before }
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lisbon")
        app.surfaces.scrim = 0.32
        app.surfaces.chromeOpacity = 0
        desk.openChat("lisbon", from: .other(nil))
        XCTAssertEqual(app.surfaces.scrim, 0)
        XCTAssertEqual(app.surfaces.chromeOpacity, 1)
        desk.foldChat()
        XCTAssertEqual(app.surfaces.recede, 0)
        XCTAssertEqual(app.surfaces.scrim, 0)
    }

    func testALiveActivityActionRequiresAuthentication() {
        XCTAssertEqual(TaskActivityIntent.authenticationPolicy, .requiresAuthentication)
    }

    func testALinkClearsTheTaskSheetWithoutStoppingItsTask() throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .yes, step: 3)
        desk.setRequests("lisbon")
        desk.showYes("lisbon", from: nil)
        desk.dismissForLink()
        XCTAssertNil(desk.sheet)
        XCTAssertNil(desk.faceID)
        XCTAssertEqual(app.tasks.run("lisbon")?.status, .yes)
    }

    func testAWrongCodeIsSaidAndTheCodeIsNotGiven() async throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        desk.send("lisbon", words: "book")
        await wait("the code") { app.tasks.run("lisbon")?.status == .code }
        let before = Haptics.played.count
        desk.giveCode("lisbon", code: "111111")
        await wait("refused") { desk.refused.contains("lisbon") }
        XCTAssertEqual(app.tasks.run("lisbon")?.status, .code)
        XCTAssertEqual(app.tasks.run("lisbon")?.codeGiven, false, "the Mac didn't take it")
        XCTAssertEqual(Haptics.played.dropFirst(before).map(\.kind), [.warning])
        XCTAssertEqual(app.surfaces.toast?.text, "TAP didn’t take that code. Enter the newest one.")
        desk.giveCode("lisbon", code: "482913")
        XCTAssertFalse(desk.refused.contains("lisbon"))
        await wait("signed in") { app.tasks.run("lisbon")?.codeGiven == true }
    }

    func testStopIsQuiet() async throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        desk.send("lisbon", words: "book")
        await wait("running") { app.tasks.run("lisbon")?.status == .running }
        let before = Haptics.played.count
        desk.act(task: "lisbon", action: "stop")
        await wait("stopped") { app.tasks.run("lisbon")?.status == .stopped }
        XCTAssertNil(app.nowItem, "the person's own Stop leaves nothing to say")
        XCTAssertTrue(Haptics.played.dropFirst(before).isEmpty, "no alarm for their own Stop")
    }

    func testWaitingSaysWhenTheMacFellAsleepOrThatItHasntAnswered() async throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lumen")
        desk.apply(.waits("lumen"))
        XCTAssertEqual(app.nowItem?.subtitle, "Waits for your Mac · no answer yet", "awake, it just hasn't answered")
        desk.virtualMac?.sleep()
        desk.apply(.waits("lumen"))
        XCTAssertEqual(app.nowItem?.subtitle, "Waits for your Mac · asleep since 18:52")
    }

    func testOneMacForTasksAndClaude() async throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        // The chats (or sync) learn the Mac fell asleep: the virtual Mac sleeps too.
        app.browser.macAsleep = true
        await wait("asleep") { desk.virtualMac?.presence.awake == false }
        XCTAssertEqual(desk.macAsleepSince, "18:52")
        var answered = false
        let waiting = Task { @MainActor in
            await desk.whenMacAwake()
            answered = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(answered, "Claude's answer waits for the same Mac")
        app.browser.macAsleep = false
        await waiting.value
        XCTAssertTrue(desk.presence.awake)
    }

    func testLockScreenTapsWhileYabWasntRunningAreActedOnAtStart() throws {
        UserDefaults.standard.set(try JSONEncoder().encode([TaskIntentRouter.Pending(task: "lisbon", action: "stop")]),
                                  forKey: "yab.tasks.pendingActivityActions")
        let app = AppModel(world: try World.load(named: "mira"))
        apps.append(app)
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .running, step: 1)
        let desk = TaskDesk(app: app, script: MacScript(stepSeconds: 0.02), signer: StandInSigner(match: true), still: false, activities: false)
        app.taskDesk = desk
        XCTAssertEqual(app.tasks.run("lisbon")?.status, .stopped)
        XCTAssertTrue(TaskIntentRouter.takePending().isEmpty, "read once")
    }

    func testPayTwiceSignsOnce() async throws {
        let signer = SystemPanelSigner()
        let desk = try desk(signer: signer)
        let app = try XCTUnwrap(desk.app)
        desk.send("lisbon", words: "book")
        await wait("the code") { app.tasks.run("lisbon")?.status == .code }
        desk.giveCode("lisbon", code: "482913")
        await wait("the yes") { app.tasks.run("lisbon")?.status == .yes }
        desk.showYes("lisbon", from: nil)
        async let first: Void = desk.approve("lisbon")
        async let second: Void = desk.approve("lisbon")
        _ = await (first, second)
        await wait("done") { app.tasks.run("lisbon")?.status == .done }
        XCTAssertEqual(signer.signs, 1, "a system panel leaves faceID nil while it authenticates")
        XCTAssertEqual(desk.virtualMac?.diary.filter { $0 == "Checked the Face ID signature from the \(DeviceWord.name)" }.count, 1)
    }

    func testStoppingDuringFaceIDDoesNotDeliverTheYes() async throws {
        let signer = SystemPanelSigner()
        let desk = try desk(signer: signer)
        let app = try XCTUnwrap(desk.app)
        desk.send("lisbon", words: "book")
        await wait("the code") { app.tasks.run("lisbon")?.status == .code }
        desk.giveCode("lisbon", code: "482913")
        await wait("the yes") { app.tasks.run("lisbon")?.status == .yes }
        let approval = Task { @MainActor in await desk.approve("lisbon") }
        await wait("Face ID") { desk.signing }
        desk.stop("lisbon")
        await approval.value
        XCTAssertEqual(app.tasks.run("lisbon")?.status, .stopped)
        XCTAssertNil(desk.faceID)
        XCTAssertFalse(desk.virtualMac?.diary.contains("Checked the Face ID signature from the \(DeviceWord.name)") ?? true)
    }

    func testReviewAfterNotNowCanStillSignTheYes() async throws {
        let desk = try desk(signer: SystemPanelSigner())
        let app = try XCTUnwrap(desk.app)
        desk.send("lisbon", words: "book")
        await wait("the code") { app.tasks.run("lisbon")?.status == .code }
        desk.giveCode("lisbon", code: "482913")
        await wait("the yes") { app.tasks.run("lisbon")?.status == .yes }
        desk.notNow("lisbon")
        XCTAssertTrue(desk.later.contains("lisbon"))
        desk.showYes("lisbon", from: nil)
        XCTAssertFalse(desk.later.contains("lisbon"))
        await desk.approve("lisbon")
        await wait("done") { app.tasks.run("lisbon")?.status == .done }
    }

    func testASheetFromTheLockScreenGoesBackIntoTheNowLine() throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .code, step: 2)
        desk.setRequests("lisbon")
        XCTAssertTrue(desk.open(URL(string: "yab://task/lisbon/code")!))
        let button = try XCTUnwrap(desk.sheetOrigin?.rect)
        XCTAssertGreaterThan(button.minY, 600, "grown out of the Lock Screen's button")
        let was = Motion.disabled
        Motion.disabled = false
        defer { Motion.disabled = was }
        desk.closeSheet()
        let line = ChromeGeometry(size: TaskDesk.screen, folded: false, hasNow: true).now
        XCTAssertEqual(desk.sheetOrigin?.rect, line, "back into the Now line, not the Lock Screen's empty place")
        XCTAssertFalse(desk.sheetLeaving)
    }

    func testTheLiveActivitysLinksOpenTheRightSheet() throws {
        let desk = try desk()
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .yes, step: 3)
        desk.setRequests("lisbon")
        XCTAssertTrue(desk.open(URL(string: "yab://task/lisbon/review")!))
        XCTAssertEqual(desk.sheet, .yes("lisbon"))
        XCTAssertFalse(desk.open(URL(string: "https://lumen.events")!), "not a task's link")
    }

    func testFaceIDNotRecognizedLeavesTheYesWaiting() async throws {
        let desk = try desk(signer: StandInSigner(match: false))
        let app = try XCTUnwrap(desk.app)
        app.tasks.start("lisbon")
        app.tasks.set("lisbon", status: .yes, step: 3)
        desk.setRequests("lisbon")
        desk.showYes("lisbon", from: nil)
        await desk.approve("lisbon")
        XCTAssertEqual(app.tasks.run("lisbon")?.status, .yes)
        XCTAssertNil(desk.faceID)
    }
}

/// A system panel stays outside the desk's faceID state while it looks.
@MainActor
private final class SystemPanelSigner: YesSigner {
    private let key = P256.Signing.PrivateKey()
    let showsSystemPanel = true
    private(set) var signs = 0
    var publicKey: P256.Signing.PublicKey { key.publicKey }

    func sign(_ request: YesRequest, task: TaskRun.ID) async throws -> SignedYes {
        signs += 1
        try await Task.sleep(for: .milliseconds(100))
        let digest = request.digest(task: task)
        return SignedYes(digest: digest, signature: try key.signature(for: digest).rawRepresentation)
    }
}
