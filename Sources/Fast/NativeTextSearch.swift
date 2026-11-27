import AppKit

/// AppKit's native text context menu (NSTextView and SwiftUI selectable text)
/// includes a "Search With Google" item (`_searchWithGoogleFromMenu:`) that
/// hands the selection to Safari's macOS service. Rewrite it to search with
/// Yab's active engine in a Yab tab instead.
@MainActor
final class NativeTextSearch: NSObject, NSMenuItemValidation {
    static let shared = NativeTextSearch()
    static let systemIdentifier = "_searchWithGoogleFromMenu:"
    static let systemAction = NSSelectorFromString(systemIdentifier)
    private static let viewSelector = NSSelectorFromString("view")
    private static let writeSelectionSelector = NSSelectorFromString("writeSelectionToPasteboard:types:")

    private final class Pending {
        let words: String
        weak var source: AnyObject?
        weak var window: NSWindow?

        init(words: String, source: AnyObject?, window: NSWindow?) {
            self.words = words
            self.source = source
            self.window = window
        }
    }

    private var observer: NSObjectProtocol?
    var onSearch: ((String, NSWindow?) -> Void)?

    override private init() {
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let menu = note.object as? NSMenu, menu !== NSApp.mainMenu else { return }
                self.rewrite(menu)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func rewrite(_ menu: NSMenu, fallbackWindow: NSWindow? = nil) {
        for item in menu.items {
            if let sub = item.submenu { rewrite(sub, fallbackWindow: fallbackWindow) }
            guard item.action == Self.systemAction || item.identifier?.rawValue == Self.systemIdentifier else { continue }
            let resolved = source(for: item, fallbackWindow: fallbackWindow)
            let words = Self.selectedText(from: resolved.object)
            let window = resolved.window ?? fallbackWindow ?? NSApp.keyWindow
            let browser = BrowserWindows.shared.browser(for: window)
                ?? BrowserWindows.shared.activeBrowser
                ?? BrowserWindows.shared.browsers.last
            item.title = "Search with \(browser?.searchEngine.name ?? Engine.name)"
            item.target = self
            item.action = #selector(searchSelection(_:))
            item.representedObject = Pending(words: words, source: resolved.object, window: window)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(searchSelection(_:)) else { return true }
        guard let pending = menuItem.representedObject as? Pending else { return false }
        return !pending.words.isEmpty || pending.source != nil
    }

    @objc func searchSelection(_ item: NSMenuItem) {
        guard let pending = item.representedObject as? Pending else { return }
        let words = pending.words.isEmpty ? Self.selectedText(from: pending.source) : pending.words
        guard !words.isEmpty else { return }
        if let onSearch {
            onSearch(words, pending.window)
            return
        }
        openSearch(words, from: pending.window)
    }

    func openSearch(_ words: String, from window: NSWindow?) {
        let ownBrowser = BrowserWindows.shared.browser(for: window)
        guard let browser = ownBrowser ?? BrowserWindows.shared.activeBrowser ?? BrowserWindows.shared.browsers.last,
              let url = browser.searchEngine.url(for: words) else { return }
        let source = ownBrowser === browser ? browser.active : nil
        if browser.fieldShowing { browser.close() }
        _ = browser.open(url, foreground: true, from: source)
        if ownBrowser !== browser {
            BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
        }
    }

    private func source(for item: NSMenuItem, fallbackWindow: NSWindow?) -> (object: AnyObject?, window: NSWindow?) {
        if item.target !== self {
            if let view = item.target as? NSView {
                return (view, view.window)
            }
            if let target = item.target as? NSObject,
               target.responds(to: Self.viewSelector),
               let view = target.perform(Self.viewSelector)?.takeUnretainedValue() as? NSView {
                return (view, view.window)
            }
        } else if let previous = item.representedObject as? Pending, let source = previous.source {
            return (source, (source as? NSView)?.window ?? previous.window)
        }
        let window = fallbackWindow ?? NSApp.keyWindow
        var responder = window?.firstResponder
        while let current = responder {
            if current is NSTextView || current.responds(to: Self.writeSelectionSelector) {
                return (current, (current as? NSView)?.window ?? window)
            }
            responder = current.nextResponder
        }
        return (nil, window)
    }

    static func selectedText(from source: AnyObject?) -> String {
        guard let object = source as? NSObject else { return "" }
        if object.responds(to: writeSelectionSelector) {
            let board = NSPasteboard(name: NSPasteboard.Name("dev.serafim.fast.native-search-selection"))
            defer { board.releaseGlobally() }
            board.clearContents()
            typealias Write = @convention(c) (AnyObject, Selector, NSPasteboard, NSArray) -> Bool
            let write = unsafeBitCast(object.method(for: writeSelectionSelector), to: Write.self)
            if write(object, writeSelectionSelector, board, [NSPasteboard.PasteboardType.string.rawValue] as NSArray),
               let words = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !words.isEmpty {
                return words
            }
        }
        if let textView = object as? NSTextView {
            let range = textView.selectedRange()
            let content = textView.string as NSString
            if range.length > 0, NSMaxRange(range) <= content.length {
                return content.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }
}
