import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// What each of yab's shortcuts is now, for everywhere that names one: a
// tooltip, the Shortcuts page, the list ⌘T offers.
//
// A shortcut is its menu item's, and the menu item's can be changed by the
// person: System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts
// gives any item of any app keys of their own, by its title. So a shortcut
// is looked up by what its item is called, in the menu as it is now, and in
// the keys macOS keeps for the app (NSUserKeyEquivalents); only a shortcut
// that has no item, or whose item nobody changed, is its default. Asked
// again whenever those keys change, and everything that shows one follows
// `version`.
//
// Keys are spelled the way KeyGlyphs draws them: ⌃⌥⇧⌘ in that order, then
// the key, capital, or a word for the few that have one (esc, tab).

@MainActor
final class Hotkeys: ObservableObject {
    static let shared = Hotkeys()

    /// Changes whenever any shortcut might have: views that name one watch it.
    @Published private(set) var version = 0

    /// Every shortcut yab has a menu item for: the item's title, as macOS's
    /// App Shortcuts names it, and its keys out of the box.
    static let items: [(title: String, keys: String)] = [
        ("New Window", "⌘N"), ("Close Window", "⇧⌘W"),
        ("New Tab", "⌘T"), ("New Private Tab", "⇧⌘N"), ("Reopen Closed Tab", "⇧⌘T"),
        ("Open Address…", "⌘L"), ("Close Tab", "⌘W"), ("Print…", "⌘P"),
        ("Find on Page…", "⌘F"), ("Find Next", "⌘G"), ("Find Previous", "⇧⌘G"),
        ("Show Tabs in Sidebar", "⇧⌘S"), ("Hide Sidebar", "⌘S"), ("Show Bookmarks Bar", "⇧⌘B"),
        ("Reload Page", "⌘R"), ("Reload Without Cache", "⇧⌘R"), ("Reading Mode", "⌥⌘R"), ("Dark Page", "⌥⇧D"),
        ("Float Video", "⇧⌘P"), ("Site Controls", "⌘E"), ("Hide Elements…", "⇧⌘H"),
        ("Zoom In", "⌘+"), ("Zoom Out", "⌘-"), ("Actual Size", "⌘0"),
        ("Developer Tools", "⌥⌘I"), ("JavaScript Console", "⌥⌘J"), ("Inspect Element", "⌥⌘C"),
        ("Back", "⌘["), ("Forward", "⌘]"), ("Next Tab", "⇧⌘]"), ("Previous Tab", "⇧⌘["),
        ("Copy URL", "⇧⌘C"), ("Paste and Go", "⇧⌘V"), ("Mute Tab", "⇧⌘M"),
        ("Add This Page", ""), ("Show Bookmarks", "⌥⌘B"), ("Search History", "⌘Y"),
        ("Search Downloads", "⇧⌘J"), ("Settings…", "⌘,"), ("Passwords", "⌥⌘L"),
        ("Stop Loading", "⌘."),
        ("Open Peek as Tab", "⌘O"), ("Open Peek in Split View", "⇧⌘O"), ("Close Peek", "esc"),
        ("Pin Tab", ""), ("Keep Tab", "⌘D"), ("Rename Tab…", "⌃⌘R"),
        ("Split View", "⌃⌘\\"), ("Move Tab Left", "⌥⇧⌘←"), ("Move Tab Right", "⌥⇧⌘→"),
        ("Move Tab to New Window", "⌥⇧⌘N"), ("Pick All Tabs", "⇧⌘A"), ("Close Other Tabs", "⌥⌘W"),
        ("Close Tabs to the Left", ""), ("Close Tabs to the Right", ""),
        ("Close Tabs Above", ""), ("Close Tabs Below", ""),
        ("Show Address Bar", "⇧⌘D"), ("Mute Call", "⌃⌘M"), ("Send Feedback…", "⌥⇧I"),
    ]

    private var now: [String: String] = [:]
    private var watching: [Any] = []
    private var windowWatch: AnyCancellable?
    private var browserWatch: [AnyCancellable] = []
    private var pinWatch: AnyCancellable?
    private weak var watchedBrowser: Browser?
    private weak var watchedTab: Tab?

    private init() {
        refresh()
        // App Shortcuts are written to the app's own defaults, or the global
        // ones for every app, and macOS hands a running app the change.
        watching = [
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.soon() } }
            },
            DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.KeyboardShortcutsChanged"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.soon() }
            },
            DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            // Changed in System Settings, the keys are there by the time yab
            // is in front again, and as the menu bar is opened.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        // These menu titles change with the selected window, sidebar and
        // pinned tab. Keep App Shortcuts' active title in the same Keymap slot.
        windowWatch = BrowserWindows.shared.$focusedID.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.watchBrowser()
                self?.refresh()
            }
        }
        watchBrowser()
        // The menu bar is made after this; asked once it is there.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// The keys a shortcut has now, by its menu item's title. The one place
    /// that answers it: yab's own rebinding, when it has one, is to answer
    /// here too.
    func keys(_ title: String) -> String {
        // One Settings › Shortcuts can change: as it has it (Keymap).
        if let action = Self.action(forTitle: title) { return Keymap.shared.keys(action)?.text ?? "" }
        return now[title] ?? Hotkeys.items.first { $0.title == title }?.keys ?? ""
    }

    /// The keys a shortcut has now, by the keys it has out of the box: for
    /// the lists written with the defaults in them. A shortcut yab has no
    /// item for is as it was written.
    func keys(default keys: String) -> String {
        guard !keys.isEmpty, let title = Hotkeys.items.first(where: { $0.keys == keys })?.title else { return keys }
        return self.keys(title)
    }

    /// Whether this key press is the shortcut, as it is now.
    func matches(_ event: NSEvent, _ title: String) -> Bool {
        // By the key, as Settings › Shortcuts records it, whatever layout.
        if let action = Self.action(forTitle: title) {
            return Keymap.shared.matches(event, action)
        }
        let keys = keys(title)
        return Hotkey.readings(event).contains { $0.text == keys }
    }

    // MARK: - reading them

    /// Asked again once things settle: defaults change for every setting yab
    /// writes, a burst of them at a time, and the keys only rarely.
    private var pending = false
    /// A refresh for the window's own changes is on its way (watchBrowser).
    private var queued = false

    private func watchBrowser() {
        let browser = BrowserWindows.shared.activeBrowser
        guard browser !== watchedBrowser else { return }
        browserWatch.removeAll()
        pinWatch = nil
        watchedTab = nil
        watchedBrowser = browser
        guard let browser else { return }
        // Once a turn of the run loop however many of these changed: a
        // change of space writes four of them, and each asked the menus again.
        let changed = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.queued else { return }
                self.queued = true
                DispatchQueue.main.async {
                    self.queued = false
                    self.watchTab()
                    self.refresh()
                }
            }
        }
        browserWatch = [
            browser.changes(\.spaceID).dropFirst().sink { _ in changed() },
            browser.prefs.changes(\.sideShut).dropFirst().sink { _ in changed() },
            browser.prefs.changes(\.stripShut).dropFirst().sink { _ in changed() },
            browser.prefs.changes(\.sidebar).dropFirst().sink { _ in changed() },
            browser.changes(\.activeID).dropFirst().sink { _ in changed() },
            browser.changes(\.gathered).dropFirst().sink { _ in changed() },
            browser.changes(\.tabs).dropFirst().sink { _ in changed() },
            browser.changes(\.pairs).dropFirst().sink { _ in changed() },
        ]
        watchTab()
    }

    private func watchTab() {
        let tab = watchedBrowser?.active
        guard tab !== watchedTab else { return }
        pinWatch = nil
        watchedTab = tab
        pinWatch = tab?.changes(\.pin).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func soon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pending = false
            self?.refresh()
        }
    }

    /// Asked again now: by Settings › Shortcuts after a key changed there,
    /// and whenever App Shortcuts may have.
    func refresh() {
        var found: [String: String] = [:]
        let user = Hotkeys.userKeys()
        Keymap.shared.take(system: user)
        for (title, value) in user {
            if let keys = Hotkeys.spell(userKey: value) { found[title] = keys }
        }
        for (action, title) in Shortcut.titles {
            found[title] = Keymap.shared.keys(action)?.text ?? ""
        }
        for command in CommandHotkeys.commands {
            found[command.shortcutID] = Keymap.shared.keys(for: command)?.text ?? ""
        }
        // And what the menu shows, which is the same once AppKit has read it.
        if let menu = NSApp?.mainMenu {
            for (title, _) in Hotkeys.items where found[title] == nil {
                if let item = Hotkeys.item(titled: title, in: menu), !item.keyEquivalent.isEmpty,
                   let keys = Hotkeys.spell(item) {
                    found[title] = keys
                }
            }
        }
        guard found != now else { return }
        now = found
        version += 1
    }

    /// What the person set in App Shortcuts, the app's own over everyone's:
    /// each item's title, and its keys in App Shortcuts' writing.
    static func userKeys() -> [String: String] {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSUserKeyEquivalents"] as? [String: String] ?? [:]
        let own = Bundle.main.bundleIdentifier
            .flatMap { UserDefaults.standard.persistentDomain(forName: $0)?["NSUserKeyEquivalents"] as? [String: String] } ?? [:]
        var out: [String: String] = [:]
        for (name, value) in global.merging(own, uniquingKeysWith: { _, mine in mine }) {
            // A title alone, or the item's path from the menu bar down, each
            // step after an escape.
            let title = name.split(separator: "\u{1b}").last.map(String.init) ?? name
            out[title] = value
        }
        return normalizedUserKeys(out, visibleTitles: visibleTitles(in: BrowserWindows.shared.activeBrowser))
    }

    /// Alternate menu labels still name one Settings › Shortcuts action.
    /// The exact visible label wins when macOS has assignments for both.
    static func normalizedUserKeys(_ raw: [String: String], visibleTitles: [Shortcut.Action: String]) -> [String: String] {
        var out = raw
        for (action, titles) in titleVariants {
            let canonical = Shortcut.titles[action] ?? titles[0]
            let preferred = [visibleTitles[action], canonical].compactMap { $0 } + titles
            if let value = preferred.compactMap({ raw[$0] }).first { out[canonical] = value }
        }
        return out
    }

    private static let titleVariants: [(Shortcut.Action, [String])] = [
        (.column, ["Hide Sidebar", "Show Sidebar", "Hide Tab Bar", "Show Tab Bar"]),
        (.closeBefore, ["Close Tabs to the Left", "Close Tabs Above"]),
        (.closeAfter, ["Close Tabs to the Right", "Close Tabs Below"]),
        (.mail, ["Mail", "Back to Your Tabs"]),
        (.pin, ["Pin Tab", "Unpin Tab"]),
        (.history, ["Search History", "Show History"]),
        (.downloads, ["Search Downloads", "Show Downloads"]),
        (.split, ["Split View", "Separate Split View"]),
        (.rename, ["Rename Tab…", "Change Letter"]),
        (.closeTab, ["Close Tab"]),
        (.duplicate, ["Duplicate Tab"]),
        (.copyAddress, ["Copy URL"]),
        (.copyMarkdownLink, ["Copy Markdown Link"]),
        (.bookmark, ["Add This Page"]),
        (.extensions, ["Site Controls", "Extensions"]),
        (.translatePage, PageTranslation.barTitles),
    ]

    private static func visibleTitles(in browser: Browser?) -> [Shortcut.Action: String] {
        guard let browser else { return [:] }
        var titles: [Shortcut.Action: String] = [
            .column: browser.columnTitle,
            .mail: browser.inMail ? "Back to Your Tabs" : "Mail",
            .split: browser.pair(of: browser.activeID) != nil ? "Separate Split View" : "Split View",
            .closeBefore: Shortcut.titles(sidebar: browser.prefs.sidebar)[.closeBefore]!,
            .closeAfter: Shortcut.titles(sidebar: browser.prefs.sidebar)[.closeAfter]!,
            .translatePage: browser.pageTranslation.barTitle(for: browser.active),
        ]
        if browser.several {
            let chosen = browser.chosen
            let count = browser.chosenCount
            let loose = chosen.filter { $0.pin == nil && !$0.isBlank }.count
            titles[.pin] = loose > 0 ? "Pin \(loose) Tabs" : "Unpin \(chosen.count) Tabs"
            titles[.closeTab] = "Close \(count) Tabs"
            titles[.duplicate] = "Duplicate \(count) Tabs"
            titles[.copyAddress] = "Copy \(count) URLs"
            titles[.copyMarkdownLink] = "Copy \(count) Markdown Links"
            titles[.bookmark] = "Add \(count) Tabs to a Folder"
        } else if let tab = browser.active {
            titles[.pin] = tab.pin == nil ? "Pin Tab" : "Unpin Tab"
        }
        return titles
    }

    static func action(forTitle title: String) -> Shortcut.Action? {
        if let action = Shortcut.titled[title] { return action }
        if let variant = titleVariants.first(where: { $0.1.contains(title) }) { return variant.0 }
        let parts = title.split(separator: " ")
        if parts.count == 3, Int(parts[1]) != nil {
            switch (parts[0], parts[2]) {
            case ("Pin", "Tabs"), ("Unpin", "Tabs"): return .pin
            case ("Close", "Tabs"): return .closeTab
            case ("Duplicate", "Tabs"): return .duplicate
            case ("Copy", "URLs"): return .copyAddress
            default: break
            }
        }
        if parts.count == 4, parts[0] == "Copy", Int(parts[1]) != nil,
           parts[2] == "Markdown", parts[3] == "Links" { return .copyMarkdownLink }
        if parts.count == 6, parts[0] == "Add", Int(parts[1]) != nil,
           parts[2] == "Tabs", parts[3] == "to", parts[4] == "a", parts[5] == "Folder" { return .bookmark }
        return nil
    }

    private static func item(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let deeper = self.item(titled: title, in: sub) { return deeper }
        }
        return nil
    }

    /// An item's key equivalent, as KeyGlyphs spells keys.
    private static func spell(_ item: NSMenuItem) -> String? {
        var flags = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        // A capital letter is ⇧ and the letter.
        if key.count == 1, let c = key.first, c.isUppercase { flags.insert(.shift) }
        key = named[key] ?? key.uppercased()
        return spell(key, flags)
    }

    /// App Shortcuts' own way of writing keys: @ ⌘, $ ⇧, ~ ⌥, ^ ⌃, then the key.
    private static func spell(userKey value: String) -> String? {
        var flags: NSEvent.ModifierFlags = []
        var rest = Substring(value)
        while let c = rest.first, "@$~^".contains(c) {
            switch c {
            case "@": flags.insert(.command)
            case "$": flags.insert(.shift)
            case "~": flags.insert(.option)
            default: flags.insert(.control)
            }
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        let key = String(rest)
        return spell(named[key] ?? key.uppercased(), flags)
    }

    private static let named: [String: String] = [
        "\u{1b}": "esc", "\r": "↩", "\t": "⇥", "\u{8}": "⌫", "\u{7f}": "⌫", " ": "space",
    ]

    /// Keys spelled as one string, one key each: the modifiers, then the
    /// key itself, a word for a key that is one.
    static func caps(_ keys: String) -> [String] {
        let mods = keys.prefix { "⌃⌥⇧⌘".contains($0) }
        let rest = keys.dropFirst(mods.count)
        return mods.map(String.init) + (rest.isEmpty ? [] : [String(rest)])
    }

    static func spell(_ key: String, _ flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + key
    }
}

// MARK: - a tooltip that names its keys

/// A tooltip for a button that has a shortcut: its name, and its keys drawn
/// as a button draws them, glyphs in the line rather than caps on plates. A
/// window of its own over everything, so no view clips it, shown after a
/// moment's rest on the button, and at once while the pointer goes from one
/// such button to the next. A click or a key press puts it away, and it
/// stays away until the pointer leaves the button: what was pressed answers.
/// Every tooltip in yab is one of these, on the corner's glass: a row's or
/// a line's (pointerTip), an AppKit view's (NSView.keyTip), so no system
/// tooltip stands beside them looking otherwise; a page's own too
/// (PageTip). The menus' own are the system's, as the menus are.
@MainActor
final class KeyTip {
    static let shared = KeyTip()

    /// Where the tip stands: beside the button, or, for a row or a line of
    /// words, under the pointer, where the system puts its tooltips.
    enum Side { case left, below, above, right, pointer }

    private var panel: NSPanel?
    /// How many times the pointer came onto a tipped view, for the bench.
    private(set) var heard = 0
    var showing: Bool { (panel?.isVisible ?? false) && (panel?.alphaValue ?? 0) > 0 }

    private init() {
        // yab behind another app: no tip left standing over it.
        watch = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coming?.cancel()
                self?.panel?.orderOut(nil)
                self?.owner = nil
            }
        }
        // A press, of the button or anything else, and the tip has had its
        // say: gone at once, and not back on this button until the pointer
        // leaves it, as a system tooltip does.
        press = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.hush() }
            return event
        }
    }
    private var watch: Any?
    private var press: Any?
    /// The owner the pointer pressed on; no tip for it until it's left.
    private weak var hushed: AnyObject?
    private var host: NSHostingView<KeyTipView>?
    private var owner: AnyObject?
    private var coming: DispatchWorkItem?
    /// Until when the next tip comes without the wait.
    private var warm = Date.distantPast
    nonisolated static let dwell: TimeInterval = 0.35

    /// The pointer came onto `owner`, a view at `rect` in screen points.
    /// `shortcut` is a menu item's title, looked up as it is now; `keys`,
    /// keys written out, for one that has no item (a small window's own).
    /// `.pointer` needs no rect: the tip goes where the pointer is when it
    /// comes, not where it came in. `wait`: the rest before a first tip.
    /// `view`: the tipped view, for no tip while something of another
    /// host stands over it under the pointer (`covered`).
    func hover(_ owner: AnyObject, title: String, shortcut: String?, keys: String? = nil, at rect: NSRect = .zero, side: Side = .left, wait: TimeInterval = KeyTip.dwell, view: NSView? = nil, surface: HUD.Surface = .dark, position: (() -> NSRect?)? = nil) {
        heard += 1
        self.owner = owner
        coming?.cancel()
        guard hushed !== owner else { return }
        hushed = nil
        let work = DispatchWorkItem { [weak self, weak view] in
            // Another app's window is what the pointer is over (yab behind
            // it, or in another Space): no tip over that app, as the
            // system's own tooltips never stand over a window not theirs.
            guard KeyTip.pointerOverYab() else { return }
            if let view, KeyTip.covered(view) { return }
            // Resolve moving anchors after the dwell, not when hover began.
            let at: NSRect
            if let position {
                guard let resolved = position() else { return }
                at = resolved
            } else {
                at = side == .pointer ? KeyTip.pointer() : rect
            }
            self?.show(title: title, keys: shortcut.map { Hotkeys.shared.keys($0) } ?? keys, at: at, side: side, surface: surface)
        }
        coming = work
        if Date() < warm || panel?.alphaValue ?? 0 > 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    /// A view of another host is over `view` where the pointer is: SwiftUI
    /// hears the hover through a view on top of its own, and the column
    /// brought out over the page as a card had a Split View half's Back
    /// named over the card's own close light (#136). A press there is the
    /// card's, so the tip is too: none. The hosts are each one's nearest,
    /// the column's being inside the window's; nothing on top, or a host
    /// `view`'s is inside, leaves the tip be.
    static func covered(_ view: NSView) -> Bool {
        guard let window = view.window, let content = window.contentView, let host = host(of: view) else { return false }
        let at = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let hit = content.hitTest(content.superview?.convert(at, from: nil) ?? at),
              let over = self.host(of: hit) else { return false }
        return over !== host && !host.isDescendant(of: over)
    }

    /// The frontmost window under the pointer, of any app, is one of yab's.
    /// WebKit's hover tracking is active always and the page script's tip
    /// (chromium-tips.js) keeps answering, so a page behind another app
    /// still names its title=""s; this panel, at the pop-up menu's level
    /// and a full screen's auxiliary, would put them over that app.
    static func pointerOverYab() -> Bool {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number) != nil
    }

    /// The nearest SwiftUI host `view` is in, of any root, a subclass's too.
    private static func host(of view: NSView) -> NSView? {
        sequence(first: view, next: \.superview).first { view in
            sequence(first: type(of: view) as AnyClass, next: { class_getSuperclass($0) })
                .contains { NSStringFromClass($0).contains("NSHostingView") }
        }
    }

    /// The pointer went off `owner`: the tip goes, and the next one comes at
    /// once for a moment.
    func leave(_ owner: AnyObject) {
        if hushed === owner { hushed = nil }
        guard self.owner === owner else { return }
        self.owner = nil
        coming?.cancel()
        guard let panel, panel.alphaValue > 0 else { return }
        warm = Date().addingTimeInterval(0.5)
        // Faded in the render server, as it came: a window's own alpha is
        // stepped from the main thread, and stalls with it.
        guard let layer = host?.layer else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        fading += 1
        let now = fading
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, self.fading == now else { return }
                panel?.alphaValue = 0
                panel?.orderOut(nil)
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.1
        layer.opacity = 0
        layer.add(fade, forKey: "tip")
        CATransaction.commit()
    }

    /// Counts the fades out, so one that a new tip overtook doesn't put
    /// that tip away when it ends.
    private var fading = 0

    /// Put away without the fade and without warming the next one: the
    /// press is the answer, and the tip shouldn't linger over what it opened.
    /// Also for a press a watcher took before this one heard it (a bookmark's
    /// right-click, `Presses`).
    func hush() {
        coming?.cancel()
        coming = nil
        hushed = owner
        warm = .distantPast
        guard let panel, panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    /// Where the last tip was asked for and put, for the bench.
    private(set) var lastRect: NSRect = .zero
    private(set) var lastFrame: NSRect = .zero
    /// What the last tip said, for the bench.
    private(set) var lastTitle = ""
    private(set) var lastKeys: String?

    /// The tip up now drawn to a PNG, as its own layers draw it (the bench).
    func snapshot(to url: URL) -> Bool {
        guard showing, let host, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }

    /// Room round the tip inside its window, for the plate's shadow, which
    /// SwiftUI draws only inside the view: the window's own shadow would
    /// be a second one, round the glass's.
    static let room: CGFloat = 12

    /// The pointer as a box as tall as the arrow below its tip, so a tip
    /// put under it clears the cursor, as the system's tooltips do. A point
    /// wide: a box of no width is on no screen.
    static func pointer() -> NSRect {
        let at = NSEvent.mouseLocation
        return NSRect(x: at.x, y: at.y - 16, width: 1, height: 16)
    }

    /// Where a tip of `size` goes by `rect`, and the side it ended up on: on
    /// the other side when its own has no room on the screen, as the
    /// system's tooltips do, then kept on the screen. Only kept on it, a tip
    /// under the column's foot at the screen's bottom was pushed up over the
    /// very dot or door it named.
    static func place(_ size: NSSize, by rect: NSRect, side: Side, on screen: NSRect?) -> (NSPoint, Side) {
        let gap: CGFloat = 8
        let edge: CGFloat = 4
        func origin(_ side: Side) -> NSPoint {
            switch side {
            case .left: NSPoint(x: rect.minX - gap - size.width, y: rect.midY - size.height / 2)
            case .right: NSPoint(x: rect.maxX + gap, y: rect.midY - size.height / 2)
            case .below: NSPoint(x: rect.midX - size.width / 2, y: rect.minY - gap - size.height)
            case .above: NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + gap)
            case .pointer: NSPoint(x: rect.minX, y: rect.minY - gap - size.height)
            }
        }
        guard let screen else { return (origin(side), side) }
        func fits(_ side: Side) -> Bool {
            let at = origin(side)
            switch side {
            case .left: return at.x >= screen.minX + edge
            case .right: return at.x + size.width <= screen.maxX - edge
            case .below, .pointer: return at.y >= screen.minY + edge
            case .above: return at.y + size.height <= screen.maxY - edge
            }
        }
        var side = side
        if !fits(side) {
            let other: Side = switch side {
            case .left: .right
            case .right: .left
            case .below: .above
            case .above: .below
            // Over the pointer: the box is the arrow's height under its tip.
            case .pointer: .above
            }
            if fits(other) { side = other }
        }
        var at = origin(side)
        at.x = min(max(at.x, screen.minX + edge), screen.maxX - size.width - edge)
        at.y = min(max(at.y, screen.minY + edge), screen.maxY - size.height - edge)
        return (at, side)
    }

    private func show(title: String, keys: String?, at rect: NSRect, side: Side, surface: HUD.Surface) {
        lastRect = rect
        lastTitle = title
        lastKeys = keys
        let view = KeyTipView(title: title, keys: keys, room: KeyTip.room, surface: surface)
        if host == nil {
            let panel = TipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            // Never key, so its glass would go flat and gray: lit as the
            // browser's windows are, see Awake.swift.
            Awake.keep(panel)
            let host = NSHostingView(rootView: view)
            // Its size known to AppKit, so the tip is measured off the view
            // already there (fittingSize) rather than a controller made anew.
            host.sizingOptions = [.intrinsicContentSize]
            host.wantsLayer = true
            panel.contentView = WindowHosting.measured(host)
            self.panel = panel
            self.host = host
        }
        guard let panel, let host else { return }
        host.rootView = view
        // Measured, not read off the view's frame: a borderless panel's host
        // has no size of its own yet, and a tip placed as a point grows away
        // from the button it names. Asked of the host already there, which
        // has the tip laid out: a controller made for every tip built the
        // whole view again first, on the frame the pointer arrived. The tip
        // is placed by its plate, the room round it left out.
        let whole = host.fittingSize
        let size = NSSize(width: whole.width - 2 * KeyTip.room, height: whole.height - 2 * KeyTip.room)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.visibleFrame
        let (origin, side) = KeyTip.place(size, by: rect, side: side, on: screen)
        let shown = panel.alphaValue > 0 && panel.isVisible
        // The window goes straight to its place, and the tip comes in from a
        // touch towards the button in Core Animation, in the render server:
        // a window's frame and alpha animated by AppKit are stepped from the
        // main thread, and the tip stalled with whatever else it was doing.
        // Straight to its new place when one tip hands over to the next.
        fading += 1
        panel.setFrame(NSRect(origin: origin, size: size).insetBy(dx: -KeyTip.room, dy: -KeyTip.room), display: false)
        panel.alphaValue = 1
        panel.orderFront(nil)
        if let layer = host.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let was = layer.presentation()?.opacity ?? layer.opacity
            layer.removeAnimation(forKey: "tip")
            layer.opacity = 1
            if !shown || was < 1 {
                let step: CGFloat = shown ? 0 : 4
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = shown ? was : 0
                fade.toValue = 1
                let move = CABasicAnimation(keyPath: "transform.translation")
                // Layer points run up, as the screen's do.
                move.fromValue = NSValue(size: NSSize(width: side == .left ? -step : side == .right ? step : 0,
                                                      height: side == .below || side == .pointer ? -step : side == .above ? step : 0))
                move.toValue = NSValue(size: .zero)
                let both = CAAnimationGroup()
                both.animations = [fade, move]
                both.duration = 0.12
                both.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                layer.add(both, forKey: "tip")
            }
            CATransaction.commit()
        }
        lastFrame = NSRect(origin: origin, size: size)
    }
}

/// The window a tip is shown in, a class of its own so Awake can keep its
/// glass lit without reaching every panel in the app.
final class TipPanel: NSPanel {}

/// The tip itself: on the corner's dark glass, as every notice over a page
/// is (HUD.plate), the name in its ink and the keys after it, quieter, set
/// as buttons set theirs: a tip with keys is a regular button's height, its
/// last plate as far in from the trailing edge as from the top and bottom,
/// and the words in the middle of the room left of the plates (KeyPlate).
struct KeyTipView: View {
    let title: String
    let keys: String?
    /// Room round the plate for its shadow, in the tip's own window.
    var room: CGFloat = 0
    /// The glass of what it names: light beside Peek's buttons over a
    /// dark page (HUD.surface(over:)), the corner's dark everywhere else.
    var surface: HUD.Surface = .dark
    /// Its keys' ink.
    private var keyInk: Color { surface == .light ? HUD.ink(on: .light).opacity(0.6) : .white.opacity(0.6) }

    private var keyed: Bool { !(keys ?? "").isEmpty || title.contains("\t") || title.contains(Self.how) }

    /// Between a line's name and how it's done, and between that and its
    /// keys: "Hide\u{1F}Click or\u{1F}⌘S", the
    /// name in ink, the rest quieter (KeyTipHows).
    static let how: Character = "\u{1F}"

    var body: some View {
        Group {
            if title.contains(Self.how) { KeyTipHows(title: title, surface: surface) }
            else if title.contains("\t") { KeyTipRows(title: title, surface: surface) } else { line }
        }
        .environment(\.keyPlate, KeyTipView.plate)
        .padding(.trailing, Self.side)
        .modifier(LeadingRoom(padding: Self.side))
        .padding(.vertical, keyed ? ButtonSize.regular.keyInset : 6)
        .frame(minHeight: keyed ? ButtonSize.regular.height : nil)
        .background { HUD.plate(Radius.control, surface: surface) }
        .fixedSize()
        .padding(room)
        .environment(\.colorScheme, surface == .light ? .light : .dark)
    }

    /// The room at the tip's sides, and its keys' plates as a regular
    /// button's: the plate inset all round, the gap before them a
    /// button's 6 with the words' share of the leading room moved into it.
    static let side: CGFloat = 10
    static let plate = KeyPlate(height: ButtonSize.regular.height - 2 * ButtonSize.regular.keyInset,
                                pull: side - ButtonSize.regular.keyInset, lead: (side - 6) / 2)

    private var line: some View {
        HStack(spacing: 6) {
            // One line while it fits, wrapped past a reading width: a
            // warning's words run longer than a button's name. A line of
            // its own each, set apart, for a tip that lists several.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(title.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(HUD.ink(on: surface))
            .frame(width: KeyTipView.width(title), alignment: .leading)
            if let keys, !keys.isEmpty {
                KeyGlyphs(keys: keys, size: 12, tint: keyInk)
            }
        }
    }

    static let widest: CGFloat = 320

    /// A rows tip's lines as name and keys, split at the first tab. A line
    /// that is only a tab, or starts with one, keeps an empty name rather
    /// than coming apart into no parts (crash #109: `row[0]` on "\t").
    static func rows(_ title: String) -> [(name: String, keys: String)] {
        title.split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// The words' own width, up to `widest`, the longest of their lines.
    static func width(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let longest = title.split(separator: "\n").map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(widest, ceil(longest) + 1)
    }
}

/// A tip that lists what a button does, a line each with its own keys,
/// as a menu's items stand: "Done and close 1 tab\t⌘↩\nDone, keep the
/// tab\t⌥⌘↩". While ⌥ is held, the lines it doesn't press go quiet.
private struct KeyTipRows: View {
    let title: String
    var surface: HUD.Surface = .dark
    @ObservedObject private var option = OptionKey.shared

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(KeyTipView.rows(title).enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.name)
                    KeyGlyphs(keys: row.keys, size: 12, tint: HUD.ink(on: surface).opacity(0.6))
                        .gridColumnAlignment(.trailing)
                }
                .opacity(option.down && !row.keys.contains("⌥") ? 0.45 : 1)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(HUD.ink(on: surface))
    }
}

/// A tip that names what a thing does and how, a line each, as a sidebar
/// edge has it: "Hide Click or ⌘S", "Resize Drag", the name in
/// ink, the how quieter, its keys on plates after it.
private struct KeyTipHows: View {
    let title: String
    var surface: HUD.Surface = .dark

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(title.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                let parts = line.split(separator: KeyTipView.how, omittingEmptySubsequences: false).map(String.init)
                // The name and how 4 apart, as one phrase; the keys a
                // button's 6 after them.
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text(parts[0]).foregroundStyle(HUD.ink(on: surface))
                        if parts.count > 1, !parts[1].isEmpty { Text(parts[1]).foregroundStyle(HUD.muted(on: surface).opacity(0.75)) }
                    }
                    if parts.count > 2, !parts[2].isEmpty {
                        KeyGlyphs(keys: parts[2], size: 12, tint: HUD.ink(on: surface).opacity(0.6))
                    }
                }
                .frame(minHeight: KeyTipView.plate.height)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }
}

/// Whether ⌥ is held, for what changes while it is: a tip's lines, a
/// button's keys.
@MainActor
final class OptionKey: ObservableObject {
    static let shared = OptionKey()
    @Published private(set) var down = NSEvent.modifierFlags.contains(.option)
    private var watch: Any?

    private init() {
        watch = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let now = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { if self?.down != now { self?.down = now } }
            return event
        }
    }
}

extension View {
    /// A button's tooltip, beside it, and the shortcut, by its menu item's
    /// title, as it is now; in place of `.help`. No words, no tip.
    /// `surface`: the glass of the button it names, where that follows the
    /// page under it (Peek's buttons). `wait`: the rest before a first tip.
    func keyTip(_ title: String, shortcut: String? = nil, keys: String? = nil, side: KeyTip.Side = .below, surface: HUD.Surface = .dark,
                wait: TimeInterval = KeyTip.dwell) -> some View {
        modifier(KeyTipped(title: title, shortcut: shortcut, keys: keys, side: side, surface: surface, wait: wait))
    }

    /// A row's or a line's tooltip, under the pointer, as the system puts
    /// its own; in place of `.help` where a tip beside the view would stand
    /// far from where one is looking (an address, a tab's name, a cut-off
    /// line). Nothing of AppKit's in each row, only the hover. No words, no
    /// tip.
    /// `cut`: so much of its trailing end, under something else (doors
    /// over a plate's site), says nothing.
    func pointerTip(_ text: String, cut: CGFloat = 0) -> some View {
        modifier(PointerTipped(text: text, cut: cut))
    }
}

private struct PointerTipped: ViewModifier {
    let text: String
    let cut: CGFloat
    @State private var owner = KeyTipAnchor()
    @State private var width: CGFloat = 0
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onContinuousHover { phase in
                let now: Bool
                switch phase {
                case .active(let at): now = at.x < width - cut
                case .ended: now = false
                }
                guard now != on else { return }
                on = now
                if now, !text.isEmpty {
                    KeyTip.shared.hover(owner, title: text, shortcut: nil, side: .pointer)
                } else {
                    KeyTip.shared.leave(owner)
                }
            }
            .onDisappear { on = false; KeyTip.shared.leave(owner) }
            .accessibilityHint(text)
    }
}

private struct KeyTipped: ViewModifier {
    let title: String
    let shortcut: String?
    let keys: String?
    let side: KeyTip.Side
    let surface: HUD.Surface
    let wait: TimeInterval
    @State private var anchor = KeyTipAnchor()
    /// The AppKit view the tip is placed by, made at the first hover, not
    /// with the view: one for every tipped button was most of what a screen
    /// of mail cost to bring up (a letter's ••• and its people's chevron).
    @State private var placed = false
    @ObservedObject private var hotkeys = Hotkeys.shared

    func body(content: Content) -> some View {
        content
            .background { if placed { KeyTipFrame(anchor: anchor) } }
            .onHover { on in
                anchor.hovered = on
                guard on, !title.isEmpty else { return KeyTip.shared.leave(anchor) }
                if let rect = anchor.screenRect { return tip(rect) }
                placed = true
                // Placed in the next pass: the tip from there, if the pointer stayed.
                DispatchQueue.main.async {
                    guard anchor.hovered, let rect = anchor.screenRect else { return }
                    tip(rect)
                }
            }
            .onDisappear { KeyTip.shared.leave(anchor) }
            .accessibilityHint([title, shortcut.map { hotkeys.keys($0) } ?? keys].compactMap { $0 }.joined(separator: ", "))
    }

    private func tip(_ rect: NSRect) {
        KeyTip.shared.hover(anchor, title: title, shortcut: shortcut, keys: keys, at: rect, side: side, wait: wait, view: anchor.view, surface: surface)
    }
}

/// Where the tipped view is on screen, read from AppKit when the pointer
/// arrives rather than published on every move of the layout.
final class KeyTipAnchor {
    weak var view: NSView?
    /// The last hover event's screen point, including queued native events.
    var hoverPoint: NSPoint?
    /// The pointer is over it now.
    var hovered = false
    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct KeyTipFrame: NSViewRepresentable {
    let anchor: KeyTipAnchor
    func makeNSView(context: Context) -> NSView {
        let view = Transparent()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    private final class Transparent: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension NSView {
    /// An AppKit view's tooltip, drawn as every tip in yab is (KeyTip);
    /// in place of `toolTip`, which the system would draw its own way.
    /// Set again as the words change; nil or none, no tip.
    func keyTip(_ title: String?, side: KeyTip.Side = .below) {
        let tracker = objc_getAssociatedObject(self, &KeyTipTracker.key) as? KeyTipTracker ?? {
            let made = KeyTipTracker(view: self)
            objc_setAssociatedObject(self, &KeyTipTracker.key, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return made
        }()
        tracker.title = title ?? ""
        tracker.side = side
    }
}

/// The hover of an AppKit view with a tip: a tracking area of its own, the
/// view's bounds wherever they are.
@MainActor
private final class KeyTipTracker: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0

    weak var view: NSView?
    var title = ""
    var side = KeyTip.Side.below

    init(view: NSView) {
        self.view = view
        super.init()
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    // Named for AppKit: a plain object's `mouseEntered(with:)` is
    // `mouseEnteredWith:` to the runtime, which AppKit never sends; it sends
    // `mouseEntered:`, threw "unrecognized selector", and while the spelling
    // panel held the events that ended Yab (crash 108).
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        guard !title.isEmpty, let view, let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        KeyTip.shared.hover(self, title: title, shortcut: nil, at: rect, side: side)
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        KeyTip.shared.leave(self)
    }
}
