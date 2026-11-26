import AppKit
import SwiftUI
import WebKit

// Back or forward, held: the pages that way, the rows a swipe lists
// (Swipe.rows, PullList.row), on the swipe list's own card. A click is
// still only back: nothing shows before the hold is long enough, since the
// door is pressed all day and the frequent path stays quiet
// (family-values-motion P10).
//
// Held, the list opens and the press goes on in it the way a Mac's menus
// do: drawn down onto a row and let go, that page. Let go anywhere else and
// it stays, for the pointer, the arrows and Return; Escape, a press outside
// or the door again put it away. Pressed and drawn down at once, or
// right-clicked, it opens without the wait.
//
// ⌘ or the middle button, on a row or on the door itself, opens that page
// in a new tab beside this one and leaves you here, ⇧ with it taking you
// there, as a link does.

/// Watches the presses on the doors that list (`Door.hold`). The press is
/// SwiftUI's button's as ever; this only reads it, from AppKit, since a
/// press that goes on into another window, the list's, is past what a
/// SwiftUI gesture follows.
@MainActor
final class DoorHold {
    static let shared = DoorHold()

    /// Held this long, the list opens.
    static let delay: TimeInterval = 0.4
    /// Drawn down this far while pressed, it opens at once.
    static let drawn: CGFloat = 8

    private let spots = NSHashTable<Spot>.weakObjects()
    private var monitor: Any?
    private weak var pressed: Spot?
    private var start: NSPoint = .zero
    private var wait: DispatchWorkItem?
    /// The list came out of this press.
    private var opened = false
    /// So the button's own click, on the same press, is not one.
    private var spentClick = false

    /// Whether the press the button was just clicked with opened or closed
    /// a list, and so is not a click.
    func spent() -> Bool {
        defer { spentClick = false }
        return spentClick
    }

    fileprivate func add(_ spot: Spot) {
        spots.add(spot)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func spot(at event: NSEvent) -> Spot? {
        guard let window = event.window else { return nil }
        return spots.allObjects.first { spot in
            spot.window === window && !spot.isHiddenOrHasHiddenAncestor
                && spot.convert(spot.bounds, to: nil).contains(event.locationInWindow)
        }
    }

    private func screen(_ event: NSEvent) -> NSPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            spentClick = false
            cancel()
            guard let spot = spot(at: event), spot.open != nil else { return event }
            // Pressed again while its list is out: the list goes, and that
            // is all the press does.
            if DoorList.shared.isOpen(from: spot) {
                DoorList.shared.close()
                spentClick = true
                return event
            }
            pressed = spot
            start = screen(event)
            opened = false
            let wait = DispatchWorkItem { [weak self, weak spot] in
                guard let self, let spot, pressed === spot else { return }
                open(spot)
            }
            self.wait = wait
            DispatchQueue.main.asyncAfter(deadline: .now() + DoorHold.delay, execute: wait)
            return event
        case .leftMouseDragged:
            guard let spot = pressed else { return event }
            let at = screen(event)
            if opened {
                DoorList.shared.hover(at: at)
            } else if start.y - at.y >= DoorHold.drawn {
                open(spot)
                DoorList.shared.hover(at: at)
            }
            return event
        case .leftMouseUp:
            guard pressed != nil else { return event }
            let at = screen(event)
            let was = opened
            cancel()
            if was {
                spentClick = true
                DoorList.shared.release(at: at)
            }
            return event
        case .rightMouseDown:
            guard let spot = spot(at: event), spot.open != nil else { return event }
            if DoorList.shared.isOpen(from: spot) {
                DoorList.shared.close()
            } else {
                _ = spot.open?(spot)
            }
            return nil
        case .otherMouseUp:
            // The middle button: beside, as a link's middle click opens.
            guard let spot = spot(at: event), let beside = spot.beside, let front = Browser.beside(event) else { return event }
            beside(front)
            return nil
        default:
            return event
        }
    }

    private func open(_ spot: Spot) {
        wait?.cancel()
        wait = nil
        guard !opened else { return }
        opened = spot.open?(spot) ?? false
        if !opened { cancel() }
    }

    /// For the bench: the list of the leftmost door that lists, in sight in
    /// the window, back before forward, opened as a hold would.
    func benchOpen(in window: NSWindow) -> Bool {
        let shown = spots.allObjects.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.open != nil }
        guard let spot = shown.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        else { return false }
        return spot.open?(spot) ?? false
    }

    /// For the bench: the doors in sight in the browser's window, by their
    /// symbol ("door arrow.left"), in its points from its top left.
    func benchDoors() -> [String: CGRect] {
        guard let window = Links.window, let content = window.contentView else { return [:] }
        var out: [String: CGRect] = [:]
        for spot in spots.allObjects where spot.window === window && !spot.isHiddenOrHasHiddenAncestor {
            let frame = spot.convert(spot.bounds, to: nil)
            out["door \(spot.name)"] = CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        }
        return out
    }

    private func cancel() {
        wait?.cancel()
        wait = nil
        pressed = nil
        opened = false
    }

    /// Where a door that lists or opens beside stands, laid under it: takes
    /// no clicks, only says where the door is, what holding it opens and
    /// what the middle button does on it.
    final class Spot: NSView {
        var open: ((NSView) -> Bool)?
        var beside: ((Bool) -> Void)?
        /// The door's symbol, for the bench.
        var name = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    struct Anchor: NSViewRepresentable {
        let open: ((NSView) -> Bool)?
        var beside: ((Bool) -> Void)? = nil
        var name = ""

        func makeNSView(context: Context) -> Spot {
            let spot = Spot()
            spot.name = name
            spot.open = open
            spot.beside = beside
            DoorHold.shared.add(spot)
            return spot
        }

        func updateNSView(_ spot: Spot, context: Context) {
            spot.name = name
            spot.open = open
            spot.beside = beside
        }
    }
}

/// The list itself: one at a time, for the door it was opened from, on the
/// swipe's own card (PanelGround), laid over everything in the door's
/// window, where the swipe's list is laid too, so its glass takes the same
/// ground and it hangs from a door in the sidebar or in the row of tabs
/// alike. "Search History" opens the tab's history (HistoryPanel) in the
/// same place, its top where the list's was.
@MainActor
final class DoorList: ObservableObject {
    static let shared = DoorList()

    /// Past this many rows, the rest scroll.
    static let tallest = 10
    /// Between the door and the card.
    static let gap: CGFloat = 6
    /// The rows' coordinate space: the host's own, top down.
    nonisolated static let space = "door-list"

    @Published private(set) var stops: [Stop] = []
    /// The row the pointer or the arrows are on.
    @Published var lit: Int?
    /// The tab's whole history, once "Search History" is picked.
    @Published private(set) var history: TabHistory?
    let seen = HistoryPanelModel()
    /// Where each row stands in the host, top down, for a press still held
    /// on the door.
    var rows: [Int: CGRect] = [:]

    private var navigation: PageNavigationList?
    private var opening: UUID?
    private var openingMonitor: Any?
    private var own = false
    private weak var tab: Tab?
    private weak var browser: Browser?
    private weak var anchor: NSView?
    /// The door, in its window, and which of its edges the card keeps to.
    private var door: NSRect = .zero
    private var leading = true
    private var host: DoorHost?
    private var monitors: [Any] = []
    private var away: NSObjectProtocol?

    func isOpen(from view: NSView) -> Bool { (host != nil || opening != nil) && anchor === view }

    /// Opens from `view`, unless there is nowhere to go that way.
    func present(_ browser: Browser, _ tab: Tab, back: Bool, own: Bool, from view: NSView) -> Bool {
        close(animated: false)
        guard view.window != nil, !tab.isBlank else { return false }
        if let page = tab.page as? ChromiumPage {
            let token = UUID()
            opening = token; anchor = view
            // A late history reply cannot reopen a list dismissed by another
            // press or Escape while the native snapshot was in flight.
            openingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                self?.close(animated: false)
                return event
            }
            Task { @MainActor [weak self, weak browser, weak tab, weak view, weak page] in
                guard let self, let browser, let tab, let view, let page else { return }
                let snapshot = try? await page.navigationHistory()
                guard opening == token else { return }
                opening = nil
                if let openingMonitor { NSEvent.removeMonitor(openingMonitor); self.openingMonitor = nil }
                guard let snapshot, tab.builtPage === page, let window = view.window,
                      page.window === window else { anchor = nil; return }
                _ = show(browser, tab, own: own, from: view, list: snapshot.list(page: page, tab: tab, back: back))
            }
            return true
        }
        guard let web = tab.webKitOnly("Native history list") else { return false }
        return show(browser, tab, own: own, from: view, list: PageNavigationList(web: web, back: back))
    }

    private func show(_ browser: Browser, _ tab: Tab, own: Bool, from view: NSView, list: PageNavigationList) -> Bool {
        guard let window = view.window, let content = window.contentView, !tab.isBlank else { return false }
        let stops = list.stops
        guard !stops.isEmpty else { return false }
        self.stops = stops
        self.navigation = list
        self.own = own
        self.tab = tab
        self.browser = browser
        anchor = view
        lit = nil
        history = nil
        rows = [:]
        door = view.convert(view.bounds, to: nil)
        // Its left edge on the door's in the sidebar, its right edge on it
        // where the doors end the row of tabs, so it never hangs past the
        // window.
        leading = door.midX < content.bounds.midX

        let host = DoorHost(rootView: DoorListView(list: self))
        // Measured by what it holds: the list, then the taller history.
        host.sizingOptions = [.intrinsicContentSize]
        // Laid over the title bar too: no room kept for it at the top.
        host.safeAreaRegions = []
        host.wantsLayer = true
        self.host = host
        // Beside SwiftUI's view rather than in it: a view added into the
        // hosting view is drawn under what SwiftUI draws (SpaceTray).
        let top = content.superview ?? content
        top.addSubview(host, positioned: .above, relativeTo: top === content ? nil : content)
        fit()
        watch()
        fade(host, in: true)
        return true
    }

    func close(animated: Bool = true) {
        opening = nil
        if let openingMonitor { NSEvent.removeMonitor(openingMonitor); self.openingMonitor = nil }
        anchor = nil
        guard let host else { return }
        unwatch()
        let typing = history != nil
        self.host = nil
        anchor = nil
        lit = nil
        if typing, let page = tab?.builtPage { host.window?.makeFirstResponder(page) }
        guard animated else { return host.removeFromSuperview() }
        fade(host, in: false)
    }

    /// The press still held on the door, over the list: the row under it
    /// lit.
    func hover(at point: NSPoint) {
        let row = row(at: point)
        if lit != row { lit = row }
    }

    /// Let go there: that row, or, anywhere else, the list stays.
    func release(at point: NSPoint) {
        if let row = row(at: point) { take(row) } else { lit = nil }
    }

    /// That row, here, or beside when the current app event asks for it.
    func take(_ row: Int) {
        take(row, as: NSApp.currentEvent)
    }

    /// That row, here, or beside when `event` asks for it (`Browser.beside`).
    func take(_ row: Int, as event: NSEvent?) {
        guard history == nil, row >= 0, row < stops.count, let tab, let browser else { return }
        let stop = stops[row]
        if let front = Browser.beside(event), let url = navigation?.address(stop) {
            close()
            browser.openBeside(url, from: tab, foreground: front)
            return
        }
        if own { browser.focus(tab) }
        if stop.kind == .search {
            search(tab)
            return
        }
        close()
        navigation?.take(stop)
    }

    /// The card, laid again at the size its content asks, or says it
    /// took, the door's edge and the card's top kept where they are,
    /// inside the window.
    func fit(_ taken: CGSize? = nil) {
        guard let host, let content = host.superview else { return }
        let size = taken ?? host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let m = PullView.margin
        let room = content.convert(content.bounds, to: nil)
        var rect = NSRect(x: leading ? door.minX - m : door.maxX + m - size.width,
                          y: door.minY - DoorList.gap + m - size.height,
                          width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, room.minX - m + 8), room.maxX + m - 8 - size.width)
        rect.origin.y = max(rect.minY, room.minY - m + 8)
        let frame = content.convert(rect, from: nil).integral
        guard frame != host.frame else { return }
        host.frame = frame
    }

    /// The tab's history in the list's place, its field ready for words.
    private func search(_ tab: Tab) {
        guard let history = navigation?.history() else { return }
        lit = nil
        self.history = history
        Diary.shared.lastSeen(history.entries.map(\.url)) { [weak self] seen in self?.seen.seen = seen }
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    func pickHistory(_ index: Int) {
        history?.pick(index)
        close()
    }

    func searchAll(_ words: String) {
        if let tab { tab.onSearchHistory?(tab, words) }
        close()
    }

    /// In and out on a fade alone: back is pressed all day, and the list is
    /// a quiet thing that comes out of it.
    private func fade(_ host: NSView, in coming: Bool) {
        guard let layer = host.layer else {
            if !coming { host.removeFromSuperview() }
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || coming else { return host.removeFromSuperview() }
        let pace = coming ? Reshape.Pace.arrive : Reshape.Pace.depart
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !coming {
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { host.removeFromSuperview() } }
        }
        layer.opacity = coming ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = coming ? 0 : 1
        fade.toValue = coming ? 1 : 0
        fade.duration = pace.duration
        fade.timingFunction = pace.timing
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    private func row(at point: NSPoint) -> Int? {
        guard let host, let window = host.window, history == nil else { return nil }
        var local = host.convert(window.convertPoint(fromScreen: point), from: nil)
        if !host.isFlipped { local.y = host.bounds.height - local.y }
        return rows.first { $0.value.contains(local) }?.key
    }

    /// A press anywhere else or the app put away closes it; up, down,
    /// Return and Escape work the list while it is out. The history's field
    /// takes its own keys.
    private func watch() {
        unwatch()
        let presses = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let host else { return event }
            let mine = event.window === host.window
            let at = event.locationInWindow
            if mine, host.frame.contains(host.superview?.convert(at, from: nil) ?? at) { return event }
            if !(mine && door.contains(at)) { close() }
            return event
        }
        // The middle button on a row: beside (`take`). SwiftUI's tap never
        // hears it.
        let middles = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self, let host, event.window === host.window, Browser.beside(event) != nil,
                  let row = row(at: host.window?.convertPoint(toScreen: event.locationInWindow) ?? .zero) else { return event }
            take(row, as: event)
            return nil
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌘Return, and ⇧⌘Return, as a ⌘-click is.
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let beside = [36, 76].contains(event.keyCode) && mods.contains(.command) && mods.isSubset(of: [.command, .shift])
            guard let self, let host, event.window === host.window, history == nil,
                  mods.isEmpty || beside else { return event }
            switch event.keyCode {
            case 125:
                lit = min(stops.count - 1, (lit ?? -1) + 1)
            case 126:
                lit = max(0, (lit ?? stops.count) - 1)
            case 36, 76:
                guard let lit else { return event }
                take(lit)
            case 53:
                close()
            default:
                return event
            }
            return nil
        }
        monitors = [presses, middles, keys].compactMap { $0 }
        away = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func unwatch() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let away { NotificationCenter.default.removeObserver(away) }
        away = nil
    }

    /// For the bench: where each row is, in the window's points from its
    /// top left, pressed as the mouse would press it.
    func benchRows() -> [String: CGRect] {
        guard let host, let content = host.window?.contentView else { return [:] }
        var out: [String: CGRect] = [:]
        for (index, rect) in rows {
            let local = NSRect(x: rect.minX, y: host.isFlipped ? rect.minY : host.bounds.height - rect.maxY,
                               width: rect.width, height: rect.height)
            let frame = host.convert(local, to: nil)
            out["history row \(index)"] = CGRect(x: frame.minX, y: content.bounds.height - frame.maxY,
                                                 width: frame.width, height: frame.height)
        }
        return out
    }

    /// Takes the first click though the window isn't key.
    final class DoorHost: NSHostingView<DoorListView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// The rows, the swipe's own on the swipe's card, lit where the pointer or
/// the arrows are; or, once picked, the tab's history.
struct DoorListView: View {
    @ObservedObject var list: DoorList

    var body: some View {
        if let history = list.history {
            HistoryPanelView(history: history, model: list.seen,
                             go: { list.pickHistory($0) },
                             all: { list.searchAll($0) },
                             close: { list.close() },
                             resized: { list.fit($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            card
                .modifier(PanelGround(width: PullView.listWidth))
                .padding(PullView.margin)
                .fixedSize()
                .coordinateSpace(name: DoorList.space)
        }
    }

    @ViewBuilder
    private var card: some View {
        if list.stops.count > DoorList.tallest {
            ScrollViewReader { reader in
                ThreadScrollView(.vertical) { rows }
                    .scrollIndicators(.never)
                    .frame(height: CGFloat(DoorList.tallest) * PullList.rowHeight)
                    .onChange(of: list.lit) { _, lit in
                        if let lit { reader.scrollTo(lit) }
                    }
            }
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(list.stops.enumerated()), id: \.offset) { index, stop in
                PullList.row(stop, lit: list.lit == index)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { list.lit = index } else if list.lit == index { list.lit = nil }
                    }
                    .onTapGesture { list.take(index) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DoorList.space)) } action: { list.rows[index] = $0 }
                    .id(index)
            }
        }
    }
}

extension Browser {
    /// A back or forward door held: the pages that way, listed from it.
    func history(back: Bool, of tab: Tab, own: Bool, from door: NSView) -> Bool {
        DoorList.shared.present(self, tab, back: back, own: own, from: door)
    }

    /// A click that asks for a page beside rather than here, as a link's
    /// does: ⌘ or the middle button. Nil for any other; otherwise whether
    /// the new tab comes to the front, ⇧ with it.
    static func beside(_ event: NSEvent?) -> Bool? {
        guard let event else { return nil }
        let middle = (event.type == .otherMouseUp || event.type == .otherMouseDown) && event.buttonNumber == 2
        guard middle || event.modifierFlags.contains(.command) else { return nil }
        return event.modifierFlags.contains(.shift)
    }

    /// Back or forward so clicked: the page that way in a new tab after
    /// this one, which stays where it is.
    func beside(back: Bool, of tab: Tab, front: Bool) {
        if let page = tab.builtPage as? ChromiumPage {
            Task { @MainActor [weak self, weak tab, weak page] in
                guard let self, let tab, let page, let history = try? await page.navigationHistory(),
                      tab.builtPage === page, let target = history.pages(back: back).first else { return }
                openBeside(target.url, from: tab, foreground: front)
            }
            return
        }
        guard let list = tab.webKitOnly("WebKit history preview", build: false)?.backForwardList, let url = (back ? list.backItem : list.forwardItem)?.url else { return }
        openBeside(url, from: tab, foreground: front)
    }

    /// Reload so clicked: the same page again in a new tab beside it.
    func reloadBeside(_ tab: Tab, front: Bool) {
        guard let url = tab.address else { return }
        openBeside(url, from: tab, foreground: front)
    }
}
