import XCTest

/// Answers and chats with a finger: hide an answer into the Now line and
/// bring it back, let it go, stand it up into a chat and follow up, go back
/// to New Tab's Chats page and open another, start a new chat from an idea.
/// Haptics are read back from the app's journal. Nothing anywhere says Delete.
final class ChatsTests: XCTestCase {
    private var journal: URL!

    override func setUp() {
        continueAfterFailure = false
        journal = FileManager.default.temporaryDirectory.appendingPathComponent("yab-haptics-\(UUID().uuidString).log")
    }

    private func launch(_ state: String, world: String = "mira", still: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", world, "-YabState", state] + (still ? ["-YabNoAnim", "YES"] : [])
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// The haptics played since launch: "light send", "selection swipe through" …
    private var haptics: [String] {
        let text = (try? String(contentsOf: journal, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// The toast says `words`.
    private func toast(_ app: XCUIApplication, _ words: String) -> Bool {
        let toast = element(app, "chrome.toast")
        return toast.waitForExistence(timeout: 3) && waitFor(toast.label.contains(words))
    }

    private func noDelete(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let delete = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'delete' OR identifier CONTAINS[c] 'delete'"))
        XCTAssertEqual(delete.count, 0, "nothing says Delete", file: file, line: line)
    }

    // MARK: - the answer and the Now line

    func testAnAnswerHidesIntoTheNowLineComesBackAndIsLetGo() {
        let app = launch("chat.1")
        let head = element(app, "chat.answerHead")
        XCTAssertTrue(head.waitForExistence(timeout: 15), "no answer")
        XCTAssertTrue(head.staticTexts["Apple Intelligence"].exists)
        XCTAssertTrue(element(app, "chat.where").label.contains("on this \(Atlas.deviceWord)"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Anna wants")).firstMatch.exists)
        // The answer stands 8 from the screen's edges, at its own height.
        let sheet = element(app, "chat.sheet")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(waitFor(abs(sheet.frame.minX - 8) < 2 && abs(screen.maxY - sheet.frame.maxY - 8) < 2), "answer at \(sheet.frame)")

        // Hide: into the Now line.
        element(app, "chat.hide").tap()
        let now = element(app, "chats.now")
        XCTAssertTrue(now.waitForExistence(timeout: 5), "no Now line")
        XCTAssertTrue(now.label.hasPrefix("Answer"), "the Now line says \(now.label)")
        XCTAssertTrue(now.label.contains("what does anna want?"))
        XCTAssertTrue(waitFor(!head.isHittable), "the sheet went")
        XCTAssertEqual(now.frame.minX, 12, accuracy: 2)
        XCTAssertEqual(now.frame.height, 52, accuracy: 2)

        // A tap brings it back out of the line.
        now.tap()
        XCTAssertTrue(waitFor(head.isHittable), "the answer came back")
        // A swipe down on its head hides it again.
        head.swipeDown(velocity: .fast)
        XCTAssertTrue(waitFor(now.isHittable), "swiped down into the Now line")

        // Flicked aside: let go, nothing left.
        now.swipeLeft(velocity: .fast)
        XCTAssertTrue(waitFor(!now.exists), "let go")
        XCTAssertTrue(haptics.contains("light let go"), "haptics: \(haptics)")
        noDelete(app)
    }

    func testOpenInChatStandsTheAnswerUpAndClaudeCarriesOn() {
        let app = launch("chat.1")
        XCTAssertTrue(element(app, "chat.open").waitForExistence(timeout: 15))
        element(app, "chat.open").tap()
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(title.isHittable))
        XCTAssertEqual(title.label, "Anna\u{2019}s hours picker")
        // An ordinary conversation fills the final tray, edge to edge.
        let sheet = element(app, "chat.sheet")
        XCTAssertTrue(waitFor(abs(sheet.frame.minY) < 2 && abs(sheet.frame.minX) < 1), "chat at \(sheet.frame)")
        // Who answers is said with the name (and in Chat Info), not under it.
        XCTAssertEqual(title.value as? String, "Apple Intelligence \u{00B7} on this \(Atlas.deviceWord)")
        XCTAssertFalse(element(app, "chat.line").exists)

        // The text field itself: its window-frame probe shares the identifier.
        let field = app.textFields["chat.field"]
        field.tap()
        field.typeText("and what did she say about the sprint?")
        let send = element(app, "chat.send")
        XCTAssertTrue(send.waitForExistence(timeout: 3), "the microphone turns into send once there are words")
        send.tap()
        XCTAssertTrue(waitFor(self.haptics.contains("light send")), "haptics: \(haptics)")
        XCTAssertTrue(element(app, "chat.note").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "chat.note").label.contains("Claude carries on, on your Mac"))
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'On Thursday in Slack'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 8), "Claude answered")
        XCTAssertTrue(waitFor((self.element(app, "chat.title").value as? String) == "Claude Opus \u{00B7} on your Mac"))
    }

    // MARK: - the Chats page

    func testBackLandsOnTheChatsPageAndARowOpensItsChat() {
        let app = launch("chat.3")
        let history = element(app, "chat.history")
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        history.tap()
        let grinder = element(app, "newtab.chat.grinder")
        XCTAssertTrue(grinder.waitForExistence(timeout: 5), "‹ lands on New Tab's Chats page")
        XCTAssertTrue(waitFor(!self.element(app, "chat.title").exists && grinder.isHittable))
        let anna = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'newtab.chat.' AND label CONTAINS 'hours picker'")).firstMatch
        XCTAssertTrue(anna.waitForExistence(timeout: 3), "the chat is on the page now")

        grinder.tap()
        let title = element(app, "chat.title")
        XCTAssertTrue(waitFor(title.exists && title.label == "Espresso grinders under $300"), "opened \(title.label)")
        XCTAssertTrue(element(app, "chat.pick").waitForExistence(timeout: 3))

        // Back goes into the same row on the same page.
        element(app, "chat.history").tap()
        XCTAssertTrue(waitFor(!title.exists && self.element(app, "newtab.chat.grinder").isHittable))
    }

    func testANewChatHasIdeasForThePageAndAnIdeaAsksIt() {
        let app = launch("chats.page")
        let new = app.chatsPageNewChat
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        new.tap()
        XCTAssertTrue(element(app, "chat.title").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "chat.title").label, "New Chat")
        let ideas = app.descendants(matching: .any).matching(identifier: "chat.idea")
        XCTAssertTrue(waitFor(ideas.count == 3), "ideas: \(ideas.count)")
        XCTAssertEqual(ideas.element(boundBy: 1).label, "What does Anna want?")
        ideas.element(boundBy: 1).tap()
        XCTAssertTrue(waitFor(self.element(app, "chat.title").label == "Anna\u{2019}s hours picker"), "named by its first words")
        XCTAssertTrue(element(app, "chat.answer").waitForExistence(timeout: 5))
    }

    func testTheChatsMenuPinsCopiesAndArchivesButNeverDeletes() {
        let app = launch("chat.7")
        let menu = app.buttons["Copy Answer"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        for item in ["Pin Chat", "Copy Answer", "Open on MacBook Pro", "Archive Chat"] {
            XCTAssertTrue(app.buttons[item].exists, "no \(item)")
        }
        noDelete(app)
        app.buttons["Copy Answer"].tap()
        XCTAssertTrue(toast(app, "Copied"), "toast: \(element(app, "chrome.toast").label)")
        element(app, "chat.title").press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Archive Chat"].waitForExistence(timeout: 3))
        app.buttons["Archive Chat"].tap()
        XCTAssertTrue(app.chatsPageNewChat.waitForExistence(timeout: 5), "archived, the Chats page in its place")
        XCTAssertTrue(waitFor(!self.element(app, "newtab.chat.cafe").exists))
        XCTAssertTrue(haptics.contains("light archive"))
    }

    func testWithoutAppleIntelligenceThePagesQuestionGoesToClaudeAndSaysSo() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "chat.1", "-YabOnDevice", "none"]
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launch()
        let head = element(app, "chat.answerHead")
        XCTAssertTrue(head.waitForExistence(timeout: 15))
        XCTAssertTrue(head.staticTexts["Claude"].exists, "Claude answers")
        XCTAssertTrue(element(app, "chat.where").label.contains("on your Mac"))
        let answer = element(app, "chat.answer")
        XCTAssertTrue(answer.waitForExistence(timeout: 8), "Claude's answer came")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Anna wants")).firstMatch.exists)
    }

    /// Each transition runs inside its own signpost, so Instruments and
    /// XCTOSSignpostMetric measure exactly it (the durations land in the log:
    /// "measured [Duration (answerToChat), s]"). One walk through all of them:
    /// the answer grows and its question flies, it hides into the Now line
    /// and comes back, stands up into the chat, its menu opens, ‹ takes it
    /// into its card on the Chats page, a card zooms into its chat (those two
    /// are UIKit's own zoom, no signpost of ours), New Chat.
    func testTransitionsRunInsideTheirSignposts() {
        let names = ["answerGrow", "questionFly", "park", "unpark", "answerToChat", "chatMenu"]
        let metrics = names.map { XCTOSSignpostMetric(subsystem: "dev.serafim.fast.iphone", category: "PointsOfInterest", name: $0) }
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: metrics, options: options) {
            let app = launch("chat.1")
            let settle = { RunLoop.current.run(until: Date().addingTimeInterval(0.8)) }
            XCTAssertTrue(element(app, "chat.hide").waitForExistence(timeout: 15))
            settle()
            element(app, "chat.hide").tap()
            XCTAssertTrue(element(app, "chats.now").waitForExistence(timeout: 5))
            settle()
            element(app, "chats.now").tap()
            XCTAssertTrue(waitFor(self.element(app, "chat.open").isHittable))
            settle()
            element(app, "chat.open").tap()
            XCTAssertTrue(waitFor(self.element(app, "chat.title").isHittable))
            settle()
            element(app, "chat.title").press(forDuration: 0.8)
            XCTAssertTrue(app.buttons["Archive Chat"].waitForExistence(timeout: 3))
            settle()
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: 300)).tap()
            XCTAssertTrue(waitFor(!app.buttons["Archive Chat"].exists))
            settle()
            element(app, "chat.history").tap()
            let grinder = element(app, "newtab.chat.grinder")
            XCTAssertTrue(grinder.waitForExistence(timeout: 5))
            XCTAssertTrue(waitFor(grinder.isHittable))
            settle()
            grinder.tap()
            XCTAssertTrue(waitFor(self.element(app, "chat.title").label == "Espresso grinders under $300"))
            settle()
            element(app, "chat.history").tap()
            XCTAssertTrue(app.chatsPageNewChat.waitForExistence(timeout: 5))
            XCTAssertTrue(waitFor(app.chatsPageNewChat.isHittable))
            settle()
            app.chatsPageNewChat.tap()
            XCTAssertTrue(waitFor(self.element(app, "chat.title").label == "New Chat"))
            settle()
            app.terminate()
        }
    }
}

/// Where a person finds chats from a page since the column went (aaf8443d):
/// the spaces' Chats page (b3e8fe50), whose rows grow into their chats and
/// take them back on ‹, and New Chat under the right button (15b7c3a0),
/// whose ‹ goes to the Chats page too.
extension XCUIApplication {
    private func chatsWait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// A control a finger could touch: on screen and hittable. XCTest can't
    /// tell the hittability of one parked off screen and fails the test, so
    /// the frame is asked first.
    func canTouch(_ control: XCUIElement) -> Bool {
        guard control.exists else { return false }
        let frame = control.frame
        guard frame.width > 0, frame.height > 0,
              windows.firstMatch.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        return control.isHittable
    }

    /// The Chats page's New Chat row, in front once the page is.
    var chatsPageNewChat: XCUIElement { descendants(matching: .any)["newtab.chats.new"].firstMatch }

    /// The Chats page's rows, one per chat (New Chat's row is not one).
    var chatsPageRows: XCUIElementQuery {
        descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'newtab.chat.'"))
    }

    /// The plate swiped up to the spaces, then the pages carried right to
    /// Chats, which stands left of the spaces (Private, Chats, the spaces).
    /// A finger on the pages, not the capsule's name: at rest the names
    /// beside the lens run under Yab's mark and the gear. True once the
    /// Chats page is in front.
    @discardableResult
    func openChatsPage(timeout: TimeInterval = 10) -> Bool {
        let newChat = chatsPageNewChat
        if canTouch(newChat) { return true }
        let capsule = descendants(matching: .any)["newtab.capsule"].firstMatch
        if !descendants(matching: .any)["newtab.spaces"].exists {
            // The plate back and in use first: the spaces just put away by ✕
            // still fold into it, and a swipe taken then left the chrome
            // hidden and no spaces up (49ce6fb8b6484bd9, the second reopen).
            let plate = descendants(matching: .any)["chrome.plate"].firstMatch
            _ = chatsWait(timeout) { canTouch(plate) }
            plate.waitUntilStill(timeout: 3)
            SpacesGesture.open(in: self)
            // Once on a loaded farm Mac the plate gave way and no spaces came
            // (farm 3dafdd91612f47d9): keep what the screen showed, and swipe
            // again if the plate is back.
            if !chatsWait(5, { capsule.exists && capsule.frame.width > 0 }) {
                XCTContext.runActivity(named: "No spaces after the plate's swipe") { activity in
                    let picture = XCTAttachment(screenshot: screenshot())
                    picture.name = "no-spaces-after-swipe"; picture.lifetime = .keepAlways; activity.add(picture)
                    let tree = XCTAttachment(string: debugDescription)
                    tree.name = "no-spaces-after-swipe-AX"; tree.lifetime = .keepAlways; activity.add(tree)
                }
                if descendants(matching: .any)["chrome.plate"].firstMatch.exists { SpacesGesture.open(in: self) }
            }
        }
        guard chatsWait(timeout, { capsule.exists && capsule.frame.width > 0 }) else { return false }
        // The capsule names the page in front ("current"), once the pages rest.
        let current = { () -> String in
            let name = capsule.buttons.matching(NSPredicate(format: "value == 'current'")).firstMatch
            return name.exists ? name.label : ""
        }
        let window = windows.firstMatch
        for _ in 0..<6 {
            let now = current()
            if now == "Chats" { break }
            // Past Chats onto Private: one page back the other way.
            let dx = window.frame.width * (now == "Private" ? -0.6 : 0.6)
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: now == "Private" ? 0.85 : 0.25, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
                        withVelocity: .fast, thenHoldForDuration: 0)
            _ = chatsWait(3) { !current().isEmpty && current() != now }
        }
        return chatsWait(timeout) { canTouch(newChat) }
    }

    /// The right button held (+, or the tab stack), then New Chat: a new
    /// chat grows out of it. True once its title stands.
    @discardableResult
    func newChatFromPlus(timeout: TimeInterval = 10) -> Bool {
        let plus = buttons["chrome.plus"]
        guard chatsWait(timeout, { plus.exists && plus.isHittable }) else { return false }
        let item = buttons["chrome.menu.newchat"]
        plus.press(forDuration: 0.8)
        if !item.waitForExistence(timeout: 3) { plus.press(forDuration: 1.2) }
        guard item.waitForExistence(timeout: 5), chatsWait(5, { item.isHittable }) else { return false }
        item.tap()
        let title = descendants(matching: .any)["chat.title"].firstMatch
        return chatsWait(timeout) { title.exists && title.isHittable }
    }
}
