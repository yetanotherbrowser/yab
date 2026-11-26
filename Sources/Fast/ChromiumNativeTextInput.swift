import AppKit
import YabCoreClient

/// Validation of the current native text snapshot. Its focus token identifies
/// a native editing target, but it is not a native document forwarding lease.
enum ChromiumNativeTextInput {
    static func focusToken(_ state: [String: JSONValue]?) -> String? {
        guard let state, state["stateVersion"]?.number == 1,
              state["coordinateSpace"]?.string == "rootPage",
              state["editable"] == .bool(true), state["cancelled"] != .bool(true),
              let token = state["focusToken"]?.string, !token.isEmpty,
              token.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = UInt64(token), value > 0 else { return nil }
        return token
    }

    static func usesLegacyHelper(_ capability: JSONValue?) -> Bool {
        // The Objective-C helper boxes compile-time feature macros as 0/1.
        capability == .bool(false) || capability == .number(0)
    }

    static func canForward(_ state: [String: JSONValue]?, legacy: Bool) -> Bool {
        focusToken(state) != nil || (legacy && state == nil)
    }

    static func range(_ value: JSONValue?) -> NSRange? {
        guard case .object(let row)? = value, row["valid"] == .bool(true),
              let start = row["start"]?.number, let end = row["end"]?.number,
              start.isFinite, end.isFinite, start.rounded(.towardZero) == start,
              end.rounded(.towardZero) == end, start >= 0, end >= start,
              end < Double(Int.max) else { return nil }
        return NSRange(location: Int(start), length: Int(end - start))
    }
    /// The wire fields of a replacement range AppKit gave an insert or a
    /// mark: none when it replaces nothing (NSNotFound).
    static func replacementFields(_ range: NSRange) -> [String: JSONValue] {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= Int(Int32.max) - range.length else { return [:] }
        return ["replacementStart": .number(Double(range.location)), "replacementLength": .number(Double(range.length))]
    }
}

/// What Yab's input context made of one key pressed in a page's field.
///
/// Yab is the active app, so only its input context can run the Mac's text
/// input: the accent menu of a held letter, dead keys, input methods and
/// their candidates. The page's process is never active; its own context
/// shows none of that. So a field's every key goes through Yab's context
/// first, and only a key that came out as its own plain character, or as
/// an editing command, goes on to the page as the key itself (the page
/// reads it into the same character or command, with its keydown, keypress
/// and input events). Everything else reaches the page as the text input
/// system said it: committed or marked text, with the range it replaces.
struct ChromiumKeyInterpretation: Equatable {
    enum Edit: Equatable {
        case insert(String, replacing: NSRange)
        case mark(String, selected: NSRange, replacing: NSRange)
        case unmark
    }

    enum Route: Equatable {
        /// The key goes on to the page, which reads it the same way.
        case page
        /// The input context's edits go to the page; the key does not.
        case inputMethod
        /// The input method finished and left an editing command for the page.
        case inputMethodThenPage
        /// The input context took the key and made nothing of it yet: a held
        /// letter's repeats while its accent menu is coming, or the key that
        /// picks from the open menu (the pick arrives a moment later, as an
        /// insert of its own). Nothing goes to the page, as in a Mac field,
        /// where only the input context's own calls ever type.
        case kept
    }

    var edits: [Edit] = []
    var commands = 0

    /// - Parameters:
    ///   - typed: the key's own characters.
    ///   - inputMethod: an input method (Kana, Pinyin, Hangul) is selected.
    ///   - taken: what the input context answered for the key.
    func route(typed: String?, inputMethod: Bool, taken: Bool, composing: Bool = false) -> Route {
        guard let last = edits.last else {
            // A key the context took without typing or a command is one it
            // keeps; passed on, the page would type it after all.
            return taken && commands == 0 ? .kept : .page
        }
        if commands > 0 {
            // Chromium keeps the key with a candidate that is still marked.
            if case .mark(let text, _, _) = last, !text.isEmpty { return .inputMethod }
            return .inputMethodThenPage
        }
        if !inputMethod, !composing, edits.count == 1,
           case .insert(let text, let range) = last, range.location == NSNotFound,
           let typed, !typed.isEmpty, text == typed { return .page }
        return .inputMethod
    }
}

/// One queued command's RPC outcome. Never infer it from a page-wide counter:
/// an earlier command can finish while this particular command is refused.
@MainActor
final class ChromiumInputMethodTicket {
    enum Result: String { case queued, dispatched, refused, unknown }
    let id = UUID()
    var result = Result.queued
    var dispatchReport: [String: Any] {
        ["dispatchTicket": id.uuidString.lowercased(), "dispatchResult": result.rawValue,
         "dispatched": result == .unknown || result == .queued ? NSNull() : (result == .dispatched) as Any]
    }
}

@MainActor
extension ChromiumPage {
    var inputMethodFocused: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self && !isHiddenOrHasHiddenAncestor
    }

    func receiveNativeTextInput(_ state: [String: JSONValue]) {
        let moved = nativeText?["focusToken"] != state["focusToken"]
        if ChromiumNativeTextInput.focusToken(state) == nil || moved {
            // No unmark is sent: it would commit into a possibly new target.
            discardNativeComposition()
        }
        nativeText = state
        if moved { accessibilityFocusMoved() }
        inputContext?.invalidateCharacterCoordinates()
    }

    /// Disposable-world diagnostics call the same NSTextInputClient methods
    /// as AppKit. A request reply proves dispatch only. The caller must read
    /// the native echo and original renderer events separately.
    func probeNativeInputMethod(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "Native IME probe requires an isolated world"]); return }
        let action = request["action"] as? String ?? "state"
        if action == "state" { answer(nativeInputMethodDescription()); return }
        if action == "cancel" {
            var result = nativeInputMethodDescription()
            result["dispatched"] = false
            result["unavailable"] = "native-cancel-document-lease"
            answer(result); return
        }
        guard ["mark", "commit", "finish", "first-client-text"].contains(action) else {
            answer(["error": "state, mark, commit, finish, cancel or first-client-text required"]); return
        }
        let observedFocus = ChromiumNativeTextInput.focusToken(nativeText)
        let expectedFocus = request["focusToken"] as? String
        guard inputMethodLive, inputMethodFocused,
              let remote = request["remote"] as? String, remote == remoteID,
              let turn = request["localTurn"] as? Int, turn == inputMethodTurn,
              action == "first-client-text" || (expectedFocus != nil && expectedFocus == observedFocus) else {
            var result = nativeInputMethodDescription()
            result["dispatched"] = false
            result["refused"] = "original-local-page-or-focus-changed"
            answer(result); return
        }
        let generation = inputMethodGeneration, previous = inputMethodTicket
        switch action {
        case "mark":
            guard let text = request["text"] as? String, text.utf16.count <= 16_384,
                  let start = request["selectionStart"] as? Int,
                  let length = request["selectionLength"] as? Int,
                  start >= 0, start <= text.utf16.count, length >= 0,
                  length <= text.utf16.count - start else {
                answer(["error": "Bounded text and exact UTF16 selection required"]); return
            }
            setMarkedText(text, selectedRange: NSRange(location: start, length: length),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        case "commit", "first-client-text":
            guard let text = request["text"] as? String, text.utf16.count <= 16_384,
                  action != "first-client-text" || (!text.isEmpty && text.count == 1 && text.utf16.count <= 8) else {
                answer(["error": "Bounded commit text required"]); return
            }
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        default: unmarkText()
        }
        let ticket = inputMethodTicket !== previous ? inputMethodTicket : nil
        afterInputMethodDispatch { [weak self] in
            guard let self else { answer(["error": "Original page released"]); return }
            var result = self.nativeInputMethodDescription()
            if let ticket { result.merge(ticket.dispatchReport) { _, owned in owned } }
            else { result["dispatched"] = false; result["dispatchResult"] = "notQueued" }
            result["localIdentityCurrent"] = self.remoteID == remote && self.inputMethodTurn == turn &&
                self.inputMethodGeneration == generation && ChromiumNativeTextInput.focusToken(self.nativeText) == observedFocus
            if action == "first-client-text" {
                result["diagnosticNoFocusWait"] = true
                result["nativeFocusBefore"] = observedFocus as Any? ?? NSNull()
                result["scope"] = "Actual first NSTextInputClient insertText; no native focus pre-wait, no production guard bypass"
            }
            answer(result)
        }
    }

    func nativeInputMethodDescription() -> [String: Any] {
        func describe(_ range: NSRange) -> [String: Any] {
            ["location": range.location == NSNotFound ? NSNull() : range.location as Any, "length": range.length]
        }
        let state = nativeText.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let caret = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let nativeCaret: Bool = {
            guard ChromiumNativeTextInput.focusToken(nativeText) != nil,
                  case .object(let row)? = nativeText?["caretBounds"],
                  let x = row["x"]?.number, let y = row["y"]?.number,
                  let w = row["width"]?.number, let h = row["height"]?.number else { return false }
            return [x, y, w, h].allSatisfy(\.isFinite) && w >= 0 && h > 0 && window != nil
        }()
        let responder = window?.firstResponder as? NSView
        let client = responder as? NSTextInputClient
        let responderCaret = client.map { $0.firstRect(forCharacterRange: $0.selectedRange(), actualRange: nil) } ?? .zero
        return ["responderClass": responder.map { String(describing: type(of: $0)) } ?? "",
                "responderInputContext": responder?.inputContext != nil,
                "inputContextIsCurrent": inputContext != nil && NSTextInputContext.current === inputContext,
                "inputContextClientClass": inputContext.map { String(describing: type(of: $0.client)) } ?? "",
                "inputContextClientIsResponder": inputContext.map { ($0.client as AnyObject) === self } ?? false,
                "responderCaret": [responderCaret.minX, responderCaret.minY, responderCaret.width, responderCaret.height],
                "contentType": contentType?.rawValue as Any? ?? NSNull(),
                "automaticPeriodSubstitution": NSSpellChecker.isAutomaticPeriodSubstitutionEnabled,
                "keyRoutes": keyRoutes,
                "inputSource": inputContext?.selectedKeyboardInputSource as Any? ?? NSNull(),
                "schemaVersion": 1, "remote": remoteID as Any? ?? NSNull(),
                "localTurn": inputMethodTurn, "localGeneration": inputMethodGeneration,
                "live": inputMethodLive, "focused": inputMethodFocused,
                "inputContext": inputContext != nil,
                "focusToken": ChromiumNativeTextInput.focusToken(nativeText) as Any? ?? NSNull(),
                "nativeRevision": nativeText?["revision"]?.string as Any? ?? NSNull(),
                "nativeState": state ?? NSNull(), "hasMarkedText": hasMarkedText(),
                "markedRange": describe(markedRange()), "selectedRange": describe(selectedRange()),
                "caret": [caret.minX, caret.minY, caret.width, caret.height],
                "caretCoordinateSpace": "screenBottomLeft", "geometrySource": nativeCaret && nativeInputEligible ? "native" : "unavailable",
                "documentProof": "unavailable", "nativeLease": false, "nativeAcknowledged": false,
                "forwarding": "legacy-cocoa-input-client"]
    }
}
