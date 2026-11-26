import AppKit
import YabCoreClient

extension ChromiumPage {
    /// AppKit offers menu equivalents before keyDown. WebKit consumes its
    /// text commands there; a remote page must do the same before the
    /// Developer Mode menu can claim Control-D in an editable field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self,
           navigationTab?.typing == true, Self.isForwardDeleteKey(event) {
            return takeEditingKey(event)
        }
        if takesPasteStyleKey(event) { return true }
        if pageTakesFirst(event) {
            menuKey = event
            editingKeyCodes.insert(event.keyCode)
            sendKey("keyDown", event)
            sendKey("keyUp", event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The menu row is only as fresh as the last menu opened, and a field in
    /// a page gives AppKit nothing to refresh it by: the key asks the live target.
    private func takesPasteStyleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, navigationTab?.typing == true,
              let key = Keymap.shared.keys(.pasteAndMatchStyle), PasteStyleMenuOrder.permits(key, in: NSApp.mainMenu),
              Hotkey.readings(event).contains(where: { $0.flags == key.flags && $0.key == key.key }) else { return false }
        return PasteStyleTarget.current(in: window).perform()
    }

    /// A key with ⌘ goes to the page before any menu or Yab's own shortcut, as
    /// in Chrome and on WebKit: bold in an editor, ⌘K in Slack, ⌘F in a Doc.
    /// What it leaves comes back (`page.keyUnhandled`). Text editing stays with
    /// Edit's menu, and the keys that make and close windows are never a page's.
    private func pageTakesFirst(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event !== resentKey, !event.isARepeat, window?.firstResponder === self,
              event.modifierFlags.contains(.command),
              let letter = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return Self.offersCommandToPage(letter, typing: navigationTab?.typing == true)
    }

    /// Non-editing pages may consume Undo (a canvas, for example). If they
    /// leave it unused, return the original event to the window's undo stack.
    /// Editable fields still use the native Edit route below.
    static func offersCommandToPage(_ letter: String, typing: Bool) -> Bool {
        if letter == "z" { return !typing }
        // Space with Command belongs to macOS (Spotlight, Finder search,
        // or Control-Command-Space's character palette), before the remote
        // renderer can consume it or route it through its hidden window.
        return !["a", "c", "v", "x", "q", "w", "t", "n", "h", "m", ",", "`", "\t", " "].contains(letter)
    }

    /// The page didn't want it: the same event through the app again, where
    /// `ContentView.pageFirst` lets Yab act on it, as WebKit sends one back.
    func receiveKeyUnhandled(_ p: [String: JSONValue]) {
        guard let event = menuKey, p["keyCode"]?.number == Double(event.keyCode) else { return }
        menuKey = nil
        resentKey = event
        NSApp.sendEvent(event)
        resentKey = nil
    }

    static func isForwardDeleteKey(_ event: NSEvent) -> Bool {
        Hotkey.readings(event).contains { $0.flags == .control && $0.key == "d" }
    }

    /// The hidden CEF window does not own AppKit's Edit menu. Dispatch its
    /// command keys as trusted renderer events, including the editor command.
    func takeEditingKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // AppKit lets Control-D through while a page field has focus. The
        // concealed producer has no active Cocoa text editor to interpret it.
        // Send the same trusted key/editor pair as the native Edit actions.
        if Self.isForwardDeleteKey(event) {
            editingKeyCodes.insert(event.keyCode)
            editFromHand("Control+d")
            return true
        }
        guard let letter = KeyLayout.keyName(for: typed, at: event.keyCode, on: .current)?.lowercased(),
              ["a", "c", "v", "x", "z"].contains(letter),
              flags == .command || (letter == "z" && flags == [.command, .shift]) else { return false }
        editingKeyCodes.insert(event.keyCode)
        editFromHand(flags.contains(.shift) ? "Meta+Shift+z" : "Meta+" + letter)
        return true
    }

    /// AppKit menu actions stop at this page instead of the window's editor.
    private func editFromHand(_ keys: String) {
        guard window != nil, case .success(let strokes) = AgentPage.strokes(keys) else { return }
        // AppKit may have just restored this responder during activation;
        // becomeFirstResponder's deferred notification can still be pending.
        // Put any needed focus handoff ahead of the editor command now.
        syncRemoteFocus()
        finishComposition()
        lastInput = ProcessInfo.processInfo.systemUptime
        RelayGuard.felt(self)
        AgentFeed.shared.person(self)
        pageCopyTurn &+= 1
        let turn = pageCopyTurn
        // The helper queues this editor key alongside native backspaces.
        // Sending it through scripts.input directly can overtake that queue.
        for stroke in strokes {
            var fields: [String: JSONValue] = ["kind": .string("editorKey"), "keyCode": .number(Double(stroke.keyCode)),
                "nativeCode": .number(Double(stroke.code)), "key": .string(stroke.key),
                "code": .string(stroke.domCode), "text": .string(stroke.text),
                "modifiers": .number(Double((stroke.flags.contains(.option) ? 1 : 0) |
                    (stroke.flags.contains(.control) ? 2 : 0) | (stroke.flags.contains(.command) ? 4 : 0) |
                    (stroke.flags.contains(.shift) ? 8 : 0))),
                "macModifiers": .number(Double(stroke.flags.rawValue))]
            // An extension's pop-out has the same native editor as its action
            // popup. CDP's paste command fires paste in a password field but
            // does not insert the clipboard. Keep the keyboard FIFO, then
            // invoke the native view's Edit selector, as the action popup does.
            if ChromiumExtensionWindow.owning(window) != nil {
                let edits = ["Meta+a": "selectAll", "Meta+c": "copy", "Meta+x": "cut",
                             "Meta+v": "paste", "Meta+Shift+v": "pasteAndMatchStyle",
                             "Meta+z": "undo", "Meta+Shift+z": "redo"]
                if let edit = edits[keys] { fields["nativeEdit"] = .string(edit) }
            }
            command("input.send", fields)
        }
        // The app's local key monitor runs before the remote selection.
        // Offer the selected page after Chromium acknowledges that input.
        if keys == "Meta+a", NSApp.currentEvent?.type == .keyDown {
            let trace = Store.testing && ProcessInfo.processInfo.environment["YAB_CHROMIUM_COPY_TRACE"] == "1"
            if trace { NSLog("YAB_COPY selectAll event=%ld", Int(NSApp.currentEvent?.type.rawValue ?? 0)) }
            afterAcceptedInput { [weak self] in
                if let self, trace {
                    let tab = self.navigationTab
                    let browser = tab?.delegate as? Browser
                    NSLog("YAB_COPY accepted turn=%d page=%d active=%d key=%d offering=%d typing=%d field=%d",
                          self.pageCopyTurn == turn ? 1 : 0, tab?.builtPage === self ? 1 : 0,
                          browser?.active === tab ? 1 : 0, self.window?.isKeyWindow == true ? 1 : 0,
                          browser?.pageCopy.offering == true ? 1 : 0, tab?.typing == true ? 1 : 0,
                          browser?.fieldShowing == true ? 1 : 0)
                }
                guard let self, self.pageCopyTurn == turn,
                      let tab = self.navigationTab, tab.builtPage === self,
                      let browser = tab.delegate as? Browser, browser.active === tab,
                      self.window?.isKeyWindow == true, !browser.pageCopy.offering else { return }
                browser.offerPageCopy()
            }
        }
    }

    @objc override func selectAll(_ sender: Any?) { editFromHand("Meta+a") }
    @objc func copy(_ sender: Any?) { editFromHand("Meta+c") }
    @objc func cut(_ sender: Any?) { editFromHand("Meta+x") }
    @objc func paste(_ sender: Any?) { editFromHand("Meta+v") }
    /// Paste and Match Style (PasteStyleTarget): the helper's editor command.
    @objc func pasteAsPlainText(_ sender: Any?) { editFromHand("Meta+Shift+v") }
    @objc func undo(_ sender: Any?) { editFromHand("Meta+z") }
    @objc func redo(_ sender: Any?) { editFromHand("Meta+Shift+z") }
}

/// PasteStyleTarget asks the first responder whether its command applies, as
/// WebKit answers for its editor. Every other row stays as it was: enabled.
extension ChromiumPage: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != PasteStyleTarget.action || navigationTab?.typing == true
    }
}
