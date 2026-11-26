import XCTest

/// Tasks on the Mac, from this iPhone, against the virtual Mac: a task from
/// words runs to "needs the code", the code goes in, it goes on to "needs a
/// yes", Face ID signs it (the simulator's enrolled face, matched), done;
/// with the Mac asleep it waits and goes on after it wakes; it fails and
/// Retry goes on; the Now line grows the task's chat and a swipe down folds
/// it back; the Live Activity shows on the Island and the Lock Screen.
/// Frames are the prototype's (sizes.md), haptics the journal's, motions
/// the motion journal's.
final class TasksTests: XCTestCase {
    private var app: XCUIApplication!
    private var haptics: URL!
    private var motions: URL!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        haptics = folder.appendingPathComponent("haptics-\(UUID().uuidString).log")
        motions = folder.appendingPathComponent("motions-\(UUID().uuidString).log")
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = haptics.path
        app.launchEnvironment["YAB_MOTION_JOURNAL"] = motions.path
    }

    override func tearDown() {
        app.terminate()
    }

    private var now: XCUIElement { app.descendants(matching: .any)["chrome.now"] }
    private var screen: CGRect { app.windows.firstMatch.frame }

    /// Waits for the Now line to say `words`.
    @discardableResult
    private func nowSays(_ words: String, timeout: TimeInterval = 40, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if now.exists, now.label.contains(words) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("the Now line never said “\(words)”; it says “\(now.exists ? now.label : "nothing")”", file: file, line: line)
        return false
    }

    /// Something on screen says `words`.
    private func has(_ words: String, timeout: TimeInterval = 2) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func journal(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // "<seconds> <kind> <reason>" → "<kind> <reason>"
        return text.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertFrame(_ element: XCUIElement, _ expected: CGRect, _ what: String, tolerance: CGFloat = 2,
                             file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        XCTAssertEqual(frame.minX, expected.minX, accuracy: tolerance, "\(what) x: \(frame)", file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: tolerance, "\(what) y: \(frame)", file: file, line: line)
        XCTAssertEqual(frame.width, expected.width, accuracy: tolerance, "\(what) width: \(frame)", file: file, line: line)
        XCTAssertEqual(frame.height, expected.height, accuracy: tolerance, "\(what) height: \(frame)", file: file, line: line)
    }

    // MARK: - the whole task

    func testATaskFromWordsRunsThroughTheCodeAndTheYesWithFaceID() throws {
        Biometrics.enroll()
        // Each of the Mac's steps holds the Now line 3 s: at 0.8 a loaded
        // farm Mac's slow queries missed "Comparing" between its neighbors
        // (19eb323a61c14cdf).
        app.launchArguments = ["-YabWorld", "mira", "-YabMacStep", "3",
                               "-YabTaskWords", "book the tap 18:35 to lisbon, window seat"]
        app.launch()
        XCTAssertTrue(now.waitForExistence(timeout: 20), "no Now line after the task was sent")
        XCTAssertTrue(now.label.contains("Lisbon flights"), now.label)
        nowSays("Comparing 4 direct flights")
        assertFrame(now, CGRect(x: 12, y: screen.height - 138, width: screen.width - 24, height: 52), "the Now line")

        // Needs the code: orange, Enter Code; a tap grows the code's sheet out of the line.
        nowSays("Needs the code TAP sent you")
        shot("needs the code")
        now.tap()
        let field = app.textFields["task.code.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no code sheet")
        let sheet = app.descendants(matching: .any)["task.code"]
        XCTAssertTrue(sheet.exists)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("the code's sheet")
        let keyboard = app.keyboards.firstMatch
        let padTop = keyboard.exists ? keyboard.frame.minY : screen.height
        XCTAssertEqual(sheet.frame.minX, 8, accuracy: 2, "the code's sheet: \(sheet.frame)")
        XCTAssertEqual(sheet.frame.width, screen.width - 16, accuracy: 2, "the code's sheet: \(sheet.frame)")
        // On the number pad: 8 over it, or over QuickType's bar above it when the system shows one.
        XCTAssertLessThanOrEqual(sheet.frame.maxY, padTop - 8 + 2, "the sheet stands over the pad (\(padTop)): \(sheet.frame)")
        XCTAssertGreaterThanOrEqual(sheet.frame.maxY, padTop - 8 - 20, "the sheet stands on the pad (\(padTop)): \(sheet.frame)")
        XCTAssertEqual(sheet.frame.height, 220, accuracy: 2, "the code's sheet: \(sheet.frame)")
        XCTAssertTrue(has("TAP sent a code to this \(Atlas.deviceWord)"))
        // As QuickType's code from Messages would: all six at once.
        field.typeText("482913")
        XCTAssertTrue(gone(sheet), "the sheet stays after the code")

        // The Mac signs in with it and goes on to the seat, then needs a yes.
        nowSays("Pay €238 to TAP?")
        now.tap()
        let pay = app.buttons["task.yes.pay"]
        XCTAssertTrue(pay.waitForExistence(timeout: 5), "no yes sheet")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let consent = app.descendants(matching: .any)["task.yes"]
        XCTAssertEqual(consent.frame.minX, 8, accuracy: 2, "the yes: \(consent.frame)")
        XCTAssertEqual(consent.frame.maxY, screen.height - 8, accuracy: 2, "the yes: \(consent.frame)")
        XCTAssertTrue(has("Pay €238.00 to TAP Air Portugal?"))
        XCTAssertTrue(has("ARN 18:35 → LIS 22:10"), "the facts read from the page")
        XCTAssertTrue(has("Visa ·· 4242"), "the facts read from the page")
        assertFrame(pay, CGRect(x: 20, y: screen.height - 136, width: screen.width - 40, height: 52), "Pay with Face ID")
        shot("the yes")
        pay.tap()

        // The system asks once whether Yab may use Face ID; then the face matches.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for allow in [springboard.alerts.buttons["OK"], app.alerts.buttons["OK"], springboard.buttons["OK"]] where allow.waitForExistence(timeout: 2) {
            allow.tap()
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("Face ID")
        // The face, until the system's panel takes it (a match posted before it looks is lost).
        func showTheFace() {
            let end = Date().addingTimeInterval(10)
            while consent.exists, Date() < end {
                Biometrics.match()
                RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            }
        }
        showTheFace()
        // The first look can end with the system's own question about Face ID; then the
        // person taps Pay again, as on an iPhone.
        if consent.exists, pay.exists {
            pay.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            showTheFace()
        }
        let toast = app.descendants(matching: .any)["chrome.toast"]
        XCTAssertFalse(toast.waitForExistence(timeout: 2) && toast.label.contains("Face ID"), "Face ID: \(toast.exists ? toast.label : "")")
        XCTAssertTrue(gone(consent, timeout: 15), "the yes stays after Face ID")
        nowSays("Booked · TAP, Oct 13 18:35, seat 14A")
        shot("done")

        // Done: a tap grows the task's chat out of the line; its result, its tabs.
        now.tap()
        let chat = app.descendants(matching: .any)["task.chat.sheet"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        assertFrame(chat, CGRect(x: 0, y: 60, width: screen.width, height: screen.height - 60), "the task's chat")
        XCTAssertTrue(app.descendants(matching: .any)["task.done"].exists, "no Done in the chat")
        shot("the task's chat")
        // A swipe down folds it into the Now line; opened, the result's line goes.
        app.descendants(matching: .any)["task.chat.who"].swipeDown(velocity: .fast)
        XCTAssertTrue(gone(chat), "the chat stays after a swipe down")
        XCTAssertTrue(gone(now, timeout: 3), "Done stays said after the result was opened")

        // The haptics table: a warning for the code and for the yes, success when signed.
        let felt = journal(haptics)
        XCTAssertEqual(felt.filter { $0 == "warning needs you" }.count, 2, "\(felt)")
        XCTAssertEqual(felt.filter { $0 == "success done" }.count, 1, "\(felt)")
        XCTAssertFalse(felt.contains { $0.hasPrefix("error") }, "\(felt)")
        // Each transition ran its motion: the sheets out of the line and back,
        // the chat out of the line and folded into it, the words in place.
        let moved = journal(motions)
        for motion in ["nowWords", "sheetGrow", "sheetBack", "nowToChat", "chatToNow", "faceIDIn", "faceIDOut"] {
            XCTAssertTrue(moved.contains(motion), "no \(motion) in \(moved)")
        }
    }

    // MARK: - the Mac asleep

    func testTheMacAsleepTheTaskWaitsAndGoesOnWhenItWakes() throws {
        app.launchArguments = ["-YabWorld", "mac-states", "-YabMacWake", "8", "-YabMacStep", "0.8",
                               "-YabTaskWords", "draft replies to anna"]
        app.launch()
        nowSays("Waits for your Mac · asleep since 18:52", timeout: 15)
        XCTAssertTrue(now.label.contains("Replies to Anna"), now.label)
        shot("waits for the Mac")
        // Gray, no alarm: no haptic while it waits.
        XCTAssertFalse(journal(haptics).contains { $0.hasPrefix("warning") || $0.hasPrefix("error") })
        // The Mac wakes: it goes on by itself.
        nowSays("Reading Anna’s 3 comments", timeout: 20)
        nowSays("3 replies drafted · not posted", timeout: 20)
        shot("done after the Mac woke")
    }

    // MARK: - failed, Retry

    func testAFailedTaskSaysWhatAndRetryGoesOnFromTheSameStep() throws {
        app.launchArguments = ["-YabWorld", "mira", "-YabMac", "fail", "-YabMacStep", "0.6",
                               "-YabTaskWords", "book the tap 18:35 to lisbon, window seat"]
        app.launch()
        nowSays("Couldn’t open flytap.com · the page didn’t load")
        XCTAssertTrue(journal(haptics).contains("error failed"), "\(journal(haptics))")
        // The line opens the task's chat, which says what happened and has Retry.
        now.tap()
        let retry = app.buttons["task.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "no Retry in the chat")
        shot("failed, in the chat")
        retry.tap()
        // Again from the same step: the failure goes, the steps go on to the code.
        XCTAssertTrue(gone(retry, timeout: 5), "Retry stays after it was tapped")
        XCTAssertTrue(has("Waiting for the code TAP sent to this \(Atlas.deviceWord)", timeout: 20), "it never went on to the code")
        app.descendants(matching: .any)["task.chat.who"].swipeDown(velocity: .fast)
        nowSays("Needs the code TAP sent you")
    }

    // MARK: - the chat out of the line and back

    func testTheNowLineGrowsTheTasksChatAndASwipeDownFoldsItBack() throws {
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "now.3"]
        app.launch()
        nowSays("Comparing 4 direct flights", timeout: 20)
        let line = now.frame
        now.tap()
        let chat = app.descendants(matching: .any)["task.chat.sheet"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        assertFrame(chat, CGRect(x: 0, y: 60, width: screen.width, height: screen.height - 60), "the task's chat")
        shot("the task's chat out of the line")
        XCTAssertTrue(has("Book the TAP 18:35 to Lisbon, back on the 17th, window seat"), "the ask as the bubble")
        XCTAssertTrue(has("Working · on your Mac"))
        XCTAssertTrue(has("Comparing 4 direct flights"), "the step in words")
        XCTAssertTrue(has("Its tabs, in a folder on your Mac"))
        // A short pull (under the AI sheet's 90 points) springs back.
        let who = app.descendants(matching: .any)["task.chat.who"]
        let from = who.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 50)), withVelocity: .slow, thenHoldForDuration: 0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(chat.exists, "a short pull closed it")
        assertFrame(chat, CGRect(x: 0, y: 60, width: screen.width, height: screen.height - 60), "back in place")
        // A real one folds it into the line, which speaks for the task again.
        who.swipeDown(velocity: .fast)
        XCTAssertTrue(gone(chat))
        XCTAssertTrue(now.waitForExistence(timeout: 3))
        XCTAssertEqual(now.frame.minY, line.minY, accuracy: 2)
        let moved = journal(motions)
        XCTAssertTrue(moved.contains("nowToChat"), "\(moved)")
        XCTAssertTrue(moved.contains("chatToNow"), "\(moved)")
        XCTAssertTrue(moved.contains("chatUnfold"), "the short pull springs back: \(moved)")
    }

    func testATapOnTheDimmedPageClosesTheCodeSheet() throws {
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "now.5"]
        app.launch()
        nowSays("Needs the code TAP sent you", timeout: 20)
        now.tap()
        let sheet = app.descendants(matching: .any)["task.code"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(gone(sheet), "the dimmed page didn't close it")
        XCTAssertTrue(now.label.contains("Needs the code"), "the task still waits for its code")
    }

    // MARK: - outside Yab

    func testTheLiveActivityShowsOnTheLockScreenAndTheIslandOpensTheTask() throws {
        app.launchArguments = ["-YabWorld", "mira", "-YabMacStep", "1.5",
                               "-YabTaskWords", "book the tap 18:35 to lisbon, window seat"]
        app.launch()
        nowSays("Opening google.com/travel/flights")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let device = XCUIDevice.shared
        let lock = NSSelectorFromString("pressLockButton")
        XCTAssertTrue(device.responds(to: lock), "the simulator can't be locked from a test")
        // The Lock Screen: the card says the task; the first time, iOS asks whether Yab may show it.
        device.perform(lock)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        let card = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Lisbon flights")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no Live Activity on the Lock Screen")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("the Lock Screen")
        // No amount on a locked iPhone, whatever the task waits for.
        XCTAssertEqual(springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "€238")).count, 0)
        // Unlocked (no passcode in the simulator), the Home Screen: the task in the Island.
        device.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        device.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("the Island over the Home Screen")
        // A tap on the Island opens Yab at the task: what it needs grows out of the Island.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 29 / 874)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the Island didn't open Yab")
        let opened = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["task.code", "task.yes", "task.chat.sheet"])).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 8), "Yab opened, but not at the task")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("Yab from the Island")
    }

    /// The system's status bar beside a compact activity on this device, as
    /// the pictures of another app with the Island draw it (OutsideYab's
    /// StatusBarPicture): each item's frame goes to the log and a shot.
    func testTheStatusBarBesideACompactActivity() throws {
        app.launchArguments = ["-YabWorld", "mira", "-YabMacStep", "30",
                               "-YabTaskWords", "book the tap 18:35 to lisbon, window seat"]
        app.launch()
        nowSays("Opening google.com/travel/flights")
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var items = springboard.statusBars.firstMatch.descendants(matching: .any).allElementsBoundByIndex
        if items.isEmpty { items = springboard.descendants(matching: .any).allElementsBoundByIndex.filter { $0.frame.maxY < 64 } }
        var lines = ["screen \(screen)"]
        for item in items where item.frame.height > 0 && item.frame.maxY < 64 {
            lines.append("status-bar \(item.elementType.rawValue) '\(item.label)' x \(item.frame.minX) y \(item.frame.minY) w \(item.frame.width) h \(item.frame.height)")
        }
        print(lines.joined(separator: "\n"))
        let text = XCTAttachment(string: lines.joined(separator: "\n"))
        text.name = "status bar items"
        text.lifetime = .keepAlways
        add(text)
        shot("the status bar beside the Island")
    }

    func testTheLockScreensReviewOpensTheYesInYab() throws {
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "now.6"]
        app.launch()
        nowSays("Pay €238 to TAP?", timeout: 20)
        // What Review on the Lock Screen opens.
        XCUIDevice.shared.system.open(URL(string: "yab://task/lisbon/review")!)
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        let pay = app.buttons["task.yes.pay"]
        XCTAssertTrue(pay.waitForExistence(timeout: 8), "the link didn't open the yes")
        XCTAssertTrue(has("Pay €238.00 to TAP Air Portugal?"))
        shot("the yes from the Lock Screen's Review")
    }
}

/// Face ID in the simulator: the enrolled face and its match, as the
/// simulator's Features › Face ID menu posts them (Darwin notifications the
/// simulated BiometricKit listens for).
enum Biometrics {
    private typealias Post = @convention(c) (UnsafePointer<CChar>) -> UInt32
    private typealias Register = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
    private typealias SetState = @convention(c) (Int32, UInt64) -> UInt32

    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func enroll() {
        guard let register = symbol("notify_register_check", Register.self), let set = symbol("notify_set_state", SetState.self),
              let post = symbol("notify_post", Post.self) else { return }
        var token: Int32 = 0
        _ = register("com.apple.BiometricKit.enrollmentChanged", &token)
        _ = set(token, 1)
        _ = post("com.apple.BiometricKit.enrollmentChanged")
    }

    static func match() {
        _ = symbol("notify_post", Post.self)?("com.apple.BiometricKit_Sim.pearl.match")
    }
}
