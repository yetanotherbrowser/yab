import AppKit
import Combine
import SwiftUI
import WebKit

/// A weak editing destination, never clipboard text. The command field keeps
/// the editor it was raised over, rather than pasting into its own query.
@MainActor
final class PasteStyleTarget {
    static let action = #selector(NSTextView.pasteAsPlainText(_:))
    private weak var window: NSWindow?
    private weak var focus: NSView?
    private weak var field: NSTextField?
    private var selection: NSRange?
    private var wasEditable = false
    private var restored = false
    private let board: NSPasteboard
    /// AppKit's key window. A test host that never runs NSApp has none, so
    /// focus tests name the key window here instead of activating the app.
    private let keyWindow: @MainActor () -> NSWindow?

    init(pasteboard: NSPasteboard = .general, keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) {
        board = pasteboard
        self.keyWindow = keyWindow
    }

    func capture(in window: NSWindow?) {
        self.window = window
        restored = false
        field = nil
        selection = nil
        focus = window?.firstResponder as? NSView
        if let editor = focus as? NSTextView, editor.isFieldEditor {
            guard let control = editor.delegate as? NSTextField, control.window === window else {
                focus = nil
                wasEditable = false
                return
            }
            field = control
            selection = editor.selectedRange()
            focus = control
        }
        wasEditable = editable()
    }

    /// Reopening the query in the same host retains its original destination.
    /// A transfer into another host must never retain the old window's editor.
    func captureBeforeField(in window: NSWindow?) {
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSTextField,
           control.delegate is AddressField.Coordinator {
            if self.window !== window { capture(in: nil) }
            return
        }
        capture(in: window)
    }

    private func receiver() -> NSResponder? {
        guard let window, let focus, focus.window === window else { return nil }
        if let field {
            guard let editor = field.currentEditor() as? NSTextView,
                  editor.delegate === field else { return nil }
            return editor
        }
        var at: NSResponder? = focus
        while let responder = at, responder !== window {
            if responder.responds(to: Self.action) { return responder }
            at = responder.nextResponder
        }
        return nil
    }

    private func editable() -> Bool {
        guard let window, let focus, focus.window === window, !focus.isHiddenOrHasHiddenAncestor else { return false }
        if let field { return field.isEditable && field.isEnabled }
        guard let receiver = receiver() else { return false }
        if let text = receiver as? NSText { return text.isEditable }
        // A selector alone does not establish an editable destination.
        let item = NSMenuItem(title: "Paste and Match Style", action: Self.action, keyEquivalent: "")
        if let native = receiver as? NSMenuItemValidation { return native.validateMenuItem(item) }
        return (receiver as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) == true
    }

    func canPaste(from supplied: NSPasteboard? = nil, restoring: Bool = false) -> Bool {
        let board = supplied ?? self.board
        guard let window, let focus, focus.window === window, !focus.isHiddenOrHasHiddenAncestor,
              board.availableType(from: [.string]) != nil else { return false }
        if restoring {
            let nativeReady = field.map { $0.isEditable && $0.isEnabled } ?? (focus as? NSText).map(\.isEditable) ?? true
            return wasEditable && nativeReady
        }
        return editable()
    }

    @discardableResult
    func perform(from supplied: NSPasteboard? = nil, restoring: Bool = false) -> Bool {
        let board = supplied ?? self.board
        guard canPaste(from: board, restoring: restoring), let window, let focus else { return false }
        if restoring {
            guard window.isVisible, keyWindow() === window,
                  window.makeFirstResponder(focus) else { return false }
            if let selection, let editor = field?.currentEditor() as? NSTextView {
                guard NSMaxRange(selection) <= editor.string.utf16.count else { return false }
                editor.setSelectedRange(selection)
            }
        } else {
            guard window.firstResponder === focus || field?.currentEditor() === window.firstResponder else { return false }
        }
        guard editable(), let receiver = receiver() else { return false }
        restored = restoring
        if let text = receiver as? NSTextView {
            // Only the plain string representation enters the destination;
            // AppKit retains its typing style and text editing/Undo behavior.
            return text.readSelection(from: board, type: .string)
        }
        return receiver.tryToPerform(Self.action, with: nil)
    }

    func consumeRestoredFocus() -> Bool {
        defer { restored = false }
        guard restored, let window, let focus, keyWindow() === window, focus.window === window else { return false }
        return window.firstResponder === focus || field?.currentEditor() === window.firstResponder
    }

    static func current(in window: NSWindow?) -> PasteStyleTarget {
        let target = PasteStyleTarget()
        target.capture(in: window)
        return target
    }

    static func current() -> PasteStyleTarget { current(in: NSApp.keyWindow) }

    /// ⇧⌘V that reached Paste and Go's menu row: in a text field it is paste
    /// without formatting, as in Chrome. The browser's key monitor decides
    /// this in its own windows; a link's window, Settings and the others
    /// leave the key to the menu, which navigated the browser's tab (#838).
    /// True when the caret is in editable text, so the key was the text's
    /// even with nothing plain to paste.
    @discardableResult
    static func takesPasteAndGoKey(in window: NSWindow?, pasteboard: NSPasteboard = .general) -> Bool {
        let target = PasteStyleTarget(pasteboard: pasteboard)
        target.capture(in: window)
        guard target.editable() else { return false }
        // WebKit says yes to a menu row before its page has answered
        // (WebViewImpl validates later), caret or not. A web view has an
        // input context only while the caret is in something editable, in
        // any frame, as the key monitor asks it (ContentView.perform).
        if let web = target.receiver() as? WKWebView, web.inputContext == nil { return false }
        target.perform()
        return true
    }
}

/// Refresh menu enablement when AppKit opens a menu. The keyboard action
/// independently checks the live target, so stale state never causes a paste.
@MainActor
final class PasteStyleMenuState: ObservableObject {
    static let shared = PasteStyleMenuState()
    @Published private(set) var enabled = false
    @Published private(set) var allowsShortcut = true
    private var watches: [NSObjectProtocol] = []

    init() {
        for name in [NSMenu.didBeginTrackingNotification, NSWindow.didBecomeKeyNotification,
                     NSControl.textDidBeginEditingNotification] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if let menu = note.object as? NSMenu { PasteStyleMenuOrder.place(in: menu) }
                    self?.refresh()
                }
            })
        }
    }

    deinit { watches.forEach(NotificationCenter.default.removeObserver) }

    func refresh() { refresh(in: NSApp.keyWindow) }

    func refresh(in window: NSWindow?, from board: NSPasteboard = .general) {
        let ready = PasteStyleTarget.current(in: window).canPaste(from: board)
        if enabled != ready { enabled = ready }
        let allowed = Keymap.shared.keys(.pasteAndMatchStyle).map { PasteStyleMenuOrder.permits($0, in: NSApp.mainMenu) } ?? false
        if allowsShortcut != allowed { allowsShortcut = allowed }
    }
}

struct PasteStyleMenuItem: View {
    @ObservedObject private var state = PasteStyleMenuState.shared

    var body: some View {
        Button("Paste and Match Style") { PasteStyleTarget.current().perform() }
            .shortcut(.pasteAndMatchStyle, enabled: state.allowsShortcut)
            .disabled(!state.enabled)
    }
}

/// Keep system Cut/Copy/Paste/Delete/Select All items and only move our unique
/// row after paste:. Never replace the pasteboard group or reorder its peers.
@MainActor
enum PasteStyleMenuOrder {
    static let title = "Paste and Match Style"
    static let identifier = NSUserInterfaceItemIdentifier("YabPasteAndMatchStyle")

    static func place(in menu: NSMenu) {
        for item in menu.items { if let sub = item.submenu { place(in: sub) } }
        let candidates = menu.items.filter { $0.identifier == identifier || $0.title == title }
        guard candidates.count == 1, let own = candidates.first,
              let paste = menu.items.first(where: { $0.action == #selector(NSText.paste(_:)) }),
              own !== paste else { return }
        own.identifier = identifier
        guard menu.index(of: own) != menu.index(of: paste) + 1 else { return }
        menu.removeItem(own)
        menu.insertItem(own, at: menu.index(of: paste) + 1)
    }

    /// A native App Shortcut on another title stays its owner's. Contextual
    /// extension/quick-action routing keeps its existing first turn as well.
    static func permits(_ key: Hotkey, in menu: NSMenu?) -> Bool {
        guard let menu else { return true }
        for item in menu.items {
            if let sub = item.submenu, !permits(key, in: sub) { return false }
            guard item.identifier != identifier && item.title != title else { continue }
            var value = item.keyEquivalent
            var flags = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
            if value.count == 1, value != value.lowercased() { value = value.lowercased(); flags.insert(.shift) }
            if !value.isEmpty, value == key.key, flags == key.flags { return false }
        }
        return true
    }
}
