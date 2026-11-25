import AppKit
import Combine
import SwiftUI
import WebKit

/// Which tab is which, without going to it: rest the pointer on a tab and a
/// card comes down from it with the page as you last left it, the whole
/// title and the site.
///
/// Pointing at tabs is something done all day, so the card holds back: it
/// comes only once the pointer has stayed half a second and has stopped
/// moving, and then, while it is up or just gone, the next tab's comes as
/// soon as the pointer stops on it, so reading along the row doesn't wait
/// on each tab, and a pointer only crossing a tab on its way elsewhere
/// brings nothing. It never takes the pointer, but for a card with a button
/// (TabGist: Checks, Pause, Sleep), which holds while the pointer goes from
/// the tab onto it, as a folder's preview does: off the tab, anywhere else,
/// and it goes. A press of the mouse or a key puts it
/// away at once, and the tab the pointer was on then gives no card until
/// the pointer has been off it: a tab clicked was gone to, not read.
///
/// An agent's tab has two: rest on the tab and its card says, under the
/// page, what the agent is doing; rest on the agent's face at the tab's end
/// and the agent's own card comes down from the face instead, sooner, since
/// pointing at a face that small is meant. It is the dock from the foot of
/// the agent's page, the same dark card in the same words, brought to where
/// you asked for it.
///
/// A shut folder's card is one to work in, as Arc's folder preview is: its
/// tabs under a search, the letters typed while it is up going to the
/// search, ↑↓ and Return to pick one, which comes out under the shut
/// folder as the tab in front. It takes the pointer, and holds while the
/// pointer is on its way from the folder to it or over it.
@MainActor
final class TabGlance: ObservableObject {
    /// The tab whose card is up.
    @Published private(set) var shown: Tab.ID?
    /// A folder's contents, from its pill in the strip.
    @Published private(set) var shownFolder: String?
    /// The card up is the agent's, from its face, not the tab's.
    @Published private(set) var agent = false
    /// The folder's card up is its preview, a shut folder's tabs to search
    /// and pick from, not only its name.
    @Published private(set) var searching = false
    /// The tab's card up has a button (TabGist): it takes the pointer, and
    /// holds while the pointer is on its way from the tab to it, as a
    /// folder's preview does.
    @Published private(set) var holds = false
    /// A card up that the pointer may go onto: a preview, or a tab's card
    /// with a button.
    var taking: Bool { searching || holds }
    /// What has been typed into the preview, and the row picked in what it
    /// finds.
    @Published private(set) var query = ""
    @Published var lit = 0
    /// Held for this opening, so filtering shortens the far end only.
    @Published private(set) var previewFalls = true
    private weak var searchField: NSSearchField?
    private weak var searchWindow: NSWindow?
    private weak var beforeSearch: NSResponder?

    /// The real field editor owns text selection, input methods and paste.
    var editingSearch: Bool {
        guard let field = searchField, let window = field.window else { return false }
        return window.firstResponder === field || (window.firstResponder as? NSText)?.delegate === field
    }

    func focusSearch(_ field: NSSearchField) {
        searchField = field
        guard searching, let window = field.window, window.isKeyWindow, !editingSearch,
              browser?.active?.typing != true, !(window.firstResponder is NSTextView) else { return }
        beforeSearch = window.firstResponder
        searchWindow = window
        window.makeFirstResponder(field)
    }

    func search(_ words: String) {
        guard query != words else { return }
        query = words
        lit = 0
        if let id = shownFolder, Self.isPin(id) { listPin() }
    }

    func walkPreview(_ step: Int) {
        guard let id = shownFolder else { return }
        let count = Self.isPin(id) ? pinItems.count : items(id).count
        lit = min(max(lit + step, 0), max(count - 1, 0))
    }

    func takePreview() {
        guard let id = shownFolder else { return }
        if Self.isPin(id) {
            if pinItems.indices.contains(lit) { pickPin(pinItems[lit]) }
            return
        }
        let found = items(id)
        guard found.indices.contains(lit) else { return }
        switch found[lit] {
        case .tab(let tab): pick(tab)
        case .folder(let nest, _): enter(nest)
        }
    }
    /// The folder of yours in the shut one whose card is up that the card
    /// shows the inside of, gone into from its row (nil: the card's own).
    @Published private(set) var at: String?
    /// A pin's card, a list in place of the page's picture (PinCards.swift):
    /// its lines for the words typed. Its id is the pin's, "pin:" first.
    @Published private(set) var pinItems: [PinItem] = []
    /// A reply belongs to one opening or search, including when the same
    /// pin is closed and reopened before its first reply arrives.
    private var pinRequest: UUID?
    typealias PinLoader = @MainActor (Tab, Browser, String, @escaping @MainActor ([PinItem]) -> Void) -> Void
    var pinLoader: PinLoader = PinList.items
    /// A pointer supplied by an isolated test world, in the tabs' space.
    var pointerLocation: (() -> CGPoint?)?
    /// Where the preview is in the window, counted from its top left as
    /// the folders' shapes are.
    var previewFrame: CGRect?
    /// The pointer is over the preview.
    private var inside = false
    /// A tab or folder the pointer came onto through the preview: the
    /// column, in a host of its own, hears the pointer under the card. Not
    /// rested on, and taken up only if the pointer comes off the preview
    /// still on it.
    private var through: Through?
    private enum Through: Equatable { case tab(Tab.ID), folder(String) }

    /// The page as it was when last left, for each tab that has been left:
    /// already the card's size in pixels with the card's corners, so
    /// drawing it is a copy, no scaling and no clip. Only in memory, never
    /// written anywhere, and only so many, about half a megabyte each: the
    /// tabs looked at longest ago give theirs up first, a closed tab's at once.
    private(set) var stills: [Tab.ID: NSImage] = [:]
    private var order: [Tab.ID] = []
    private static let kept = 40

    private weak var browser: Browser?
    private var under: Tab.ID?
    /// Where the tab under the pointer is said to be has held the pointer
    /// since its hovering said so. Until then that place is not believed
    /// over the tab's own word: it was once a strip's height off, and the
    /// first move on a tab took it off again and no card came.
    private var agreed = false
    private var underFolder: String?
    var folderFrames: [String: CGRect] = [:]
    /// Bookmarks borrow a folder anchor and the same dwell, dismissal and
    /// pointer corridor as tabs; their content comes from the row.
    private(set) var bookmarkChips: [String: BookmarkBar.Chip] = [:]

    func putBookmark(_ key: String, chip: BookmarkBar.Chip, frame: CGRect) {
        if shownFolder == key, bookmarkChips[key] != chip { objectWillChange.send() }
        bookmarkChips[key] = chip
        folderFrames[key] = frame
    }

    func removeBookmark(_ key: String) {
        hoverFolder(key, false)
        bookmarkChips[key] = nil
        folderFrames[key] = nil
        if shownFolder == key { drop() }
    }

    func hoverBookmark(_ key: String, _ on: Bool) {
        hoverFolder(key, on)
    }

    /// The tab row or pill under the pointer, if one is.
    var pointed: Tab.ID? { under }
    /// The last tab whose own hovering said the pointer came onto it and
    /// hasn't said it left, whatever else is believed: for the bench.
    private(set) var heard: Tab.ID?
    /// The tab whose agent's face the pointer is on.
    private var onFace: Tab.ID?
    /// Where the pointer was on a tab when the mouse or a key was pressed:
    /// no card while it stays there. Whatever comes under it next, the tab
    /// itself redrawn as the one in front or the next one sliding up into a
    /// closed one's place, was not rested on.
    private var hush: CGRect?
    private var coming: DispatchWorkItem?
    private var going: DispatchWorkItem?
    /// Until when the next tab's card comes without the wait.
    private var warm = Date.distantPast
    /// Where the pointer last was in the window, and when it last moved
    /// faster than a hand resting on a tab moves it.
    private var last: (spot: CGPoint, at: TimeInterval)?
    private var brisk: TimeInterval = 0
    /// When the tab in front came to the front.
    private var since = CACurrentMediaTime()
    private var watching: Set<AnyCancellable> = []
    private var monitors: [Any] = []

    private static let dwell: TimeInterval = 0.5
    /// A face is small and pointed at on purpose: its card comes sooner,
    /// but not on a pointer only passing over it along the row.
    private static let beckon: TimeInterval = 0.15
    /// How long the pointer has to have been slow before any card comes,
    /// the first or the next along the row.
    private static let settle: TimeInterval = 0.08
    /// Faster than this, in points a second, the pointer is on its way
    /// somewhere, not resting.
    private static let rest: CGFloat = 90
    private static let linger: TimeInterval = 0.12
    /// Off a folder with its preview up: long enough for the pointer to
    /// get from the folder across to the preview beside or under it.
    private static let corridor: TimeInterval = 0.35
    private static let grace: TimeInterval = 0.7
    /// A tab in front for less than this was passed through, ⌃Tab going
    /// by it, not looked at: the picture it already has stays.
    private static let looked: CFTimeInterval = 0.35

    /// The card's width, its corner, and the picture's height in it; a
    /// folder's or a pin's preview's width, and how many of a pin's rows
    /// show before it scrolls.
    static let width: CGFloat = 264
    static let folderPreviewWidth: CGFloat = FieldActionsPanel.width
    static let previewRows = 9
    /// A tab's card is a popover beside its tab (Radius.floating); its
    /// button sits `buttonInset` in from its corner, so the button's
    /// control corner runs on the card's: 6 + 8 = 14, the find bar's.
    static let corner: CGFloat = Radius.floating
    static let inset: CGFloat = 12
    static let buttonInset: CGFloat = BarFrame.inset
    static let still: CGFloat = 132

    private static let all = NSMapTable<Browser, TabGlance>.weakToStrongObjects()
    /// Where pictures are cut to the card, off the main thread.
    private static let studio = DispatchQueue(label: "glance.stills", qos: .utility)

    /// The one for this window's browser.
    static func of(_ browser: Browser) -> TabGlance {
        if let glance = all.object(forKey: browser) { return glance }
        let glance = TabGlance(browser)
        all.setObject(glance, forKey: browser)
        return glance
    }

    init(_ browser: Browser) {
        self.browser = browser
        // Heard as the tab in front is about to change, while the one being
        // left is still on screen: the moment to keep a picture of it.
        browser.changes(\.activeID)
            .sink { [weak self, weak browser] next in
                guard let self, let browser, let old = browser.active, old.id != next else { return }
                let now = CACurrentMediaTime()
                if now - self.since >= Self.looked { self.keep(old) }
                self.since = now
                // Gone to: its own card would only show the page now in front.
                if self.shown == next { self.drop() }
            }
            .store(in: &watching)
        // A tab closed: its card goes if it is up, and its picture.
        browser.changes(\.tabs)
            .sink { [weak self] tabs in
                guard let self else { return }
                let alive = Set(tabs.map(\.id))
                if let shown = self.shown, !alive.contains(shown) { self.drop() }
                if self.order.contains(where: { !alive.contains($0) }) {
                    for gone in self.order where !alive.contains(gone) { self.stills[gone] = nil }
                    self.order.removeAll { !alive.contains($0) }
                }
            }
            .store(in: &watching)
        // The tabs moving to the side or the top: the card would hang
        // from where its tab no longer is.
        browser.prefs.changes(\.sidebar)
            .dropFirst()
            .sink { [weak self] _ in self?.drop() }
            .store(in: &watching)
        // The column put away, its rows gone past the edge.
        browser.peek.$out
            .dropFirst()
            .sink { [weak self] out in if !out { self?.drop() } }
            .store(in: &watching)
        // And the strip put away, or gone back up past the top edge.
        browser.topPeek.$out.combineLatest(browser.prefs.changes(\.stripShut))
            .dropFirst()
            .sink { [weak self] out, shut in if shut && !out { self?.drop() } }
            .store(in: &watching)
        let quiet: (Notification) -> Void = { [weak self] _ in self?.drop() }
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink(receiveValue: quiet).store(in: &watching)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink(receiveValue: quiet).store(in: &watching)
        // Where the pointer really is, not only what the tabs' hovering
        // says: that can come again for a tab the pointer never left, as the
        // tab is drawn anew, and a leaving can go unheard.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            AppKitMainThread.sync { self?.moved(event) }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = AppKitMainThread.sync { () -> Bool in
                guard let self else { return false }
                if self.typed(event) { return true }
                self.pressed(event)
                return false
            }
            return consumed ? nil : event
        } as Any)
    }

    deinit {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }

    /// The pointer came onto a tab, or went off it. Nothing is published
    /// until a card comes or goes, so running the pointer along the row
    /// redraws nothing but the tabs it crosses.
    func hover(_ id: Tab.ID, _ on: Bool) {
        // Off a tab nothing here knows of: rows scrolled away or recycled
        // say so by the dozen, so this answers in constant time, without
        // looking the tab up among all of them.
        if !on, !concerns(id) { return }
        if on { heard = id } else if heard == id { heard = nil }
        if on, overPreview { through = .tab(id); return }
        if !on, through == .tab(id) { through = nil }
        // A pin: its card is a list to work in, as a shut folder's is.
        if let browser, let tab = browser.tabs.first(where: { $0.id == id }), PinList.wanted(tab) {
            let key = Self.pinKey(id)
            if on, let frame = browser.keySky.place(id) { folderFrames[key] = frame }
            return hoverFolder(key, on)
        }
        // A button held is a drag or a click on its way: not reading tabs.
        if on, NSEvent.pressedMouseButtons != 0 { return }
        if on, covered { return }
        if on {
            underFolder = nil
            under = id
            agreed = pointer().map { spot in frame(id)?.contains(spot) ?? false } ?? false
            going?.cancel()
            // With a card up or just gone, the next one as soon as the
            // pointer stops on it; the card up stays where it is meanwhile.
            arm(id, after: shown != nil || shownFolder != nil || Date() < warm ? 0 : Self.dwell)
        } else if under == id {
            under = nil
            if onFace == id { onFace = nil }
            coming?.cancel()
            leave()
        }
    }

    /// Whether a tab's leaving could change anything: it is the one heard,
    /// under the pointer, heard through the preview, or the pin whose card
    /// is wanted. Only these are read when `hover` hears it leave.
    func concerns(_ id: Tab.ID) -> Bool {
        if heard == id || under == id || through == .tab(id) { return true }
        guard underFolder != nil || through != nil else { return false }
        let key = Self.pinKey(id)
        return underFolder == key || through == .folder(key)
    }

    func hoverFolder(_ id: String, _ on: Bool) {
        if on, overPreview { through = .folder(id); return }
        if !on, through == .folder(id) { through = nil }
        if on, NSEvent.pressedMouseButtons != 0 || covered { return }
        if on {
            under = nil
            if underFolder != id { pinRequest = nil }
            underFolder = id
            going?.cancel()
            armFolder(id, after: shown != nil || shownFolder != nil || Date() < warm ? 0 : Self.dwell)
        } else if underFolder == id {
            underFolder = nil
            if shownFolder != id { pinRequest = nil }
            coming?.cancel()
            leave()
        }
    }

    /// The pointer came onto an agent's face at a tab's end, or went off it,
    /// always inside the tab's own `hover`.
    func face(_ id: Tab.ID, _ on: Bool) {
        if on {
            if NSEvent.pressedMouseButtons != 0 || overPreview || covered { return }
            onFace = id
            going?.cancel()
            arm(id, after: shown != nil || shownFolder != nil || Date() < warm ? 0 : Self.beckon)
        } else if onFace == id {
            onFace = nil
            coming?.cancel()
            guard under == id else { return }
            // Back on the rest of the tab: its own card, at once if the
            // agent's was up, as the next tab's would be. A moment later,
            // so a pointer leaving the tab by way of the face doesn't flash
            // the tab's card on its way out.
            arm(id, after: shown == id ? Self.linger : Self.dwell)
        }
    }

    /// The card as if the pointer had rested on the tab, for ./bench, where
    /// there is no pointer to ask where it is.
    func pretend(_ id: Tab.ID, _ on: Bool) {
        if on { under = id; hush = nil; show(id, agent: false) } else { hover(id, false) }
    }

    /// The folder card without a pointer, for an isolated bench world.
    func pretendFolder(_ id: String, _ on: Bool) {
        if on { underFolder = id; hush = nil; shown = nil; open(id) }
        else { drop() }
    }

    /// Put away at once, and not warm: whatever the pointer did next was
    /// not reading tabs.
    func drop() {
        coming?.cancel()
        going?.cancel()
        warm = .distantPast
        if shown != nil { shown = nil }
        if shownFolder != nil { shownFolder = nil }
        if agent { agent = false }
        closePreview()
    }

    // MARK: - the folder's preview

    /// A folder's card: the preview, over a shut folder with tabs in it;
    /// over any other only its name, and only on the strip, where a folder
    /// can be down to its first letter.
    private func open(_ id: String) {
        // Hung from where the folder is now, as a tab's card (show).
        if let browser { ColumnPages.of(browser)?.moved() }
        if Self.isPin(id) {
            if shownFolder == id, searching { return }
            closePreview()
            shownFolder = nil
            listPin(id, opening: true)
            return
        }
        pinRequest = nil
        if bookmarkChips[id] != nil {
            if shownFolder != id { closePreview() }
            shownFolder = id
            return
        }
        let folders = browser?.folderBook ?? .shared
        let folder = folders.folder(id)
        let shut = !(folder?.nest?.open ?? folders.open.contains(id))
        let search = folder != nil && shut && !(folder?.members.isEmpty ?? true)
        if !search, browser?.prefs.sidebar ?? false { return }
        if shownFolder != id || searching != search {
            query = ""
            lit = 0
            inside = false
            at = nil
            if let frame = folderFrames[id], let room = home?.contentView?.bounds.size {
                let tall = FolderPreview.height(items(id).count, foot: folder?.nest.flatMap { LiveFolders.foot($0) } != nil)
                let top = browser?.prefs.sidebar == true ? frame.midY - FolderPreview.field / 2 : frame.maxY + 6
                previewFalls = top + tall <= room.height - 8
            }
        }
        if searching != search { searching = search }
        if shownFolder != id { shownFolder = id }
    }

    private func closePreview() {
        pinRequest = nil
        if editingSearch, let window = searchWindow ?? searchField?.window {
            window.makeFirstResponder(beforeSearch ?? browser?.active?.builtPage)
        }
        searchField = nil
        searchWindow = nil
        beforeSearch = nil
        through = nil
        if searching { searching = false }
        if holds { holds = false }
        if !query.isEmpty { query = "" }
        if at != nil { at = nil }
        lit = 0
        inside = false
        previewFrame = nil
    }

    /// The preview's tabs, in the folder's order, those the words find:
    /// under the folder gone into, if one is, however deep.
    func found(_ id: String) -> [Tab] {
        guard let browser, let folder = browser.folderBook.folder(at ?? id) ?? browser.folderBook.folder(id) else { return [] }
        let tabs = folder.members.compactMap { member in browser.tabs.first { $0.id == member } }
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return tabs }
        return tabs.filter {
            $0.label.lowercased().contains(words) || ($0.address?.host()?.lowercased().contains(words) ?? false)
        }
    }

    /// A row of the preview: a tab, or a folder of yours in the one shown,
    /// with how many tabs are under it.
    enum PreviewItem: Identifiable {
        case tab(Tab)
        case folder(Nest, count: Int)

        var id: String {
            switch self {
            case .tab(let tab): return tab.id.uuidString
            case .folder(let nest, _): return Nest.key(nest.id)
            }
        }
    }

    /// What the preview lists: with words typed, the tabs they find under
    /// the shut folder, however deep; else what is right in the folder
    /// shown, its tabs and its folders, each where its first tab stands.
    func items(_ id: String) -> [PreviewItem] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return found(id).map { .tab($0) } }
        guard let browser, let folder = browser.folderBook.folder(at ?? id), let nest = folder.nest else {
            return found(id).map { .tab($0) }
        }
        var out: [PreviewItem] = []
        var listed = Set<UUID>()
        for member in folder.members {
            guard let tab = browser.tabs.first(where: { $0.id == member }), let inner = tab.nest else { continue }
            if inner === nest {
                out.append(.tab(tab))
                continue
            }
            let chain = inner.chain
            guard let here = chain.firstIndex(where: { $0 === nest }), here + 1 < chain.count else { continue }
            let next = chain[here + 1]
            if listed.insert(next.id).inserted {
                out.append(.folder(next, count: browser.folderBook.folder(next.key)?.members.count ?? 0))
            }
        }
        return out
    }

    /// Into a folder of yours from its row in the preview, or back out to
    /// the one it is in.
    func enter(_ nest: Nest) {
        at = nest.key
        query = ""
        lit = 0
    }

    func back() {
        guard let key = at, let root = shownFolder, let nest = (browser?.folderBook ?? .shared).folder(key)?.nest else { return }
        let up = nest.parent.map(\.key)
        at = up == root ? nil : up
        lit = 0
    }

    /// Out to a folder on the way down to the one shown, from its crumb:
    /// the card's own when it is that one's key.
    func back(to key: String?) {
        guard at != nil else { return }
        at = key == shownFolder ? nil : key
        lit = 0
    }

    static func pinKey(_ id: Tab.ID) -> String { "pin:" + id.uuidString }
    static func isPin(_ key: String) -> Bool { key.hasPrefix("pin:") }

    /// The pin whose card is up.
    var pinTab: Tab? {
        guard let key = shownFolder, Self.isPin(key), let id = UUID(uuidString: String(key.dropFirst(4))) else { return nil }
        return browser?.tabs.first { $0.id == id }
    }

    /// A pin's lines again, for the words typed now.
    private func listPin(_ openingKey: String? = nil, opening: Bool = false) {
        guard let browser, let key = openingKey ?? shownFolder,
              Self.isPin(key), let id = UUID(uuidString: String(key.dropFirst(4))),
              let tab = browser.tabs.first(where: { $0.id == id }) else { return }
        let asked = query
        let request = UUID()
        pinRequest = request
        pinLoader(tab, browser, asked) { [weak self, weak tab] items in
            guard let self, let tab, self.pinRequest == request, self.query == asked,
                  browser.tabs.contains(where: { $0 === tab }), PinList.wanted(tab),
                  opening ? self.underFolder == key : self.shownFolder == key else { return }
            if self.pinItems != items { self.pinItems = items }
            if self.lit >= items.count { self.lit = 0 }
            // Publish the card only with its completed rows. An empty
            // result is ready too; a pending request is never an empty card.
            if opening {
                self.searching = true
                self.shownFolder = key
            }
        }
    }

    /// A line of a pin's card, gone to.
    func pickPin(_ item: PinItem) {
        drop()
        item.open()
    }

    /// Go to a tab from the preview: it comes out under its shut folder,
    /// as the tab in front does.
    func pick(_ tab: Tab) {
        guard let browser else { return }
        drop()
        if let spot = pointer(), let id = underFolder, let frame = folderFrames[id], frame.contains(spot) { hush = frame }
        browser.select(tab)
    }

    /// A key while the preview is up: letters to its search, ↑↓ along what
    /// it finds, Return to go, Escape away. Anything held with ⌘ or ⌃ is
    /// the app's, and puts the card away as any other key does. Words being
    /// typed somewhere, a page's box or yab's own field, stay there: the
    /// pointer resting on a folder is no reason to take them.
    private func typed(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, searching, let id = shownFolder,
              event.window == nil || event.window === Links.window else { return false }
        if editingSearch { return false }
        if browser?.active?.typing == true || event.window?.firstResponder is NSTextView { return false }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        if event.modifierFlags.contains(.option),
           Hotkey.readings(event).contains(where: { Keymap.shared.action(for: $0) != nil || Keymap.shared.hasCommand($0) || QuickActions.shared.action(for: $0) != nil }) {
            return false
        }
        // Arrows, Return, Escape and Delete navigate this card only bare.
        // A modified one may be a shortcut chosen for the browser.
        if [53, 125, 126, 36, 76, 51, 123, 124].contains(event.keyCode),
           !event.modifierFlags.intersection([.option, .shift]).isEmpty { return false }
        if Self.isPin(id) { return typedPin(event) }
        let found = items(id)
        switch event.keyCode {
        case 53: // escape
            drop()
        case 125: // down
            lit = min(lit + 1, max(found.count - 1, 0))
        case 126: // up
            lit = max(lit - 1, 0)
        case 36, 76, 124: // return, enter, right: a tab gone to, a folder gone into
            guard found.indices.contains(lit) else { break }
            switch found[lit] {
            case .tab(let tab): if event.keyCode != 124 { pick(tab) }
            case .folder(let nest, _): enter(nest)
            }
        case 123: // left: out of a folder gone into
            if at != nil, query.isEmpty { back() } else { return false }
        case 51: // delete
            if !query.isEmpty { query.removeLast(); lit = 0 }
        case 48: // tab
            return false
        default:
            guard let letters = event.characters, !letters.isEmpty,
                  letters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return false }
            query += letters
            lit = 0
        }
        return true
    }

    /// The same keys on a pin's card.
    private func typedPin(_ event: NSEvent) -> Bool {
        let items = pinItems
        switch event.keyCode {
        case 53: drop()
        case 125: lit = min(lit + 1, max(items.count - 1, 0))
        case 126: lit = max(lit - 1, 0)
        case 36, 76: if items.indices.contains(lit) { pickPin(items[lit]) }
        case 51:
            guard !query.isEmpty else { return true }
            query.removeLast()
            lit = 0
            listPin()
        case 48: return false
        default:
            guard let letters = event.characters, !letters.isEmpty,
                  letters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return false }
            query += letters
            lit = 0
            listPin()
        }
        return true
    }

    /// The card for the tab under the pointer, after `delay` and once the
    /// pointer has stopped: its own, or its agent's with the pointer on
    /// the face.
    private func arm(_ id: Tab.ID, after delay: TimeInterval) {
        coming?.cancel()
        if delay <= 0 { ready(id); return }
        later(delay, into: &coming) { [weak self] in self?.ready(id) }
    }

    private func armFolder(_ id: String, after delay: TimeInterval) {
        coming?.cancel()
        if delay <= 0 { readyFolder(id); return }
        later(delay, into: &coming) { [weak self] in self?.readyFolder(id) }
    }

    private func readyFolder(_ id: String) {
        guard underFolder == id, NSEvent.pressedMouseButtons == 0, !covered,
              let frame = folderFrames[id]?.insetBy(dx: -1, dy: -1) else { return }
        if let spot = pointer() {
            if let hush, hush.contains(spot) { return }
            if !frame.contains(spot) { return }
        }
        let calm = ProcessInfo.processInfo.systemUptime - brisk
        if calm < Self.settle {
            later(Self.settle - calm, into: &coming) { [weak self] in self?.readyFolder(id) }
            return
        }
        shown = nil
        agent = false
        open(id)
    }

    private func ready(_ id: Tab.ID) {
        guard under == id || onFace == id, NSEvent.pressedMouseButtons == 0, !covered else { return }
        // Only where the pointer really is, and not where it was when the
        // mouse or a key was pressed.
        if let spot = pointer() {
            if let hush, hush.contains(spot) { return }
            // Off where the tab is said to be: believed once that place
            // has held the pointer, else the tab's own hovering wins.
            if let frame = frame(id) {
                if frame.contains(spot) { agreed = true } else if agreed { return }
            }
        }
        let calm = ProcessInfo.processInfo.systemUptime - brisk
        if calm < Self.settle {
            later(Self.settle - calm, into: &coming) { [weak self] in self?.ready(id) }
            return
        }
        show(id, agent: onFace == id)
    }

    /// Off every tab: the card goes a moment later, unless the pointer is
    /// on another by then.
    private func leave() {
        guard shown != nil || shownFolder != nil else { return }
        later(taking ? Self.corridor : Self.linger, into: &going) { [weak self] in
            guard let self, self.under == nil, self.underFolder == nil, !self.inside else { return }
            self.shown = nil
            self.shownFolder = nil
            self.agent = false
            self.closePreview()
            self.warm = Date().addingTimeInterval(Self.grace)
        }
    }

    private func moved(_ event: NSEvent) {
        guard let window = event.window, window === home, let spot = spot(event.locationInWindow, in: window) else { return }
        moved(to: spot)
    }

    func moved(to spot: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last {
            let travel = hypot(spot.x - last.spot.x, spot.y - last.spot.y)
            if travel / max(now - last.at, 1.0 / 120) > Self.rest { brisk = now }
        }
        last = (spot, now)
        if let hush, !hush.contains(spot) { self.hush = nil }
        // The preview may hang over the next favorite. Its own tracking
        // never hears an entry there, so take it from the pointer too.
        if let tab = favorite(at: spot), underFolder != Self.pinKey(tab.id), under != tab.id,
           NSEvent.pressedMouseButtons == 0, !covered {
            inside = false
            through = nil
            hover(tab.id, true)
        }
        // Off the tab whether or not its hovering said so, once where it is
        // said to be has held the pointer: until then the tab's own word.
        if let id = under, let frame = frame(id) {
            if frame.contains(spot) {
                agreed = true
            } else if agreed {
                if onFace == id { face(id, false) }
                hover(id, false)
            }
        }
        if let id = underFolder, let frame = folderFrames[id], !frame.contains(spot) {
            hoverFolder(id, false)
        }
        // Over the preview it holds; off it, and off its folder, it goes
        // as the pointer leaving a tab's card goes.
        if taking, previewFrame != nil {
            let over = covers(spot)
            if over, !inside {
                inside = true
                going?.cancel()
            } else if !over, inside {
                inside = false
                // Off it onto a row heard through it: that row now.
                switch through {
                case .tab(let id): if frame(id)?.contains(spot) == true { hover(id, true) }
                case .folder(let id): if folderFrames[id]?.insetBy(dx: -1, dy: -1).contains(spot) == true { hoverFolder(id, true) }
                case nil: break
                }
                through = nil
                if under == nil, underFolder == nil { leave() }
            }
        }
    }

    /// The pointer is over the preview, wherever the views under it think
    /// it is.
    private var overPreview: Bool {
        guard let spot = pointer() else { return false }
        return covers(spot)
    }

    /// Favorites take precedence over a pin's overlapping preview. Rows
    /// under any other card still leave the pointer to that card.
    func covers(_ spot: CGPoint) -> Bool {
        taking && previewFrame?.contains(spot) == true && favorite(at: spot) == nil
    }

    private func favorite(at spot: CGPoint) -> Tab? {
        guard searching, let key = shownFolder, Self.isPin(key), let browser, !browser.inMail else { return nil }
        let out = browser.prefs.sidebar ? browser.peek.out : browser.topPeek.out
        guard !browser.tabsAway || out else { return nil }
        return browser.gridPins.first { tab in
            guard let frame = browser.keySky.place(tab.id), frame.width > 0, frame.height > 0 else { return false }
            return frame.contains(spot)
        }
    }

    /// This event's pointer is over the preview: the column's rows, in a
    /// host of their own, hear it through the card and are not to light.
    func covers(_ event: NSEvent) -> Bool {
        if let window = event.window, underTray(event.locationInWindow, in: window) { return true }
        guard let window = event.window,
              let spot = spot(event.locationInWindow, in: window) else { return false }
        return covers(spot)
    }

    private func pressed(_ event: NSEvent) {
        guard event.window == nil || event.window === home else { return }
        // Let the native search editor handle typing and its editing keys.
        // Browser shortcuts still dismiss the hover card before they run.
        if event.type == .keyDown, editingSearch,
           !event.modifierFlags.contains(.command) || [0, 6, 7, 8, 9].contains(event.keyCode) { return }
        // A click in the preview is a pick, or a scroll: the preview's own.
        if event.type != .keyDown,
           let window = event.window, let spot = spot(event.locationInWindow, in: window) {
            if covers(spot) { return }
        }
        if let id = under, let frame = frame(id) { hush = frame }
        if let id = underFolder, let frame = folderFrames[id] { hush = frame }
        drop()
    }

    /// The tab's shape in the window, a point wider all round.
    private func frame(_ id: Tab.ID) -> CGRect? {
        guard let frame = browser?.keySky.place(id), frame.width > 0 else { return nil }
        return frame.insetBy(dx: -1, dy: -1)
    }

    /// Where the pointer is in the window, counted from its top left as
    /// the tabs' shapes are.
    private func pointer() -> CGPoint? {
        if let pointerLocation { return pointerLocation() }
        guard let window = home else { return nil }
        return spot(window.convertPoint(fromScreen: NSEvent.mouseLocation), in: window)
    }

    /// The pointer is on the space's tray over the tabs (`underTray`).
    private var covered: Bool {
        guard let window = home else { return false }
        return ActionMenu.isOpen(in: window) || underTray(window.convertPoint(fromScreen: NSEvent.mouseLocation), in: window)
    }

    /// The space's tray (New Space, Change Emoji… with its Emoji and Icon)
    /// is laid over the column in its window, a view and not a window of
    /// its own, and the rows under its panel heard the pointer through it:
    /// each lit and brought its card while an emoji was being picked
    /// (feedback #182). `point` is in the window's own space.
    private func underTray(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard let tray = SpaceTray.shown, tray.window === window else { return false }
        return tray.convert(tray.panelFrame, to: nil).contains(point)
    }

    /// The window these tabs are in: the one in front until it is known.
    private var home: NSWindow? { browser?.keySky.groundView?.window ?? Links.window }

    /// A point of the window's own in the space the tabs' shapes are in
    /// (KeySky.spot), or from the content's top left until that is known.
    private func spot(_ point: NSPoint, in window: NSWindow) -> CGPoint? {
        if let spot = browser?.keySky.spot(point, in: window) { return spot }
        guard let content = window.contentView else { return nil }
        return CGPoint(x: point.x, y: content.bounds.height - point.y)
    }

    private func show(_ id: Tab.ID, agent: Bool) {
        pinRequest = nil
        // Hung from where the row is now: the put-away column out over the
        // page may not have said so since it came out, and the card hung
        // from past the window's edge, over the rows (0.0.23).
        if let browser { ColumnPages.of(browser)?.moved() }
        if shownFolder != nil { shownFolder = nil; closePreview() }
        if self.agent != agent { self.agent = agent }
        if shown != id {
            // The next card says for itself whether it has a button.
            if holds { holds = false }
            inside = false
            shown = id
        }
    }

    /// The tab's card up has a button, or no longer has one.
    func hold(_ has: Bool) {
        let has = has && !agent
        guard holds != has else { return }
        holds = has
        if !has { inside = false }
    }

    /// The card's button pressed: what it says, done, and the card away.
    func act(_ action: TabGist.Action, on tab: Tab) {
        guard let browser else { return }
        drop()
        switch action.kind {
        case .open(let url):
            browser.select(tab)
            tab.go(to: url)
        case .play: tab.tuneWatch.want(playing: true)
        case .pause: tab.tuneWatch.want(playing: false)
        case .sleep: browser.sleep([tab], byHand: true)
        case .reload: browser.reload(tab)
        case .connectCalendar:
            // Where Google is connected, as the welcome's chapter does; with
            // mail off, the Mac's own question, asked because Connect was pressed.
            if SettingsPage.mail.available {
                SettingsWindow.shared.show(.mail, for: browser)
            } else {
                Task { _ = await Meetings.shared.ask() }
            }
        }
    }

    private func later(_ delay: TimeInterval, into slot: inout DispatchWorkItem?, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        slot = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The top of the page, the width of the card, as it is on screen now.
    ///
    /// WebKit paints it in the page's own process; asking costs the main
    /// thread a few hundredths of a millisecond and the picture comes back
    /// some ten milliseconds later. Cutting it to the card is done once,
    /// here, off the main thread, not by a mask every time the card is drawn.
    private func keep(_ tab: Tab) {
        guard !tab.isBlank, let web = tab.builtPage, let window = web.window, web.bounds.width > 0 else { return }
        let width = web.bounds.width
        let shot = PageShot(rect: CGRect(x: 0, y: 0, width: width, height: min(web.bounds.height, width * Self.still / Self.width)), width: Self.width, afterUpdates: false)
        let id = tab.id
        let scale = window.backingScaleFactor
        let address = tab.address
        let revision = tab.engineNavigationRevision
        web.snapshot(shot) { [weak self, weak tab, weak web] image, _ in
            guard let tab, let web, !tab.gone, tab.builtPage === web, tab.address == address,
                  tab.engineNavigationRevision == revision, self != nil, let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            Self.studio.async {
                guard let cut = Self.cut(picture, scale: scale) else { return }
                DispatchQueue.main.async { [weak self, weak tab, weak web] in
                    guard let self, let tab, let web, !tab.gone, tab.builtPage === web, tab.address == address,
                          tab.engineNavigationRevision == revision else { return }
                    self.stills[id] = NSImage(cgImage: cut, size: NSSize(width: Self.width, height: Self.still))
                    self.order.removeAll { $0 == id }
                    self.order.append(id)
                    while self.order.count > Self.kept { self.stills[self.order.removeFirst()] = nil }
                }
            }
        }
    }

    /// Only a picture history already kept, cut by the tab card's own
    /// drawing code. This path never asks WebKit or a site for a picture.
    static func storedStill(_ url: URL) async -> NSImage? {
        let key = Diary.key(url)
        return await withCheckedContinuation { continuation in
            studio.async {
                let source = [Diary.shot(key), Diary.og(key)].lazy.compactMap { NSImage(contentsOf: $0) }.first
                let picture = source?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let cut = picture.flatMap { Self.cut($0, scale: 2) }
                let image = cut.map { NSImage(cgImage: $0, size: NSSize(width: width, height: still)) }
                continuation.resume(returning: image)
            }
        }
    }

    /// The picture at the card's size in pixels, filling it from the top,
    /// its top corners the card's.
    private nonisolated static func cut(_ picture: CGImage, scale: CGFloat) -> CGImage? {
        let w = Int((width * scale).rounded()), h = Int((still * scale).rounded())
        guard let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        let r = corner * scale
        // Core Graphics counts up from the bottom: the rounded corners are
        // the top two, at the far end of y.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: box.maxX, y: 0))
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX - r, y: box.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: 0, y: box.maxY), tangent2End: CGPoint(x: 0, y: box.maxY - r), radius: r)
        path.closeSubpath()
        context.addPath(path)
        context.clip()
        let fill = max(CGFloat(w) / CGFloat(picture.width), CGFloat(h) / CGFloat(picture.height))
        let drawn = CGSize(width: CGFloat(picture.width) * fill, height: CGFloat(picture.height) * fill)
        context.draw(picture, in: CGRect(x: (CGFloat(w) - drawn.width) / 2, y: CGFloat(h) - drawn.height, width: drawn.width, height: drawn.height))
        return context.makeImage()
    }
}

@MainActor
extension Browser {
    var glance: TabGlance { TabGlance.of(self) }
}

// MARK: - the card

/// Over the whole window, under the panels: the card hanging from the tab
/// the pointer rests on.
struct GlanceLayer: View {
    /// Read, not watched: the layer is drawn again only when a card comes,
    /// goes or moves to another tab, not with everything else the browser
    /// publishes. A tab closing under its card puts the card away (see
    /// `TabGlance`), and the card watches its own tab's title.
    let browser: Browser
    @ObservedObject var glance: TabGlance
    /// Watched: every window's folders tell the first window's; this
    /// window's are read.
    @ObservedObject private var watched = Folders.shared
    private var folders: Folders { browser.folderBook }

    @State private var height: CGFloat = 0
    @State private var folderHeight: CGFloat = 0
    /// The agent's card, as big as its words make it.
    @State private var pill = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.size
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if let id = glance.shown,
                   browser.editingTab != id,
                   let tab = browser.tabs.first(where: { $0.id == id }),
                   let frame = browser.keySky.place(id), frame.width > 0 {
                    let local = frame.offsetBy(dx: -origin.x, dy: -origin.y)
                    if glance.agent {
                        // Asking for you, the agent already has a card
                        // hanging from the tab, the one that asks.
                        if tab.worker != nil, tab.handoff == nil {
                            let spot = beside(local, in: window)
                            AgentGlance(tab: tab)
                                .onGeometryChange(for: CGSize.self) { $0.size } action: { pill = $0 }
                                .padding(.leading, spot.x)
                                .padding(.top, spot.y)
                                .allowsHitTesting(false)
                        }
                    } else {
                        let spot = place(local, in: window)
                        GlanceCard(tab: tab, still: tab.id == browser.activeID ? nil : glance.stills[id],
                                   act: { [weak glance] in glance?.act($0, on: tab) },
                                   holding: { [weak glance] in glance?.hold($0) })
                            .id(id)
                            // Where it is, as a preview's is: the pointer on
                            // it holds it while it has a button.
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box in
                                height = box.height
                                glance.previewFrame = box
                            }
                            .padding(.leading, spot.x)
                            .padding(.top, spot.y)
                            .allowsHitTesting(glance.holds)
                    }
                } else if let id = glance.shownFolder,
                          let chip = glance.bookmarkChips[id], let frame = glance.folderFrames[id] {
                    let local = frame.offsetBy(dx: -origin.x, dy: -origin.y)
                    let spot = CGPoint(x: min(max(8, local.minX), max(8, window.width - TabGlance.width - 8)), y: local.maxY + 6)
                    Group {
                        if chip.node.isFolder || chip.stacked {
                            FolderGlanceCard(title: chip.title, bookmarks: chip.contents)
                        } else {
                            BookmarkGlanceCard(browser: browser, glance: glance, node: chip.node)
                        }
                    }
                    .id(id)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { glance.previewFrame = $0 }
                    .padding(.leading, spot.x)
                    .padding(.top, spot.y)
                    .allowsHitTesting(glance.holds)
                } else if let id = glance.shownFolder,
                          let frame = glance.folderFrames[id], frame.width > 0,
                          let folder = folderContents(id) {
                    let local = frame.offsetBy(dx: -origin.x, dy: -origin.y)
                    if glance.searching, TabGlance.isPin(id) {
                        let halves = glance.pinTab.map { browser.pinMate(of: $0) != nil } ?? false
                        let spot = preview(local, in: window, height: halves ? nil : PinPreview.height(glance.pinItems.count))
                        PinPreview(browser: browser, glance: glance, heading: folder.title,
                                   halves: halves)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box in
                                folderHeight = box.height
                                glance.previewFrame = box
                            }
                            .padding(.leading, spot.x)
                            .padding(.top, spot.y)
                    } else if glance.searching {
                        let spot = preview(local, in: window)
                        FolderPreview(browser: browser, glance: glance, id: id, title: folder.title)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box in
                                folderHeight = box.height
                                glance.previewFrame = box
                            }
                            .padding(.leading, spot.x)
                            .padding(.top, spot.y)
                    } else {
                        let spot = place(local, in: window, cardHeight: folderHeight)
                        FolderGlanceCard(title: folder.title, tabs: folder.tabs)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { folderHeight = $0 }
                            .padding(.leading, spot.x)
                            .padding(.top, spot.y)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: window.width, height: window.height, alignment: .topLeading)
        }
        // Nothing here takes the pointer but a folder's preview.
        .allowsHitTesting(glance.taking)
    }

    private var side: Bool { browser.prefs.sidebar }
    /// The column on the right: what opens beside a row opens to its left,
    /// over the page all the same.
    private var onRight: Bool { browser.flank == .right }

    private func folderContents(_ id: String) -> (title: String, tabs: [Tab])? {
        if TabGlance.isPin(id) {
            guard let tab = glance.pinTab else { return nil }
            return (PinList.heading(tab, in: browser), [])
        }
        if let folder = folders.folder(id) {
            let members = Set(folder.members)
            return (folder.nest?.name ?? Folders.title(id), browser.tabs.filter { members.contains($0.id) })
        }
        if let nest = folders.empties.first(where: { $0.key == id }) { return (nest.name, []) }
        return nil
    }

    /// Under the tab, lined up with its left edge, with the tabs along the
    /// top; beside it, level with it, with them down the side; inside the
    /// window either way.
    private func place(_ tab: CGRect, in window: CGSize, cardHeight: CGFloat? = nil) -> CGPoint {
        let margin: CGFloat = 8
        if side {
            let y = min(max(margin, tab.minY - 4), window.height - (cardHeight ?? height) - margin)
            // Clear of the column's edge and into the page, not on the line
            // between them.
            return CGPoint(x: onRight ? tab.minX - 16 - TabGlance.width : tab.maxX + 16, y: y)
        }
        let x = min(max(margin, tab.minX), window.width - TabGlance.width - margin)
        return CGPoint(x: x, y: tab.maxY + 6)
    }

    /// A folder's preview: its search level with the folder, beside the
    /// column; under the folder, lined up with it, on the strip.
    private func preview(_ folder: CGRect, in window: CGSize, height: CGFloat? = nil) -> CGPoint {
        let margin: CGFloat = 8
        let width = TabGlance.folderPreviewWidth
        let folderHeight = height ?? self.folderHeight
        if side {
            let pin = glance.shownFolder.map(TabGlance.isPin) == true
            let field = FolderPreview.field / 2
            let top = pin || glance.previewFalls ? folder.midY - field : folder.midY + field - folderHeight
            let y = max(margin, min(top, window.height - folderHeight - margin))
            let x = onRight ? folder.minX - 4 - width : folder.maxX + 4
            return CGPoint(x: min(max(margin, x), window.width - width - margin), y: y)
        }
        let x = min(max(margin, folder.minX), window.width - width - margin)
        let falls = glance.shownFolder.map(TabGlance.isPin) == true || glance.previewFalls
        let top = falls ? folder.maxY + 6 : folder.minY - 6 - folderHeight
        return CGPoint(x: x, y: max(margin, min(top, window.height - folderHeight - margin)))
    }

    /// The agent's card: centered under the face with the tabs along the
    /// top, the face being at the tab's end, or the whole tab when the tab
    /// is down to it; out beside the row, level with it, down the side.
    private func beside(_ tab: CGRect, in window: CGSize) -> CGPoint {
        let margin: CGFloat = 8
        if side {
            let y = min(max(margin, tab.midY - pill.height / 2), window.height - pill.height - margin)
            return CGPoint(x: onRight ? tab.minX - 16 - pill.width : tab.maxX + 16, y: y)
        }
        // The face's middle: the slot's inset from the tab's end and half its 15.
        let face = tab.width < Metrics.tabTitled ? tab.midX : tab.maxX - TabEnd.stripEnd - TabEnd.stripSlot / 2
        let x = min(max(margin, face - pill.width / 2), window.width - pill.width - margin)
        return CGPoint(x: x, y: tab.maxY + 6)
    }
}

/// The kept page's signals, from tabs and live folders already in memory.
@MainActor
enum BookmarkGlance {
    @MainActor struct Open {
        let browser: Browser
        let tab: Tab?
        let space: UUID
        let count: Int
        let url: URL

        var text: String {
            let name = space == Space.mailID ? Space.mail.name : browser.spaces.first { $0.id == space }?.name ?? browser.space.name
            return "Open in " + name + (count > 1 ? " · \(count) tabs" : "")
        }

        func go() {
            if browser.spaceID != space { browser.switchSpace(to: space) }
            guard browser.spaceID == space,
                  let target = browser.tabs.first(where: { tab != nil ? $0.id == tab?.id : ($0.pending ?? $0.address).map(Diary.key) == Diary.key(url) }) else { return }
            browser.select(target)
            BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
        }
    }

    struct Stored {
        let browser: Browser
        let space: UUID
        let url: URL
    }

    private static func owners(_ browser: Browser) -> [Browser] {
        let others = browser.privateBrowsing ? [] : BrowserWindows.shared.browsers.filter { $0 !== browser && !$0.privateBrowsing }
        return [browser] + others
    }

    /// Rows not yet visited this launch have no Tab objects. Read their
    /// saved addresses once per hover, without loading a row or a page.
    static func stored(in browser: Browser) -> [Stored] {
        guard !browser.privateBrowsing else { return [] }
        return owners(browser).flatMap { owner in
            guard owner.prefs.usesSpaces else { return [Stored]() }
            return owner.spaces.filter { $0.id != owner.spaceID && owner.parked[$0.id] == nil }.flatMap { space in
                owner.pages(in: space.id).map { Stored(browser: owner, space: space.id, url: $0.url) }
            }
        }
    }

    static func opened(_ node: Bookmark, in browser: Browser, stored: [Stored] = []) -> Open? {
        guard let url = node.url.flatMap(URL.init(string:)) else { return nil }
        let key = Diary.key(url)
        var matches: [(Browser, Tab?, UUID)] = []
        var seen = Set<Tab.ID>()
        for owner in owners(browser) {
            for tab in owner.everyTab where tab.shy == browser.privateBrowsing {
                guard let address = tab.pending ?? tab.address, Diary.key(address) == key, seen.insert(tab.id).inserted else { continue }
                let space = owner.tabs.contains { $0 === tab } ? owner.spaceID : owner.spaceHolding(tab.id) ?? owner.spaceID
                guard space == owner.spaceID || owner.prefs.usesSpaces || space == Space.mailID && owner.prefs.usesMail else { continue }
                matches.append((owner, tab, space))
            }
        }
        for entry in stored where entry.browser.spaceID != entry.space && entry.browser.parked[entry.space] == nil && Diary.key(entry.url) == key {
            matches.append((entry.browser, nil, entry.space))
        }
        guard let first = matches.first else { return nil }
        return Open(browser: first.0, tab: first.1, space: first.2, count: matches.count, url: url)
    }

    static func gist(_ node: Bookmark, open: Open?, at now: Date) -> TabGist {
        let url = node.url.flatMap(URL.init(string:))
        var signals = TabGist.Signals(address: url, label: BookmarkBar.label(node))
        signals.item = LiveSeen.item(LiveText.thing(url))
        signals.words = signals.item?.words
        signals.now = now
        var gist = open?.tab.map { TabGist.of($0, at: now) } ?? TabGist.make(signals)
        if gist.title == nil {
            if let tab = open?.tab {
                gist.title = MarkdownLink.title(LiveGitHub.shortTitle(tab.label), host: tab.address?.host() ?? "")
            } else {
                gist.title = signals.item?.title ?? BookmarkBar.titleParts(node).title
            }
        }
        if let open, let url {
            gist.now = TabGist.Now(word: nil, text: open.text, tone: .going)
            gist.action = TabGist.Action(label: "Go to Tab", kind: .open(url))
        }
        return gist
    }

    static func site(_ url: URL, path: Bool = true) -> String {
        guard let host = url.host(), !host.isEmpty else { return Address.shown(url) }
        let name = IDN.shown(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        return name + (path && url.path != "/" ? url.path : "")
    }
}

private struct BookmarkGlanceCard: View {
    let browser: Browser
    let glance: TabGlance
    let node: Bookmark
    @State private var still: NSImage?
    @State private var stored: [BookmarkGlance.Stored] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let open = BookmarkGlance.opened(node, in: browser, stored: stored)
            let gist = BookmarkGlance.gist(node, open: open, at: context.date)
            GlanceBody(gist: gist, title: BookmarkBar.titleParts(node).title,
                       icon: node.savedIcon,
                       letter: String(BookmarkBar.label(node).prefix(1)).uppercased(),
                       site: node.url.flatMap(URL.init(string:)).map { BookmarkGlance.site($0) },
                       still: still,
                       act: { action in
                           glance.drop()
                           if let open { open.go() }
                           else if case .open(let url) = action.kind { browser.visit(url) }
                       }, holding: { glance.hold($0) }) { EmptyView() }
        }
        .task(id: node.url) {
            still = nil
            stored = BookmarkGlance.stored(in: browser)
            guard !browser.privateBrowsing, let url = node.url.flatMap(URL.init(string:)),
                  BookmarkGlance.opened(node, in: browser, stored: stored) == nil else { return }
            let picture = await TabGlance.storedStill(url)
            if !Task.isCancelled { still = picture }
        }
    }
}

private struct GlanceCard: View {
    @ObservedObject var tab: Tab
    let still: NSImage?
    let act: (TabGist.Action) -> Void
    let holding: (Bool) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GlanceBody(gist: TabGist.of(tab, at: context.date), title: tab.label,
                       icon: tab.icon, letter: tab.monogram, site: tab.address.map { BookmarkGlance.site($0, path: false) },
                       still: still, act: act, holding: holding) {
                if let page = tab.peek { PeekLine(page: page) }
                if tab.worker != nil { AgentLine(tab: tab) }
            }
        }
    }
}

/// The one card drawing, for tabs and kept pages alike.
private struct GlanceBody<Extra: View>: View {
    let gist: TabGist
    let title: String
    let icon: NSImage?
    let letter: String
    let site: String?
    let still: NSImage?
    let act: (TabGist.Action) -> Void
    let holding: (Bool) -> Void
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TabGlance.corner, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            // The page's picture only when the card has nothing to say of
            // it: a pull request's picture says less than its line does.
            if let still, gist.now == nil, gist.facts == nil {
                // Already this size in pixels, its top corners already the
                // card's: drawn as it is.
                Image(nsImage: still)
                    .frame(width: TabGlance.width, height: TabGlance.still)
                    .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(gist.title ?? title)
                    .sidebarFont(size: 13)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                facts(gist)
            }
            .padding(.horizontal, TabGlance.inset)
            .padding(.top, TabGlance.inset)
            .padding(.bottom, gist.now == nil ? TabGlance.inset : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let now = gist.now {
                NowLine(now: now, action: gist.action, act: act)
            }
            extra()
        }
        .frame(width: TabGlance.width)
        // No clip over the whole card, which would be a mask every frame it
        // moves, and a shadow from a path rather than worked out from what
        // is drawn, which would be another.
        .background {
            ZStack {
                CardShadow()
                shape.fill(Palette.ground)
            }
        }
        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
        .onAppear { holding(gist.action != nil) }
        .onChange(of: gist.action != nil) { _, has in holding(has) }
    }

    @ViewBuilder
    private func facts(_ gist: TabGist) -> some View {
        if let facts = gist.facts {
            HStack(spacing: 6) {
                if let person = gist.person {
                    Initial(name: person)
                } else {
                    Mark(icon: icon, letter: letter, size: 12)
                }
                Text(facts)
                    .sidebarFont(size: 11.5)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        } else if let site {
            HStack(spacing: 6) {
                Mark(icon: icon, letter: letter, size: 12)
                Text(site)
                    .sidebarFont(size: 11.5)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
    }
}

/// The card's line of what is going on now, one line whatever its length,
/// with its button at its end: the card's inset from the left, the
/// button's from the right and the foot, so the button's corner runs on
/// the card's (TabGlance.corner).
private struct NowLine: View {
    let now: TabGist.Now
    let action: TabGist.Action?
    let act: (TabGist.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            (Text(now.word.map { $0 + " " } ?? "").fontWeight(.semibold) + Text(now.text))
                .sidebarFont(size: 11.5)
                .foregroundStyle(now.tone == .going ? Palette.muted : Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.label) { act(action) }
                    .buttonStyle(.yab(now.tone == .going ? .secondary : .primary, .small))
            }
        }
        // As tall as the button beside it, so the words sit on its middle;
        // alone, the words' own height, so they end the card's inset above
        // its foot as they start its inset in from its side.
        .frame(minHeight: action == nil ? nil : ButtonSize.small.height)
        .padding(.leading, TabGlance.inset)
        .padding(.trailing, action == nil ? TabGlance.inset : TabGlance.buttonInset) // design: the button 6 in from the corner, its 8 on the card's 14; the words at the card's 12
        .padding(.top, 6)
        .padding(.bottom, action == nil ? TabGlance.inset : TabGlance.buttonInset)
    }
}

/// A person on a card, by the first letter of their name, on a color their
/// name always gets.
private struct Initial: View {
    let name: String

    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 12 * 0.56, weight: .medium)) // design: a letter in a 12 pt mark, as Mark draws a site's
            .foregroundStyle(.white)
            .frame(width: 12, height: 12)
            .background(Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.62)))
    }
}

/// A folder mark alone cannot say what is inside it at the strip's narrowest.
/// The same quiet card as a tab's gives its name and the first few pages.
private struct FolderGlanceCard: View {
    let title: String
    struct Line: Identifiable {
        let id: String
        let title: String
        let icon: NSImage?
        let letter: String
        var folder = false
        var detail: String? = nil
    }
    let detail: String
    let lines: [Line]
    let limit: Int

    init(title: String, tabs: [Tab]) {
        self.title = title
        detail = "\(tabs.count) \(tabs.count == 1 ? "tab" : "tabs")"
        lines = tabs.map { Line(id: $0.id.uuidString, title: $0.label, icon: $0.icon, letter: $0.monogram) }
        limit = 6
    }

    init(title: String, bookmarks: [Bookmark]) {
        self.title = title
        let pages = bookmarks.filter { !$0.isFolder }.count
        let folders = bookmarks.filter(\.isFolder).count
        detail = "\(pages) \(pages == 1 ? "bookmark" : "bookmarks") · \(folders) \(folders == 1 ? "folder" : "folders")"
        lines = bookmarks.map { node in
            let parts = BookmarkBar.titleParts(node)
            return Line(id: node.id.uuidString, title: parts.title, icon: node.savedIcon,
                        letter: String(BookmarkBar.label(node).prefix(1)).uppercased(), folder: node.isFolder,
                        detail: node.isFolder ? String(Bookmarks.count(node.children ?? [])) : parts.tail)
        }
        limit = 3
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TabGlance.corner, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .sidebarFont(size: 13, weight: .medium)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(detail)
                    .sidebarFont(size: 11.5)
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if !lines.isEmpty {
                Palette.hairline.frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.prefix(limit))) { line in
                        HStack(spacing: 8) {
                            Group {
                                if line.folder {
                                    BookmarkBar.FolderMark().foregroundStyle(Palette.muted)
                                } else {
                                    Mark(icon: line.icon, letter: line.letter, size: 12)
                                }
                            }
                            .frame(width: 12, height: 12)
                            Text(line.title)
                                .sidebarFont(size: 11.5)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            if let detail = line.detail {
                                Text(detail).sidebarFont(size: 11.5).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                        }
                    }
                    if lines.count > limit {
                        Text("\(lines.count - limit) more")
                            .sidebarFont(size: 11.5)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: TabGlance.width, alignment: .leading)
        .background {
            ZStack {
                CardShadow()
                shape.fill(Palette.ground) // design: matches the existing tab glance surface and its cached shadow
            }
        }
        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1)) // design: matches the existing tab glance border
    }
}

/// A shut folder's tabs to search and go to, as Arc's folder preview has
/// them: the Actions panel's rows, with search nearest the opening point,
/// when you last looked at it, or, in a task's folder, whether it needs
/// you. Its native search takes the keyboard while the preview is up.
struct FolderPreview: View {
    let browser: Browser
    @ObservedObject var glance: TabGlance
    let id: String
    let title: String
    @ObservedObject private var live = LiveFolders.shared
    @Environment(\.colorScheme) private var scheme

    static let field: CGFloat = 48
    static let visibleRows = 7
    /// From the panel's edge to the rows, whose lit plate's corner runs on
    /// the panel's; the foot's button stands as far in, all round.
    static let margin = FieldActionsPanel.corner - Radius.surface
    /// From a row's plate to its mark.
    static let rowInset: CGFloat = 8
    /// Above and below the rows: the margin, as at their sides, so a lit
    /// first or last row runs on the panel's curve.
    static let rowsAir = margin
    /// The foot: a small button with the margin above and below it.
    static let foot = ButtonSize.small.height + 2 * margin
    /// The foot's button in the panel's corner, on its curve.
    static let footCorner = FieldActionsPanel.corner - margin

    static func height(_ count: Int, foot: Bool) -> CGFloat {
        CGFloat(min(max(1, count), visibleRows)) * FieldActionsPanel.row + field + 1 + 2 * rowsAir + (foot ? 1 + Self.foot : 0)
    }

    var body: some View {
        let found = glance.items(id)
        let words = glance.query
        let inside = glance.at.flatMap { browser.folderBook.folder($0)?.nest }
        let appearance = LookMode(rawValue: browser.prefs.lookMode)?.scheme ?? scheme
        VStack(alignment: .leading, spacing: 0) {
            if glance.previewFalls {
                search(inside: inside, scheme: appearance)
                seam
            }
            VStack(spacing: 0) {
                if found.isEmpty {
                    Self.empty("No tabs in \(inside?.name ?? title) match “\(words.trimmingCharacters(in: .whitespaces))”")
                } else if found.count > Self.visibleRows {
                    ScrollViewReader { scroller in
                        ThreadScrollView(.vertical) { previewRows(found, inside: inside) }
                            .scrollBounceBehavior(.basedOnSize)
                            .scrollIndicators(.never)
                            .frame(height: CGFloat(Self.visibleRows) * FieldActionsPanel.row)
                            .onChange(of: glance.lit) { _, row in scroller.scrollTo(row) }
                    }
                } else {
                    previewRows(found, inside: inside)
                }
            }
            .padding(.vertical, Self.rowsAir)
            if let nest = browser.folderBook.folder(id)?.nest, let foot = LiveFolders.foot(nest) {
                seam
                footLine(foot, nest)
            }
            if !glance.previewFalls {
                seam
                search(inside: inside, scheme: appearance)
            }
        }
        .modifier(PreviewPanel(scheme: appearance))
    }

    /// Between the header, the rows and the foot: Actions' seam.
    static var seam: some View {
        Rectangle().fill(Omnibox.seam).frame(height: 1)
    }
    private var seam: some View { Self.seam }

    /// Where the rows would be when there are none: what's missing, in a
    /// row's place, its words where the marks start.
    static func empty(_ words: String) -> some View {
        Text(words)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, margin + rowInset)
            .frame(height: FieldActionsPanel.row)
    }

    /// The search, after the way back out once the preview has gone down
    /// into a folder of the one shown: the folders it went through, then
    /// the one shown, in ink. At the top it is the search alone.
    private func search(inside: Nest?, scheme: ColorScheme) -> some View {
        let path = crumbs(inside: inside)
        // The first crumb's plate as far in from the panel's edge as from
        // the header's top and bottom, its words where the rows' marks are.
        let side = Self.margin + Self.rowInset - FolderCrumb.pad
        // Half the header at most, so the search keeps its words.
        let room = (TabGlance.folderPreviewWidth - 2 * side) / 2
        let shown = FolderCrumb.fit(path, in: room)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.crumb.id) { index, item in
                    if index > 0 {
                        Symbol("chevron.right", size: 9, weight: .semibold, side: FolderCrumb.chevron)
                            .foregroundStyle(Palette.faint)
                    }
                    FolderCrumb(crumb: item.crumb) { glance.back(to: item.crumb.key) }
                        .frame(width: item.width)
                }
            }
            .fixedSize()
            FolderPreviewSearch(glance: glance, placeholder: "Search \(inside?.name ?? title)", scheme: scheme)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                // The current crumb's pad and a row's inset: 12 after its words.
                // Alone, its words where the rows' marks are.
                .padding(.leading, shown.isEmpty ? FolderCrumb.pad : Self.rowInset)
        }
        .padding(.horizontal, side)
        .frame(height: Self.field)
    }

    private func crumbs(inside: Nest?) -> [FolderCrumb.Model] {
        var names: [(name: String, key: String?, goes: Bool)] = []
        let root = browser.folderBook.folder(id)?.nest
        if let inside, let root, inside !== root {
            names.append((title, id, true))
            let chain = inside.chain
            if let top = chain.firstIndex(where: { $0 === root }), top + 1 < chain.count - 1 {
                for nest in chain[(top + 1)..<(chain.count - 1)] { names.append((nest.name, nest.key, true)) }
            }
            names.append((inside.name, nil, false))
        }
        return names.enumerated().map { index, item in
            FolderCrumb.Model(id: index, name: item.name, key: item.key, goes: item.goes, current: index == names.count - 1)
        }
    }

    private func previewRows(_ found: [TabGlance.PreviewItem], inside: Nest?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(found.enumerated()), id: \.element.id) { index, item in
                Group {
                    switch item {
                    case .tab(let tab):
                        PreviewRow(tab: tab, detail: detail(tab, under: inside ?? browser.folderBook.folder(id)?.nest), lit: index == glance.lit)
                            .onTapGesture { glance.pick(tab) }
                    case .folder(let nest, let count):
                        PreviewFolderRow(nest: nest, count: count, lit: index == glance.lit)
                            .onTapGesture { glance.enter(nest) }
                    }
                }
                .id(index)
                .contentShape(Rectangle())
                .onHover { if $0, glance.lit != index { glance.lit = index } }
            }
        }
        .padding(.horizontal, Self.margin)
    }

    private func footLine(_ foot: LiveFolders.Foot, _ nest: Nest) -> some View {
        HStack(spacing: 6) {
            switch foot {
            case .reading(let name):
                ProgressView().controlSize(.mini)
                Text("Reading \(name)…").foregroundStyle(Palette.muted)
            case .late(let minutes):
                Text("Last read \(minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h") ago").foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Button("Refresh") { LiveFolders.shared.read(nest, in: browser) }
                    .buttonStyle(.yab(.secondary, .small, cornerRadius: Self.footCorner))
                    .focusable(false)
            case .signedOut(let name, let page):
                Text("Signed out of \(name)").foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                if let page {
                    Button("Sign In") { glance.drop(); browser.arrive(page) }
                        .buttonStyle(.yab(.secondary, .small, cornerRadius: Self.footCorner))
                        .focusable(false)
                }
            }
        }
        .sidebarFont(size: 11)
        .lineLimit(1)
        // Words where the rows' marks start (the margin, then a row's
        // inset); the button the margin in from the panel's edge, top,
        // bottom and side alike.
        .padding(.leading, Self.rowInset)
        .padding(.horizontal, Self.margin)
        .frame(height: Self.foot)
    }

    /// When you last looked at it; in a task's folder, a tab asking for
    /// you says so instead, and in a live folder, what the tab needs.
    /// Found by words in a folder deeper than the one shown, the folders
    /// it is in below that one.
    private func detail(_ tab: Tab, under shown: Nest? = nil) -> String {
        if tab.handoff != nil { return "Needs you" }
        if let words = tab.live?.words { return words.text }
        if !glance.query.isEmpty, let shown, let inner = tab.nest, inner !== shown, inner.within(shown) {
            return inner.chain.drop { $0 !== shown }.dropFirst().map(\.name).joined(separator: " › ")
        }
        if tab.id == browser.activeID { return "Now" }
        return PanelTime.short(tab.touched)
    }
}

/// One step of the way down to the folder a preview shows. One the
/// preview went down through is pressed to go back out to it, a quiet
/// plate under the pointer; the folder shown, in ink, and the ones above
/// the preview's own, are only said. Cut short, its name comes on a tip.
private struct FolderCrumb: View {
    struct Model: Identifiable {
        let id: Int
        let name: String
        /// Where it goes back to: the preview's own folder's key, or one in it.
        let key: String?
        let goes: Bool
        let current: Bool
        /// Said on its tip whatever its width: the folded ones' names.
        var tip: String? = nil
    }

    let crumb: Model
    let go: () -> Void
    @State private var hovered = false
    @State private var cut = false

    /// Between a crumb's plate and its words: what puts the first plate
    /// 12 in from the panel's edge, as from the header's top and bottom
    /// (FolderPreview.field less the plate, halved), with its words at
    /// the rows' marks.
    static let pad: CGFloat = 4
    static let words: CGFloat = 12.5
    /// The chevron between two crumbs, as a submenu's line has it.
    static let chevron: CGFloat = 12
    /// Narrowest a crumb gives way to: a letter or two and the ellipsis.
    static let least: CGFloat = 44

    /// The crumbs to show and each one's width, plate and all, in `room`
    /// with the chevrons between them: whole when they fit; else the
    /// middle ones give way first, evenly, then fold into one "…" that
    /// goes back to the nearest of them and names them all on its tip;
    /// then the folder shown, whose name the search beside it says too,
    /// and the first last of all.
    static func fit(_ path: [Model], in room: CGFloat) -> [(crumb: Model, width: CGFloat)] {
        let font = NSFont.systemFont(ofSize: words)
        func natural(_ name: String) -> CGFloat {
            ceil((name as NSString).size(withAttributes: [.font: font]).width) + 2 * pad
        }
        var shown = path.map { (crumb: $0, width: natural($0.name)) }
        func over() -> CGFloat {
            shown.reduce(0) { $0 + $1.width } + CGFloat(max(0, shown.count - 1)) * chevron - room
        }
        guard over() > 0 else { return shown }
        let middle = Array(shown.indices.dropFirst().dropLast())
        if !middle.isEmpty {
            let ends = shown[0].width + shown[shown.count - 1].width
            let free = room - CGFloat(shown.count - 1) * chevron - ends
            let share = free / CGFloat(middle.count)
            if share >= least {
                for i in middle { shown[i].width = min(shown[i].width, share) }
            } else {
                let hidden = middle.map { shown[$0].crumb }
                let near = hidden.last { $0.goes }
                let fold = Model(id: -1, name: "\u{2026}", key: near?.key, goes: near != nil, current: false,
                                 tip: hidden.map(\.name).joined(separator: " \u{203A} "))
                shown = [shown[0], (crumb: fold, width: natural(fold.name)), shown[shown.count - 1]]
            }
        }
        for i in [shown.count - 1, 0] where over() > 0 {
            shown[i].width = max(least, shown[i].width - over())
        }
        return shown
    }

    var body: some View {
        Text(crumb.name)
            .font(.system(size: Self.words))
            .foregroundStyle(crumb.current ? Palette.ink : Palette.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let whole = (crumb.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Self.words)]).width
                let now = width + 0.5 < ceil(whole)
                if cut != now { cut = now }
            }
            .padding(.horizontal, Self.pad)
            .frame(height: ButtonSize.small.height)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(crumb.goes && hovered ? Omnibox.tileFill : .clear)
            )
            .contentShape(Rectangle())
            .onHover { on in if crumb.goes, hovered != on { hovered = on } }
            .onTapGesture { if crumb.goes { go() } }
            .pointerTip(crumb.tip ?? (cut ? crumb.name : ""))
            .accessibilityAddTraits(crumb.goes ? .isButton : [])
            .accessibilityLabel(crumb.goes ? "Back to \(crumb.tip ?? crumb.name)" : crumb.name)
    }
}

/// A bare native search, as in Actions. Wait for attachment and a key
/// window before taking focus; a single async attempt can run too early.
struct FolderPreviewSearch: NSViewRepresentable {
    @ObservedObject var glance: TabGlance
    let placeholder: String
    let scheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator(glance) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.glance = glance
        field.identifier = NSUserInterfaceItemIdentifier("folder-preview-search")
        field.setAccessibilityLabel("Search folder")
        field.isAutomaticTextCompletionEnabled = false
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.textColor = NSColor(Palette.ink)
        field.placeholderString = placeholder
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        if field.stringValue != glance.query { field.stringValue = glance.query }
        field.placeholderString = placeholder
        field.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        field.textColor = Palette.NS.ink
        field.currentEditor()?.textColor = Palette.NS.ink
    }

    final class Field: NSSearchField {
        weak var glance: TabGlance?
        private var keyWatch: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }
            keyWatch = nil
            guard let window else { return }
            take()
            keyWatch = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                AppKitMainThread.sync { self?.take() }
            }
        }

        private func take() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.glance?.focusSearch(self)
            }
        }

        deinit {
            if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let glance: TabGlance
        init(_ glance: TabGlance) { self.glance = glance }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { glance.search(field.stringValue) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): glance.walkPreview(-1)
            case #selector(NSResponder.moveDown(_:)): glance.walkPreview(1)
            case #selector(NSResponder.insertNewline(_:)): glance.takePreview()
            case #selector(NSResponder.cancelOperation(_:)): glance.drop()
            case #selector(NSResponder.moveLeft(_:)) where textView.string.isEmpty: glance.back()
            case #selector(NSResponder.moveRight(_:)) where textView.string.isEmpty:
                guard let id = glance.shownFolder else { return true }
                let items = glance.items(id)
                if items.indices.contains(glance.lit), case .folder(let nest, _) = items[glance.lit] { glance.enter(nest) }
            default: return false
            }
            return true
        }
    }
}

/// A folder in the one the preview shows: its mark, its name, how many tabs
/// are under it, and the chevron that says a click goes in.
private struct PreviewFolderRow: View {
    @ObservedObject var nest: Nest
    let count: Int
    let lit: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = CustomMarks.image(nest.customMark) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Face(pose: .seen, size: 14, tint: Palette.ink, folder: true, unfolded: false)
                }
            }
            .frame(width: 16, height: 16)
            Text(nest.name)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 16)
            HStack(spacing: 4) {
                Text(count == 1 ? "1 tab" : "\(count) tabs")
                    .font(.system(size: 13.5))
                Symbol("chevron.right", size: 9, weight: .semibold)
            }
            .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 8)
        .frame(height: FieldActionsPanel.row)
        .background(lit ? Omnibox.chosenFill : .clear, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
    }
}

/// The panel a folder's or a pin's preview is drawn on: Actions' (⌘K)
/// width, corner and glass, in the window's look.
struct PreviewPanel: ViewModifier {
    let scheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .frame(width: TabGlance.folderPreviewWidth, alignment: .leading)
            .modifier(ActionMenuGlass(corner: FieldActionsPanel.corner))
            .environment(\.colorScheme, scheme)
            .contentShape(RoundedRectangle(cornerRadius: FieldActionsPanel.corner, style: .continuous))
            .transaction { $0.animation = nil }
    }
}

/// A site's mark in a preview's row, rounded as the sidebar's; a dark one
/// on a white plate in the dark.
struct PreviewMark: View {
    let icon: NSImage?
    let letter: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image = icon {
                Mark(icon: image, letter: letter, size: 16)
                    .padding(scheme == .dark && ActionIcons.inky(image) ? 1.5 : 0)
                    .background {
                        if scheme == .dark, ActionIcons.inky(image) {
                            RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Color.white.opacity(0.9))
                        }
                    }
                    .frame(width: 16, height: 16)
            } else {
                Mark(icon: nil, letter: letter, size: 16)
            }
        }
        .frame(width: 16)
    }
}

/// A preview's row: a mark, the title, and at its end when, or what it
/// needs; Actions' row, its pick a veil rather than the ink.
struct PreviewLine<Lead: View>: View {
    let title: String
    let detail: String
    /// Something to do: drawn in ink.
    var strong = false
    let lit: Bool
    @ViewBuilder let mark: () -> Lead

    var body: some View {
        HStack(spacing: 12) {
            mark()
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 16)
            // Said whole: the title gives way, never the detail's letters.
            Text(detail)
                .font(.system(size: 13.5, weight: strong ? .medium : .regular))
                .foregroundStyle(strong ? Palette.ink : Palette.muted)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, FolderPreview.rowInset)
        .frame(height: FieldActionsPanel.row)
        .background(lit ? Omnibox.chosenFill : .clear, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
    }
}

/// One of a folder preview's tabs.
private struct PreviewRow: View {
    @ObservedObject var tab: Tab
    let detail: String
    let lit: Bool

    /// Something to do: a task asking, a live folder's tab that needs you.
    private var strong: Bool { detail == "Needs you" || tab.live?.words?.needsYou == true }

    var body: some View {
        PreviewLine(title: tab.label, detail: detail, strong: strong, lit: lit) {
            PreviewMark(icon: tab.icon, letter: tab.monogram)
        }
    }
}

// MARK: - the agent's

/// What an agent is doing in a tab, in the words its dock uses.
@MainActor
enum AgentWords {
    static func now(_ session: Agents.Session, in tab: Tab) -> String {
        if let ask = tab.handoff { return "Needs you · \(ask)" }
        if AgentFeed.shared.driving.contains(tab.id), session.state.live {
            return "You're driving, \(session.name) waits"
        }
        switch session.state {
        case .done: return AgentDock.result(session)
        case .failed: return "\(session.name) couldn’t finish"
        case .stopped: return "\(session.name) stopped"
        default: break
        }
        // A script is no one to have been here: only what opened the tab.
        if session.script, !session.busy { return "Opened by a script" }
        if !session.busy {
            // Came on its own and quiet for now: when it was last here, to
            // the minute. Seconds would change the words, and cross them
            // over, every second the card is up.
            guard session.touched > .distantPast else { return session.name }
            let minutes = Int(Date().timeIntervalSince(session.touched) / 60)
            if minutes < 1 { return "\(session.name), here just now" }
            if minutes < 60 { return "\(session.name), here \(minutes) min ago" }
            let ago = RelativeDateTimeFormatter()
            ago.locale = When.words
            ago.unitsStyle = .short
            ago.dateTimeStyle = .named
            return "\(session.name), here \(ago.localizedString(for: session.touched, relativeTo: Date()))"
        }
        // Busy, but its last step was in another of its tabs: that one.
        let feed = AgentFeed.shared
        let theirs = Agents.shared.liveBrowsingWindow(of: session.id)?.tabs.filter { $0.worker == session.id } ?? []
        if let latest = theirs.max(by: { (feed.last[$0.id]?.count ?? 0) < (feed.last[$1.id]?.count ?? 0) }),
           latest.id != tab.id, feed.last[latest.id] != nil {
            return "Working in \(latest.label)"
        }
        return AgentDock.say(session.now, name: session.name)
    }

    /// Who, and the task it was given, when there is one.
    static func task(_ session: Agents.Session) -> String? {
        if session.script { return nil }
        let first = session.prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? session.name : "\(session.name) · \(first)"
    }
}

/// The agent's card, hanging from its face: the dock at the foot of its
/// page, dark, its face and its step, the step's words crossing over as it
/// moves on, and under them who it is and what it was asked. Nothing to
/// press: the card never takes the pointer, and Stop is in the tab's menu.
private struct AgentGlance: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var feed = AgentFeed.shared

    var body: some View {
        if let session = agents.session(tab.worker) {
            // Once a second, for an attached agent going quiet; the words
            // themselves change at most once a minute when it has.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                card(session)
            }
        }
    }

    private func card(_ session: Agents.Session) -> some View {
        let words = AgentWords.now(session, in: tab)
        let task = AgentWords.task(session)
        return HStack(alignment: .top, spacing: 9) {
            AgentFace(tab: tab, size: 15, tint: Palette.ground, tip: false)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                ZStack(alignment: .leading) {
                    Text(words)
                        .sidebarFont(size: 12.5)
                        .foregroundStyle(Palette.ground)
                        .lineLimit(1)
                        .id(words)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity.combined(with: .offset(y: -6)).animation(.easeIn(duration: 0.1))
                        ))
                }
                if let task, !words.contains(task) {
                    Text(task)
                        .sidebarFont(size: 11.5)
                        .foregroundStyle(Palette.ground.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        // As wide as the words, up to a width that is still a glance.
        .frame(maxWidth: 270, alignment: .leading)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .fixedSize()
        .background {
            ZStack {
                CardShadow()
                RoundedRectangle(cornerRadius: TabGlance.corner, style: .continuous)
                    .fill(Palette.ink.opacity(0.94))
            }
        }
        // The width follows the words on the words' own curve, as the dock's.
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: words)
    }
}

/// Under a tab's card, what its agent is doing, for the pointer that
/// rested on the tab rather than on the face.
private struct AgentLine: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var feed = AgentFeed.shared

    var body: some View {
        if let session = agents.session(tab.worker) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                // A script's, only while it is doing something here: quiet,
                // its robot face already says a script opened the tab.
                if !session.script || session.busy {
                    HStack(spacing: 7) {
                        AgentFace(tab: tab, size: 12, tint: Palette.muted, tip: false)
                        Text(AgentWords.now(session, in: tab))
                            .sidebarFont(size: 11.5)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Palette.hairline.frame(height: 1) }
                }
            }
        }
    }
}

/// A page shift-clicked open from the tab and waiting over it (LinkPeek):
/// what it is, under the tab's own, as the mark on the tab only hints.
private struct PeekLine: View {
    @ObservedObject var page: Tab

    var body: some View {
        HStack(spacing: 6) {
            Mark(icon: page.icon, letter: page.monogram, size: 12)
            Text("In Peek · \(page.label)")
                .sidebarFont(size: 11.5)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 11) // design: in line with the card's words above, at its 11
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Palette.hairline.frame(height: 1) }
    }
}

/// The card's shadow, from a path. SwiftUI's `.shadow` gives the layer no
/// path, and Core Animation then works the shadow out from the layer's
/// drawn pixels, offscreen, every frame the card comes in or slides along.
struct CardShadow: NSViewRepresentable {
    /// The card's own corner.
    var corner: CGFloat = TabGlance.corner

    func makeNSView(context: Context) -> Plate { Plate(corner: corner) }
    func updateNSView(_ view: Plate, context: Context) {}

    final class Plate: NSView {
        /// A layer of its own: AppKit keeps a view's own layer's shadow in
        /// step with the view's `shadow`, and would wipe this one.
        private let caster = CALayer()
        private let corner: CGFloat

        init(corner: CGFloat) {
            self.corner = corner
            super.init(frame: .zero)
            wantsLayer = true
            caster.shadowColor = NSColor.black.cgColor
            caster.shadowOpacity = 0.12
            caster.shadowRadius = 16
            // Unflipped: down is negative.
            caster.shadowOffset = CGSize(width: 0, height: -6)
            layer?.addSublayer(caster)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            caster.frame = bounds
            caster.shadowPath = CGPath.rounded(bounds, corner: corner)
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
