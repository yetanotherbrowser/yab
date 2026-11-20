import AppKit
import YabCoreClient

/// Own CEF text input: delegated key status for the remote page, and the
/// client side of input methods. Yab's own input context composes (it is the
/// active app); the page's view in YabCore only shows the composition. Caret
/// and composition geometry come from the helper's native text state
/// (page.textInput, UTF-16 ranges, root-page DIP). Helpers without these
/// hooks answer tab.focus with an error, which is ignored.
@MainActor
extension ChromiumPage {
    func watchKeyWindow() {
        keyWatch.forEach(NotificationCenter.default.removeObserver)
        keyWatch = []
        guard let window else { syncRemoteFocus(resigning: true); return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWatch.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusChanged() }
            })
        }
        keyWatch.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sightChanged() }
        })
        // The hidden window follows the page to where it shows (placeProducer).
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            keyWatch.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeProducer() }
            })
        }
        syncRemoteFocus()
    }

    /// The page has focus only while this view is first responder of the key window.
    func syncRemoteFocus(resigning: Bool = false) {
        syncNativeInputContext(resigning: resigning)
        let focused = !resigning && window?.isKeyWindow == true && window?.firstResponder === self && !isHiddenOrHasHiddenAncestor && !windowCovered
        // The pointer comes back with focus, before Chromium ends the lock.
        if !focused { ChromiumPointerLock.release(self) }
        if !focused, remoteFocused == true || hasMarkedText() { discardNativeComposition() }
        guard remoteID != nil, remoteFocused != focused else { return }
        remoteFocused = focused
        if extensionPopup != nil { popupTrace("owner page focus \(focused)") }
        // Enqueue synchronously with keyboard input. A separate Task calling
        // navigationRequest waits for whatever tail exists when it starts:
        // an immediate external paste can become that tail and run while the
        // renderer is still unfocused. It can also overtake a preceding blur.
        command("tab.focus", ["focused": .bool(focused)])
    }

    /// Native focus is authoritative when available. Older helpers use the
    /// page's existing caret report until they publish native text state.
    var inputMethodEditable: Bool {
        if let nativeText { return ChromiumNativeTextInput.focusToken(nativeText) != nil }
        return navigationTab?.typing == true
    }

    /// Routes a key through Yab's input context while a page field has the
    /// keyboard or words are being composed
    /// (ChromiumKeyInterpretation says why). Returns true when the page must
    /// not get the key itself.
    func composeKey(_ event: NSEvent) -> Bool {
        guard Self.usesInputContext(event, marked: hasMarkedText(), editable: inputMethodEditable),
              let context = inputContext else { return false }
        let source = context.selectedKeyboardInputSource ?? ""
        let inputMethod = source.contains(".inputmethod.")
        // NSEvent.characters can already contain the composed character. A
        // matching insert still has to commit the renderer's marked text.
        let composing = hasMarkedText()
        imeHandled = false
        keyInterpretation = ChromiumKeyInterpretation()
        let taken = context.handleEvent(event)
        let heard = keyInterpretation ?? ChromiumKeyInterpretation()
        keyInterpretation = nil
        let route = heard.route(typed: event.characters, inputMethod: inputMethod, taken: taken, composing: composing)
        if Store.testing {
            keyRoutes = Array((keyRoutes + ["\(event.keyCode)\(event.isARepeat ? " repeat" : "") taken=\(taken) edits=\(heard.edits) commands=\(heard.commands) \(route)"]).suffix(24))
        }
        switch route {
        case .page:
            return false
        case .kept:
            // A held letter's keydown reached the page, so its keyup does
            // too; a key the page never saw goes up unseen as well.
            if !event.isARepeat { imeKeys.insert(event.keyCode) }
            return true
        case .inputMethod:
            heard.edits.forEach(sendTextEdit)
            imeKeys.insert(event.keyCode)
            return true
        }
    }

    /// Every editable field uses the Mac's context, including plain keys
    /// that can open the accent menu. Page shortcuts outside a field and
    /// Command shortcuts keep the page's key-event path.
    static func usesInputContext(_ event: NSEvent, marked: Bool, editable: Bool = false) -> Bool {
        (editable || marked) && !event.modifierFlags.contains(.command)
    }

    var nativeInputEligible: Bool {
        inputMethodFocused && !windowCovered && ChromiumNativeTextInput.focusToken(nativeText) != nil
    }

    private var editingState: [String: JSONValue]? {
        guard let state = nativeText, ChromiumNativeTextInput.focusToken(state) != nil else { return nil }
        return state
    }

    func nativeRange(_ key: String) -> NSRange? {
        ChromiumNativeTextInput.range(editingState?[key])
    }

    func nativeSubstring(_ range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let state = editingState, let text = state["surrounding"]?.string,
              let offset = state["surroundingOffset"]?.string.flatMap(Int.init) else { return nil }
        let units = text.utf16
        let local = NSRange(location: range.location - offset, length: range.length)
        guard local.location >= 0, local.location <= units.count else { return nil }
        let clamped = NSRange(location: local.location, length: min(local.length, units.count - local.location))
        actualRange?.pointee = NSRange(location: clamped.location + offset, length: clamped.length)
        return NSAttributedString(string: (text as NSString).substring(with: clamped))
    }

    /// Screen rectangle for a character range, for the candidate window.
    func nativeFirstRect(_ range: NSRange) -> NSRect {
        guard nativeInputEligible, let window, let state = editingState else { return .zero }
        var rect: [String: JSONValue]?
        if case .array(let boxes)? = state["compositionBounds"], let composition = nativeRange("composition") {
            let index = range.location - composition.location
            if index >= 0, index < boxes.count, case .object(let box) = boxes[index] { rect = box }
        }
        if rect == nil, case .object(let caret)? = state["caretBounds"] { rect = caret }
        guard let rect, let x = rect["x"]?.number, let y = rect["y"]?.number,
              let w = rect["width"]?.number, let h = rect["height"]?.number,
              [x, y, w, h].allSatisfy(\.isFinite), w >= 0, h > 0 else { return .zero }
        // Root-page DIP has a top-left origin; this view is not flipped.
        let local = NSRect(x: x, y: bounds.height - y - h, width: max(1, w), height: max(1, h))
        return window.convertToScreen(convert(local, to: nil))
    }
}
