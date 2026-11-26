import SwiftUI
import WebKit
import Combine

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.

@MainActor
@Observable
final class Browser: NSObject, ObservableObject, Relaying {
    /// Each formerly published property's new values for Combine (`changes(\.name)`), and any of
    /// them about to change (`relay.any`), as @Published told them (Observed.swift).
    @ObservationIgnored let relay = ChangeRelay<Browser>()
    /// ObservableObject's publisher, kept here. With no @Published left
    /// (the state is @Observable), Combine's own `objectWillChange` found
    /// it by walking every stored property through reflection on each
    /// read, and SwiftUI reads it for every @ObservedObject on every
    /// update: about 0.1 ms a read of a Browser or a Tab (bench
    /// willchange), many times over in every pass (feedback #120).
    nonisolated let objectWillChange = ObservableObjectPublisher()
    let pageTranslation = PageTranslation()
    @ObservationIgnored private var fieldNavigationInput: String?
    let selectionCommands = SelectionCommands()
    /// Nil for the original window, whose session files keep their old names.
    let windowID: UUID?
    /// Fixed before restoration, never inferred from whichever tab is active.
    let windowPurpose: BrowserWindowPurpose
    var privateBrowsing: Bool { windowPurpose.isPrivate(active: active?.shy) }
    /// A Blank Window, Arc's File › Blank Window (BlankWindow.swift): its
    /// tabs are its own, in no space's sidebar and in no other window, made
    /// with the sign-ins of the space it was opened from.
    let blank: Bool

    func blankTab() -> Tab {
        Tab(shy: windowPurpose == .privateOnly, configuration: windowPurpose == .privateOnly ? Web.configuration(shy: true) : Web.configuration(store: Spaces.store(for: spaceID)))
    }

    func configuration(for url: URL) -> WKWebViewConfiguration {
        if windowPurpose == .privateOnly { return Web.configuration(shy: true) }
        // An agent's published page: Yab's copy, in a view with no cookies (ArtifactPages).
        if ArtifactPages.isPage(url) { return ArtifactPages.configuration() }
        return Browser.extensionConfiguration(for: url, space: spaceID) ?? Web.configuration(store: Spaces.store(for: spaceID))
    }

    /// Where each view's load began, for a server's redirect to an
    /// extension's page (didReceiveServerRedirectForProvisionalNavigation).
    @ObservationIgnored var loadFrom: [ObjectIdentifier: URL] = [:]
    /// Pages that are tabs but not in the row yet: a link from another app
    /// in its small window (LinkWindow), until it is kept or closed. Tabs to
    /// extensions too, whose scripts run in them (Extensions.place).
    @ObservationIgnored var outside: [Tab] = [] {
        didSet {
            refreshBackSources()
            if #available(macOS 15.4, *) { Extensions.all.forEach { $0.rowChanged() } }
        }
    }
    /// A link looked at in a panel over the page (LinkPeek.swift), the tab it
    /// was looked at from, and the view it is shown in. Not published: the
    /// peek draws itself; only its navigation doors follow PeekFront.
    @ObservationIgnored var peeking: Tab? {
        didSet {
            peekFront.set(peeking)
            DispatchQueue.main.async { AgentFeed.shared.lookAround() }
        }
    }
    /// Only the navigation doors follow a peek coming and going.
    let peekFront = PeekFront()
    @ObservationIgnored var peekFrom: Tab.ID?
    /// The tab a new mail is up over, from a mailto: link clicked on its
    /// page (MailtoPeek.swift), shown in the peek's view.
    @ObservationIgnored var mailtoFrom: Tab.ID?
    /// A mail thread over the page, from a row of Now (MailThreadPeek).
    @ObservationIgnored var threadPeek: ThreadPeek?
    @ObservationIgnored weak var peekView: PeekView?
    let peekCorner = PeekCorner()
    /// What the menu bar says about the tab in front, a moment behind it
    /// (MenuFront.swift).
    let menuFront = MenuFront()
    var menuBlank: Bool { Narrow.menu ? menuFront.now.blank : (active?.isBlank ?? true) }
    var menuDev: Bool { Narrow.menu ? menuFront.now.dev : (active?.isDev ?? false) }
    var menuBack: Bool { Narrow.menu ? menuFront.now.back : active?.canGoBack == true }
    var menuForward: Bool { Narrow.menu ? menuFront.now.forward : active?.canGoForward == true }
    /// Tab › Keep Tab: some tab picked can be kept.
    var menuKeepable: Bool { Narrow.menuAddress ? menuFront.now.keepable : chosen.contains { $0.keepable } }
    /// View › Show Buttons on …: the skill for the site in front, if any.
    var menuSiteSkill: String? {
        Narrow.menuAddress ? menuFront.now.siteSkill
            : active.flatMap { $0.shy ? nil : SiteItems.shared.skill(for: $0.address) }
    }
    /// Menu, command field and remapped keys share the native URL picker.
    @discardableResult
    func sharePage() -> Bool {
        guard let url = active?.address, Bookmark.keepable(url),
              let view = BrowserWindows.shared.window(for: self)?.contentView else { return false }
        NSSharingServicePicker(items: [Diary.shareable(url)]).show(
            relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1),
            of: view, preferredEdge: .minY)
        return true
    }

    var menuShare: URL? {
        Narrow.menu ? menuFront.now.share : active?.address.flatMap { Bookmark.keepable($0) ? $0 : nil }
    }

    /// Sets of tabs in the one window (Spaces.swift): every space, the one
    /// on screen, and the rows of the others, parked as they were left.
    var spaces: [Space] = Spaces.read() {
        willSet { relay.send(\.spaces, newValue) }
    }
    /// What the field searches with: the space on screen's own engine, or
    /// Settings › Search's while it has none (Space.search).
    var searchEngine: EngineChoice { spaces.first { $0.id == spaceID }?.engine ?? .global }
    var spaceID: UUID = Space.firstID {
        willSet { relay.send(\.spaceID, newValue) }
        // Its sign-in's extensions on its buttons (ExtensionSignIns).
        didSet {
            if #available(macOS 15.4, *), spaceID != oldValue {
                DispatchQueue.main.async { ExtensionsHere.shared.refresh() }
            }
        }
    }
    /// Observed, unlike the plain values beside it: the capsule draws
    /// whether a tab of another space is playing from it (SpaceFoot).
    var parked: [UUID: Parked] = [:] {
        didSet { ChromiumTabGroups.shared.changed() }
    }
    /// Whether this window's rows are laid out with the pins shared, one
    /// row every space signed in where the others are shows
    /// (SharedPins.swift): what Settings said at launch, then each turn.
    @ObservationIgnored var pinsShared = false
    /// The space last left with the shared pins on screen, to go back to
    /// for one of them while they are put aside.
    @ObservationIgnored var sharedLeft: UUID?
    /// The last switch went between two spaces that show the shared pins:
    /// the grid stayed where it was, and doesn't come in with the rows
    /// (SpaceTurn's `holds`).
    @ObservationIgnored var pinsStayed = false
    /// A change of space writing its row: the space on screen already the
    /// new one, its tabs and folders not yet. Nothing is laid from the row
    /// meanwhile (ColumnPages.sync): laid then, the new space's page drew
    /// the old space's rows, and its own folders' tabs came in again in
    /// turn after every switch (feedback #249).
    @ObservationIgnored var rowTurning = false
    /// How much of the old space's color a switch across the top starts
    /// with over the new one: all of it for a key, what two fingers left
    /// of it for a swipe let go (SpacePull).
    @ObservationIgnored var washFrom: Float = 1
    /// Which way the last switch went, for the icon to turn over that way.
    var spaceStep = 1 {
        willSet { relay.send(\.spaceStep, newValue) }
    }

    private(set) var tabs: [Tab] = [] {
        willSet { relay.send(\.tabs, newValue) }
        didSet {
            ChromiumTabGroups.shared.changed()
            refreshBackSources()
            // An empty column asks for a page again. A kept tab arriving
            // later through sync must not inherit the old dismissal.
            if fieldPutAway, oldValue.isEmpty != tabs.isEmpty || (!tabs.isEmpty && !Browser.holdsOwn(tabs)) { fieldPutAway = false }
            tabsGrew = tabs.count >= oldValue.count
            if tabs.count > oldValue.count { WrappedLedger.shared.peak(.tabsPeak, Double(tabs.count)) }
            tabsLineChanged = Folders.showsLine(oldValue) != Folders.showsLine(tabs)
            // A picked tab that went, closed by its page, say, is simply
            // no longer picked. Written back only if one did go: every write
            // to a published value redraws the window, changed or not.
            if !gathered.isEmpty {
                let left = gathered.filter { id in tabs.contains { $0.id == id } }
                if left.count != gathered.count { gathered = left }
            }
            // Two side by side stay side by side, and go when one does.
            if !pairs.isEmpty { keepPairs(); restage() }
            if tabs.count < oldValue.count { player.restage() }
            activeFound = nil
        }
    }
    /// The automatic mail lookup is replaceable by native fixtures that
    /// exercise tab selection without opening MailCenter or its keychain.
    @ObservationIgnored var lookForMailSignInLink: () -> Void = { MailLinks.look() }

    var activeID: Tab.ID? {
        willSet { relay.send(\.activeID, newValue) }
        didSet {
            guard oldValue != activeID else { return }
            ChromiumTabGroups.shared.changed()
            tab(id: oldValue)?.built?.updateVideoOpening()
            if fieldPutAway { fieldPutAway = false }
            if stagePair == nil, (oldValue == nil) != (activeID == nil) { columnAfresh(preservingScroll: true) }
            // Another tab in front by any other way: the switch waiting
            // for its page's first frame is off (`select`).
            if switchPending != activeID { releaseSwitch() }
            // Back on a minimized video's tab: leaving it floats it again.
            minimizeHold.shown(activeID)
            searchSuggestions.update(nil, engine: searchEngine.engine) {}
            if loginWaiting?.tab == oldValue { loginWaiting = nil }
            // A sign-in link that came while another tab was in front.
            if activeID != nil { DispatchQueue.main.async { [weak self] in self?.lookForMailSignInLink() } }
            // A tab in front again: the field had its answer, or was left
            // for another tab, and what stood under it goes.
            if activeID != nil, under != nil { settleUnder() }
            // The field's answer is the window's, not the tab's: a tab coming
            // forward under it (one the agent opens) leaves it answering.
            if !(query.answering && selectionCommands.answering) { selectionCommands.close() }
            // Another tab's field is not the site this one was searching.
            dropScope()
            // Going to another tab puts down whatever was picked around the
            // one you were on, only if there was any: this runs on every
            // switch, and an empty set written over an empty one would still
            // redraw everything.
            if !gathered.isEmpty { gathered = [] }
            // A peek belongs to the page it was opened over: put by with it,
            // and back with it.
            followPeek()
            watchBlank()
            // In mail: its page, or one of the space's tabs (MailTabRows).
            if inMail { mailFollows() }
            findFollows(left: oldValue)
            // Hide Elements points at one page, and ends with it. Left on,
            // its bar stood over a page nothing pointed at, Esc there
            // turned it off on the wrong tab, and the page left went on
            // hiding whatever was clicked, with no bar to say so.
            if veiling {
                veiling = false
                tab(id: oldValue)?.stopPicking()
            }
            // Developer Tools are the tab's (DevTools.swift).
            devFollows(left: oldValue)
            // The tab just left is the tab just looked at. Whether a tab has
            // gone unwatched long enough to sleep is counted from here, not
            // from when it was first picked.
            // A page's question waits on the tab left, and comes down on
            // the one arrived at, also when the one left has just closed.
            // Which stages show what, before a question follows: a half
            // still on screen keeps its question up.
            restage(from: oldValue)
            player.restage()
            // A stuck page's question is only ever on the page: left, it goes
            // rather than waiting on the tab, and comes back with you.
            if let left = tab(id: oldValue) { leaveStuck(left) }
            asksFollow(left: tab(id: oldValue), to: active)
            askIfStuck(active)
            if let old = oldValue { noteLeft(old) }
            // Only the tab ⌘W just landed on is one: any other step ends it.
            if activeID != closeLanded { closeLanded = nil }
            if activeID != closedOnto { closedOnto = nil }
            // Each time a tab comes on screen: one you keep coming back to
            // stays awake (Sleep.swift).
            active?.visits += 1
            // What a finished agent left on it, seen (AgentFeed).
            DispatchQueue.main.async { AgentFeed.shared.lookAround() }
            guard let left = tab(id: oldValue) else { return }
            left.touch()
            // A password asked about over the page goes to wait on its tab.
            offerLeft(left)
            payLeft(left)
            if fileWaiting(for: left) { dropFiles() }
        }
    }

    // MARK: - two side by side (Split.swift)

    /// The tabs shown side by side, each pair in the row's order.
    var pairs: [Pair] = [] {
        willSet { relay.send(\.pairs, newValue) }
        // However they changed, a pin taken out of one, a space's brought
        // back, what is on screen follows, and the two of each stay side by
        // side. Asked only when they changed.
        didSet {
            guard pairs != oldValue else { return }
            keepPairs()
            restage()
            player.restage()
            // A pin's copy goes with its pair, however the pair went
            // (`dropCarried`): separated, its other half closed, or the copy
            // replaced by another tab.
            let left: [Tab.ID] = oldValue.flatMap { [$0.first, $0.second] }.filter { (id: Tab.ID) in
                pair(of: id) == nil && tabs.contains { $0.id == id && $0.carriedFrom != nil }
            }
            if !left.isEmpty { DispatchQueue.main.async { [weak self] in self?.dropCarried(left) } }
        }
    }
    /// A pair just pinned as one (PinPairs.swift): its square grows in.
    @ObservationIgnored var pinGrowing: Tab.ID?
    /// The pair on screen, or nil for one page. Kept through a change of
    /// shape after the pair itself is gone, so the half going stays drawn
    /// until it is covered.
    var stagePair: Pair? {
        willSet { relay.send(\.stagePair, newValue) }
        didSet {
            if stagePair != oldValue { DispatchQueue.main.async { AgentFeed.shared.lookAround() } }
            if active != nil, (stagePair == nil) != (oldValue == nil) { columnAfresh() }
        }
    }

    /// The site's color the window wears, `dresser`'s tone, read alone where
    /// it is drawn (Worn, SteadyWorn, LookWorn, GroundFill), not by watching
    /// the whole tab (feedback #186).
    var worn: WornSite { WornSite(color: dresser?.tone, tab: dresser?.id) }

    /// The tab whose color the window wears (`dresser`) come or gone: the
    /// column, which stays whole through it (SteadyWorn), is next laid as
    /// one made anew would be (ColumnPage.showAfresh), as Worn's remaking
    /// it did.
    func columnAfresh(preservingScroll: Bool = false) {
        for pages in ColumnPages.live.allObjects where pages.browser === self {
            pages.shown?.showAfresh(preservingScroll: preservingScroll)
        }
    }
    /// How narrow the window may go: further with no pair on screen than
    /// with one (floorWindow).
    var windowFloor = Browser.narrowestWindow {
        willSet { relay.send(\.windowFloor, newValue) }
    }
    /// The least size the window's content asked for when last measured
    /// (WindowFloorLayout), which Yab gives the window (applyWindowFloor).
    var contentFloor = CGSize.zero
    /// An applyWindowFloor waiting for the next turn of the run loop.
    var floorSoon = false
    /// While a pair comes together or comes apart, the half that has the
    /// whole width, over the other.
    var wide: Tab.ID? {
        willSet { relay.send(\.wide, newValue) }
    }
    /// A pair coming together or apart, or made even: the pages held.
    var splitting = false {
        willSet { relay.send(\.splitting, newValue) }
    }
    /// The divider in the hand: the pages held, and nothing drawn going.
    var splitHeld = false {
        willSet { relay.send(\.splitHeld, newValue) }
    }
    /// Room made beside the page in front for a tab carried over it,
    /// watched only by the halves' room, the band and the page it moves
    /// (SplitPreview): published here, every move of it laid the whole
    /// window out again, some 20 ms a pass.
    let splitPreview = SplitPreview()
    /// The side the carried tab would take (`previewSplit`). Never in the
    /// pairs or the session.
    var splitRoom: Side? { splitPreview.room }
    /// That room being made or given back: the page held, and WebKit
    /// following the width it shows.
    var splitRooming: Bool { splitPreview.moving }
    /// The side asked for last, set at once; `splitRoom` follows a frame on.
    @ObservationIgnored var splitRoomAsked: Side?
    @ObservationIgnored var splitRoomMoves = 0
    /// Which tab each of the two stages shows. Read while drawing, changed
    /// only with `activeID` or the pairs, and observed itself, so the window
    /// that draws the stages depends on it and not on whatever else changed
    /// with it.
    var stages: [Tab.ID?] = [nil, nil]
    let splitBook = SplitBook()
    /// What plays in a tab you aren't looking at, for the band over the
    /// column's foot (Tune.swift, PlayerBand.swift).
    @ObservationIgnored lazy var player = Player(browser: self)
    /// The folders as this window's column draws them (AgentFolders.swift):
    /// the first window's are `Folders.shared`, every other window open on
    /// screen has its own (`takeOwnFolders`), so a space's folders of yours
    /// are drawn in each window of it (KeptEverywhere.swift). A test's
    /// browser, no window, has the shared ones.
    var folderBook: Folders { ownFolders ?? Folders.shared }
    @ObservationIgnored private(set) var ownFolders: Folders?

    /// A window other than the first, coming on screen: folders of its own.
    func takeOwnFolders() {
        guard windowPurpose == .normal, windowID != nil, ownFolders == nil, Folders.shared.browser !== self else { return }
        let made = Folders(sharing: Folders.shared)
        ownFolders = made
        made.browser = self
    }
    let splitDrag = SplitDrag()
    let splitHint = SplitHint()

    /// Whether the row last grew or shrank, so it can make room at the pace
    /// of what happened: an arrival a touch slower than a leaving. Read while
    /// drawing, never watched, nothing redraws because it changed.
    @ObservationIgnored private(set) var tabsGrew = true
    @ObservationIgnored private(set) var tabsLineChanged = false

    /// The tab whose page is currently out in the little window. Nothing
    /// floating means no window: the two are checked against each other rather
    /// than trusted to stay in step.
    private(set) var floating: Tab.ID? {
        willSet { relay.send(\.floating, newValue) }
        didSet {
            guard floating == nil, floater.showing, !floater.homing else { return }
            floater.drop()
        }
    }
    /// The floating video is WebKit's own, out of its page (FloatPiP.swift):
    /// the page stays in its tab, and goes home by WebKit's exit, not by
    /// being put back.
    private(set) var picturing: SitePiP.Picture?
    /// A native request can outlive the tab departure that started it. Keep
    /// its owner until both the script answer and native delivery are known.
    @MainActor private final class VideoRequest {
        weak var page: NSView?
        let navigation: CFTimeInterval?
        var cancelled = false
        var answered = false
        var delivered = false
        init(_ tab: Tab) { page = tab.builtPage; navigation = tab.askedAt }
    }
    @ObservationIgnored private var videoRequests: [Tab.ID: VideoRequest] = [:]
    var pendingVideoRequestsForBench: Int { Store.testing ? videoRequests.count : 0 }
    /// The tab out in the little window. Among every space's tabs, as
    /// `land` looks: a call stays floating while its space is put away.
    var floatedTab: Tab? { floating.flatMap { id in everyTab.first { $0.id == id } } }
    /// The tab with this id in the row on screen, nil for none.
    func tab(id: Tab.ID?) -> Tab? { id.flatMap { id in tabs.first { $0.id == id } } }

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs = Preferences()
    let spaceWash = SpaceWash()
    /// The gradient's turn and last tab count belong to this window.
    var lookStep = 0
    @ObservationIgnored var lookSeen: (space: UUID, count: Int)?
    /// The settings window. Setting it opens that window, or brings it
    /// forward; the window closing sets it back.
    var tuning = false {
        willSet { relay.send(\.tuning, newValue) }
        didSet {
            if tuning { SettingsWindow.shared.show(for: self) } else if oldValue { SettingsWindow.shared.hide() }
        }
    }
    /// The first-launch walk-through, over everything. Also from the menu.
    var welcoming = false {
        willSet { relay.send(\.welcoming, newValue) }
    }
    /// The walk-through's one button, for Return. The page or the field
    /// under the walk-through holds the keyboard, and WebKit takes Return
    /// before SwiftUI would give it to the button, so the key watcher hands
    /// it over itself.
    @ObservationIgnored var welcomeReturn: (() -> Void)?
    @ObservationIgnored var welcomeBack: (() -> Void)?
    /// The welcome's quiet button, for the bench: Start Fresh, Later, Not Now.
    @ObservationIgnored var welcomeQuiet: (() -> Void)?

    // MARK: - bookmarks

    let bookmarks = Bookmarks.shared

    /// Add This Page: the page you are on, at the end of the list.
    func bookmarkCurrent() {
        guard let tab = active, let url = tab.address else { return }
        // The app's own pages, history, the bookmarks themselves, aren't
        // places to keep.
        guard Bookmark.keepable(url) else {
            announce("Nothing to bookmark here", mark: "bookmark.slash")
            return
        }
        guard !bookmarks.contains(url) else {
            announce("Already bookmarked", mark: "bookmark.check")
            return
        }
        guard let kept = bookmarks.add(url, title: tab.title) else { return }
        NoticeFeedback.success.play()
        // With folders to put it in, the corner offers them, saved already
        // and nothing to answer: Move To is one click to a menu of them, as
        // Chrome's star asks for a folder, without the asking.
        if !Bookmarks.folders(bookmarks.roots).isEmpty {
            if shelfShown { Teach.shared.pressed(.bookmark) }
            toaster.pop("Bookmarked", mark: "bookmark.check", undo: { [weak self] in self?.fileBookmark(kept) }, act: "Move To")
            return
        }
        // With the bookmarks in view, the new one arriving there says it.
        // Otherwise the corner, with Add This Page's key after it, when it
        // has one chosen, when the star or a menu did it (Teach.swift).
        if shelfShown { Teach.shared.pressed(.bookmark) }
        else { toaster.pop("Bookmarked", mark: "bookmark.check", keys: Teach.shared.keys(after: .bookmark, action: .bookmark)) }
    }

    /// The address's star (AddressBar, SidePlate): Add This Page, and on a
    /// page kept already the bookmark taken out again, ⌘Z putting it back.
    /// The star going hollow says it; the corner says nothing more.
    func toggleBookmark(_ tab: Tab) {
        guard let url = tab.address else { return }
        focus(tab)
        guard let id = bookmarks.id(for: url) else {
            bookmarkCurrent()
            return
        }
        did(bookmarks.removeUndoably(id))
    }

    /// The folders a bookmark can go into from the corner's Move To, each
    /// with how deep it sits: every one but the one it is in.
    func bookmarkFolders(for id: Bookmark.ID) -> [(node: Bookmark, depth: Int)] {
        Bookmarks.folders(bookmarks.roots).filter { folder in !(folder.node.children ?? []).contains { $0.id == id } }
    }

    /// The corner's Move To: the Mac's menu of folders at the pointer, the
    /// one it was pressed with, a folder three deep drawn three in.
    func fileBookmark(_ id: Bookmark.ID) {
        guard let window = Links.window, let content = window.contentView else { return }
        folderMenu(for: id).popUp(positioning: nil, at: content.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: content)
    }

    func folderMenu(for id: Bookmark.ID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (folder, depth) in bookmarkFolders(for: id) {
            let line = PageMenuItem(folder.title) { [weak self] in self?.bookmarks.move(id, into: folder.id) }
            line.indentationLevel = depth
            MenuMark.put("folder", on: line)
            menu.addItem(line)
        }
        return menu
    }

    /// Another browser's bookmarks, folders and all, and, behind them, the
    /// icons it had for those sites, so the menu wears them from the start
    /// instead of a letter each. Taken again, only what is new comes (see
    /// Bookmarks.take). Hands how many pages came over to `done`, on the
    /// main thread.
    func takeBookmarks(from source: Chromium.Source, then done: @escaping (Int) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            let profiles = source.bundle == TabImport.dia ? source.profiles.map {
                (folder: $0.lastPathComponent, nodes: Chromium.bookmarks(inProfile: $0))
            } : []
            let names = TabImport.profileNames(in: source)
            let found = profiles.isEmpty ? Chromium.bookmarks(in: source) : profiles.flatMap(\.nodes)
            let brought = Bookmarks.brought(from: source.name)
            let count = Bookmarks.count(found)
            let urls = Bookmarks.urls(found)
            DispatchQueue.main.async {
                let took: (added: Int, held: Int)
                if source.bundle == TabImport.dia {
                    var added = 0
                    for profile in profiles where !profile.nodes.isEmpty {
                        added += self.takeProfileBookmarks(profile.nodes, profile: profile.folder,
                                                          name: names[profile.folder] ?? profile.folder, from: source)
                    }
                    took = (added, 0)
                } else {
                    took = self.bookmarks.take(found, from: source.name, brought: brought)
                }
                // Under the welcome, its own corner says it once it is all in.
                if !self.welcoming {
                    self.announce(Browser.broughtLine(added: took.added, held: took.held, of: count, from: source.name), mark: "tray.and.arrow.down", feedback: took.added > 0 ? .success : nil)
                }
                done(took.added)
            }
            let icons = Chromium.icons(in: source, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
    }

    /// Zen's or Firefox's bookmarks, read from a copy of each profile's
    /// places.sqlite and taken the way a Chromium browser's are. Said in
    /// the corner given, or the window's. Hands how many pages came over to
    /// `done`, on the main thread.
    func takeBookmarks(from source: Firefox.Source, quiet: Bool = false, on corner: Toaster? = nil,
                       then done: @escaping (Int) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Firefox.bookmarks(in: source)
            let brought = Bookmarks.brought(from: source.name)
            DispatchQueue.main.async {
                let took = self.bookmarks.take(found, from: source.name, brought: brought)
                if !quiet {
                    self.announce(Browser.broughtLine(added: took.added, held: took.held, of: Bookmarks.count(found), from: source.name),
                                  mark: "tray.and.arrow.down", feedback: took.added > 0 ? .success : nil, on: corner)
                }
                done(took.added)
            }
        }
    }

    /// ⇧⌘S. The same tabs, down the left or across the top.
    ///
    /// Not the strip sliding off the top and the column sliding in from
    /// the left, each the whole way: only a hint of the way each one goes,
    /// the strip up, the column in from the left, over a fade, the two
    /// overlapping, while the page reshapes in the same beat.
    func toggleSidebar() {
        let side = !prefs.sidebar
        turns += 1
        let turn = turns
        // First, with nothing moving yet, the side the tabs are going to is
        // built and put in the window unseen (see Presence), the costly
        // part, done in a frame nobody can tell from the one before. Only
        // then, in a pass of its own that has nothing left to build, does
        // anything move; and the side left behind is taken away once it has
        // stopped. A plain async can run before the first pass is drawn.
        turning = true
        // The lights are the same three either way, and in the same place
        // but for a few points down: they stay, and only step. Not when
        // there were none to see, a column or a strip put away took them
        // with it.
        let lit = !tabsAway
        // Asked for the column, so the column, not a column put away, and
        // set now, so the column that is put in unseen for the change is
        // already the docked one, not a card waiting past the edge.
        // A pair on screen with no room for the column beside it keeps the
        // room: the column is put away, and comes out over the page.
        // Asked for the strip, so the strip, not one put away.
        if side { prefs.sideShut = columnMost < prefs.sideWidth } else { putStrip(away: false) }
        stillLights = !fullScreen && active?.immersed != true && lit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            // No animation around it: the window is laid out once, where
            // everything ends up, and what moves draws its own way there,
            // the page and its paper in Core Animation (see Reshape), the
            // strip, the column and the lights on their own curves.
            prefs.sidebar = side
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                guard turns == turn else { return }
                turning = false
                stillLights = false
            }
        }
    }

    /// True while the tabs are changing sides.
    private(set) var turning = false {
        willSet { relay.send(\.turning, newValue) }
    }
    /// While the tabs change sides, the lights are drawn over the window
    /// rather than by the strip or the column, so they are not part of
    /// either one's going.
    private(set) var stillLights = false {
        willSet { relay.send(\.stillLights, newValue) }
    }
    @ObservationIgnored private var turns = 0

    /// ⌘S. The column put away into the left edge, or brought back out of
    /// it. With the tabs across the top there is no column to put away:
    /// the strip goes instead (`toggleStrip`).
    func toggleColumn() {
        guard prefs.sidebar else { return toggleStrip() }
        // A pair on screen with no room for the column beside it: out over
        // the page as a card, as the edge brings it, and back, and the
        // halves keep their room.
        if prefs.sideShut, columnMost < prefs.sideWidth {
            Brim.bring(self, out: !sidePeek)
            return
        }
        sidePull = nil
        folds += 1
        let fold = folds
        let target = !(columnTarget ?? prefs.sideShut)
        columnTarget = target
        // Dia pins its floating card at the docked width directly. The
        // ordinary hidden-column slide is a different operation: replaying
        // it here carries an old-width page out from under the card.
        if sidePeek, !target, StageView.geometryFollowing {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                sidebarPins += 1
                folding = false
                columnTarget = nil
                sideCard = false
                sidePeek = false
                prefs.sideShut = false
            }
            column?.settleSlide(out: true)
            return
        }
        // The page held where it is first, in a pass of its own, and only
        // then anything moved, as for ⇧⌘S; see `folding`.
        folding = true
        StageView.mark("folding")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            guard folds == fold else { return }
            guard prefs.sideShut != target else {
                folding = false
                columnTarget = nil
                return
            }
            StageView.mark("fold-change", ["shut": !prefs.sideShut])
            // Let go once the column has arrived, and not before: the page
            // made its new size, WebKit lays it out anew, and AppKit can
            // wait on that for up to half a second with nothing drawn, the
            // column stopped wherever it had got to. Nor much after, or the
            // page sits still at its old size and its laying out comes late,
            // a step of its own. A frame after the page's curve, counted
            // from when the window's pass handed it to Core Animation
            // (Reshape.landed), never from SwiftUI's own animation: with
            // nothing of SwiftUI's moving in the change, its completion came
            // at once, before the window was laid out, and the page was let
            // go unheld, at its new size in one frame (feedback #88).
            let asked = CACurrentMediaTime()
            let arrived = { [self] in
                guard folds == fold, folding else { return }
                folding = false
                columnTarget = nil
                Reshape.pace = .reshape
            }
            // Only the newest requested state may change the layout.
            if !target {
                // Brought back: the column slides in from past the edge as
                // it is, the page making room in the same beat, on the same
                // curve. Out over the page as a card, the card goes at once
                // and the docked column comes in from the edge all the same,
                // as Arc pins its sidebar. Grown in place, the see-through
                // card showed the page sliding out from under it, and in
                // two frames turned the window's color (2026-10-20 report,
                // evals/sidebar-motion/pin.py).
                if sidePeek {
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        sideCard = false
                        sidePeek = false
                    }
                    column?.slide(out: false, animated: false)
                }
                let pace: Reshape.Pace = .arrive
                Reshape.pace = pace
                withAnimation(pace.animation) {
                    sidePeek = false
                    prefs.sideShut = false
                }
                Reshape.landed(after: asked, pace: pace) { arrived() }
            } else {
                // Put away, it slides out past the edge as it is, and the
                // page takes the room, no stop as a card on the way. On the
                // arriving curve too, not the leaving one: the page's edge
                // is what the eye follows here, and it lands where it goes,
                // soft, where gathering speed it hit the window's edge. As
                // Dia's does, which leaves and comes back on one curve.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { sideCard = false }
                Reshape.pace = .arrive
                withAnimation(Reshape.Pace.arrive.animation) {
                    sidePeek = false
                    prefs.sideShut = true
                }
                Reshape.landed(after: asked, pace: .arrive) { arrived() }
            }
        }
    }

    /// True while ⌘S puts the column away or brings it back: the page is
    /// carried on the column's curve, with WebKit following its visible size
    /// as it goes (see `Reshape` and `StageView.following`).
    private(set) var folding = false {
        willSet { relay.send(\.folding, newValue) }
    }
    @ObservationIgnored private var folds = 0
    @ObservationIgnored private var columnTarget: Bool?
    private(set) var sidebarPins = 0 {
        willSet { relay.send(\.sidebarPins, newValue) }
    }
    /// Only the line's controls observe this; entering the column does not
    /// relay a row-layout change through Combine.
    var columnHovered = false

    // MARK: - the strip put away

    /// With the tabs across the top, the strip put away by ⌘S, the page
    /// taking its room (`prefs.stripShut`, feedback #48). The window's top
    /// edge brings it out over the page for a while (Brim), the way the
    /// left edge brings out a column put away.
    var stripAway: Bool { !prefs.sidebar && prefs.stripShut }

    /// Whatever holds the tabs, the column or the strip, is put away.
    var tabsAway: Bool { prefs.sidebar ? prefs.sideShut : prefs.stripShut }

    /// How far the island stands in from the column's side and bottom
    /// (Band.edge). In full screen the window has no corners to hug, and
    /// the column in its place stands beside the page laid as a card: the
    /// island takes the page's inset, its bottom level with the page's and
    /// its ends with the foot's row over it.
    var bandEdge: CGFloat {
        fullScreen && prefs.backdrop != .none && !prefs.sideShut ? Backdrop.inset : Band.edge
    }

    /// ⌘S's menu item as it reads now: the sidebar's, or with the tabs
    /// across the top, the tab bar's.
    var columnTitle: String { Self.menuTitle(sidebar: prefs.sidebar, away: tabsAway) }

    static func menuTitle(sidebar: Bool, away: Bool) -> String {
        sidebar ? (away ? "Show Sidebar" : "Hide Sidebar") : (away ? "Show Tab Bar" : "Hide Tab Bar")
    }

    /// The strip out over the page, and its look: watched by the strip, the
    /// window's drag strip and the downloads button, not by the whole
    /// window (StripPeek).
    let topPeek = StripPeek()
    /// The strip is out over the page while it is put away.
    var stripPeek: Bool {
        get { topPeek.out }
        set { topPeek.out = newValue }
    }
    /// How the strip looks while it is not in its place: lifted off the
    /// page on a ground of its own, when the top edge has brought it, or
    /// is about to bring it, out over the page; flat, as in its place, when
    /// ⌘S has just put it away and it slides up past the edge as it was.
    /// Put on only while it is out of sight, and never animated on, as
    /// `sideCard` is for the column; ⌘S landing it fades it off.
    var stripCard: Bool {
        get { topPeek.card }
        set { topPeek.card = newValue }
    }
    /// True while ⌘S puts the strip away or brings it back: the page is
    /// held and carried on the strip's curve, with WebKit following its
    /// visible size as it goes (see `Reshape` and `StageView.following`).
    private(set) var stripMoving = false {
        willSet { relay.send(\.stripMoving, newValue) }
    }
    /// How far down the strip is drawn while `stripMoving`: 1 in its place,
    /// 0 past the window's top edge. Animated while the layout is already
    /// where it ends, so what rides with the strip, the address bar and the
    /// bookmarks over the page, is drawn by the difference (`ShelfCarry`).
    /// Only read while `stripMoving`.
    private(set) var stripDown: CGFloat = 1 {
        willSet { relay.send(\.stripDown, newValue) }
    }
    @ObservationIgnored private var stripMoves = 0

    /// The curve ⌘S moves the strip on, nil for none. Under Reduce Motion
    /// nothing slides: the strip and the page simply change. Otherwise
    /// Dia's, away and back on one curve (Motion.stripCurve); out over the
    /// page when ⌘S brings it back, the strip is already where it goes,
    /// and only the page moves on it, making room under it.
    static func stripPace(reduce: Bool) -> Reshape.Pace? {
        reduce ? nil : .strip
    }

    /// The strip in its place, or put away, at once, nothing moving: for a
    /// change of layout that asks for the tabs across the top, and for
    /// ⌘S under Reduce Motion.
    func putStrip(away: Bool) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            stripPeek = false
            stripCard = false
            stripDown = away ? 0 : 1
            if prefs.stripShut != away { prefs.stripShut = away }
        }
    }

    /// ⌘S with the tabs across the top: the strip put away up past the
    /// window's top edge, the page taking its room, or brought back down.
    ///
    /// Done the way ⌘S does the column: the page held where it is first,
    /// in a pass of its own; then the window laid out once, where
    /// everything ends up, the page and its paper carried there by Core
    /// Animation and the strip slid on the same curve, flat, as it is in
    /// its place. Out over the page when ⌘S comes, it stays where it is,
    /// its ground and shadow going as the page makes room under it.
    func toggleStrip() {
        guard !prefs.sidebar else { return }
        // Under Reduce Motion the page isn't even held: nothing is carried.
        guard let pace = Self.stripPace(reduce: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) else {
            return putStrip(away: !prefs.stripShut)
        }
        stripMoves += 1
        let move = stripMoves
        var still = Transaction()
        still.disablesAnimations = true
        // Drawn where it stands now, before anything moves; up past the
        // edge, as it is in its place, flat, with no lift left over from
        // the last time the edge brought it out. Not while the last ⌘S
        // still moves it: it turns back from where its curve has it, and
        // set here it jumped to one end first.
        if !stripMoving {
            withTransaction(still) {
                let hidden = stripAway && !stripPeek
                stripDown = hidden ? 0 : 1
                if hidden { stripCard = false }
            }
        }
        stripMoving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            // Let go a frame after the strip's last, and in any case after
            // a second, should its end never be told; as for the column.
            let arrived = { [self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
                    guard stripMoves == move, stripMoving else { return }
                    stripMoving = false
                    Reshape.pace = .reshape
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { arrived() }
            // The tabs went down the side meanwhile: nothing to move.
            guard !prefs.sidebar else { return arrived() }
            // Decided here, not when asked: two quick presses are two
            // changes, the second undoing the first.
            let away = !prefs.stripShut
            // The window laid out once, where everything ends up, with no
            // animation round it: the page and its paper draw their edge
            // from where it was in Core Animation (Reshape). Put away, the
            // strip goes as it was in its place, flat, not lifted.
            Reshape.pace = pace
            withTransaction(still) {
                if away { stripCard = false }
                stripPeek = false
                prefs.stripShut = away
            }
            // In the same pass as the layout, so the strip, and what rides
            // with it, start in the frame the page's own carry starts in, on
            // the same curve. Brought back from over the page, its ground
            // and shadow go as the page makes room under it.
            withAnimation(pace.animation, completionCriteria: .logicallyComplete) {
                stripDown = away ? 0 : 1
                if !away { stripCard = false }
            } completion: { arrived() }
        }
    }

    /// How much of the column shows while a hand is on it, its edge pulled
    /// in past its narrowest, or a shut one pulled back out of the window's
    /// edge. Nil the rest of the time, when the column is simply open or shut.
    var sidePull: CGFloat? {
        willSet { relay.send(\.sidePull, newValue) }
    }

    /// A hand on the sidebar's width owns its geometry, including its pins.
    var sideSizing = false
    @ObservationIgnored private var sideSizeTurn = 0

    func beginSideSize() {
        sideSizeTurn += 1
        sideSizing = true
    }

    func endSideSize() {
        let turn = sideSizeTurn
        // Keep the final drag target in the same tracking pass as its width.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sideSizeTurn == turn else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { self.sideSizing = false }
        }
    }

    /// The column out past its widest under the hand, or on its way back:
    /// its width runs on a curve, and its rows follow it a frame behind
    /// (ColumnPage.rowWidth). Ends with the curve.
    @ObservationIgnored var sideStretching = false
    /// When the stretched column was let go: its first frame back, which
    /// also sets the window's curves going, leaves the rows where they are.
    @ObservationIgnored var sideLetGo: CFTimeInterval = 0

    /// The window fills the screen. Set by Brim, which looks after the rest.
    var fullScreen = false {
        willSet { relay.send(\.fullScreen, newValue) }
    }
    /// The column out over the page as a card, and its look: watched by
    /// the column and the downloads button, not by the whole window.
    let peek = SidePeek()
    /// The column is out over the page as a card, while it is put away.
    var sidePeek: Bool {
        get { peek.out }
        set { peek.out = newValue }
    }
    /// How the column looks while it is not in its place: a card, when it
    /// was, or is about to be, brought out over the page; docked, flush
    /// and flat, when it has just been put away and is sliding out as it
    /// was. Changed only while it is out of sight, and never animated.
    var sideCard: Bool {
        get { peek.card }
        set { peek.card = newValue }
    }
    /// In full screen, how far the menu bar and the title bar have come
    /// down into the window, for whatever has to step down out of their way.
    var menuDown: CGFloat = 0 {
        willSet { relay.send(\.menuDown, newValue) }
    }
    /// In full screen, macOS has its menu bar down, over the window, or,
    /// on a screen with a notch, above it, and the title bar with the
    /// lights in it under that.
    var menuOut = false {
        willSet { relay.send(\.menuOut, newValue) }
    }
    /// In full screen the lights are macOS's own, in the title bar it
    /// brings down with the menu bar, and ours are gone; not with the tabs
    /// down the left, whose column keeps ours in its corner. Set by Brim.
    var titleLights = false {
        willSet { relay.send(\.titleLights, newValue) }
    }

    /// The edge the column is on: the one asked for, while there is a
    /// column; the left with the tabs across the top, so nothing that asks
    /// moves for a column that isn't there.
    /// The band with the lights has its room over the page (HeadBand): the
    /// pointer rested in the seam above the page and is still in the band
    /// (Brim). The page starts under it, as under a title bar.
    var headOut: Bool {
        get { headPeek.out }
        set { headPeek.out = newValue }
    }
    /// What is in the band shows: after the room is made, before it is
    /// given back, so the lights never stand over a page moving under them.
    var headShown: Bool {
        get { headPeek.shown }
        set { headPeek.shown = newValue }
    }
    /// Both, in an object of their own that only the band and the page's
    /// offset watch (HeadPeek).
    let headPeek = HeadPeek()
    @ObservationIgnored private var headMoves = 0

    var flank: Flank { prefs.sidebar ? prefs.sideFlank : .left }

    /// The column is on the right and the window isn't full screen: the
    /// lights and the page's title are in a band over the page that comes
    /// down while the pointer is at the window's top, the
    /// column keeping the whole height beside it (HeadBand).
    var headBand: Bool {
        flank == .right && !fullScreen
    }

    /// How much of the column the window gives it right now.
    var sideShown: CGFloat {
        // Element fullscreen uses WebKit's own window. Keep this source
        // window's room, placeholder and chrome unchanged for its return.
        guard prefs.sidebar else { return 0 }
        return sidePull ?? (prefs.sideShut ? 0 : prefs.sideWidth)
    }

    /// The address field, raised over a page by ⌘L. With no tab in front,
    /// or a private one still empty, it starts up without being asked.
    var editing = false {
        willSet { relay.send(\.editing, newValue) }
        didSet {
            if editing && !oldValue {
                query.pasteStyleTarget.captureBeforeField(in: fieldHost ?? BrowserWindows.shared.window(for: self))
            }
            if !editing, asked != nil { asked = nil }
            if editing != oldValue { fieldAway.watch(editing) }
            if !editing { searchSuggestions.update(nil, engine: searchEngine.engine) {} }
            // The field raised again asks anew, whatever it last said.
            if !editing { query.answered = nil }
            if !editing, fieldGuest != nil { fieldGuest = nil; fieldHost = nil }
            if editing, fieldPutAway { fieldPutAway = false }
        }
    }
    /// The field put away with no tab in front, by Escape or a click on the
    /// ground, in an empty window or a space whose column has tabs to go to.
    /// ⌘T, ⌘L, a tab in front or another space raises it again.
    var fieldPutAway = false {
        willSet { relay.send(\.fieldPutAway, newValue) }
    }
    /// Nothing in front or under the field: an empty window, or a normal
    /// space with its own tabs in the column to pick instead.
    var fieldCanPutAway: Bool {
        active == nil && under == nil && fieldGuest == nil
            && (tabs.isEmpty || (windowPurpose == .normal && Browser.holdsOwn(tabs)))
    }
    /// Close Tab on the window's own ground closes the window. Pins and
    /// kept rows in its column are places to go, not pages in front. A
    /// regular background page or another space under the field stays.
    var closesWindowOnCloseTab: Bool {
        activeID == nil && fieldGuest == nil
            && (tabs.isEmpty || (under == nil && tabs.allSatisfy { $0.kept || $0.pin != nil }))
    }
    /// The page of a small window the field was raised over there (⌘L, or
    /// a click on its address, LinkWindow): the field stands in that window
    /// instead of this one, and what it is sent to goes to that page. Nil
    /// for the window's own tab.
    var fieldGuest: Tab?
    /// That small window, where a click away from the field puts it away.
    @ObservationIgnored weak var fieldHost: NSWindow?
    /// The field over a page: a click anywhere in the window but on its box
    /// puts it away, the sidebar, the strip and the column as the page
    /// (App's scrim, which keeps the page's own click). The click still
    /// does its own: a tab clicked in the sidebar is then in front.
    @ObservationIgnored lazy var fieldAway: ClickAway = {
        // A row takes its click on mouse-up. Dismissing on mouse-down lit
        // the old tab between the press and the row's selection. Let that
        // selection finish first, including its deferred first frame.
        let away = ClickAway(on: [.leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] in
            guard let self, self.editing, self.switchPending == nil,
                  (self.fieldGuest ?? self.active)?.isBlank == false else { return }
            self.dismiss()
        }
        away.within = { [weak self] in self.flatMap { $0.fieldHost ?? BrowserWindows.shared.window(for: $0) } }
        return away
    }()
    /// What the field asking for somewhere new makes of the place it is
    /// given: a tab of its own beside the page (⌘T, the plus), or the half
    /// beside the page (Split View). ⌘N asks in a window of its own.
    enum Asked { case tab, split }
    /// ⌘T or Split View over a page: the field stands over the page as
    /// ⌘L's does, but empty and asking for somewhere new, and what it opens
    /// comes with a tab or a half of its own. Nothing is made
    /// until there is something to put in it, so Escape leaves the row as
    /// it was. Nil for ⌘L's field.
    private(set) var asked: Asked? {
        willSet { relay.send(\.asked, newValue) }
    }
    /// The field is asking for somewhere new rather than about the page
    /// under it: ⌘T's, Split View's, or, with no tab in front, the window's
    /// own (a new window's, ⌘N).
    var fresh: Bool { asked != nil || (fieldGuest == nil && active == nil) }
    /// What `place` is to make of a place chosen now: what was asked for,
    /// a tab of its own with nothing in front, the page under the field
    /// (nil) after ⌘L. Read before the field goes, which lets go of it.
    var asking: Asked? { asked ?? (fieldGuest == nil && active == nil ? .tab : nil) }
    /// The field is asking where to go next rather than about the page
    /// under it: an empty private tab's, ⌘T's over a page, or the window's
    /// with nothing in front.
    var askingNew: Bool { fresh || ((fieldGuest ?? active)?.isBlank ?? true) }
    /// What the field's Return does with a place, in the words of its foot.
    static func openWords(_ asking: Asked?) -> String {
        switch asking {
        case .tab: "Open in New Tab"
        case .split: "Open in Split View"
        case nil: "Open"
        }
    }

    /// The mark beside those words in ⌘K's list: the one the page's link
    /// menu and a tab's menu wear for the same thing (PageView.marks,
    /// TabBar): a tab with a plus for a new tab.
    static func openSymbol(_ asking: Asked?) -> String {
        switch asking {
        case .tab: "yab.tab.plus"
        case .split: "yab.split.plus"
        case nil: "yab.globe.right"
        }
    }

    /// The words for a field asking for a new tab in a folder (New Tab in
    /// Folder): the folder it goes into, by name.
    func openWords(_ asking: Asked?) -> String {
        guard asking == .tab, let landing, !landing.name.isEmpty else { return Browser.openWords(asking) }
        return "Open in \(landing.name)"
    }

    /// Its mark: into the folder, when the words name one.
    func openSymbol(_ asking: Asked?) -> String {
        guard asking == .tab, let landing, !landing.name.isEmpty else { return Browser.openSymbol(asking) }
        return "yab.folder.right"
    }

    /// New Tab in Folder's folder: what the field opens goes into it, at
    /// the end of its tabs, rather than among today's. Set with the field,
    /// let go of by the next one, and taken by the tab it makes.
    var landing: Nest?

    /// What the window shows under the field while no tab is in front:
    /// the page you were on, when a space with nothing in it came up; its
    /// tab stays in its own space's row. Nil with nothing to show, the last
    /// tab closed, a new window, a first launch: the field stands on the
    /// window's own ground.
    enum Under {
        case space(Tab, from: UUID)

        var tab: Tab {
            switch self {
            case .space(let tab, _): tab
            }
        }
    }
    var under: Under? {
        willSet { relay.send(\.under, newValue) }
    }
    var underTab: Tab? { under?.tab }
    /// A tab is carried over the spaces (ColumnSpaceCarry), from this one.
    /// A space it visits only shows its rows: nothing there opens or wakes,
    /// and the page it was lifted over stays, until the mouse lifts.
    @ObservationIgnored var carryHome: UUID?
    var spaceVisiting: Bool { carryHome.map { $0 != spaceID } ?? false }
    /// What each visited space had in front, for when it is left again.
    @ObservationIgnored var visitFronts: [UUID: Tab.ID] = [:]
    /// A tab's web view built a moment after a window opens with nothing in
    /// it, so the first address typed finds WebKit already running; the
    /// first page opened takes it (see `open`).
    @ObservationIgnored private var spare: Tab?
    /// The spare to be built again, a moment after one is taken (`keepSpare`).
    @ObservationIgnored private var spareTimer: Timer?
    /// Everything the field says while it is being typed into. Kept on an
    /// object of its own, so a keystroke redraws the field and its list and
    /// nothing else, held here, every letter re-read the whole window.
    let query = Query()
    private let searchSuggestions = SearchSuggestions()
    @ObservationIgnored private var searchCompleting = true
    @ObservationIgnored private var pendingHistorySubmit: (way: Way, typed: String, copyingTabs: Bool)?
    /// ⌃Tab's grid of pages, while ⌃ is down (see Switcher).
    let switcher = Switcher()

    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the gray ending inside it are both just
    /// answers to this string.
    var typed: String {
        get { query.typed }
        set { replaceTyped(newValue) }
    }

    func replaceTyped(_ text: String, completing: Bool = true) {
        if text != query.typed {
            pendingHistorySubmit = nil
            query.typed = text
        }
        guess(completing: completing)
    }

    /// Where you have been. A test gives its window a history of its own.
    @ObservationIgnored private var historyOverride: History?
    var history: History {
        get { historyOverride ?? History.profile(space.profileID) }
        set { historyOverride = newValue }
    }

    /// A background page keeps writing in its own profile after a Space switch.
    func history(for tab: Tab) -> History {
        historyOverride ?? History.profile(Spaces.ownSpace(of: tab.store) ?? Space.firstID)
    }
    /// The rows kept under Favorites in the empty field (FieldFavorites).
    @ObservationIgnored var favorites = FieldFavorites.shared
    @ObservationIgnored var pageRowSettings = Store.settings
    /// What the field is offering, best first.
    var offers: [Suggestion] { query.offers }
    /// The rest of the best match, drawn gray after the caret. Tab takes it.
    var ending: String? { query.ending }
    /// Which row the arrow keys have walked to, if any.
    var picked: Int? {
        get { query.picked }
        set { query.picked = newValue }
    }
    /// Bumped when what was typed isn't an address and can't be searched for.
    private(set) var refusals = 0 {
        willSet { relay.send(\.refusals, newValue) }
    }
    /// Bumped whenever the cursor should go back into the field.
    var focusRequest: Int { query.focusRequest }

    /// The tab in front. Views ask for it hundreds of times in one pass of
    /// the window, and a walk down every tab each time was the most the
    /// window's own code cost on a switch of tab with eighty of them: found
    /// once, kept until the tabs or the one in front change.
    var active: Tab? {
        if let found = activeFound, found.id == activeID { return found.tab }
        let tab = tabs.first { $0.id == activeID }
        activeFound = (activeID, tab)
        return tab
    }
    @ObservationIgnored private var activeFound: (id: Tab.ID?, tab: Tab?)?
    var fieldShowing: Bool { !spaceVisiting && (editing || ((active?.isBlank ?? true) && !(fieldPutAway && fieldCanPutAway) && !tabs.contains { $0.instantState == .searching })) }

    /// Typed plus whatever the field is quietly finishing for you.
    var completed: String {
        if let picked, offers.indices.contains(picked) {
            // Walking onto a thing to do leaves the words as they were:
            // "New Private Tab" is not an address to put in the field.
            switch offers[picked].kind {
            case .command, .setting, .ask, .task, .sum, .place, .clip, .page, .hint, .quickAction: return typed
            // Recent and frequent rows use the page's name as their key.
            // The field takes the address, including its port and query.
            case .open, .visited:
                return offers[picked].url.map { Address.whole($0) } ?? offers[picked].key
            default: return offers[picked].key
            }
        }
        return typed + (ending ?? "")
    }

    // MARK: - looking for something on the page

    /// The find bar is up on the tab in front. Each tab keeps its own, see
    /// Finder, and this follows whichever is in front.
    private(set) var finding = false {
        willSet { relay.send(\.finding, newValue) }
    }

    /// The page ⌘F, ⌘G and ⌘⇧G look through: a peek's while one is up over
    /// the tab, as in Arc, the tab in front's otherwise (#389).
    var findPage: Tab? { peeking ?? active }

    /// ⌘F. Up, or back in the field with what it holds picked. Over a
    /// peek, the peek's page's own bar, in its corner (PeekView.showFind).
    func openFind() {
        if let page = peeking {
            guard !page.isBlank else { return }
            page.finder.open()
            peekView?.showFind(page)
            return
        }
        guard let tab = active, !tab.isBlank else { return }
        if !finding { withAnimation(Motion.arrive) { finding = true } }
        tab.finder.open()
    }

    func closeFind() {
        guard finding else { return }
        withAnimation(Motion.depart) { finding = false }
        active?.finder.close()
    }

    /// ⌘G and ⌘⇧G, from anywhere: with the bar down, it comes up with the
    /// words looked for last.
    func look(forward: Bool) {
        if let page = peeking {
            guard page.finder.shown else { return openFind() }
            return page.finder.step(forward: forward)
        }
        guard finding, let tab = active else { return openFind() }
        tab.finder.step(forward: forward)
    }

    /// The bar is the tab's: it goes with the tab left and comes with the
    /// one arrived at, counted again where its page stands.
    private func findFollows(left: Tab.ID?) {
        tab(id: left)?.finder.pause()
        let shown = active?.finder.shown == true
        if finding != shown { finding = shown }
        if shown { active?.finder.recount() }
    }

    /// ⇧⌘M: the tab muted, or let back in, as its speaker does it, and the
    /// speaker's mark on the tab is the answer. Several picked: all of
    /// them, quiet unless every one already is. Where WebKit can't mute a
    /// page, what plays in it is paused instead.
    func toggleMute(_ group: [Tab]? = nil) {
        let tabs = group ?? (active.map { [$0] } ?? [])
        guard !tabs.isEmpty else { return }
        guard AudioWatch.canMute else { return pauseMedia(tabs) }
        let quiet = tabs.allSatisfy(\.muted)
        tabs.forEach { $0.mute(!quiet) }
    }

    /// Whether a page at this address, in this tab's space, is on a site
    /// muted there (Space.mutedSites).
    func siteMuted(_ tab: Tab, at url: URL? = nil) -> Bool {
        guard let host = (url ?? tab.address)?.host()?.lowercased(),
              let space = spaces.first(where: { $0.id == spaceHolding(tab) }) else { return false }
        return AwakeSites.match(host, in: space.mutedSites ?? [])
    }

    /// The tab's site muted in its space, every tab of it there now and
    /// every one opened later, or let back in, as Dia's Mute youtube.com
    /// does. A site muted because a wider one is (music.youtube.com under
    /// youtube.com) is let back in by taking that one off.
    func toggleSiteMute(_ tab: Tab) {
        guard AudioWatch.canMute, let host = tab.address?.host()?.lowercased(), let site = AwakeSites.site(from: host),
              let id = spaceHolding(tab), let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        let before = spaces[at].mutedSites ?? []
        let on = !AwakeSites.match(host, in: before)
        let after = on ? before + [site] : before.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        spaces[at].mutedSites = after.isEmpty ? nil : after
        Spaces.write(spaces)
        let row = id == spaceID ? tabs : parked[id]?.tabs ?? []
        for other in row {
            guard let there = other.address?.host()?.lowercased() else { continue }
            if on, AwakeSites.match(there, in: after) { other.mute(true) }
            if !on, AwakeSites.match(there, in: before), !AwakeSites.match(there, in: after) { other.mute(false) }
        }
    }

    /// The space a tab of this window's is in: the one on screen, or the
    /// one it is parked with.
    func spaceHolding(_ tab: Tab) -> UUID? {
        if tabs.contains(where: { $0 === tab }) { return spaceID }
        return parked.first { $0.value.tabs.contains { $0 === tab } }?.key
    }

    /// The space a visit in this tab counts for (History.frequent).
    func visitSpace(_ tab: Tab) -> UUID? { spaceHolding(tab) }

    /// The Space a password saved on this tab is kept in, and whose logins
    /// its sign-in boxes offer first (SuggestRows.away): one of the Spaces,
    /// never Mail's or the shared pins', and none while Spaces are off.
    func loginSpace(_ tab: Tab) -> UUID? {
        guard prefs.usesSpaces, let id = spaceHolding(tab), spaces.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Every Space's emoji and name, for a login saved in another.
    var loginSpaceNames: [UUID: String] {
        Dictionary(spaces.map { ($0.id, $0.icon.isEmpty ? $0.name : $0.icon + " " + $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - taking things off pages

    let curtain = Curtain.shared
    let loot = Loot()
    /// Downloads under way, and the button that shows them. See Hoard.swift.
    let hoard = Hoard()
    let floater = Floater()
    /// Tabs on a call, and what is kept about them (Calls.swift).
    let calls = Calls()
    /// True while the pointer is picking things to hide.
    private(set) var veiling = false {
        willSet { relay.send(\.veiling, newValue) }
    }

    var hereHost: String? { curtain.host(of: active?.address) }
    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        guard let tab = active, !tab.isBlank else { return }
        if veiling {
            veiling = false
            tab.stopPicking()
        } else {
            veiling = true
            tab.startPicking()
        }
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        if let tab = active, BoostEditor.shared.owns(tab), let last = BoostEditor.shared.look.hidden.last {
            BoostEditor.shared.restoreGroup(last)
            return
        }
        guard let host = hereHost, curtain.undo(on: host) != nil else { return }
        // It comes back on the page, where the eye already is.
        redress()
    }

    /// The pointer resting on a row of what is hidden here (Site Controls)
    /// brings that one thing back, outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        active?.unpeek(curtain.css(on: hereHost))
    }

    func restore(_ veil: Veil) {
        guard let host = hereHost else { return }
        curtain.restore(veil, on: host)
        redress()
    }

    func restoreAll() {
        guard let host = hereHost else { return }
        curtain.restoreAll(on: host)
        redress()
    }

    /// Both the page in front of you and the one that loads next time.
    private func redress() {
        guard let tab = active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    // MARK: - passwords

    /// A password offer's mark in the air between the pill and its tab.
    /// See Keep.swift.
    let keySky = KeySky()
    /// Where the page in front's card stands, for the corner's notice to
    /// come out under it (AskRoom).
    let askRoom = AskRoom()
    /// The notes a tab sings when it starts to play out of sight.
    let chorus = Chorus()

    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is, a list hangs from it, and a click fills the form.
    /// An empty sign-in field can take the last account used here; the list
    /// remains available when a different account is wanted.
    var suggesting: Suggesting? {
        willSet { relay.send(\.suggesting, newValue) }
        didSet {
            if oldValue?.tab != suggesting?.tab || oldValue?.logins != suggesting?.logins
                || oldValue?.list.map(\.id) != suggesting?.list.map(\.id) {
                lit = suggesting?.list.firstIndex(where: \.pickable)
            }
        }
    }
    /// Yab's plate inside the sign-in box (ManagerSuggestions.swift).
    var fieldPlate: FieldPlate? {
        willSet { relay.send(\.fieldPlate, newValue) }
    }
    /// An agent filling a sign-in from a manager, said under the box.
    var agentFilling: AgentFilling? {
        willSet { relay.send(\.agentFilling, newValue) }
    }
    /// The row Return takes: the first as the list comes up, the likeliest,
    /// then wherever the arrow keys put it. With no list, Return is the page's.
    private(set) var lit: Int? {
        willSet { relay.send(\.lit, newValue) }
    }

    /// The cards or addresses kept, hanging from the box a card or an
    /// address goes in (WalletKeep.swift), and the row the arrows are on.
    var walletList: WalletChoices? {
        willSet { relay.send(\.walletList, newValue) }
        didSet {
            if oldValue?.tab != walletList?.tab || oldValue?.group != walletList?.group {
                walletLit = walletList == nil ? nil : 0
                walletChosen = false
            }
        }
    }
    var walletLit: Int? {
        willSet { relay.send(\.walletLit, newValue) }
    }
    /// The codes a site just sent, hanging from the box that asks for one
    /// (MailCodes.swift), and the row Return takes.
    var codeList: CodeChoices? {
        willSet { relay.send(\.codeList, newValue) }
        didSet { if oldValue?.tab != codeList?.tab { codeLit = codeList == nil ? nil : 0 } }
    }
    var codeLit: Int? {
        willSet { relay.send(\.codeLit, newValue) }
    }
    let codeWatch = CodeWatch()
    /// A page's pending file answer and its Mac picker (FormFiles.swift).
    @ObservationIgnored var fileAnswer: (([URL]?) -> Void)?
    /// Opened in the folder given, else where this site's file last came from.
    @ObservationIgnored var filePanel: ((URL?) -> Void)?
    /// The tab a file is asked for, and its page's frame; no frame when Yab asks (the chat's +).
    @ObservationIgnored var fileRequest: (tab: Tab.ID, frame: PageFrame?)?
    @ObservationIgnored var fileVersion = 0
    @ObservationIgnored var fileSearch: FileSearch?
    @ObservationIgnored var fileSearchWork: DispatchWorkItem?
    /// Observed: the field's rows draw a tick on each file chosen.
    var fileSelected: Set<String> = []
    @ObservationIgnored var fileNativeRequest: PageFileRequest?
    @ObservationIgnored var fileScanID: UUID?
    @ObservationIgnored var fileRowsLoading = false
    @ObservationIgnored var fileOpening = false
    /// A row was come to with the arrows or the pointer, not only lit as
    /// the list came up (walletShown).
    var walletChosen = false {
        willSet { relay.send(\.walletChosen, newValue) }
    }
    /// The box the caret is in holds nothing yet.
    var walletBoxEmpty = true {
        willSet { relay.send(\.walletBoxEmpty, newValue) }
    }
    @ObservationIgnored var walletLowering: DispatchWorkItem?

    struct Suggesting: Equatable {
        let tab: Tab.ID
        let spot: CGRect
        let logins: [Login]
        /// The page the list was made for, as `site` spells it: its host,
        /// after http:// when it came in the clear. A pick fills only a page
        /// that still is that one.
        let site: String
        /// The page dark under the box, so the list is too.
        var dark: Bool? = nil
        /// Every row, from every source (ManagerSuggestions.swift); empty
        /// for a list of Yab's logins alone, made from `logins`.
        var rows: [SuggestRow] = []
        /// The page came over plain http: a quiet line under the list.
        var insecure = false
        /// The box's Space and every Space's name: another Space's logins
        /// come last, dimmed (SuggestRows.away).
        var here: UUID? = nil
        var spaces: [UUID: String] = [:]

        /// The rows shown.
        var list: [SuggestRow] {
            rows.isEmpty ? SuggestRows.build(.init(yab: logins, host: site, here: here, spaces: spaces)) : rows
        }
    }
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    @ObservationIgnored var pickedInto: Tab.ID?
    /// The box whose plate was pressed: its list shows even when all it
    /// says is that nothing is kept for the site.
    @ObservationIgnored var plateAsked: (tab: Tab.ID, field: String?)?
    /// The accounts for the site whose box the caret is in, read once when
    /// it arrives: each is a keychain read, and the list is narrowed again
    /// on every keystroke.
    @ObservationIgnored private var kept: (tab: Tab.ID, host: String, logins: [Login])?
    /// Keychain can wait on securityd even when it may not show a prompt.
    /// A field's focus must return to WebKit while that lookup waits.
    private let loginQueue = DispatchQueue(label: "yab.login-suggestions", qos: .utility)
    @ObservationIgnored private var loginLookup: String?
    @ObservationIgnored private var loginWaiting: (tab: Tab.ID, address: URL?, site: String)?
    @ObservationIgnored private var savedLoginsRevision = 0
    var loginLookupPending: Bool { loginLookup != nil }

    private func lookUpLogins(_ host: String) {
        guard loginLookup == nil else { return }
        loginLookup = host
        let revision = savedLoginsRevision
        // A controlled wait in isolated tests proves the page and native
        // window keep answering while the unchanged Keychain read waits.
        let asked = Store.testing ? Double(ProcessInfo.processInfo.environment["YAB_TEST_LOGIN_LOOKUP_DELAY"] ?? "") : nil
        let delay = asked.map { $0.isFinite ? min(5, max(0, $0)) : 0 } ?? 0
        loginQueue.async { [weak self] in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let logins = Vault.logins(matching: host)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                loginLookup = nil
                if revision != savedLoginsRevision {
                    if let wanted = loginWaiting, let tab = autofillTab(wanted.tab),
                       tab.fieldAddress == wanted.address, tab.fieldSpot != nil,
                       let currentHost = curtain.host(of: tab.fieldAddress) {
                        lookUpLogins(currentHost)
                    }
                    return
                }
                guard let wanted = loginWaiting, let tab = autofillTab(wanted.tab),
                      offersAutofill(tab), tab.fieldAddress == wanted.address,
                      !tab.gone, !tab.asleep, tab.builtPage != nil,
                      prefs.fillsPasswords, prefs.usesYabPasswords, !tab.fieldCode, let spot = tab.fieldSpot,
                      pickedInto != tab.id, let currentHost = curtain.host(of: tab.fieldAddress)
                else { return }
                let clear = tab.fieldAddress?.scheme?.lowercased() == "http"
                let site = (clear ? "http://" : "") + currentHost
                guard site == wanted.site else { return }
                // One read at a time, with only the newest field waiting.
                // Visiting other hosts cannot leave a backlog of reads.
                guard currentHost == host else {
                    lookUpLogins(currentHost)
                    return
                }
                loginWaiting = nil
                kept = (tab.id, site, logins.filter { !clear || $0.clear })
                // Read the current field and typed text again. An old focus
                // event cannot fill a field that has since gone or moved.
                tab.onField?(tab, spot)
            }
        }
    }
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    @ObservationIgnored private var lowering: DispatchWorkItem?

    /// One of the accounts in the list, picked by name.
    func choose(_ login: Login) {
        lowering?.cancel()
        guard let list = suggesting, let tab = autofillTab(list.tab) else { return }
        suggesting = nil
        // The tab may have gone somewhere else while the list was up, a
        // redirect, a script: what was offered for one site is never put
        // into another's page.
        let clear = tab.fieldAddress?.scheme?.lowercased() == "http"
        guard let host = curtain.host(of: tab.fieldAddress), (clear ? "http://" : "") + host == list.site else { return }
        pickedInto = tab.id
        fieldPlate = nil
        tab.namedAccount(login.user, on: host)
        tab.fill(user: login.user, password: login.password, caret: true) { [weak self] filled in
            switch filled {
            case .filled:
                Vault.touch(login)
                self?.markFilled(tab, from: "Yab")
            case .gone: self?.toaster.pop("The sign-in fields are gone", mark: "exclamationmark.triangle")
            case .refused: break
            case .unasked: self?.cantAskToFill()
            }
        }
    }

    /// Settings asks for Touch ID before filling and the Mac couldn't put
    /// the question: nothing went in, and nobody said no, so it is said.
    func cantAskToFill() {
        announce("Couldn't ask for \(Vault.proof), nothing filled", mark: "key")
    }

    func dropChoice() { suggesting = nil }

    /// The list asked for again (a test world staged): as the box reports.
    func reopenList(_ id: Tab.ID) {
        if pickedInto == id { pickedInto = nil }
        refreshField(id)
    }

    /// The plate in the box pressed: the list again, even after a pick, and
    /// even when nothing is kept for the site.
    func pressPlate(_ id: Tab.ID) {
        plateAsked = (id, autofillTab(id)?.fieldIdentity)
        reopenList(id)
    }

    /// ↑ and ↓ in the list, round the ends, over the rows that take a pick.
    func moveChoice(_ by: Int) {
        guard let rows = suggesting?.list, rows.contains(where: \.pickable) else { return }
        let count = rows.count
        var at = lit ?? (by > 0 ? -1 : count)
        repeat { at = ((at + by) % count + count) % count } while !rows[at].pickable
        lit = at
    }

    /// The pointer on a row lights it, as the arrows do, so one row is lit
    /// and Return takes the one it shows.
    func pointChoice(_ at: Int) {
        if let rows = suggesting?.list, rows.indices.contains(at), rows[at].pickable { lit = at }
    }

    /// Return on a lit row. False when nothing is lit, so the key goes on.
    func chooseLit() -> Bool {
        guard let lit, let rows = suggesting?.list, rows.indices.contains(lit), rows[lit].pickable else { return false }
        chooseRow(rows[lit])
        return true
    }

    /// The other browser's history, into this one's. Off the main thread for
    /// the reading and the keying; only the last merge is on it.
    func takePlaces(from source: Chromium.Source, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = Chromium.places(in: source)
            let gathered = History.gather(places)
            // Brought in: its visits from now on are read too (OtherHistory).
            OtherHistory.brought(source.name)
            DispatchQueue.main.async {
                Hangs.measure("history.merge") { self.history.take(gathered) }
                Diary.shared.absorb(self.history.everything())
                Task {
                    await self.history.flush()
                    done(places.count)
                }
            }
        }
    }

    /// Zen's or Firefox's history, the same way. Hands how many places it
    /// had to `done`.
    func takePlaces(from source: Firefox.Source, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = Firefox.places(in: source)
            let gathered = History.gather(places)
            DispatchQueue.main.async {
                Hangs.measure("history.merge") { self.history.take(gathered) }
                Diary.shared.absorb(self.history.everything())
                Task {
                    await self.history.flush()
                    done(places.count)
                }
            }
        }
    }

    /// The other browser's live sign-ins, its cookies, into WebKit's own
    /// store, so the sites it was signed in to open signed in here. Read,
    /// unwrapped and made into WebKit's cookies off the main thread; the
    /// store takes them on the main one, a few milliseconds of it at a time
    /// (CookiePour: a big profile's jar held it for seconds, crash #60).
    /// Hands back how many went in.
    ///
    /// A profile brought in as a space with sign-ins of its own (Space.
    /// signedInAs) signs that space in, not the shared store; `only`: just
    /// those profiles, for the spaces being brought. `keeping`: a cookie a
    /// store holds already, of the same name, domain and path, stays, so a
    /// space signed in here since isn't put back to the other browser's.
    func takeCookies(from source: Chromium.Source, only: Set<String>? = nil, keeping: Bool = false,
                     then done: @escaping (Int) -> Void) {
        guard source.credentialAccess else { done(0); return }
        DispatchQueue.global(qos: .userInitiated).async {
            // One read, the keychain asked once. Each source profile keeps
            // its own account, even when it had no tabs to bring across.
            let found = (try? Chromium.cookiesByProfile(in: source, only: only)) ?? [:]
            let names = TabImport.profileNames(in: source)
            CookiePour.convert(found) { made in
                let reads = self.cookieWork(made, names: names, from: source)
                let all = reads.flatMap { space, cookies in
                    let store = space.map { Spaces.store(for: $0) } ?? Store.websites
                    return cookies.map { (store, $0) }
                }
                Hangs.phase("cookies.set")
                guard keeping, !all.isEmpty else { CookiePour.pour(all, then: done); return }
                Task { @MainActor in
                    var held: [ObjectIdentifier: Set<String>] = [:]
                    for (store, _) in all where held[ObjectIdentifier(store)] == nil {
                        held[ObjectIdentifier(store)] = Set(await store.httpCookieStore.allCookies().map(Browser.cookieKey))
                    }
                    CookiePour.pour(Browser.unset(all, held: held), then: done)
                }
            }
        }
    }

    /// A cookie as a store tells one from another: its name, domain and path.
    nonisolated static func cookieKey(_ cookie: HTTPCookie) -> String {
        [cookie.name, cookie.domain.lowercased(), cookie.path].joined(separator: "\u{1F}")
    }

    /// The cookies of `work` whose store holds none of their key yet.
    nonisolated static func unset<Holder: AnyObject>(_ work: [(Holder, HTTPCookie)], held: [ObjectIdentifier: Set<String>]) -> [(Holder, HTTPCookie)] {
        work.filter { !(held[ObjectIdentifier($0.0)]?.contains(cookieKey($0.1)) ?? false) }
    }

    /// Takes in a CSV as Google Password Manager exports one. The file is read
    /// once and never copied; the keychain writes, a call or two a row, are
    /// off the main thread.
    /// `message`: what the panel says the file is, Zen's or Firefox's own
    /// export when that is the one asked for.
    func importPasswords(message: String = "A passwords CSV from Chrome, Dia or Google Password Manager") {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let text = HistoryFile.text(of: url) else {
                DispatchQueue.main.async { self.announce("Can't read that file", mark: "exclamationmark.triangle") }
                return
            }
            let result = Vault.take(csv: text)
            DispatchQueue.main.async {
                var said = "\(result.kept) passwords saved"
                if result.changed > 0 { said += ", \(result.changed) changed" }
                if result.skipped > 0 { said += ", skipped \(result.skipped)" }
                self.announce(said, mark: "tray.and.arrow.down", feedback: result.kept + result.changed > 0 ? .success : nil)
            }
        }
    }

    /// What is said when bookmarks come in, from a browser or a file.
    static func broughtLine(added: Int, held: Int, of count: Int, from name: String) -> String {
        if count == 0 { return "\(name) has no bookmarks" }
        let left = held == 1 ? "1 deleted left out" : "\(held) deleted left out"
        if added == 0 { return held > 0 ? "Nothing new, \(left)" : "All bookmarks already here" }
        let line = added == 1 ? "1 bookmark from \(name)" : "\(added) bookmarks from \(name)"
        return held > 0 ? line + ", " + left : line
    }

    /// A bookmarks file another browser exported, Safari's, Firefox's,
    /// anyone's: folders kept, filed into a folder named for the file, and
    /// merged there the way a browser's are when taken again.
    func importBookmarksFile(on corner: Toaster? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "A bookmarks file exported from Safari, Firefox or any other browser"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        takeBookmarks(file: url, on: corner)
    }

    /// Yab's bookmarks out to a file any browser takes in, in the usual
    /// bookmarks HTML format (BookmarkFile.write).
    func exportBookmarksFile(on corner: Toaster? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "Bookmarks.html"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeBookmarks(to: url, on: corner)
    }

    /// How many bookmarks went into the file at `url`, nil when it couldn't
    /// be written.
    @discardableResult
    func writeBookmarks(to url: URL, quiet: Bool = false, on corner: Toaster? = nil) -> Int? {
        let count = bookmarks.count
        do {
            try BookmarkFile.write(bookmarks.roots).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            if !quiet { announce("Couldn’t write the file", mark: "exclamationmark.triangle", on: corner) }
            return nil
        }
        if !quiet { announce(count == 1 ? "1 bookmark exported" : "\(count) bookmarks exported", mark: "square.and.arrow.up", on: corner) }
        return count
    }

    /// Hands how many pages came in to `done`, nil when the file wasn't a
    /// bookmarks file, on the main thread.
    func takeBookmarks(file url: URL, quiet: Bool = false, on corner: Toaster? = nil,
                       then done: @escaping (Int?) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = HistoryFile.text(of: url)
            let found = text.flatMap(BookmarkFile.parse)
            let name = BookmarkFile.name(for: url, text: text ?? "")
            let brought = Bookmarks.brought(from: name)
            DispatchQueue.main.async {
                guard let found else {
                    if !quiet { self.announce("Not a bookmarks file", mark: "exclamationmark.triangle", on: corner) }
                    done(nil)
                    return
                }
                let took = self.bookmarks.take(found, from: name, brought: brought)
                if !quiet { self.announce(Browser.broughtLine(added: took.added, held: took.held, of: Bookmarks.count(found), from: name), mark: "tray.and.arrow.down", feedback: took.added > 0 ? .success : nil, on: corner) }
                done(took.added)
            }
        }
    }

    /// A history export: Safari's, as its Export Browsing Data writes it,
    /// or a CSV with addresses, titles and times. It only adds (see
    /// History.add): nothing kept here is changed by it.
    func importHistoryFile(on corner: Toaster? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "History exported from Safari (History.json), or a CSV of addresses and visit times"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        takePlaces(file: url, on: corner)
    }

    /// Read and sorted into places off the main thread; only the adding is
    /// on it. Hands how many places were new to `done`, nil when the file
    /// held no history.
    func takePlaces(file url: URL, quiet: Bool = false, on corner: Toaster? = nil,
                    then done: @escaping (Int?) -> Void = { _ in }) {
        DispatchQueue.global(qos: .userInitiated).async {
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let places = HistoryFile.text(of: url).flatMap { HistoryFile.places(in: $0, fallback: written) } ?? []
            let gathered = History.gather(places)
            // The history page's own store takes them too; a page already
            // there is left alone.
            let traces = gathered.traces
            DispatchQueue.main.async {
                guard gathered.count > 0 else {
                    if !quiet { self.announce("No history in that file", mark: "exclamationmark.triangle", on: corner) }
                    done(nil)
                    return
                }
                let added = Hangs.measure("history.add") { self.history.add(gathered) }
                Diary.shared.absorb(traces)
                Task {
                    await self.history.flush()
                    if quiet { return done(added) }
                    switch added {
                    case 0: self.announce("Nothing new in that file", mark: "clock.arrow.circlepath", on: corner)
                    case 1: self.announce("1 place added to history", mark: "clock.arrow.circlepath", feedback: .success, on: corner)
                    default: self.announce("\(added) places added to history", mark: "clock.arrow.circlepath", feedback: .success, on: corner)
                    }
                    done(added)
                }
            }
        }
    }

    // MARK: - what is kept, and getting rid of it

    /// Everything one site keeps on this Mac, in both engines, whichever
    /// shows it now. The cookies go with it, so it signs you out of it.
    func forgetSite(_ site: String, tab: Tab) async {
        let store = tab.pageStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { record in
            let name = record.displayName.lowercased()
            return name == site || name.hasSuffix("." + site) || site.hasSuffix("." + name)
        }
        await store.removeData(ofTypes: types, for: mine)
        // WebKit's is gone: Chromium's, if it couldn't go now, goes before
        // that sign-in's next Chromium page, and nothing comes back from it.
        if !(await ChromiumSiteData.forget(site: site, store: store, page: tab.builtPage as? ChromiumPage, address: tab.address)) {
            ChromiumClearingDebt.owe(site, store: store)
        }
        // A certificate it was excused for asks again.
        CertificateExceptions.forget(site: site, in: store)
        // Its service workers went with it, and their push subscriptions.
        WebPush.shared.drop(site: site)
    }

    /// Cookies, caches, local storage, everything a site left on this Mac.
    /// Clearing it signs you out of everything, which is the point.
    func clearSites(on corner: Toaster? = nil) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        Task { @MainActor [weak self] in
            for store in ChromiumSiteData.stores { await store.removeData(ofTypes: types, modifiedSince: .distantPast) }
            let whole = await ChromiumSiteData.clear([.cookies, .cache]) { ChromiumClearingDebt.owe(ChromiumClearingDebt.everything, store: $0) }
            EngineStorageCarry.forgetAll(stores: ChromiumSiteData.stores)
            self?.announce(whole ? "Signed out everywhere" : "Some sites could not be signed out", mark: "cookie",
                           feedback: whole ? .success : nil, on: corner)
        }
    }

    /// Only what was fetched to draw pages, not what identifies you.
    func clearCache(on corner: Toaster? = nil) {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        Task { @MainActor [weak self] in
            for store in ChromiumSiteData.stores { await store.removeData(ofTypes: types, modifiedSince: .distantPast) }
            let whole = await ChromiumSiteData.clear([.cache])
            self?.announce(whole ? "Cache cleared" : "Some of the cache could not be cleared", mark: "broom",
                           feedback: whole ? .success : nil, on: corner)
        }
    }

    func clearHistory(on corner: Toaster? = nil) {
        history.forget()
        Diary.shared.forgetEverything()
        // What agents found in the places you go, snippets of mail and
        // drafts among it, goes with the record of going there.
        Hints.shared.forgetFound()
        // It names pages deleted from the bookmarks, which is history too.
        Bookmarks.forgetBrought()
        // Chromium keeps its own record for visited links, and what was typed.
        Task { @MainActor [weak self] in
            let whole = await ChromiumSiteData.clear([.history, .downloads, .forms])
            self?.announce(whole ? "History cleared" : "Some history could not be cleared", mark: "clock.arrow.circlepath",
                           feedback: whole ? .success : nil, on: corner)
        }
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices(on corner: Toaster? = nil) {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") {
            Store.settings.removeObject(forKey: key)
        }
        announce("Camera and mic choices reset", mark: "mic", feedback: .success, on: corner)
    }

    // MARK: - pinning

    /// The pinned tab whose letter is being typed over, in place. There is no
    /// dialog: pinning happens at once, with a letter guessed from the address,
    /// and that letter arrives selected so the next keystroke replaces it.
    var editingPin: Tab.ID? {
        willSet { relay.send(\.editingPin, newValue) }
    }

    /// Counted, not collected: the row asks this several times each time it
    /// is drawn, and a filtered copy of two hundred tabs each time was
    /// most of what drawing the row cost.
    var pinnedCount: Int { tabs.reduce(0) { $0 + ($1.pin != nil ? 1 : 0) } }

    /// The tab pinned, or for a half of a pair a new square on its page
    /// (`pinStandIn`): the one now in the grid. `apart`: the tab itself,
    /// out of its pair, as an agent asking for that tab pinned means it.
    @discardableResult
    func pin(_ tab: Tab, apart: Bool = false) -> Tab? {
        if startsArranging { return arranging { pin(tab, apart: apart) } }
        guard !Agents.shared.sealed(tab), !blank else { return nil }
        // A half of a pair, as Arc does: the split stays on screen, the
        // half in it now the pin's copy, and the pin is a square of its own
        // on the same page, never in the pair, so a pin shared with every
        // space never takes the pair along.
        if !apart, tab.pin == nil, pair(of: tab.id) != nil, let square = pinStandIn(for: tab) {
            var row = tabs
            row.insert(square, at: min(pinnedCount, row.count))
            tabs = row
            return pin(square)
        }
        if tab.agent != nil { folderBook.keep(tab) }
        if tab.pin == nil {
            // A pin is a square of its own: out of any pair first.
            if !pairs.isEmpty { pairs.removeAll { $0.contains(tab.id) } }
            tab.pin = tab.monogram
            tab.kept = false
            tab.nest = nil
            // In a space that shows the shared pins, one of them, in every
            // space and window (SharedPins.swift).
            if showsShared(spaceID), Browser.sharable(tab) { tab.everywhere = tab.id }
            // Pinned tabs live at the head of the row, in the order they were
            // pinned, so their letters never move under your hand.
            if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
                let home = max(0, pinnedCount - 1)
                if here != home {
                    tabs.move(
                        fromOffsets: IndexSet(integer: here),
                        toOffset: home > here ? home + 1 : home
                    )
                }
            }
        }
        // No dialog and no waiting cursor: the letter is taken from the
        // address and applied. Changing it is a separate act, for the day it
        // matters, which is why it is not folded into this one.
        writeSession(now: true)
        // A calendar, pinned: its next meeting on it, if you'd like.
        offerMeetings(for: tab)
        return tab
    }

    /// The square pinning a half of a pair makes: a new tab on the half's
    /// page, asleep until it is clicked, the half itself left in the pair.
    func pinStandIn(for tab: Tab) -> Tab? {
        guard !tab.isBlank, let url = tab.address else { return nil }
        let square = Tab(configuration: configuration(for: url))
        prepare(square)
        square.restore(url: url, title: tab.title)
        square.name = tab.name
        return square
    }

    /// Pin Tab: what is picked pinned, or unpinned when all of it is already.
    func togglePin() {
        // A split's shortcut has the same scope as its context menu,
        // including when both chips are picked.
        if let pair = pair(of: activeID), chosen.allSatisfy({ pair.contains($0.id) }) {
            if pinPair(of: pair.first) != nil { unpinPair(pair) } else { pinPair(pair) }
            return
        }
        if several {
            let group = chosen
            if group.contains(where: { $0.pin == nil && !$0.isBlank }) { pin(group) } else { unpin(group) }
        } else if let tab = active {
            if tab.pin != nil { unpin(tab) } else if !tab.isBlank { pin(tab) }
        }
    }

    /// ⌃⌘R: the open tab's name typed over, or a pin's letter.
    func renameActive() {
        guard let tab = active else { return }
        if tab.pin != nil { editLetter(tab) } else if !tab.isBlank { beginTabEdit(tab) }
    }

    /// Change Letter, from the menu or the rename shortcut.
    func editLetter(_ tab: Tab) {
        guard tab.pin != nil else { return }
        holdArranging()
        editingPin = tab.id
    }

    /// Typed into the square. Empty leaves the letter as it was, a pinned tab
    /// with nothing on it would be a blank square you could never identify.
    func letter(_ typed: String, for tab: Tab) {
        guard let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return
        }
        tab.pin = String(first).uppercased()
    }

    func endPinEdit() {
        guard editingPin != nil else { return }
        editingPin = nil
        writeSession(now: true)
        letGoArranging()
    }

    /// The mail pin taken out of the row: closed as a tab is, not put down.
    func unpinMail(_ tab: Tab) {
        if !inMail, Browser.handMade, let at = tabs.firstIndex(where: { $0 === tab }) {
            did { [weak self] in
                guard let self else { return }
                MailCenter.shared.putPin(in: self)
                if let door = tabs.first(where: { $0.pin != nil && MailPage.isMail($0.pending ?? $0.address) }) { move(door, to: min(at, pinnedCount - 1)) }
            }
        }
        if !inMail { MailCenter.shared.pinTaken() }
        if editingPin == tab.id { editingPin = nil }
        tab.pin = nil
        tab.everywhere = nil
        close(tab)
        writeSession(now: true)
    }

    func unpin(_ tab: Tab) {
        if startsArranging { return arranging { unpin(tab) } }
        // A half of a pinned pair: the pair goes back to Today whole.
        if tab.pin != nil, let pair = pinPair(of: tab.id) { return unpinPair(pair) }
        // The mail pin is a door, not a page: unpinned, it goes, and stays
        // away (MailCenter.pinWanted).
        if tab.pin != nil, MailPage.isMail(tab.pending ?? tab.address) { unpinMail(tab); return }
        if editingPin == tab.id { editingPin = nil }
        tab.pin = nil
        // A shared pin unpinned is a tab of the space on screen, and goes
        // from every other space and window.
        tab.everywhere = nil
        defer { writeSession(now: true) }
        // Back out of the pinned block, to the head of today's tabs, under
        // the kept.
        if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
            let home = keptEnd
            if here != home {
                tabs.move(fromOffsets: IndexSet(integer: here), toOffset: home > here ? home + 1 : home)
            }
        }
        rememberSession()
    }

    // MARK: - a name of your own, in the tab itself

    /// A double-click names an ordinary tab; a pinned square returns to
    /// its pinned address. Change Letter stays in the pin's menu.
    private(set) var editingTab: Tab.ID? {
        willSet { relay.send(\.editingTab, newValue) }
    }
    /// The field is Edit…'s, a pin's or a kept tab's home being typed
    /// (PinnedHome.swift), not its name.
    private(set) var editingHome = false {
        willSet { relay.send(\.editingHome, newValue) }
    }
    var tabDraft = "" {
        willSet { relay.send(\.tabDraft, newValue) }
    }
    /// Kept across row redraws when the first click selects a different tab.
    @ObservationIgnored private var lastTabTap: (id: Tab.ID, at: TimeInterval)?

    /// An agent's tabs of mail's space opened as tabs, from their peek
    /// (⌘O, the knob) or with ⌘: their row goes to the tab after that, never
    /// a peek over it again.
    @ObservationIgnored var openedTasks: Set<Tab.ID> = []

    func tapTab(_ tab: Tab) {
        glance.drop()
        // An agent's tab under its task in mail's column: over the email,
        // live, as a link's peek; ⌘-click, or once it was opened, the tab
        // itself (MailTaskRows).
        if inMail, MailChat.isAgents(tab), tab.id != activeID {
            lastTabTap = nil
            guard !NSEvent.modifierFlags.contains(.command), !openedTasks.contains(tab.id) else {
                openedTasks.insert(tab.id)
                return select(tab)
            }
            return peekLive(tab)
        }
        guard !pick(tab) else {
            lastTabTap = nil
            return
        }
        // A pinned pair's square: both halves, a half put down back too.
        if let pair = pinPair(of: tab.id) {
            lastTabTap = nil
            return openPinPair(pair)
        }
        // The press's own time, not the moment this runs: a first click's
        // select can hold the main thread past the double-click interval in
        // a long session, and the second click then read as a new single.
        let event = NSApp.currentEvent
        let now = event.map { [.leftMouseUp, .leftMouseDown].contains($0.type) } == true
            ? event!.timestamp : ProcessInfo.processInfo.systemUptime
        let second = lastTabTap.map { $0.id == tab.id && now - $0.at < NSEvent.doubleClickInterval } == true
        lastTabTap = second ? nil : (tab.id, now)
        if second {
            if tab.id != activeID { select(tab) }
            if tab.pin != nil { goHome(tab) } else { beginTabEdit(tab) }
        } else {
            select(tab)
        }
    }

    func beginTabEdit(_ tab: Tab) {
        tabDraft = tab.label
        if editingHome { editingHome = false }
        editingTab = tab.id
        tabEditBegan()
    }

    /// The same field with a home in it, Edit…'s (Browser.beginHomeEdit).
    func beginTabEdit(_ tab: Tab, home: String) {
        tabDraft = home
        editingHome = true
        editingTab = tab.id
        tabEditBegan()
    }

    /// Each begin of the field, so the field takes the keys again when the
    /// same tab's edit is asked for twice, nothing it shows changing
    /// (TabAddressField.Coordinator).
    static let tabEditBegan = Notification.Name("YabTabEditBegan")
    @ObservationIgnored private(set) var editRound = 0
    /// When the last begin was, for how long its field took to come into a
    /// window and take the keys (TabAddressField, the bench's `kept`).
    @ObservationIgnored private(set) var editBeganAt: CFTimeInterval = 0

    private func tabEditBegan() {
        editRound += 1
        editBeganAt = CACurrentMediaTime()
        NotificationCenter.default.post(name: Self.tabEditBegan, object: self)
    }

    /// Empty gives the tab back its page's own title. In Edit…'s field,
    /// empty leaves the home as it was, and words that are no address are
    /// refused: the field shakes and stays.
    func commitTabEdit() {
        if startsArranging { return arranging { commitTabEdit() } }
        // A tab gone while it was edited (closed, moved away) leaves no
        // edit behind to hold Return, Tab and the agents' gates.
        guard let tab = self.tab(id: editingTab) else { return cancelTabEdit() }
        let typed = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if editingHome {
            guard typed.isEmpty || setHome(tab, typed: typed) else {
                refusals += 1
                return
            }
            editingTab = nil
            editingHome = false
            tabDraft = ""
            return
        }
        editingTab = nil
        tabDraft = ""
        tab.name = typed.isEmpty || typed == tab.title ? nil : typed
        writeSession(now: true)
    }

    func cancelTabEdit() {
        // Written only when a title was being edited: every write of a
        // published value has the window drawn again, changed or not, and
        // every change of space and of tab puts the edit down.
        if editingTab != nil { editingTab = nil }
        if editingHome { editingHome = false }
        if !tabDraft.isEmpty { tabDraft = "" }
    }

    // MARK: - saying so

    /// ⌘⇧C. The address, in the clipboard, and a line that says as much.
    /// `door`: the link beside the address was pressed, rather than ⇧⌘C or
    /// a menu.
    func copyAddress(_ target: Tab? = nil, door: Bool = false) {
        // A peek up: its page's, said in its own corner (PeekCorner).
        if target == nil, let url = peeking?.address {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Diary.shareable(url).absoluteString, forType: .string)
            NoticeFeedback.success.play()
            toaster.pop(keys: Teach.shared.keys(after: .copyAddress, action: .copyAddress))
            return
        }
        guard let url = (target ?? active)?.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diary.shareable(url).absoluteString, forType: .string)
        // The link pressed turns into a tick; the address itself stays
        // still, as Arc's does, and the corner says it, with the key after
        // the words until the key has been used.
        NoticeFeedback.success.play()
        if addressInView && door { copies += 1 }
        toaster.pop(keys: Teach.shared.keys(after: .copyAddress, action: .copyAddress))
    }

    /// Counts copies of the address, from the bar's link or ⇧⌘C alike, so
    /// the link turns into a tick for either.
    private(set) var copies = 0 {
        willSet { relay.send(\.copies, newValue) }
    }

    /// The address is somewhere on screen: the bar over the page, or the
    /// plate at the top of the column while the column is out, in its
    /// place or over the page.
    var addressInView: Bool {
        barShown || (sidePlated && (sideShown > 0 || sidePeek))
    }

    /// The address bar is up when asked for, with a page to stand over.
    /// Not over a new tab: there is no site to name, and the field in the
    /// middle is the whole of it. Native element fullscreen keeps this
    /// source window's layout while WebKit owns the page elsewhere.
    var barShown: Bool {
        // Two side by side: each half has its own, always.
        if splitShown { return true }
        guard let active, !active.isBlank else { return false }
        // Nor over Mail's own list: it is not a site, and its column
        // already says where you are (MailPage). A page opened from a
        // letter keeps it.
        if active.showsMail { return false }
        // A page in Developer Mode always has it: its whole address and
        // what it has logged are said there (DevMode.swift).
        return prefs.addressBar || active.isDev
    }

    /// `barShown` for a space not on screen, from its own tab in front:
    /// the pages that slide in (SpacePager) are plated as their space will
    /// stand, not as the one on screen, Mail's list, which never has it.
    func barShown(_ row: Parked?, travelling: [Tab]) -> Bool {
        guard let row, let id = row.active else { return false }
        if row.pairs.contains(where: { $0.first == id || $0.second == id }) { return true }
        guard let front = (row.tabs + travelling).first(where: { $0.id == id }), !front.isBlank, !front.showsMail else { return false }
        return prefs.addressBar || front.isDev
    }

    /// The band has the doors of the row's far end or the column's foot,
    /// back, forward, reload, the extensions: it is the address bar, or two
    /// halves each with its own. Developer Mode's band alone leaves them.
    var bandDoors: Bool { barShown && (splitShown || prefs.addressBar) }

    // MARK: - the bookmarks bar

    /// The bookmarks belong to the window, including while the field asks
    /// for its first page. Their shortcut must still show the row with no
    /// active tab. WebKit element fullscreen keeps its geometry intact.
    var shelfShown: Bool {
        prefs.bookmarkBar == .always
    }

    /// True while the row comes or goes by ⇧⌘B: the page is held at the
    /// size it had and carried, the way it is while the tabs change sides
    /// (see `Reshape`).
    private(set) var shelving = false {
        willSet { relay.send(\.shelving, newValue) }
    }
    /// How far up the row is as drawn, 0 to 1, animated while the layout
    /// is already where it ends: what stands under the row is drawn by the
    /// difference (see `ShelfCarry`). Only read
    /// while `shelving`; the rest of the time the row is where it is.
    private(set) var shelfUp: CGFloat = 0 {
        willSet { relay.send(\.shelfUp, newValue) }
    }
    /// The row gone from the layout and still lying where it stood, for
    /// the card to come up over.
    private(set) var shelfLeaving = false {
        willSet { relay.send(\.shelfLeaving, newValue) }
    }
    @ObservationIgnored private var shelvings = 0
    /// The mode Settings' switch asked for, in the frame before the row
    /// moves to it.
    private var shelfHeading: BookmarkBarMode? {
        willSet { relay.send(\.shelfHeading, newValue) }
    }
    /// What the row is set to, or on its way to: the switch shows this, so
    /// it turns when it is clicked, not a frame later after turning back.
    var bookmarkBarAsked: BookmarkBarMode { shelfHeading ?? prefs.bookmarkBar }

    /// The page is being held for a change of shape, any kind.
    var reshaping: Bool { turning || shelving || folding || stripMoving || splitting || splitHeld || devMoving || devSizing || chatMoving || chatSizing || (sideSizing && !prefs.sideShut) }

    /// Animated changes to the page's size: let WebKit lay out at the
    /// size the moving edge shows, rather than jump to it at the end.
    /// A dragged divider has its own tracking path; room made for a tab
    /// carried over the page is SplitPreview's own.
    /// A pair coming together or apart is one too: the half staying grew
    /// to the whole width and then jumped there all at once.
    var followingSize: Bool { turning || shelving || folding || stripMoving || splitting || devMoving || chatMoving }

    /// Dividers follow the hand directly. DevTools' room already moves on
    /// SwiftUI's curve too; do not start another curve at every new frame.
    /// WebKit coalesces these targets through the same coordinator.
    var trackingSize: Bool { splitHeld || devSizing || chatSizing || devMoving || (sideSizing && !prefs.sideShut) }

    /// The chat column is out on the right (ChatColumn.swift).
    var chatOpen = false {
        willSet { relay.send(\.chatOpen, newValue) }
    }
    /// The extension page sharing the chat column; native chat state remains
    /// intact while a panel is in front.
    var panelExtension: String? {
        willSet { relay.send(\.panelExtension, newValue) }
    }
    var panelTabID: Int? {
        willSet { relay.send(\.panelTabID, newValue) }
    }
    /// The exact page in the shared column: two sign-ins can have the
    /// same extension and tab IDs without owning the same panel.
    var panelContextID: String? {
        willSet { relay.send(\.panelContextID, newValue) }
    }
    /// True while it comes or goes: the page held, as for the errors sheet.
    var chatMoving = false {
        willSet { relay.send(\.chatMoving, newValue) }
    }
    @ObservationIgnored var chatMovement = ChatMovement()
    @ObservationIgnored var chatRestoration: ChatRestoration?
    /// The actual native column, so closing does not wait for SwiftUI's
    /// next layout after sleep or a display change.
    @ObservationIgnored weak var chatColumnView: ChatColumnView?
    /// How wide the column is, dragged by its edge as a split's divider is.
    var chatWidth: CGFloat = ChatLook.stored { willSet { relay.send(\.chatWidth, newValue) } didSet { ChatLook.dragged = chatWidth } }
    /// True while its edge is dragged: the viewport follows the newest
    /// width and waits for the final paint when the edge is let go.
    var chatSizing = false {
        willSet { relay.send(\.chatSizing, newValue) }
    }
    @ObservationIgnored var chatGrabbed: CGFloat?
    /// The chat kept in the column whatever tab is in front.
    var chatPinned: String? {
        willSet { relay.send(\.chatPinned, newValue) }
    }
    /// The chat last handed to the column, for a tab with none of its own.
    var chatShown: String? {
        willSet { relay.send(\.chatShown, newValue) }
        // A chat opened is a chat read.
        didSet { if let chatShown, chatShown != oldValue { Chats.shared.read(chatShown) } }
    }
    /// The column shows the chats kept rather than one of them.
    var chatHistory = false {
        willSet { relay.send(\.chatHistory, newValue) }
        didSet {
            if !chatHistory, chatArchive { chatArchive = false }
            if !chatHistory, chatUnread { chatUnread = false }
        }
    }
    /// The history shows only the chats with an answer not yet seen.
    var chatUnread = false {
        willSet { relay.send(\.chatUnread, newValue) }
    }
    /// The history shows the chats put away (Archived Chats) instead.
    var chatArchive = false {
        willSet { relay.send(\.chatArchive, newValue) }
    }
    /// The project's store, supplied separately by command tests.
    @ObservationIgnored var chatProjects = Projects.shared
    /// The project of chats the history shows in the list's place
    /// (ChatProjectScreen); a chat opened from it goes back to it.
    var chatProject: String? {
        willSet { relay.send(\.chatProject, newValue) }
    }
    /// The project's own card is out over it (ProjectCard).
    var chatProjectInfo = false {
        willSet { relay.send(\.chatProjectInfo, newValue) }
    }
    /// The project a new chat in the column starts in: its pill in the field.
    var chatNewProject: String? {
        willSet { relay.send(\.chatNewProject, newValue) }
    }
    /// New Project's sheet is out over the column.
    var chatProjectSheet = false {
        willSet { relay.send(\.chatProjectSheet, newValue) }
    }
    /// A new chat is being begun in the column: none shows until it starts.
    var chatFresh = false {
        willSet { relay.send(\.chatFresh, newValue) }
    }
    /// Counted up to put the cursor in the column's field.
    var chatFocus = 0 {
        willSet { relay.send(\.chatFocus, newValue) }
    }
    /// Words for the column's field to take: your own, back to be changed.
    /// They are the draft of the chat the column is on now (chatID), so a
    /// caller starting a new chat calls newChat() first: the field shows
    /// them once that chat is its own (ChatAttach).
    var chatDraft: String? {
        willSet {
            if let newValue { chatAttach.keep(newValue, for: chatID) }
            relay.send(\.chatDraft, newValue)
        }
    }
    /// One of your messages being edited in the column's field: Return
    /// sends from it, the turns after it gone; Esc leaves it as it was.
    var chatEditing: ChatEdit? {
        willSet { relay.send(\.chatEditing, newValue) }
    }
    /// The agent and model a new chat goes to, picked in the column's head;
    /// nil for the saved Chats and ⌘J default.
    var chatNext: ModelChoice? {
        willSet { relay.send(\.chatNext, newValue) }
    }
    /// The model picker up in the middle of the window (ModelPicker).
    var modelPicker: ModelPickerRequest? {
        willSet { relay.send(\.modelPicker, newValue) }
    }
    /// What the column's field carries besides its words.
    let chatAttach = ChatAttach()
    /// The drop zone shown without a drag, for the bench to see it.
    var chatDropShown = false {
        willSet { relay.send(\.chatDropShown, newValue) }
    }
    /// A tab carried over the column from the tabs (SplitDeck): let go,
    /// it is added to the chat.
    var chatTabOver = false {
        willSet { relay.send(\.chatTabOver, newValue) }
    }

    /// The Developer Tools card is out (DevTools.swift, DevMode.swift).
    var devOpen = false {
        willSet {
            if newValue { catchUpDevRoom() }
            relay.send(\.devOpen, newValue)
        }
    }
    var devPicking = false {
        willSet { relay.send(\.devPicking, newValue) }
        // Inspect mode over: the page has its mouse back (DevPicker).
        didSet { if !devPicking, oldValue { DevPicker.stop() } }
    }
    var devDetached = false {
        willSet { relay.send(\.devDetached, newValue) }
    }
    /// What the card shows: yab's lists or one of WebKit's tabs.
    /// Where it was last, in this window or the one before (DevMemory).
    var devPane: DevPane = DevMemory.pane {
        willSet { relay.send(\.devPane, newValue) }
        didSet { if devPane != oldValue, panelWanted == nil || devPane != .webkit(.elements) { DevMemory.pane = devPane } }
    }
    /// The panels extensions added to the inspector of the page the card
    /// looks at, React's Components and Profiler: in the head after Console.
    var devPanels: [DevPanel] = [] {
        willSet { relay.send(\.devPanels, newValue) }
    }
    /// The panel showing when its page's inspector went: shown again once
    /// the next page's inspector has it, Elements standing in till then.
    @ObservationIgnored var panelWanted: String? = DevMemory.panelWanted
    /// Where WebKit docks its inspector, in the card.
    @ObservationIgnored lazy var inspectorDock = InspectorDock(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
    @ObservationIgnored lazy var inspectorRelay: InspectorRelay = {
        let relay = InspectorRelay()
        relay.browser = self
        return relay
    }()
    /// How wide the room the card and the page share is, for the card's
    /// width beside the page (DevLook.width(in:)).
    var devRoomWidth: CGFloat = 1200 {
        willSet { relay.send(\.devRoomWidth, newValue) }
    }
    /// The room as last measured. With the card away only whether it
    /// would fit beside the page is read (`devSide`), so the window's
    /// body isn't made again on every frame of a window resize for a
    /// width nothing draws; the card coming out catches up first.
    @ObservationIgnored private var devRoomMeasured: CGFloat = 1200

    func measuredDevRoom(_ width: CGFloat) {
        devRoomMeasured = width
        guard abs(devRoomWidth - width) > 0.5 else { return }
        if devOpen || devMoving || DevLook.fitsBeside(devRoomWidth) != DevLook.fitsBeside(width) {
            devRoomWidth = width
        }
    }

    private func catchUpDevRoom() {
        if abs(devRoomWidth - devRoomMeasured) > 0.5 { devRoomWidth = devRoomMeasured }
    }
    /// Which of what went wrong the list shows (DevIssues.swift).
    var issueFilter: IssueFilter = .errors {
        willSet { relay.send(\.issueFilter, newValue) }
    }
    /// WebKit's console open under its other tabs, as Escape opens it.
    var devDrawer = false {
        willSet { relay.send(\.devDrawer, newValue) }
    }
    /// The tab whose page WebKit's inspector is docked in the card for.
    @ObservationIgnored weak var inspected: Tab?
    /// The tab whose page is heard for the card although it isn't local.
    @ObservationIgnored weak var listened: Tab?
    /// Its page has said it is ready; work waiting for that.
    @ObservationIgnored var inspectorLive = false
    @ObservationIgnored var inspectorWaiting: [() -> Void] = []
    /// True while the sheet comes, goes or changes sides: the page is held,
    /// as for ⌘S, and made its new size once they have arrived.
    var devMoving = false {
        willSet {
            if newValue { catchUpDevRoom() }
            relay.send(\.devMoving, newValue)
        }
    }
    /// True while its edge is dragged: the viewport follows the newest
    /// size and waits for the final paint when the edge is let go (DevEdge).
    var devSizing = false {
        willSet { relay.send(\.devSizing, newValue) }
    }
    /// The card's frame in the window, from its top left, for the bench.
    @ObservationIgnored var devCard: CGRect = .zero
    @ObservationIgnored var devMoves = 0

    /// ⇧⌘B. The row up for good, or back to what it was before.
    ///
    /// Done the way ⇧⌘S is: first the page is held, in a frame of its own;
    /// then the window is laid out once, where everything ends up, with no
    /// animation round it. The page and its paper draw their edge from
    /// where it was in Core Animation; the address bar, the only thing of
    /// ours on the card, is drawn a room off and brought back on the same
    /// curve; the row lies still under the card, uncovered as it moves off
    /// and covered as it comes back.
    /// Only this moves. A new tab coming and going under the "new tab"
    /// mode is the frequent path, and the row is simply there or not.
    func toggleBookmarkBar() { shelve(to: nil) }

    /// Settings' switch: the same carry as ⇧⌘B, to the mode it asks for.
    func setBookmarkBar(_ mode: BookmarkBarMode) {
        guard mode != bookmarkBarAsked else { return }
        shelve(to: mode)
    }

    private func shelve(to asked: BookmarkBarMode?) {
        shelvings += 1
        let turn = shelvings
        // Drawn where it stands now, before anything moves.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            shelfUp = shelfShown ? 1 : 0
            if let asked { shelfHeading = asked }
        }
        shelving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            // Decided here, not when asked: two quick presses are two
            // changes, the second undoing the first.
            let next: BookmarkBarMode = asked ?? (prefs.bookmarkBar == .always ? .never : .always)
            let was = shelfShown
            withTransaction(still) {
                prefs.bookmarkBar = next
                shelfLeaving = was && !shelfShown
                if shelvings == turn { shelfHeading = nil }
            }
            // In the same pass as the layout, so it starts in the frame the
            // page's own carry starts in, on the same curve.
            withAnimation(Motion.reshape) { shelfUp = shelfShown ? 1 : 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                guard shelvings == turn else { return }
                shelving = false
                shelfLeaving = false
            }
        }
    }

    /// The tab in front going from blank to somewhere, told to the window:
    /// the bar comes with the page, and the tab's doors move up into it. A
    /// tab is an object of its own, and nothing else here would say so.
    @ObservationIgnored private var blankWatch: AnyCancellable?

    /// Whether the page in front has the screen: a copy the window's body
    /// reads, changed only when it does (ContentView's frontImmersed).
    private(set) var frontImmersed = false

    private func watchBlank() {
        let immersed = active?.immersed == true
        if frontImmersed != immersed { frontImmersed = immersed }
        blankWatch = active?.changes(\.address)
            .map { $0 == nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // And the page in front taking the screen and giving it back: the
        // column lays itself out from `sideShown`, which reads it, but is
        // drawn in a host of its own that hears only the browser. Untold,
        // a column emptied as the page went full screen stayed empty after
        // it came back, until a click told the browser something (#46).
        immersedWatch = active?.changes(\.immersed)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] now in
                if self?.frontImmersed != now { self?.frontImmersed = now }
                self?.objectWillChange.send()
            }
    }
    @ObservationIgnored private var immersedWatch: AnyCancellable?

    /// Every notice the browser gives, "Link copied" to "Bookmarked", in
    /// the page's top right corner. Not published: see Toaster.
    let toaster = Toaster()

    /// ⇧⌘2: a part of the page, framed and on the clipboard (Capture.swift).
    @ObservationIgnored private(set) lazy var capture = Capture(self)

    /// ⌘A's offer on a page: copy it, as Markdown, or as a file for an
    /// agent (PageCopy.swift). Not published, for the same reason.
    let pageCopy = PageCopy()

    /// One thing said, in the corner every notice uses, with a mark for
    /// what it is about. `on` another corner, Settings' own, for what was
    /// done there: said where it was asked, not in the browser behind.
    func announce(_ text: String, mark: String = "info.circle", stay: TimeInterval? = nil,
                  feedback: NoticeFeedback? = nil, on corner: Toaster? = nil) {
        // A notice is a phrase, not a sentence: no full stop, whoever wrote it.
        (corner ?? toaster).pop(text.hasSuffix(".") ? String(text.dropLast()) : text, mark: mark, stay: stay, feedback: feedback)
    }

    /// A page wanted a passkey this build can't give: said once a site, in
    /// the corner, while you are looking at it (PasskeyHint).
    func passkeysMissing(_ tab: Tab, _ ask: PasskeyHint.Ask) {
        guard active === tab,
              PasskeyHint.shared.take(ask, at: tab.builtPage?.url, entitled: PasskeyHint.possible)
        else { return }
        toaster.pop(PasskeyHint.words(at: tab.builtPage?.url), mark: PasskeyHint.mark, stay: PasskeyHint.stay)
    }

    /// A setting changed: said only when it was changed from somewhere that
    /// doesn't show it, ⌘T or a menu. In Settings the switch itself answers.
    func announceSetting(_ text: String, mark: String) {
        if SettingsWindow.shared.window?.isKeyWindow == true { return }
        announce(text, mark: mark)
    }

    /// The names extensions asked their downloads to be saved under.
    @ObservationIgnored var namedDownloads: [URL: String] = [:]
    @ObservationIgnored var downloadNames: [ObjectIdentifier: String] = [:]

    /// Tabs you closed, newest last, so ⌘⇧T can put them back where they were
    /// and the History menu can offer them by name.
    private(set) var ghosts: [Ghost] = [] {
        willSet { relay.send(\.ghosts, newValue) }
    }
    /// The closed tabs whose last frame is kept for ⇧⌘T (PageStills, under
    /// the ghost's id), newest last.
    @ObservationIgnored var ghostStills: [UUID] = []
    /// Files a page started that nobody's click asked for, waiting on the
    /// one card that asks about them, by tab and site (askDownloads).
    @ObservationIgnored var manyAsking: [String: (card: UUID, waiting: [(Bool) -> Void])] = [:]
    /// Download folders macOS kept closed to Yab, already said (DownloadFolder).
    @ObservationIgnored var closedDownloadFolders = Set<String>()
    /// Kept tabs on their way out by hand (Kept.swift, discard), with the
    /// folder each was in, until their ghost is made.
    @ObservationIgnored var unkept: [Tab.ID: Nest?] = [:]
    /// And where each stood among the kept, taken before it leaves them:
    /// no longer kept, it drops under the line before it closes.
    @ObservationIgnored var unkeptAt: [Tab.ID: Int] = [:]
    /// What ⌘Z takes back in the window, newest last (WindowUndo.swift).
    @ObservationIgnored var steps: [UndoStep] = []
    /// The row before a drag or a letter being typed, until let go.
    @ObservationIgnored var heldShape: (shape: RowShape, at: CFTimeInterval)?
    @ObservationIgnored var arrangeDepth = 0
    /// The curve the column's next laying moves on, when an act asks for
    /// its own: a folder leaving for another space, on Arc's spring.
    @ObservationIgnored var columnCurve: ColumnMotion.Curve?
    /// Taking a step back: nothing done meanwhile is a step of its own.
    @ObservationIgnored var undoing = false

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int
        /// When it was closed: ⇧⌘T brings back a window closed after it.
        let at = Date()
        /// Shared by the tabs closed together, so ⌘⇧T brings them back
        /// together.
        var batch: UUID?
        /// The folder of today's it stood in, to go back into; for a kept
        /// tab, the folder of yours it was removed from.
        var nest: Nest? = nil
        /// Kept, and removed by hand (Remove from Folder, Close and Don't
        /// Keep): ⌘Z puts it back kept, in its folder.
        var kept = false
        /// Where it stood among the kept when it was removed, for ⌘Z and
        /// ⌘⇧T to keep it there again, not at the end (register #463).
        var keptAt: Int? = nil
        /// The page's own history when it went (Tab.history), so it comes
        /// back with Back still going back; nil starts from the address.
        var history: Any? = nil

        var label: String { title.isEmpty ? Address.pretty(url) : title }

        static func == (a: Ghost, b: Ghost) -> Bool {
            a.id == b.id && a.batch == b.batch && a.nest === b.nest && a.kept == b.kept
        }
    }

    /// A line of History › Recently Closed: one tab, or a folder closed with
    /// its tabs, which come back together into it.
    enum Closed: Identifiable {
        case tab(Ghost)
        case folder(Nest, [Ghost])

        var id: UUID {
            switch self {
            case .tab(let ghost): ghost.id
            case .folder(_, let group): group[0].id
            }
        }
    }

    /// Recently Closed, newest first: the tabs of a folder that went with
    /// them as one line, as Dia and Chrome list a closed group. Closing a
    /// few of a folder's tabs leaves it, so those stay a line each.
    var recentlyClosed: [Closed] {
        var lines: [Closed] = []
        var listed = Set<UUID>()
        for ghost in ghosts.reversed() {
            if let batch = ghost.batch, let (nest, group) = closedFolder(batch) {
                if listed.insert(batch).inserted { lines.append(.folder(nest, group)) }
            } else {
                lines.append(.tab(ghost))
            }
        }
        return lines
    }

    /// The folder a batch of ghosts was, all of it: two or more tabs, each
    /// in it or a folder inside it, and none of its tabs left in the row.
    private func closedFolder(_ batch: UUID) -> (Nest, [Ghost])? {
        let group = ghosts.filter { $0.batch == batch }
        let nests = group.compactMap(\.nest)
        guard group.count >= 2, nests.count == group.count,
              let outer = nests.filter({ outer in nests.allSatisfy { $0.within(outer) } })
                  .min(by: { $0.depth < $1.depth }),
              !tabs.contains(where: { $0.nest?.within(outer) == true }) else { return nil }
        return (outer, group.sorted { $0.index < $1.index })
    }

    @ObservationIgnored private var bag = Set<AnyCancellable>()
    /// Coming back to the app, or the Mac waking: when the tidy-up looks.
    /// See Tidy.swift.
    @ObservationIgnored var tidyWatch = Set<AnyCancellable>()
    /// The batches tidy-ups put away, latest last, so ⌘⇧T and the notice's
    /// Undo bring them back as they went: quietly, in place, nothing loaded.
    @ObservationIgnored var tidied: [UUID] = []
    @ObservationIgnored var clearedEmptyFolders: [UUID: (space: UUID, nests: [Nest])] = [:]
    /// "Cleared", with its Undo. Not published, like the toaster.
    let tidier = Tidier()
    /// Today's rows going to dust by Clear: hidden at once, put away once
    /// the dust has left them (Dust.swift).
    var dusting: Set<Tab.ID> = [] {
        willSet { relay.send(\.dusting, newValue) }
    }
    /// Rows of those that have given up their room, in Clear's wave.
    var dustFolded: Set<Tab.ID> = [] {
        willSet { relay.send(\.dustFolded, newValue) }
    }
    /// A folder's own row and its "N more" going with its tabs, by their
    /// keys in `drawnRows`, the same way.
    var dustingRows: Set<String> = [] {
        willSet { relay.send(\.dustingRows, newValue) }
    }
    var dustFoldedRows: Set<String> = [] {
        willSet { relay.send(\.dustFoldedRows, newValue) }
    }
    /// Tidy asked the model how today's tabs go together and hasn't heard
    /// yet: the line waves, its words away (TidyTabs.swift).
    var tabsTidying = false {
        willSet { relay.send(\.tabsTidying, newValue) }
    }
    /// Where the column's rows are drawn, for the dust to be taken from.
    let drawnRows = DrawnRows()
    /// The row closing up after the dust, at the pace of room rather than of
    /// a leaving. Read while drawing, like `tabsGrew`.
    @ObservationIgnored var dustLanding = false
    /// The column this window draws, for the dust to be laid over.
    @ObservationIgnored weak var column: ColumnView?
    /// Where the kept line and the scrolling rows are, in the window's
    /// SwiftUI space: written as they are laid out, read at the click.
    @ObservationIgnored var keptLine: CGRect?
    @ObservationIgnored var rowsClip: CGRect?
    /// The space's own part of the column, its pins' top and the top of
    /// the room over the foot, in the same space: what slides when the
    /// space changes (SpacePager).
    @ObservationIgnored var pinsTop: CGFloat?
    var spaceFloor: CGFloat? {
        // The column first laid out: the spaces beside this one made ahead
        // (SpacePager.prepare), for the first switch to find them.
        didSet { if oldValue == nil, spaceFloor != nil { SpacePager.shared.prepareSoon(self, after: 1.5) } }
    }
    /// The top of the space's name over its rows, in the same space: under
    /// the pins every space shares, where what slides starts while they
    /// stand still (SpacePager.hold).
    @ObservationIgnored var nameTop: CGFloat?
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    @ObservationIgnored var dozing: Timer?
    let stuck = StuckWatch()
    @ObservationIgnored var pressure: DispatchSourceMemoryPressure?
    /// A relief under way (see `relieve`), and the tabs it could not put
    /// down this time.
    @ObservationIgnored var relieving = false
    @ObservationIgnored var passedOver = Set<UUID>()
    /// When the first of `passedOver` was passed over, on the awake clock:
    /// they are asked again a while later (`reaskAfter`).
    @ObservationIgnored var passedOverSince: TimeInterval?
    /// The next look while memory stays short (`lookAgain`).
    @ObservationIgnored var nextLook: DispatchWorkItem?
    /// The window is gone (`stopWatching`): a relief under way looks no more.
    @ObservationIgnored var stoppedWatching = false
    /// The tabs you were last on, the one just left first (Sleep.swift:
    /// the few you go back and forth between are not put to sleep).
    @ObservationIgnored var recent: [Tab.ID] = []
    /// The tab ⌘W last landed on, while it is still the one in front: ⌘W
    /// again there goes to a neighbor, not further back (`close`).
    @ObservationIgnored var closeLanded: Tab.ID?
    /// The tab in front because ⌘W closed or put down the one before it,
    /// while it still is: not a tab you went to, so the column leaves its
    /// rows where you are in them (ColumnPage.follow, feedback #1916).
    @ObservationIgnored var closedOnto: Tab.ID?
    /// Downloads still under way. See `keep(_:)`.
    @ObservationIgnored var downloading: [any PageDownload] = []
    /// The page each download started from, noted as it starts: where its
    /// file came from, said in Downloads and written on the file.
    @ObservationIgnored var downloadPages: [ObjectIdentifier: (url: URL, title: String)] = [:]
    /// Where each download is being written, as it was given WebKit: a
    /// resumed one is never asked again and its progress has no file URL.
    @ObservationIgnored var downloadFiles: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored var downloadParts: [ObjectIdentifier: DownloadFile] = [:]
    /// Download Image's downloads, made portable once they are in
    /// (PictureFile).
    @ObservationIgnored var pictureDownloads = Set<UUID>()
    @ObservationIgnored var publishingDownloads = Set<UUID>()
    /// Captured before a consent/panel/permission wait and carried by Retry.
    /// A switch of Space or folder setting never redirects an in-flight file.
    @ObservationIgnored var downloadFolders: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored var chooseDownloadLocation: @MainActor (String, URL, @escaping @MainActor (URL?) -> Void) -> Void = {
        DownloadFolder.choose($0, in: $1, $2)
    }
    /// Only automatic destinations of user downloads may be tidied.
    @ObservationIgnored var tidyDownloadFiles: Set<ObjectIdentifier> = []
    @ObservationIgnored var downloadReplies: [ObjectIdentifier: DownloadReply] = [:]
    @ObservationIgnored var failedDownloadIDs = Set<UUID>()
    @ObservationIgnored var completedDownloadIDs = Set<UUID>()
    @ObservationIgnored var retryingDownloadIDs = Set<UUID>()
    /// The page whose navigation became each download, until the file is
    /// in: WebKit gives a download from a window a page opened the
    /// opener's view as its own, not the window's (closeIfOnlyFetched).
    @ObservationIgnored var downloadBecame: [ObjectIdentifier: () -> (any PageHandle)?] = [:]
    @ObservationIgnored var downloadFetching: [ObjectIdentifier: [URL?]] = [:]
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    @ObservationIgnored var storeWatch: AnyCancellable?
    /// The store pages extensions were added from, by extension id, for
    /// the icon to fly out of once the yes is given. See StoreRelay.swift.
    @ObservationIgnored var storeAskers: [String: WeakTab] = [:]
    @ObservationIgnored private var zoomShown = 100
    @ObservationIgnored private var remembering = false
    /// The first window's row as last written: tabs, their order, kept and
    /// pinned. A row that changed there (a tab opened, closed, moved, kept)
    /// is written at once, so sync carries it to the other devices in a
    /// moment (R8, Phone/Reference/digest/sync-ios.md); titles and the like
    /// wait out the second.
    @ObservationIgnored private var writtenShape: [String] = []
    @ObservationIgnored private var rushing = false
    /// The observer for `yab setup` turning agents on, removed with the window.
    @ObservationIgnored private var cliAllowed: NSObjectProtocol?

    deinit {
        if let cliAllowed { DistributedNotificationCenter.default().removeObserver(cliAllowed) }
    }

    // MARK: - beginning and ending

    init(windowID: UUID? = nil, purpose: BrowserWindowPurpose = .normal) {
        self.windowID = windowID
        self.windowPurpose = purpose
        blank = windowID.map(BlankWindow.marked) ?? false
        super.init()
        // The first window's browser with its properties made (Startup).
        if windowID == nil { Startup.mark("browser") }
        // Browser uses AppKit even when made before an application window,
        // as in a tool test. Do not depend on another test creating NSApp.
        _ = NSApplication.shared
        keySky.across = { [unowned prefs] in !prefs.sidebar }
        History.anyIndexReady.sink { [weak self] ready in
            guard let self, self.history === ready else { return }
            guard self.fieldShowing, !self.typed.isEmpty else {
                self.pendingHistorySubmit = nil
                return
            }
            self.guess()
            if let pending = self.pendingHistorySubmit {
                self.pendingHistorySubmit = nil
                if self.typed == pending.typed { self.submit(pending.way, copyingTabs: pending.copyingTabs) }
            }
        }.store(in: &bag)
        // What the app starts once a run comes with the first window, in
        // stages, each where it always was (AppStartup.swift).
        if windowID == nil { AppStartup.links(for: self) }
        hoard.browser = self
        if windowID == nil { AppStartup.services(for: self) }
        // `yab setup` in a terminal turns agents on while yab is open.
        cliAllowed = DistributedNotificationCenter.default().addObserver(forName: Cli.allowed, object: Bundle.main.bundleIdentifier, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prefs.bench = true }
        }
        if windowID == nil { AppStartup.skills() }
        // Hidden for agents, the welcome waits for someone to open yab.
        welcoming = windowID == nil && !prefs.welcomed && !Headless.on
        if windowID == nil { AppStartup.checks(for: self) }
        // A yes from an older build is no yes without the entitlement. A
        // test run may stand in for it: it never reaches macOS, only the
        // made-up answer (Passkeys.rehearsal).
        let rehearsing = Store.testing && ProcessInfo.processInfo.environment["YAB_TEST_PASSKEYS"] == "1"
        FormRelay.passkeysOffered = prefs.passkeys && (prefs.passkeysPossible || rehearsing)

        // The history's changes are not passed on as the browser's: the History
        // menu watches the history itself (RecentlyVisited), and nothing else
        // drawn from the browser reads it.
        if windowID == nil { AppStartup.desks(for: self) }
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: Spaces.changed)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.windowPurpose == .normal else { return }
                    let fresh = Spaces.read()
                    if self.spaces != fresh {
                        let previous = self.space.paint
                        let profiles = self.spaces.filter { old in fresh.contains { $0.id == old.id && $0.profileID != old.profileID } }
                        self.spaces = fresh
                        for old in profiles { self.reloadSpaceProfile(old.id, previouslyShared: !old.ownSignIns) }
                        if self.spaceID != Space.mailID, !fresh.contains(where: { $0.id == self.spaceID }) {
                            let enabled = self.prefs.usesSpaces
                            self.prefs.usesSpaces = true
                            self.switchSpace(to: self.homeSpaceID)
                            self.prefs.usesSpaces = enabled
                        }
                        if let paint = self.space.paint, paint != previous { paint.wear(self.prefs) }
                    }
                }
            }
            .store(in: &bag)
        // What this window wears and was not yet kept with its space (a
        // look card's change still settling, a welcome's look) is kept at
        // quit: the launch wears the space's kept look, not the window's.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.windowPurpose == .normal, self.prefs.usesSpaces else { return }
                    self.keepPaint()
                }
            }
            .store(in: &bag)

        if windowID == nil { AppStartup.icons(for: self) }
        // A page's video put out, by its own button or ⇧⌘P: into the window
        // of the browser it left.
        SitePiP.takers.add(self)
        fullscreenDeparture.start(for: self)
        // The little window's own three buttons.
        floater.onReturn = { [weak self] in
            self?.returnFloatingTab()
        }
        floater.onSkip = { [weak self] seconds, done in
            if let native = self?.picturing?.native {
                Task { @MainActor [weak self] in
                    if seconds.isFinite, seconds != 0, native.state.canSeek {
                        _ = await native.perform(seconds > 0 ? "seekForward" : "seekBackward", values: ["seconds": .number(abs(seconds))])
                    }
                    guard self?.picturing?.native === native else { return }
                    done()
                }
                return
            }
            guard let tab = self?.floatedTab else { return }
            Isolate.run("skip", seconds, on: tab.page) { _ in done() }
        }
        floater.onSeek = { [weak self] through, rough, done in
            if let native = self?.picturing?.native {
                Task { @MainActor [weak self] in
                    if through.isFinite, (0...1).contains(through), native.state.canSeek, let duration = native.state.duration {
                        _ = await native.perform("seek", values: ["seconds": .number(through * duration)])
                    }
                    guard self?.picturing?.native === native else { return }
                    done()
                }
                return
            }
            guard let tab = self?.floatedTab else { return done() }
            Isolate.run(rough ? "scrub" : "seek", through, on: tab.page) { _ in done() }
        }
        floater.onRetry = { [weak self] done in
            if self?.picturing?.native != nil { return done() }
            guard let tab = self?.floatedTab else { return done() }
            Isolate.run("retry", on: tab.page) { _ in done() }
        }
        floater.onWords = { [weak self] answer in
            if self?.picturing?.native != nil { return answer("") }
            guard let tab = self?.floatedTab else { return }
            Isolate.run("words", on: tab.page) { found in
                answer(found as? String ?? "")
            }
        }
        floater.onChapters = { [weak self] answer in
            if self?.picturing?.native != nil { return answer([]) }
            guard let tab = self?.floatedTab else { return answer([]) }
            Isolate.run("chapters", on: tab.page) { found in answer(Floater.Chapter.list(found)) }
        }
        floater.onRate = { [weak self] speed, answer in
            if let native = self?.picturing?.native {
                Task { @MainActor [weak self] in
                    guard speed.isFinite, (0.25...8).contains(speed), native.state.canRate,
                          let observed = await native.perform("rate", values: ["rate": .number(speed)]),
                          abs(observed.rate - speed) < 0.001 else {
                        if self?.picturing?.native === native { answer(nil) }; return
                    }
                    guard self?.picturing?.native === native else { return }
                    answer(observed.rate)
                }
                return
            }
            guard let tab = self?.floatedTab else { return answer(nil) }
            Isolate.run("rate", speed, on: tab.page) { found in answer((found as? NSNumber)?.doubleValue) }
        }
        floater.onSubtitles = { [weak self] choice, answer in
            if let native = self?.picturing?.native {
                Task { @MainActor [weak self] in
                    guard [-2, -1, 0].contains(choice), let initial = await native.refresh(), initial.captionsAvailable else {
                        if self?.picturing?.native === native { answer(nil) }; return
                    }
                    let observed: ChromiumVideoPiPState?
                    if choice == -2 { observed = initial }
                    else { observed = await native.perform("captions", values: ["enabled": .bool(choice == 0)]) }
                    guard let observed, choice == -2 || observed.captionsEnabled == (choice == 0) else {
                        if self?.picturing?.native === native { answer(nil) }; return
                    }
                    guard self?.picturing?.native === native else { return }
                    answer(Floater.Subtitles([observed.captionsEnabled ? 0 : -1, ["Track 1"]] as [Any]))
                }
                return
            }
            guard let tab = self?.floatedTab else { return answer(nil) }
            let own = {
                Isolate.run("subtitles", Double(choice), on: tab.page) { found in answer(Floater.Subtitles(found)) }
            }
            // YouTube's are its player's; anywhere else, the video's tracks.
            guard YouTube.runs(on: tab.address?.host()) else { return own() }
            let wanted = Floater.Subtitles.base(Locale.preferredLanguages.first ?? "en")
            let name = Locale(identifier: "en_US").localizedString(forLanguageCode: wanted) ?? wanted
            tab.page.call(Floater.youTubeSubtitles, arguments: ["choice": choice, "wanted": wanted, "wantedName": name],
                                        in: .page) { result in
                MainActor.assumeIsolated {
                    if case .success(let value) = result, let found = Floater.Subtitles(value) { answer(found) } else { own() }
                }
            }
        }
        floater.onProgress = { [weak self] answer in
            if let native = self?.picturing?.native {
                Task { @MainActor [weak self] in
                    let observed = await native.refresh()
                    guard self?.picturing?.native === native else { return }
                    answer(observed?.playhead)
                }
                return
            }
            guard let tab = self?.floatedTab else { return answer(nil) }
            // Always an answer, nothing included, so the window never
            // waits on a question nobody will reply to.
            Isolate.run("where", on: tab.page) { found in answer(Floater.Playhead(found)) }
        }
        floater.onPlayPause = { [weak self] answer in
            if let native = self?.picturing?.native {
                Task { @MainActor [weak self] in
                    let observed = await native.perform(native.state.paused ? "play" : "pause")
                    guard self?.picturing?.native === native else { return }
                    answer(!(observed ?? native.state).paused)
                }
                return
            }
            guard let tab = self?.floatedTab else { return }
            Isolate.run("toggle", on: tab.page) { playing in
                answer((playing as? Bool) ?? true)
            }
        }
        floater.onSound = { [weak self] in
            if let native = self?.picturing?.native { return native.state.muted }
            guard let tab = self?.floatedTab else { return nil }
            return tab.muted
        }
        floater.onMute = { [weak self] done in
            if let native = self?.picturing?.native {
                Task { @MainActor [weak self] in
                    let wanted = !native.state.muted
                    guard let observed = await native.perform("mute", values: ["enabled": .bool(wanted)]), observed.muted == wanted else {
                        if self?.picturing?.native === native { done(nil) }; return
                    }
                    guard self?.picturing?.native === native else { return }
                    done(observed.muted)
                }
                return
            }
            guard let tab = self?.floatedTab else { return done(nil) }
            // This control belongs to the floated video. Clear an older tab
            // mute if present, then change only that video's media element.
            let wasTabMuted = tab.muted
            if wasTabMuted { tab.mute(false) }
            Isolate.run("sound", wasTabMuted ? 1 : 0, on: tab.page) { value in
                done(value as? Bool)
            }
        }
        floater.onClose = { [weak self] in self?.land() }
        floater.onMinimize = { [weak self] in self?.minimizeFloat() }
        floater.onDismiss = { [weak self] in
            guard let self else { return }
            if let native = picturing?.native {
                Task { @MainActor [weak self] in
                    // The control already hid the panel. Always retire its
                    // owned native session, even if pause cannot be confirmed.
                    _ = await native.perform("pause")
                    guard let self, self.picturing?.native === native else { return }
                    self.land()
                }
                return
            }
            guard self.floater.kind == .video, let tab = self.floatedTab else { return self.land() }
            let id = tab.id
            // Closing PiP pauses the exact video still floated, including one
            // inside an iframe, and puts it back in its tab quietly: the tab
            // isn't chosen and the window isn't brought forward, you stay
            // where you are. Going to the tab is onReturn's, and keeps playing.
            Isolate.run("pause", on: tab.page) { [weak self] _ in
                guard let self, self.floating == id else { return }
                self.land()
            }
        }
        wireCallWindow()
        if windowID == nil { AppStartup.meetingsAndMail(for: self) }

        // Yesterday's tabs, or none and the field. Either way a web view is
        // built soon, which starts a content process while the window is
        // still being drawn, so the first address you type navigates instead
        // of waiting for WebKit to get up.
        defer {
            follow()
            watchForSleep()
            watchForStuck()
            // What hidden pages dropped, collected while the Mac is idle.
            Garbage.start()
            watchForTidy()
            // Your folders among the kept are worked out there, agents or not,
            // and now, with the row read, so it is first drawn with them.
            if windowPurpose == .normal, Folders.shared.browser == nil { Folders.shared.browser = self }
            if windowID == nil { Folders.shared.refresh() }
            // Opened on Mail: it is what the window shows, so it starts now
            // rather than once the launch is over (AppStartup.meetingsAndMail).
            if windowID == nil, inMail { AppStartup.mailNow(self) }
            if windowID == nil { Startup.mark("browser ready") }
        }

        // A private window opens as ⌘N's does: nothing in it, the field
        // asking on its own ground. Every tab it makes is private
        // (`open`), so it needs no empty one of its own to say so.
        windowPurpose.begin(normal: { restoreInitialRow() }, privateOnly: {
            let folders = Folders(emptiesFile: nil, forwardingTo: .shared)
            ownFolders = folders
            folders.browser = self
            askNew()
        })
    }

    private func restoreInitialRow() {
        // The space you were in, with spaces on; the first one otherwise,
        // which is the session and the sign-ins there always were.
        let currentKey = windowID.map { "window.\($0.uuidString).space" } ?? "space.current"
        spaceID = homeSpaceID
        if prefs.usesSpaces, let kept = Store.settings.string(forKey: currentKey).flatMap(UUID.init(uuidString:)),
           spaces.contains(where: { $0.id == kept }) {
            spaceID = kept
        }
        if windowID == nil { Spaces.current = spaceID }
        Spaces.sharing = Set(spaces.filter { !$0.ownSignIns }.map(\.id))
        Spaces.healLinked()
        // The space on screen wears its own look. The window's color keys
        // are one set every window writes, holding whichever window wore a
        // look last: kept into this space, they painted it in another
        // window's space's look at every launch, until every space wore the
        // same (feedback #702, two windows). A space with no look of its
        // own yet, made before spaces had them, keeps the window's.
        if prefs.usesSpaces {
            if let paint = space.paint { paint.wear(prefs) } else if windowID == nil { keepPaint() }
        }
        // The pins every space shares lead the row of one that shows them.
        pinsShared = !blank && prefs.usesSpaces && prefs.pinsEverySpace
        var row = windowID == nil ? Startup.stage("session") { loadRow(spaceID) } : loadRow(spaceID)
        if showsShared(spaceID) { row = joinShared(row, along: [], fromShowing: false) }
        guard !row.tabs.isEmpty else {
            // Nothing to show: no tab, the field on the window's own ground.
            // A spare tab's web view, and with it WebKit's helper processes,
            // is built a moment after the window is up, so that the first
            // address you type finds everything already running, and the
            // first frame never had to share the CPU with it.
            warmSpare()
            askNew()
            return
        }
        tabs = row.tabs
        // Two that were side by side, side by side again.
        pairs = row.pairs
        if !pairs.isEmpty { keepPairs() }
        // With none of its own, only the shared pins: the field over them,
        // as a switch into such a space has it (Browser.present).
        // A new window: the space's kept and pins asleep, the field over
        // them, none in front (KeptEverywhere.swift).
        // Left with none in front, or on a tab gone since: none now either.
        activeID = row.fresh ? nil : row.active.flatMap { id in tabs.contains { $0.id == id } ? id : nil }
        if activeID == nil {
            warmSpare()
            askNew()
        }
        // Only the one you were looking at actually loads, and its other
        // half, if it had one. Hidden for agents, none yet (Headless.show).
        if Headless.hidden { tidy(atLaunch: true); return }
        if windowID == nil { Startup.stage("front tab") { _ = active?.wake() } } else { active?.wake() }
        // A spare for the first tab opened, once the session is up: as soon
        // as the front page is in (Startup.later), not 4 s on, so a sleeping
        // tab picked in the first seconds wakes in it too (wakeInSpare).
        // YAB_LAUNCH_SPARE_SOON=0: at 4 s, as before.
        keepSpare(in: 4)
        if windowID == nil, Startup.flag("SPARE_SOON") {
            Startup.later("spare") { [weak self] in self?.keepSpare(in: 0.05) }
        }
        if let active, let other = partner(of: active) { _ = other.wake() }
        tidy(atLaunch: true)
    }

    /// A space's row as it was last written, its tabs asleep, made with
    /// that space's sign-ins, and its pairs side by side. The shared pins'
    /// row is one file for every window (SharedPins.swift).
    func loadRow(_ space: UUID) -> Parked {
        guard windowPurpose == .normal else { return Parked(tabs: [], active: nil) }
        let shared = space == Space.pinsID
        var saved = Session.read(space: space, window: shared ? nil : windowID)
        if shared { SharedPins.known = SharedPins.marks(saved.tabs, pairs: saved.pairs ?? []) }
        // In a window other than the first, the space's kept tabs and pins
        // are every window's: the list, then its own today's
        // (KeptEverywhere.swift). The list's are made under its keys.
        var keyed = 0, strays = 0, fresh = false
        if !shared, let list = sharedKept(for: space) {
            let joined = KeptEverywhere.joined(saved, list: list)
            saved = joined.shape
            keyed = joined.keyed
            strays = joined.strays
            fresh = joined.fresh && keyed > 0
        }
        var row: [Tab] = []
        var made: [Int: Tab.ID] = [:]
        var nests: [String: Nest] = [:]
        for (index, entry) in saved.tabs.enumerated() {
            guard let url = URL(string: entry.url) else { continue }
            // Old sessions can contain Mail as a loose tab. Only an explicit
            // pin belongs in a browser space; Mail's page lives in its own.
            if MailPage.isMail(url), !prefs.usesMail || entry.pin == nil { continue }
            let id = index < keyed ? UUID() : Tab.returning(entry.id)
            let tab = ArtifactPages.isPage(url)
                ? Tab(id: id, configuration: ArtifactPages.configuration(), engine: entry.restoredEngine)
                : Startup.flag("LAZY_CONFIG")
                ? Tab(id: id, later: Spaces.store(for: space), engine: entry.restoredEngine)
                : Tab(id: id, configuration: Web.configuration(store: Spaces.store(for: space)), engine: entry.restoredEngine)
            if index < keyed { tab.keptKey = entry.id.flatMap(UUID.init(uuidString:)) ?? UUID() }
            made[index] = tab.id
            prepare(tab)
            tab.restore(url: url, title: entry.title)
            tab.pin = shared ? entry.pin ?? tab.monogram : entry.pin
            if shared { tab.everywhere = entry.id.flatMap(UUID.init(uuidString:)) ?? tab.id }
            tab.customMark = entry.customMark
            tab.name = entry.name
            if let seen = entry.seen { tab.touch(at: Date(timeIntervalSince1970: seen)) }
            tab.visits = entry.visits ?? 0
            tab.arrive(at: entry.depth)
            if entry.kept == true, entry.pin == nil {
                tab.kept = true
                if let key = entry.folder {
                    let nest = nests[key] ?? Nest(id: UUID(uuidString: key) ?? UUID(), name: entry.folderName ?? "Folder", open: entry.folderOpen ?? true)
                    if nest.live == nil { nest.live = entry.folderLive }
                    // One a ⌥⇧-click made, wearing its site or emoji.
                    if entry.folderLinked == true { nest.linked = true }
                    nests[key] = nest
                    // In the folders its path names, made from it where no
                    // tab is right in them.
                    if nest.parent == nil, entry.folderPath != nil { nest.file(in: entry.folderPath, nests: &nests) }
                    tab.nest = nest
                }
                tab.live = entry.live
            } else if entry.pin == nil, let key = entry.folder, entry.folderToday == true {
                // One of today's you made, among them.
                let nest = nests[key] ?? Nest(id: UUID(uuidString: key) ?? UUID(), name: entry.folderName ?? "Folder", open: entry.folderOpen ?? true)
                nest.ordinaryToday = entry.folderOrdinaryToday == true
                nest.fleeting = !nest.ordinaryToday
                nest.file(in: entry.folderPath, nests: &nests)
                for each in nest.chain where nest.ordinaryToday { each.ordinaryToday = true }
                nest.linked = entry.folderLinked == true
                nests[key] = nest
                tab.nest = nest
            } else if entry.pin == nil, let key = entry.folder, let search = entry.folderSearch {
                // A search's folder, among today's.
                let nest = nests[key] ?? Nest(id: UUID(uuidString: key) ?? UUID(), name: entry.folderName ?? Research.name(search),
                                              open: entry.folderOpen ?? true, search: search)
                nests[key] = nest
                tab.nest = nest
            }
            tab.nest?.customMark = entry.folderMark
            tab.nest?.color = entry.folderColor
            tab.takeHome(entry)
            row.append(tab)
        }
        // Arc's folders in folders, brought in before a folder could be in
        // another, one folder each with the path in its name: in the
        // folders the names say, once.
        let unflattened = Store.settings.stringArray(forKey: "folders.unflattened") ?? []
        if !unflattened.contains(space.uuidString) {
            Nest.unflatten(row)
            Store.settings.set(unflattened + [space.uuidString], forKey: "folders.unflattened")
        }
        // The kept after the pins, whatever order the file had them in.
        let pins = row.filter { $0.pin != nil }
        let kept = row.filter(\.kept)
        row = pins + kept + row.filter { $0.pin == nil && !$0.kept }
        // Two that were side by side, side by side again, never one tab
        // in two pairs, whatever the file says (Pair.restore).
        let pairs = Pair.restore(saved.pairs ?? [], made: made)
        // Kept here alone by a Yab from before every window shared them:
        // they join the list, the other windows told once the row is written.
        if strays > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if space == spaceID {
                    writeSession(now: true)
                } else if let row = parked[space] {
                    writeRow(row.tabs, active: row.active, space: space, pairs: row.pairs, now: true)
                }
            }
        }
        // Below zero: left on one of the shared pins, found once they lead
        // the row (Browser.joinShared).
        if let at = saved.front, at < 0 { return Parked(tabs: row, active: nil, pairs: pairs, sharedFront: -1 - at) }
        // Left with none in front, or on a tab gone since: none in front
        // again, as in Arc, never the first pin or folder tab instead.
        let here = saved.front.flatMap { made[$0] }
        return Parked(tabs: row, active: fresh ? nil : here, pairs: pairs, fresh: fresh)
    }

    /// The blocker switched on or off for a site, from Settings or the
    /// site's card: every open page of it follows now, not at its next
    /// document. YouTube moves from video to video without one, so a tab
    /// left alone there would go on skipping ads until it was reloaded.
    /// With an extension blocking, its rules change too, and true says the
    /// page waits for them: it reloads once they land (Blockers), not now.
    @discardableResult
    func pauseShield(_ host: String, _ off: Bool) -> Bool {
        Shield.shared.pause(host, off)
        reshield()
        return Blockers.paused(host, off)
    }

    /// Site Controls' "Block ads and trackers" pressed for the site of `tab`:
    /// turned the other way, and the page reloaded for it.
    func switchBlocking(_ site: String, on tab: Tab) {
        // Through an extension, the page reloads once its rules land
        // (Blockers); Shield's own off is there at once.
        if !pauseShield(site, !Shield.shared.isPaused(on: site)) { reloadForChange(tab, .blocking) }
    }

    /// The blocker's answer changed for pages already open, in every space,
    /// link window and peek: the lists put on or taken off every page
    /// (Shield keeps them all), and YouTube's pages changed from inside,
    /// and put back the same way, from the next request on. Each by its own
    /// answer, which is off for a site paused however the switch stands.
    private func reshield() {
        Shield.shared.apply()
        let open = tabs + parkedTabs + outside + [peeking].compactMap { $0 }
        for tab in open where YouTube.runs(on: curtain.host(of: tab.address)) {
            tab.skipsAds = Shield.shared.skips(on: curtain.host(of: tab.address))
            tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
            tab.builtPage?.run(tab.skipsAds ? YouTube.script : YouTube.off, in: .page, gesture: false)
        }
    }

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private func follow() {
        followPrivatePreferences()
        guard windowPurpose == .normal else { return }
        followStore()
        // "Allow in private tabs" on Chromium: Chrome's own per-extension
        // switch follows it in every profile (ChromiumExtensions.list).
        prefs.changes(\.extensionsInPrivate)
            .dropFirst()
            .removeDuplicates()
            .sink { _ in ChromiumExtensions.privateTabsChanged() }
            .store(in: &bag)
        prefs.changes(\.shielded)
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                Shield.shared.enabled = on
                Blockers.shieldSwitched(on)
                reshield()
                announceSetting(on ? "Blocking ads and trackers" : "Ads allowed, reload to see them", mark: on ? "checkmark.shield" : "xmark.shield")
            }
            .store(in: &bag)

        // Spaces turned off: back to the first, the others kept for later.
        prefs.changes(\.usesSpaces)
            .dropFirst()
            .sink { [weak self] on in
                guard let self, !on else { return }
                DispatchQueue.main.async { self.leaveSpaces() }
            }
            .store(in: &bag)
        // Pins: In Every Space or In Each Space, with spaces on: the pins
        // shared, or given back to the spaces, in every window at once
        // (SharedPins.swift). Heard as the value is about to be set, so
        // turned with the value given; not for leaveSpaces' one switch.
        prefs.changes(\.usesSpaces)
            .dropFirst()
            .sink { [weak self] on in if !Spaces.leaving { self?.settlePins(spaces: on) } }
            .store(in: &bag)
        prefs.changes(\.pinsEverySpace)
            .dropFirst()
            .sink { [weak self] every in self?.settlePins(every: every) }
            .store(in: &bag)
        Spaces.finishErasing()
        Spaces.sweep()

        prefs.changes(\.bench)
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                // Getting started's rows, which ask for agents on, as they are now.
                Hints.shared.refresh()
                announceSetting(on ? "Agents can use Yab" : "Agents can’t use Yab", mark: "agent.face")
            }
            .store(in: &bag)

        prefs.changes(\.passkeys)
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                FormRelay.passkeysOffered = on && self.prefs.passkeysPossible
                // Each tab keeps whatever is hidden on the site it is showing:
                // re-arming with nothing would quietly restore every element
                // this person had taken off, everywhere.
                for tab in tabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                }
                announceSetting(on ? "Passkeys on" : "Passkeys off", mark: "person.key")
            }
            .store(in: &bag)


    }


    /// The same profile's harmless live preferences apply to private windows
    /// too. Session, spaces, services and shared-row subscriptions stay above
    /// behind the lifetime purpose guard.
    private func followPrivatePreferences() {
        // Who fills and saves: Yab's own switch, the managers connected,
        // and their extensions coming in and turning on or off. Only a real
        // change is told: another extension arriving is not one.
        passwordSource = prefs.passwordSource
        Publishers.MergeMany(
            prefs.changes(\.usesYabPasswords).map { _ in () }.eraseToAnyPublisher(),
            PasswordManagers.Connections.shared.$list.map { _ in () }.eraseToAnyPublisher(),
            Extensions.shared.$installed.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.passwordSourceMaybeChanged() }
        .store(in: &bag)
        // The look changes, from Settings, or from the Mac while set to
        // System, and the icons a site keeps for each scheme change with it.
        // A beat after, so the appearance has actually turned over.
        prefs.changes(\.look)
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.look == .system else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)

        // The window and the menus are drawn from this object; a setting that
        // changes what they show has to be heard here.
        prefs.changes(\.searchSuggest).combineLatest(prefs.changes(\.engine)).dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.fieldShowing else { return }
                    self.guess(completing: self.searchCompleting)
                }
            }
            .store(in: &bag)

        // Preferences is observed setting by setting (Observation): a view
        // that draws one redraws for it alone. What still comes through
        // here is the rare word for everyone, the density and the Mac's
        // display options, which views read from outside Preferences.
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

    }

    /// Who filled when last looked: Settings, an extension starting or
    /// its app answering ask again, and only a different answer counts.
    @ObservationIgnored private(set) var passwordSource = PasswordManagers.Source(yab: true, saver: nil)
    @ObservationIgnored var passwordImportRoute = PasswordsToApple.CommandRoute.live

    /// Whether who fills changed since last looked; if so the list under
    /// the box is taken down and asked for again. An agent's sign-ins stay:
    /// sign_in checks who fills each time it is called.
    @discardableResult
    func passwordSourceMaybeChanged() -> Bool {
        let now = prefs.passwordSource
        guard now != passwordSource else { return false }
        passwordSource = now
        suggesting = nil
        pickedInto = nil
        loginWaiting = nil
        kept = nil
        if now.yab, let tab = active, let spot = tab.fieldSpot {
            tab.onField?(tab, spot)
        }
        return true
    }

    func savedPasswordChanged() {
        savedLoginsRevision &+= 1
        kept = nil
        suggesting = nil
        pickedInto = nil
        loginWaiting = nil
        if prefs.usesYabPasswords, let tab = active, let spot = tab.fieldSpot {
            tab.onField?(tab, spot)
        }
    }

    private func relook() {
        Favicons.shared.relook(tabs.filter { !$0.asleep })
        // The mail pin's envelope turns with the look, asleep or in another
        // space too: it is in every one.
        for tab in tabs + parkedTabs where MailPage.isMail(tab.address) { tab.adoptIcon() }
        // A page that follows the window's look has drawn itself again by
        // now; the strip and ⌘L's field go by what it drew.
        active?.retone(fresh: true)
    }

    func writeSession(now: Bool = false) {
        if windowID == nil { writtenShape = rowShape }
        // One in from another space with you (a call, an agent at work in
        // it) is written in its own space's row, never this one's, where it
        // was found stuck after the call, in its home's folder (row 1149).
        let visitors = tabs.filter { $0.homeSpace != nil && $0.homeSpace != spaceID }
        guard !visitors.isEmpty else {
            writeRow(tabs, active: activeID, space: spaceID, pairs: pairs, now: now)
            return
        }
        writeRow(tabs.filter { tab in !visitors.contains { $0 === tab } }, active: activeID, space: spaceID, pairs: pairs, now: now)
        for (home, group) in Dictionary(grouping: visitors, by: { $0.homeSpace ?? spaceID }) {
            guard let row = parked[home] else { continue }
            writeRow(row.tabs + group, active: row.active, space: home, pairs: row.pairs, now: now)
        }
    }

    /// What sync's row is made of, per tab: its id, kept, pinned.
    /// Only tabs `writeRow` writes: a new tab without its address yet isn't
    /// in it, so it is written at once when the address comes.
    private var rowShape: [String] {
        tabs.compactMap { tab in
            guard !tab.shy, !tab.bench, let url = tab.pending ?? tab.address, Session.writes(url) else { return nil }
            return "\(tab.id.uuidString)\(tab.kept ? "+" : "")\(tab.pin ?? "")"
        }
    }

    /// A space's row, to its own file, its pairs with it. Agents' tabs and
    /// private ones are never written. The shared pins in it go to their
    /// own row's file, one for every window, never to a space's
    /// (SharedPins.swift); a row left on one of them says so by a place
    /// below zero.
    func writeRow(_ tabs: [Tab], active activeID: Tab.ID?, space: UUID, pairs: [Pair], now: Bool = false) {
        guard windowPurpose == .normal else { return }
        MainBudget.chunk("session.row") { writeRowNow(tabs, active: activeID, space: space, pairs: pairs, now: now) }
    }

    private func writeRowNow(_ tabs: [Tab], active activeID: Tab.ID?, space: UUID, pairs: [Pair], now: Bool) {
        Spaces.pageCounts[space] = nil
        let shared = space == Space.pinsID
        if !shared { settleShared(tabs, in: space) }
        var written: [Tab.ID: Int] = [:]
        // The space's kept tabs and pins, every window's (KeptEverywhere.swift),
        // each under its key; in a window other than the first, marked so,
        // and keyed the first time with a key of their own, never the tab's
        // id, which the first window takes for its tab.
        var list: [Session.Entry] = []
        let mirrors = !shared && sharesKept
        if !shared {
            for tab in tabs where tab.keptKey != nil && tab.pin == nil && !tab.kept && !(KeptEverywhere.today && listed(tab)) { tab.keptKey = nil }
        }
        let entries: [Session.Entry] = tabs.compactMap { tab in
            guard shared ? tab.pin != nil : tab.everywhere == nil else { return nil }
            // Mail's space keeps its tabs, not an agent's work in them; its
            // own page is no http address and is made afresh (MailSpace).
            if space == Space.mailID, MailChat.isAgents(tab) { return nil }
            let inList = !shared && listed(tab)
            if inList, mirrors, tab.keptKey == nil { tab.keptKey = UUID() }
            guard var entry = sessionEntry(tab, id: shared ? tab.everywhere ?? tab.id : inList ? KeptEverywhere.key(tab) : tab.id) else { return nil }
            if inList {
                list.append(entry)
                if mirrors { entry.shared = true }
            }
            written[tab.id] = written.count
            return entry
        }
        // Pairs by where their two stand in what was written: a tab left
        // out, a private one, takes its pair with it.
        let kept = pairs.compactMap { pair -> Session.Pair? in
            guard let a = written[pair.first], let b = written[pair.second] else { return nil }
            return Session.Pair(first: a, second: b, share: Double(pair.share))
        }
        // Left with none in front, or on one never written (a private tab,
        // a blank one): none in front when it comes back, not its first pin
        // or folder tab woken for it.
        let front = activeID.flatMap { written[$0] } ?? (shared ? nil : sharedFront(activeID))
        Session.write(
            now: now,
            space: space,
            window: shared ? nil : windowID,
            shared ? .init(tabs: entries, active: 0, pairs: kept.isEmpty ? nil : kept)
                : .init(tabs: entries, front: front, pairs: kept.isEmpty ? nil : kept)
        )
        // The shared row with any row that holds some of them, and with the
        // row on screen of a space that shows them, the last one unpinned
        // there too.
        if shared {
            toldPins(entries, pairs: kept)
        } else if tabs.contains(where: { $0.everywhere != nil }) || space == spaceID && showsShared(space) {
            writePins(now: now)
        }
        // Every other window follows a change in the space's list.
        if !shared { KeptEverywhere.wrote(list, space: space, by: self) }
    }

    /// A tab as its row's file keeps it, under `id`, or nil for one that is
    /// never written: an agent's, a private one, one with no web address.
    func sessionEntry(_ tab: Tab, id: Tab.ID) -> Session.Entry? {
        // An agent's tab that is waiting for you (a sign-in, a yes) or that
        // you are looking at is kept: granting Full Disk Access for a texted
        // code has macOS quit and reopen Yab, and the page you were signing
        // in on comes back as a tab of yours instead of vanishing with the
        // agent's others.
        guard !tab.shy, !tab.bench || tab.handoff != nil || tab.permit != nil || onScreen(tab.id) else { return nil }
        // A sleeping tab holds its address in `pending`; asking for
        // it there too means a pin can never be written out of
        // existence by whatever its web view happens to be showing.
        guard let url = tab.pending ?? tab.address, Session.writes(url) else { return nil }
        // The one on screen is being looked at now.
        let seen = onScreen(tab.id) ? Date() : tab.touched
        let nest = tab.kept || tab.nest?.today == true ? tab.nest : nil
        return Session.Entry(url: url.absoluteString, title: tab.title, pin: tab.pin, name: tab.name, seen: seen.timeIntervalSince1970,
                             kept: tab.kept ? true : nil, folder: nest?.id.uuidString, folderName: nest?.name, folderOpen: nest?.open,
                             folderPath: nest?.path, folderSearch: nest?.search, folderToday: nest.map { ($0.fleeting || $0.ordinaryToday) && !tab.kept } == true ? true : nil,
                             folderOrdinaryToday: nest?.ordinaryToday == true ? true : nil,
                             folderLinked: nest?.linked == true ? true : nil,
                             folderLive: tab.kept ? nest?.live : nil, live: tab.kept ? tab.live : nil,
                             customMark: tab.customMark, folderMark: nest?.customMark, folderColor: nest?.color,
                             visits: tab.visits > 0 ? tab.visits : nil, id: id.uuidString, depth: tab.depth,
                             home: tab.home?.absoluteString, homeTitle: tab.home == nil ? nil : tab.homeTitle, engine: tab.engineKind.rawValue)
    }

    /// The row in a new order, or with a tab more, from Split.swift, which
    /// keeps the two of a pair side by side.
    func lay(_ row: [Tab]) {
        tabs = row
    }

    func rememberSession() {
        guard windowPurpose == .normal else { return }
        if windowID == nil, !rushing, MainBudget.chunk("session.shape", { rowShape != writtenShape }) {
            rushing = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                rushing = false
                if rowShape != writtenShape { writeSession() }
            }
        }
        guard !remembering else { return }
        remembering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            remembering = false
            writeSession()
        }
    }

    /// The app is quitting. Whatever the debounce above was waiting out, it
    /// stops waiting: this writes straight to disk, on the thread asking to
    /// quit, before there is a process left to finish the wait on its behalf.
    func flushSession() {
        guard windowPurpose == .normal else { return }
        Session.land { writeRows() }
    }

    /// Every row as it is now, asked to be written without waiting for the
    /// disk: what Session.read answers from at once (sync's delivery).
    func writeRows() {
        guard windowPurpose == .normal else { return }
        writeSession(now: true)
        // The spaces not on screen, whose pages may have moved on since. The
        // shared pins all together: one a call took along is in the row on
        // screen, not among those put aside.
        for (space, row) in parked where space != Space.pinsID {
            writeRow(row.tabs, active: row.active, space: space, pairs: row.pairs, now: true)
        }
        writePins(now: true)
    }

    /// Another space's row, on screen in place of this one (Spaces.swift):
    /// the tabs themselves swapped, nothing closed or loaded.
    /// The tab left is marked as just looked at, or it would sleep at the
    /// next tick and load again on the way back; its video stays in it,
    /// parked with it. The row changes at once, with nothing animated: a
    /// row's own arrivals and departures, every tab of both rows at once,
    /// were a frame spike and a different switch for every pair of counts.
    /// A row with nothing in front, empty or not, has the field come up
    /// over the page you were on (switchSpace).
    func showRow(_ row: [Tab], active id: Tab.ID?) {
        active?.touch()
        quietly {
            tabs = row
            activeID = id
        }
    }

    /// `body`'s writes without animation, and all of them in one
    /// transaction, however deep: SwiftUI brings the whole window up to
    /// date there and then each time the transaction changes between two
    /// writes, to keep each change on its own, and a switch of space that
    /// wrote in three (its own, the paint's, the row's) laid the window
    /// out three times before its frame.
    func quietly(_ body: () -> Void) {
        guard !Browser.quiet else { return body() }
        Browser.quiet = true
        defer { Browser.quiet = false }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still, body)
    }
    private static var quiet = false

    // MARK: - tabs

    /// ⌘T, or the plus. Over a page, the field and nothing else: the tab
    /// comes with the place it is for (see `asked`), never as an empty row.
    /// With no tab in front the field is already that, and only takes the
    /// cursor. A held ⌘T is ignored after its first press.
    func newTab() {
        if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return }
        Lag.shared.begin(.newTab)
        // From a private tab in a normal window (an agent's private
        // sign-in), a private one: ⌘T from a page that keeps nothing onto
        // one that keeps everything is how a private search ends up in the
        // history. A private window's ⌘T is everyone's: the field over the
        // page, and whatever it opens is private there anyway.
        if privateBrowsing, windowPurpose == .normal {
            newShyTab()
            return
        }
        // An extension's new tab page, if one asked and you said yes; never
        // in a private window, whose new tab is the field alone.
        if #available(macOS 15.4, *), windowPurpose == .normal, let page = Extensions.of(self).newTabPage {
            open(page, foreground: true)
            rememberSession()
            return
        }
        let destination = query.returnPlace
        if active != nil { openFresh() } else { askNew() }
        if let destination {
            enterPlace(destination.place, filter: destination.filter)
        }
        // Asked once, the first time an extension wants the new tab: on
        // yes, its page comes in place of the field, if the field still
        // has nothing in it.
        if #available(macOS 15.4, *), windowPurpose == .normal {
            Extensions.of(self).offerNewTabPage { [weak self] page in
                guard let self, fieldShowing, fresh, typed.isEmpty else { return }
                editing = false
                open(page, foreground: true)
                rememberSession()
            }
        }
    }

    /// ⌘T as its key or File › New Tab presses it: again, with its own
    /// field up, the field goes, including in a tabless window.
    func pressNewTab() {
        let press = { [weak self] in
            guard let self else { return }
            if self.tabs.isEmpty, self.fieldGuest == nil, self.fieldShowing,
               self.query.place == nil, self.query.returnPlace == nil, !self.query.answering {
                if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return }
                self.dismiss()
                return
            }
            if self.fieldShowing, self.query.place != nil {
                if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return }
                self.close()
                self.query.returnPlace = nil
                self.openFresh()
                return
            }
            if self.putAwayAgain(asking: .tab) { return }
            self.newTab()
        }
        if !leavePageFullScreen(then: press) { press() }
    }

    /// ⌘L as its key or File › Open Address… presses it, the same way.
    func pressOpenAddress() {
        let press = { [weak self] in
            guard let self else { return }
            if self.putAwayAgain(asking: nil) { return }
            self.edit()
        }
        if !leavePageFullScreen(then: press) { press() }
    }

    /// The page in front has the screen in WebKit's own window (a video's
    /// full screen), over this one, where the field would open unseen
    /// (register 939): it is given back first, and
    /// `then` runs once the page is in its tab again and WebKit's window
    /// gone, which hands the keyboard back to the page as it goes: a field
    /// opened before that lost it and shut. False when no page has the
    /// screen.
    @discardableResult
    func leavePageFullScreen(then: @escaping () -> Void) -> Bool {
        guard let tab = active, tab.immersed else { return false }
        if let page = tab.builtPage as? ChromiumPage {
            page.exitPageFullscreen()
        } else {
            guard let web = tab.built else { return false }
            web.closeAllMediaPresentations(completionHandler: {})
        }
        let id = UUID()
        leavingFull = id
        // Looked at every 50 ms, for 3 s at most: WebKit that never says it
        // left still gets the key, in this window.
        func look(_ left: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tab] in
                MainActor.assumeIsolated {
                    guard let self, self.leavingFull == id else { return }
                    // WebKit keeps its window ordered in off the screen
                    // between turns: what counts is who has the page and
                    // the keyboard.
                    let lent = [tab?.builtPage?.window, NSApp.keyWindow].contains { window in
                        window.map { NSStringFromClass(Swift.type(of: $0)) == "WebCoreFullScreenWindow" } == true
                    }
                    if left > 0, tab?.immersed == true || lent { return look(left - 1) }
                    self.leavingFull = nil
                    then()
                }
            }
        }
        look(60)
        return true
    }
    @ObservationIgnored private var leavingFull: UUID?

    /// ⌘T pressed again with ⌘T's field up, or ⌘L with ⌘L's, puts the
    /// field away as Escape does, whatever was typed in it, as Arc's
    /// Command Bar does (feedback #165b). The other key still turns the
    /// field into its own, and inside one of the field's places the keys
    /// are as before. A held key's repeats are no presses: the field stays
    /// as the first press left it.
    private func putAwayAgain(asking kind: Asked?) -> Bool {
        // Main-window keys only toggle that window's field. A guest field
        // must first give the field back through openFresh() or edit().
        guard fieldGuest == nil, editing, asked == kind, query.place == nil, !query.answering,
              let tab = active, !tab.isBlank else { return false }
        if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return true }
        unchoose()
        dismiss()
        return true
    }

    /// New Tab in Folder: ⌥⌘T in a folder's tab, a folder's menu, or ⌘T's
    /// row. ⌘T's field, and what it opens lands at the end of the folder,
    /// which opens if shut. Outside a folder of yours, ⌘T.
    func newTab(in nest: Nest?) {
        if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return }
        guard let nest, !privateBrowsing, nests.contains(where: { $0 === nest }) else { return newTab() }
        Lag.shared.begin(.newTab)
        if active != nil { openFresh() } else { askNew() }
        landing = nest
    }

    /// The folder ⌥⌘T opens a tab in: the one the tab in front is in.
    var folderHere: Nest? {
        guard let nest = active?.nest, !privateBrowsing, nests.contains(where: { $0 === nest }) else { return nil }
        return nest
    }

    /// ⌘N, as Arc's: a window at once, of the space you are in, the field
    /// asking on its own ground for the window's first tab (a window with
    /// nothing in it asks by itself, `fresh`). ⌘T's field, if it was up
    /// here, goes, as switching windows would leave it (feedback #285: the
    /// field over the page read as a new tab). `opening` makes the window;
    /// a test hands in its own.
    func newWindow(opening: ((Browser) -> Void)? = nil) {
        if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return }
        if fieldShowing, asked != nil, active != nil { dismiss() }
        if let opening { opening(self) } else { BrowserWindows.shared.newWindow(from: self) }
    }

    /// A separate private window, seeded before it can be shown or restored,
    /// with `url` in it when there is one (a link menu's Open Link in Private Window).
    func newPrivateWindow(opening url: URL? = nil) {
        if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.isARepeat == true { return }
        let window = BrowserWindows.shared.newPrivateWindow(from: self)
        if let url { window.arrive(url) }
    }

    /// The field, empty, asking where to go, with no tab in front: over
    /// what stands under it (`under`), or on the window's own ground.
    func askNew() {
        fieldPutAway = false
        landing = nil
        editing = false
        dropScope()
        typed = ""
        query.focusRequest += 1
    }

    /// What stood under the field goes: the field was answered, or left
    /// for a tab.
    func settleUnder() {
        if under != nil { under = nil }
    }

    /// Escape, or a click on the page under the field, with no tab in
    /// front: the space you came from with its page. On the window's own
    /// ground in a space with tabs in its column the field goes, and the
    /// column is free to pick one (feedback: the field stood over the
    /// column and hid the tabs). An empty normal or private window also
    /// lets the field go, leaving the window's own ground.
    private func backOut() {
        guard case .space(_, let from) = under else {
            typed = ""
            if fieldCanPutAway {
                editing = false
                landing = nil
                dropScope()
                fieldPutAway = true
            }
            return
        }
        under = nil
        switchSpace(to: from)
        editing = false
    }

    /// A spare tab's web view, a moment after a window opens with nothing
    /// in it (see `spare`).
    private func warmSpare() {
        guard windowPurpose == .normal else { return }
        guard spare == nil else { return }
        let tab = blankTab()
        prepare(tab)
        spare = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + (tab.warmsSoon ? 0.05 : 1)) { [weak self, weak tab] in
            guard let tab, self?.spare === tab, !Headless.hidden else { return }
            tab.warm()
        }
    }

    /// The spare tab, for a page going into this space's own store, or for
    /// something that needs a tab while none is in front.
    private func takeSpare(for url: URL? = nil) -> Tab? {
        guard let tab = spare, tab.store === Spaces.store(for: spaceID), tab.spareFits(url),
              url.map({ Browser.extensionConfiguration(for: $0) == nil && !ArtifactPages.isPage($0) }) ?? true else { return nil }
        spare = nil
        if #available(macOS 15.4, *) { ContentWarm.release(tab.webKitOnly("WebKit native page lifecycle", build: false)) }
        keepSpare()
        return tab
    }

    /// The window's Chromium spare for a peek, as a tab opened takes it: its
    /// helper tab, profile and renderer are up already, so the peeked page
    /// only has to load. Made anew, a peek's page paid for all of that on
    /// its way to its first frame and the card came in empty (register 2493).
    func takeSpareForPeek(_ url: URL) -> Tab? {
        guard spare?.warmsSoon == true else { return nil }
        return takeSpare(for: url)
    }

    /// A sleeping tab picked, whose page was never built: its page made in
    /// the spare's process, which is started and has the extensions'
    /// content scripts compiled (ContentWarm), rather than in a new one
    /// that compiles them on the way to the page's first script (uBO
    /// Lite's scriptlets, +23 ms; docs/evidence/night-extensions-2026-10-14.md).
    /// WebKit puts a page made with a related view in that view's process.
    /// The spare is let go once the page is under way, and another kept.
    /// YAB_WAKE_SPARE=0: a process of its own, as before.
    static let wakesInSpare = ProcessInfo.processInfo.environment["YAB_WAKE_SPARE"] != "0"

    private func wakeInSpare(_ tab: Tab) {
        guard tab.engineKind == .webKit else { WebKitOnly.note("WebKit related process warming", engine: tab.engineKind); return }
        guard Browser.wakesInSpare, tab.webKitOnly("WebKit native page lifecycle", build: false) == nil, !tab.shy, let spare, let view = spare.webKitOnly("WebKit native page lifecycle", build: false),
              spare.store === tab.store, let url = tab.pending, Browser.extensionConfiguration(for: url) == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if #available(macOS 15.4, *), tab.carriesExtensions != spare.carriesExtensions { return }
        self.spare = nil
        // Held until the page is under way: its own page closed sooner, the
        // process could go before the new page is in it.
        spare.lingerNote = "the spare a woken page was made in"
        tab.relate(to: view) { spare.close() }
        keepSpare()
    }

    /// Whether a spare is kept ready all along, a spare
    /// renderer, and not only for a window's first page. Every other tab
    /// opened started a content process of its own on the way to its first
    /// frame, 45-50 ms of it: with a spare kept, the stand's open tab went
    /// from 101-116 ms to 60-66, for one idle process of about 10 MB
    /// (docs/evidence/tab-open-2026-10-13.md). YAB_KEEP_SPARE=0 for the A/B.
    static let keepsSpare = ProcessInfo.processInfo.environment["YAB_KEEP_SPARE"] != "0"

    /// A spare built again in a while: after the tab that took the last one
    /// has drawn, and never during a drag or a scroll (the run loop's
    /// default mode only). One a window, in the store of the space on
    /// screen; one of another space's store is let go for it.
    func keepSpare(in seconds: TimeInterval? = nil) {
        guard windowPurpose == .normal else { return }
        guard Browser.keepsSpare else { return }
        spareTimer?.invalidate()
        // A Chromium endpoint and its document-start scripts take about
        // 130 ms on the tab's opening path. A 1.5 s debounce never replenishes
        // the spare during successive opens; prepare it while the current
        // page loads. renewSpare still waits for its first real document.
        let delay = seconds ?? (active?.warmsSoon == true ? 0.25 : 1.5)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.renewSpare() }
        }
        RunLoop.main.add(timer, forMode: .default)
        spareTimer = timer
    }

    private func renewSpare() {
        spareTimer = nil
        // Saving power, or for agents only: no process kept for nobody.
        guard !Headless.hidden, !Thrift.on else { return dropSpare() }
        // A spare's window and agents go through the helper ahead of a page
        // still on its way to its first document: 100 ms of a cold start's 570.
        if (active?.builtPage as? ChromiumPage)?.reachingFirstDocument == true { return keepSpare(in: 0.5) }
        let store = Spaces.store(for: spaceID)
        if let spare, spare.store === store {
            OpenTrace.time("spare.build") { spare.warm() }
            return
        }
        dropSpare()
        let tab = blankTab()
        prepare(tab)
        spare = tab
        OpenTrace.time("spare.build") { tab.warm() }
    }

    /// The extensions done loading at launch: a spare warmed before some
    /// of them were has their content scripts compiled too (ContentWarm
    /// skips what it compiled there already).
    func rewarmSpare() {
        guard Startup.flag("SPARE_SOON"), let view = spare?.webKitOnly("WebKit native page lifecycle", build: false), !Headless.hidden else { return }
        if #available(macOS 15.4, *) { ContentWarm.warm(view) }
    }

    /// Read-only state for the isolated native regression probe.
    var spareForBench: [String: Any] {
        let page = spare?.builtPage as? ChromiumPage
        return ["id": spare?.id.uuidString ?? "", "remote": page?.remoteID ?? "",
                "ready": page?.isWarmSpare == true]
    }

    /// The spare and its process let go: the window closed, or power saved.
    func dropSpare() {
        spareTimer?.invalidate()
        spareTimer = nil
        guard let tab = spare else { return }
        spare = nil
        tab.lingerNote = "the spare"
        tab.close()
    }

    /// A tab to hold what the field does while no tab is in front (an
    /// answer asked in it): the page under the field, or one of no row's,
    /// the spare if it is there, kept from becoming the next page opened.
    func holder() -> Tab {
        if let tab = active ?? underTab { return tab }
        if let tab = takeSpare() { return tab }
        let tab = blankTab()
        prepare(tab)
        return tab
    }

    /// A tab sent to an extension's page: a blank one given the extension's
    /// new tab page, or a website's that the extension sends to one of its
    /// own. The page needs a view built from that extension's
    /// configuration, so it is a new tab in the old one's place, and the
    /// same tab to everyone else: its id, whether it is private or a
    /// script's, the agent at work in it, its pin (a shared one too), its
    /// name, its folder and kept row, and its history: Tab Suspender sends
    /// a tab in a folder to its suspended page and back, and in Chrome the
    /// tab stays in its group with Back to the site (feedback #209).
    func replaceBlank(_ tab: Tab, with url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let url = Browser.page(url)
        let page = Tab(id: tab.id, shy: tab.shy, bench: tab.bench, configuration: configuration(for: url),
                       engine: tab.enginePendingDefault ?? (tab.engineMemoryMoved ? tab.engineDefaultBase : tab.engineKind),
                       factory: tab.engineFactory)
        page.assistantSpace = tab.assistantSpace
        page.agent = tab.agent
        page.guest = tab.guest
        page.inheritHandoff(from: tab)
        page.opener = tab.opener
        page.from = tab.from
        page.backLinkSource = tab.backLinkSource
        page.pin = tab.pin
        page.everywhere = tab.everywhere
        page.customMark = tab.customMark
        page.name = tab.name
        page.kept = tab.kept
        page.keptKey = tab.keptKey
        page.nest = tab.nest
        page.home = tab.home
        page.homeTitle = tab.homeTitle
        page.live = tab.live
        page.visits = tab.visits
        tab.retireReplacedChromiumPage()
        prepare(page)
        tabs[index] = page
        if #available(macOS 15.4, *) { Extensions.all.forEach { $0.rehome(page) } }
        // The back list of the site it was, so Back goes there from the
        // extension's page.
        if url.scheme == Extensions.scheme, let web = tab.webKitOnly("WebKit native page lifecycle", build: false), let was = web.url, was.scheme != "about" {
            page.backList = web.interactionState
        }
        page.go(to: url)
        if activeID == tab.id {
            editing = false
        } else if page.bench {
            // Out of sight, as the bench keeps its tabs.
            Bench.shared.house(page)
        }
    }

    func select(_ tab: Tab) {
        // Yab's own work out of sight (Get to Know): its tabs are never the
        // one in front, whoever asks, a key, a list, the omnibox, a script.
        guard !Agents.shared.sealed(tab) else { return }
        folderBook.picked(tab)
        folderBook.focused = nil
        cancelTabEdit()
        suggesting = nil
        // Picked while its row waits for its page's frames: the row now.
        if waitingRow?.tab == tab.id { putWaitingRow() }
        // The mail pin is the door to mail's space, never a page of its own.
        if tab.pin != nil, !inMail, MailPage.isMail(tab.pending ?? tab.address) {
            enterMail()
            return
        }
        // Back to the tab in front while the switch away from it waits for
        // its page's frame: that switch is off, and its page comes back.
        if tab.id == activeID, switchPending != nil {
            let stage = heldStage
            releaseSwitch()
            if let stage, let page = tab.builtPage { stage.show(page, of: tab.id, tab: tab) }
            return
        }
        guard tab.id != activeID else { return }
        // Asleep here, awake in another window: that page comes here, the
        // same one, never a second copy loading (BrowserWindows.handOff).
        if tab.asleep, Browser.handMade, BrowserWindows.shared.handOff(tab, to: self) { return }
        Lag.shared.begin(.tabSwitch)
        // A hand's switch, a click or a key, for Split View's hint: back and
        // forth between two tabs (Teach.swift). ⌃Tab lands as ⌃ is let go.
        if let kind = NSApp.currentEvent?.type, [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp].contains(kind) {
            Teach.shared.switched(from: activeID, to: tab, in: self)
        }
        // The other half of the pair on screen: only the one in front changes.
        if stagePair?.contains(tab.id) == true, stagePair?.contains(activeID) == true, !splitBook.frozen {
            focus(tab)
            return
        }
        (tab.builtPage as? ChromiumPage)?.willShow()
        settleNow()
        // Its page on screen now, from its last frame, before anything of
        // the switch is written for SwiftUI (PageStills).
        let early = showEarly(tab)
        // On the stage already: the window's own redraw for the switch (the
        // row, the bar, the colors: 30-50 ms of the main thread) waits until
        // the page has drawn its first frame there, which it couldn't while
        // that redraw held the thread its frames go through. 80 ms at most.
        if early, Narrow.deferSwitch, let web = tab.webKitOnly("WebKit native page lifecycle", build: false) {
            let attempt = holdSwitch(to: tab.id, on: web.superview as? StageView)
            let finish = { [weak self, weak tab] in
                guard let self, let tab, self.hold.holds(tab.id, attempt: attempt) else { return }
                self.finishSelect(tab)
            }
            StageView.afterNextDrawing(web) { DispatchQueue.main.async { finish() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { finish() }
            return
        }
        // The same for a Chromium page: the redraw waits until the helper has it in front.
        if Narrow.deferSwitch, !LinkGap.cut("chromium.defer"), let page = tab.builtPage as? ChromiumPage,
           let stage = early ? page.superview as? StageView : StageView.earlyChromium(from: active, to: tab,
               single: stagePair == nil && !splitBook.frozen && stages.compactMap { $0 }.count == 1 && pair(of: tab.id) == nil) {
            let attempt = holdSwitch(to: tab.id, on: stage)
            let finish = { [weak self, weak tab] in
                guard let self, let tab, self.hold.holds(tab.id, attempt: attempt) else { return }
                self.finishSelect(tab)
            }
            page.afterShown { DispatchQueue.main.async { finish() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { finish() }
            return
        }
        finishSelect(tab)
    }

    /// A tab's page shown on the stage ahead of the switch, until the rest
    /// of the switch is written (`select`).
    /// A tab a link opened behind the one on screen, for the column to
    /// bring its row into sight, as Arc does (ColumnPage.reveal).
    @ObservationIgnored var revealAsked: Tab.ID?

    /// The row of the tab last opened in front while it waits for its
    /// page's frames (OPEN_LATE_ROW), outside the row meanwhile. Another
    /// tab opened in front, or this one picked, puts it in at once: opened
    /// three in a row, the first's row came after the third's, and a pick
    /// of one still outside found no row and was dropped, the last opened
    /// coming to the front instead (evals/tab-tearoff/active.py).
    @ObservationIgnored private var waitingRow: (tab: Tab.ID, put: () -> Void)?

    private func putWaitingRow() {
        let row = waitingRow?.put
        waitingRow = nil
        row?()
    }

    @ObservationIgnored private var hold = SwitchHold()
    var switchPending: Tab.ID? { hold.tab }
    @ObservationIgnored private weak var heldStage: StageView?

    /// Holds the switch to `id`, on `stage` if given, letting go of any
    /// earlier hold and its stage first. The attempt is what its finishers check.
    private func holdSwitch(to id: Tab.ID, on stage: StageView?) -> Int {
        releaseSwitch()
        heldStage = stage
        stage?.heldFor = id
        return hold.hold(id)
    }

    private func releaseSwitch() {
        hold.release()
        heldStage?.heldFor = nil
        heldStage = nil
    }

    /// The switch, written: the tab in front, the window redrawn for it.
    private func finishSelect(_ tab: Tab) {
        releaseSwitch()
        guard tab.id != activeID, tabs.contains(where: { $0 === tab }) else { return }
        cancelVideoRequest(for: tab)
        // Coming back to the tab whose video is out brings it home first, so
        // it is never lifted and landed in the same breath.
        if floating == tab.id { land(home: true) }
        leaving()
        // A sleeping tab, one brought back from last time as pins and kept
        // tabs are, comes in front at once, its page loading inside it, as
        // one opened from ⌘T does (StageView.willOpen, #206): the stage
        // kept the page left on screen until the site's first document
        // drew, a second at most, so the switch seemed to wait for the
        // load (feedback #278).
        if tab.asleep { StageView.willOpen(tab.id) }
        activeID = tab.id
        tab.touch()
        // A tab brought back from last time, or waking from ⌘W while pinned,
        // opens the moment you look at it, and only if there was nothing to
        // wake is this the other case, one whose page quietly died while you
        // were elsewhere, which revive() checks for on its own.
        if tab.asleep { wakeInSpare(tab) }
        if !tab.wake() { tab.revive() }
        wakePartner(of: tab)
        rememberSession()
        editing = false
        typed = ""
    }

    /// A tab of a space not on screen closed from outside it, by an
    /// extension (OneTab sending the window's tabs away, feedback #156):
    /// closed there, without going to it, and kept for ⌘⇧T and the diary
    /// as a close in the row is.
    func closeElsewhere(_ tab: Tab) {
        if closePeekTab(tab) { return }
        guard let space = parked.first(where: { $0.value.tabs.contains(where: { $0 === tab }) })?.key,
              let index = parked[space]?.tabs.firstIndex(where: { $0 === tab }) else { return }
        remember(tab, at: index)
        if tab.pin == nil {
            Diary.shared.closed(tab.id)
            DiaryPage.noted[tab.id] = nil
        }
        AgentPage.forget(tab)
        pageTranslation.forget(tab)
        dropPeek(of: tab)
        if fileWaiting(for: tab) { dropFiles() }
        dropAsks(tab)
        closeParked(tab, in: space)
    }

    /// Finished agents' temporary pages can be in a parked space. Remember
    /// them just like an ordinary close, without switching the user's space.
    func closeAgentTab(_ tab: Tab) {
        guard tab.bench, tab.agent != nil, tab.pin == nil, !tab.kept, !onScreen(tab.id) else { return }
        if tabs.contains(where: { $0 === tab }) { close(tab); return }
        guard let space = parked.first(where: { $0.value.tabs.contains(where: { $0 === tab }) })?.key,
              let index = parked[space]?.tabs.firstIndex(where: { $0 === tab }) else { return }
        remember(tab, at: index)
        AgentPage.forget(tab)
        pageTranslation.forget(tab)
        dropPeek(of: tab)
        if fileWaiting(for: tab) { dropFiles() }
        dropAsks(tab)
        closeParked(tab, in: space)
    }

    /// ⌘W, or the cross on the tab. Closing the last one leaves the field
    /// on the window's own ground; ⌘W with no tab in front closes the
    /// window.
    func close(_ tab: Tab) {
        // The tab it lands on next takes no page from another window.
        BrowserWindows.handingOff += 1
        defer { BrowserWindows.handingOff -= 1 }
        if !tab.bench { Lag.shared.begin(.closeTab) }
        AgentPage.forget(tab)
        pageTranslation.forget(tab)
        AssistantApprovals.shared.closed(tab: tab.id)
        // A cloud assistant keeps working in its granted space while the
        // user is elsewhere. Closing that tab must not switch their space.
        if tab.bench, tab.assistantSpace != nil, let home = spaceHolding(tab.id) {
            dropPeek(of: tab)
            if fileWaiting(for: tab) { dropFiles() }
            dropAsks(tab)
            closeParked(tab, in: home)
            return
        }
        // A pair still coming apart finishes first: ⌘W twice.
        settleNow()
        // The other half a pin's copy: the pair goes whole, the copy with it
        // (`dropCarried`), and you land on the pin, on that same page.
        if tab.pin == nil, !tab.kept, let pair = pair(of: tab.id), let other = partner(of: tab),
           let home = carriedHome(other) {
            pairs.removeAll { $0 == pair }
            if activeID == tab.id || activeID == other.id { select(home) }
            return close(tab)
        }
        // The tab in front closed while a switch away from it waits for the
        // next page's first frame: that switch lands first, and this one
        // closes behind it. OneTab brings its list to the front and then
        // closes the tabs it kept; the switch was dropped, and the window
        // stood on the empty field with the list behind it (feedback #156).
        if activeID == tab.id, let pending = switchPending, pending != tab.id,
           let next = tabs.first(where: { $0.id == pending }) {
            finishSelect(next)
        }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.pin == nil, !tab.kept, !tab.bench, let born = tab.linkBorn, Date().timeIntervalSince(born) < Teach.glance {
            Teach.shared.shutSoon(in: self)
        }
        if tab.pin == nil {
            Diary.shared.closed(tab.id)
            DiaryPage.noted[tab.id] = nil
        }
        // In a folder of today's, the rows below close up on Dia's spring;
        // its last but one, the folder goes in one frame (LinkFolders).
        if let nest = tab.nest, nest.today, !nest.staysAlone {
            ColumnMotion.next(tabs.filter { $0.nest === nest }.count == 2 ? .still : .curve(ColumnMotion.folderClose))
        }

        // A tab whose page is out in the little window takes the window with
        // it. Left alone, the window would go on holding a page belonging to a
        // tab that no longer exists.
        if floating == tab.id { land() }
        // Its peek goes with it, shown or waiting.
        dropPeek(of: tab)
        // A page waiting on a file hears that none came.
        if fileWaiting(for: tab) { dropFiles() }
        // Nobody is left to answer what the page was asking.
        dropAsks(tab)

        // A half of a pinned pair on screen: put down, the other half takes
        // the width, the square keeps both (PinPairs.swift). Alone on
        // screen, it is put down as any pin, and stays half of the pair.
        if putDownPinHalf(tab) { return }
        if tab.pin != nil, pinPair(of: tab.id) != nil { tab.pairRest = true }

        // A pinned tab is not closed by ⌘W, it is put down. The letter keeps
        // its place, the page is let go, and you land on whatever you were
        // looking at before. Only Unpin takes it out of the row. A kept tab
        // the same: its row stays above the line (Kept.swift).
        if tab.pin != nil || tab.kept {
            var leavesActive = activeID == tab.id
            // Put down, it goes back to where it was pinned or kept, as
            // Arc's pinned tabs and Favorites "always revert back to the
            // original link" (PinnedHome.swift).
            // One of two side by side, as Arc's ⌘W in a split measured
            // (register #443, evals/split-pin/arc_cmd_w.py). A pinned pair's
            // half was put down above and stays its half.
            if pinPair(of: tab.id) == nil, let pair = pair(of: tab.id), let other = partner(of: tab) {
                if other.pin != nil || other.kept {
                    // Both pinned or kept, Arc's pinned split: the two are
                    // put down together and stay a pair, and you land as ⌘W
                    // on one alone lands you. Taken apart, as it was, the
                    // split was gone and each half was a row of its own.
                    leavesActive = leavesActive || activeID == other.id
                    other.rest(closing: true)
                    if other.awayFromHome { other.sendHome() }
                } else {
                    // Beside a tab of today's (a split brought in from Arc,
                    // an older session): this one goes to sleep, out of the
                    // pair, and the other takes the width and is where you
                    // land, as Arc's pinned tab does in a split with one of
                    // today's. Left in the pair, it stayed on screen.
                    leave(pair, keeping: other.id) { [self] in
                        pairs.removeAll { $0.contains(tab.id) }
                        tab.rest(closing: true)
                        if tab.awayFromHome { tab.sendHome() }
                        writeSession(now: true)
                    }
                    return
                }
            }
            tab.rest(closing: true)
            if tab.awayFromHome { tab.sendHome() }
            // Pins and kept rows share the same live MRU order. Putting a
            // page down never wakes another one just to replace it, nor
            // moves away from a page already in front on a background close.
            if leavesActive {
                if let back = backTo(leaving: tab, liveOnly: true) {
                    closedOnto = back.id
                    select(back)
                } else {
                    activeID = nil
                    askNew()
                }
            }
            writeSession(now: true)
            return
        }

        // One of the two on screen: the other takes the width, and is where
        // you land.
        if let pair = pair(of: tab.id), stagePair == pair, let other = partner(of: tab) {
            leave(pair, keeping: other.id) { [self] in
                guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                remember(tab, at: index)
                tab.close()
                // Closing the page can run the page's own close handlers and
                // another tab's with them, so the row may have shifted:
                // looked up again, not removed at the index from before.
                tabs.removeAll { $0.id == tab.id }
            }
            return
        }

        // The page you were on just before this one: closing goes back
        // there, as Arc's ⌘W does, today's, a pin or a kept tab alike, and
        // the same page ⌃Tab's first step would land on (`backTo`). One
        // step only: on a tab ⌘W just landed on, the one before it has
        // gone, and Arc takes the neighbor rather than walking further back
        // (evals/close-order/close_order.py).
        let agents = Agents.shared
        let previous: Tab? = activeID == tab.id && !inMail && closeLanded != tab.id ? backTo(leaving: tab) : nil

        // The tab this one was opened from, a pin or a kept tab among them,
        // when the page before has gone: back there, as Arc goes back to the
        // Favorite a link came from, even when it was the last of today's
        // tabs. Only while it is still open: a pin or kept tab put down
        // since is not woken for it, or closing today's tabs one by one
        // reopened the folder tabs they came from (register #388).
        let source = previous != nil ? nil : tab.from.flatMap { id in
            tabs.first { $0.id == id && $0.id != tab.id && !agents.sealed($0) && !Switcher.agents($0) && !(($0.pin != nil || $0.kept) && $0.asleep) }
        }

        // The last one you can be on: a sealed folder's tabs (Get to Know's)
        // aren't counted, and stay where they are. Nor are pins and kept
        // tabs: none of them is picked or woken, and the field stands on the
        // window's own ground, unless this tab came from one of them or one
        // still open was the page just before it. Nor an agent's own tabs,
        // which aren't yours to land on.
        if activeID == tab.id, !inMail, source == nil, previous == nil,
           !tabs.contains(where: { $0.id != tab.id && $0.pin == nil && !$0.kept && !agents.sealed($0) && !Switcher.agents($0) }) {
            // An empty private tab: the window goes with it. So does a
            // Blank Window's last tab, as Arc's ⌘W shuts that window
            // (evals/blank-window/arc_more.py); ⇧⌘T brings it back whole.
            if tab.isBlank || blank {
                BrowserWindows.shared.window(for: self)?.performClose(nil)
                return
            }
            // The last page closes as any other, into Recently Closed
            // (⌘⇧T), and the field stands on the window's own ground:
            // Escape hides the field; another ⌘W closes the empty window.
            guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            remember(tab, at: index)
            tab.close()
            tabs.removeAll { $0.id == tab.id }
            activeID = nil
            askNew()
            rememberSession()
            return
        }

        let marks = CloseMarks(Store.testing)
        // A tab of mail's space goes back to mail, as it was left, rather
        // than on to the next of its tabs: mail is what the space is for.
        // A link goes back to the tab it came from, even when that tab is
        // pinned far from it in the row. Otherwise use the neighboring tab
        // among today's, the one above first as in Arc, never a pin or a
        // kept tab's in a folder, which stands next to today's first tab in
        // the row (register #388), nor an agent's, whose tasks stand under
        // today's last one.
        let mail = inMail ? mailPageTab : nil
        let anywhere = inMail
        let today: (Tab) -> Bool = { anywhere || ($0.pin == nil && !$0.kept && !Switcher.agents($0)) }
        let next = activeID == tab.id ? mail ?? previous ?? source ?? nearestOpen(to: index, in: tabs.filter { $0.id != tab.id }, where: today, aboveFirst: true) : nil
        // The next page on screen first, from its last frame, as in Dia:
        // the closed page's teardown and the window's redraw for the switch
        // come after it, not before (Narrow.closeFirst).
        closedOnto = next?.id
        if Narrow.closeFirst, let next, showEarly(next) {
            marks?.shown()
        }
        // Page callbacks above may have changed its place in the row.
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        remember(tab, at: index)
        marks?.begin("teardown")
        tab.close()
        marks?.end("teardown")
        // The row may have shifted while the page closed (crash #225,
        // Array.remove out of range): removed by identity.
        tabs.removeAll { $0.id == tab.id }
        // select() wakes the next one if needed.
        if let next {
            marks?.begin("select")
            select(next)
            marks?.end("select")
            closeLanded = next.id
        }
        rememberSession()
        marks?.done()
    }

    /// ⌘W timed, in a test world only, for the bench's `pace close`: when
    /// the next page was on screen (shown early, else the commit at the end
    /// of the pass), and what the teardown and the switch cost.
    @MainActor final class CloseMarks {
        static var last: [String: Double] = [:]
        private let t0 = CACurrentMediaTime()
        private var started: [String: Double] = [:]
        private var marks: [String: Double] = [:]

        init?(_ on: Bool) {
            guard on else { return nil }
            Self.last = [:]
        }

        private func ms(_ t: Double) -> Double { ((t - t0) * 10000).rounded() / 10 }
        func shown() { marks["shown_ms"] = ms(CACurrentMediaTime()); marks["early"] = 1 }
        func begin(_ name: String) { started[name] = CACurrentMediaTime() }
        func end(_ name: String) {
            guard let start = started[name] else { return }
            marks[name + "_ms"] = ((CACurrentMediaTime() - start) * 10000).rounded() / 10
        }

        /// Done in `close`; the pass it ran in ends with Core Animation's
        /// commit (order 2000000), noted just after it.
        func done() {
            marks["close_ms"] = ms(CACurrentMediaTime())
            Self.last = marks
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001) { [self] _, _ in
                MainActor.assumeIsolated {
                    Self.last["committed_ms"] = ms(CACurrentMediaTime())
                    if Self.last["shown_ms"] == nil { Self.last["shown_ms"] = Self.last["committed_ms"] }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    /// Where you land once the tab at `index` has gone: the nearest tab on
    /// its right, else on its left (`aboveFirst`: the other way round), of
    /// those that `fits`; never one of a sealed folder's, which isn't yours
    /// to land on.
    private func nearestOpen(to index: Int, in tabs: [Tab]? = nil, where fits: (Tab) -> Bool = { _ in true }, aboveFirst: Bool = false) -> Tab? {
        let agents = Agents.shared
        let tabs = tabs ?? self.tabs
        let at = min(max(index, 0), tabs.count)
        let below = tabs[at...].first { !agents.sealed($0) && fits($0) }
        let above = tabs[..<at].last { !agents.sealed($0) && fits($0) }
        return aboveFirst ? above ?? below : below ?? above
    }

    /// The page you were on before `tab`, where ⌃Tab's first step goes
    /// (`switchStep`): the one left last, by `touched`, a tab opened behind
    /// counting as one just left, as in Arc. Never an agent's own tab, a
    /// sealed folder's, nor a pin or kept tab put down since: none is
    /// woken for it. Putting a retained page down also excludes sleeping
    /// Today's tabs: only a page still live can replace it.
    func backTo(leaving tab: Tab, liveOnly: Bool = false) -> Tab? {
        let agents = Agents.shared
        return tabs.lazy
            .filter { $0.id != tab.id && !agents.sealed($0) && !Switcher.agents($0)
                && (!$0.asleep || (!liveOnly && $0.pin == nil && !$0.kept)) }
            .max { $0.touched < $1.touched }
    }

    /// Everything but these. Pinned tabs are put down rather than removed,
    /// they are not open pages so much as places kept.
    func closeOthers(but keep: [Tab]) {
        let agents = Agents.shared
        let kept = Set(keep.map(\.id))
        guard let first = keep.first(where: { !agents.sealed($0) }) else { return }
        if let activeID, !kept.contains(activeID) { select(first) }
        // A call is never one of the others: it goes only by itself. Nor is
        // a sealed folder's tab: Yab's own work, which ends with it.
        let others = tabs.filter { !kept.contains($0.id) && !$0.onCall && !agents.sealed($0) }
        let still = gathered
        closeInDust(others)
        gathered = still
    }

    /// Closing the others or those to one side: today's rows go to dust as
    /// Clear's do, then close; pinned and kept ones are put down at once.
    /// With no dust to be had, closed as they always were. Nor over the
    /// column brought out over the page: the menu's close puts it away, and
    /// the dust flew on with no rows under it.
    private func closeInDust(_ group: [Tab]) {
        let loose = group.filter { $0.pin == nil && !$0.kept }
        guard !loose.isEmpty, !prefs.sideShut,
              dust(loose, then: { [weak self] left in self?.close(left) }) else { return close(group) }
        let resting = group.filter { $0.pin != nil || $0.kept }
        if !resting.isEmpty { close(resting) }
    }

    /// Ordinary tabs strictly outside the selected run. Kept places, calls,
    /// sealed agent work and the visible split's other half stay where they
    /// are. The menu, palette and key monitor all use these same targets.
    func sideCloseTargets(_ group: [Tab], before: Bool) -> [Tab] {
        let agents = Agents.shared
        let selected = Set(group.map(\.id))
        let indices = tabs.indices.filter { selected.contains(tabs[$0].id) }
        guard let boundary = before ? indices.first : indices.last,
              tabs[boundary].pin == nil, !tabs[boundary].kept,
              !agents.sealed(tabs[boundary]) else { return [] }
        var protected = selected
        for tab in group {
            if let partner = partner(of: tab) { protected.insert(partner.id) }
        }
        // A context menu can be opened on a background tab. Closing to its
        // side must leave the page already on screen and its split in place.
        if let active {
            protected.insert(active.id)
            if let partner = partner(of: active) { protected.insert(partner.id) }
        }
        return tabs.indices.compactMap { index in
            guard before ? index < boundary : index > boundary else { return nil }
            let tab = tabs[index]
            return tab.pin == nil && !tab.kept && !tab.onCall && !agents.sealed(tab)
                && !protected.contains(tab.id) ? tab : nil
        }
    }

    func closeBefore(_ group: [Tab]? = nil) {
        closeInDust(sideCloseTargets(group ?? chosen, before: true))
    }

    func closeAfter(_ group: [Tab]? = nil) {
        closeInDust(sideCloseTargets(group ?? chosen, before: false))
    }

    // MARK: - more than one

    /// Tabs picked alongside the open one, the way Arc does it: ⇧-click takes
    /// the run from the open tab to the one clicked, ⌘-click one more or one
    /// fewer. The open tab is always among them and the end every run starts
    /// from, and the page doesn't change for any of it, picking twenty tabs
    /// to close shouldn't wake the nineteen of them that were asleep. Going
    /// to another tab puts them all down. Never saved.
    private(set) var gathered: Set<Tab.ID> = [] {
        willSet { relay.send(\.gathered, newValue) }
    }

    /// The open tab and everything picked with it, in the row's order.
    var chosen: [Tab] {
        tabs.filter { $0.id == activeID || gathered.contains($0.id) }
    }

    /// More than the open tab is picked. Asked by every tab on every draw, so
    /// it counts rather than looks through.
    var several: Bool {
        gathered.count > 1 || (gathered.count == 1 && activeID.map { !gathered.contains($0) } ?? true)
    }

    /// How many a tab command would act on, without walking the row for the
    /// common answer: the menu bar asks on every change the window sees.
    var chosenCount: Int { several ? chosen.count : (activeID == nil ? 0 : 1) }

    func isPicked(_ tab: Tab) -> Bool { several && (tab.id == activeID || gathered.contains(tab.id)) }

    /// What a tab's own menu acts on: all of them, if it is one of them;
    /// otherwise that tab alone, and the picking is left as it was.
    func group(for tab: Tab) -> [Tab] {
        isPicked(tab) ? chosen : [tab]
    }

    /// A click on a tab, read for the keys held with it. True if it was a
    /// picking click and there is nothing more to do.
    func pick(_ tab: Tab) -> Bool {
        // The keys the click came with, as its own event says: the same as
        // the keyboard's for a hand, and the only ones for a posted click.
        let event = NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0 : nil }
        switch Self.rowClick(event?.modifierFlags ?? NSEvent.modifierFlags, groups: prefs.optShiftFolders) {
        case .group:
            return groupClick(tab)
        case .extend:
            extend(to: tab)
            return true
        case .gather:
            guard tab.id != activeID else { return true }
            cancelTabEdit()
            if gathered.contains(tab.id) { gathered.remove(tab.id) } else { gathered.insert(tab.id) }
            return true
        case .split:
            splitClick(tab)
            return true
        case .open:
            break
        }
        // A plain click on the open tab with others picked puts them down;
        // the next one edits its address, as ever.
        if several, tab.id == activeID {
            gathered = []
            return true
        }
        return false
    }

    /// ⇧-click: the run from the open tab to this one, in the row's own
    /// order, pins included, if it crosses them; a sealed folder's tabs
    /// never.
    func extend(to tab: Tab) {
        cancelTabEdit()
        let agents = Agents.shared
        guard !agents.sealed(tab), let from = tabs.firstIndex(where: { $0.id == activeID }),
              let to = tabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        gathered = Set(tabs[min(from, to)...max(from, to)].filter { !agents.sealed($0) }.map(\.id))
    }

    /// ⇧⌘A: the whole row picked, for one command to act on all of it, but
    /// a sealed folder's tabs, which no command of yours acts on.
    func pickAll() {
        guard tabs.count > 1 else { return }
        cancelTabEdit()
        let agents = Agents.shared
        gathered = Set(tabs.filter { !agents.sealed($0) }.map(\.id))
    }

    /// Escape. True if there was anything to put down.
    func unpick() -> Bool {
        guard several else { return false }
        gathered = []
        return true
    }

    /// ⌘W with several picked, or Close from their menu: one batch, which
    /// ⌘⇧T brings back whole. A sealed folder's tabs are left alone: Yab's
    /// own work closes them itself, one by one, as it ends.
    /// `batch`: the batch's id, given by one who brings it back itself
    /// (tabs.close), a single tab included.
    func close(_ group: [Tab], batch given: UUID? = nil) {
        let agents = Agents.shared
        let group = group.filter { !agents.sealed($0) }
        guard group.count > 1 || (given != nil && !group.isEmpty) else {
            if let tab = group.first { close(tab) }
            return
        }
        let going = Set(group.map(\.id))
        var nowhere = false
        // Somewhere to land first, so no tab on its way out is woken just to
        // be closed: the first page after the last one going, or failing that
        // the nearest before it. A pin being put down is no place to land.
        if let activeID, going.contains(activeID) {
            let last = tabs.lastIndex { going.contains($0.id) } ?? 0
            let staying = tabs.indices.filter { !going.contains(tabs[$0].id) && !agents.sealed(tabs[$0]) }
            let loose = staying.filter { tabs[$0].pin == nil && !tabs[$0].kept && !Switcher.agents(tabs[$0]) }
            if let landing = loose.first(where: { $0 > last }) ?? loose.last ?? ((inMail) ? staying.last : nil) {
                select(tabs[landing])
            } else {
                // Nowhere: no tab in front, the field on the window's own
                // ground once they have gone.
                self.activeID = nil
                nowhere = true
            }
        }
        // The row, and the list of the closed, each written once: a write
        // per tab was a redraw of the whole window per tab.
        let batch = given ?? UUID()
        var row = tabs
        var gone: [Ghost] = []
        for index in row.indices.reversed() where going.contains(row[index].id) {
            let tab = row[index]
            pageTranslation.forget(tab)
            if floating == tab.id { land() }
            dropPeek(of: tab)
            if tab.pin != nil || tab.kept {
                tab.rest(closing: true)
                // Put down back home, as one alone is (PinnedHome.swift).
                if tab.awayFromHome { tab.sendHome() }
                continue
            }
            // Where it stood in the full row, which is where ⌘⇧T puts it,
            // and among the kept, for a kept one removed by hand.
            let keptAt = unkeptAt.removeValue(forKey: tab.id)
            let left = unkept.removeValue(forKey: tab.id)
            if !tab.shy, !agents.sealed(tab), let url = tab.address, !MailPage.isMail(url) {
                gone.append(Ghost(url: url, title: tab.title, index: index, batch: batch, nest: left ?? tab.nest.flatMap { $0.today ? $0 : nil }, kept: left != nil,
                                  keptAt: keptAt, history: tab.history))
            }
            tab.close()
            row.remove(at: index)
        }
        tabs = row
        if !gone.isEmpty { keepGhosts(ghosts + gone.reversed()) }
        if nowhere { askNew() }
        writeSession(now: true)
    }

    /// The loose tabs in a new order: several dragged at once.
    func arrange(loose order: [Tab.ID]) {
        if startsArranging { return arranging { arrange(loose: order) } }
        let pins = tabs.filter { $0.pin != nil }
        let byID = Dictionary(tabs.lazy.filter { $0.pin == nil }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let loose = order.compactMap { byID[$0] }
        guard loose.count == byID.count, loose.count == order.count else { return }
        tabs = pins + loose
        rememberSession()
    }

    /// Duplicate with several: a copy of each, together after the last of them, and
    /// the copies are picked alongside the current tab, which stays in front.
    func duplicate(_ group: [Tab]) {
        guard group.count > 1 else {
            if let tab = group.first { duplicate(tab) }
            return
        }
        let ids = Set(group.map(\.id))
        guard let last = tabs.lastIndex(where: { ids.contains($0.id) }) else { return }
        let sources = group.compactMap { source -> (Tab, URL)? in
            source.address.map { (source, Browser.page($0)) }
        }
        let copies = sources.map { source, url in
            // Each copy keeps its source's privacy and sign-ins, as a
            // single Duplicate does, including a private artifact page.
            let tab: Tab
            if ArtifactPages.isPage(url) {
                tab = Tab(shy: windowPurpose == .privateOnly || source.shy, configuration: ArtifactPages.configuration())
            } else if source.shy {
                tab = Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
            } else {
                tab = Tab(shy: windowPurpose == .privateOnly, configuration: configuration(for: url))
            }
            prepare(tab)
            return tab
        }
        guard !copies.isEmpty else { return }
        // Beside them, but never above the line: a copy is today's.
        tabs.insert(contentsOf: copies, at: max(last + 1, keptEnd))
        for (tab, source) in zip(copies, sources) { tab.go(to: source.1) }
        gathered = Set(copies.map(\.id))
        rememberSession()
    }

    /// ⌘⇧C with several: every address, one to a line.
    func copyAddresses(_ group: [Tab]) {
        let urls = group.compactMap(\.address).map(Diary.shareable)
        guard !urls.isEmpty else { return }
        guard urls.count > 1 else {
            if let tab = group.first(where: { $0.address != nil }) { copyAddress(tab) }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        announce("\(urls.count) addresses copied", mark: "link", feedback: .success)
    }

    /// A folder's Copy N Links: every address under it, one to a line, its
    /// tabs left where they are.
    func copyLinks(_ group: [Tab]) {
        let urls = group.compactMap(\.address).map(Diary.shareable)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
        announce(urls.count == 1 ? "Link copied" : "\(urls.count) links copied", mark: "link", feedback: .success)
    }

    /// ⌘⇧B with several, or tabs let go of over a folder: kept together, in
    /// that folder, or in a new one named for their site if they share one,
    /// or for the day if they don't. The tabs stay open.
    func keep(_ group: [Tab], in folder: Bookmark.ID? = nil) {
        let sites = group.compactMap { tab in
            tab.address.flatMap { Bookmark.keepable($0) ? Bookmark.site(tab.title, $0) : nil }
        }
        guard !sites.isEmpty else { return }
        if let folder, let name = Bookmarks.folders(bookmarks.roots).first(where: { $0.node.id == folder })?.node.title {
            bookmarks.insert(contentsOf: sites, into: folder)
            announce(sites.count == 1 ? "Bookmarked in \(name)" : "\(sites.count) tabs bookmarked in \(name)", mark: "folder.bookmark", feedback: .success)
            return
        }
        guard sites.count > 1 else {
            if let url = group.first?.address, bookmarks.contains(url) {
                announce("Already bookmarked", mark: "bookmark.check")
                return
            }
            bookmarks.insert(sites[0], into: nil)
            announce("Bookmarked", mark: "bookmark.check", feedback: .success)
            return
        }
        let hosts = Set(sites.compactMap(\.host))
        let name = hosts.count == 1
            ? Address.pretty(URL(string: "https://\(hosts.first!)")!)
            : Date.now.formatted(AppDates.dateTime.day().month(.abbreviated))
        bookmarks.insert(.folder(name, sites), into: nil)
        announce("\(sites.count) tabs bookmarked in \(name)", mark: "folder.bookmark", feedback: .success)
    }

    func pauseMedia(_ group: [Tab]) {
        // Either engine: Chromium's frames pause through YabCore.
        func pause(_ tab: Tab) {
            if let page = tab.builtPage as? ChromiumPage { page.mediaAction("pause") } else { tab.webKitOnly("Pause all media")?.pauseAllMediaPlayback(completionHandler: {}) }
        }
        guard group.count > 1 else {
            if let tab = group.first { pause(tab) }
            return
        }
        for tab in group where !tab.asleep && !tab.isBlank { pause(tab) }
    }

    /// Pinned in the order they stand, at the end of the pins, or from
    /// `index` on, where a stack of them was let go of over the grid. One
    /// new row and one write, however many there are.
    func pin(_ group: [Tab], at index: Int? = nil) {
        if startsArranging { return arranging { pin(group, at: index) } }
        guard !blank else { return }
        // A half of a pair stays in it, a square on its page pinned for it
        // (`pin(_ tab:)`).
        let pinning = group.filter { $0.pin == nil && !$0.isBlank && !Agents.shared.sealed($0) }
            .map { pair(of: $0.id) == nil ? $0 : pinStandIn(for: $0) ?? $0 }
        guard !pinning.isEmpty else { return }
        let ids = Set(pinning.map(\.id))
        if !pairs.isEmpty { pairs.removeAll { ids.contains($0.first) || ids.contains($0.second) } }
        let shared = showsShared(spaceID)
        for tab in pinning {
            if tab.agent != nil { folderBook.keep(tab) }
            tab.pin = tab.monogram
            tab.kept = false
            tab.nest = nil
            if shared, Browser.sharable(tab) { tab.everywhere = tab.id }
        }
        var pins = tabs.filter { $0.pin != nil && !ids.contains($0.id) }
        pins.insert(contentsOf: pinning, at: min(max(0, index ?? pins.count), pins.count))
        tabs = pins + tabs.filter { $0.pin == nil }
        writeSession(now: true)
    }

    /// Back to the head of the loose tabs, in the order they stood.
    func unpin(_ group: [Tab]) {
        if startsArranging { return arranging { unpin(group) } }
        for tab in group where tab.pin != nil && MailPage.isMail(tab.pending ?? tab.address) { unpinMail(tab) }
        let unpinning = group.filter { $0.pin != nil && !MailPage.isMail($0.pending ?? $0.address) }
        guard !unpinning.isEmpty else { return }
        let ids = Set(unpinning.map(\.id))
        if let editing = editingPin, ids.contains(editing) { editingPin = nil }
        for tab in unpinning {
            tab.pin = nil
            tab.everywhere = nil
        }
        tabs = tabs.filter { $0.pin != nil } + tabs.filter(\.kept) + unpinning + tabs.filter { $0.pin == nil && !$0.kept && !ids.contains($0.id) }
        writeSession(now: true)
    }

    /// The ones that can sleep, asleep now rather than in four hours.
    /// `byHand`, from a menu: past what only keeps a tab from the clock
    /// (a pin, a kept row, a site that may notify). The current page may
    /// sleep by hand too, after its draft has been checked; never a visible
    /// split half, one playing, on a call, downloading or holding a draft.
    func sleep(_ group: [Tab], byHand: Bool = false) {
        let ids = Set(group.map(\.id))
        for tab in group { sleep(tab, waiving: byHand ? Self.byHand : [], byHand: byHand, excluding: ids) }
    }

    func canSleep(_ group: [Tab], byHand: Bool = false) -> Bool {
        let skipped = byHand ? Self.byHand.union(["on screen"]) : []
        return group.contains { awake(because: $0, waiving: skipped) == nil }
    }

    /// Handing the current page to sleep returns to the last live page,
    /// never waking another page or selecting one in the same sleep group.
    func leaveForSleep(_ tab: Tab, excluding group: Set<Tab.ID>) {
        guard activeID == tab.id else { return }
        let excluded = group.union([tab.id])
        let available = tabs.filter { candidate in
            guard !excluded.contains(candidate.id), !candidate.asleep, candidate.builtPage != nil,
                  !Agents.shared.sealed(candidate), !Switcher.agents(candidate) else { return false }
            // Selecting one half also wakes its partner: both must already
            // be awake, outside the group, and belong to the person.
            guard let pair = pair(of: candidate.id) else { return true }
            return [pair.first, pair.second].allSatisfy { id in
                guard !excluded.contains(id), let half = self.tab(id: id) else { return false }
                return !half.asleep && half.builtPage != nil && !Agents.shared.sealed(half)
            }
        }
        let back = recent.lazy.compactMap { id in available.first { $0.id == id } }.first
            ?? available.max { $0.touched < $1.touched }
        // Detach first: an intentional sleep must not float the old page's
        // video through the ordinary leave-on-selection path.
        activeID = nil
        if let back { finishSelect(back) } else { askNew() }
    }

    /// A link let go of over the tabs becomes a tab among them.
    func take(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let url = Address.url(from: text) else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            }
        }
        return took
    }

    /// ⌘⇧T. Back into the row at the place it left, all of them, if they
    /// were closed together, and still picked.
    /// ⌘Z for the window only outside text editing; native editors remain
    /// owners of undo. The chat's box, empty and with nothing of its own to
    /// undo, leaves it to the window as the empty field does.
    func canUndoClose(nativeEditor: Bool, emptyEditor: Bool = false) -> Bool {
        canUndoWindow && active?.typing != true && typed.isEmpty && !nativeEditor
            && (!chatAttach.typing || emptyEditor)
    }

    func reopen() {
        // A window closed since the last tab was: the window, as
        // ⇧⌘T brings back whatever was closed last.
        if reopensWindow {
            BrowserWindows.shared.reopenClosedWindow()
            return
        }
        guard let ghost = ghosts.last else { return }
        reopen(from: ghost)
    }

    /// ⇧⌘T would bring back a window: one was closed after this window's
    /// last tab was.
    var reopensWindow: Bool {
        guard let closed = BrowserWindows.shared.lastClosedAt else { return false }
        return closed > (ghosts.last?.at ?? .distantPast)
    }

    /// A ghost back, with the tabs closed together with it.
    func reopen(from ghost: Ghost) {
        if let batch = ghost.batch, tidied.contains(batch) {
            untidy(batch)
            return
        }
        guard let batch = ghost.batch else {
            reopen(ghost)
            return
        }
        let empty = active == nil
        // Put back from the front: each goes to where it stood when the row
        // still held the ones before it.
        let group = ghosts.filter { $0.batch == batch }.sorted { $0.index < $1.index }
        ghosts.removeAll { $0.batch == batch }
        var row = tabs
        let pins = keptEnd
        var back: [Tab] = []
        for ghost in group {
            let tab = Tab(configuration: configuration(for: ghost.url))
            prepare(tab)
            row.insert(tab, at: min(max(ghost.index, pins), row.count))
            back.append(tab)
        }
        tabs = row
        refold(Array(zip(back, group)))
        for (tab, ghost) in zip(back, group) {
            bringStill(of: ghost, to: tab, intoEmpty: empty && tab === back.last)
            tab.reopen(ghost)
        }
        rekeep(Array(zip(back, group)))
        guard let last = back.last else { return }
        leaving()
        activeID = last.id
        gathered = Set(back.map(\.id))
        editing = false
        typed = ""
        rememberSession()
    }

    /// One of them by name, from the History menu.
    func reopen(_ ghost: Ghost) {
        let empty = active == nil
        ghosts.removeAll { $0.id == ghost.id }
        let tab = Tab(configuration: configuration(for: ghost.url))
        prepare(tab)
        leaving()
        tabs.insert(tab, at: min(max(ghost.index, keptEnd), tabs.count))
        bringStill(of: ghost, to: tab, intoEmpty: empty)
        activeID = tab.id
        editing = false
        typed = ""
        tab.reopen(ghost)
        rekeep([(tab, ghost)])
    }

    /// Tabs taken out of the row without anything else moving: the page on
    /// screen stays, nothing is picked or woken. One batch; nil if none of
    /// them could go.
    func putAway(_ group: [Tab]) -> UUID? {
        let going = Set(group.filter { $0.pin == nil && !$0.kept && $0.id != activeID }.map(\.id))
        guard !going.isEmpty else { return nil }
        let batch = UUID()
        // From the back, so each index is still the one it had in the full
        // row, which is where they go back.
        for index in tabs.indices.reversed() where going.contains(tabs[index].id) {
            let tab = tabs[index]
            if floating == tab.id { land() }
            gathered.remove(tab.id)
            dropPeek(of: tab)
            dropAsks(tab)
            remember(tab, at: index, batch: batch)
            tab.close()
            tabs.remove(at: index)
        }
        writeSession(now: true)
        return batch
    }

    /// The last tidy-up, back where it stood. Asleep, the way a session
    /// comes back: twenty pages loading at once to undo a tidy is worse than
    /// the mess was. The page on screen stays the page on screen.
    func untidy(_ batch: UUID? = nil) {
        guard let batch = batch ?? tidied.last, tidied.contains(batch) else { return }
        tidied.removeAll { $0 == batch }
        if tidier.batches.contains(batch) { tidier.hide() }
        bringBack(batch)
        if let empty = clearedEmptyFolders.removeValue(forKey: batch) {
            for nest in empty.nests { folderBook.keepEmpty(nest, space: empty.space) }
        }
    }

    /// A batch of the closed back where each stood, asleep, kept again in
    /// the folder it left; nothing picked or woken. In the order they
    /// stood; empty when Recently Closed no longer has them (⌘⇧T took
    /// them first). The tidy-up's Undo, and tabs.close's (NativeControl).
    @discardableResult
    func bringBack(_ batch: UUID) -> [Tab] {
        let group = ghosts.filter { $0.batch == batch }.sorted { $0.index < $1.index }
        ghosts.removeAll { $0.batch == batch }
        var back: [(Tab, Ghost)] = []
        for ghost in group {
            let tab = Tab(configuration: configuration(for: ghost.url))
            prepare(tab)
            tab.restore(url: ghost.url, title: ghost.title, history: ghost.history)
            tabs.insert(tab, at: min(max(ghost.index, keptEnd), tabs.count))
            back.append((tab, ghost))
        }
        refold(back)
        rekeep(back)
        rememberSession()
        return back.map(\.0)
    }

    /// Tabs put back into the folder of today's they left, where that
    /// folder still has a tab or comes back with two or more: a folder of
    /// one would only go quietly again (Folders.refresh).
    private func refold(_ back: [(Tab, Ghost)]) {
        var count: [ObjectIdentifier: Int] = [:]
        for nest in back.compactMap(\.1.nest) { count[ObjectIdentifier(nest), default: 0] += 1 }
        for tab in tabs { if let nest = tab.nest { count[ObjectIdentifier(nest)]? += 1 } }
        var moved = false
        for (tab, ghost) in back {
            guard let nest = ghost.nest, nest.staysAlone || count[ObjectIdentifier(nest), default: 0] >= 2 else { continue }
            tab.nest = nest
            moved = true
        }
        if moved { folderBook.refresh() }
    }

    /// Kept tabs removed by hand, kept again by ⌘Z: in the folder they
    /// left, which comes back with them if it went with its last tab.
    private func rekeep(_ back: [(Tab, Ghost)]) {
        // In the order they stood among the kept, each where it was.
        for (tab, ghost) in back.sorted(by: { ($0.1.keptAt ?? .max) < ($1.1.keptAt ?? .max) }) where ghost.kept {
            keepTabs([tab], in: ghost.nest, at: keptSpot(for: ghost, besides: tab))
        }
    }

    /// Where among the kept a kept tab removed by hand goes back: where it
    /// stood, as Arc's ⌘Z puts it, inside its folder's run of tabs if the
    /// row changed since (the nearest folder up that still has one), and
    /// never past the end. Nil, with no place known, is the folder's end.
    private func keptSpot(for ghost: Ghost, besides tab: Tab) -> Int? {
        guard let at = ghost.keptAt else { return nil }
        let kept = tabs.filter { $0.kept && $0 !== tab }
        var spot = min(max(0, at), kept.count)
        var nest = ghost.nest
        while let each = nest {
            if let first = kept.firstIndex(where: { $0.nest?.within(each) == true }),
               let last = kept.lastIndex(where: { $0.nest?.within(each) == true }) {
                spot = min(max(spot, first), last + 1)
                break
            }
            nest = each.parent
        }
        return spot
    }

    /// The tab's place in Recently Closed, its id for taking it back out.
    @discardableResult
    private func remember(_ tab: Tab, at index: Int, batch: UUID? = nil) -> UUID? {
        // A private tab leaves nothing behind, Recently Closed and ⌘⇧T included;
        // nor does a sealed folder's, whose pages were never yours to see.
        let keptAt = unkeptAt.removeValue(forKey: tab.id)
        let left = unkept.removeValue(forKey: tab.id)
        guard !tab.shy, !Agents.shared.sealed(tab), let url = tab.address,
              !MailPage.isMail(url) else { return nil }
        let nest = left ?? tab.nest.flatMap { $0.today ? $0 : nil }
        let ghost = Ghost(url: url, title: tab.title, index: index, batch: batch, nest: nest, kept: left != nil, keptAt: keptAt, history: tab.history)
        // Its last frame, for ⇧⌘T to show the page at once, as Arc does,
        // rather than white till it draws again: the last few closed only.
        PageStills.shared.rehome(tab.id, to: ghost.id)
        ghostStills.append(ghost.id)
        while ghostStills.count > 3 { PageStills.shared.forget(ghostStills.removeFirst()) }
        keepGhosts(ghosts + [ghost])
        return ghost.id
    }

    /// A closed tab's last frame given to the tab bringing it back: shown
    /// on the stage in its place until that page has drawn (StageView's
    /// still), if the stage is still the size and look it was left at.
    /// A window that showed no page (its last tab closed) has no stage
    /// to stand the still on yet: the tab wears it as its cover instead, as
    /// a sleeping tab wakes under its picture.
    private func bringStill(of ghost: Ghost, to tab: Tab, intoEmpty: Bool = false) {
        guard ghostStills.contains(ghost.id) else { return }
        ghostStills.removeAll { $0 == ghost.id }
        if intoEmpty {
            if let picture = PageStills.shared.picture(of: ghost.id) { tab.cover(with: picture) }
            PageStills.shared.forget(ghost.id)
            return
        }
        PageStills.shared.rehome(ghost.id, to: tab.id, loose: true)
    }

    /// A deleted space's pages, for ⌘⇧T, together as one batch.
    @discardableResult
    func rememberClosed(_ pages: [(url: URL, title: String)]) -> UUID? {
        guard !pages.isEmpty else { return nil }
        let batch = UUID()
        keepGhosts(ghosts + pages.enumerated().map { Ghost(url: $1.url, title: $1.title, index: tabs.count + $0, batch: batch) })
        return batch
    }

    /// A deleted space back: its pages are in it again, not Recently Closed.
    func forgetGhosts(batch: UUID) {
        keepGhosts(ghosts.filter { $0.batch != batch })
    }

    /// The closed, written back once. A dozen, but never by cutting into the
    /// latest batch: ⌘⇧T after closing twenty brings back twenty.
    private func keepGhosts(_ list: [Ghost]) {
        let latest = list.last?.batch
        var list = list
        while list.count > 12, let first = list.first, first.batch == nil || first.batch != latest {
            list.removeFirst()
        }
        didClose(Set(list.map(\.id)).subtracting(ghosts.map(\.id)))
        ghosts = list
        tidied.removeAll { kept in clearedEmptyFolders[kept] == nil && !ghosts.contains { $0.batch == kept } }
    }

    /// Dragged from one place in the row to another.
    func move(_ tab: Tab, to index: Int) {
        if startsArranging { return arranging { move(tab, to: index) } }
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }),
              index != here, tabs.indices.contains(index)
        else { return }
        // The pinned block and the loose one don't mix: a letter that wandered
        // into the middle of the titles would stop meaning anything.
        let pinned = pinnedCount
        if tab.pin != nil, index >= pinned { return }
        if tab.pin == nil, index < pinned { return }
        folderBook.moving.formUnion([tab.id] + (partner(of: tab).map { [$0.id] } ?? []))
        if let other = partner(of: tab) {
            // The two go together, where the one was let go.
            tabs = Browser.moving(tabs, tab.id, to: index, with: other.id)
        } else {
            tabs.move(fromOffsets: IndexSet(integer: here), toOffset: index > here ? index + 1 : index)
        }
        rememberSession()
    }

    /// ⌥⇧⌘← and →: the open tab one place along the row, its split
    /// partner with it, and never out of the pinned block or into it.
    func nudge(_ by: Int) {
        guard let tab = active else { return }
        let partner = partner(of: tab)?.id
        let span = tabs.indices.filter { tabs[$0].id == tab.id || tabs[$0].id == partner }
        guard let low = span.first, let high = span.last else { return }
        move(tab, to: by > 0 ? high + 1 : low - 1)
    }

    /// ⇧⌘] and ⇧⌘[: the next tab or the one before, round the ends. A
    /// shut agent's folder is passed as if it weren't there, all its tabs,
    /// in the column and on top alike: shut, it is one row you didn't ask
    /// to walk into. A sealed one's always, its folder made yet or not.
    func step(_ direction: Int) {
        guard tabs.count > 1, let here = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let shut = passed()
        guard let next = Browser.stepped(from: here, by: direction, skipping: shut) else { return }
        select(tabs[next])
    }

    /// Which tabs a step passes, by where each stands: every tab of a folder
    /// that is shut, a folder of yours among the kept as much as a task's
    /// (as ⌘1 to ⌘9 don't count them), and every sealed one's, open or not.
    /// The chain includes the first shut ancestor, even if its child is open.
    static func passed(_ places: [Folders.Place?], sealed: [Bool], open: (String) -> Bool) -> [Bool] {
        zip(places, sealed).map { place, sealed in
            sealed || place.map { $0.bare ? !$0.shown : !open($0.folder) || !$0.chain.allSatisfy(open) } ?? false
        }
    }

    private func passed() -> [Bool] {
        let folders = folderBook
        let agents = Agents.shared
        return Browser.passed(tabs.map { folders.place(of: $0) }, sealed: tabs.map { agents.sealed($0) }, open: { folders.isOpen($0) })
    }

    /// Where a step from `here` lands, round the ends, passing every index
    /// `skipping` marks; nil when there is nowhere else to go.
    nonisolated static func stepped(from here: Int, by direction: Int, skipping: [Bool]) -> Int? {
        let count = skipping.count
        guard count > 1, direction != 0 else { return nil }
        let way = direction > 0 ? 1 : -1
        var at = here
        for _ in 1..<count {
            at = (at + way + count) % count
            if !skipping[at] { return at }
        }
        return nil
    }

    /// ⌘1 to ⌘8 by place among the tabs you can reach: tabs under a shut
    /// folder and sealed tasks are not counted. ⌘9 is the last.
    func select(index: Int) {
        guard let at = Browser.numbered(index, among: numberable(), count: tabs.count) else { return }
        select(tabs[at])
    }

    /// The places in the row ⌘ and a digit count among: the tabs you can
    /// reach, as `select(index:)` and the numbers ⌘ held shows (KeyNumbers).
    func numberable() -> [Int] {
        let shut = passed()
        return tabs.indices.filter { !shut[$0] }
    }

    /// Where in the row ⌘1 to ⌘9 lands: `index` counted among the tabs you
    /// can be on (`open`, their places in the row), and the row's last
    /// index, ⌘9's, the last of them.
    nonisolated static func numbered(_ index: Int, among open: [Int], count: Int) -> Int? {
        guard index >= 0, let last = open.last else { return nil }
        if index == count - 1 { return last }
        return open.indices.contains(index) ? open[index] : nil
    }

    /// A new tab, at the top of today's, as Arc opens one you asked for (at
    /// the end of the strip with the tabs across the top,
    /// as a strip grows), or at the end of the row for one of a batch, which keeps
    /// the order it came in.
    ///
    /// `from`: the tab it came out of. A private one's opens private, in the
    /// same store, still signed in to whatever the private page was.
    /// `linked`: that tab's page opened it, a ⌘-click or a middle click: it
    /// goes after that page and what the page already opened (Placement.swift).
    @discardableResult
    /// `rowNow`: in the row at once, even in front: a tab an extension
    /// opens has its place from the start, and those it
    /// opens after it come after it.
    /// `userLink`: a person opened this link, for its video on first display.
    func open(_ url: URL, foreground: Bool, atEnd: Bool = false, from source: Tab? = nil, shy: Bool = false, linked: Bool = false, backToSource: Bool = true, into nest: Nest? = nil, rowNow: Bool = false, userLink: Bool = false) -> Tab {
        // An extension's own page is served only to a view built from that
        // extension's configuration.
        let url = Browser.page(url)
        let tab: Tab
        if ArtifactPages.isPage(url) {
            // An agent's published page, in a view of its own kind, private or not.
            tab = Tab(shy: windowPurpose == .privateOnly || source?.shy == true || shy, configuration: ArtifactPages.configuration())
        } else if let source, source.shy {
            tab = Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
        } else if shy || windowPurpose == .privateOnly {
            tab = Tab(shy: true, configuration: Web.configuration(shy: true))
        } else if let spare = takeSpare(for: url) {
            // WebKit already up for it (see `spare`).
            tab = spare
            OpenTrace.mark("spare \(spare.webKitOnly("WebKit native page lifecycle", build: false).map(OpenTrace.process) ?? "unbuilt")")
        } else {
            tab = OpenTrace.time("tab.init") { Tab(configuration: configuration(for: url)) }
            // None ready in this space's store: one for the next.
            if Browser.extensionConfiguration(for: url) == nil { keepSpare() }
        }
        OpenTrace.time("prepare") { prepare(tab) }
        tab.from = source?.id
        if linked, backToSource, let source { linkBack(tab, to: source) }
        // Once: put early (another tab opened, or this one picked) and then
        // by front, a tab closed between them would come back into the row.
        var placed = false
        let row = { [weak self, weak tab] in
            guard !placed, let self, let tab, !self.tabs.contains(where: { $0 === tab }) else { return }
            placed = true
            self.outside.removeAll { $0 === tab }
            if linked, let source, self.tabs.contains(where: { $0 === source }) {
                // After the page that opened it, as Arc stacks a page's links.
                let at = self.linkLanding(from: source)
                tab.linkedFrom = source.id
                if !foreground { self.revealAsked = tab.id }
                self.tabs.insert(tab, at: at)
            } else {
                // First among today's, under New Tab: never among the pins or
                // the kept, which the new tab isn't one of. With the tabs across
                // the top, last, beside the plus.
                self.tabs.insert(tab, at: atEnd ? self.tabs.count
                                 : Browser.askedLanding(count: self.tabs.count, keptEnd: self.keptEnd, strip: !self.prefs.sidebar))
            }
            // New Tab in Folder's, its row added late: on its way already.
            if let nest, tab.address != nil { self.land(tab, in: nest) }
        }
        // Its row added once its page has drawn (OPEN_LATE_ROW), outside
        // the row until then, where WebKit's questions still find it.
        // Never an extension's own page: it asks for its tab as it starts
        // (tabs.getCurrent), and a tab outside the row has no place in its
        // window to be told; OneTab's list, opened in front, never got past
        // its spinner (feedback #156).
        let lateRow = foreground && Narrow.openFirst && Narrow.openLateRow && !editing && stagePair == nil
            && active?.builtPage?.superview is StageView && Browser.extensionConfiguration(for: url) == nil && !rowNow
        // One opened in front a moment ago and still waiting for its row:
        // its row first, so the rows stand in the order they were asked for.
        putWaitingRow()
        if lateRow {
            outside.append(tab)
            waitingRow = (tab.id, row)
        } else {
            row()
        }
        if userLink, !foreground, source?.bench == false { tab.prepareVideoOpening(url) }
        OpenTrace.time("go") { tab.go(to: url) }
        // New Tab in Folder's: at the end of the folder, once it has an
        // address; a tab with none is no folder's (Folders.settle).
        if let nest, tabs.contains(where: { $0 === tab }) { land(tab, in: nest) }
        if foreground {
            let attempt = holdSwitch(to: tab.id, on: nil)
            // Once: the page's frames and the 0.3 s both call it, and the
            // second putting the row back would bring a tab closed between
            // them (⌘W, or a script's close) back into the row.
            var fronted = false
            let front = { [weak self, weak tab] in
                guard !fronted else { return }
                fronted = true
                row()
                guard let self, let tab, self.hold.holds(tab.id, attempt: attempt) else { return }
                self.releaseSwitch()
                guard self.tabs.contains(where: { $0 === tab }), self.activeID != tab.id else { return }
                OpenTrace.time("front") {
                    self.leaving()
                    self.activeID = tab.id
                    self.editing = false
                    self.typed = ""
                }
            }
            // In front at once, its page loading inside it, as Arc opens
            // one: the stage doesn't keep the page left until the site
            // answers (StageView.willOpen, feedback #206). A page already
            // drawn by then, from the cache, still has the window's redraw
            // after its next two frames, 0.3 s at most (OPEN_FIRST).
            StageView.willOpen(tab.id)
            if Narrow.openFirst, !editing, stagePair == nil, StageView.earlyOpen(from: active, to: tab),
               let stage = tab.webKitOnly("WebKit native page lifecycle", build: false)?.superview as? StageView,
               let web = tab.webKitOnly("WebKit first-paint scheduling", build: false) {
                heldStage = stage
                stage.heldFor = tab.id
                // Then the page's own next frames, so the redraw doesn't
                // land on them either.
                func frames(_ left: Int) {
                    guard left > 0 else { return front() }
                    StageView.afterNextDrawing(web) { DispatchQueue.main.async { frames(left - 1) } }
                }
                stage.afterReveal(of: web) { frames(Narrow.openFirstFrames) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { front() }
            } else {
                front()
            }
        }
        return tab
    }

    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.unpopped(Extensions.current(url)) }
        return url
    }

    /// The configuration for an extension's page, or nil for anything else.
    /// The extension an address belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// `space`: whose sign-in's extension it is, the one new tabs go to
    /// unless said.
    static func extensionConfiguration(for url: URL, space: UUID? = nil) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return MainActor.assumeIsolated {
            Extensions.of(space: space ?? Spaces.current).controller.extensionContext(for: url)?.webViewConfiguration
        }
    }

    /// A page for the bench: at the end of the row, behind whatever you are
    /// looking at, and marked as not yours.
    @discardableResult
    func benchOpen(_ url: URL, space: UUID? = nil, shy: Bool = false) -> Tab {
        let url = Browser.page(url)
        // The test-only browserWindow route may select a private window.
        // Its lifetime purpose wins over the default argument, before a
        // normal website store or tab can be constructed.
        let privately = windowPurpose.isPrivate(active: shy)
        let tab = Tab(shy: privately, bench: true, configuration: privately ? nil
                      : Browser.extensionConfiguration(for: url, space: space ?? spaceID)
                        ?? Web.configuration(store: Spaces.store(for: space ?? spaceID)))
        prepare(tab)
        tab.assistantSpace = space ?? spaceID
        tabs.append(tab)
        tab.go(to: url)
        return tab
    }

    /// A page a task from the iPhone reads (SyncTaskRead): behind the tabs,
    /// in its space's website store, with none of the browser's own
    /// callbacks, so a page can't start a draft, a download, a popup or a
    /// sign-in; RemoteReadPage is its only delegate.
    func makeRemoteReadTab(url: URL, store: WKWebsiteDataStore, session: String, policy: RemoteReadPage) -> Tab {
        let configuration = Web.configuration(store: store)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let tab = Tab(bench: true, configuration: configuration, factory: .webKitOnly)
        tab.agent = session
        policy.attach(to: tab)
        tabs.append(tab)
        tab.go(to: url)
        return tab
    }

    /// Closed by the task that owns it: never the person's page in front,
    /// and nothing goes to Recently Closed.
    func closeRemoteReadTab(_ tab: Tab, session: String) {
        guard tab.bench, !tab.shy, tab.agent == session, tab.id != activeID,
              let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        AgentPage.forget(tab)
        tab.close()
        tabs.remove(at: index)
    }

    /// Tabs of yours, many at once, for ./load: at the end of the row,
    /// behind the one on screen, either loading or asleep the way last
    /// session's tabs come back.
    func flood(_ urls: [URL], asleep: Bool) {
        for url in urls {
            if asleep {
                let tab = blankTab()
                prepare(tab)
                tab.restore(url: url, title: url.host() ?? url.absoluteString)
                tabs.append(tab)
            } else {
                open(url, foreground: false, atEnd: true)
            }
        }
    }

    /// A link from another app. A blank tab with nothing typed in it takes
    /// the page rather than staying behind as an empty one; otherwise the
    /// page gets a tab of its own, in front.
    func arrive(_ url: URL) {
        if let active, active.isBlank, typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A bookmark, or a page from a list of them: into the tab you are on,
    /// the way every bookmarks bar has ever worked, or, as a link does, into
    /// a new one behind with ⌘ held or the middle button, in front with ⇧⌘;
    /// and into one in front when the tab you are on is playing in the float.
    func visit(_ url: URL, middle: Bool = false) {
        let event = NSApp.currentEvent
        if let front = Browser.beside(event) ?? (middle ? event?.modifierFlags.contains(.shift) == true : nil) {
            let opened = open(url, foreground: front, from: active)
            if !front { sayBehind(opened, url, from: active) }
        } else if let active, !active.floating {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: true)
        }
    }

    /// Past this many, opening a folder's bookmarks all at once asks first,
    /// so a slip of the hand opens nothing big.
    static let openAllAsk = 15

    /// Every bookmark in a folder, its folders' too, each in a tab of its
    /// own behind the one you are on; asked first when there are many.
    func openAll(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let go = { [weak self] in
            guard let self else { return }
            // Each lands where a tab you ask for does: the top of today's,
            // or the end of the strip. Read in the folder's order either way.
            for url in self.prefs.sidebar ? urls.reversed() : urls { _ = self.open(url, foreground: false, from: self.active) }
        }
        guard urls.count > Self.openAllAsk else { return go() }
        Task { @MainActor in
            if await Questions.shared.ask(Question(title: "Open all \(urls.count) tabs?", glyph: "folder", yes: "Open All")) { go() }
        }
    }

    /// ⌘⇧N. A tab that keeps nothing, its own cookies, its own sign-ins, no
    /// history, and no place in tomorrow's session.
    func newShyTab() {
        let tab = Tab(shy: true)
        // Going private from a tab that kept things is the moment; from
        // another private tab the page is already dark, and nothing changes.
        if !privateBrowsing { tab.hushedAt = Date() }
        adopt(tab)
        leaving()
        activeID = tab.id
        typed = ""
        editing = false
        query.focusRequest += 1
        // The field says it now, "Nothing here is kept", so no pill
        // says it again; only a screen reader is told in words.
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: "Private tab. Nothing here is kept.", .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// A private tab with nothing in it yet is a place of the field's own,
    /// as one site's search is: Private at the foot, the way back where the
    /// glass was.
    var privateLeavable: Bool {
        guard fieldGuest == nil, let tab = active, tab.shy, tab.isBlank else { return false }
        return query.place == nil && query.scope == nil && emojiWords == nil && !query.answering
    }

    /// ‹, ⌫ in the empty field or Escape out of Private, as out of a site's
    /// search: the empty private tab goes, and the plain field stands over
    /// the last tab that keeps things, what was typed kept. With none, on
    /// the window's own ground; never another private page, whose ⌘T would
    /// only be Private again.
    @discardableResult
    func leavePrivate() -> Bool {
        guard privateLeavable, let tab = active else { return false }
        let words = typed
        let agents = Agents.shared
        let back = tabs
            .filter { $0.id != tab.id && !$0.shy && $0.pin == nil && !$0.kept && !agents.sealed($0) }
            .max(by: { $0.touched < $1.touched })
        if let back {
            select(back)
            close(tab)
            newTab()
        } else if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tab.close()
            tabs.remove(at: index)
            activeID = nil
            askNew()
            rememberSession()
        }
        if !words.isEmpty { typed = words }
        return true
    }

    /// Duplicate Tab. The same page, right after itself and behind it, as Arc's
    /// Duplicate leaves you on the one you had; from above the line, at the
    /// top of today's, the column's and the strip's alike.
    func duplicate(_ page: Tab? = nil) {
        guard let source = page ?? active, let url = source.address else { return }
        let copy = open(url, foreground: false, from: source)
        guard let at = tabs.firstIndex(where: { $0 === copy }) else { return }
        if source.pin != nil || source.kept {
            // Opened as a tab you ask for, it is at the strip's far end.
            move(copy, to: min(keptEnd, tabs.count - 1))
            return
        }
        guard let here = tabs.firstIndex(where: { $0 === source }), at != here + 1 else { return }
        move(copy, to: at > here ? here + 1 : here)
    }

    /// ⌘⇧V. What is in the clipboard, if it is a place, or a search.
    func pasteAndGo() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = searchEngine.destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            refusals += 1
            return
        }
        place(url, asking, from: active)
        editing = false
        typed = ""
    }

    /// ⌘P. The system's own sheet, which is also where "save as PDF" lives.
    func printPage() {
        // AppKit can dispatch a menu equivalent before a local key monitor.
        // The DevTools responder keeps Quick Open even through that route.
        if devOpen, let window = BrowserWindows.shared.window(for: self), DevKeys.contains(window.firstResponder) { openDevCommand(""); return }
        // A peek over the tab is what is being looked at.
        guard let tab = peeking ?? active, let window = BrowserWindows.shared.window(for: self) ?? NSApp.keyWindow else { return }
        Self.printSheet(tab, in: window)
    }

    /// A tab's page in the system's sheet, over the window it is in: the
    /// browser's, or a small window's (LinkWindow).
    static func printSheet(_ tab: Tab, in window: NSWindow) {
        guard !tab.isBlank else { return }
        if let page = tab.page as? ChromiumPage { page.printSheet(in: window); return }
        guard let web = tab.webKitOnly("System print sheet") else { return }
        // Paper stays white: a darkened page is put back as the site sent
        // it for the sheet, and darkened again after (DarkPages).
        guard tab.dark == .engine else { return printSheet(web, frame: nil, in: window) }
        tab.darkPrint(true) { [weak tab, weak window] in
            guard let tab, let window else { return }
            guard let web = tab.webKitOnly("System print sheet") else { return }
            printSheet(web, frame: nil, in: window) { [weak tab] in tab?.darkPrint(false) {} }
        }
    }

    /// `web`'s page in the system's sheet: the frame WebKit names (a
    /// page's window.print() from an iframe), or the whole page.
    static func printSheet(_ web: WKWebView, frame: AnyObject?, in window: NSWindow, done: (@MainActor () -> Void)? = nil) {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let framed = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        let job: NSPrintOperation
        if let frame, web.responds(to: framed),
           let own = web.perform(framed, with: info, with: frame)?.takeUnretainedValue() as? NSPrintOperation {
            job = own
        } else {
            job = web.printOperation(with: info)
        }
        job.view?.frame = web.bounds
        printed = web.url
        let end = done.map { PrintEnd($0) }
        job.runModal(for: window, delegate: end, didRun: end == nil ? nil : PrintEnd.selector, contextInfo: nil)
    }
    /// The page last put in the print sheet, for a probe to tell which.
    static var printed: URL?

    private func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Stepping away from a tab. A video you were watching does not stop
    /// existing because you went to look something up.
    private func leaving() {
        guard prefs.floatsOnLeave || presenting else { return }
        // A call comes along whatever the site: it is the one thing on it.
        if let active, active.onCall { return liftCall(active) }
        guard minimizeHold.allowsAuto(active?.id) else { return }
        pictureOut(active, quietly: true, tabLeft: true)
    }

    /// Going to another space: a video playing in front comes along, as
    /// for a tab left. A call has its own way across (switchSpace).
    func leavingSpace() {
        guard prefs.floatsOnLeave, let active, !active.onCall, minimizeHold.allowsAuto(active.id) else { return }
        pictureOut(active, quietly: true)
    }

    /// A minimized video stays in its tab until that tab is in front again
    /// (MinimizeHold).
    @ObservationIgnored var minimizeHold = MinimizeHold()

    /// The floating window's minimize: the window goes, the video plays on
    /// in its tab, where you aren't, so the island comes up with it; the
    /// island's Float Video floats it again (rows 1090, 1038).
    func minimizeFloat() {
        traceFloat("minimize", tab: floatedTab)
        if let tab = floatedTab, floater.kind == .video { minimizeHold.minimized(tab.id) }
        land()
    }

    /// Lifted because another app came to the front, and so to go home on
    /// its own when yab does. One already out stays out.
    @ObservationIgnored private var liftedAway = false
    // One bounded provenance record; Context holds its page/windows weakly.
    // Keep it after the request settles so a later site button cannot
    // inherit this automatic return flag after a selection change.
    @ObservationIgnored private var fullscreenAwayOwner: FullscreenPiPDeparture.Context?
    @ObservationIgnored var fullscreenDeparture = FullscreenPiPDeparture()
    /// Landings so far, for a lift to tell whether one came after it was
    /// asked for (`lift`).
    @ObservationIgnored private var landings = 0

    // Native test traces distinguish a pending page-isolation answer from
    // the window that a later Back already sent home. No production state
    // or ordering is changed by these counters or the optional test delay.
    @ObservationIgnored private var floatProbeEpoch = 0
    @ObservationIgnored private var floatProbePending = Set<Int>()

    private func traceFloat(_ event: String, request: Int? = nil, tab: Tab? = nil, quietly: Bool? = nil) {
        guard Store.testing else { return }
        var record: [String: Any] = [
            "event": event, "timestamp_ms": (CACurrentMediaTime() * 10000).rounded() / 10,
            "epoch": floatProbeEpoch, "pending": floatProbePending.sorted(),
            "tab": tab.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "",
            "active": activeID.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
            "floating": floating.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
            "showing": floater.showing, "homing": floater.homing, "lifted_away": liftedAway,
        ]
        if let request { record["request"] = request }
        if let quietly { record["quietly"] = quietly }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        FileHandle.standardError.write(Data("YAB_FLOAT_TRACE ".utf8) + data + Data("\n".utf8))
    }

    /// On a call in front and showing your screen: the call comes along
    /// whatever Settings say, to another tab or another app, since that is
    /// where what you show is, and the people are only in the window then.
    private var presenting: Bool { active.map { $0.onCall && $0.presentingScreen } ?? false }

    /// The bench's say over leaving Yab alone (evals/float-return turns it
    /// off to try a tab left, then on), nil for the switch's.
    static var benchAway: Bool?

    /// Another app in front: the video comes along, as in Arc, from the same
    /// sites that float when you leave their tab, under the same switch
    /// (Settings › Tabs, Picture in Picture automatically).
    func appLeft() {
        traceFloat("appLeft")
        guard (Self.benchAway ?? prefs.floatsOnLeave) || presenting else { return }
        if presenting { return leftNow() }
        // Its window went out of sight first, with Yab still in front: already out.
        if desktopAway { return }
        // A click on another display leaves Yab, and the video is still in
        // plain sight on this one: it stays in its page, full screen too
        // (2026-10-14). It comes out only once this window is hidden or
        // mostly covered, now or later while Yab is behind. The app in front
        // puts its window up a moment after Yab hears it left.
        awayWatch = true
        watchCover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.coverChanged()
        }
    }

    /// The page's window went out of sight with Yab still in front, and its
    /// video came along (`sightChanged`).
    @ObservationIgnored private var desktopAway = false

    /// A window in its native full-screen slide, in or out: macOS sends
    /// it occlusion changes that mean nothing until the slide is over
    /// (the lent window read occluded 30 ms into its own slide in, farm
    /// b622c7536b8342c1). Chrome ignores the same window's updates for the
    /// same reason (WebContentsOcclusionCheckerMac, crbug.com/1081229).
    @ObservationIgnored private weak var sightSliding: NSWindow?

    func fullscreenSlide(_ window: NSWindow, started: Bool) {
        if started { sightSliding = window } else if sightSliding === window { sightSliding = nil }
    }

    /// A window's occlusion changed with Yab still in front. Only the window
    /// the page in front is shown in counts (the page's own full-screen
    /// window, else the browser's), as Chromium decides automatic Picture in
    /// Picture from the tab's own view being occluded
    /// (AutoPictureInPictureTabHelper::OnOcclusionStateChanged), not from
    /// the desktop changing. A three-finger swipe, ⌃→, Mission Control or
    /// another Yab window going full screen leaves that window out of sight
    /// on a desktop no longer shown: macOS keeps the app that was active on
    /// a desktop with none of its own windows and posts no didResignActive,
    /// so the video comes along by `appLeft`'s rules (feedback #1837). In
    /// sight again, it goes home as when Yab comes back (`appBack`). A page
    /// going full screen moves into a window of its own, whose slide says
    /// nothing (`sightSliding`), and the browser window it left going out
    /// of sight says nothing about it either (register 2516: read as
    /// leaving the desktop, the video floated instead of going full
    /// screen). With Yab behind,
    /// `appLeft`'s own watch has it. `active` and `shown` are for tests.
    func sightChanged(of changed: NSWindow? = nil, active: Bool = NSApp.isActive, shown: Bool? = nil) {
        guard active, !fullscreenDeparture.staysAway(in: self) else { return }
        let onScreen: Bool
        var seen = ""
        if let shown {
            onScreen = shown
        } else {
            guard let source = BrowserWindows.shared.window(for: self) else { return }
            // WebKit's own full screen, sliding in or out, keeps its earlier
            // reading (WKWebView.fullscreenState).
            if let web = self.active?.builtPage?.webKit,
               web.fullscreenState == .enteringFullscreen || web.fullscreenState == .exitingFullscreen { return }
            let window = self.active?.builtPage?.window ?? source
            guard changed === window, window !== sightSliding else { return }
            // Minimized or hidden has its own departure (FullscreenPiPDeparture).
            guard !NSApp.isHidden, !window.isMiniaturized, window.isVisible else { return }
            // Gone: occluded, as Chromium reads the tab's view. Not whether it
            // is on the active Space: macOS says a window is on its Space
            // until the slide away is over, after its occlusion has changed
            // (night-16, another Yab window taken full screen: nothing came
            // out when both had to say so).
            let visible = window.occlusionState.contains(.visible)
            onScreen = visible
            seen = " occluded=\(!visible) space=\(window.isOnActiveSpace) source=\(window === source)"
        }
        traceFloat("sight shown=\(onScreen) away=\(desktopAway)\(seen)")
        if onScreen {
            if desktopAway { appBack() }
            return
        }
        guard !desktopAway, (Self.benchAway ?? prefs.floatsOnLeave) || presenting else { return }
        desktopAway = true
        awayWatch = false
        leftNow()
    }

    /// Yab is behind and its window not yet out of sight.
    @ObservationIgnored private var awayWatch = false
    @ObservationIgnored private var coverToken: NSObjectProtocol?
    @ObservationIgnored private var coverSpaceToken: NSObjectProtocol?

    /// Full screen, the page's own or the window's: a click on another
    /// display leaves Yab and the film stays in plain sight, though macOS
    /// reads its window as covered then, so its Space decides: left, it
    /// comes out as any video does.
    private var watchingFullScreen: Bool {
        if let page = active?.builtPage, Self.pageFullscreen(page) { return true }
        return fullScreen || BrowserWindows.shared.window(for: self)?.styleMask.contains(.fullScreen) == true
    }

    /// The page's own full screen, either engine's: WebKit's window, or
    /// the one Yab lends a Chromium page (`ChromiumFullscreen`).
    private static func pageFullscreen(_ page: any PageHandle) -> Bool {
        if let native = page as? ChromiumPage { return native.media.fullscreen }
        return page.webKit.map { $0.fullscreenState != .notInFullscreen } ?? false
    }

    private func watchCover() {
        guard coverToken == nil, let window = BrowserWindows.shared.window(for: self) else { return }
        // A full-screen window reads as on its Space until the slide is over.
        coverSpaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coverChanged() }
        }
        coverToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coverChanged() }
        }
    }

    private func coverChanged(again: Bool = false) {
        guard awayWatch, !NSApp.isActive else { return }
        // Explicit hiding/minimizing has an owned departure, including
        // its pending native answer. Do not start a second request here.
        if fullscreenDeparture.staysAway(in: self) { return }
        let source = BrowserWindows.shared.window(for: self)
        if NSApp.isHidden || source?.isMiniaturized == true || source?.isVisible == false {
            fullscreenDeparture.changed()
            return
        }
        if watchingFullScreen {
            traceFloat("cover fullScreen")
            guard let page = active?.builtPage, !automaticPiPFullscreen(page) else { return }
            awayWatch = false
            leftNow()
            return
        }
        guard let window = BrowserWindows.shared.window(for: self) else { return }
        let seen = Self.inSight(window)
        traceFloat("cover seen=\(seen) again=\(again) \(Self.sightWhy)")
        guard !seen else { return }
        // Asked once more a moment later: while windows change places
        // between apps, one may read as covered for an instant (YouTube on
        // main, 2026-10-14, with only a corner under another window).
        guard again else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.coverChanged(again: true) }
            return
        }
        awayWatch = false
        leftNow()
    }

    // Completed app-departure path, after the existing occlusion checks.
    func leftNow() {
        guard (Self.benchAway ?? prefs.floatsOnLeave) || presenting else { return }
        guard let active, active.onCall || (active.noisy && !active.muted) else { return }
        fullscreenAwayOwner = nil
        liftedAway = !floater.showing
        if active.onCall { return liftCall(active) }
        guard minimizeHold.allowsAuto(active.id) else { return }
        pictureOut(active, quietly: true)
    }

    /// Explicit inline hide/minimize departures carry
    /// an owner through the native request and its return to the source.
    func leftFullscreen(_ context: FullscreenPiPDeparture.Context) {
        guard fullscreenDeparture.permits(context, in: self) else { return }
        liftedAway = !floater.showing
        fullscreenAwayOwner = liftedAway ? context : nil
        pictureOut(active, quietly: true, departure: context)
    }

    /// A user/site native request may arrive without pictureOut. Clear
    /// only this helper's automatic-return flag before it lands an older
    /// floater and loses the pending context that supplied that flag.
    func supersedeFullscreenDeparture(with tab: Tab) {
        fullscreenDeparture.supersede(with: tab)
        if fullscreenAwayOwner != nil {
            liftedAway = false
            fullscreenAwayOwner = nil
        }
    }

    /// Whether a window can still be watched: on screen, and at least half
    /// of it not under other apps' windows. Window bounds need no Screen
    /// Recording.
    /// Why the last `inSight` said what it did, for the float trace.
    static var sightWhy = ""

    static func inSight(_ window: NSWindow) -> Bool {
        sightWhy = "hidden=\(NSApp.isHidden) mini=\(window.isMiniaturized) occluded=\(!window.occlusionState.contains(.visible))"
        if NSApp.isHidden || window.isMiniaturized || !window.occlusionState.contains(.visible) { return false }
        guard let primary = NSScreen.screens.first else { return true }
        // Core Graphics counts from the top of the first screen.
        let f = window.frame
        let mine = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        guard mine.width > 0, mine.height > 0,
              let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], CGWindowID(window.windowNumber)) as? [[String: Any]]
        else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        var covered: CGFloat = 0
        for info in above {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { continue }
            let cut = bounds.intersection(mine)
            if !cut.isNull { covered += cut.width * cut.height }
        }
        sightWhy += " covered=\(Int(covered * 100 / (mine.width * mine.height)))%"
        return covered < mine.width * mine.height / 2
    }

    /// Back, and still on the tab it came from: into the tab again. On
    /// another tab by now, it stays out, as if you had left it by hand.
    func appBack() {
        traceFloat("appBack")
        if fullscreenDeparture.staysAway(in: self) { return }
        fullscreenDeparture.cancel()
        awayWatch = false
        desktopAway = false
        if liftedAway, let active { cancelVideoRequest(for: active) }
        defer { liftedAway = false; fullscreenAwayOwner = nil }
        if liftedAway, let id = floating, id == activeID { land() }
    }

    /// ⌘⇧P, for lifting one out by hand.
    /// A tab's video out in the little window, or back if it is out: the
    /// island's Float Video, for a tab playing out of sight.
    func float(_ tab: Tab) {
        if floating == tab.id {
            land()
            return
        }
        minimizeHold.forget()
        pictureOut(tab)
    }

    /// Old page-reparenting lifetime probes, not a user video entrypoint.
    func benchLiftPage(_ tab: Tab, quietly: Bool) {
        guard Store.testing else { return }
        lift(tab, quietly: quietly)
    }

    func benchReturnBeforePiP(_ sibling: Tab) -> [String: Any] {
        guard Store.testing, let source = active, sibling !== source else { return ["error": "source and sibling required"] }
        // Use the production selection commit, after its drawing barrier.
        // Two ordinary select calls in one turn can instead cancel a pending
        // drawing transition without ever departing (not the PiP race).
        finishSelect(sibling)
        let left = activeID == sibling.id
        let pending = pendingVideoRequestsForBench
        finishSelect(source)
        return ["left": left, "returned": activeID == source.id, "pendingAtDeparture": pending]
    }

    private func videoRequest(for tab: Tab) -> VideoRequest? {
        guard let request = videoRequests[tab.id], request.page === tab.builtPage,
              request.navigation == tab.askedAt else { return nil }
        return request
    }

    private func beginVideoRequest(for tab: Tab, quietly: Bool) -> VideoRequest? {
        if quietly, let request = videoRequest(for: tab), !request.cancelled { return nil }
        videoRequests = videoRequests.filter { $0.value.page != nil }
        let request = VideoRequest(tab)
        videoRequests[tab.id] = request
        return request
    }

    private func cancelVideoRequest(for tab: Tab) {
        guard let request = videoRequest(for: tab), !request.cancelled else { return }
        request.cancelled = true
        // Invalidate discovery in every frame. An already-committed native
        // presentation is rejected by its same receipt at take/hasVideo.
        if let page = tab.builtPage { Isolate.run("off", 1, on: page) }
        if request.answered, let web = tab.built {
            web.closeAllMediaPresentations { [weak self, weak tab] in
                guard let self, let tab, self.videoRequests[tab.id] === request else { return }
                self.videoRequests[tab.id] = nil
            }
        }
    }

    func rejectsPendingVideoRequest(for tab: Tab) -> Bool { videoRequest(for: tab)?.cancelled == true }

    func endedPendingVideoRequest(for tab: Tab) {
        if let request = videoRequest(for: tab), request.answered { videoRequests[tab.id] = nil }
    }

    private func videoRequestAnswered(_ request: VideoRequest, for tab: Tab, succeeded: Bool) {
        request.answered = true
        if videoRequests[tab.id] === request, !succeeded || request.delivered { videoRequests[tab.id] = nil }
    }

    private func videoRequestDelivered(for tab: Tab) {
        guard let request = videoRequest(for: tab) else { return }
        request.delivered = true
        if request.answered { videoRequests[tab.id] = nil }
    }

    func toggleFloat() {
        toggleFloat(own: false)
    }

    /// `own`: the tab in front's video into Yab's window, as ⇧⌘P did until
    /// 2026-10-12; the bench's verbs, whose evals are about that window.
    func toggleFloat(own: Bool) {
        // Tucked behind an edge, asking for it is asking to see it.
        if floater.parked != nil {
            floater.untuck()
            return
        }
        if floater.showing {
            land()
            return
        }
        minimizeHold.forget()
        if own, Store.testing, !(active?.builtPage is ChromiumPage) { lift(active, quietly: false) } else { pictureOut(active) }
    }

    /// ⇧⌘P on the tab in front: its video alone out of the page, WebKit's
    /// own, into Yab's window (`take`), so the page stays in the tab,
    /// readable and scrolling. Automatic departures and the player's menu
    /// use this same native ownership. A refused request never lends the
    /// entire document to a video window.
    /// `quietly`: Yab left, by the same rules as a lift on its own; the
    /// video alone too, since the page may still be seen around it.
    private func pictureOut(_ tab: Tab?, quietly: Bool = false, tabLeft: Bool = false, departure: FullscreenPiPDeparture.Context? = nil) {
        if let tab, let native = tab.builtPage as? ChromiumPage {
            guard !tab.gone, !tab.asleep, native.nativeVideoPiPKnown, tab.delegate === self,
                  everyTab.contains(where: { $0 === tab }) else { return }
            // Out already: leaving its tab, its space or Yab leaves it out, as
            // under WebKit (`lift`). Only ⇧⌘P and the field's action ask it back.
            if let picture = native.videoPiP {
                if !quietly { picture.close() }
                return
            }
            if quietly {
                guard native.media.permitsAutomaticPiP,
                      tabLeft || !automaticPiPFullscreen(native), AutomaticPiPSites.shared.allows(tab.address),
                      Players.follows(tab), !tabs.contains(where: \.pictureInPicture),
                      !floater.showing || floater.homing else { return }
            }
            // This is Yab's eligible, preference-enabled PiP action, like
            // Isolate.run on WebKit. Chromium also needs activation for
            // requestPictureInPicture after the original play click expires.
            guard let request = beginVideoRequest(for: tab, quietly: quietly) else { return }
            native.evaluate(.function("return await window.__yabFloat?.pip(automatic, true)", arguments: ["automatic": quietly ? Players.automaticPolicy(tab.address) : 0]),
                            in: .named("float"), frame: nil, gesture: true) { [weak self, weak tab] result in
                guard let self, let tab, self.videoRequests[tab.id] === request else { return }
                let succeeded = (try? result.get()) as? String == "pip"
                if request.cancelled, self.floating == tab.id { self.land() }
                self.videoRequestAnswered(request, for: tab, succeeded: succeeded)
            }
            return
        }
        guard let tab, !tab.gone, !tab.isBlank, !tab.asleep, let web = tab.webKitOnly("WebKit native page lifecycle", build: false),
              tab.delegate === self, everyTab.contains(where: { $0 === tab }) else { return }
        if quietly {
            guard tabLeft || !automaticPiPFullscreen(web), AutomaticPiPSites.shared.allows(tab.address),
                  Players.follows(tab), !tabs.contains(where: \.pictureInPicture),
                  !floater.showing || floater.homing else { return }
        }
        if departure == nil { supersedeFullscreenDeparture(with: tab) }
        if !quietly, let picture = picturing, floating != tab.id {
            // A source we previously handed back can still be finishing its
            // native exit. Asking it for PiP during that exit resolves to its
            // retiring presentation, which then disappears. Finish both native
            // returns before starting this new presentation, using their own
            // completion callbacks rather than a timer or another request.
            let previous = floatedTab?.built
            land(preserving: departure, mediaAlreadyClosing: picture.native == nil)
            let epoch = landings, navigation = tab.askedAt
            var remaining = previous != nil && previous !== web ? 2 : 1
            let returned = { [weak self, weak tab, weak web] in
                remaining -= 1
                guard remaining == 0, let self, let tab, let web,
                      self.landings == epoch, !tab.gone, !tab.asleep,
                      tab.built === web, tab.askedAt == navigation, tab.delegate === self,
                      self.everyTab.contains(where: { $0 === tab }) else { return }
                self.requestPictureOut(tab, web: web, quietly: false, departure: departure)
            }
            if let previous, previous !== web { previous.closeAllMediaPresentations(completionHandler: returned) }
            web.closeAllMediaPresentations(completionHandler: returned)
            return
        }
        if tab.pictureInPicture {
            web.closeAllMediaPresentations(completionHandler: {})
            return
        }
        requestPictureOut(tab, web: web, quietly: quietly, departure: departure)
    }

    private func requestPictureOut(_ tab: Tab, web: WKWebView, quietly: Bool, departure: FullscreenPiPDeparture.Context?) {
        if let departure, !fullscreenDeparture.beginRequest(departure, in: self) { return }
        let request = departure == nil ? beginVideoRequest(for: tab, quietly: quietly) : nil
        if departure == nil, request == nil { return }
        let navigation = tab.askedAt
        Isolate.run("pip", quietly ? Players.automaticPolicy(tab.address) : 0, on: web) { [weak self, weak tab, weak web] answer in
            guard let self else { return }
            let succeeded = answer as? String == "pip"
            defer {
                if let request, let tab { self.videoRequestAnswered(request, for: tab, succeeded: succeeded) }
                if let departure, self.fullscreenDeparture.finished(departure), self.floating == nil {
                    self.liftedAway = false
                    self.fullscreenAwayOwner = nil
                }
            }
            guard let tab, let web, !tab.gone, !tab.asleep,
                  tab.webKitOnly("WebKit native page lifecycle", build: false) === web, tab.askedAt == navigation, tab.delegate === self,
                  self.everyTab.contains(where: { $0 === tab }) else { return }
            if let request {
                guard self.videoRequests[tab.id] === request else { return }
                if request.cancelled {
                    if succeeded {
                        if self.floating == tab.id { self.land() }
                        else {
                            web.closeAllMediaPresentations { [weak self, weak tab] in
                                guard let self, let tab, self.videoRequests[tab.id] === request else { return }
                                self.videoRequests[tab.id] = nil
                            }
                        }
                    }
                    return
                }
            }
            let said = answer as? String
            self.traceFloat("pip.answer \(said ?? "nil")", tab: tab, quietly: quietly)
            if let departure, !(said == "pip"
                ? self.fullscreenDeparture.acceptsSystemAnswer(departure, in: self)
                : self.fullscreenDeparture.permits(departure, in: self)) {
                if said == "pip", self.fullscreenDeparture.mayUndoSystemAnswer(departure, in: self) {
                    if self.floating == tab.id { self.land() }
                    else { web.closeAllMediaPresentations(completionHandler: {}) }
                }
                return
            }
            if said == "pip" {
                if let departure { self.fullscreenDeparture.installed(departure) }
                return
            }
            // The page's system-PiP request may already have completed. Do
            // not start a fallback lift after this site's choice changed.
            if quietly, !AutomaticPiPSites.shared.allows(tab.address) { return }
            if said == "none" {
                if !quietly { self.announce("Nothing playing", mark: "speaker.slash") }
                return
            }
            // Refusal describes the engine's video capability. Moving the
            // WKWebView instead hides the document, changes its viewport and
            // leaves Stage with an entire-page placard. Keep it in place.
            if !quietly { self.announce("Picture in Picture unavailable", mark: "pip") }
        }
    }

    /// The page action keeps the tab the field was raised over.
    func floatVideoFromField(_ tab: Tab) {
        if tab === active { toggleFloat() } else { pictureOut(tab) }
    }

    /// WebKit's video, out of the page, into this window: the page stays in
    /// its tab, running and scrolling, with WebKit's placard where the video
    /// was. False leaves it to the system's window: a call's is up.
    func take(_ picture: SitePiP.Picture) -> Bool {
        guard let tab = tab(for: picture), canTake else { return false }
        let departure: FullscreenPiPDeparture.Context?
        switch automaticPiPReceipt(for: picture, tab: tab) {
        case .rejected:
            picture.rejectedAutomaticDeparture = true
            videoRequestDelivered(for: tab)
            return false
        case .automatic(let context): departure = context
        case .ordinary:
            supersedeFullscreenDeparture(with: tab)
            departure = nil
        }
        videoRequestDelivered(for: tab)
        traceFloat("picture.take", tab: tab, quietly: false)
        if floater.showing, !floater.homing { land(preserving: departure) }
        if floater.homing { floater.drop() }
        picturing = picture
        floating = tab.id
        // WebKit taking it back, the page's exit, ⇧⌘P, the tab going.
        picture.gone = { [weak self, weak picture] in
            guard let self, let picture, self.picturing === picture else { return }
            self.land(mediaAlreadyClosing: true)
        }
        if let departure { fullscreenDeparture.installed(departure) }
        floater.lift(picture.view, shape: picture.shape, whole: true)
        player.restage()
        return true
    }

    /// The window's buttons, bar and times mean the video out: the float
    /// script holds it, without laying out the page. The page knows which
    /// it is (`pictureInPictureElement`) only once WebKit has heard it
    /// arrived, a moment after it is in the window: asked before, X's had
    /// no bar (2026-10-13). Asked again until it says.
    func holdPicture(_ tab: Tab, tries: Int = 10) {
        guard let picture = picturing, floating == tab.id, !tab.gone, !tab.asleep, let web = tab.webKitOnly("WebKit native page lifecycle", build: false),
              tab.delegate === self, everyTab.contains(where: { $0 === tab }) else { return }
        let navigation = tab.askedAt
        Isolate.run("picture", on: web) { [weak self, weak tab, weak web, weak picture] answer in
            guard let self, let tab, let web, let picture, !tab.gone, !tab.asleep, tab.webKitOnly("WebKit native page lifecycle", build: false) === web,
                  tab.askedAt == navigation, tab.delegate === self, self.everyTab.contains(where: { $0 === tab }),
                  self.picturing === picture, self.floating == tab.id else { return }
            let held = Isolate.floated(answer)
            self.traceFloat("picture.held \(held)", tab: tab, quietly: false)
            if !held, tries > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak tab, weak web, weak picture] in
                    guard let self, let tab, let web, let picture, !tab.gone, !tab.asleep, tab.webKitOnly("WebKit native page lifecycle", build: false) === web,
                          tab.askedAt == navigation, tab.delegate === self, self.everyTab.contains(where: { $0 === tab }),
                          self.picturing === picture, self.floating == tab.id else { return }
                    self.holdPicture(tab, tries: tries - 1)
                }
            }
        }
    }

    /// Not while a call is in the window: a video goes to the system's.
    var canTake: Bool { !(floater.showing && !floater.homing && floater.kind == .call) }

    /// Yab left with its film full screen and still on the active Space:
    /// on a display of its own, in plain sight. Uses the source browser
    /// window, since a tab switch may already have selected another page.
    private func automaticPiPFullscreen(_ page: any PageHandle) -> Bool {
        let full = Self.pageFullscreen(page) || fullScreen
            || BrowserWindows.shared.window(for: self)?.styleMask.contains(.fullScreen) == true
            || page.window?.styleMask.contains(.fullScreen) == true
        return full && page.window?.isOnActiveSpace == true
    }

    /// A tab chosen in the window beside a film full screen on another
    /// display: the film is still there to watch.
    private func playerBeside(_ web: WKWebView) -> Bool {
        guard let host = web.window, let source = BrowserWindows.shared.window(for: self), host !== source else { return false }
        return host.isOnActiveSpace && source.isOnActiveSpace && host.screen !== source.screen
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house, into a small window that stays above everything.
    private func lift(_ tab: Tab?, quietly: Bool, tabLeft: Bool = false, departure: FullscreenPiPDeparture.Context? = nil) {
        // Retained only for explicit legacy lifetime/window probes. All user
        // video paths use pictureOut; calls have their own putOut owner.
        guard Store.testing else { return }
        // Leaving a tab is a departure even when its browser window remains
        // in a native fullscreen Space. App/Space departures keep their
        // separate visibility policy in pictureOut.
        if tab?.builtPage is ChromiumPage { pictureOut(tab, quietly: quietly, tabLeft: tabLeft, departure: departure); return }
        traceFloat("lift.request", tab: tab, quietly: quietly)
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        // A window still handing the last page home is as good as closed:
        // going back to the tab whose video was out, from another one that is
        // playing, swaps the two.
        // One picture at a time: a page's video out by its own button goes
        // home for the one asked for.
        guard let tab, !tab.gone, !tab.isBlank, !tab.asleep, let web = tab.webKitOnly("WebKit native page lifecycle", build: false),
              tab.delegate === self, everyTab.contains(where: { $0 === tab }) else { return }
        // A page never comes out of WebKit's full-screen window into ours
        // (request 1007): the video alone goes, as ⇧⌘P puts it out.
        if quietly, web.fullscreenState != .notInFullscreen {
            if departure == nil, !playerBeside(web) { pictureOut(tab, quietly: true, tabLeft: true) }
            return
        }
        // A failed native PiP request does not authorize moving a player
        // that WebKit still owns in fullscreen. Its supported native path
        // above can complete without touching the page's window.
        if let departure, departure.mode == .player { return }
        if let departure, !fullscreenDeparture.permits(departure, in: self) { return }
        if !quietly, picturing != nil, floating != tab.id { land() }
        guard !floater.showing || floater.homing else { return }
        // The page checks user-started playback on unlisted sites, so a
        // hero background never follows. Manual PiP still lifts anywhere.
        if quietly, !AutomaticPiPSites.shared.allows(tab.address) || !Players.follows(tab) { return }
        // A video in the system's Picture-in-Picture window, from a page's
        // own button (FloatPiP.swift): nothing else comes out on its own
        // while it is there, and ⇧⌘P on its tab asks for it back.
        if quietly, tabs.contains(where: \.pictureInPicture) { return }
        if tab.pictureInPicture {
            web.closeAllMediaPresentations(completionHandler: {})
            return
        }
        // Asked before a landing that came after it: the answer is about a
        // moment that is over. Back to Tab, or Yab in front again, while the
        // page was still finding its video put the window up again after it
        // had gone home, and left the page laid out for it.
        if departure == nil { supersedeFullscreenDeparture(with: tab) }
        let asked = landings
        let navigation = tab.askedAt
        let probeRequest: Int
        if Store.testing {
            floatProbeEpoch += 1
            probeRequest = floatProbeEpoch
            floatProbePending.insert(probeRequest)
            traceFloat("lift.pending", request: probeRequest, tab: tab, quietly: quietly)
        } else {
            probeRequest = 0
        }
        Isolate.run("on", quietly ? Players.automaticPolicy(tab.address) : 0, on: web) { [weak self, weak tab, weak web] answer in
            guard let self else { return }
            self.traceFloat("lift.answer", request: probeRequest, tab: tab, quietly: quietly)
            guard let tab, let web, !tab.gone, !tab.asleep,
                  tab.webKitOnly("WebKit native page lifecycle", build: false) === web, tab.askedAt == navigation, tab.delegate === self,
                  self.everyTab.contains(where: { $0 === tab }) else {
                if Store.testing {
                    self.floatProbePending.remove(probeRequest)
                    self.traceFloat("lift.finished", request: probeRequest, tab: tab, quietly: quietly)
                }
                return
            }
            let floated = Isolate.floated(answer)
            let shape = Isolate.shape(answer)
            let complete: @MainActor @Sendable () -> Void = { [weak self, weak tab, weak web] in
                guard let self else { return }
                self.traceFloat("lift.complete", request: probeRequest, tab: tab, quietly: quietly)
                defer {
                    if Store.testing {
                        self.floatProbePending.remove(probeRequest)
                        self.traceFloat("lift.finished", request: probeRequest, tab: tab, quietly: quietly)
                    }
                }
                // The answer belongs to this browser's page and navigation.
                // A closed, moved or replaced page is not ours to clean up.
                guard let tab, let web, !tab.gone, !tab.asleep,
                      tab.webKitOnly("WebKit native page lifecycle", build: false) === web, tab.askedAt == navigation, tab.delegate === self,
                      self.everyTab.contains(where: { $0 === tab }) else { return }
                // Lifted on its own, for a tab left or Yab left, and by now
                // you are back on that tab in Yab: nothing to float for.
                // Yab in front with its window's desktop left (desktopChanged)
                // is not back: macOS keeps it active there (#1837).
                let away = departure.map { self.fullscreenDeparture.permits($0, in: self) }
                let back = FullscreenPiPDeparture.back(quietly: quietly, appActive: NSApp.isActive && !self.desktopAway,
                                                       selected: self.activeID == tab.id, departure: away)
                let siteDenied = quietly && !AutomaticPiPSites.shared.allows(tab.address)
                let fullscreenDenied = quietly && web.fullscreenState != .notInFullscreen
                guard self.landings == asked, !back, !siteDenied, !fullscreenDenied, away != false else {
                    self.traceFloat("lift.stale", request: probeRequest, tab: tab, quietly: quietly)
                    if floated, self.floating != tab.id { Isolate.run("off", on: web) }
                    return
                }
                guard floated else {
                    self.traceFloat("lift.noVideo", request: probeRequest, tab: tab, quietly: quietly)
                    if !quietly { self.announce("Nothing playing", mark: "speaker.slash") }
                    return
                }
                // Closed meanwhile, or another window came up first: the page
                // is put back as it was, not left with everything but its video
                // out of sight.
                // Parked in a space left meanwhile is still there.
                guard self.everyTab.contains(where: { $0 === tab }),
                      !self.floater.showing || self.floater.homing
                else {
                    self.traceFloat("lift.rejected", request: probeRequest, tab: tab, quietly: quietly)
                    if self.floating != tab.id { Isolate.run("off", on: web) }
                    return
                }
                self.traceFloat("lift.allowed", request: probeRequest, tab: tab, quietly: quietly)
                if self.floater.homing { self.floater.drop() }
                // One picture at a time: a page's video in the system's
                // window goes back into its page for this one.
                for other in self.tabs where other.pictureInPicture {
                    other.webKitOnly("Close media presentations")?.closeAllMediaPresentations(completionHandler: {})
                }
                self.floating = tab.id
                tab.floating = true
                // In the video's own shape, so the page is laid out in it once.
                if let departure { self.fullscreenDeparture.installed(departure) }
                self.floater.lift(web, shape: shape)
                self.traceFloat("lift.installed", request: probeRequest, tab: tab, quietly: quietly)
                // Playing in its window now, not in the band.
                self.player.restage()
            }
            // A controlled late answer is only available in a disposable
            // native test world, for proving the Back/callback ordering.
            if Store.testing, quietly,
               let delay = Double(ProcessInfo.processInfo.environment["YAB_FLOAT_CALLBACK_DELAY"] ?? ""),
               delay > 0, delay <= 5 {
                self.traceFloat("lift.delayed", request: probeRequest, tab: tab, quietly: quietly)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: complete)
            } else {
                complete()
            }
        }
    }

    /// A call's page into the window (Calls.swift): the bookkeeping is kept
    /// here, beside the video's.
    func putOut(_ tab: Tab, web: NSView) {
        floating = tab.id
        tab.floating = true
        floater.lift(web, kind: .call)
        player.restage()
    }

    /// The floated tab has a new document: float its video again once it is
    /// playing, and if nothing plays within a few seconds, the page goes home.
    private func refloat(_ tab: Tab, tries: Int = 8) {
        guard floating == tab.id, !tab.gone, !tab.asleep, let web = tab.webKitOnly("WebKit native page lifecycle", build: false),
              tab.delegate === self, everyTab.contains(where: { $0 === tab }) else { return }
        let navigation = tab.askedAt
        Isolate.run("on", on: web) { [weak self, weak tab, weak web] answer in
            guard let self, let tab, let web, !tab.gone, !tab.asleep,
                  tab.webKitOnly("WebKit native page lifecycle", build: false) === web, tab.askedAt == navigation, tab.delegate === self,
                  self.everyTab.contains(where: { $0 === tab }) else { return }
            guard self.floating == tab.id else {
                // Home meanwhile: the page has just been laid out for a
                // window that is gone, and is put back as it was.
                if Isolate.floated(answer) { Isolate.run("off", on: web) }
                return
            }
            if Isolate.floated(answer) {
                self.floater.cover(false)
            } else if tries > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak tab, weak web] in
                    guard let self, let tab, let web, !tab.gone, !tab.asleep, tab.webKitOnly("WebKit native page lifecycle", build: false) === web,
                          tab.askedAt == navigation, tab.delegate === self,
                          self.everyTab.contains(where: { $0 === tab }), self.floating == tab.id else { return }
                    self.refloat(tab, tries: tries - 1)
                }
            } else {
                self.land()
            }
        }
    }

    /// Back into its tab.
    func returnFloatingTab() {
        traceFloat("return.begin")
        if let native = picturing?.native { native.close(returning: true); return }
        // The source tab may be in the background. Put the page back before
        // selecting it, then focus this browser's window, not whichever
        // NSApp window happens to precede it (often the floating panel).
        let came = floating
        // A call left talking in its own space: that space first, its tab
        // picked, and the window lands into it there (switchSpace, select).
        if floater.kind == .call, let came, !tabs.contains(where: { $0.id == came }),
           let space = spaceHolding(came), let tab = everyTab.first(where: { $0.id == came }) {
            switchSpace(to: space)
            select(tab)
            if floating == came { land(home: activeID == came) }
            BrowserWindows.shared.window(for: self)?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            traceFloat("return.focused", tab: tab)
            return
        }
        land(home: true)
        // Its tab may wait in another space (BrowserWindows.reveal).
        guard let came, let tab = BrowserWindows.shared.reveal(came)?.tab else { return }
        NSApp.activate(ignoringOtherApps: true)
        traceFloat("return.focused", tab: tab)
    }

    /// Back into its tab.
    ///
    /// Going home, to the tab you are on, or are about to be, the page goes
    /// straight from the little window to the stage, which takes it on its
    /// next update, and the window closes the moment it has. Anywhere else,
    /// the tab closing or out of sight, the window closes now.
    func land(home: Bool? = nil, preserving departure: FullscreenPiPDeparture.Context? = nil, mediaAlreadyClosing: Bool = false) {
        if departure.map({ fullscreenDeparture.acceptsSystemAnswer($0, in: self) }) != true {
            fullscreenDeparture.cancel()
            if fullscreenAwayOwner != nil { liftedAway = false; fullscreenAwayOwner = nil }
        }
        landings += 1
        if Store.testing { floatProbeEpoch += 1 }
        traceFloat("land.begin")
        // WebKit's video was never the page: the window just closes.
        let home = picturing == nil && (home ?? (floating != nil && floating == activeID))
        // The window closes whatever else is true. Tying that to the bookkeeping
        // is how a little window outlives the thing that opened it.
        if floater.showing {
            if home { floater.release() } else { floater.drop() }
        }
        let picture = picturing
        picturing = nil
        if let native = picture?.native {
            // The original source may now belong to another browser. Its
            // exact session still retires, without requiring a local row.
            floating = nil
            native.tab?.floating = false
            native.close()
            player.restage()
            return
        }
        guard let tab = floatedTab else { return }
        // The video kept playing while its page was out. Its pre-lift still
        // is an old frame, including a capture still on its way back.
        if home, floater.kind == .video { PageStills.shared.forget(tab.id) }
        floating = nil
        tab.floating = false
        traceFloat("land.bookkeeping", tab: tab)
        // WebKit's video goes home by WebKit's own exit; the float script
        // lets go of it and asks for that (`off`).
        if picture != nil {
            player.restage()
            // The native dismiss callback is already returning this video.
            // Starting another close here reenters WebKit's pending completion
            // handling before pipDidClose: has finished the first request.
            // Still clear the script's target, timers and subtitle state;
            // only the native exit request is suppressed on this route.
            Isolate.run("off", mediaAlreadyClosing ? 1 : 0, on: tab.page)
            if !mediaAlreadyClosing, tab.pictureInPicture {
                tab.webKitOnly("Close media presentations")?.closeAllMediaPresentations(completionHandler: {})
            }
            return
        }
        player.restage()
        // Whichever put the page in the window takes itself off it.
        if floater.kind == .call {
            // Either engine's: a Chromium call's page was left on the stage,
            // its tab back in front showing the call's tiles in the window's
            // layout, or black (Meet, 0.46.7).
            if let web = tab.builtPage { CallStage.run("off", on: web) }
        } else {
            Isolate.run("off", on: tab.page)
        }
    }

    func prepare(_ tab: Tab) {
        tab.videoOpeningFront = { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return self.activeID == tab.id && self.tabs.contains { $0 === tab }
        }
        tab.delegate = self
        tab.onNavigate = { [weak self] url in
            HTTPNavigation(input: self?.fieldNavigationInput, destination: url)
        }
        tab.onSound = { [weak self] tab in
            guard let self else { return }
            chorus.heard(tab, in: self)
        }
        tab.onCapture = { [weak self] tab in self?.captureChanged(tab) }
        tab.onShare = { [weak self] tab, body, frame in self?.shareAsked(tab, body, frame) }
        tab.onPick = { [weak self] tab, selector, label, note, rect in
            guard let self, let host = curtain.host(of: tab.address) else { return }
            if BoostEditor.shared.picked(tab, selector: selector, label: label, rect: rect) { return }
            curtain.hide(selector, label: label, note: note, on: host)
            let css = curtain.css(on: host)
            tab.arm(hiding: css)
            // It goes from the page in a puff of dust, and
            // the hint along the bottom already says ⌘Z.
            HideDust.play(on: tab.webKitOnly("WebKit native page lifecycle", build: false), css: rect) { tab.applyVeils(css) }
        }
        tab.onPickEnd = { [weak self] _ in self?.veiling = false }
        tab.onImageAct = { [weak self] tab, act, url, foreground in self?.imageAct(act, url, in: tab, foreground: foreground) }
        tab.onCapturePage = { [weak self] tab in
            self?.focus(tab)
            self?.capture.start()
        }
        tab.onMediaSave = { [weak self] tab, media in self?.saveMedia(media, from: tab) }
        tab.onStoreAdd = { [weak self] tab in self?.addFromStore(tab) }
        tab.onPictureCopied = { [weak self] _ in self?.announce("Text copied", mark: "text.viewfinder", feedback: .success) }
        tab.onCross = { [weak self] tab, url in self?.replaceBlank(tab, with: url) }
        tab.onSearch = { [weak self] tab, text in
            guard let self, let url = self.searchEngine.url(for: text) else { return }
            self.open(url, foreground: true, from: tab)
        }
        tab.onSelectedURL = { [weak self] tab, url, flags in
            guard let self else { return }
            let front = Self.way(for: flags) != .behind
            let opened = open(url, foreground: front, from: tab, userLink: true)
            if !front { sayBehind(opened, url, from: tab) }
        }
        tab.onSearchName = { [weak self] _ in self?.searchEngine.name ?? Engine.name }
        tab.onSelectionCommand = { [weak self] tab, command in
            guard let self else { return }
            self.selectionCommands.open(on: tab, command: command)
        }
        tab.onSelectionMenu = { [weak self] _ in
            guard let self else { return [] }
            return SelectionCommands.menuSuggestions(self.selectionCommands.commands)
        }
        // A touch or scroll of the page puts a selection's answer away, not
        // the field's: that one stopped its agent and left the field empty.
        tab.onSelectionTouch = { [weak self] _ in
            guard let self, !self.selectionCommands.answering else { return }
            if self.selectionCommands.docked && self.selectionCommands.receipt == nil { return }
            self.selectionCommands.close()
        }
        tab.onSelectionPause = { [weak self] tab in self?.selectionCommands.maybeHint(on: tab) }
        tab.onForceClick = { [weak self] tab, point in self?.forcePeek(on: tab, at: point) }
        tab.onPress = { [weak self] tab, amount in self?.pressPeek(on: tab, amount) }
        tab.forcePeeks = { true }
        // A swipe back past the start of a tab's history: the tab it was
        // opened from, while that is open.
        tab.onBackAtStart = { [weak self] tab in self?.closeBackToSource(tab) ?? false }
        tab.onCloseUnshown = { [weak self] tab in self?.closeUnshown(tab) }
        tab.fromTitle = { [weak self] tab in
            guard let self, let source = self.tab(id: tab.from ?? tab.opener) else { return nil }
            return source.title.isEmpty ? (source.address?.host() ?? "Tab") : source.title
        }
        // The mouse's side buttons: the toolbar's Back and Forward, the
        // doors kicked and the last frame put up, as browsers treat
        // them, not a step of WebKit's own beside ours.
        tab.onStep = { [weak self] tab, forward in
            guard let self else { return }
            if tab.id == activeID { forward ? self.forward() : back() } else if forward { tab.forward() } else { tab.back() }
        }
        tab.onFrom = { [weak self] tab in
            guard let self else { return }
            if peeking === tab {
                closePeek()
                return
            }
            // A tab a link opened and nothing else has happened in: the
            // swipe's "back to the page" row closes it like Back does.
            if closeBackToSource(tab) { return }
            guard let source = self.tab(id: tab.from ?? tab.opener) else { return }
            select(source)
        }
        tab.onSearchHistory = { [weak self] tab, words in
            guard let self else { return }
            select(tab)
            openPlace(.history, words: words)
        }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. The last account used
        // here fills an empty sign-in once, with the same Touch ID setting.
        tab.onField = { [weak self] tab, spot in
            guard let self else { return }
            // A box that asks for a code: the codes a site sent, not accounts.
            if tab.fieldCode || codeList?.tab == tab.id || codeWatch.tab == tab.id {
                codeField(tab, spot: tab.fieldCode ? spot : nil)
                if tab.fieldCode {
                    if loginWaiting?.tab == tab.id { loginWaiting = nil }
                    return
                }
            }
            guard let spot else {
                if fieldPlate?.tab == tab.id { fieldPlate = nil }
                if loginWaiting?.tab == tab.id { loginWaiting = nil }
                if pickedInto == tab.id { pickedInto = nil }
                if kept?.tab == tab.id { kept = nil }
                guard suggesting?.tab == tab.id else { return }
                lowering?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, suggesting?.tab == tab.id else { return }
                    suggesting = nil
                }
                lowering = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                return
            }
            lowering?.cancel()
            // A box emptied after a pick is asking for the list again.
            if pickedInto == tab.id, tab.fieldEmpty { pickedInto = nil }
            // A password box that already holds one, filled or typed, has
            // nothing left to offer: the list comes back once it is emptied.
            if tab.fieldSecret, !tab.fieldEmpty {
                if suggesting?.tab == tab.id { suggesting = nil }
                if fieldPlate?.tab == tab.id { fieldPlate = nil }
                return
            }
            // A password manager's extension on in Yab has the box: its
            // icon and its menu are the only list on it, and
            // Yab draws nothing beside them (docs/password-manager-fields.md).
            if PasswordManagers.fieldOwner(on: tab) != nil {
                if suggesting?.tab == tab.id { suggesting = nil }
                if fieldPlate?.tab == tab.id { fieldPlate = nil }
                return
            }
            // Yab lists a connected manager only where it reads its vault
            // itself and its extension isn't on (ManagerVaults.listed). The
            // vaults are read on the way, so a manager that turns out open
            // comes in. A box in another site's frame is asked for under
            // that frame's site (fieldAddress), as Chromium and the iCloud
            // Passwords extension ask for the frame's own origin.
            if prefs.fillsPasswords, !ManagerVaults.readable.isEmpty,
               let host = curtain.host(of: tab.fieldAddress) {
                ManagerLists.shared.look(host) { [weak self, id = tab.id] in self?.refreshField(id) }
                // Apple Passwords connected, its helper not paired yet (each
                // helper pairs once, ApplePasswords.swift): the code asked
                // for here, at the box the person is at, never for a page
                // behind. The read above tells this box again once it knows.
                if ManagerVaults.lastState[PasswordManagers.apple] == .needsApproval,
                   ManagerVaults.readable.contains(PasswordManagers.apple), offersAutofill(tab) {
                    ApplePasswordsPairing.offer(on: host)
                }
            }
            let managing = !ManagerVaults.listed(on: tab).isEmpty
                || (tab.fieldFrame == nil && Store.testing && ManagerLists.shared.staged != nil)
            // A page's pending conditional get, and its site's passkeys, on
            // a box it marked webauthn (Chromium tabs, CEF 0127): listed
            // whatever Yab's passwords are set to, as Chromium lists them
            // beside its passwords (ChromiumWebAuthn+Conditional.swift).
            let passkeys = ChromiumWebAuthn.offer(for: tab) != nil
            let passwords = prefs.fillsPasswords && (prefs.usesYabPasswords || managing)
            guard passwords || passkeys, offersAutofill(tab), pickedInto != tab.id,
                  let host = curtain.host(of: tab.fieldAddress)
            else {
                // Nothing of Yab's for this box (its passwords off, no
                // manager it reads): no list or plate of Yab's left up from
                // a box before, here or in another tab.
                if !(prefs.usesYabPasswords || managing) {
                    suggesting = nil
                    fieldPlate = nil
                }
                return
            }
            // A page that came over plain http can have been written by
            // anyone on the way here, a café's network, a hotel's. It is
            // offered only what was kept from plain http too, never an
            // account kept from the https site of the same name.
            let inTheClear = tab.fieldAddress?.scheme?.lowercased() == "http"
            let site = (inTheClear ? "http://" : "") + host
            // Password filling off: the passkeys alone.
            guard passwords else {
                showRows(tab, spot: spot, site: site, host: host, yab: [], passkeysOnly: true)
                return
            }
            // Yab's own off: the managers' rows alone.
            guard prefs.usesYabPasswords else {
                showRows(tab, spot: spot, site: site, host: host, yab: [])
                return
            }
            if kept?.tab != tab.id || kept?.host != site {
                suggesting = nil
                loginWaiting = (tab.id, tab.fieldAddress, site)
                lookUpLogins(host)
                return
            }
            // One line an account: the same name and password kept under
            // google.com and accounts.google.com is one choice, not two.
            // This Space's logins first (SuggestRows.away), so the one kept
            // twice is this Space's.
            let here = loginSpace(tab), names = loginSpaceNames
            var seen = Set<String>()
            var all = SuggestRows.hereFirst(kept?.logins ?? [], here: here, spaces: names).filter {
                seen.insert($0.user.lowercased() + "\u{1}" + $0.password).inserted
            }
            // What has been typed so far, like a combo box: names that start
            // with it first, then names that merely contain it.
            let typed = tab.fieldQuery.trimmingCharacters(in: .whitespaces).lowercased()
            if !typed.isEmpty {
                let starts = all.filter { $0.user.lowercased().hasPrefix(typed) }
                let contains = all.filter { !$0.user.lowercased().hasPrefix(typed) && $0.user.lowercased().contains(typed) }
                all = starts + contains
            }
            // The password step of a sign-in whose name step just took an
            // account: that account first, where the list already points.
            // Google takes the name without its @gmail.com, so a typed name
            // also finds the address it is the start of.
            func meant(_ user: String) -> Int? {
                let user = user.lowercased()
                return all.firstIndex(where: { $0.user.lowercased() == user })
                    ?? all.firstIndex(where: { $0.user.lowercased().split(separator: "@").first.map(String.init) == user })
            }
            let automaticOrigin = Tab.originOf(tab.fieldAddress)
            let automaticDocument = tab.fieldDocument
            // Beside a connected manager, Yab's own are only listed:
            // nothing goes in by itself.
            let fillsAlone = prefs.passwordSource.yabFillsAlone
            // This Space's logins first, in the list and for what goes in
            // by itself; another Space's only when this one has none.
            all = SuggestRows.hereFirst(all, here: here, spaces: names)
            let local = all.filter { SuggestRows.away($0, here: here, spaces: names) == nil }
            // A recent account goes into an empty sign-in once per form.
            // The page checks its document, identity and contents again after
            // Touch ID, so typing or navigation while it waits cannot be lost.
            // A form that takes passkeys (a box marked webauthn) waits for a
            // pick, as Chromium fills none on load (password_form_filling.cc,
            // kAcceptsWebAuthnCredentials).
            if fillsAlone, !tab.fieldWebAuthnForm, tab.fieldAutomatic,
               let login = PasswordAutofill.login(in: local, secret: tab.fieldSecret, empty: tab.fieldEmpty,
                                                   account: tab.fieldAccount, named: tab.account(on: host))
                   ?? PasswordAutofill.login(in: all, secret: tab.fieldSecret, empty: tab.fieldEmpty,
                                             account: tab.fieldAccount, named: tab.account(on: host)),
               tab.beginAutomaticFill() {
                suggesting = nil
                pickedInto = tab.id
                tab.fill(user: login.user, password: login.password, automatic: true, caret: true) { [weak self, weak tab] filled in
                    guard let self, let tab else { return }
                    if filled == .filled {
                        tab.namedAccount(login.user, on: host)
                        Vault.touch(login)
                    } else {
                        if pickedInto == tab.id { pickedInto = nil }
                        if offersAutofill(tab), tab.fieldEmpty, !tab.fieldCode, let current = tab.fieldSpot,
                           Tab.originOf(tab.fieldAddress) == automaticOrigin, tab.fieldDocument == automaticDocument {
                            suggesting = Suggesting(tab: tab.id, spot: current, logins: all, site: site, dark: tab.fieldDark,
                                                    here: here, spaces: names)
                        }
                        if filled == .unasked { cantAskToFill() }
                    }
                }
                return
            }
            // The password step, with the account already said: that choice
            // was made once, and is not asked for twice. The password goes
            // in; emptying the box brings the list back to choose again.
            if fillsAlone, !tab.fieldWebAuthnForm, tab.fieldSecret, tab.fieldEmpty, tab.fieldAutomatic,
               let user = tab.takeAccount(on: host), let at = meant(user), tab.beginAutomaticFill() {
                let login = all[at]
                suggesting = nil
                pickedInto = tab.id
                // The fields filling are the answer.
                tab.fill(user: login.user, password: login.password, automatic: true, caret: true) { [weak self, weak tab] filled in
                    guard let self, let tab else { return }
                    if filled == .filled { Vault.touch(login) }
                    else {
                        if pickedInto == tab.id { pickedInto = nil }
                        if offersAutofill(tab), tab.fieldEmpty, !tab.fieldCode, let current = tab.fieldSpot,
                           Tab.originOf(tab.fieldAddress) == automaticOrigin, tab.fieldDocument == automaticDocument {
                            suggesting = Suggesting(tab: tab.id, spot: current, logins: all, site: site, dark: tab.fieldDark,
                                                    here: here, spaces: names)
                        }
                        if filled == .unasked { cantAskToFill() }
                    }
                }
                return
            }
            // The page says whose password this is, Google's chip over the
            // box: only that account's, lit, where Return takes it. With
            // none kept under that name, every account, as before.
            let named = all.filter { $0.user.lowercased() == tab.fieldAccount?.lowercased() }
            if tab.fieldSecret, !named.isEmpty {
                all = named
            } else if let user = tab.account(on: host), let at = meant(user) {
                // The account the password step already knows is meant goes
                // first, where Return takes it.
                all.insert(all.remove(at: at), at: 0)
            }
            showRows(tab, spot: spot, site: site, host: host, yab: all)
        }

        tab.onCredentials = { [weak self] tab, host, user, password, clear, frame in
            guard let self else { return }
            // A second account on a site you already signed in to: a space
            // each, offered once (Teach.swift).
            Teach.shared.signedIn(tab, host: host, user: user, in: self)
            let apple = prefs.passwordSource.saver == PasswordManagers.apple
            // Offer to save passwords is the person's for Apple Passwords
            // too: off, no card asks into it either (register 2497).
            guard prefs.savesPasswords, apple || prefs.passwordSource.yabSaves,
                  !password.isEmpty, !host.isEmpty, !tab.shy, !Vault.isNever(host) else { return }
            if !apple, PasswordManagers.fieldOwner != nil { return }
            let login = Login(host: host, user: user, password: password, used: nil,
                              clear: clear, space: loginSpace(tab))
            let check = UUID()
            let address = tab.address
            tab.passwordOfferCheck = check
            Task { @MainActor [weak self, weak tab] in
                await PasswordSaveDecision.waitForSave(login)
                let known = await Task.detached { Vault.logins(matching: host) }.value
                let decision = await PasswordSaveDecision.check(login, known: known,
                                                               apple: apple ? AppleVault() : nil)
                guard let self, let tab, self.tab(id: tab.id) === tab,
                      tab.passwordOfferCheck == check, tab.address == address, !tab.shy,
                      !Vault.isNever(host),
                      // FormRelay derived host from the submitting document's
                      // engine origin. An embedded sign-in owns its password;
                      // its parent page may belong to a different site.
                      frame != nil || (tab.address?.host()).map({ Vault.registrable($0) == Vault.registrable(host) }) == true,
                      self.prefs.passwordSource.saver == (apple ? PasswordManagers.apple : nil),
                      self.prefs.savesPasswords,
                      apple || (self.prefs.passwordSource.yabSaves && PasswordManagers.fieldOwner == nil)
                else { return }
                if decision == .none {
                    if var same = known.first(where: { $0.user == user && $0.password == password }) {
                        same.clear = clear
                        Vault.touch(same)
                    }
                    return
                }
                self.offer(login, changed: decision == .update, on: tab,
                           into: apple ? PasswordManagers.apple : nil)
            }
        }
        // Cards and addresses: the list under a box, and a new one offered
        // once it went through (WalletKeep.swift).
        tab.onWalletField = { [weak self] tab, field in self?.walletField(tab, field) }
        tab.onPaid = { [weak self] tab, card, address, host in self?.paid(tab, card: card, address: address, host: host) }
        tab.onFilesAway = { [weak self] tab in if self?.fileWaiting(for: tab) == true { self?.dropFiles() } }
        tab.onPickTrouble = { [weak self] _, reason in
            self?.announce("Can't hide that", mark: "exclamationmark.triangle")
        }

        // The line at the bottom doubles as the zoom read-out: it keeps being
        // rewritten while you pinch and fades a moment after you stop.
        tab.onTune = { [weak self] tab in self?.player.heard(tab) }
        tab.onPasskeysMissing = { [weak self] tab, ask in self?.passkeysMissing(tab, ask) }
        // Measure's dock says Copied on its own button: no notice as well.
        tab.onMeasureCopy = { [weak self] _, text in self?.copyForAgent(text, nil) }
        tab.toolsOpen = { [weak self] tab in self?.devOpen == true && self?.active === tab }
        tab.onMeasureElements = { [weak self] tab, path in
            guard let self, self.active === tab else { return }
            self.openDevTools(.elements)
            self.showWebPane { _, inspector in DevTools.select(path, in: inspector) }
        }
        tab.onTranslationMenu = { [weak self] tab in self?.pageTranslation.menuItems(for: tab) ?? [] }
        // Why a page wasn't translated, in the corner: nothing else says it.
        pageTranslation.failed = { [weak self] tab, reason in
            guard let self, self.active === tab else { return }
            self.announce(reason, mark: "translate")
        }
        tab.onWebInspectElement = { [weak self] tab, inspect in
            guard let self else { return }
            let small = self.smallInspectorOwner(of: tab)
            switch LocalInspectorOwnership.route(page: ObjectIdentifier(tab),
                main: self.active.map { ObjectIdentifier($0) },
                small: small.map { ObjectIdentifier($0.tab) }) {
            case .main:
                // Yab's Elements from the first frame; WebKit's action only
                // tells its frontend the node, which Elements hears as picked.
                self.openDevTools(.elements) { [weak self, weak tab] opened, _ in
                    guard let self, let tab, opened === tab, self.toolsFront === tab, self.devOpen || self.devComing else { return }
                    inspect()
                }
            case .small:
                guard let web = tab.webKitOnly("WebKit native page lifecycle", build: false), let inspector = Inspector.of(web) else { return }
                Inspector.send(inspector, "show")
                inspect()
            case .stale:
                return
            }
        }
        tab.onZoom = { [weak self] _, value in
            guard let self else { return }
            let percent = Int((value * 100).rounded())
            guard percent != zoomShown else { return }
            let mark = percent == 100 ? "magnifyingglass"
                : percent > zoomShown ? "plus.magnifyingglass" : "minus.magnifyingglass"
            zoomShown = percent
            announce("\(percent)%", mark: mark)
        }

        // A page's title lands a beat after the page itself, and a history
        // entry that only ever holds an address is half a memory.
        // Anywhere a tab lands is worth remembering for next launch.
        let addressWatch = tab.changes(\.address)
            .scan((URL?.none, URL?.none)) { ($0.1, $1) }
            .dropFirst()
            .sink { [weak self, weak tab] moved in
                let url = moved.1
                if LinkGap.cut("aw.rest"), LinkGap.cut("aw.wallet") { return }
                if !LinkGap.cut("aw.rest") { self?.rememberSession() }
                // A pull request just made: its live folder, the first time
                // (LiveFolders.swift).
                if !LinkGap.cut("aw.rest"), let self, let tab, let url { LiveFolders.shared.noticeMove(tab, from: moved.0, to: url, in: self) }
                // A page that moves on without loading, most apps now,
                // never finishes a navigation, but is somewhere new all the same.
                if let self, let tab, let url {
                    // A move within the page (#section) keeps its lists.
                    let wallet = !LinkGap.cut("aw.wallet"), rest = !LinkGap.cut("aw.rest")
                    if wallet, Browser.unhashed(moved.0) != Browser.unhashed(url) { self.walletPageLeft(tab) }
                    if rest { self.noticeMove(tab, to: url) }
                    if rest { self.offerMoved(tab, to: url) }
                    if wallet { self.payMoved(tab, to: url) }
                    if rest { self.asksMoved(tab, to: url) }
                }
            }

        // At most every two seconds, and the latest: a page that counts
        // unread messages or a clock in its title renames itself many times
        // a second, and each renaming went through the history into this
        // object, the whole window, every tab in the row and the main menu
        // drawn again, and the diary written, for a title nobody could read
        // at that speed.
        let titleWatch = tab.changes(\.title)
            .dropFirst()
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak tab] title in
                guard let tab, !tab.shy, !tab.bench, let url = tab.address else { return }
                self?.history(for: tab).retitle(url, title)
                Diary.shared.retitle(url, title)
                QuickActions.shared.noticed(url, title: title)
            }
        let engineWatch = tab.changes(\.engineKind)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rememberSession() }
        tab.browserWatches = [addressWatch, titleWatch, engineWatch]
    }

    /// Put the cursor back in the field, from wherever asked.
    func askFocus() { query.focusRequest += 1 }

    // MARK: - guessing

    /// `completing` false, just after a backspace: no ending, and so no
    /// row chosen for one, only what is actually in the field.
    /// The list made again for the same words: an extension's keyword
    /// answered (ExtensionOmnibox).
    func guessAgain() { guess(completing: searchCompleting, refreshing: true) }

    /// Tab in the compact card's empty field (or over the page's address,
    /// untouched): its Actions page, as Arc's Tab has it.
    func enterActions() -> Bool {
        guard prefs.compactField, !query.actionsPage, query.place == nil, query.scope == nil, emojiWords == nil,
              !query.answering, !privateBrowsing, query.typed.isEmpty || untouched != nil else { return false }
        query.actionsPage = true
        picked = nil
        query.pointed = nil
        typed = ""
        guessAgain()
        return true
    }

    /// Out of Actions to the plain field, nothing typed.
    @discardableResult
    func leaveActions() -> Bool {
        guard query.actionsPage else { return false }
        query.actionsPage = false
        picked = nil
        query.pointed = nil
        typed = ""
        guessAgain()
        return true
    }

    /// Commands that can be done now, by their names; with nothing typed,
    /// the ones about the page in front first, as Arc's Actions lists them.
    private func actionRows(_ words: String) -> [Suggestion] {
        let first: [Command] = [.copyAddress, .duplicate, .reload, .splitView, .closeTab, .bookmarkPage, .reader,
                                .find, .capture, .privateTab, .reopen, .closeOthers]
        let here = Command.allCases.filter { $0.available(in: self) }
        let ordered: [Command]
        if words.isEmpty {
            ordered = first.filter(here.contains) + here.filter { !first.contains($0) }
        } else {
            ordered = here.compactMap { command in command.score(words, in: self).map { (command, $0) } }
                .sorted { $0.1 > $1.1 }.map(\.0)
        }
        let pageMatches = pageActionMatches(words)
        let commands = ordered.filter { command in
            !pageMatches.contains { $0.0.kind == .page("page-action:" + command.rawValue) }
        }.map { Suggestion(key: $0.title(in: self), title: $0.keys, url: nil, kind: .command($0)) }
        let targets = MenuCommands.targets(in: self)
        if words.isEmpty { return commands + pageMatches.map(\.0) + targets.map(\.offer) }
        return (commands.compactMap { row in
            if case .command(let command) = row.kind, let score = command.score(words, in: self) { return (row, score) }
            return nil
        } + pageMatches + targets.compactMap { target in target.score(words).map { (target.offer, $0) } })
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Run from the compact card's list, a command that has keys says them
    /// once at the window's corner, three times at most for each.
    private func teachKeys(of command: Command) {
        guard prefs.compactField, !command.keys.isEmpty else { return }
        let key = "field.taught." + command.rawValue
        let told = UserDefaults.standard.integer(forKey: key)
        guard told < 3 else { return }
        UserDefaults.standard.set(told + 1, forKey: key)
        toaster.pop("Next time", keys: command.keys.map(String.init))
    }

    private func guess(completing: Bool = true, refreshing: Bool = false) {
        let span = MainBudget.begin("field.guess"); defer { span?.end() }
        searchCompleting = completing
        let textForSuggestions = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressForSuggestions = Address.url(from: textForSuggestions) != nil && !Address.isBareName(textForSuggestions)
        let usualPrivateField = windowPurpose == .privateOnly && !prefs.compactField
        let eligible = fieldShowing && prefs.searchSuggest && (!privateBrowsing || usualPrivateField)
            && query.scope == nil && query.place == nil && emojiWords == nil
            && untouched == nil && !textForSuggestions.isEmpty && !addressForSuggestions
        searchSuggestions.update(eligible ? typed : nil, engine: searchEngine.engine) { [weak self] in
            self?.guessAgain()
        }
        // The compact card's Actions: commands by name, the ones about the
        // page first while nothing is typed.
        if query.actionsPage {
            let list = actionRows(typed.trimmingCharacters(in: .whitespacesAndNewlines))
            // Import needs an explicit selection, even when it is the only hit.
            let lead = list.isEmpty || list.first?.kind == .command(.importYabPasswords) ? nil : 0
            answer(list, ending: nil, lead: lead, picked: nil)
            return
        }
        // One site's field: its words, asked of it, and nothing else.
        if let scope = query.scope {
            let list = scoped(scope)
            answer(list, ending: nil, lead: list.first?.kind == .search ? 0 : nil, picked: nil)
            return
        }
        // New words, a new question: ⌘K's list of the old row's actions goes.
        if !refreshing, query.acting != nil { query.acting = nil }
        // Mail's place: the thread's commands, threads by their words, or
        // times, as ⌘J's rows (MailField).
        if query.place == .mail {
            if query.offering != nil { query.offering = nil }
            let list = mailSuggestions()
            // The first row there is something to take from.
            answer(list, ending: nil, lead: list.firstIndex { !Browser.inert($0) }, picked: nil)
            return
        }
        // The selection's place: its commands, those the words name, and
        // the words as a question.
        if query.place == .selection {
            if query.offering != nil { query.offering = nil }
            // Under a command's answer the words are a follow-up, no rows.
            let list = query.answering ? [] : selectionRows(limit: 40, naming: typed)
            answer(list, ending: nil, lead: list.isEmpty ? nil : 0, picked: nil)
            return
        }
        // One of the field's own places, or an emoji being named: the place
        // lists what the words find, the field offers no rows of its own.
        if query.place != nil || emojiWords != nil {
            if query.offering != nil { query.offering = nil }
            if query.spot != 0 { query.spot = 0 }
            if query.place == .history { askHistory() }
            if query.place == .files { askFileSearch() }
            if query.place == .passwords { lookElsewhere() }
            answer([], ending: nil, lead: nil, picked: nil)
            return
        }
        let text = typed.trimmingCharacters(in: .whitespaces)
        // Empty, or the page's own address as ⌘L brought it: nothing asked
        // yet, only what can be done to the page, or what was just copied.
        guard !text.isEmpty, untouched == nil else {
            if query.offering != nil { query.offering = nil }
            // For somewhere new, the first of them is chosen, as a launcher
            // chooses its first; over ⌘L's address nothing is, and Return
            // stays where it is.
            // Only a row that goes somewhere: a stray Return never starts an
            // agent (getting started's rows) on its own.
            let quiet = quietRows()
            let lead = untouched == nil ? quiet.firstIndex { !startsWork($0) } : nil
            answer(quiet, ending: nil, lead: lead, picked: nil)
            return
        }

        // Pages already open that the words name, then three places, then
        // the things the app does and the pages of its settings that the
        // words name, then, if it can't be a place, a search. One field
        // for all of it: ⌘T, then whatever you meant.
        let openMatches = MainBudget.chunk("field.open") { openPageMatches(matching: typed) }
        let open = openMatches.rows
        let already = Set(open.filter { automaticOpenPage($0) }.compactMap { $0.url.map(History.key(for:)) })
        // Bookmarks among the places, as browsers' address fields
        // offer them: read again only after they change.
        history.keep(bookmarks: bookmarks.roots, revision: bookmarks.revision)
        let saved = savedPageRows(matching: typed).filter { !already.contains($0.key) }
        let savedKeys = Set(saved.map(\.key))
        let found = saved + history.suggestions(for: typed, limit: 5).filter { !savedKeys.contains($0.key) }
        let guessed = Address.url(from: typed)
        let address = guessed != nil && !Address.isBareName(typed)
        let quick = address ? [] : QuickActions.shared.matches(text)
        let quickExact = address ? nil : QuickActions.shared.exact(text)
        // An extension's commands, by alias or name (Settings › Shortcuts).
        let extensionCommands: (rows: [Suggestion], exact: Suggestion?) = address ? ([], nil) : extensionCommandRows(text)
        // Mail called by its name, "mail" or "inbox": Yab's own mail, not a
        // bookmarked Gmail page the letters happen to begin. "gmail" stays
        // the site's.
        let mailNamed = !address && text.count >= 3 && prefs.usesMail && !MailCenter.shared.accounts.isEmpty
            && FieldPlace.mail.names.contains { $0 != "gmail" && $0.hasPrefix(text.lowercased()) }
        // Built-in places share one naming rule, including aliases such as
        // "files" and places without a Command, such as Clipboard History.
        // Mail keeps its account-specific handling below; "gmail" stays a site.
        let placeNamed = address ? nil : FieldPlace.named(text).flatMap { $0 == .mail ? nil : $0 }
        let pageMatches = address || !FieldUnder.shared.commands ? [] : typedPageRows(text)
        let exactPage = pageMatches.first { Command.normalizedName($0.0.key) == Command.normalizedName(text) }?.0
        let availableCommands = address ? [] : Command.allCases.filter { $0.available(in: self) }
        let menuTargets = address ? [] : MenuCommands.targets(in: self)
        let exactCommand = FieldUnder.shared.commands ? availableCommands.first { $0.matchesExactly(text, in: self) } : nil
        let exactTarget = FieldUnder.shared.commands && placeNamed == nil ? menuTargets.first { $0.matchesExactly(text) } : nil
        let projectNamed = text.count >= 3 ? menuTargets.first {
            $0.operation == .openChatProject && ($0.score(text) ?? 0) >= 2
        } : nil
        let pasteNamedIntent = !address && Command.pasteAndMatchStyle.namedExactly(text)
            && Command.pasteAndMatchStyle.available(in: self)
        let ending = completing && (address || (saved.isEmpty && !openMatches.named)) && quickExact == nil && !mailNamed && placeNamed == nil
            && exactCommand == nil && exactTarget == nil && exactPage == nil && projectNamed == nil && !pasteNamedIntent ? history.completion(for: typed, among: found) : nil
        // Five places at most, fewer beside open pages that already answer:
        // a list longer than a glance is read, not chosen from. Never
        // without the place the ending finishes, that is Return's row.
        let whole = ending.map { (typed + $0).lowercased() }
        var places = found.filter { !already.contains($0.key) }
        while places.count > max(2, 5 - open.count),
              let last = places.lastIndex(where: { $0.key != whole }) {
            places.remove(at: last)
        }
        // A place for certain, or a bare name with a port, nas:5000, which
        // reads as words too: it leads, and the search is still offered.

        // An address is being typed: what the app does is not what is meant.
        var things: [(Suggestion, Double)] = pageMatches
        let commandsSpan = MainBudget.begin("field.commands")
        if !address {
            for command in availableCommands {
                guard !pageMatches.contains(where: { $0.0.kind == .page("page-action:" + command.rawValue) }) else { continue }
                guard let score = command.score(text, in: self) else { continue }
                things.append((Suggestion(key: command.title(in: self), title: command.keys, url: nil, kind: .command(command)), score))
            }
            for target in menuTargets {
                guard let score = target.score(text) else { continue }
                things.append((target.offer, score))
            }
            // Passwords is a page of its own and a page of settings too.
            // The words name the place you go to, not the settings about
            // it: those come when the words say so, "passwords settings".
            // Autofill's place is named so too, though its command is not.
            var commands = Set(things.map(\.0.key))
            for (thing, _) in things {
                if case .command(let command) = thing.kind, let place = FieldPlace.of(command) { commands.insert(place.title) }
            }
            if let place = FieldPlace.named(text) { commands.insert(place.title) }
            for page in SettingsPage.allCases where !commands.contains(page.title) {
                guard let score = page.score(text) else { continue }
                // Under a thing named as well: "passwords" is the passwords
                // before it is the page about them, and "priv" a private
                // tab before it is the page on privacy.
                things.append((Suggestion(key: page.title, title: "Settings", url: nil, kind: .setting(page),
                                          settingAnchor: page.fieldItem(text)?.id), score - 0.6))
            }
            things.sort { $0.1 > $1.1 }
        }
        commandsSpan?.end()
        // Named outright, the words begin its title, it goes above the
        // places, and Return does it. Otherwise it waits under them.
        // Two letters are too few to mean anything, except a layout's own
        // short name, "sf" or "ny", when no address of yours begins with it.
        let short = things.first.map { thing in
            if case .command(let command) = thing.0.kind { return command.arranges && thing.1 >= 3 }
            return false
        } ?? false
        let pasteNamed = things.first { thing in
            guard case .command(.pasteAndMatchStyle) = thing.0.kind else { return false }
            return Command.pasteAndMatchStyle.namedExactly(text)
        }?.0
        let named = pasteNamed ?? (ending == nil && (text.count >= 3 || short)
            ? things.first.flatMap { thing -> Suggestion? in
                guard thing.1 >= 2 else { return nil }
                // A page open or visited that the words name comes first: a
                // command leads over it only called by its whole name. "ins"
                // and "insta" are Instagram before Inspect Element or Add
                // Extension (its "install extension"), and Return goes there.
                // Only rows the list shows count: with Open Tabs or History
                // off in Settings › Field, a hidden tab doesn't hold it back.
                let shown = open.contains(where: FieldUnder.shared.wants) || places.contains(where: FieldUnder.shared.wants)
                if shown, !calledByName(thing.0, text) { return nil }
                // Empty-window Close Tab now closes the window itself. Keep
                // its row discoverable, but require picking it deliberately.
                // A page's existing full-title Return behavior stays unchanged.
                if case .command(.closeTab) = thing.0.kind, closesWindowOnCloseTab { return nil }
                // Rank the sensitive import separately from Return's choice.
                if case .command(.importYabPasswords) = thing.0.kind { return nil }
                // One that acts leads only when called by its whole name,
                // "site controls": a start of it, "clo", is not yet meant.
                if case .command(let command) = thing.0.kind, !command.opens(in: self),
                   command.title(in: self).lowercased() != text.trimmingCharacters(in: .whitespaces).lowercased() { return nil }
                if case .page(let what) = thing.0.kind,
                   (FieldPageRows.command(what) != nil || what == "tracking"),
                   Command.normalizedName(thing.0.key) != Command.normalizedName(text) { return nil }
                if let id = thing.0.menuTargetID,
                   let target = menuTargets.first(where: { $0.id == id }), !target.opens,
                   Command.normalizedName(target.title) != Command.normalizedName(text) { return nil }
                return thing.0
            }
            : nil)
        var rest = Array(things.map(\.0).filter { $0 != named }.prefix(named == nil ? 2 : 1))
        // A short exact action can also prefix a field place, such as Add
        // and Addresses. The place replaces `named` below, so retain the
        // action even when it was selected as that named row. Otherwise
        // exact-name ranking has no row to restore. Return keeps its choice.
        if let exactCommand, let exact = things.first(where: { $0.0.kind == .command(exactCommand) })?.0,
           (exact != named || placeNamed != nil), !rest.contains(exact) { rest.insert(exact, at: 0) }
        // Its title begun, five letters in: meant, though Return still takes
        // the search. It waits above the places rather than under them.
        let begun = text.count < 5 ? [] : rest.filter { row in
            guard case .command = row.kind else { return false }
            return things.contains { $0.0 == row && $0.1 >= 3 }
        }

        // A sum, a place of the field's own, a clip the words find. The
        // commands that open one of the field's places are that place's
        // row, and it is listed once.
        let own = MainBudget.chunk("field.own") { ownRows(for: text, address: address) }
        // The mail accounts the words name, each going to its own mail: the
        // mail tab's row, which goes to mail as it was left, gives them its
        // place. An account's whole address reads as a place too.
        let accounts: (rows: [Suggestion], meant: Bool) = address && !text.contains("@") ? ([], false) : MainBudget.chunk("field.accounts") { mailAccountRows(for: text) }
        // This space's open tabs lead. Other spaces keep their marks and
        // explicit selection, but remain above history too.
        let shown = accounts.rows.isEmpty ? open : open.filter { !MailPage.isMail($0.url) }
        let openHere = shown.filter { automaticOpenPage($0) }
        let openElsewhere = shown.filter { !automaticOpenPage($0) }
        var list: [Suggestion] = openHere + accounts.rows
        list += quick.compactMap { action in
            action.destination.map { Suggestion(key: action.name, title: action.host, url: $0, kind: .quickAction(action.id)) }
        }
        list += extensionCommands.rows
        // What history suggests and isn't kept yet, under the kept ones,
        // saying why: taken, it is kept (take).
        if !address {
            list += QuickActions.shared.offered(text).compactMap { offer in
                URL(string: offer.url).map { Suggestion(key: offer.name, title: offer.detail, url: $0, kind: .quickAction(offer.id)) }
            }
        }
        // A command that opens a place is listed, and leads, as that place's row.
        let namedRow = placeNamed.map { Suggestion(key: $0.title, title: placeDetail($0), url: nil, kind: .place($0)) }
            ?? named.map { FieldPlace.row(for: $0, in: self) }
        if let namedRow { list.append(namedRow) }
        // ⌘T over text selected on the page: the commands the words name,
        // "summ" for Summarize, over the places. ⌘L stays the address's.
        let selecting = address || text.count < 2 ? [] : selectionRows(limit: 3, naming: text)
        // Named by the start of a word of it, and nothing the app does
        // named instead: Return runs it on the selection.
        let selectionNamed = text.count < 3 || namedRow != nil ? nil : selecting.first.flatMap { first -> Suggestion? in
            first.key.lowercased().split(separator: " ").contains { $0.hasPrefix(text.lowercased()) } ? first : nil
        }
        list += selecting
        // A userscript's menu commands on the page under the field, by name.
        if !address { list += userscriptRows(text) }
        list += begun.map { FieldPlace.row(for: $0, in: self) }
        // A remote tab has two destinations: a new copy here and an
        // explicit jump to its existing Space. Keeping only the jump row
        // made selecting a title match leave the Space that asked for it.
        var remoteDestinations = Set<String>()
        var remoteCopies: [Suggestion] = []
        for remote in openElsewhere {
            if asked == .tab, FieldUnder.shared.tabs, let url = remote.url {
                let key = History.key(for: url)
                if !already.contains(key), remoteDestinations.insert(key).inserted {
                    var destination = places.first { $0.url.map(History.key(for:)) == key }
                        ?? Suggestion(key: key, title: remote.key, url: url, kind: .known)
                    destination.opensHere = true
                    list.append(destination)
                    remoteCopies.append(destination)
                }
            }
            list.append(remote)
        }
        list += places.filter { offer in
            offer.url.map { !remoteDestinations.contains(History.key(for: $0)) } ?? true
        }
        list += rest.filter { !begun.contains($0) }.map { FieldPlace.row(for: $0, in: self) }
        list += own.rest
        var listed = Set<String>()
        list = list.filter { offer in
            guard case .place(let place) = offer.kind else { return true }
            return listed.insert(place.rawValue).inserted
        }
        // Only the matches Settings › Field looks for.
        list = list.filter(FieldUnder.shared.wants)
        let engine = searchEngine
        // An address too: under the row that goes there, the same words
        // searched, as Arc and Chrome offer it (#678). Return still goes.
        if let asked = engine.url(for: typed) {
            list.append(Suggestion(key: typed, title: engine.name, url: asked, kind: .search))
        }

        // What Return takes with no row walked to: the ending's place, what
        // was named, or the search, and nothing marked for a bare address,
        // which goes where it says.
        // An address typed out that nothing here finishes: it is the answer,
        // so the list says where Return goes instead of going blank the
        // moment what you type stops matching anything. A page already open
        // there, or a place already known by exactly that address, is that
        // answer with more to say, then it is the one chosen.
        var exact: Int?
        if ending == nil, let url = guessed {
            // Port and all: localhost:3000 is not the page open on localhost:5173.
            let key = Address.pretty(url, port: true).lowercased()
            let explicitScheme = typed.contains("://") ? url.scheme?.lowercased() : nil
            let same: (Suggestion) -> Bool = { offer in
                guard let candidate = offer.url else { return false }
                return Address.pretty(candidate, port: true).lowercased() == key
                    && (explicitScheme == nil || candidate.scheme?.lowercased() == explicitScheme)
            }
            exact = list.firstIndex { automaticOpenPage($0) && same($0) } ?? list.firstIndex { $0.isPlace && same($0) }
            if exact == nil {
                list.insert(Suggestion(key: Address.pretty(url, port: true), title: "", url: url, kind: .address), at: 0)
                exact = 0
            }
        }

        var lead: Int?
        if let quickExact, let quickRow = list.firstIndex(where: { $0.kind == .quickAction(quickExact.id) }) {
            lead = quickRow
        } else if let named = extensionCommands.exact, let row = list.firstIndex(of: named) {
            // Its alias typed whole: Return runs it.
            lead = row
        } else if let exact {
            lead = exact
        } else if !address, exactCommand == nil, exactTarget == nil, exactPage == nil, namedRow == nil,
                  // A saved destination can suppress inline completion, but
                  // only its address begun means navigation. A title match
                  // ("google" in Play Console) stays under the words searched.
                  let kept = (openHere + remoteCopies + saved).first(where: {
                      $0.url.map { History.key(for: $0).hasPrefix(text.lowercased()) } == true
                  }), let row = list.firstIndex(of: kept) {
            lead = row
        } else if let ending {
            // Finishing the address of a page that is already open: Return
            // goes back to it rather than opening it again.
            let whole = (typed + ending).lowercased()
            lead = list.firstIndex { automaticOpenPage($0) && $0.url.map(History.key(for:)) == whole }
                ?? list.firstIndex { $0.isPlace && $0.key == whole }
        } else if let quickName = quick.first(where: { $0.name.lowercased() == text.lowercased() }),
                  let quickRow = list.firstIndex(where: { $0.kind == .quickAction(quickName.id) }) {
            lead = quickRow
        } else if text.contains(" "), ending == nil,
                  case let makers = list.indices.filter({ if case .quickAction = list[$0].kind { true } else { false } }),
                  makers.count == 1 {
            // "new sh": words that leave one thing to make mean it, where
            // a search for them would find nothing.
            lead = makers[0]
        } else if mailNamed, let account = accounts.rows.first, let row = list.firstIndex(of: account) {
            // All Accounts, or the one account there is.
            lead = row
        } else if let namedRow {
            lead = list.firstIndex(of: namedRow)
        } else if let selectionNamed {
            lead = list.firstIndex(of: selectionNamed)
        } else if accounts.meant, let account = accounts.rows.first {
            // An account the words single out by its address: its mail.
            lead = list.firstIndex(of: account)
        } else if text.count >= 3, let known = list.firstIndex(where: {
                      ($0.kind == .known || remoteCopies.contains($0)) && $0.title.lowercased().hasPrefix(text.lowercased())
                  }) {
            // Called by its name, "gmail", a site the field knows goes
            // where the name does, as its address would.
            lead = known
        } else {
            lead = list.firstIndex { $0.kind == .search }
        }
        // The row Return takes is the first one, where the eye lands and
        // where ↓ starts from, never a chosen row at the foot of the list
        // under places that Return would pass over.
        if let chosen = lead, chosen > 0 {
            list.insert(list.remove(at: chosen), at: 0)
            lead = 0
        }
        // Under a place Return goes to, the words themselves, searched: the
        // other thing one short word most often means, one ↓ away rather
        // than under everything the history had to say.
        if lead == 0, list.first?.kind != .search,
           let search = list.firstIndex(where: { $0.kind == .search }), search > 1 {
            list.insert(list.remove(at: search), at: 1)
        }
        // The words, three ways: searched, asked (answered here, in the
        // field), or given to the agent to do in tabs of its own. A question
        // puts Ask on top, a verb the task, anything else the search, and
        // the other two stay right under it in that order, one or two ↓
        // away. Under a place Return goes to, all three follow the place.
        // Never from a private tab: its words go nowhere.
        if !address, ending == nil, query.scope == nil, text.count >= 3, !privateBrowsing,
           let search = list.firstIndex(where: { $0.kind == .search }) {
            // In Settings › Field's order; "The top row" leaves it so.
            var three = underRows(list[search], words: text)
            let leads = search == 0
            let read = wordsLead(text)
            let kind = query.searchOver == read ? .search : read
            if leads, !FieldUnder.shared.firstRow, let top = three.firstIndex(where: { $0.kind == kind }), top > 0 { three.insert(three.remove(at: top), at: 0) }
            list.replaceSubrange(search...search, with: three)
        }
        // Experimental: words that read as one thing to do somewhere known
        // lead with a row of their own, what is known of it beside the list
        // (FieldRequest).
        FieldRequest.shown[ObjectIdentifier(self)] = nil
        if prefs.fieldRequests, !address, ending == nil, query.scope == nil, !privateBrowsing,
           exactCommand == nil, exactTarget == nil {
            let read = Array(RequestReader.read(text, in: self).prefix(4))
            // Pages found in what you read are places like any other: their
            // own rows, with the site's icon and the address in the field,
            // one row per page however many lists found it.
            let leading = lead.flatMap { list.indices.contains($0) ? list[$0].id : nil }
            var pages: [Suggestion] = []
            for request in read {
                guard case .page(let hit, _)? = request.object, let url = URL(string: hit.url) else { continue }
                let key = History.key(for: url)
                if let at = list.firstIndex(where: { $0.url.map(History.key(for:)) == key }) {
                    // Where Return goes already: it stays there.
                    if list[at].id != leading { pages.append(list.remove(at: at)) }
                } else if let tab = tabs.first(where: { $0.address.map(History.key(for:)) == key }) {
                    pages.append(Suggestion(key: tab.label, title: Tab.place(url), url: url, kind: .open, tab: tab.id))
                } else if !pages.contains(where: { $0.url.map(History.key(for:)) == key }) {
                    pages.append(Suggestion(key: hit.title.isEmpty ? hit.host : hit.title, title: Address.pretty(url),
                                            url: url, kind: .visited, seen: hit.at))
                }
            }
            if !pages.isEmpty {
                let at = min(1, list.count)
                list.insert(contentsOf: pages, at: at)
                if let leading { lead = list.firstIndex { $0.id == leading } }
            }
            let requests = read.filter { if case .page? = $0.object { false } else { true } }
            if !requests.isEmpty {
                FieldRequest.shown[ObjectIdentifier(self)] = requests
                // Read sure enough: on top, where Return goes; less sure,
                // right under it.
                let at = requests[0].under && !list.isEmpty ? 1 : 0
                for (index, request) in requests.enumerated().reversed() {
                    // The site once: "Cancel on Supabase", not "… Supabase" again.
                    let site = request.title.contains(request.site) ? "" : request.site
                    list.insert(Suggestion(key: request.title, title: site, url: nil, kind: .request(index)), at: at)
                }
                if at == 0 { lead = 0 }
            }
        }
        // A site the words name that can be searched: Tab makes the field
        // that site's. Said on the site's own row, and a row is made for it
        // under Return's when the list has none.
        let offering = Scopes.offer(for: text, ending: ending)
        if query.offering != offering { query.offering = offering }
        if let offering, !list.contains(where: { offer in
            guard offer.isPlace || offer.kind == .open, let host = offer.url?.host()?.lowercased() else { return false }
            return offering.allHosts.contains { host == $0 || host == "www." + $0 }
        }), let home = offering.home {
            list.insert(Suggestion(key: offering.id, title: offering.name, url: home, kind: .known), at: list.isEmpty ? 0 : 1)
        }
        // Words that are a sum and nothing else: the answer leads, Return
        // copies it.
        if let sum = own.sum {
            list.insert(sum, at: 0)
            lead = 0
        }
        if eligible {
            let suggested = SearchSuggestions.rows(searchSuggestions.items) { engine.url(for: $0) }
            // A few of them, under the words, Ask and Task, and the pages
            // the words name: ten of them once buried both (#103, #108).
            (list, lead) = SearchSuggestions.merge(suggested, into: list, lead: lead)
        }
        // Reading Mode named over an article: right under the words, Ask
        // and Task, not under the engine's guesses. Return still searches.
        if let tab = fieldGuest ?? active, tab.readable || tab.reader,
           let row = list.firstIndex(where: { $0.kind == .command(.reader) }), row != lead,
           let block = list.lastIndex(where: \.isUnderWords), row > block + 1 {
            let leading = lead.flatMap { list.indices.contains($0) ? list[$0].id : nil }
            list.insert(list.remove(at: row), at: block + 1)
            lead = leading.flatMap { id in list.firstIndex { $0.id == id } }
        }
        // Exact feature names stay above history and web completions.
        // Ranking a destructive action is separate from choosing Return's row.
        let exactRow = exactCommand.flatMap { command in list.firstIndex { $0.kind == .command(command) } }
            ?? exactTarget.flatMap { target in list.firstIndex { $0.menuTargetID == target.id } }
            ?? exactPage.flatMap { page in list.firstIndex { $0.id == page.id } }
        if let row = exactRow, row > 0 {
            let leading = lead.flatMap { list.indices.contains($0) ? list[$0].id : nil }
            list.insert(list.remove(at: row), at: 0)
            lead = leading.flatMap { id in list.firstIndex { $0.id == id } }
        }
        // A row that was picked stops being the right row the moment the
        // question changes.
        MainBudget.chunk("field.answer") { answer(list, ending: ending, lead: lead, picked: nil) }
    }

    /// Set together, and only what changed, so a keystroke that leaves the
    /// list as it was redraws the field and not the rows.
    private func answer(_ offers: [Suggestion], ending: String?, lead: Int?, picked: Int?) {
        // The same question answered again (suggestions, history, a reading
        // of the words coming in late) keeps the row walked to or pointed
        // at, wherever it is now: the list never starts over under a hand
        // going down it. A new question starts with nothing chosen.
        let asked = Query.Asked(typed: query.typed, place: query.place, scope: query.scope, actions: query.actionsPage)
        let same = query.answered == asked
        query.answered = asked
        let was = query.offers
        func kept(_ row: Int?) -> Int? {
            guard same, let row, was.indices.contains(row) else { return nil }
            return offers.firstIndex { $0.id == was[row].id }
        }
        let picked = picked ?? kept(query.picked)
        let pointed = kept(query.pointed)
        if query.offers != offers {
            query.grew = offers.count >= query.offers.count
            query.offers = offers
            // A place offered without its icon on this Mac asks for it, and
            // wears it when it comes. Not the address as typed, that is a
            // new host on every key, and nothing from a private tab.
            if !privateBrowsing {
                for offer in offers {
                    let hasMark: Bool = switch offer.kind {
                    case .open, .visited, .known, .quickAction: true
                    default: false
                    }
                    guard hasMark else { continue }
                    guard let host = offer.url?.host()?.lowercased() else { continue }
                    let other = host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www." + host
                    if Favicons.shared.cached(host) == nil, Favicons.shared.cached(other) == nil {
                        Favicons.shared.fetch(host: host)
                    }
                }
            }
        }
        if query.ending != ending { query.ending = ending }
        if query.lead != lead { query.lead = lead }
        if query.picked != picked { query.picked = picked }
        // A new question: nothing is pointed at until the pointer moves
        // again.
        if query.pointed != pointed { query.pointed = pointed }
        query.restingAt = NSEvent.mouseLocation
    }

    /// Typing an address can reuse a tab in this space. A tab in another
    /// space stays in the list for an explicit choice, but cannot make a
    /// plain Return leave this space, even when both share their sign-ins.
    private func automaticOpenPage(_ offer: Suggestion) -> Bool {
        guard offer.kind == .open, let id = offer.tab else { return false }
        if let space = offer.space { return space == spaceID }
        if tab(id: id) != nil { return true }
        return BrowserWindows.shared.owner(of: id)?.browser.spaceID == spaceID
    }

    /// Pages already open that the words name, this space's first, then
    /// each group most recently looked at first.
    /// Going back to one beats opening it a second time. Every window's, and
    /// the rows of the spaces not on screen too, as Arc's Command Bar finds a
    /// tab in any space: taken, its space comes with it.
    func openPages(matching typed: String) -> [Suggestion] {
        openPageMatches(matching: typed).rows
    }

    /// A word of a page's name or site can hold off inline history completion.
    /// A loose URL substring (x in /fixture) must not hide the actual x.com
    /// destination, nor let history jump above genuinely named saved pages.
    private func openPageMatches(matching typed: String) -> (rows: [Suggestion], named: Bool) {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return ([], false) }
        let windows = BrowserWindows.shared.browsers
        var seen = Set<Tab.ID>()
        // A kept tab or a pin is in every window of its space: this
        // window's own tab for it, not another window's (KeptEverywhere.swift).
        var keys = Set<UUID>()
        var pool: [(owner: Browser, tab: Tab, space: UUID?)] = []
        for owner in [self] + windows.filter({ $0 !== self }) {
            for tab in owner.tabs where seen.insert(tab.id).inserted && (!owner.listed(tab) || keys.insert(KeptEverywhere.key(tab)).inserted) {
                pool.append((owner, tab, nil))
            }
            // Mail's row and the shared pins' aside, as ⌃Tab leaves them (a
            // shared pin is in the row on screen already). Split View's
            // field takes only what can go beside the page here.
            guard owner.prefs.usesSpaces, asked != .split else { continue }
            for space in owner.spaces where space.id != owner.spaceID {
                for tab in owner.parked[space.id]?.tabs ?? [] where !tab.bench && tab.guest == nil && seen.insert(tab.id).inserted
                    && (!owner.listed(tab) || keys.insert(KeptEverywhere.key(tab)).inserted) {
                    pool.append((owner, tab, space.id))
                }
            }
        }
        var named = false
        let rows = pool
            .filter { owner, tab, _ in (owner !== self || tab.id != activeID) && !tab.isBlank && !tab.shy && !Agents.shared.sealed(tab) }
            // Split View's field: only the ones that can go beside the page.
            .filter { _, tab, _ in asked != .split || splitTakes(tab) }
            .filter { _, tab, _ in
                guard let url = tab.address else { return false }
                let address = Address.pretty(url)
                let match = SavedPageMatch.matches(needle, title: tab.label + " " + tab.title + " " + (tab.homeTitle ?? ""), url: url)
                if match { named = true }
                return match || address.contains(needle)
            }
            .compactMap { owner, tab, space -> (here: Bool, touched: Date, row: Suggestion)? in
                guard let url = tab.address else { return nil }
                // A tab of another window is in that window's space.
                let here = space == nil && (owner === self || owner.spaceID == spaceID)
                return (here, tab.touched, Suggestion(
                    key: tab.label,
                    title: Tab.place(url),
                    url: url,
                    kind: .open,
                    tab: tab.id,
                    space: space
                ))
            }
            .sorted { $0.touched > $1.touched }
            // This space's tabs first, three at most, then three of the
            // other spaces': fresh tabs elsewhere never push out the one
            // here (#260a).
            .reduce(into: (here: [Suggestion](), elsewhere: [Suggestion]())) { rows, found in
                if found.here { if rows.here.count < 3 { rows.here.append(found.row) } }
                else if rows.elsewhere.count < 3 { rows.elsewhere.append(found.row) }
            }
        return (rows.here + rows.elsewhere, named)
    }

    /// The window, this one or another, whose parked row of that space
    /// holds the tab.
    func parkedOwner(of id: Tab.ID, in space: UUID) -> Browser? {
        ([self] + BrowserWindows.shared.browsers).first { $0.parked[space]?.tabs.contains { $0.id == id } == true }
    }

    /// The words are a thing's whole name, or one of its other whole names:
    /// "add extension" or "install extension", not "inst".
    private func calledByName(_ thing: Suggestion, _ words: String) -> Bool {
        let typed = words.trimmingCharacters(in: .whitespaces)
        if case .command(let command) = thing.kind { return command.matchesExactly(typed, in: self) }
        if let id = thing.menuTargetID, let target = MenuCommands.targets(in: self).first(where: { $0.id == id }) {
            return target.matchesExactly(typed)
        }
        return Command.normalizedName(thing.key) == Command.normalizedName(typed)
    }

    /// A tab of a space not on screen, in this window or another, taken from
    /// the field: its window comes forward, the space comes, and the tab is
    /// the one in front there, as ⌃Tab lands on one.
    @discardableResult
    func goToParked(_ id: Tab.ID, in space: UUID) -> Bool {
        guard let owner = parkedOwner(of: id, in: space) else { return false }
        if owner !== self, let window = BrowserWindows.shared.window(for: owner) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        owner.parked[space]?.active = id
        owner.switchSpace(to: space)
        if owner.activeID != id, let tab = owner.tab(id: id) { owner.select(tab) }
        return owner.activeID == id
    }

    /// A row clicked in the list, taken directly rather than through the
    /// keyboard's selection. The pointer and the arrow keys are answering the
    /// same question but must not share an answer: a list that appears under a
    /// resting cursor would otherwise rewrite the field before you had moved.
    func take(_ offer: Suggestion, _ way: Way = .here, copyingTab: Bool = false) {
        let previousInput = fieldNavigationInput
        fieldNavigationInput = offer.kind == .address ? typed : previousInput
        defer { fieldNavigationInput = previousInput }
        // An extension's row, clicked: told to the extension.
        if let url = offer.url, let row = ExtensionOmnibox.content(of: url) {
            enteredKeyword(row.id, content: row.content, way)
            return
        }
        // A Quick Action taken: what it makes was asked for here, and one
        // history only suggested is kept, alias and all, from now on.
        if case .quickAction(let id) = offer.kind {
            if let suggested = QuickActions.shared.suggestion(id) { QuickActions.shared.accept(suggested) }
            if let url = offer.url { QuickActions.shared.ran(url) }
        }
        // ⌥↩ or ⌥-click on a tab already open: that tab beside the page,
        // as ⌥-click on its row in the column puts it (splitClick).
        if way == .split, let id = offer.tab, let page = active, !page.isBlank, splitFits {
            let here = self.tab(id: id)
            let elsewhere = here == nil ? BrowserWindows.shared.owner(of: id)?.browser.tab(id: id) : nil
            if here != nil || elsewhere.map(splitTakes) == true {
                editing = false
                dropScope()
                typed = ""
                picked = nil
                if let here { splitClick(here) } else if let elsewhere { splitBeside(page, with: elsewhere) }
                return
            }
        }
        // A place, asked for in a new tab. A page already open is only
        // switched to, and what the app does is done where it is.
        if way != .here, offer.tab == nil || copyingTab || way == .split, let url = offer.url {
            switch offer.kind {
            case .command, .setting: break
            default:
                picked = nil
                var url = url
                if offer.kind != .search, offer.kind != .suggested, offer.kind != .asked {
                    if case .quickAction = offer.kind {} else { url = meant(url) }
                }
                send(url, way)
                return
            }
        }
        // The field's own: a sum, a place, a clip, the page's actions.
        if takeOwn(offer) { return }
        // The empty tab that asked, if it was one. When what was asked for
        // lands on another tab, one already open, a private one, one
        // reopened, this one is put away rather than left behind in the
        // row: ⌘T then a name is how you get somewhere, not how you collect
        // empty tabs.
        let asking = active.flatMap { $0.isBlank && $0.pin == nil ? $0 : nil }
        // ⌘T's field: a place goes into a tab of its own, Split View's
        // beside the page. Read before the field goes, which lets go of it.
        let making = self.asking
        // Only an explicitly requested new site follows its configured Space.
        // Search rows and switching to an existing tab keep their own meaning.
        let routingSite = asked == .tab && offer.tab == nil && !offer.opensHere
            && offer.kind != .search && offer.kind != .suggested && offer.kind != .asked
            && !privateBrowsing
        // Raised in a small window, a place goes to that window's page.
        let guest = fieldGuest
        // The field goes first, so what is done next, a new tab, a panel,
        // arrives on a window that is no longer asking for an address.
        editing = false
        dropScope()
        typed = ""
        picked = nil
        var switchedWindow = false
        switch offer.kind {
        case .command(let command):
            // The command list and This Page rows agree about whose link
            // is copied or duplicated after the field lets its guest go.
            if let guest, command == .copyAddress || command == .copyMarkdownLink {
                LinkWindow.all.first { $0.tab === guest }?.copyPage(markdown: command == .copyMarkdownLink)
            } else if let guest, command == .duplicate {
                duplicate(guest)
            } else {
                command.run(in: self)
                teachKeys(of: command)
            }
        case .quickAction:
            if let url = offer.url { place(url, making ?? .tab, from: privateBrowsing ? active : nil) }
        case .setting(let page):
            if let anchor = offer.settingAnchor { openSettings(row: anchor) }
            else { openSettings(page) }
        default:
            // A sealed folder's tab (Yab's own work out of sight) is nobody's
            // to switch to, a hint's page the morning look has open, say:
            // the page comes anew, as if it weren't open.
            let there = offer.tab.flatMap { id in
                tab(id: id) ?? BrowserWindows.shared.owner(of: id)?.browser.tab(id: id)
            }
            let sealed = there.map { Agents.shared.sealed($0) } ?? false
            if let guest, let url = Browser.guestKeeps(offer, making: making) {
                // Raised in a small window: a page already open, a pin's
                // too, is that window's to go to, never the main window's
                // to switch to (register 1012, #615).
                meant(url)
                guest.go(to: url)
            } else if let id = offer.tab, let space = offer.space, there == nil, let owner = parkedOwner(of: id, in: space) {
                // The empty tab that asked goes before its space is parked.
                if owner === self, let asking { close(asking) }
                WrappedLedger.shared.add(.tabJumps)
                goToParked(id, in: space)
                switchedWindow = owner !== self
            } else if making == .split, let tab = there, let page = active, splitTakes(tab) {
                // Split View's field, given a tab already open: that tab
                // beside the page, not switched to in its place.
                splitBeside(page, with: tab)
            } else if !sealed, let tab = self.tab(id: offer.tab) {
                WrappedLedger.shared.add(.tabJumps)
                select(tab)
            } else if !sealed, let id = offer.tab, BrowserWindows.shared.owner(of: id) != nil {
                WrappedLedger.shared.add(.tabJumps)
                switchedWindow = BrowserWindows.shared.focus(tab: id)
            } else if var url = offer.url {
                if offer.kind != .search, offer.kind != .suggested, offer.kind != .asked { url = meant(url) }
                if offer.kind == .search { WrappedLedger.shared.add(.searches) }
                if making == nil, let guest { guest.go(to: url) } else { place(url, making, from: privateBrowsing ? active : nil, routingSite: routingSite) }
            }
        }
        if !switchedWindow, let asking, asking.id != activeID, asking.isBlank { close(asking) }
    }

    /// A window a small window's page opens: a small window of its own
    /// beside it, its opener kept, whether the page asked for a size or
    /// not: a script's window.open, a file page's target=_blank. Only a
    /// new tab you asked for (⌘-click, the menu's Open Link in New Tab)
    /// goes to the main window's row. Every unsized one used to go there,
    /// behind, and nothing in the small window said so (register 986).
    static func smallWindowOpensBeside(sized: Bool, modified: Bool?, menu: Bool?) -> Bool {
        sized || (modified == nil && menu == nil)
    }

    /// Where a small window's field sends a row for a page already open,
    /// a pinned one's included: into that window's own page, by the row's
    /// address, as Little Arc does. Nil for anything else, and for a field
    /// asking for a new tab or Split View.
    static func guestKeeps(_ offer: Suggestion, making: Asked?) -> URL? {
        guard making == nil, offer.tab != nil, let url = offer.url else { return nil }
        switch offer.kind {
        case .command, .setting, .quickAction: return nil
        default: return url
        }
    }

    /// A place asked for in the field rather than reached by a link: the
    /// history counts it as a habit. Nothing from a private tab. What comes
    /// back is where to go: a site that answered at its other name before
    /// goes there at once, else one failure of this name gets a look at it
    /// (WWWRetry, register 1023).
    @discardableResult
    private func meant(_ url: URL) -> URL {
        guard !privateBrowsing else { return url }
        let url = WWWRetry.preferred(url)
        WWWRetry.typed(url)
        history.typedIn(url)
        return url
    }

    /// A Quick Action always makes a new tab, including when a page is
    /// already open. A private tab keeps the destination private.
    func run(_ action: QuickAction) {
        guard action.enabled, let url = action.destination else { return }
        QuickActions.shared.ran(url)
        open(url, foreground: true, from: privateBrowsing ? active : nil)
    }

    /// A backspace means the ending was not wanted. Recomputing it on the very
    /// next keystroke is right; putting it back on this one is what makes a
    /// field impossible to shorten. The list is asked again without it too:
    /// the row Return takes has to be what the field now says, not the place
    /// the ending that just went would have finished.

    /// ⇧⌫ on a place you have been, chosen in the list or finished in the
    /// field: it is not offered again until you go there again. The other
    /// rows, open pages, searches, things to do, are not the history's to
    /// forget, and the key deletes as it always does.
    func forgetChosen() -> Bool {
        // History's own list: the chosen page forgotten, as ⌃X's Forget
        // This Page, not ⌫'s way out of the place (feedback #295).
        if query.place == .history {
            guard !picking, case .visit? = placeItem?.what else { return false }
            return runAction("delete")
        }
        guard let index = query.current, offers.indices.contains(index), forgettable(offers[index]) else { return false }
        forget(offers[index])
        return true
    }

    /// A place you have been, which the history can forget: not a favorite,
    /// nor a bookmark never been to.
    func forgettable(_ offer: Suggestion) -> Bool {
        offer.kind == .visited && !offer.favorite
            && (offer.frequent != nil || !offer.bookmarked || history.remembers(offer.key))
    }

    /// ⇧⌫, ⌘K's Remove and the row's minus: the place goes from the
    /// history and the list is asked again without it. A Frequent row's key
    /// is the title it shows, not the history's (#199: nothing went).
    func forget(_ offer: Suggestion) {
        if let key = offer.frequent {
            history.forgetFrequent(key)
        } else if offer.seen != nil, let url = offer.url {
            history.forget(History.key(for: url))
        } else {
            history.forget(offer.key)
        }
        // Gone from History's list as well, as its own Delete does there.
        if offer.frequent == nil, let url = offer.url { Diary.shared.forget(keys: [Diary.key(url)]) }
        picked = nil
        query.pointed = nil
        query.acting = nil
        // The same words, asked again of a history without it.
        typed = typed
    }

    /// The arrow keys walk the list, and off one end come round at the
    /// other, as ⌘K's list does: ↑ on the first row is the last row, ↓ on
    /// the last the first. From whichever row is chosen, pointed at, walked
    /// to, or the one the field proposes, so the arrows carry on from what
    /// you can see.
    func walk(_ step: Int) {
        // ⌘K's list, when it is up; then a place's own rows or grid.
        if let acting = query.acting {
            let count = shownActions.count
            if count > 0 { query.acting = (acting + step + count) % count }
            return
        }
        if emojiWords != nil { _ = walkEmoji(step); return }
        if walkPlace(step) { return }
        guard !offers.isEmpty else { return }
        let from = query.pointed ?? picked
        query.pointed = nil
        let start = from ?? query.lead
        var next = start.map { $0 + step } ?? (step > 0 ? 0 : offers.count - 1)
        // A row with nothing to take is passed by (MailField's quiet rows),
        // and a list of only those has nothing to walk to.
        var round = false
        for _ in offers.indices {
            if !offers.indices.contains(next) {
                guard walksRound else { picked = from; return }
                next = step > 0 ? 0 : offers.count - 1
                round = true
            }
            guard inert(next) else { break }
            next += step
        }
        guard offers.indices.contains(next), !inert(next) else { picked = nil; return }
        // Round onto the row Return takes anyway: the field says what was
        // typed again, as before the arrows.
        picked = round && next == query.lead ? nil : next
    }

    /// A press of an arrow goes round the end of a list; the key held down,
    /// repeating, stops there, so holding ↓ doesn't spin the list.
    var walksRound: Bool {
        guard let event = NSApp?.currentEvent, event.type == .keyDown else { return true }
        return !event.isARepeat
    }

    /// The pointer moved onto a row. Only a move counts: a list that came up
    /// under a pointer at rest has not been chosen from.
    func point(at index: Int) {
        let now = NSEvent.mouseLocation
        if let resting = query.restingAt {
            guard now != resting else { return }
            query.restingAt = nil
        }
        guard offers.indices.contains(index), query.pointed != index else { return }
        // ⌘K's panel is the row's it was raised for: the pointer crossing
        // the list on its way there chooses nothing else.
        guard query.acting == nil else { return }
        // A row with nothing to take is never pointed at: what was chosen
        // stays chosen.
        guard !inert(index) else { return }
        if picked != nil { picked = nil }
        query.pointed = index
    }

    /// Escape, while a row is chosen by hand: back to what the field proposes.
    @discardableResult
    func unchoose() -> Bool {
        guard picked != nil || query.pointed != nil else { return false }
        picked = nil
        query.pointed = nil
        return true
    }

    // MARK: - the address field

    /// ⌘T over a page: the field, empty, over the page, asking for a tab
    /// of its own; Split View's for the half beside it (see `asked`).
    func openFresh(_ kind: Asked = .tab) {
        query.pasteStyleTarget.captureBeforeField(in: BrowserWindows.shared.window(for: self))
        // A main-window entry takes the shared field back from Little Arc,
        // even when it was already editing there and never closed first.
        fieldGuest = nil
        fieldHost = nil
        landing = nil
        query.pageTyping = active?.typing ?? false
        notePageForm()
        query.here = nil
        dropScope()
        active?.retone(color: false)
        editing = true
        asked = kind
        typed = ""
        query.focusRequest += 1
        // ⌘T over text selected on the page: its commands are rows too,
        // the ones the words name as they are typed.
        if kind == .tab { watchSelection() } else { fieldSelection = nil }
    }

    /// ⌘L. The current address comes up whole and selected, so typing over it
    /// replaces it. Until then the field is only the page's address, nothing
    /// under it, the same quiet field a new tab has.
    func edit() {
        query.pasteStyleTarget.captureBeforeField(in: BrowserWindows.shared.window(for: self))
        fieldGuest = nil
        fieldHost = nil
        asked = nil
        landing = nil
        let page = fieldPage
        query.pageTyping = page?.typing ?? false
        notePageForm()
        // Editing first: the address arriving is then already the page's,
        // and asks nothing of the list.
        query.here = page?.address
        dropScope()
        // How light the page is now, not when it was last scrolled: the
        // field comes up in what was last seen, and corrects itself if the
        // page has turned since. Its color stays the page's (#334).
        page?.retone(color: false)
        editing = true
        typed = query.here.map(Address.whole) ?? ""
        query.focusRequest += 1
        watchSelection()
        refreshPageRows(page)
    }

    /// ⌘L in a small window, or a click on its address: the same field,
    /// raised in that window over its page, the address whole and selected.
    func edit(over tab: Tab, in window: NSWindow) {
        query.pasteStyleTarget.captureBeforeField(in: window)
        asked = nil
        landing = nil
        query.pageTyping = tab.typing
        query.here = tab.address
        dropScope()
        tab.retone(color: false)
        fieldSelection = nil
        fieldGuest = tab
        fieldHost = window
        editing = true
        typed = query.here.map(Address.whole) ?? ""
        query.focusRequest += 1
        refreshPageRows(tab)
    }

    /// ⌘J over selected text: the field, in the selection's own place, its
    /// commands the rows. What one does to the text still happens at the
    /// text: a preview over it, or an answer beside it.
    func editSelection(_ snap: SelectionSnapshot) {
        edit()
        fieldSelection = snap
        enterPlace(.selection)
    }

    /// Text selected on the page the field came up over: its commands are
    /// rows of the field too (FieldPlaces.selectionRows).
    @ObservationIgnored var fieldSelection: SelectionSnapshot?

    /// The page's selection, read as the field comes up over it; the rows
    /// asked again once it is in, the address unchanged.
    private func watchSelection() {
        fieldSelection = nil
        guard let tab = fieldPage, !tab.isBlank else { return }
        selectionCommands.peek(on: tab) { [weak self, weak tab] snap in
            guard let self, let tab, let snap, self.editing, self.fieldPage === tab, self.query.place == nil else { return }
            self.fieldSelection = snap
            self.replaceTyped(self.typed)
        }
    }

    /// The page the field stands over: a small window's own when it was
    /// raised there, else the Peek or active tab. Its icon is the field's, so a
    /// small window's field wears that window's site, not the main
    /// window's tab (register 987).
    var fieldPage: Tab? { fieldGuest ?? (asked == nil ? peeking : nil) ?? active }

    /// The page ⌘L raised the field over, while the field still says its
    /// address as it came.
    var untouched: URL? {
        guard editing, let here = query.here, fieldPage?.address == here,
              typed == Address.whole(here) else { return nil }
        return here
    }

    /// Escape, with the address typed over: the page's address back,
    /// selected, as ⌘L brought it. Another Escape puts the field away.
    @discardableResult
    func restore() -> Bool {
        guard editing, let here = query.here, untouched == nil, fieldPage?.address == here else { return false }
        typed = Address.whole(here)
        query.focusRequest += 1
        return true
    }

    func dismiss() {
        rememberPlace()
        // Raised in a small window: that window's page is under it.
        if fieldGuest != nil {
            editing = false
            landing = nil
            dropScope()
            typed = ""
            return
        }
        // No tab in front: what stands under the field back (`backOut`).
        guard active != nil else { return backOut() }
        // An empty private tab has nothing behind the field to go back to.
        guard active?.isBlank == false else { return }
        editing = false
        landing = nil
        dropScope()
        typed = ""
    }

    /// Where Return sends what the field names: this tab, as plain Return,
    /// a new one behind, as ⌘Return, or a new one brought forward, as
    /// ⌘⇧Return, the way ⌘ and ⌘⇧ take a link; or beside the page in
    /// Split View, as ⌥Return and ⌥-click, as Arc's command bar has them.
    enum Way { case here, behind, ahead, last, split }

    /// The way the keys held down ask for.
    static func way(for flags: NSEvent.ModifierFlags) -> Way {
        guard flags.contains(.command) else { return flags.contains(.option) ? .split : .here }
        return flags.contains(.shift) ? .ahead : .behind
    }

    /// A row clicked with keys held. ⌥ is Split View only while ⌥↩'s
    /// action keeps a key in Settings › Shortcuts (`fieldAlternate`): a key
    /// taken away there, or given to another action, takes the click too.
    static func clickWay(for flags: NSEvent.ModifierFlags, alternate: Hotkey?) -> Way {
        let way = way(for: flags)
        return way == .split && alternate == nil ? .here : way
    }

    /// Search rows only: a chosen command, tab, scope or answer keeps its own key.
    var instantWords: String? {
        guard prefs.instantLinks, query.place == nil, query.scope == nil,
              !query.answering, emojiWords == nil, untouched == nil else { return nil }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        if let chosen = query.current, offers.indices.contains(chosen) {
            switch offers[chosen].kind {
            case .search, .suggested, .asked: return offers[chosen].key
            case .ask, .task: return query.pointed == nil && picked == nil ? words : nil
            default: return nil
            }
        }
        return Address.url(from: words) == nil ? words : nil
    }

    @discardableResult
    func submitInstant() -> Bool {
        guard windowPurpose == .normal else { return false }
        guard let words = instantWords else { return false }
        let requests = InstantLinks.requests(words)
        guard !requests.isEmpty else { return false }
        let origin = activeID
        let originURL = active?.address
        let originSpace = spaceID
        let guest = fieldGuest
        let guestWindow = fieldHost
        let source = guest ?? active
        let store = guest?.store ?? (source?.shy == true ? source!.store : Spaces.store(for: spaceID))
        guard let destination = instantSpace(for: guest, store: store) else { return false }
        let fromGuest = guest != nil
        let guestURL = guest?.address
        let guestPending = guest?.pending
        let guestStarted = guest?.loadStarted
        let guestIsCurrent: @MainActor () -> Bool = { [weak guest, weak guestWindow] in
            guard fromGuest else { return true }
            guard let guest, let guestWindow, !guest.gone, guestWindow.isVisible,
                  LinkWindow.owning(guestWindow)?.tab === guest else { return false }
            return guest.address == guestURL && guest.pending == guestPending && guest.loadStarted == guestStarted
        }
        guard guestIsCurrent() else { return false }
        query.acting = nil
        let choice = searchEngine, engine = choice.engine
        let template = (Store.testing ? Store.settings.string(forKey: "instant.fixtureTemplate") : nil)
            ?? choice.template
        // Private ⌘T already made an empty tab. Keep its store and its row.
        let waiting = source.flatMap { source in
            source.isBlank && source.pending == nil && tabs.contains(where: { $0 === source }) ? source : nil
        }
        let tab = waiting ?? Tab(shy: source?.shy ?? false, configuration: Web.configuration(shy: source?.shy ?? false, store: store))
        tab.instantState = .searching
        tab.instantOrigin = origin
        tab.instantOriginURL = active?.address
        if waiting == nil {
            prepare(tab)
            if destination == spaceID {
                putWaitingRow()
                ColumnMotion.next(.curve(ColumnMotion.room))
                tabs.insert(tab, at: Self.askedLanding(count: tabs.count, keptEnd: keptEnd, strip: !prefs.sidebar))
            } else {
                var row = parked[destination] ?? loadRow(destination)
                let kept = row.tabs.lastIndex { $0.pin != nil || $0.kept }.map { $0 + 1 } ?? 0
                row.tabs.insert(tab, at: Self.askedLanding(count: row.tabs.count, keptEnd: kept, strip: !prefs.sidebar))
                parked[destination] = row
            }
        }
        editing = false
        typed = ""
        landing = nil
        tab.instantTask = Task { @MainActor [weak self, weak tab, weak guestWindow] in
            let groups = await withTaskGroup(of: (Int, [URL]).self) { group in
                for (index, request) in requests.enumerated() {
                    group.addTask { @MainActor in
                        if Task.isCancelled || !guestIsCurrent() { return (index, []) }
                        if let direct = Address.url(from: request.words) { return (index, [direct]) }
                        guard let search = Engine.url(for: request.words, template: template) else { return (index, []) }
                        let loader = InstantLinksSearch(search: search, engine: engine, store: store)
                        return (index, await loader.resolve(count: request.count))
                    }
                }
                var results = [(Int, [URL])]()
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
            }
            guard !Task.isCancelled, let tab, !tab.gone, tab.instantState == .searching else { return }
            tab.instantTask = nil
            guard let owner = tab.delegate as? Browser else { tab.instantState = nil; return }
            if fromGuest {
                // A closed/navigated guest, removed space, or transferred row
                // cannot apply an old request to a different source/container.
                guard owner === self, guestIsCurrent(),
                      let place = owner.spaceHolding(tab), owner.spaces.contains(where: { $0.id == place }),
                      tab.shy || Spaces.store(for: place) === store else {
                    owner.discardInstant(tab)
                    return
                }
            }
            let revealGuest = fromGuest && guestWindow?.isKeyWindow == true && NSApp.isActive
                && !owner.editing && owner.spaceID == originSpace && owner.activeID == origin
                && owner.active?.address == originURL
            owner.finishInstant(tab, urls: Array(groups.prefix(InstantLinks.limit)), fromGuest: fromGuest, revealGuest: revealGuest)
        }
        return true
    }

    /// Rows must use their space's sign-ins. Prefer the current space when
    /// compatible; otherwise use the guest's existing store-owning space.
    /// Shared sign-ins use the first space when the current one is isolated.
    /// An orphaned/foreign store is not silently put into another container.
    private func instantSpace(for guest: Tab?, store: WKWebsiteDataStore) -> UUID? {
        guard let guest, !guest.shy else { return spaceID }
        if Spaces.store(for: spaceID) === store { return spaceID }
        if store === Store.websites { return spaces.first { $0.id == Space.firstID }?.id }
        return spaces.first { Spaces.madeStores[Spaces.signIn(of: $0.id)] === store }?.id
    }

    private func discardInstant(_ tab: Tab) {
        if tabs.contains(where: { $0 === tab }) { close(tab) } else { closeElsewhere(tab) }
    }

    private func finishInstant(_ tab: Tab, urls: [URL], fromGuest: Bool, revealGuest: Bool) {
        guard let first = urls.first else {
            discardInstant(tab)
            return
        }
        // Its current owner places the results, also after the row moved to another window.
        let here = tabs.firstIndex { $0 === tab }
        let away = here == nil ? parked.first { $0.value.tabs.contains { $0 === tab } }?.key : nil
        guard here != nil || away != nil else { tab.instantState = nil; return }
        tab.instantState = .loading
        tab.go(to: first)
        let extra = urls.dropFirst().map { url -> Tab in
            let next = Tab(shy: tab.shy, configuration: Web.configuration(shy: tab.shy, store: tab.store))
            prepare(next)
            next.instantState = .loading
            next.go(to: url)
            return next
        }
        if let at = here {
            if !extra.isEmpty {
                ColumnMotion.next(.curve(ColumnMotion.room))
                tabs.insert(contentsOf: extra, at: at + 1)
            }
            // A user who went elsewhere while the engine answered keeps that page.
            if !fromGuest, !editing, activeID == tab.id || (activeID == tab.instantOrigin && active?.address == tab.instantOriginURL) { select(tab) }
            rememberSession()
        } else if let away, var row = parked[away], let at = row.tabs.firstIndex(where: { $0 === tab }) {
            row.tabs.insert(contentsOf: extra, at: at + 1)
            parked[away] = row
            writeRow(row.tabs, active: row.active, space: away, pairs: row.pairs)
        }
        if revealGuest, let place = spaceHolding(tab) {
            if place != spaceID { switchSpace(to: place) }
            select(tab)
            Links.showBrowser(self)
        }
    }

    /// With the original page still in front, ⌘W stops the search row first.
    func cancelInstantSearch() -> Bool {
        guard !editing else { return false }
        guard let tab = tabs.first(where: { $0.instantState == .searching && ($0.instantOrigin == activeID || $0.id == activeID) }) else { return false }
        close(tab)
        return true
    }

    /// ⌥↩, as in Arc's command bar: what the field names opens in Split
    /// View beside the page in front (`splitOpen`).
    /// Special field places retain their plain-text alternate action.
    func submitAlternate() {
        if query.place != nil || emojiWords != nil { submit(searching: true) }
        else { submit(.split) }
    }

    /// Return. A row picked from the list wins; otherwise what the field was
    /// finishing for you wins; otherwise what you actually typed. If none of
    /// those is a place, nothing happens and the field says so. With
    /// `searching`: the words as typed go to the search engine
    /// even when they look like a place: node.js is a thing to read about as
    /// often as a site.
    func submit(_ way: Way = .here, searching: Bool = false, copyingTabs: Bool = false) {
        let previousInput = fieldNavigationInput
        fieldNavigationInput = searching || picked != nil || query.pointed != nil ? nil : completed
        defer { fieldNavigationInput = previousInput }
        // ⌘K's list: what is chosen in it.
        if let acting = query.acting {
            let actions = shownActions
            query.acting = nil
            if actions.indices.contains(acting) { actions[acting].run() }
            return
        }
        // A place of the field's own: ↩ its first action, ⌘↩ a copy, ⌥↩
        // the text alone.
        if query.place != nil || emojiWords != nil {
            // Rows picked together: ↩ is no act on all of them, ⌫ is.
            if picking { refusals += 1; return }
            if way != .here { _ = runAction("copy") || runPrimary() } else if searching { _ = runAction("plain") } else if !runPrimary() { refusals += 1 }
            return
        }
        if let scope = query.scope {
            if !submitScoped(scope, way, copyingTabs: copyingTabs) { refusals += 1 }
            return
        }
        if searching {
            guard untouched == nil, let url = searchEngine.url(for: typed) else {
                refusals += 1
                return
            }
            send(url, way)
            return
        }
        // Return on the address as ⌘L brought it: you are already there. The
        // field goes; the page is not loaded again, that is ⌘R's. ⌘Return
        // there is the page again, beside itself.
        // A row walked to under it, the page's own actions, is taken below.
        if let here = untouched, query.pointed == nil, picked == nil {
            if way == .here { dismiss() } else { send(here, way) }
            return
        }
        // chrome://extensions, chrome://extensions/shortcuts, typed as in
        // Chrome: the place in Settings that holds the same (ChromePages).
        if query.pointed == nil, picked == nil, let place = ChromePages.typed(typed) {
            let asked = URL(string: typed.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
            ChromePages.open(place, in: self, from: asked)
            return
        }
        // A literal WebUI address must reach the native creation path even
        // when old searches/history offer a matching completion above it.
        if query.pointed == nil, picked == nil, let url = Address.url(from: typed), ChromePages.needsChromium(url) {
            send(url, way)
            return
        }
        // A row walked to is taken as a click would take it, a page already
        // open is switched to, not opened again.
        if let chosen = query.pointed ?? picked, offers.indices.contains(chosen) {
            take(offers[chosen], way, copyingTab: copyingTabs)
            return
        }
        // The index is prepared off the main thread after a large import.
        // Return waits for that answer, rather than taking a temporary
        // search row while the intended history completion is still loading.
        if history.isIndexing {
            pendingHistorySubmit = (way, typed, copyingTabs)
            return
        }
        // Something the words named outright, marked in the list as Return's.
        // A place the ending is finishing goes by the ending, below, and the
        // search by the words as typed.
        if let lead = query.lead, offers.indices.contains(lead), offers[lead].kind != .search,
           !(offers[lead].isPlace && ending != nil) {
            take(offers[lead], way, copyingTab: copyingTabs)
            return
        }

        let target: URL?
        if ending != nil {
            // The words the ending finished are a place's name in the list,
            // its address without its scheme: read back alone, a machine
            // known by one word (nas) is no address, and a server its row
            // opens over http, dev.test:3000, would be tried over https (#761).
            let place = query.lead.flatMap { lead in
                offers.indices.contains(lead) && offers[lead].isPlace && offers[lead].key == completed.lowercased() ? offers[lead].url : nil
            }
            target = Address.finished(completed, place: place)
        } else {
            target = searchEngine.destination(for: typed)
        }

        guard var url = target else {
            refusals += 1
            return
        }
        if ending != nil || Address.url(from: typed) != nil { url = meant(url) }
        send(url, way)
    }

    /// A place the field settled on, sent the way asked. A new tab from a
    /// private one is private too. Behind, the field lets go over a page
    /// and stays over an empty tab, empty again, for the next address: ⌘T,
    /// then one ⌘Return after another, is how a handful are opened at once.
    func send(_ url: URL, _ way: Way) {
        let url = ChromePages.place(of: url) == .newTab ? ChromePages.blank : url
        // CEF rejects a normal renderer's navigation into WebUI. Keep that
        // document (including unsaved forms) and create a browser at this URL.
        // WebKit uses its normal beforeunload-aware engine transaction below.
        let current = fieldGuest ?? active
        let native = ChromePages.needsChromium(url)
        let way: Way = native && way == .here && current?.engineKind == .chromium ? .ahead : way
        // Route before Tab.go replaces the current page's address, or open
        // creates a loose tab that WebKit will subsequently cancel.
        if MailPage.isMail(url) {
            if way != .behind { enterMail(url) }
            dropScope()
            typed = ""
            return
        }
        let from = (native ? current : active).flatMap { $0.isBlank ? nil : $0 }
        switch way {
        case .here:
            // Raised in a small window: its page goes there.
            if let guest = fieldGuest { guest.go(to: url) } else {
                place(url, asking, from: from, routingSite: asked == .tab && !privateBrowsing
                      && (ending != nil || Address.url(from: typed) != nil))
            }
            editing = false
        case .behind:
            let opened = open(url, foreground: false, from: from, into: asking == .tab ? landing : nil)
            sayBehind(opened, url, from: from)
            if active?.isBlank == false { editing = false }
        case .ahead, .last:
            // An empty tab that asked is put away, as `take` puts it away.
            let asking = active.flatMap { $0.isBlank && $0.pin == nil ? $0 : nil }
            open(url, foreground: true, atEnd: way == .last, from: from, into: way == .ahead && self.asking == .tab ? landing : nil)
            if let asking, asking.isBlank { close(asking) }
        case .split:
            // Split View's own field: as its Return.
            if asking == .split {
                place(url, .split, from: from)
            } else if !splitOpen(url, beside: from) {
                // No pair to be had here: the empty tab that asked takes
                // the place, else a tab of its own in front.
                if let blank = active, blank.isBlank, blank.pin == nil { blank.go(to: url) } else { open(url, foreground: true, from: from) }
            }
            editing = false
        }
        dropScope()
        typed = ""
    }

    /// A place the field settled on, made what the field was asking for
    /// (`asking`, read before the field went): a tab of its own beside the
    /// page, or the half beside the page; or, nil, the page under the
    /// field, after ⌘L.
    func place(_ url: URL, _ asking: Asked?, from source: Tab?, routingSite: Bool = false) {
        // Mail's own address goes to its space, as `send` sends it, from a
        // row of Now as from the field, and from inside mail too: a tab made
        // for it would sit loose and pull you back to mail later.
        if windowPurpose == .normal, MailPage.isMail(url), prefs.usesMail {
            enterMail(url)
            return
        }
        switch asking {
        case .split:
            // Put in behind the page, which then makes room for it.
            let page = active
            let tab = open(url, foreground: page == nil, from: source)
            if let page, canCarry(tab, beside: page) { split(tab, with: page) } else { select(tab) }
        case .tab:
            // Cmd-T's new site uses the destination's sign-ins from its first
            // load. Existing-tab rows and Cmd-L never enter this route.
            if routingSite, !privateBrowsing, source?.shy != true,
               ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               let destination = LinkRoutes.shared.space(for: url, in: self), destination != spaceID {
                landing = nil
                switchSpace(to: destination)
                open(url, foreground: true)
            } else {
                open(url, foreground: true, from: source, into: landing)
            }
            landing = nil
        case nil:
            if let page = peeking ?? active {
                // Cmd-L chooses a new destination without replacing a pin's
                // page or icon. Links inside the pinned page still navigate
                // normally; only the command field takes this route.
                if page.pin != nil { open(url, foreground: true, from: page) }
                else { page.go(to: url) }
            } else { open(url, foreground: true, from: source) }
        }
    }

    // MARK: - the page

    /// ⌘+ and ⌘−; in reading mode, the theme's text a size larger or
    /// smaller instead of the page, said in the corner when the card that
    /// shows it isn't out.
    func zoom(by factor: CGFloat) {
        guard let tab = peeking ?? active else { return }
        guard tab.reader else { return tab.stepZoom(increasing: factor > 1) }
        ReaderStyle.shared.prefs.step(factor > 1 ? 1 : -1)
        if !ReaderCard.shared.isOpen { announce("Text \(ReaderStyle.shared.prefs.look.points) pt", mark: "textformat.size") }
    }

    /// ⌘0; in reading mode, back to the theme's own size.
    func resetZoom() {
        guard let tab = peeking ?? active else { return }
        guard tab.reader else { return tab.resetZoom() }
        let own = ReaderStyle.shared.prefs.spec.look.size
        ReaderStyle.shared.prefs.change { $0.size = own }
        if !ReaderCard.shared.isOpen { announce("Text back to \(ReaderStyle.shared.prefs.spec.name)\u{2019}s size", mark: "textformat.size") }
    }

    /// ⌥⌘R, or the book among the doors. The article, and nothing that was
    /// arranged around it. A half's own door acts on that half and brings it
    /// to the front.
    func toggleReader(_ given: Tab? = nil) {
        guard let tab = given ?? active else { return }
        if given != nil { focus(tab) }
        // A translated page stays translated: in the reader once it is up,
        // and on the page once the reader has gone (it is shown again a
        // frame after leaving starts).
        let held = pageTranslation.holdForReader(tab)
        let leaving = tab.reader
        tab.toggleReader { [weak self, weak tab] worked in
            if let self, let tab, let held {
                self.pageTranslation.again(tab, held, after: leaving ? .milliseconds(200) : .zero)
            }
            guard !worked else { return }
            self?.announce("No article on this page", mark: "book.open")
        }
    }

    /// Keyboard/menu reload uses the selected tabs, as Chromium's
    /// ReloadInternal does. A peek or a half's own button has its own target.
    /// Snapshot before reloading: navigation callbacks can change selection.
    func reloadTargets(_ given: Tab? = nil) -> [Tab] {
        if let given { return [given] }
        if let peeking { return [peeking] }
        return several ? chosen : active.map { [$0] } ?? []
    }

    func reload(_ given: Tab? = nil) {
        let targets = reloadTargets(given)
        if let given { focus(given) }
        for tab in targets {
            if !tab.isBlank { reloads += 1 }
            // Your own reload answers Yab's question about one (ReloadAsk).
            if tab.asks.first?.kind == .reload { dismissAsk(tab) }
            Unbreak.shared.reloaded(tab, in: self)
            // Mail's page is drawn from this Mac: its reload is a look at Gmail.
            if tab.showsMail { MailCenter.shared.now("reload", pressed: true) }
            tab.reload()
            unstick(tab, reload: true)
        }
    }
    func hardReload() {
        guard let tab = active else { return }
        if tab.asks.first?.kind == .reload { dismissAsk(tab) }
        if !tab.isBlank { reloads += 1 }
        Unbreak.shared.reloaded(tab, in: self)
        if tab.showsMail { MailCenter.shared.now("reload", pressed: true) }
        tab.hardReload()
        unstick(tab, reload: true)
    }
    /// Arc's Clear Cookies and Refresh: the site's cookies go, the page
    /// loads again signed out (feedback #177). Nothing else it keeps goes;
    /// Site Controls' Clear Cookies and Data does that, after a yes.
    func clearCookiesAndRefresh() {
        guard let tab = active, !tab.isBlank else { return }
        if tab.asks.first?.kind == .reload { dismissAsk(tab) }
        reloads += 1
        Unbreak.shared.reloaded(tab, in: self)
        tab.clearCookiesAndReload()
        unstick(tab, reload: true)
    }
    /// ⌘. or the cross: a stuck page's process is ended if need be (unstick).
    func stop(_ tab: Tab) {
        tab.stop()
        unstick(tab, reload: false)
    }
    /// A door, or with `byKey` ⌘[ and ⌘], whose page just appears.
    func back(_ given: Tab? = nil, byKey: Bool = false) {
        guard let tab = given ?? peeking ?? active else { return }
        if given != nil { focus(tab) }
        if !tab.isBlank, tab.canGoBack { backs += 1 }
        coverHistory(tab, to: tab.webKitOnly("WebKit native page lifecycle", build: false)?.backForwardList.backItem?.url)
        tab.back(byKey: byKey)
    }
    func forward(_ given: Tab? = nil, byKey: Bool = false) {
        guard let tab = given ?? peeking ?? active else { return }
        if given != nil { focus(tab) }
        if !tab.isBlank, tab.canGoForward { forwards += 1 }
        coverHistory(tab, to: tab.webKitOnly("WebKit native page lifecycle", build: false)?.backForwardList.forwardItem?.url)
        tab.forward(byKey: byKey)
    }

    /// Back or Forward on the tab in front to `url`: the last frame kept of
    /// that page put up at once, before WebKit has asked anything
    /// (BACK_STILLS). Once a step: the policy's call finds it up.
    private func coverHistory(_ tab: Tab, to url: URL?) {
        guard Narrow.backStills, tab.id == activeID, let url, let web = tab.webKitOnly("WebKit native page lifecycle", build: false) else { return }
        guard let still = tab.historyStill(for: url) else {
            StageView.mark("cover", ["kept": false, "entries": tab.historyStillCount])
            return
        }
        guard let stage = web.superview as? StageView else { return }
        stage.coverForHistory(still, page: web)
    }

    /// How many times each has been asked for, from a door or a shortcut
    /// alike, so the helm's icons answer ⌘[ the way they answer a click.
    private(set) var backs = 0 {
        willSet { relay.send(\.backs, newValue) }
    }
    private(set) var forwards = 0 {
        willSet { relay.send(\.forwards, newValue) }
    }
    private(set) var reloads = 0 {
        willSet { relay.send(\.reloads, newValue) }
    }
}

// MARK: - WebKit

extension Browser {
    /// Only another place on the page shown (a link to #section): no
    /// document is loaded, nothing to keep the window quiet for.
    nonisolated static func sameDocument(_ url: URL, _ shown: URL?) -> Bool {
        guard let shown, url.fragment != nil,
              var to = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var here = URLComponents(url: shown, resolvingAgainstBaseURL: false) else { return false }
        to.fragment = nil
        here.fragment = nil
        return to == here
    }

    /// An extension's preference tabs are document controls. Leave their
    /// fragment navigation and page click handlers to the extension.
    nonisolated static func extensionFragment(_ url: URL, on shown: URL?) -> Bool {
        ["chrome-extension", "webkit-extension"].contains(url.scheme?.lowercased() ?? "")
            && sameDocument(url, shown)
    }

    /// A Gmail address naming its account by email, /mail/u/name@site/…,
    /// as /mail/?authuser=name@site#…, or nil for any other.
    nonisolated static func gmailByPlace(_ url: URL) -> URL? {
        guard url.host()?.lowercased() == "mail.google.com",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        // "", "mail", "u", "name@site", …
        guard path.count >= 4, path[1] == "mail", path[2] == "u", path[3].contains("@") else { return nil }
        let account = String(path[3])
        parts.path = "/mail/" + path.dropFirst(4).joined(separator: "/")
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "authuser" } + [URLQueryItem(name: "authuser", value: account)]
        return parts.url
    }
}

extension Browser {
    // Standalone WebKit surfaces use the same popup placements without
    // acquiring the row's private setter or its adoption implementation.
    func adoptPagePopup(_ tab: Tab) { adopt(tab) }
    func appendPagePopup(_ tab: Tab) { tabs.append(tab) }
    func insertPagePopup(_ tab: Tab, at index: Int) { tabs.insert(tab, at: index) }

    /// Keep Chromium's original document and opener. A native user-popup
    /// receipt can place it before row insertion; subsequent transitions
    /// describe navigation inside that document, not its placement.
    @discardableResult
    func peekAdoptedLink(_ tab: Tab, from source: Tab, action: PageAction, atCreation: Bool = false) -> Bool {
        let flags = action.modifierFlags.intersection([.command, .shift, .option, .control])
        guard action.kind == .linkActivated, !source.bench,
              tabs.contains(where: { $0 === source }), atCreation || tabs.contains(where: { $0 === tab }),
              let url = action.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") || (atCreation && url.absoluteString == "about:blank"),
              !CallLink.isCall(url), !Self.middleClick(action.buttonNumber),
              flags == PeekClick.read(in: Store.settings).flags || (flags.isEmpty && (source.pin != nil || source.kept)),
              let view = peekView, view.window != nil else { return false }
        dropPeek(of: source)
        // Adoption may have selected the child before its held navigation
        // arrived. Restore the source before taking its child out of the row.
        if activeID == tab.id { select(source) }
        tabs.removeAll { $0 === tab }
        outside.append(tab)
        source.peek = tab
        if activeID == source.id {
            peeking = tab
            peekFrom = source.id
            view.present(tab, shy: source.shy, from: source.builtPage)
        }
        return true
    }

    /// Whether a ⌘-click or middle-click link tab comes to the front (⇧ held):
    /// nil for an ordinary click. A site that opens the link itself, X's
    /// t.co links, a YouTube embed's, calls window.open from its click
    /// handler: the action has no modifiers then. Use the source page's
    /// native click receipt, for a plain tab rather than a sized popup.
    nonisolated static func modifiedForeground(for action: PageAction, isPopup: Bool, held: NSEvent.ModifierFlags, afterClick: Bool, clickedButton: Int? = nil, clickedFlags: NSEvent.ModifierFlags? = nil) -> Bool? {
        if action.modifierFlags.contains(.command) || middleClick(action.buttonNumber) {
            return action.modifierFlags.contains(.shift)
        }
        // window.open has no mouse intent in its navigation action. The
        // click receipt survives both the script boundary and key release.
        let flags = clickedFlags ?? held
        if action.kind == .other, !isPopup, afterClick,
           flags.contains(.command) || clickedButton == 2 { return flags.contains(.shift) }
        return nil
    }

    /// A link that asks for a new window gets a tab in the same places as
    /// before. The engine owns the opener relationship and construction.
    func page(_ page: any PageHandle, open request: PagePopup,
              reply: @escaping @MainActor (UUID?) -> Void) {
        let action = request.action
        let menuForeground = request.menuForeground
        let modifiedForeground = Self.modifiedForeground(for: action, isPopup: request.isPopup, held: NSEvent.modifierFlags,
                                                        afterClick: page.webKit?.hasRecentWindowClick == true, clickedButton: page.webKit?.recentWindowClickButton,
                                                        clickedFlags: page.webKit?.recentWindowClickModifiers)
        let parent = tab(owning: page)
        let from = parent?.id ?? activeID
        // Asked for with no click of yours nearby: kept back, and the plate
        // says so (WindowGate).
        guard letsWindow(from: page, for: action, parent: parent) else { reply(nil); return }
        let popup = request.isPopup
        // window.open, not a link: the opener waits on this one's answer.
        let scripted = action.kind == .other ? Date() : nil
        // A link from Peek asking for another page opens a tab in this
        // space. Peek shares outside storage with Small Window, but is
        // not one: its links must not acquire a separate little window.
        // Scripted popups still take their window and keep their opener.
        let peekLink = parent != nil && parent === peeking && action.kind == .linkActivated && !popup
        // A plain target=_blank link stays in Small Window, as Little
        // Arc does, so Back uses that window's own history. Explicit new
        // tabs still go to the row; any other window the page opens, a
        // script's with or without a size, is a small window of its own
        // (smallWindowOpensBeside).
        if let parent, !peekLink, outside.contains(where: { $0.id == parent.id }) {
            if action.kind == .linkActivated, action.source?.isMainFrame == true,
               !popup, modifiedForeground == nil, menuForeground == nil,
               page.webKitLinkWindow != nil, let url = action.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                page.navigate(to: action.request)
                reply(nil); return
            }
            guard let tab = page.webKitPopupTab(request.id, shy: parent.shy) else { reply(nil); return }
            tab.popup = popup
            tab.opener = from
            tab.from = from
            if action.kind == .linkActivated { linkBack(tab, to: parent) }
            tab.scripted = scripted
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            let size = request.size
            if Self.smallWindowOpensBeside(sized: size != nil, modified: modifiedForeground, menu: menuForeground) {
                prepare(tab)
                outside.append(tab)
                LinkWindow.present(tab, for: self, size: size)
            } else {
                adopt(tab)
            }
            reply(tab.id)
            return
        }
        // A window an agent's page opens, a sign-in with Google, most often,
        // is the agent's too: beside yours, behind what you are looking at,
        // and handed to you only if the agent asks.
        if let parent, parent.bench {
            guard let tab = page.webKitPopupTab(request.id, bench: true) else { reply(nil); return }
            tab.popup = popup
            prepare(tab)
            tabs.append(tab)
            tab.opener = from
            tab.from = from
            if action.kind == .linkActivated { linkBack(tab, to: parent) }
            tab.scripted = scripted
            tab.assistantSpace = parent.assistantSpace
            tab.agent = parent.agent
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            // Opened while you have the tab, you are the one signing in,
            // it comes to you, as any window you opened would.
            // What the agent needed of you there, it needs here now: the
            // sign-in goes on in this window.
            tab.inheritHandoff(from: parent)
            if Agents.optional.contains(parent.id) { Agents.optional.insert(tab.id) }
            defer { Agents.shared.recall() }
            if parent.id == activeID, menuForeground ?? modifiedForeground ?? true {
                activeID = tab.id
                editing = false
            } else {
                Bench.shared.house(tab)
            }
            reply(tab.id)
            return
        }
        // Window features express a separate browsing window. Keep WebKit's
        // related document, rather than opening its URL in a replacement view.
        if popup {
            guard let tab = page.webKitPopupTab(request.id, shy: parent?.shy ?? false) else { reply(nil); return }
            tab.popup = true; tab.opener = from; tab.from = from; tab.scripted = scripted
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            prepare(tab)
            outside.append(tab)
            LinkWindow.present(tab, for: self, size: request.size)
            reply(tab.id)
            return
        }
        // A web page sending you on to an extension's own page in a new tab,
        // Nord Account handing NordPass back its sign-in (app.html?verify_token=):
        // WebKit's copy of the web page's configuration can't serve
        // chrome-extension://, and the tab came up blank or "couldn't load".
        // It is built for the extension instead, as a typed address is; the
        // web page that opened it gives up its hold on it.
        if let parent, !parent.shy, tabs.contains(where: { $0 === parent }),
           let url = action.request.url, let target = Self.extensionHost(of: url),
           target != page.url.flatMap(Self.extensionHost(of:)) {
            _ = open(url, foreground: parent.id == activeID, from: parent, linked: true, backToSource: action.kind == .linkActivated)
            reply(nil); return
        }
        // A link to a site a rule keeps in another space: opened there, in
        // that space's sign-ins, as Arc's Air Traffic Control sends it
        // (LinkRoutes). Only a link you clicked, or Open Link in New Tab: a
        // script's window, a sign-in, talks to its page and stays by it.
        if action.kind == .linkActivated || menuForeground != nil, !popup, let parent,
           tabs.contains(where: { $0 === parent }), let url = action.request.url,
           routePageLink(url, from: parent, foreground: menuForeground ?? modifiedForeground ?? true) {
            reply(nil); return
        }
        // Place the related WebKit document at creation too. Cancelling
        // the popup and opening its URL again loses the opener, and script
        // click handlers need not report a link transition on their child.
        if !popup, modifiedForeground == nil, menuForeground == nil,
           action.kind == .linkActivated || action.userInitiated,
           let parent, !parent.bench, parent.pin != nil || parent.kept,
           tabs.contains(where: { $0 === parent }), peekView?.window != nil,
           action.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           let url = action.request.url, !CallLink.isCall(url),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank",
           let tab = page.webKitPopupTab(request.id, shy: parent.shy) {
            prepare(tab)
            tab.opener = parent.id; tab.from = parent.id
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            let placement = PageAction(request: action.request, kind: .linkActivated,
                targetIsMainFrame: true, source: action.source, modifierFlags: action.modifierFlags,
                buttonNumber: action.buttonNumber, shouldPerformDownload: false, userInitiated: true)
            let placed = peekAdoptedLink(tab, from: parent, action: placement, atCreation: true)
            assert(placed, "Creation eligibility must match Peek placement")
            if action.kind == .linkActivated { linkBack(tab, to: parent) }
            reply(tab.id); return
        }
        // A link to a new tab has no opener to keep, so its tab follows the
        // rules, not the page: from a site kept on WebKit, a link to anywhere
        // else opens on the default. A script's window stays with its page.
        if action.kind == .linkActivated || menuForeground != nil, !popup, let parent, !parent.shy,
           tabs.contains(where: { $0 === parent }), let url = action.request.url, parent.leavesEngine(for: url) {
            _ = open(url, foreground: menuForeground ?? modifiedForeground ?? true, from: parent, linked: true,
                     backToSource: action.kind == .linkActivated)
            reply(nil); return
        }
        guard let tab = page.webKitPopupTab(request.id, shy: parent?.shy ?? false) else { reply(nil); return }
        tab.popup = popup
        if !popup, parent?.bench == false, (menuForeground ?? modifiedForeground ?? true) == false,
           menuForeground != nil || (action.userInitiated && action.kind == .linkActivated) {
            tab.prepareVideoOpening(action.request.url)
        }
        if let parent, tabs.contains(where: { $0 === parent }) {
            // After the page that opened it and what that page already
            // opened, as Arc puts a link that opens a new tab.
            prepare(tab)
            tabs.insert(tab, at: linkLanding(from: parent))
            tab.linkedFrom = parent.id
        } else {
            adopt(tab)
        }
        tab.opener = from
        tab.from = from
        if action.kind == .linkActivated, let parent { linkBack(tab, to: parent) }
        tab.scripted = scripted
        // A link that opens in a new tab, from a page a search gathered: in
        // the folder too. Not a window a script asked for, a sign-in. With
        // ⌘-clicking links making folders, from a page in any folder of
        // today's: in it, right after the page, as Dia puts it.
        if menuForeground != nil, !popup, let parent {
            // Open Link in New Tab is the same explicit tab request as a
            // Command-click. The engine may report its native menu action
            // as .other, so the trusted menu receipt carries that intent.
            gatherSearch(tab, from: parent)
        } else if action.kind == .linkActivated, !popup, let parent, let nest = parent.nest {
            if nest.research {
                gatherSearch(tab, from: parent)
            } else if nest.today, !nest.byExtension, prefs.linkFolders {
                tab.nest = nest
                if let at = tabs.firstIndex(where: { $0 === parent }), let here = tabs.firstIndex(where: { $0 === tab }), here != at + 1 {
                    move(tab, to: here > at ? at + 1 : at)
                }
                ColumnMotion.next(.folder)
                folderBook.refresh()
            }
        }
        // Shut again within seconds, it was a look: Peek's hint (Teach.swift).
        if action.kind == .linkActivated, !popup { tab.linkBorn = Date() }
        if menuForeground ?? modifiedForeground ?? true {
            activeID = tab.id
            editing = false
        } else if !popup, let url = action.request.url {
            sayBehind(tab, url, label: LinkStatus.shared.label(of: url, in: parent?.id), from: parent)
        }
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        reply(tab.id)
    }

    func page(_ page: any PageHandle, became download: any PageDownload, isMainFrame: Bool) {
        captureDownloadFolder(download, page: page)
        if isMainFrame { downloadBecame[ObjectIdentifier(download)] = { [weak page] in page } }
        keep(download)
    }

    /// Every download this window has going, heard from until it ends, and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(_ download: any PageDownload) {
        guard !downloading.contains(where: { $0 === download }) else { return }
        captureDownloadFolder(download)
        if let page = download.pageURL, ["http", "https"].contains(page.scheme ?? "") {
            downloadPages[ObjectIdentifier(download)] = (page, download.pageTitle ?? "")
        }
        DebugLog.note("download", ["url": String(download.originalRequest?.url?.absoluteString.prefix(120) ?? ""),
                                   "user": download.isUserInitiated])
        download.downloadEvents = self
        downloading.append(download)
        hoard.expect(download)
        download.webKitCreated()
    }

    /// Closes a Peek tab when its page calls `window.close()` (for example at
    /// the end of an adopted OAuth popup). Returns whether `tab` was a Peek.
    @discardableResult
    func closePeekTab(_ tab: Tab) -> Bool {
        guard !isLive(tab) else { return false }
        if peeking === tab {
            closePeek()
            return true
        }
        if let source = tabs.first(where: { $0.peek === tab }) ?? parkedTabs.first(where: { $0.peek === tab }) {
            dropPeek(of: source)
            return true
        }
        return false
    }

    /// An ordinary tab's page asking to close itself.
    func pageClosed(_ page: any PageHandle) {
        guard let tab = tab(owning: page) else { return }
        if closePeekTab(tab) { return }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if !tab.bench || tab.id == activeID, let home = self.tab(id: tab.opener) {
            select(home)
        }
        tab.pin = nil
        close(tab)
    }

    /// `failed`, typed, did not load: the tab goes to `other` if that
    /// answers, while the tab still shows the failure, and the site's
    /// working name is kept for the next time it is typed. `then` runs if
    /// nothing answers there, or the tab has moved on.
    func lookAtOtherName(_ tab: Tab, failed: URL, other: URL, then: (@MainActor () -> Void)? = nil) {
        let showing = tab.address
        Task { @MainActor [weak tab] in
            let answered = await WWWRetry.answers(other)
            guard answered, let tab, tab.address == showing, self.tabs.contains(where: { $0 === tab }) else {
                then?()
                return
            }
            DebugLog.note("wwwretry", ["from": failed.host ?? "", "to": other.host ?? ""])
            WWWRetry.keep(failed, answered: other)
            tab.go(to: other)
        }
    }

    /// What `_webView(_:getWindowFrameWithCompletionHandler:)` answers, in
    /// the screen's coordinates: the page's own rectangle on the screen in
    /// its window; in none, its size at the origin of the window its tab is
    /// shown in, or of the screen; not sized yet, that window.
    static func windowFrame(of webView: NSView, shownIn window: NSWindow?) -> CGRect {
        if let own = webView.window { return own.convertToScreen(webView.convert(webView.bounds, to: nil)) }
        let size = webView.bounds.size
        guard size.width >= 1, size.height >= 1 else { return window?.frame ?? .zero }
        return CGRect(origin: window?.frame.origin ?? .zero, size: size)
    }


    /// A page from a small window, kept: into the row beside the tab on
    /// screen, and in front, loaded as it is.
    func takeIn(_ tab: Tab) {
        outside.removeAll { $0.id == tab.id }
        let here = tabs.firstIndex { $0.id == activeID }
        tabs.insert(tab, at: here.map { max($0 + 1, pinnedCount) } ?? tabs.count)
        select(tab)
    }

    /// Transfer ownership of a live page without closing its WKWebView.
    /// BrowserWindows checks the Space, privacy and split constraints first.
    /// `standIn`: a kept tab's or a pin's own tab here, asleep, takes its
    /// place (KeptEverywhere.swift), and is not landed on.
    func moveOut(_ tab: Tab, leaving standIn: Tab? = nil) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.documentPiP.close()
        dropPeek(of: tab)
        if floating == tab.id { land() }
        let wasActive = activeID == tab.id
        if let page = tab.builtPage, let stage = page.superview as? StageView { stage.relinquish(page) }
        tab.builtPage?.removeFromSuperview()
        calls.set(tab.id, live: false)
        calls.over[tab.id] = nil
        if let standIn { tabs[index] = standIn } else { tabs.remove(at: index) }
        if wasActive, let next = nearestOpen(to: index, in: tabs.filter { $0 !== standIn }, where: { $0.pin == nil && !$0.kept }) {
            select(next)
        } else if wasActive || tabs.isEmpty {
            // Only saved rows or sealed folders remain: as after closing
            // the last page, leave the field without waking a bookmark.
            activeID = nil
            askNew()
        }
        writeSession(now: true)
    }

    /// Take the same tab and view into another window. Its delegates now
    /// answer to this Browser; the old one has already let go of it.
    /// Brought in behind the page in front when not `selecting`, asleep
    /// until selected if it had no page before the move.
    /// `replacing`: this window's own tab for the same kept tab or pin,
    /// asleep, whose place it takes, in this window's folder
    /// (KeptEverywhere.swift).
    func moveIn(_ tab: Tab, selecting: Bool = true, replacing mine: Tab? = nil) {
        guard windowPurpose == .normal || tab.shy else { return }
        if mine == nil, tabs.count == 1, tabs[0].isBlank, let empty = tabs.first, selecting {
            tabs = []
            empty.close()
        }
        prepare(tab)
        calls.set(tab.id, live: tab.onCall)
        if let mine, let at = tabs.firstIndex(where: { $0 === mine }) {
            tab.nest = mine.nest
            let front = activeID == mine.id
            tabs[at] = tab
            if front { activeID = tab.id }
            AgentPage.forget(mine)
            mine.close()
        } else {
            tabs.append(tab)
        }
        if selecting || active == nil {
            // Use the selection lifecycle, including the field and early
            // stage handoff. Merely writing activeID can leave a returned
            // live page detached behind the old window's field.
            if activeID == tab.id { tab.wake(); editing = false; restage() }
            else { select(tab) }
        }
        writeSession(now: true)
    }

    /// Its window closed: every page in it goes, the row's, a parked
    /// space's, a peek's, as a closed window's tabs do in Chrome. Kept, they
    /// went on running out of sight, sound, timers and extensions' scripts.
    /// Reopened, the window comes back from its session file.
    func letGo() {
        fullscreenDeparture.stop()
        stopWatching()
        for tab in tabs + parkedTabs + outside { tab.close() }
    }

    /// A small window's page, closed without being kept.
    func letGo(outside tab: Tab) {
        if suggesting?.tab == tab.id { dropChoice() }
        if walletList?.tab == tab.id { dropWallet() }
        if codeList?.tab == tab.id { codeList = nil; codeWatch.stop() }
        if loginWaiting?.tab == tab.id { loginWaiting = nil }
        outside.removeAll { $0.id == tab.id }
        Diary.shared.closed(tab.id)
        dropAsks(tab)
        tab.close()
    }
}

// MARK: - keeping files

extension Browser: PageDownloadEvents {
    /// The actual owning row, including parked tabs and an outside page's
    /// opener. Never infer an unknown source from whichever Space is active.
    func downloadSpace(for tab: Tab?) -> UUID? {
        guard prefs.usesSpaces else { return nil }
        var next = tab
        var seen = Set<UUID>()
        while let tab = next, seen.insert(tab.id).inserted {
            let here = tab.homeSpace ?? spaceHolding(tab)
                ?? LinkWindow.all.first(where: { $0.tab === tab })?.downloadSpace
            if let here, spaces.contains(where: { $0.id == here }) { return here }
            let source = tab.opener ?? tab.from
            next = source.flatMap { id in (tabs + outside + parkedTabs).first { $0.id == id } }
        }
        return nil
    }

    func downloadFolder(for tab: Tab?) -> URL {
        DownloadFolder.destination(for: downloadSpace(for: tab), fallback: prefs.downloads)
    }

    /// The folder command is about the current Space; an unknown download
    /// source, unlike this explicit UI action, still follows General.
    var currentDownloadFolder: URL {
        DownloadFolder.destination(for: prefs.usesSpaces && spaces.contains(where: { $0.id == spaceID }) ? spaceID : nil,
                                   fallback: prefs.downloads)
    }

    private func captureDownloadFolder(_ download: any PageDownload, page: (any PageHandle)? = nil) {
        let id = ObjectIdentifier(download)
        guard downloadFolders[id] == nil else { return }
        let tab = (page ?? download.page).flatMap { self.tab(owning: $0) }
        downloadFolders[id] = downloadFolder(for: tab)
    }

    func download(
        _ download: any PageDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler incoming: @escaping @MainActor (URL?) -> Void
    ) {
        let id = ObjectIdentifier(download)
        guard downloadReplies[id] == nil, downloadParts[id] == nil,
              !failedDownloadIDs.contains(download.downloadID), !completedDownloadIDs.contains(download.downloadID) else { incoming(nil); return }
        let reply = DownloadReply(incoming)
        downloadReplies[id] = reply
        let completionHandler: @MainActor (URL?) -> Void = { [weak self] file in
            guard reply.pending else { return }
            self?.downloadReplies[id] = nil
            reply.answer(file)
        }
        if let error = DownloadRequest.failure(response) {
            completionHandler(nil)
            self.download(download, didFailWithError: error, resumeData: nil)
            return
        }
        captureDownloadFolder(download)
        let asked = downloadNames.removeValue(forKey: id)
            ?? response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
            ?? (download.originalRequest?.url).flatMap { namedDownloads.removeValue(forKey: $0) }
        // A tab, a peek or a small window opened only to fetch this steps
        // aside now and goes once the file is in: closed while the file
        // was still coming, a window a page opened took its download with
        // it.
        if let opened = downloadBecame[ObjectIdentifier(download)]?() {
            let fetching = [download.originalRequest?.url, response.url]
            downloadBecame[ObjectIdentifier(download)] = { [weak opened] in opened }
            downloadFetching[ObjectIdentifier(download)] = fetching
            DispatchQueue.main.async { [weak self, weak opened] in
                if let opened { self?.stepAside(opened, fetching: fetching) }
            }
        }
        if let page = download.pageURL, page.scheme == "https" || page.scheme == "http" {
            downloadPages[ObjectIdentifier(download)] = (page, download.pageTitle ?? "")
        }
        let proposed = asked ?? suggestedFilename
        if let webKit = download as? WKDownload {
            ExtensionDownloads.determineFilename(webKit, proposed: proposed) { [weak self] resolved in
                guard let self, self.downloadReplies[id]?.pending == true else { return }
                self.chooseDownloadDestination(download, response: response, proposed: resolved, completionHandler)
            }
        } else {
            chooseDownloadDestination(download, response: response, proposed: proposed, completionHandler)
        }
    }

    private func chooseDownloadDestination(_ download: any PageDownload, response: URLResponse,
                                           proposed: String, _ completionHandler: @escaping @MainActor (URL?) -> Void) {
        let name = download.isExtensionDownload
            ? DownloadRequest.relativeFilename(proposed) ?? DownloadRequest.filename(proposed)
            : DownloadRequest.filename(proposed)
        let host = download.originalRequest?.url?.host() ?? ""

        // An agent's: into its task's folder, never a panel.
        if let (folder, session) = AgentFiles.shared.claim(download) {
            downloadFolders[ObjectIdentifier(download)] = folder
            let url = DownloadDestinations.reserve(name, in: folder, for: download.downloadID)
            prepareDownload(download, response: response, destination: url, from: host, agent: session, completionHandler)
            return
        }

        // Retry is an explicit request for this file, not another file
        // started by the site without a new click inside its web view.
        if retryingDownloadIDs.remove(download.downloadID) != nil {
            saveDownload(download, response: response, name: name, from: host, completionHandler)
            return
        }

        // Started by the page with nobody's click: asked first, the answer
        // kept for the site (SiteDownloads). No leaves nothing behind.
        let refuse = { [weak self] in
            guard let self else { return completionHandler(nil) }
            self.downloadPages.removeValue(forKey: ObjectIdentifier(download))
            self.downloadFolders.removeValue(forKey: ObjectIdentifier(download))
            self.hoard.drop(download)
            download.webKitFailed(resumable: false, canceled: true)
            completionHandler(nil)
        }
        let go = { [weak self] in
            guard let self else { return completionHandler(nil) }
            self.saveDownload(download, response: response, name: name, from: host, completionHandler)
        }
        // More files than a click asked for (SiteDownloads.more): asked once
        // for all of them, the answer kept for the site. Counted for every
        // file, the unasked ones too, so a page's second file is "multiple".
        let alone = download.isExtensionDownload ? nil : SiteDownloads.asking(download)
        let more = download.isExtensionDownload ? nil : SiteDownloads.more(download)
        if let site = alone ?? more {
            if alone != nil, let said = SiteDownloads.answer(for: site) { return said ? go() : refuse() }
            // A site let download automatically (Site Controls) sends every
            // file, the first unasked one too, as Chromium's Allowed does; a
            // blocked one still gets its first, as Chromium's Blocked does.
            if let said = SiteDownloads.many(for: site), said || more != nil { return said ? go() : refuse() }
            guard let tab = download.page.flatMap({ self.tab(owning: $0) }) ?? active else { return refuse() }
            askDownloads(site, name: name, many: more != nil, on: tab) { yes in yes ? go() : refuse() }
            return
        }
        saveDownload(download, response: response, name: name, from: host, completionHandler)
    }

    /// One card per tab and site for the files a page sends that nobody's
    /// click asked for, as Chromium asks once for a site's parts (Google
    /// Drive's "zip 1 of 4", each started seconds after the click, #1940).
    /// A file that comes while the card is up waits on its answer, and a
    /// second one makes it the "multiple files" card; one Allow lets every
    /// one of them in. Before, each unasked file queued a card of its own.
    func askDownloads(_ site: String, name: String, many: Bool, on tab: Tab, _ then: @escaping (Bool) -> Void) {
        let key = tab.id.uuidString + " " + Browser.site(site)
        if let up = manyAsking[key] {
            manyAsking[key] = (card: up.card, waiting: up.waiting + [then])
            changeAsk(up.card, on: tab) { $0.kind = .downloads }
            return
        }
        let question = PageAsk(kind: many ? .downloads : .download, host: site, message: name)
        manyAsking[key] = (card: question.id, waiting: [then])
        // The page's origin, as Chromium keeps a site's automatic downloads.
        let origin = Self.origin(of: tab.address)
        ask(question, on: tab) { [weak self] reply, answered in
            let yes: Bool
            if case .yes = reply { yes = true } else { yes = false }
            // Pressed, not taken away by leaving the page: kept. A "multiple
            // files" answer is the site's automatic downloads, which lets
            // the parts still to come in; a lone file's is kept until quit.
            if answered.ticked {
                if answered.kind == .downloads { SiteDownloads.rememberMany(site, yes, origin: origin) } else { SiteDownloads.remember(site, yes) }
            }
            for waiting in self?.manyAsking.removeValue(forKey: key)?.waiting ?? [] { waiting(yes) }
        }
    }

    /// Where a download of yours goes: Downloads, or where the panel says.
    private func saveDownload(
        _ download: any PageDownload,
        response: URLResponse,
        name: String,
        from host: String,
        _ completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        guard downloadReplies[ObjectIdentifier(download)]?.pending == true else { return }
        // A transfer has an identity. URL/time deduplication also discarded
        // a real second click and an immediate retry after a fast failure.
        let folder = downloadFolders[ObjectIdentifier(download)] ?? prefs.downloads
        guard !prefs.asksWhereToSave else {
            let chosen: @MainActor (URL?) -> Void = { [weak self] url in
                guard let self else { completionHandler(nil); return }
                guard self.downloadReplies[ObjectIdentifier(download)]?.pending == true else { return }
                guard let url else {
                    self.downloadFolders.removeValue(forKey: ObjectIdentifier(download))
                    self.hoard.drop(download)
                    download.webKitFailed(resumable: false, canceled: true)
                    completionHandler(nil)
                    return
                }
                DownloadFolder.check(url.deletingLastPathComponent()) { open in
                    guard self.downloadReplies[ObjectIdentifier(download)]?.pending == true else { return }
                    guard open else {
                        self.downloadFolderClosed(url.deletingLastPathComponent())
                        completionHandler(nil)
                        self.hoard.drop(download)
                        self.downloadFolders.removeValue(forKey: ObjectIdentifier(download))
                        download.webKitFailed(resumable: false, canceled: true)
                        return
                    }
                    self.prepareDownload(download, response: response, destination: url, from: host,
                                         replacesExisting: true, completionHandler)
                }
            }
            chooseDownloadLocation(DownloadRequest.filename(name), folder, chosen)
            return
        }


        // Into a folder Yab may write in: one macOS keeps closed, or never
        // answered for, kept the file "in progress" forever (#400).
        DownloadFolder.check(folder) { [weak self] open in
            guard let self else { return completionHandler(nil) }
            guard self.downloadReplies[ObjectIdentifier(download)]?.pending == true else { return }
            if !open {
                try? FileManager.default.createDirectory(at: DownloadFolder.own, withIntermediateDirectories: true)
                self.downloadFolderClosed(folder)
            }
            self.writeDownload(download, response: response, name: name, from: host,
                               in: open ? folder : DownloadFolder.own, completionHandler)
        }
    }

    /// The download handed to WebKit, into `folder`.
    private func writeDownload(
        _ download: any PageDownload,
        response: URLResponse,
        name: String,
        from host: String,
        in folder: URL,
        _ completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        guard downloadReplies[ObjectIdentifier(download)]?.pending == true else { return }
        let destinationFolder: URL
        do {
            destinationFolder = try download.isExtensionDownload
                ? DownloadRequest.extensionFolder(for: name, in: folder) : folder
        } catch {
            completionHandler(nil)
            self.download(download, didFailWithError: error, resumeData: nil)
            return
        }
        let url = DownloadDestinations.reserve(name, in: destinationFolder, for: download.downloadID)
        if !download.isExtensionDownload {
            tidyDownloadFiles.insert(ObjectIdentifier(download))
            DownloadNames.warm(url.lastPathComponent, browser: self)
        }
        prepareDownload(download, response: response, destination: url, from: host, completionHandler)
    }

    static var downloadPartsFolder: URL { Store.folder.appendingPathComponent("DownloadParts", isDirectory: true) }

    /// At launch, before a window can start a download: what a killed Yab
    /// left. A quit clears its own (`discardUnfinishedDownloads`).
    static func clearLeftoverDownloads() {
        let leftovers = DownloadFile.leftovers(in: downloadPartsFolder)
        guard !leftovers.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { DownloadFile.clear(leftovers) }
    }

    private func prepareDownload(_ download: any PageDownload, response: URLResponse, destination: URL,
                                 from host: String, agent: String? = nil, replacesExisting: Bool = false,
                                 _ completionHandler: @escaping @MainActor (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        guard downloadReplies[id]?.pending == true else { return }
        do {
            // An agent's file goes into its task's folder, not one anyone watches.
            let part = try DownloadFile(destination: destination, root: Self.downloadPartsFolder, showsPartial: agent == nil,
                                        replacesExisting: replacesExisting)
            downloadParts[id] = part
            downloadFiles[id] = destination
            download.webKitNamed(file: destination, response: response)
            hoard.begin(download, name: destination.lastPathComponent, from: host)
            if let agent { AgentFiles.shared.began(download, at: destination, for: agent) }
            if let partial = part.partial {
                partial.follow(download.progress)
                DispatchQueue.global(qos: .userInitiated).async { partial.place() }
            }
            // Install all state before an engine is allowed to write or finish.
            completionHandler(part.staging)
        } catch {
            completionHandler(nil)
            self.download(download, didFailWithError: error, resumeData: nil)
        }
    }

    /// The folder downloads go to is closed to Yab: said once a folder
    /// while Yab runs, with the switch's place. The file itself is in the
    /// stack, in Yab's own folder.
    func downloadFolderClosed(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard !closedDownloadFolders.contains(path) else { return }
        closedDownloadFolders.insert(path)
        let name = DownloadFolder.name(folder)
        guard ClosedPlace.of(path) != nil else {
            // Not macOS's switch: the folder's own permissions, or a disk.
            toaster.pop("Can't save in \(name)", mark: "exclamationmark.triangle")
            return
        }
        toaster.pop("macOS keeps \(name) closed to Yab", mark: "exclamationmark.triangle",
                    undo: { DownloadFolder.openSettings() }, act: "Open Settings")
    }

    /// A page that never showed anything, opened by another page only for
    /// the file it turned into: a receipt mail's "Download receipt" (a new
    /// tab, or a peek from a pinned Gmail), a site's window.open of an
    /// invoice. Left, it was a blank tab or an empty peek over the page,
    /// the file going quietly to the stack, and the download looked as if
    /// it hadn't worked (a tester's Stripe invoices, 2026-10-12). Closed, as
    /// Chrome and Safari close it, and you are back where you clicked.
    /// A tab of yours you typed the address into stays.
    func closeIfOnlyFetched(_ webView: any PageHandle, fetching: [URL?] = []) {
        guard webView.webKitOnlyFetched(fetching) else { return }
        if let page = peeking, page.builtPage === webView {
            closePeek()
            return
        }
        if webView.webKitLinkWindow != nil {
            webView.webKitClose(in: self)
            return
        }
        guard let tab = tabs.first(where: { $0.builtPage === webView }), tab.opener != nil,
              tab.pin == nil, !tab.kept else { return }
        webView.webKitClose(in: self)
    }

    /// While its file comes, a peek that only fetched it is put away at
    /// once: its file goes on. A tab or a small window is left alone until
    /// the file is in: left behind as you go back, a tab that never showed
    /// a page was let go, and its download with it.
    private func stepAside(_ webView: any PageHandle, fetching: [URL?]) {
        guard webView.webKitOnlyFetched(fetching), let page = peeking, page.builtPage === webView else { return }
        closePeek()
    }

    /// The file in, or given up on: the page that only fetched it goes.
    private func fetched(_ download: any PageDownload) {
        let id = ObjectIdentifier(download)
        let fetching = downloadFetching.removeValue(forKey: id) ?? []
        guard let opened = downloadBecame.removeValue(forKey: id)?() else { return }
        closeIfOnlyFetched(opened, fetching: fetching)
    }

    func downloadDidFinish(_ download: any PageDownload) {
        guard !failedDownloadIDs.contains(download.downloadID), !completedDownloadIDs.contains(download.downloadID) else { return }
        if let part = downloadParts[ObjectIdentifier(download)] {
            guard publishingDownloads.insert(download.downloadID).inserted else { return }
            Task { [self] in
                defer { publishingDownloads.remove(download.downloadID) }
                do {
                    let picture = pictureDownloads.remove(download.downloadID) != nil
                    let file = try await Task.detached(priority: .utility) {
                        let file = try part.publish()
                        return picture ? PictureFile.portable(file: file) : file
                    }.value
                    guard !failedDownloadIDs.contains(download.downloadID) else { return }
                    try await download.didPublish(to: file)
                    guard !failedDownloadIDs.contains(download.downloadID) else { return }
                    downloadParts[ObjectIdentifier(download)] = nil
                    download.progress.fileURL = file
                    if picture { downloadFiles[ObjectIdentifier(download)] = file }
                    recordedDownload(download)
                } catch { self.download(download, didFailWithError: error, resumeData: nil) }
            }
            return
        }
        recordedDownload(download)
    }

    private func recordedDownload(_ download: any PageDownload) {
        guard completedDownloadIDs.insert(download.downloadID).inserted else { return }
        retryingDownloadIDs.remove(download.downloadID)
        downloadNames[ObjectIdentifier(download)] = nil
        DownloadDestinations.release(download.downloadID)
        downloading.removeAll { $0 === download }
        AgentFiles.shared.ended(download)
        defer { hoard.finish(download) }
        fetched(download)
        downloadFolders.removeValue(forKey: ObjectIdentifier(download))
        let mayTidy = tidyDownloadFiles.remove(ObjectIdentifier(download)) != nil
        let page = downloadPages.removeValue(forKey: ObjectIdentifier(download))
        let written = downloadFiles.removeValue(forKey: ObjectIdentifier(download))
        let file = written ?? download.progress.fileURL
        download.webKitFinished(file: file)
        guard let file else { return }
        let source = download.originalRequest?.url
        Browser.writeWhereFrom(file, [source, page?.url].compactMap { $0 })
        SiteDownloads.quarantine(file, from: source, page: page?.url)
        let keep = Keep(
            name: file.lastPathComponent,
            from: source?.host() ?? "",
            path: file.path,
            date: Date(),
            page: page?.url,
            pageTitle: page.flatMap { $0.title.isEmpty ? nil : $0.title },
            source: source
        )
        loot.add(keep)
        // Named by what it is, if it came in under a name nobody would give
        // it: only a file of yours that went straight to the Downloads
        // folder, not one you named in the panel or an agent's.
        if mayTidy {
            DownloadNames.tidy(keep, page: keep.pageTitle, browser: self)
        }
    }

    func download(
        _ download: any PageDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        guard !completedDownloadIDs.contains(download.downloadID), failedDownloadIDs.insert(download.downloadID).inserted else { return }
        DownloadFailureLog.note(error, destination: downloadFiles[ObjectIdentifier(download)],
                                staging: downloadParts[ObjectIdentifier(download)]?.staging)
        retryingDownloadIDs.remove(download.downloadID)
        downloadReplies.removeValue(forKey: ObjectIdentifier(download))?.answer(nil)
        downloading.removeAll { $0 === download }
        // Kept for Resume; discardPart removes it if the user lets it go.
        pictureDownloads.remove(download.downloadID)
        // With nothing to go on from, the piece is only a file that opens
        // broken: it goes now, and Try Again starts from the top under the
        // same name (row 1005). Its page and place stay for that.
        if resumeData == nil {
            if let part = downloadParts[ObjectIdentifier(download)] { part.discard() }
            else if let file = downloadFiles[ObjectIdentifier(download)] { try? FileManager.default.removeItem(at: file) }
        } else {
            downloadParts[ObjectIdentifier(download)]?.partial?.stop()
        }
        AgentFiles.shared.ended(download, error: error.localizedDescription)
        fetched(download)
        let canceled = (error as NSError).code == NSURLErrorCancelled
        download.webKitFailed(resumable: resumeData != nil, canceled: canceled)
        hoard.fail(download, resumeData: resumeData)
    }

    /// A failed download going on as a new one: its page and its file are
    /// the old one's.
    func resumed(_ download: any PageDownload, from old: ObjectIdentifier) {
        let id = ObjectIdentifier(download)
        retryingDownloadIDs.insert(download.downloadID)
        download.webKitCarried(from: old)
        if let page = downloadPages.removeValue(forKey: old) { downloadPages[id] = page }
        if let file = downloadFiles.removeValue(forKey: old) { downloadFiles[id] = file }
        if let part = downloadParts.removeValue(forKey: old) {
            downloadParts[id] = part
            part.partial?.follow(download.progress)
        }
        if let folder = downloadFolders.removeValue(forKey: old) { downloadFolders[id] = folder }
        if tidyDownloadFiles.remove(old) != nil { tidyDownloadFiles.insert(id) }
    }

    /// What a failed download wrote before it stopped, removed: a piece of
    /// a file, under the file's own name, that opens as a broken one.
    func discardPart(of id: ObjectIdentifier, keepingDestination: Bool = false) {
        downloadNames[id] = nil
        downloadReplies.removeValue(forKey: id)?.answer(nil)
        if !keepingDestination { downloadFolders.removeValue(forKey: id) }
        tidyDownloadFiles.remove(id)
        if !keepingDestination { downloadPages[id] = nil }
        guard let file = downloadFiles.removeValue(forKey: id) else { return }
        if let part = downloadParts.removeValue(forKey: id) { part.discard() }
        else { try? FileManager.default.removeItem(at: file) }
    }

    /// Quitting: nothing unfinished outlives Yab, resume data included, so
    /// every piece still under way or kept for Resume goes rather than
    /// staying behind in Downloads as a broken file.
    func discardUnfinishedDownloads() {
        for download in downloading {
            failedDownloadIDs.insert(download.downloadID)
            DownloadDestinations.release(download.downloadID)
            download.cancelDownload { _ in }
        }
        for id in Set(downloadFiles.keys).union(downloadFolders.keys) { discardPart(of: id) }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    static func free(_ name: String, in folder: URL) -> URL {
        let name = DownloadRequest.filename(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}

extension Browser {
    /// The band with the lights in or out (HeadBand). The page is carried
    /// down under it and back up whole, at the size it has (ContentView's
    /// `headSink`): made a row shorter, WebKit laid the whole page out again
    /// and what was on it shifted as it went. The page and its paper are
    /// slid there by Core Animation on the band's curve, and the window is
    /// laid out where they are once they have landed (Reshape.slide):
    /// nothing for the main thread or WebKit while anything moves. Out, the
    /// room first and then what is in it; in, the other way round.
    func moveHead(out: Bool) {
        guard out != headOut || out != headShown else { return }
        headMoves += 1
        let move = headMoves
        let pace: Reshape.Pace = out ? .arrive : .depart
        if !out { withAnimation(.easeOut(duration: 0.08)) { headShown = false } }
        DispatchQueue.main.asyncAfter(deadline: .now() + (out ? 1.0 / 60 : 0.08)) { [self] in
            guard headMoves == move else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { headOut = out }
            let peek = headPeek
            let down = headBand ? (out ? peek.sink : 0) - (peek.sunk ? peek.sink : 0) : 0
            Reshape.slide(in: BrowserWindows.shared.window(for: self), down: down, pace: pace) {
                withTransaction(still) { peek.sunk = out }
            }
            if out { withAnimation(.easeOut(duration: pace.duration).delay(0.04)) { headShown = true } }
        }
    }
}

extension Browser: PageEvents {
    func tab(owning page: any PageHandle) -> Tab? {
        tabs.first { $0.builtPage === page } ?? outside.first { $0.builtPage === page }
            ?? parkedTabs.first { $0.builtPage === page }
    }

    func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
        switch event {
        case .started(let navigation): pageStarted(page, navigation)
        case .redirected: pageRedirected(page)
        case .committed(let navigation):
            tab(owning: page)?.documentMetadataCommitted()
            pageCommitted(page, navigation)
        case .finished: pageFinished(page)
        case .failed(let navigation, let error, let provisional):
            if provisional { tab(owning: page)?.releaseQuiet(.failed) }
            if let tab = tab(owning: page), !tab.shy { FeedbackDiagnostics.shared.record(.navigationFailed, error: error) }
            if provisional { tab(owning: page)?.navigationFailedEarly(navigation) }
            fail(page, error)
        }
    }

    /// The engine waits for this reply, including the cookie grant's
    /// deferred answer. Metadata is a value, never an engine action object.
    func page(_ page: any PageHandle, decide action: PageAction,
              reply decisionHandler: @escaping @MainActor (PagePolicy) -> Void) {
        // A page whose name may point at this Mac (app.lvh.me, a .test
        // name): looked up first, at most half a second and once in a
        // while a name, so a local page has this Mac's rules, and no ad
        // blocker, from its first request (LocalNetwork.look, feedback #884).
        if action.targetIsMainFrame != false, let url = action.request.url,
           !LinkGap.cut("localnet"), LocalNetwork.needsLook(url) {
            LocalNetwork.look(url) { [weak self] in
                guard let self else { return decisionHandler(.cancel) }
                self.page(page, decide: action, reply: decisionHandler)
            }
            return
        }
        if let tab = tab(owning: page), let id = tab.agent, let session = Agents.shared.session(id), session.knowing {
            guard session.admission.valid, session.contextGrant?.acquisition == true,
                  let url = action.request.url, ContextConsent.webReadURL(url.absoluteString),
                  (action.request.httpMethod ?? "GET").uppercased() == "GET" else {
                decisionHandler(.cancel)
                return
            }
        }
        if action.targetIsMainFrame == true {
            OpenTrace.mark("policy.action")
            OpenTrace.watchBusy()
            // Back or Forward from the page itself (history.back(), a
            // swipe): the page's last frame up at once (BACK_STILLS).
            if action.kind == .backForward, let tab = tab(owning: page) {
                coverHistory(tab, to: action.request.url)
            }
            // A step through the history, watched to its commit (Tab.stepPatience).
            if let tab = tab(owning: page), tab.builtPage === page {
                tab.historyStep(to: action.kind == .backForward ? action.request.url : nil)
            }
        }
        if LinkGap.cut("policy"), action.targetIsMainFrame == true, action.kind == .linkActivated,
           action.modifierFlags.isEmpty {
            decisionHandler(.allow)
            return
        }
        // A spare's warmed scripts go nowhere (ContentWarm.holds).
        if page.webKitPolicyHeld {
            decisionHandler(.cancel)
            return
        }
        // "Download Image", "Download Linked File" from the page's own
        // context menu, and a link with the `download` attribute all arrive
        // as an ordinary-looking action with this one flag set. Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page, nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the download that the engine transition already knows
        // what to do with.
        DebugLog.note("navigation-action", ["url": String(action.request.url?.absoluteString.prefix(120) ?? ""),
                                            "download": action.shouldPerformDownload,
                                            "main": action.targetIsMainFrame ?? false,
                                            "type": action.kind.rawValue])
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if action.targetIsMainFrame == true, Self.extensionFragment(url, on: page.url) {
            decisionHandler(.allow)
            return
        }
        // A host on the local phishing list (Settings › Privacy, opt-in) is
        // stopped for a word from you, in the tab, once a session; going on
        // loads it again with the site excused. Off by default, and no
        // list or no feed fails open.
        if action.targetIsMainFrame == true, ["http", "https"].contains(scheme),
           action.kind != .backForward, let tab = tab(owning: page),
           let flagged = SafeBrowsing.flag(url) {
            decisionHandler(.cancel)
            tab.flagged = flagged
            return
        }
        // A page's own host under an extension's PAC script (ExtensionProxy);
        // nothing without one.
        if action.targetIsMainFrame != false { ExtensionProxy.consider(url) }
        // Slack told Chrome, for its huddles (SiteAgent); everyone else Yab's
        // own agent again. A changed agent asks the load again, so the
        // request itself says it too, not only the page's navigator.
        // A window.open window keeps its load: loaded again by Yab, a
        // cross-site load swaps its process and cuts window.opener, and a
        // sign-in coming back has no one to answer (Superhuman's Google
        // sign-in landed on /~new?oauthsuccess=true, feedback #1273). The
        // agent still changes, for what the next page reads.
        if action.targetIsMainFrame == true, scheme == "https" || scheme == "http",
           page.webKitApplySiteAgent(for: url), tab(owning: page)?.scripted == nil,
           (action.request.httpMethod ?? "GET") == "GET", action.kind != .backForward {
            decisionHandler(.cancel)
            page.navigate(to: action.request)
            return
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: page) {
            decisionHandler(.cancel)
            return
        }

        // A userscript, opened: read by Yab and offered on a Keep card over
        // the page the tab is on, never shown as text (docs/userscripts.md).
        if action.targetIsMainFrame == true, action.request.httpMethod ?? "GET" == "GET",
           let script = Userscripts.shared.takes(url), let tab = tab(owning: page) {
            decisionHandler(.cancel)
            Userscripts.shared.offer(script, in: tab, browser: self)
            return
        }

        // A web page sending its tab to an extension's own page, by a link,
        // a script or a server's redirect (Nord Account after a sign-in,
        // app.html?verify_token=): a view built for the web can't serve
        // chrome-extension://, and the tab came up blank or "couldn't load".
        // One place for every way in: the tab is built for the extension and
        // goes there, as a typed address is. An extension's own page going
        // to another of its pages is served as it is. Chromium serves them in
        // any page: replacing one there only asked the same question of a new
        // page, for ever.
        if action.targetIsMainFrame == true, page.engine == .webKit, let target = Self.extensionHost(of: url),
           target != page.url.flatMap(Self.extensionHost(of:)),
           let source = tab(owning: page), source.builtPage === page, tabs.contains(where: { $0 === source }) {
            decisionHandler(.cancel)
            replaceBlank(source, with: url)
            return
        }

        // Out of an agent's published page (ArtifactPages) to a site: never
        // in the copy's view, which has no cookies. A tab of the row is
        // built for the site and goes there, as for an extension's page; from
        // a Peek, the site opens in a tab of its own, with the space's
        // sign-ins, and the copy stays where it is.
        if action.targetIsMainFrame == true, page.webKitIsArtifact,
           ["http", "https", "file"].contains(scheme), action.kind != .backForward {
            decisionHandler(.cancel)
            let source = tab(owning: page)
            if let source, source.builtPage === page, tabs.contains(where: { $0 === source }) {
                replaceBlank(source, with: url)
            } else {
                _ = open(url, foreground: true, from: source)
            }
            return
        }

        // An assistant's tab keeps to its sites whatever takes it on: a link,
        // a server's redirect, a script, back. Its `open` was checked before.
        if action.targetIsMainFrame == true, ["http", "https"].contains(scheme),
           let source = tab(owning: page), source.agent != nil,
           Assistants.shared.refusal(tab: source.agent, url: url) != nil {
            decisionHandler(.cancel)
            return
        }

        // Extension pages need a different WebKit configuration from web
        // pages. Script navigation (NordPass's OAuth window.open _self)
        // must use the same view replacement as typing a new address.
        if action.targetIsMainFrame == true, page.engine == .webKit,
           ["http", "https", "chrome-extension", "webkit-extension"].contains(scheme),
           let here = page.url, let source = tab(owning: page),
           source.builtPage === page, tabs.contains(where: { $0 === source }), source.onCross != nil,
           Self.extensionHost(of: here) != Self.extensionHost(of: url) {
            decisionHandler(.cancel)
            source.go(to: url)
            return
        }

        // Gmail names an account by its place, /mail/u/1/, and answers one
        // named by its address, /mail/u/name@site/, with "Temporary Error
        // (404)", Try Again only loading it again. Agents write that form,
        // so it goes as ?authuser=, which Gmail turns into the place itself,
        // the thread after # kept.
        if action.targetIsMainFrame != false, let fixed = Self.gmailByPlace(url),
           let tab = tab(owning: page) {
            decisionHandler(.cancel)
            tab.go(to: fixed)
            return
        }

        // Mail lives in its own space: a yab://mail address anywhere else,
        // typed, a new tab's row, the mail pin, goes there (MailSpace). A
        // tab that had nothing in it yet goes with it. One loading behind,
        // the pin being put, loads nothing and takes you nowhere.
        if MailPage.isMail(url), !inMail, action.targetIsMainFrame != false,
           let source = tab(owning: page), !source.bench {
            decisionHandler(.cancel)
            routeMailNavigation(url, from: source)
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it. Middle-click does what ⌘-click does, for hands
        // that learned it that way, ⇧ with it taking you there.
        // ⌥-click opens it in Split View beside.
        if action.kind == .linkActivated,
           ["http", "https"].contains(scheme) {
            let flags = action.modifierFlags.intersection([.command, .shift, .option, .control])
            let middle = Self.middleClick(action.buttonNumber)
            // ⇧-click previews from any tab. A plain click from a pin or a
            // kept tab (Arc's Favorites and its ⌘D Pinned Tabs, register
            // #426) previews another site, a target=_blank link too, while
            // links within its site stay there, as in Arc.
            // An agent's, a small window's or the peek's own page follows
            // the link as a click.
            if let source = tab(owning: page), !source.bench,
               tabs.contains(where: { $0 === source }),
               Self.shouldPeek(url, from: source.address ?? page.url, pinned: source.pin != nil || source.kept,
                               flags: flags, button: action.buttonNumber, peekClick: PeekClick.read(in: Store.settings)) {
                peek(url, from: source)
                decisionHandler(.cancel)
                return
            }
            if flags == .option, !middle {
                splitLink(url, from: tab(owning: page))
                decisionHandler(.cancel)
                return
            }
            if flags.contains(.command) || middle {
                // A site a rule keeps in another space opens there (LinkRoutes).
                let source = tab(owning: page)
                if !routePageLink(url, from: source, foreground: flags.contains(.shift)) {
                    openBeside(url, from: source, foreground: flags.contains(.shift))
                }
                decisionHandler(.cancel)
                return
            }
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetIsMainFrame ?? true, let tab = tab(owning: page) {
            // On the way to making something, by a maker's button or its
            // .new address: counted, never from a private tab.
            if !tab.shy, !tab.bench { QuickActions.shared.noticed(url) }
            let host = curtain.host(of: url)
            tab.skipsAds = Shield.shared.skips(on: host)
            tab.arm(hiding: curtain.css(on: host), on: host, to: url)
            // And the blocker, on or off for where it is going.
            if !LinkGap.cut("shield") { page.webKitTuneShield(for: host, watching: !tab.shy) }
        }

        // A task's answer page, kept in a tab from before answers moved to
        // the chat: the tab goes, and the task's chat comes out.
        if action.targetIsMainFrame ?? true, let id = TaskAnswer.oldPage(url), let tab = tab(owning: page) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                close(tab)
                if Agents.shared.session(id) != nil { showChat(id) }
            }
            return
        }

        // chrome-extension: an extension's own pages, options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ChromePages.needsChromium(url) || ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension", DiaryPage.scheme, ArtifactPages.scheme].contains(scheme) {
            // yab:// pages' handlers, there only on the way to one of them.
            if action.targetIsMainFrame ?? true {
                page.webKitFitDiary(to: url)
                // The window hears of it once its response is answered.
                if action.targetIsMainFrame == true, !Self.sameDocument(url, page.url),
                   let tab = tab(owning: page), tab.builtPage === page {
                    if url != tab.address { tab.prepareDocumentMetadata(for: url) }
                    tab.quietUntilAnswered()
                }
            }
            // A claude.ai artifact's frame keeps the cookie it is given (FrameGrants).
            if FrameGrants.wants(url, mainFrame: action.targetIsMainFrame ?? true) {
                page.webKitSeedFrameGrant(url) { decisionHandler($0 ? .allow : .cancel) }
                return
            }
            decisionHandler(.allow)
        } else {
            // Another app's link: asked about in the tab's pill first. The
            // page itself may ask, by its address or by a hidden frame of
            // its own (Slack's "Redirecting..." page, feedback #143/#144),
            // and so may a click inside any of its frames; a frame from
            // another site that asks on its own, an advertisement, is
            // ignored.
            decisionHandler(.cancel)
            let clicked = action.kind == .linkActivated
            // Our site's dress-up block, worn here and never another app's.
            if Dress.take(url, from: page, page: page.url,
                          clicked: clicked && action.source?.isMainFrame != false, in: self) { return }
            // Chrome's own pages Yab has a place for, chrome://extensions,
            // chrome://extensions/shortcuts, chrome://settings: that place,
            // the page staying where it is (ChromePages). The rest go on
            // as before.
            if action.targetIsMainFrame ?? true || clicked,
               let place = ChromePages.place(of: url, opener: ChromePages.opener(of: page.url)), place != .newTab {
                ChromePages.open(place, in: self, from: url)
                return
            }
            if action.targetIsMainFrame ?? true || clicked
                || Self.pageAsks(action.source, page: page.url, gesture: action.userInitiated) {
                openElsewhere(url, from: page, clicked: clicked)
            }
        }
    }


    /// Anything the window can't show is something to keep instead.
    func page(_ page: any PageHandle, decide response: PageDocumentResponse,
              reply decisionHandler: @escaping @MainActor (PagePolicy) -> Void) {
        if response.isMainFrame { OpenTrace.mark("policy.response") }
        if LinkGap.cut("policy"), response.canShowMIMEType {
            decisionHandler(.allow)
            return
        }
        page.webKit?.rememberApplicationResponse(response.response)
        // The main document's status and headers, for the JSON door's card.
        if response.isMainFrame, let tab = tab(owning: page),
           let heard = PageResponse(response.response, since: tab.askedAt) {
            tab.heard(heard)
        }
        // A PDF, for Fill & Sign's plate (PDFDesk.swift).
        let pdf = response.isMainFrame && tab(owning: page)?.paper.heard(response.response) == true
        let policy = PageResponsePolicy.decide(response.response, canShowMIMEType: response.canShowMIMEType)
        if pdf, policy == .allow, let web = page.webKit { sizeUnseenPDF(web) }
        DebugLog.note("navigation-response", ["host": response.response.url?.host ?? "",
                                              "status": (response.response as? HTTPURLResponse)?.statusCode ?? 0,
                                              "mime": response.response.mimeType ?? "",
                                              "main": response.isMainFrame,
                                              "canShow": response.canShowMIMEType,
                                              "download": policy == .download])
        // A step through the history loading its page again: that page's
        // process told before the answer (Tab.stepPatience).
        if response.isMainFrame, policy == .allow, let tab = tab(owning: page), tab.builtPage === page {
            tab.historyStepAnswered()
        }
        decisionHandler(policy)
        // Answered: what the window was kept from hearing (QUIET_START).
        if response.isMainFrame { tab(owning: page)?.releaseQuiet(.answered) }
    }

    /// A PDF about to load behind, its view in no window and of no size (a
    /// link opened in a new tab): WebKit's viewer fits the pages to the
    /// view as it first lays the document out, drew them at a tenth of
    /// their size there, and kept them so once the tab came to the front,
    /// a white page with a sliver of paper in its middle (feedback #954,
    /// evals/pdf/blank.py). Laid out at the size it will be shown at.
    private func sizeUnseenPDF(_ web: PageView) {
        guard web.window == nil, web.frame.width < 100 || web.frame.height < 100 else { return }
        let front = active?.builtPage.flatMap { $0.window != nil ? $0.frame.size : nil }
        guard let size = front ?? BrowserWindows.shared.window(for: self)?.contentView?.bounds.size,
              size.width >= 100, size.height >= 100 else { return }
        web.setFrameSize(size)
    }

    private func pageStarted(_ page: any PageHandle, _ navigation: PageNavigation?) {
        page.webKit?.clearMenuOpen()
        OpenTrace.mark("provisional \(page.webKit.map(OpenTrace.process) ?? "")")
        OpenTrace.turns("provisional")
        loadFrom[ObjectIdentifier(page)] = page.url
        if LinkGap.cut("window") { return }
        if !LinkGap.cut("started") { _ = OpenTrace.time("provisional.tab") { tab(owning: page)?.navigationStarted(navigation) } }
    }

    /// A server answering with an extension's own page, Nord Account's
    /// sign-in callback answering 302 chrome-extension://<NordPass>/app.html:
    /// the web page's view can't load it and ends with -1008, no address
    /// given. The tab is built for the extension and goes there, as a typed
    /// address does.
    private func pageRedirected(_ page: any PageHandle) {
        guard let url = page.url, let target = Self.extensionHost(of: url),
              target != loadFrom[ObjectIdentifier(page)].flatMap(Self.extensionHost(of:)),
              let tab = tab(owning: page), tab.builtPage === page, tabs.contains(where: { $0 === tab }) else { return }
        page.stopLoading()
        replaceBlank(tab, with: url)
    }

    private func pageCommitted(_ page: any PageHandle, _ navigation: PageNavigation?) {
        OpenTrace.mark("commit \(page.webKit.map(OpenTrace.process) ?? "")")
        // A page from the back-forward cache commits with no response asked.
        tab(owning: page)?.releaseQuiet(.committed)
        loadFrom[ObjectIdentifier(page)] = nil
        if LinkGap.cut("window") || LinkGap.cut("commitwork") { return }
        SiteDownloads.committed(page)
        guard let tab = tab(owning: page) else { return }
        LinkStatus.shared.forget(tab.id)
        linkCard.forget(tab)
        // A new document starts with no questions asked, and may ask again.
        tab.pageDialogs = 0
        tab.hushed = nil
        // The site a window a script opened shows first: where its sign-in is.
        if tab.scripted != nil, tab.firstSite == nil, let host = page.url?.host(), !host.isEmpty {
            tab.firstSite = Browser.site(host)
        }
        tab.httpNavigation.clearFallback()
        if page.engine == .chromium {
            tab.applyRememberedZoom()
            // CEF has canceled the previous document's native callbacks,
            // including when this document has the same origin.
            dropAsks(tab)
            windowsLeft(tab)
            tab.untrusted = nil
            tab.typing = false
            // Page scripts share their document lifecycle with WebKit.
            chromiumScriptsCommitted(tab)
            // TODO(chromium): migrate the WebKit-only commit side effects below.
            tab.failure = nil
            tab.releaseNavigation()
            tab.uncover()
            return
        }
        tab.navigationCommitted(navigation, behind: tab.id != activeID)
        // Another site's page came up: its questions go (asksMoved).
        if let url = page.url { asksMoved(tab, to: url, committed: true) }
        tab.paper.committed(page.url)
        noticeCommit(tab, at: page.url)
        // A page of a site muted in its space comes in muted.
        if !tab.muted, siteMuted(tab, at: page.url) { tab.mute(true) }
        windowsLeft(tab)
        Unbreak.shared.committed(tab, at: page.url)
        // A new document holds nothing typed yet, and no box a list hangs
        // from: a challenge page (Cloudflare's) at the same address too.
        tab.draft = false
        ChatBusy.left(tab)
        walletPageLeft(tab)
        pageTranslation.navigationCommitted(tab)
        // A search's first page searched again (Research.swift).
        if tab.nest?.research == true { searched(tab) }
        // The page out in the little window went somewhere else, the next
        // episode, a link in the player. The new document knows nothing of
        // being floated, and would be shown whole at the size of a stamp.
        // A call's page that went elsewhere has left the call: home.
        if floating == tab.id { floater.kind == .call ? land() : picturing == nil ? floater.cover(true) : () }
        tab.failure = nil
        tab.untrusted = nil
        tab.flagged = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
        if let web = page.webKit { (page.superview as? StageView)?.documentCommitted(web) }
        // A tab waking from sleep: the new document is in, and a moment
        // after it is on screen the picture of the old one can go.
        tab.uncover(after: 0.45)
        // What the navigation changed for the window, after the page's
        // next frame (Tab.held).
        tab.releaseAfterFrame()
    }

    private func pageFinished(_ page: any PageHandle) {
        if LinkGap.cut("window") || LinkGap.cut("finishwork") { return }
        OpenTrace.mark("finish")
        // Held with the rest of the navigation's changes (Tab.held): its
        // colors, icon, history and session after the page's first frame.
        if let tab = tab(owning: page), tab.holdingNavigation {
            tab.held { [weak self, weak page] in
                guard let self, let page else { return }
                self.finished(page)
            }
            return
        }
        finished(page)
    }

    private func finished(_ page: any PageHandle) {
        guard let tab = tab(owning: page), let url = tab.address else { return }
        Startup.mark("page")
        if page.engine == .chromium {
            chromiumScriptsFinished(tab)
            tab.releaseNavigation()
            tab.uncover()
            tab.returnToPlace()
            if !tab.shy && !tab.bench { history(for: tab).record(url, title: tab.title, space: visitSpace(tab)) }
            return
        }
        if floating == tab.id, floater.kind == .video, picturing == nil { refloat(tab) }
        tab.uncover()
        tab.returnToPlace()
        tab.retone()
        tab.retoneAsItSettles()
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        Boosts.shared.navigated(tab)
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        // A form that asks in words: Claude Code starts now, for its drafts.
        warmDrafts(tab)
        // A PDF: whether it has a form, for Fill & Sign's plate.
        tab.paper.finished(tab)
        guard !tab.shy, !tab.bench else { return }
        // With ⌘-click folders on: Haiku started now for the next one's name.
        LinkFolders.warm(tab, in: self)
        // A manager Yab unlocks, its own unlock page in a tab: unlocked there.
        ManagerKeep.inPlacePage(tab.page, url: url)
        AssistantAuthorizationPage.arrived(tab, in: self)
        // A server on this Mac never asked about: Developer Mode, offered.
        offerDevMode(tab)
        // Counted already while it loaded (noticeCommit): only its title now.
        if DiaryPage.counted[tab.id] == url { history(for: tab).retitle(url, title: tab.title) } else { history(for: tab).record(url, title: tab.title, space: visitSpace(tab)) }
        // What was asked of a site the field searches, and whether a site
        // it doesn't yet says how it is searched.
        Scopes.landed(on: url)
        Scopes.learn(from: tab)
        remember(tab, at: url)
    }

    @discardableResult
    func retryHTTP(_ tab: Tab, failed: URL, code: Int) -> Bool {
        guard WWWRetry.key(tab.address ?? failed) == WWWRetry.key(failed),
              let http = tab.httpNavigation.claim(failed, code: code) else { return false }
        tab.untrusted = nil
        tab.go(to: http)
        return true
    }

    private func fail(_ page: any PageHandle, _ error: Error) {
        if page.engine == .chromium, let tab = tab(owning: page) { dropAsks(tab) }
        (page.superview as? StageView)?.uncoverHistory()
        tab(owning: page)?.releaseNavigation()
        tab(owning: page)?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        loadFrom[ObjectIdentifier(page)] = nil
        // Canceled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked, clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        // Nor is a video opened as the page itself: WebKit hands it to its
        // player and ends the document's load with "plug-in handled load"
        // (204) while the video plays on. Answered as a failure, ChatGPT's
        // Download (window.open of the video's blob:) came up as "The page
        // couldn't load" over the video (Danny, 2026-10-13).
        guard !(nsError.domain == "WebKitErrorDomain" && code == 204) else {
            // A PDF that ended so is shown all the same: Fill & Sign's plate.
            if let tab = tab(owning: page) { tab.paper.finished(tab) }
            return
        }
        guard let tab = tab(owning: page) else { return }
        LoadFailureLog.note(engine: page.engine, domain: nsError.domain, code: code,
                            host: (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host ?? page.url?.host,
                            name: nsError.userInfo["netErrorName"] as? String)
        tab.failure = PageLoadFailure.message(domain: nsError.domain, code: code)
        // An extension's sign-in in a tab of its own reaching its redirect:
        // the tab says that address, which the extension reads the code off.
        if let failed = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL, ExtensionAuth.ownTabRedirect(failed) {
            tab.stand(at: failed, failure: PageLoadFailure.message(domain: nsError.domain, code: code))
            return
        }
        if let failed = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
           nsError.domain == NSURLErrorDomain, retryHTTP(tab, failed: failed, code: code) { return }
        // An address typed in the field whose name finds nothing, or no
        // server: one look at it with www. put on or taken off (WWWRetry).
        if let failed = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
           let other = WWWRetry.claim(failed, code: code) {
            lookAtOtherName(tab, failed: failed, other: other)
            return
        }
        // A device on the network that answers only https (LocalHTTPS): one
        // look there, and the tab goes if something answers, unless it has
        // gone elsewhere meanwhile.
        guard let failed = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
              !tab.httpNavigation.keepsHTTP,
              let https = LocalHTTPS.candidate(for: failed, code: code) else { return }
        let showing = tab.address
        Task { @MainActor [weak tab] in
            guard await LocalHTTPS.answers(https), let tab, tab.failure != nil, tab.address == showing else { return }
            tab.go(to: https)
        }
    }

}
