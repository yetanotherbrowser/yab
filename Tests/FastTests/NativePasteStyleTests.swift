import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct NativePasteStyleTests {}

extension NativePasteStyleTests {
@MainActor
@Suite
struct PasteStyleTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private func board(_ text: String? = "  plain café\nsecond line  ") -> NSPasteboard {
        let board = NSPasteboard(name: .init("yab-paste-style-" + UUID().uuidString))
        board.clearContents()
        if let text { board.setString(text, forType: .string) }
        return board
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 420, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func editor(in window: NSWindow) throws -> NSTextView {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        text.isRichText = true
        text.allowsUndo = true
        window.contentView = text
        try #require(window.makeFirstResponder(text))
        return text
    }

    private func withBrowser(_ body: (Browser) throws -> Void) rethrows {
        // Never select a tab or start a browser session: no account/provider
        // path, real page, user clipboard or standard defaults is involved.
        let keys = ["mail", "search.suggest", "field.compact", "shortcuts", FieldRequest.key]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { Store.settings.set(value, forKey: key) }
                else { Store.settings.removeObject(forKey: key) }
            }
            Keymap.shared.adoptStored()
        }
        Store.settings.set(false, forKey: "mail")
        Store.settings.set(false, forKey: "search.suggest")
        Store.settings.set(false, forKey: FieldRequest.key)
        Store.settings.set(true, forKey: "field.compact")
        Store.settings.set([String: String](), forKey: "shortcuts")
        Keymap.shared.adoptStored()
        let previousFoldersBrowser = Folders.shared.browser
        let id = UUID(), browser = Browser(windowID: id)
        browser.lookForMailSignInLink = {}
        browser.dropSpare()
        browser.history = History([])
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.letGo()
            browser.dropSpare()
            Folders.shared.browser = previousFoldersBrowser
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            for prefix in ["session", "spaces"] {
                try? FileManager.default.removeItem(at: Store.file("\(prefix)-window-\(id.uuidString).json"))
            }
        }
        try body(browser)
    }

    @Test func nativePasteUsesOnlyPlainRepresentationAndKeepsDestinationStyle() throws {
        let window = window(), board = board()
        defer { window.close(); board.releaseGlobally() }
        let text = try editor(in: window)
        let font = NSFont.systemFont(ofSize: 14)
        text.typingAttributes = [.font: font, .foregroundColor: NSColor.blue]
        let rich = NSAttributedString(string: "SOURCE RICH", attributes: [.font: NSFont.boldSystemFont(ofSize: 32), .foregroundColor: NSColor.red])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(rtf, forType: .rtf)
        let unchangedCount = board.changeCount, unchangedTypes = board.types
        let unchangedPlain = board.string(forType: .string), unchangedRich = board.data(forType: .rtf)
        let target = PasteStyleTarget(pasteboard: board)
        target.capture(in: window)
        try #require(target.canPaste())
        try #require(target.perform())
        #expect(text.string == "  plain café\nsecond line  ")
        #expect(board.changeCount == unchangedCount && board.types == unchangedTypes)
        #expect(board.string(forType: .string) == unchangedPlain && board.data(forType: .rtf) == unchangedRich)
        #expect(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font)
        #expect(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.blue)
        #expect(!target.consumeRestoredFocus())
        let undo = try #require(text.undoManager)
        try #require(undo.canUndo)
        undo.undo()
        #expect(text.string.isEmpty)
    }

    @Test func readonlyMissingPlainPayloadDetachedAndWrongResponderCannotPaste() throws {
        let window = window(), board = board(nil)
        defer { window.close(); board.releaseGlobally() }
        let text = try editor(in: window), target = PasteStyleTarget(pasteboard: board)
        target.capture(in: window)
        #expect(!target.canPaste())
        board.setString("value", forType: .string)
        text.isEditable = false
        target.capture(in: window)
        #expect(!target.perform())
        text.isEditable = true
        target.capture(in: window)
        try #require(window.makeFirstResponder(window))
        #expect(!target.perform())
        window.contentView = NSView()
        #expect(!target.canPaste(restoring: true))
        #expect(text.string.isEmpty)
    }

    /// #838: ⇧⌘V reaching Paste and Go's row pastes plain in a text field
    /// and keeps the key from navigating, even with nothing plain to paste.
    @Test func pasteAndGoKeyPastesPlainInTextAndGoesElsewhere() throws {
        let window = window(), board = board()
        defer { window.close(); board.releaseGlobally() }
        let text = try editor(in: window)
        #expect(PasteStyleTarget.takesPasteAndGoKey(in: window, pasteboard: board))
        #expect(text.string == "  plain café\nsecond line  ")

        let empty = self.board(nil)
        defer { empty.releaseGlobally() }
        #expect(PasteStyleTarget.takesPasteAndGoKey(in: window, pasteboard: empty))

        text.isEditable = false
        #expect(!PasteStyleTarget.takesPasteAndGoKey(in: window, pasteboard: board))
        try #require(window.makeFirstResponder(window))
        #expect(!PasteStyleTarget.takesPasteAndGoKey(in: window, pasteboard: board))
        #expect(!PasteStyleTarget.takesPasteAndGoKey(in: nil, pasteboard: board))
    }

    /// WebKit validates the plain-paste row as enabled before its page
    /// answers. A focused web view with no caret in a field leaves the key
    /// to Paste and Go.
    @Test func pasteAndGoKeyGoesFromAWebViewWithoutACaret() throws {
        let window = window(), board = board("https://example.com/838")
        defer { window.close(); board.releaseGlobally() }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        window.contentView = web
        try #require(window.makeFirstResponder(web))
        try #require(web.inputContext == nil)
        #expect(!PasteStyleTarget.takesPasteAndGoKey(in: window, pasteboard: board))
    }

    @Test func onlyOurUniqueMenuRowMovesImmediatelyAfterPaste() throws {
        let menu = NSMenu(title: "Edit")
        let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let delete = NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        let all = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let own = NSMenuItem(title: PasteStyleMenuOrder.title, action: nil, keyEquivalent: "v")
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "f")
        let peers = [cut, copy, paste, delete, all, find]
        for item in [cut, copy, paste, delete, all, own, find] { menu.addItem(item) }
        let root = NSMenu(), edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = menu; root.addItem(edit)
        PasteStyleMenuOrder.place(in: root)
        #expect(menu.items.map(\.title) == ["Cut", "Copy", "Paste", "Paste and Match Style", "Delete", "Select All", "Find"])
        #expect(menu.items.filter { $0 !== own }.elementsEqual(peers, by: { $0 === $1 }))
        #expect(own.identifier == PasteStyleMenuOrder.identifier)
        PasteStyleMenuOrder.place(in: root)
        #expect(menu.index(of: own) == menu.index(of: paste) + 1)
        menu.addItem(withTitle: PasteStyleMenuOrder.title, action: nil, keyEquivalent: "")
        let before = menu.items
        PasteStyleMenuOrder.place(in: root)
        #expect(menu.items.elementsEqual(before, by: { $0 === $1 }))
    }

    @Test func composedOffersKeepExactPasteIntentAheadOfHistoryAndSuggestions() throws {
        try withBrowser { browser in
            let window = window(), board = board("synthetic")
            defer { window.close(); board.releaseGlobally() }
            _ = try editor(in: window)
            browser.query.pasteStyleTarget = PasteStyleTarget(pasteboard: board)
            browser.query.pasteStyleTarget.capture(in: window)
            let aliases = ["Paste and Match Style", "paste without formatting", "paste plain text", "plain paste", "match style"]
            for words in aliases {
                browser.history = History([Visit(url: "https://example.invalid/paste", key: "example.invalid/paste", title: words + " guide", count: 5, last: Date())])
                browser.replaceTyped(words)
                try #require(browser.offers.contains { $0.kind == .visited })
                try #require(browser.offers.first?.kind == .command(.pasteAndMatchStyle))
                #expect(browser.ending == nil)
                let suggestions = [Suggestion(key: words + " tutorial", title: "", url: URL(string: "https://example.invalid/search"), kind: .suggested)]
                let merged = SearchSuggestions.merge(suggestions, into: browser.offers, lead: 0)
                try #require(merged.list.contains { $0.kind == .suggested })
                #expect(merged.list.first?.kind == .command(.pasteAndMatchStyle))
                #expect(merged.lead == 0)
                browser.picked = 0
                let action = try #require(browser.fieldMenuActions.first { $0.id == "run" })
                #expect(action.title == "Run Command")
                #expect(action.keys == Command.pasteAndMatchStyle.keys)
            }
            browser.replaceTyped("")
            try #require(browser.enterActions())
            try #require(browser.offers.contains { $0.kind == .command(.pasteAndMatchStyle) })
            browser.replaceTyped("paste plain text")
            #expect(browser.offers.first?.kind == .command(.pasteAndMatchStyle))
            browser.query.pasteStyleTarget.capture(in: nil)
            browser.guessAgain()
            #expect(!browser.offers.contains { $0.kind == .command(.pasteAndMatchStyle) })
        }
    }
}
}
