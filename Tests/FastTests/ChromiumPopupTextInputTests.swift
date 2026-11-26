import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// Extension popups take Chinese, Japanese and Korean input
/// (extensions parity #3): YabCore says whether the popup's focused element
/// takes text and where its caret is (popup.textInput).
struct ChromiumPopupTextInputTests {
    @Test func readsAFieldAndItsCaret() {
        let state = ChromiumPopupTextInput(["token": .string("t1"), "editable": .bool(true),
            "caret": .object(["x": .number(24), "y": .number(30), "width": .number(1), "height": .number(17)])], token: "t1")
        #expect(state == ChromiumPopupTextInput(editable: true, caret: CGRect(x: 24, y: 30, width: 1, height: 17)))
    }

    @Test func aButtonOrPasswordTakesNoComposition() {
        let state = ChromiumPopupTextInput(["token": .string("t1"), "editable": .bool(false)], token: "t1")
        #expect(state == ChromiumPopupTextInput(editable: false, caret: nil))
    }

    @Test func anotherPopupsStateOrAnUnreadableOneIsRefused() {
        #expect(ChromiumPopupTextInput(["token": .string("t2"), "editable": .bool(true)], token: "t1") == nil)
        #expect(ChromiumPopupTextInput(["token": .string("t1"), "editable": .number(1)], token: "t1") == nil)
        #expect(ChromiumPopupTextInput(["token": .string("t1")], token: "t1") == nil)
    }

    @Test func aCaretThatIsNoRectangleIsDropped() {
        for caret: [String: JSONValue] in [["x": .number(1), "y": .number(1), "width": .number(1), "height": .number(0)],
                                           ["x": .number(.nan), "y": .number(1), "width": .number(1), "height": .number(9)],
                                           ["x": .number(1), "y": .number(1), "width": .number(-1), "height": .number(9)],
                                           ["x": .number(1), "y": .number(1)]] {
            let state = ChromiumPopupTextInput(["token": .string("t1"), "editable": .bool(true), "caret": .object(caret)], token: "t1")
            #expect(state == ChromiumPopupTextInput(editable: true, caret: nil))
        }
    }

    /// Plain typing and composition use the input context in text fields.
    @MainActor @Test func editablePopupKeysUseTheInputContext() throws {
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(ChromiumPage.usesInputContext(key, marked: false, editable: true))
        #expect(!ChromiumPage.usesInputContext(key, marked: false, editable: false))
        let command = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        #expect(!ChromiumPage.usesInputContext(command, marked: true, editable: true))
    }

    /// #922: a plain key in the popup's field is delivered as text through
    /// the input path (keyDown, the input context, insertText), the same
    /// hop that ends in popup.send(["kind": "text"]), and not only routed
    /// by the shared Boolean. A field that takes no text gets nothing.
    @MainActor
    @Test(.enabled("needs a test screen") { await TestScreen.available })
    func aPlainKeyIsDeliveredAsTextThroughThePopupInput() throws {
        let screen = try #require(TestScreen.screen)
        final class RecordingInput: ChromiumPopupInput {
            var inserted: [String] = []
            override func insertText(_ string: Any, replacementRange: NSRange) {
                inserted.append((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
                super.insertText(string, replacementRange: replacementRange)
            }
        }
        func key(_ character: String, _ code: UInt16, window: Int) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: window, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code)
        }

        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let popup = ChromiumExtensionPopup(token: "t1", extensionID: "ext922", page: page)
        popup.receiveTextInput(["token": .string("t1"), "editable": .bool(true),
            "caret": .object(["x": .number(47), "y": .number(84), "width": .number(1), "height": .number(18)])])
        let frame = NSRect(x: 32, y: 32, width: 480, height: 600)
        let typing = RecordingInput(frame: NSRect(origin: .zero, size: frame.size))
        typing.popup = popup
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
        try #require(window.screen === screen)
        defer { window.orderOut(nil) }
        window.contentView = typing
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(typing)
        for (character, code) in [("t", 17), ("e", 14), ("s", 1)] as [(String, UInt16)] {
            typing.keyDown(with: try #require(key(character, code, window: window.windowNumber)))
        }
        #expect(typing.inserted == ["t", "e", "s"])

        popup.receiveTextInput(["token": .string("t1"), "editable": .bool(false)])
        let event = try #require(key("t", 17, window: window.windowNumber))
        // The input view holds the popup weakly.
        withExtendedLifetime(popup) {
            typing.keyDown(with: event)
            #expect(typing.inserted == ["t", "e", "s"])
        }
    }
}
