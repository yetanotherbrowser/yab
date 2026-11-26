import AppKit
import Combine
import SwiftUI

/// A window's lifetime purpose, chosen before any normal row can be read.
/// The initializer uses the same dispatch seam as the inert factory tests.
enum BrowserWindowPurpose: Equatable {
    case normal, privateOnly

    func begin(normal: () -> Void, privateOnly: () -> Void) {
        switch self {
        case .normal: normal()
        case .privateOnly: privateOnly()
        }
    }

    func isPrivate(active: Bool?) -> Bool { self == .privateOnly || active == true }
}

enum WindowFrameAutosave {
    /// Restore once before registering saves. Dressing the same window
    /// again leaves its current frame alone.
    @MainActor static func keep(_ window: NSWindow, name: String, restoring: Bool) {
        guard window.frameAutosaveName != name else { return }
        if restoring, !window.styleMask.contains(.fullScreen) {
            _ = window.setFrameUsingName(name)
            // AppKit can bring a frame saved on a screen other than the
            // first back on the first, as far in from its corner as it
            // was from its own screen's (a window saved at 1960 on a
            // second screen came back at 40). While that screen is still
            // there, the window goes back where it was saved.
            if let saved = savedFrame(name), window.frame != saved {
                let screens = NSScreen.screens.map(\.visibleFrame)
                if screens.contains(where: { $0.intersects(saved) }) {
                    window.setFrame(WindowPlacing.fitting(saved, screens: screens, fallback: nil), display: false)
                }
            }
        }
        // A frame saved while a layout loop ran can be many screens wide
        // (22,065 pt at x=-20145 on a 1,920 pt screen, 0.43.1). Whatever
        // came back is brought onto a screen at a size that fits it, and
        // the corrected frame is saved over the bad one.
        let screens = NSScreen.screens.map(\.visibleFrame)
        var frame = window.frame
        if restoring, !window.styleMask.contains(.fullScreen), !screens.isEmpty {
            let fitted = WindowPlacing.fitting(frame, screens: screens, fallback: NSScreen.main?.visibleFrame ?? screens[0])
            if fitted != frame {
                frame = fitted
                window.setFrame(frame, display: false)
            }
        }
        window.setFrameAutosaveName(name)
        // Registering the name can apply its saved frame again. Keep the
        // restored frame, or the placement chosen for a new window.
        if window.frame != frame { window.setFrame(frame, display: false) }
        if restoring, savedFrame(name).map({ $0 != frame }) ?? false { window.saveFrame(usingName: name) }
    }

    /// The frame `saveFrame(usingName:)` wrote for `name`, its first four
    /// numbers ("x y width height", then its screen's), or nil.
    static func savedFrame(_ name: String) -> CGRect? {
        guard let words = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)")?
            .split(separator: " ").compactMap({ Double($0) }), words.count >= 4,
            words[2] > 0, words[3] > 0 else { return nil }
        return CGRect(x: words[0], y: words[1], width: words[2], height: words[3])
    }
}

/// Where a new window opens when nothing says where: on the screen of the
/// window it was asked from, a step right of and down from that window's
/// top-left, as macOS cascades a document's windows, at a new window's
/// size and whole on that screen. Past the screen's room, it starts again
/// a step in from the room's top-left; a spot a window already stands on
/// is stepped past. With no window to go by, where it always opened, in
/// `fallback`'s corner, a step on for each window already open. Every new
/// window opened there, on the first screen, so from a window on a screen
/// above the laptop's it came up out of sight (Oct 9). Screen space, y up.
enum WindowPlacing {
    static let step = CGSize(width: 34, height: 28)

    /// Keep a remembered frame wholly in the available screen, including
    /// after a display was removed or its resolution changed.
    nonisolated static func fitting(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var frame = frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        return frame
    }

    /// A sliver on another display must not make its smaller room win.
    nonisolated static func fitting(_ frame: CGRect, screens: [CGRect], fallback: CGRect?) -> CGRect {
        let screen = screens.max { area($0.intersection(frame)) < area($1.intersection(frame)) }
        guard let visible = screen.flatMap({ area($0.intersection(frame)) > 0 ? $0 : nil }) ?? fallback else { return frame }
        return fitting(frame, in: visible)
    }

    static func frame(from source: CGRect?, screens: [(frame: CGRect, visible: CGRect)], fallback: CGRect,
                      taken: [CGPoint] = [], open: Int, size: CGSize) -> CGRect {
        guard let source,
              let screen = screens.max(by: { area($0.frame.intersection(source)) < area($1.frame.intersection(source)) }),
              area(screen.frame.intersection(source)) > 0 else {
            return CGRect(x: fallback.minX + 180 + CGFloat(open) * step.width,
                          y: fallback.minY + 110 + CGFloat(open) * step.height,
                          width: size.width, height: size.height)
        }
        let room = screen.visible
        let width = min(size.width, room.width), height = min(size.height, room.height)
        func fits(_ corner: CGPoint) -> Bool { corner.x + width <= room.maxX && corner.y - height >= room.minY }
        func stand(_ corner: CGPoint) -> CGPoint {
            CGPoint(x: max(corner.x, room.minX), y: min(corner.y, room.maxY))
        }
        var corner = stand(CGPoint(x: source.minX + step.width, y: source.maxY - step.height))
        // At most a screen's worth of steps, so a full screen still opens one.
        for _ in 0..<40 {
            if !fits(corner) { corner = CGPoint(x: room.minX + step.width, y: room.maxY - step.height) }
            guard taken.contains(where: { abs($0.x - corner.x) < 2 && abs($0.y - corner.y) < 2 }) else { break }
            corner = CGPoint(x: corner.x + step.width, y: corner.y - step.height)
        }
        if !fits(corner) { corner = CGPoint(x: room.minX, y: room.maxY) }
        return CGRect(x: corner.x, y: corner.y - height, width: width, height: height)
    }

    nonisolated private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}

/// The browser windows, apart from Little yab, Settings, and floating video.
/// A tab belongs to one Browser. Looking it up here never makes a second web view.
@MainActor
final class BrowserWindows: ObservableObject {
    static let shared = BrowserWindows()

    private struct Saved: Codable {
        var open: [UUID] = []
        var closed: [UUID] = []
    }

    private struct Entry {
        let browser: Browser
        let window: NSWindow
    }

    @Published private(set) var focusedID: UUID?
    @Published private var menuRevision = 0
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var shown = Saved()
    private var restored = false
    private var quitting = false
    private var watches: [UUID: [NSObjectProtocol]] = [:]
    private var menuWatches: [UUID: Set<AnyCancellable>] = [:]
    private var fullscreen: [UUID: WindowFullscreen] = [:]

    private init() {
        let file = Store.file("windows.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            shown = saved
        } else if FileManager.default.fileExists(atPath: file.path) {
            Store.quarantine(file)
        }
    }

    static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    var browsers: [Browser] { order.compactMap { entries[$0]?.browser } }
    var normalBrowsers: [Browser] { browsers.filter { $0.windowPurpose == .normal } }
    var activeBrowser: Browser? { activeEntry?.browser }
    var activeWindow: NSWindow? { activeEntry?.window }
    /// The window last used, one put away in the Dock too: the one Show Yab
    /// brings back.
    var lastWindow: NSWindow? {
        let kept = { (window: NSWindow) in window.isVisible || window.isMiniaturized }
        if let focusedID, let window = entries[focusedID]?.window, kept(window) { return window }
        return order.reversed().compactMap { entries[$0]?.window }.first(where: kept)
    }
    private var visibleIDs: [UUID] { order.filter { entries[$0]?.window.isVisible == true } }

    private var activeEntry: Entry? {
        if let key = NSApplication.shared.keyWindow,
           let entry = entries.values.first(where: { $0.window === key }) { return entry }
        if let browser = DevFloating.owner(of: NSApp.keyWindow),
           let entry = entries.values.first(where: { $0.browser === browser }) { return entry }
        if let focusedID, let entry = entries[focusedID], entry.window.isVisible { return entry }
        return order.reversed().compactMap { entries[$0] }.first { $0.window.isVisible }
    }

    func browser(for window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        if let browser = DevFloating.owner(of: window) { return browser }
        return entries.values.first { $0.window === window }?.browser
    }

    func window(for browser: Browser) -> NSWindow? {
        entries.values.first { $0.browser === browser }?.window
    }

    /// Exact registered normal ownership only. No focused/last-visible or
    /// detached-inspector fallback can stand in for this window.
    func isSettledFullscreen(_ window: NSWindow) -> Bool {
        guard let pair = entries.first(where: { $0.value.window === window }),
              pair.value.browser.windowPurpose == .normal, !pair.value.browser.privateBrowsing
        else { return false }
        return fullscreen[pair.key]?.isSettledFullscreen == true
    }

    /// A tab brought forward wherever it is, as a click on a notification
    /// or a picture's way back means it: its window's space switched to
    /// the one it waits in, the tab picked, its window in front. Nil when
    /// no window has it. `front` false leaves the windows' order alone
    /// (a --test run's site notifications).
    @discardableResult
    func reveal(_ tabID: Tab.ID, front: Bool = true) -> (browser: Browser, tab: Tab)? {
        for browser in browsers {
            guard let tab = browser.everyTab.first(where: { $0.id == tabID }) else { continue }
            if !browser.tabs.contains(where: { $0 === tab }), let space = browser.spaceHolding(tab.id) {
                browser.switchSpace(to: space)
            }
            browser.select(tab)
            if front { window(for: browser)?.makeKeyAndOrderFront(nil) }
            return (browser, tab)
        }
        return nil
    }

    func owner(of tabID: Tab.ID) -> (browser: Browser, window: NSWindow)? {
        for id in order {
            guard let entry = entries[id], entry.browser.tabs.contains(where: { $0.id == tabID }) else { continue }
            return (entry.browser, entry.window)
        }
        return nil
    }

    func register(_ window: NSWindow, for browser: Browser) {
        // Includes the scene-created first window, which bypasses our host
        // factory. Do this before WindowFullscreen can restore its frame.
        WindowHosting.ownFrame(of: window)
        let id = browser.windowID ?? Self.primaryID
        if entries[id]?.window === window, watches[id] != nil { return }
        // Its folders of yours drawn as its own (KeptEverywhere.swift).
        browser.takeOwnFolders()
        for token in watches.removeValue(forKey: id) ?? [] { NotificationCenter.default.removeObserver(token) }
        menuWatches[id] = nil
        entries[id] = Entry(browser: browser, window: window)
        if !order.contains(id) { order.append(id) }
        ChromiumTabGroups.shared.changed()
        NativeControl.shared.observe(browser)
        if #available(macOS 15.4, *) { Extensions.all.forEach { $0.follow(browser) } }
        // In the Window menu and the Dock's list of windows, as the others
        // are: SwiftUI leaves its own window out of both.
        window.isExcludedFromWindowsMenu = false
        let center = NotificationCenter.default
        watches[id] = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.focusedID = id
                    if id == Self.primaryID { self?.closedAt[id] = nil }
                    self?.menuRevision += 1
                }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed(id) }
            },
            // Its least size, held while it was in full screen.
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak browser] _ in
                MainActor.assumeIsolated { browser?.applyWindowFloorSoon() }
            },
        ]
        if browser.windowPurpose == .normal {
            fullscreen[id] = WindowFullscreen(window, id: id)
        }
        browser.applyWindowFloorSoon()
        menuWatches[id] = [
            browser.changes(\.activeID).dropFirst().sink { [weak self] _ in
                self?.reviseMenuSoon()
            },
            browser.changes(\.tabs).dropFirst().sink { [weak self] _ in
                self?.reviseMenuSoon()
            },
            browser.changes(\.spaceID).dropFirst().sink { [weak self] _ in
                self?.reviseMenuSoon()
            },
            // The tab in front, and its title and address as they change.
            browser.changes(\.activeID).combineLatest(browser.changes(\.tabs))
                .map { id, tabs in tabs.first { $0.id == id } }
                .removeDuplicates { $0 === $1 }
                .map { tab -> AnyPublisher<Void, Never> in
                    guard let tab else { return Just(()).eraseToAnyPublisher() }
                    return Publishers.Merge3(tab.changes(\.title).map { _ in () }, tab.changes(\.address).map { _ in () }, tab.changes(\.name).map { _ in () })
                        .eraseToAnyPublisher()
                }
                .switchToLatest()
                .sink { [weak self] in self?.retitleSoon(id) },
        ]
        if focusedID == nil { focusedID = id }
        menuRevision += 1
        if id == Self.primaryID, !restored {
            restored = true
            let reopen = shown.open
            DispatchQueue.main.async { [weak self] in
                for id in reopen { self?.open(id: id, restoring: true) }
            }
        }
    }

    /// A new window's size, where nothing else gives it one.
    static let freshSize = CGSize(width: 1080, height: 730)

    /// `space`: the one it opens in, as the Dock's menu asks; otherwise
    /// the space of the window it was asked from. `blank`: a Blank Window
    /// (BlankWindow.swift).
    @discardableResult
    func newWindow(from source: Browser? = nil, frame: NSRect? = nil, space asked: UUID? = nil, blank: Bool = false) -> Browser {
        let id = UUID()
        let space = asked ?? source?.spaceID ?? activeBrowser?.spaceID ?? Space.firstID
        Store.settings.set(space.uuidString, forKey: "window.\(id.uuidString).space")
        if blank { Store.settings.set(true, forKey: BlankWindow.key(id)) }
        return open(id: id, restoring: false, frame: frame, near: source.flatMap(window(for:)))
    }

    /// No normal space/session metadata is written for this lifetime.
    @discardableResult
    func newPrivateWindow(from source: Browser? = nil) -> Browser {
        open(id: UUID(), restoring: false, near: source.flatMap(window(for:)), purpose: .privateOnly)
    }

    func reopenClosedWindow() {
        // The first window, closed after the others were: it is kept, out
        // of sight, and comes back as the Dock brings it, with its tabs.
        if let first = closedFirst, first >= (shown.closed.last.flatMap { closedAt[$0] } ?? .distantPast),
           let entry = entries[Self.primaryID] {
            closedAt[Self.primaryID] = nil
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let id = shown.closed.popLast() else { return }
        closedAt[id] = nil
        _ = open(id: id, restoring: true)
    }

    /// When each window closed since launch went, for ⇧⌘T: a window closed
    /// after a window's last tab is what it brings back. The first window
    /// too, which is never in `shown.closed`: closed while another was up,
    /// ⇧⌘T in that one brought back a tab of its own, and nothing but the
    /// Dock with every window shut brought the first back (feedback #286).
    private var closedAt: [UUID: Date] = [:]
    var lastClosedAt: Date? {
        [shown.closed.last.flatMap { closedAt[$0] }, closedFirst].compactMap { $0 }.max()
    }

    /// When the first window was closed, while it still is: let go once it
    /// is in front again, however it came back (the Dock too). Not read off
    /// its window: on willClose it is still on screen, and the File menu,
    /// redrawn then, kept ⇧⌘T off.
    private var closedFirst: Date? { closedAt[Self.primaryID] }

    var canReopen: Bool { !shown.closed.isEmpty || closedFirst != nil }

    /// The window an agent's tools work in: `kept`, the one the bench took
    /// at launch, unless it was closed while another is up. A closed first
    /// window keeps its tabs out of sight, and with today's tabs in every
    /// window those are stale copies of the ones on screen (#819).
    func live(_ kept: Browser) -> Browser {
        guard closedAt[kept.windowID ?? Self.primaryID] != nil else { return kept }
        // Never a private window: a tab an agent opens there is shy, and no
        // session may use it.
        if let front = activeBrowser, front.windowPurpose == .normal { return front }
        return normalBrowsers.last { window(for: $0)?.isVisible == true } ?? kept
    }

    /// `near`: the window it was asked from, the one in front if none.
    @discardableResult
    private func open(id: UUID, restoring: Bool, frame placed: NSRect? = nil, near: NSWindow? = nil, purpose: BrowserWindowPurpose = .normal) -> Browser {
        if let existing = entries[id] { existing.window.makeKeyAndOrderFront(nil); return existing.browser }
        let source = near ?? activeWindow
        let browser = Browser(windowID: id, purpose: purpose)
        // A tab dragged out of a window (TearOff): where it was let go.
        // Otherwise on the screen of the window it came from (WindowPlacing);
        // a window reopened goes back where it was, if it was anywhere.
        let frame = placed ?? WindowPlacing.frame(
            from: source?.frame,
            screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
            fallback: (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero,
            taken: entries.values.map { CGPoint(x: $0.window.frame.minX, y: $0.window.frame.maxY) },
            open: max(entries.count - 1, 0), size: Self.freshSize)
        let window = BrowserWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Kept by this list and by its view (ContentView's window), never
        // let go by AppKit as well when it closes: that last release, one
        // more than it was given, left the view's hold on a freed window,
        // and Yab crashed when the closed window's view went (⇧⌘W, then
        // the run loop's autorelease pool).
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: false)
        Awake.keep(window)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = "Yab"
        // Its space's own Light or Dark before the first frame: the colors
        // are drawn in the shades of the window's appearance.
        if purpose == .normal { window.wearLookMode(of: browser.prefs) }
        window.contentView = WindowFloorLayout.host(ContentView(browser: browser)
            .windowFloor(browser))
        let frameName = frameAutosaveName(for: id)
        if purpose == .normal {
            WindowFrameAutosave.keep(window, name: frameName, restoring: restoring)
        }
        keepVisible(window)
        register(window, for: browser)
        let added = !shown.open.contains(id)
        let reopened = shown.closed.contains(id)
        if added, purpose == .normal { shown.open.append(id) }
        if reopened { shown.closed.removeAll { $0 == id } }
        if purpose == .normal, added || reopened { save() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        menuRevision += 1
        return browser
    }

    func frameAutosaveName(for id: UUID) -> String {
        let prefix = Store.world.map { "yab (\($0))" } ?? "yab"
        return id == Self.primaryID ? prefix : "\(prefix) window \(id.uuidString)"
    }

    private func keepVisible(_ window: NSWindow) {
        window.setFrame(WindowPlacing.fitting(window.frame, screens: NSScreen.screens.map(\.visibleFrame),
                                              fallback: NSScreen.main?.visibleFrame), display: false)
    }

    private func closed(_ id: UUID) {
        guard let entry = entries[id] else { return }
        entry.browser.cancelEdit()
        if quitting { return }
        entry.browser.closeDevTools()
        // No spare page kept for a window that is gone.
        entry.browser.dropSpare()
        // A tab ⌘W left under the field goes with the window.
        entry.browser.settleUnder()
        entry.browser.flushSession()
        if id != Self.primaryID {
            shown.open.removeAll { $0 == id }
            shown.closed.removeAll { $0 == id }
            if entry.browser.windowPurpose == .normal {
                shown.closed.append(id)
                closedAt[id] = Date()
            }
            if shown.closed.count > 10 { shown.closed.removeFirst(shown.closed.count - 10) }
            entries[id] = nil
            order.removeAll { $0 == id }
            ChromiumTabGroups.shared.changed()
            if #available(macOS 15.4, *) { Extensions.all.forEach { $0.unfollow(entry.browser) } }
            entry.browser.letGo()
            for token in watches.removeValue(forKey: id) ?? [] { NotificationCenter.default.removeObserver(token) }
            menuWatches[id] = nil
            fullscreen[id] = nil
        } else {
            // Kept, and watched still: shown again, its window is the same
            // one, and the second close went unseen once these were let go.
            WelcomeStage.shared.dismissReplay(in: entry.browser)
            closedAt[id] = Date()
        }
        focusedID = order.last(where: { entries[$0]?.window.isVisible == true })
        menuRevision += 1
        save()
    }

    /// A unit test's window let go entirely, the first one too, which a
    /// close keeps: the next suite starts with no window of this one's
    /// sharing its rows (KeptEverywhere.first).
    func forgetForTests(_ browser: Browser) {
        guard Store.unitTests, let id = entries.first(where: { $0.value.browser === browser })?.key else { return }
        entries[id] = nil
        order.removeAll { $0 == id }
        ChromiumTabGroups.shared.changed()
        closedAt[id] = nil
        for token in watches.removeValue(forKey: id) ?? [] { NotificationCenter.default.removeObserver(token) }
        menuWatches[id] = nil
        fullscreen[id] = nil
        if focusedID == id { focusedID = nil }
    }

    func flushAll() {
        for browser in browsers { browser.flushSession() }
        save()
    }

    func prepareToQuit() {
        guard !quitting else { return }
        quitting = true
        for state in fullscreen.values { state.prepareToQuit() }
        flushAll()
        for browser in browsers { browser.discardUnfinishedDownloads() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(shown) else { return }
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        try? data.write(to: Store.file("windows.json"), options: .atomic)
    }

    @discardableResult
    func focus(tab id: Tab.ID) -> Bool {
        guard let owner = owner(of: id), let tab = owner.browser.tabs.first(where: { $0.id == id }) else { return false }
        owner.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        owner.browser.select(tab)
        return true
    }

    /// `selecting` false brings the tab in behind the page in front, as
    /// Split View's field does before putting it beside that page. Never a
    /// shared pin: every window has its own already (SharedPins.swift).
    /// By hand, ⌘Z in the window it went to sends it back (WindowUndo.swift).
    func move(_ tab: Tab, from source: Browser, to destination: Browser, announce: Bool = true, selecting: Bool = true, undoable: Bool = true) -> Bool {
        guard source !== destination, destination.windowPurpose == .normal, source.tabs.contains(where: { $0 === tab }),
              source.spaceID == destination.spaceID, tab.everywhere == nil,
              !tab.shy, !tab.onCall, source.partner(of: tab) == nil else { return false }
        // A kept tab or a pin of the space: the other window has its own tab
        // for it already (KeptEverywhere.swift). The page goes into that
        // one's place, and one asleep stays in this one's: the list is the
        // same, in both windows.
        if KeptEverywhere.first != nil, source.listed(tab),
           let mine = destination.tabs.first(where: { destination.listed($0) && KeptEverywhere.key($0) == KeptEverywhere.key(tab) }),
           let standIn = source.keptStandIn(for: tab) {
            source.moveOut(tab, leaving: standIn)
            destination.moveIn(tab, selecting: selecting, replacing: mine)
        } else {
            source.moveOut(tab)
            destination.moveIn(tab, selecting: selecting)
        }
        show(destination)
        let back = { [weak self, weak source, weak destination, weak tab] in
            guard let self, let source, let destination, let tab else { return }
            _ = self.move(tab, from: destination, to: source, announce: false, undoable: false)
        }
        let step = undoable && Browser.handMade ? destination.did(back) : nil
        if announce {
            destination.toaster.pop("Moved to this window", mark: "macwindow.on.rectangle", stay: 8, undo: { [weak destination] in
                if let step { destination?.undo(step: step) } else { back() }
            }, feedback: .success)
        }
        return true
    }

    /// The windows a shared tab's live page is looked for in; a test's
    /// browsers are no windows, so a test names its own.
    var handOffWindows: [Browser]?
    /// Inside a hand-off, or a close's landing on the next tab: a pick
    /// then takes no page from another window.
    static var handingOff = 0

    /// A tab every window has (a shared pin, a kept tab, a space's own pin,
    /// one of today's in every window), picked here asleep while another
    /// window has its page awake: that page, the same tab and view, comes
    /// here in place of this window's own sleeping one, and the other
    /// window keeps one asleep in its place, as Arc brings a tab over from
    /// the window it is open in. Loading a second copy started a call twice
    /// and lost a half-written reply (feedback #667). Never an agent's page
    /// or half of a pair.
    func handOff(_ mine: Tab, to destination: Browser) -> Bool {
        guard Self.handingOff == 0, destination.windowPurpose == .normal, mine.asleep, !mine.shy,
              destination.tabs.contains(where: { $0 === mine }), destination.partner(of: mine) == nil else { return false }
        let every = mine.everywhere
        guard every != nil || destination.listed(mine) else { return false }
        let key = KeptEverywhere.key(mine)
        for source in handOffWindows ?? normalBrowsers where source !== destination && source.windowPurpose == .normal {
            guard let live = source.tabs.first(where: { tab in
                guard tab !== mine, !tab.asleep, !tab.gone, tab.builtPage != nil, !tab.shy, !tab.bench, tab.guest == nil,
                      tab.store === mine.store else { return false }
                if let every { return tab.everywhere == every }
                return tab.everywhere == nil && source.spaceID == destination.spaceID && KeptEverywhere.key(tab) == key
                    && (source.listed(tab) || tab.onCall)
            }), source.partner(of: live) == nil else { continue }
            let standIn: Tab?
            if let every {
                standIn = source.sessionEntry(live, id: every).flatMap { source.madePin($0, key: every) }
            } else {
                standIn = source.keptStandIn(for: live)
            }
            guard let standIn else { continue }
            Self.handingOff += 1
            defer { Self.handingOff -= 1 }
            source.moveOut(live, leaving: standIn)
            destination.moveIn(live, selecting: false, replacing: mine)
            destination.select(live)
            return true
        }
        return false
    }

    @discardableResult
    func moveToNewWindow(_ tab: Tab, from source: Browser) -> Bool {
        guard source.tabs.contains(where: { $0 === tab }), !tab.shy, !tab.onCall, tab.everywhere == nil,
              source.partner(of: tab) == nil else { return false }
        let destination = newWindow(from: source)
        return move(tab, from: source, to: destination)
    }

    /// A tab dragged out of its window and let go over no other: a new
    /// window at `frame`, the same tab and page in it (TearOff).
    func moveToNewWindow(_ tab: Tab, from source: Browser, frame: NSRect, announce: Bool) -> Browser? {
        guard TearOff.tearable(tab, in: source) else { return nil }
        let destination = newWindow(from: source, frame: frame)
        return move(tab, from: source, to: destination, announce: announce) ? destination : nil
    }

    func otherWindows(than browser: Browser) -> [(title: String, browser: Browser)] {
        visibleIDs.compactMap { id in
            guard let entry = entries[id], entry.browser !== browser else { return nil }
            return (title(for: entry), entry.browser)
        }
    }

    func openWindows() -> [(id: UUID, title: String, browser: Browser)] {
        _ = menuRevision
        return visibleIDs.compactMap { id in
            guard let entry = entries[id] else { return nil }
            return (id, title(for: entry), entry.browser)
        }
    }

    /// The window's own title, where macOS names it: the Dock's list of
    /// windows, Mission Control, ⌘`. The page in front, as in every
    /// browser, but for a private one, whose name stays unsaid.
    /// The title a moment after the page settles on one: a navigation
    /// says its address, then its title, and setting a window's title
    /// is a window-server transaction on the main thread, on the way to
    /// the page's first frame. Several in a row are one.
    private func retitleSoon(_ id: UUID) {
        guard !titleDue.contains(id) else { return }
        titleDue.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + (Narrow.title ? 0.25 : 0)) { [weak self] in
            self?.titleDue.remove(id)
            self?.retitle(id)
        }
    }
    private var titleDue: Set<UUID> = []

    /// The Window menu's list again, a moment after the tabs or the tab in
    /// front changed (it names each window by its page): every revision
    /// runs the menu bar's whole body and AppKit's main menu again, which
    /// was on the way to a new tab's first frame. Several in a row are one.
    private func reviseMenuSoon() {
        guard !menuDue else { return }
        menuDue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (Narrow.menu ? 0.25 : 0)) { [weak self] in
            self?.menuDue = false
            self?.menuRevision += 1
        }
    }
    private var menuDue = false

    private func retitle(_ id: UUID) {
        guard let entry = entries[id] else { return }
        let title: String
        if entry.browser.privateBrowsing {
            title = "Private Window"
        } else if let tab = entry.browser.active, !tab.isBlank {
            title = tab.label
        } else if entry.browser.blank {
            title = BlankWindow.title
        } else {
            // No tab in front: the field, in the space it opens into.
            title = entry.browser.prefs.usesSpaces ? entry.browser.space.name : "Yab"
        }
        if entry.window.title != title { entry.window.title = title }
        PageContinuity.advertise(entry.browser, in: entry.window)
    }

    private func title(for entry: Entry) -> String {
        let name: String
        // A private window names no space of yours (register 1015).
        if entry.browser.windowPurpose == .privateOnly { return "Private Window" }
        if entry.browser.privateBrowsing {
            name = "Private Window"
        } else if let tab = entry.browser.active, !tab.isBlank {
            let label = tab.label
            if let host = tab.address?.host(), !label.localizedCaseInsensitiveContains(host) {
                name = "\(label) · \(IDN.shown(host))"
            } else {
                name = label
            }
        } else {
            return entry.browser.blank ? BlankWindow.title : entry.browser.space.name
        }
        // A Blank Window's is in no space's list: it says so, not the space.
        return "\(name) · \(entry.browser.blank ? BlankWindow.title : entry.browser.space.name)"
    }

    func show(_ browser: Browser) {
        guard let window = window(for: browser) else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
