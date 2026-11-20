import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// Native forwarding needs the prepared-app original renderer probe. These
/// exercise the actual page's local invalidation and adapter refusal only.
@Suite(.serialized)
@MainActor
struct ChromiumInputMethodTests {
    @Test func checkingDocumentKeepsThePageAsItsNativeClient() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.receiveNativeTextInput(native())
        let client: any NSTextCheckingClient = page
        #expect(client.selectedRange() == page.selectedRange())
        page.contentType = .emailAddress
        #expect((client as? NSTextContent)?.contentType == .emailAddress)
        (client as? NSTextContent)?.contentType = .oneTimeCode
        #expect(page.contentType == .oneTimeCode)
        client.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(client.hasMarkedText() && page.hasMarkedText())
        client.unmarkText()
        #expect(!client.hasMarkedText() && !page.hasMarkedText())
        // Calls through the native protocol retain the page's refusal gates.
        client.insertText("dictation", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(page.inputMethodTicket?.result == .refused && page.inputMethodDispatched == 0)
    }

    @Test func checkingDocumentKeepsNativeUTF16OffsetsAndBoundsAnnotations() throws {
        var state = native()
        state["surrounding"] = .string("a🙂 b\nnext")
        state["surroundingOffset"] = .string("100")
        let snapshot = try #require(ChromiumTextCheckingSnapshot(state: state))
        #expect(snapshot.localRange(NSRange(location: 101, length: 2)) == NSRange(location: 1, length: 2))
        #expect(snapshot.localRange(NSRange(location: 98, length: 4)) == NSRange(location: 0, length: 2))
        #expect(snapshot.localRange(NSRange(location: 98, length: 1)) == nil)
        #expect(snapshot.localRange(NSRange(location: 111, length: 0)) == nil)
        #expect(snapshot.localRange(NSRange(location: NSNotFound, length: 0)) == NSRange(location: 0, length: 10))
        #expect(snapshot.localRange(NSRange(location: 101, length: Int.max)) == NSRange(location: 1, length: 9))
        #expect(snapshot.documentRange(NSRange(location: 1, length: 2)) == NSRange(location: 101, length: 2))
        #expect(snapshot.mutationRange(NSRange(location: 101, length: 2)) == NSRange(location: 101, length: 2))
        #expect(snapshot.mutationRange(NSRange(location: 98, length: 4)) == nil)
        #expect(snapshot.mutationRange(NSRange(location: 101, length: Int.max)) == nil)
        #expect(snapshot.mutationRange(NSRange(location: NSNotFound, length: 0)) == nil)
        state["surroundingOffset"] = .string("-1")
        #expect(ChromiumTextCheckingSnapshot(state: state) == nil)
        state["surroundingOffset"] = .string(String(Int.max))
        #expect(ChromiumTextCheckingSnapshot(state: state) == nil)
    }

    @Test func checkingDocumentNeverInventsSurroundingTextForAnUnknownEditor() throws {
        var state = native()
        #expect(ChromiumTextCheckingSnapshot(state: state) == nil)
        state["hasSurrounding"] = .bool(false)
        #expect(ChromiumTextCheckingSnapshot(state: state) == nil) // nonempty selection
        state["selection"] = .object(["valid": .bool(true), "start": .number(0), "end": .number(0)])
        #expect(ChromiumTextCheckingSnapshot(state: state) == nil) // a caret at zero does not prove emptiness
        state["hasSurrounding"] = .bool(true)
        state["surrounding"] = .string("")
        state["surroundingOffset"] = .string("0")
        let empty = try #require(ChromiumTextCheckingSnapshot(state: state))
        #expect(empty.text.length == 0 && empty.offset == 0)
        state["cancelled"] = .bool(true)
        #expect(ChromiumTextCheckingSnapshot(state: state) == nil)
    }

    @Test func editableKeysReachTheInputContextWithoutTakingPageShortcuts() throws {
        func key(_ text: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: 14))
        }
        #expect(ChromiumPage.usesInputContext(try key("´", .option), marked: false, editable: true))
        #expect(ChromiumPage.usesInputContext(try key("ç", .option), marked: false, editable: true))
        #expect(ChromiumPage.usesInputContext(try key(""), marked: false, editable: true))
        #expect(ChromiumPage.usesInputContext(try key("e"), marked: false, editable: true))
        #expect(!ChromiumPage.usesInputContext(try key("e", [.command, .option]), marked: true, editable: true))
    }

    // #1785: the page body is not an editing target. Selecting Pinyin must
    // not turn video shortcuts into text or open the candidate window.
    @Test func inputContextLeavesNonEditingPageShortcutsAlone() throws {
        for (text, code) in [(" ", 49), ("k", 40), ("f", 3), ("m", 46)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false,
                keyCode: UInt16(code)))
            #expect(!ChromiumPage.usesInputContext(event, marked: false))
        }
    }

    @Test func editingFocusGatesCompositionAndNativeStateOverridesOldCaretReports() throws {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        #expect(!page.inputMethodEditable)
        tab.typing = true
        #expect(page.inputMethodEditable) // older helper's caret report
        var body = native(); body["editable"] = .bool(false)
        page.receiveNativeTextInput(body)
        #expect(!page.inputMethodEditable) // stale caret report cannot override it
        page.receiveNativeTextInput(native())
        #expect(page.inputMethodEditable)
        var cancelled = native(); cancelled["cancelled"] = .bool(true)
        page.receiveNativeTextInput(cancelled)
        #expect(!page.inputMethodEditable)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        #expect(ChromiumPage.usesInputContext(event, marked: false, editable: true))
        #expect(ChromiumPage.usesInputContext(event, marked: true, editable: false))
        #expect(!ChromiumPage.usesInputContext(event, marked: false, editable: false))
    }


    @Test func interpretationKeepsPlainKeysButCommitsAnExistingComposition() {
        let none = NSRange(location: NSNotFound, length: 0)
        var read = ChromiumKeyInterpretation()
        read.edits = [.insert("e", replacing: none)]
        #expect(read.route(typed: "e", inputMethod: false, taken: true) == .page)
        read.edits = [.insert("é", replacing: none)]
        #expect(read.route(typed: "é", inputMethod: false, taken: true, composing: true) == .inputMethod)
        read.edits = [.insert("é", replacing: NSRange(location: 4, length: 1))]
        #expect(read.route(typed: "é", inputMethod: false, taken: true) == .inputMethod)
        read.edits = [.mark("に", selected: NSRange(location: 1, length: 0), replacing: none)]
        #expect(read.route(typed: "n", inputMethod: true, taken: true) == .inputMethod)
        read.edits = []
        #expect(read.route(typed: "2", inputMethod: false, taken: true) == .kept)
        #expect(read.route(typed: "e", inputMethod: false, taken: false) == .page)
        read.commands = 1
        #expect(read.route(typed: "\u{7f}", inputMethod: false, taken: true) == .page)
    }

    @Test func replacementCoordinatesAreUTF16AndMarkedTextStartsAtTheSelection() {
        #expect(ChromiumNativeTextInput.replacementFields(NSRange(location: NSNotFound, length: 0)).isEmpty)
        #expect(ChromiumNativeTextInput.replacementFields(NSRange(location: Int.max - 1, length: 4)).isEmpty)
        #expect(ChromiumNativeTextInput.replacementFields(NSRange(location: 3, length: 2)) ==
                ["replacementStart": .number(3), "replacementLength": .number(2)])
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.receiveNativeTextInput(native())
        page.setMarkedText("に🙂", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(page.markedRange() == NSRange(location: 2, length: 3))
        page.discardNativeComposition()
        #expect(!page.hasMarkedText())
    }

    private func native(_ token: String = "41") -> [String: JSONValue] {
        ["stateVersion": .number(1), "coordinateSpace": .string("rootPage"),
         "editable": .bool(true), "focusToken": .string(token), "revision": .string("8"),
         "selection": .object(["valid": .bool(true), "start": .number(2), "end": .number(4)])]
    }

    @Test func inactiveClientNeverOffersAContextOrGuessedCaret() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        #expect(page.inputContext == nil)
        #expect(page.nativeFirstRect(NSRange(location: 0, length: 0)) == .zero)
        page.receiveNativeTextInput(native())
        #expect(page.inputContext == nil, "A cached detached editable page must not become a text client")
        #expect(page.nativeFirstRect(NSRange(location: 2, length: 0)) == .zero)
        page.resetNativeTextInput()
        #expect(page.inputContext == nil)
    }

    private final class InputWindow: NSWindow {
        // The suite runs without a display lease. Model key-window status
        // without activating a test window over another farm job's app.
        override var isKeyWindow: Bool { true }
    }

    @Test func inputContextAndCaretFollowActualEditableResponder() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let window = InputWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        defer { window.close(); page.retire(call: false, pictureInPicture: false); tab.close() }
        #expect(window.makeFirstResponder(page))
        #expect(page.inputMethodFocused)
        #expect(page.inputContext == nil)
        var state = native()
        state["caretBounds"] = .object(["x": .number(100), "y": .number(80),
                                       "width": .number(0), "height": .number(22)])
        page.receiveNativeTextInput(state)
        let context = try #require(page.inputContext)
        // IME services must reach the editing responder itself. A second
        // client can handle layout keys yet never start a conversion session.
        #expect((context.client as AnyObject) === page)
        #expect(context.client is NSTextCheckingClient)
        #expect(page.nativeFirstRect(NSRange(location: 2, length: 0)) ==
                window.convertToScreen(page.convert(NSRect(x: 100, y: page.bounds.height - 102, width: 1, height: 22), to: nil)))
        state["caretBounds"] = nil
        page.receiveNativeTextInput(state)
        #expect(page.nativeFirstRect(NSRange(location: 2, length: 0)) == .zero)
        state["editable"] = .bool(false)
        page.receiveNativeTextInput(state)
        #expect(page.inputContext == nil)
        state["editable"] = .bool(true)
        page.receiveNativeTextInput(state)
        #expect(page.inputContext === context)
        window.makeFirstResponder(nil)
        #expect(page.inputContext == nil)
        #expect(page.nativeFirstRect(NSRange(location: 2, length: 0)) == .zero)
    }

    @Test func helperLossClearsTheActualInputClientCompositionWithoutRecreatingAnEndpoint() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        // Direct AppKit client state is local. With no helper/view it cannot
        // forward any input or serve as native composition acceptance.
        page.setMarkedText("に🙂", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        page.imeHandled = true; page.imeKeys.insert(7)
        #expect(page.hasMarkedText())
        let generation = page.inputMethodGeneration
        page.helperExited()
        #expect(!page.hasMarkedText() && page.markedRange().location == NSNotFound)
        #expect(!page.imeHandled && page.imeKeys.isEmpty && page.nativeText == nil)
        #expect(page.inputMethodGeneration > generation)
        #expect(page.remoteID == nil && page.inputMethodDispatched == 0)
    }

    @Test func nativeFocusChangeAndCancellationDiscardLocalMarkedStateWithoutUnmarkingANewTarget() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.receiveNativeTextInput(native())
        page.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        page.receiveNativeTextInput(native())
        #expect(page.hasMarkedText(), "An unchanged native focus does not drop a local composition")
        page.receiveNativeTextInput(native("42"))
        #expect(!page.hasMarkedText())
        let range = page.selectedRange()
        #expect(range == NSRange(location: 2, length: 2))
        page.setMarkedText("さ", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        var cancelled = native("42"); cancelled["cancelled"] = .bool(true)
        page.receiveNativeTextInput(cancelled)
        #expect(!page.hasMarkedText() && page.selectedRange().location == NSNotFound)
        #expect(page.remoteID == nil && page.inputMethodDispatched == 0)
    }

    @Test func legacyCocoaForwardingRequiresAnExplicitLegacyHelperAndNoInvalidSnapshot() {
        #expect(ChromiumNativeTextInput.usesLegacyHelper(.number(0)))
        #expect(ChromiumNativeTextInput.usesLegacyHelper(.bool(false)))
        for capability in [nil, .null, .number(1), .bool(true), .string("false")] as [JSONValue?] {
            #expect(!ChromiumNativeTextInput.usesLegacyHelper(capability))
        }
        #expect(!ChromiumNativeTextInput.canForward(nil, legacy: false))
        #expect(ChromiumNativeTextInput.canForward(nil, legacy: true))
        #expect(ChromiumNativeTextInput.canForward(native(), legacy: false))
        #expect(!ChromiumNativeTextInput.canForward([:], legacy: true))
        var cancelled = native(); cancelled["cancelled"] = .bool(true)
        #expect(!ChromiumNativeTextInput.canForward(cancelled, legacy: true))
    }

    @Test func focusMetadataAndUTF16RangesRejectMissingOrMalformedNativeAuthority() {
        var state = native()
        #expect(ChromiumNativeTextInput.focusToken(state) == "41")
        for invalid in [nil, .string("0"), .string("-1"), .string("+1"), .string(""), .string("18446744073709551616")] as [JSONValue?] {
            state["focusToken"] = invalid
            #expect(ChromiumNativeTextInput.focusToken(state) == nil)
        }
        for (start, end) in [(-1.0, 2.0), (1.5, 2.0), (2.0, 1.0), (0.0, Double(Int.max)), (0.0, .infinity)] {
            let value = JSONValue.object(["valid": .bool(true), "start": .number(start), "end": .number(end)])
            #expect(ChromiumNativeTextInput.range(value) == nil)
        }
        #expect(ChromiumNativeTextInput.range(native()["selection"]) == NSRange(location: 2, length: 2))
    }

    @Test func anEarlierDispatchedCommandCannotAcknowledgeARefusedCurrentTicket() {
        let earlier = ChromiumInputMethodTicket(), current = ChromiumInputMethodTicket()
        earlier.result = .dispatched
        current.result = .refused
        let first = earlier.dispatchReport, second = current.dispatchReport
        #expect(first["dispatched"] as? Bool == true)
        #expect(second["dispatched"] as? Bool == false)
        #expect(first["dispatchTicket"] as? String != second["dispatchTicket"] as? String)
        current.result = .unknown
        let uncertain = current.dispatchReport
        #expect(uncertain["dispatched"] is NSNull)
        #expect(uncertain["dispatchResult"] as? String == "unknown")
    }

    @Test func unboundProbeRefusesMutationsAndCancelDoesNotPretendToFinish() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.receiveNativeTextInput(native())
        var reply: [String: Any] = [:]
        page.probeNativeInputMethod(["action": "mark", "remote": "foreign", "localTurn": 0,
                                    "focusToken": "41", "text": "に", "selectionStart": 1,
                                    "selectionLength": 0]) { reply = $0 }
        #expect(reply["dispatched"] as? Bool == false)
        #expect(reply["refused"] as? String == "original-local-page-or-focus-changed")
        #expect(!page.hasMarkedText() && page.remoteID == nil)
        page.probeNativeInputMethod(["action": "cancel"]) { reply = $0 }
        #expect(reply["dispatched"] as? Bool == false)
        #expect(reply["unavailable"] as? String == "native-cancel-document-lease")
        #expect(reply["nativeLease"] as? Bool == false && reply["documentProof"] as? String == "unavailable")
        #expect(page.remoteID == nil && page.inputMethodDispatched == 0)
    }
}
