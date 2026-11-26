import Foundation
import Observation
import WebKit
import os

/// Everything the app holds, made once per launch from a profile or a test world.
@MainActor
@Observable
final class AppModel {
    let world: World
    let fixturesEnabled: Bool
    var isFixture: Bool { fixturesEnabled }
    let profile: BrowserProfile?
    let localChatProfile: LocalChatProfile?
    let websiteDataStore: WKWebsiteDataStore
    let browser: BrowserStore
    let privateLock: PrivateLock
    let tasks: TaskStore
    let chats: ChatStore
    let surfaces = Surfaces()
    let chrome = ChromeState()
    let workspace: BrowserWorkspace
    let pages: WebPool
    /// Zoom, desktop mode and permissions per site (Page/SiteSettings).
    let siteSettings: SiteSettings
    /// The page menu over the plate and Site Settings in it (Chrome/PageMenu).
    let pageMenu = PageMenuModel()
    /// The Mac's Favorites, Quick Actions and meetings, for the field (Model/MacField).
    let macField = MacField()
    private(set) var websiteStoreRevision = 0
    /// Sync with the Mac (Sync/SyncBridge): off until attached at launch.
    let sync = SyncBridge(probe: SyncProbe.make())
    /// The field over the keyboard: words, drafts, the eyes (Field/).
    let field = FieldModel()
    let tabEdits = TabEdits()
    /// The one sheet of answers and chats (Chats/ChatSheet.swift).
    let chatSheet = ChatSheet()
    /// Projects of chats, from the Mac (Chats/ChatProjects.swift).
    let projects = ProjectStore()
    /// Pages been to, here and on the Mac (History/).
    let history = HistoryModel()
    /// The skeleton's check of its drawings (Testing/DesignSheet), over everything.
    var showsDesignSheet = false
    /// Tasks on the Mac: sending them, what the Mac says, the code and the yes (Tasks/).
    @ObservationIgnored lazy var taskDesk = TaskDesk(app: self)
    /// Browser actions share UIKit’s shake-to-undo responder route. Text editors
    /// keep their own UndoManager ahead of this one in the responder chain.
    @ObservationIgnored let actionUndo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    @ObservationIgnored lazy var tabClear = TabClearCoordinator(app: self)
    /// The system's panels a private page has open (Page/PagePanels).
    @ObservationIgnored let privatePanels = PrivatePanels()
    /// Going back: who opened which tab, the pull from the left edge, Undo
    /// after a close (Back/).
    @ObservationIgnored lazy var backStack = BackStack(app: self)
    /// Translate page: offered per tab, done in the page itself (Page/PageTranslation).
    @ObservationIgnored lazy var translation = PageTranslation(app: self)
    /// New Tab's microphone and QR code scanner (Field/VoiceSearch, Field/CodeScanner).
    @ObservationIgnored lazy var voice = VoiceSearch(app: self)
    @ObservationIgnored lazy var scanner = CodeScanner(app: self)
    @ObservationIgnored private var lastRecordedURL: [Tab.ID: String] = [:]
    #if DEBUG
    /// How many times the field's rows were made (tests). Each making walks
    /// every tab; a view asking for them once per row made an iPad with many
    /// tabs miss its launch (#546-#561). Not observed: a write here in a
    /// view's body would draw it again for ever.
    @ObservationIgnored var fieldRowsMade = 0
    #endif

    /// Unit tests that construct a world keep their local fixture pages.
    init(world: World, fixturesEnabled: Bool = true, profile: BrowserProfile? = nil,
         privateAuthentication: (any PrivateAuthenticating)? = nil,
         privateLockEnabled: (@MainActor () -> Bool)? = nil, downloads: DownloadStore? = nil) {
        self.world = world
        workspace = BrowserWorkspace(preferences: fixturesEnabled ? TabletLayoutPreferences() : SettingsStore.shared.tablet)
        self.fixturesEnabled = fixturesEnabled
        self.profile = fixturesEnabled ? nil : profile
        localChatProfile = fixturesEnabled ? nil : profile.map { LocalChatProfile(folder: $0.folder) }
        browser = BrowserStore(world: world, fixturesEnabled: fixturesEnabled)
        // Private tabs open without Face ID unless the lock is turned on.
        privateLock = PrivateLock(enabled: privateLockEnabled ?? { false },
                                  authentication: privateAuthentication ?? DevicePrivateAuthentication())
        tasks = TaskStore(world: world)
        chats = ChatStore(world: world, local: localChatProfile?.entries ?? [])
        if fixturesEnabled { websiteDataStore = WKWebsiteDataStore(forIdentifier: world.dataStoreID) }
        else if let id = profile?.dataStoreID { websiteDataStore = WKWebsiteDataStore(forIdentifier: id) }
        else { websiteDataStore = .nonPersistent() }
        pages = WebPool(dataStore: websiteDataStore, fixturesEnabled: fixturesEnabled,
                        downloads: downloads ?? (fixturesEnabled || UserDefaults.standard.string(forKey: "YabProfileDirectory") != nil ? .temporary() : .standard()))
        siteSettings = SiteSettings(defaults: fixturesEnabled ? nil : .standard)
        pages.siteSettings = siteSettings
        pages.spaceForTab = { [weak self] id in self?.browser.space(holding: id) }
        pages.websiteStoreID = { [weak self] space in self?.profile?.websiteStoreID(for: space) }
        pages.siteOf = { [weak self] id, url in
            guard let self, let tab = self.browser.tab(id) else { return (url?.host(), false) }
            return (self.siteHost(of: tab, url: url), tab.isPrivate || self.browser.space(holding: id)?.isPrivate == true)
        }
        pages.swipeHost = backStack
        attachDownloads()
        // The ad blocker's lists on each page (Page/Shield).
        attachShield()
        chatSheet.answerers.configureFixtures(fixturesEnabled)
        tasks.handoff = world.mac.handoff.flatMap { browser.tab($0) }
        browser.didInsertTab = { [weak self] tab, space in self?.tabClear.inserted(tab, in: space) }
        pages.onActivity = { [weak self] id in self?.tabClear.activity(id) }
        pages.onScroll = { [weak self] id, y in
            guard let self, id == self.browser.tab?.id else { return }
            self.chrome.scrolled(to: y)
        }
        pages.onScrollRebase = { [weak self] id, delta in
            guard let self, id == self.browser.tab?.id else { return }
            self.chrome.rebaseScroll(by: delta)
        }
        pages.onScrollSettle = { [weak self] id, y in
            guard let self, id == self.browser.tab?.id else { return }
            self.chrome.settleScroll(to: y)
        }
        pages.onState = { [weak self] id, state in
            self?.chrome.pageStates[id] = state
            self?.translation.pageChanged(id, state)
        }
        pages.onReport = { [weak self] id, report in
            self?.chrome.pageDark[id] = report.dark
        }
        pages.onCommit = { [weak self] id, url in
            guard let self else { return }
            if self.fixturesEnabled { self.pageCommitted(id, url) }
            else {
                self.lastRecordedURL.removeValue(forKey: id)
                // A committed link must survive eviction before Finish. Title
                // and visits still wait for the page's completed metadata.
                if var tab = self.browser.tab(id), tab.url != url.absoluteString {
                    tab.url = url.absoluteString
                    self.browser.replace(id, with: tab)
                    self.profile?.capture(self.browser)
                }
            }
            self.tabClear.activity(id)
        }
        pages.onMetadata = { [weak self] id, url, title in
            self?.pageMetadata(id, url: url, title: title)
        }
        pages.onFailure = { [weak self] id, url in self?.pageFailed(id, url: url) }
        pages.navigationForTab = { [weak self] id in self?.profile?.navigation[id] }
        pages.onNavigation = { [weak self] id, state in
            guard let self else { return }
            self.profile?.capture(self.browser)
            self.profile?.navigationChanged(id, state)
        }
        pages.onOpenWindowFrom = { [weak self] url, source, isPrivate in
            guard let self, let space = self.browser.space(holding: source),
                  space.isPrivate == isPrivate, !isPrivate || self.privateLock.mayReveal else { return nil }
            let tab = PageFixtures.tab(for: url, isPrivate: isPrivate, in: self.world, fixturesEnabled: self.fixturesEnabled)
            self.browser.open(tab, in: space.id, deduplicate: false)
            // Back at its first page returns to the page that opened it.
            self.backStack.opened(tab.id, by: source)
            self.profile?.capture(self.browser)
            return self.browser.tab(tab.id)
        }
        pages.onOpenLink = { [weak self] url, source, opening in self?.openHeldLink(url, from: source, as: opening) }
        pages.onCloseWindowFrom = { [weak self] id, source in
            guard let self, self.browser.tab(id) != nil else { return }
            // A background completion never takes focus from another page.
            if self.browser.tab?.id == id, self.backStack.opener(of: id) == source,
               !self.browser.space.isPrivate || self.privateLock.mayReveal {
                self.browser.select(source)
            }
            self.browser.close(id)
            self.reconcileWorkspace()
            self.profile?.capture(self.browser)
        }
        browser.mayEnterPrivate = { [weak self] in self?.privateLock.mayReveal ?? false }
        browser.requestPrivateEntry = { [weak self] action in self?.privateLock.request(action) }
        browser.didEnterPublic = { [weak self] in self?.privateLock.leavePrivate() }
        chats.mayRevealPrivate = { [weak self] in self?.browser.space.isPrivate == true && self?.privateLock.mayReveal == true }
        field.attach(self)
        history.attach(self)
        watchWebsiteStores()
        if self.profile != nil { watchProfile() }
        watchClearSelection()
        // Chrome extensions (Extensions/ExtensionHost), on real pages only.
        if !fixturesEnabled { ExtensionHost.shared.start(self) }
        // Every conversation retains its draft in memory, including Private.
        // Only a real local profile observes the separately filtered disk entries.
        chatSheet.onDraftChange = { [weak self] id, text in self?.chats.setDraft(text, in: id) }
        if localChatProfile != nil { watchLocalChats() }
    }

    private func watchClearSelection() {
        withObservationTracking {
            _ = browser.spaceID
            _ = browser.tab?.id
            _ = SettingsStore.shared.autoClearToday
            tabClear.selectionChanged()
            tabClear.scheduleAutomatic()
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchClearSelection() }
        }
    }

    /// Fixtures require an explicit world or named screenshot state.
    static func launch(_ options: LaunchOptions) -> AppModel {
        guard let name = options.fixtureWorld else {
            let profile = BrowserProfile.launch(options)
            let testing = PrivateLock.testingConfiguration(profileDirectory: options.profileDirectory)
            let enabled: (@MainActor () -> Bool)? = testing.enabled.map { value in { value } }
            let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile,
                               privateAuthentication: testing.authentication, privateLockEnabled: enabled)
            if let url = options.initialURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                app.browser.open(PageFixtures.liveTab(for: url))
            }
            return app
        }
        do {
            return AppModel(world: try World.load(named: name))
        } catch {
            Logger(subsystem: "dev.serafim.fast.iphone", category: "app").error("\(String(describing: error), privacy: .public)")
            let blank = Space(id: "empty", name: "Personal", emoji: "🏠", tint: RGB(238, 233, 226),
                              today: [Tab(id: "blank", title: "New Tab", site: "New Tab", icon: "globe", page: "blank")])
            // No world at all is a first launch: no Mac yet, the welcome asks.
            return AppModel(world: World(name: name, space: "empty", spaces: [blank], mac: World.Mac(joined: false)))
        }
    }

    /// Any private foreground surface replaces the whole root, including its AX.
    var privateContentBlocked: Bool { !privateLock.mayReveal && hasPrivateForeground }

    var hasPrivateForeground: Bool {
        if browser.space.isPrivate || browser.tab?.isPrivate == true || (field.shown && field.pageIsPrivate && field.mode != .newTab)
            || (chatSheet.shown && surfaces.chatPage?.isPrivate == true) { return true }
        if chatSheet.shown || chatSheet.flight != nil, let id = chatSheet.chatID,
           chats.isPrivate(id) || chatSheet.pageSources[id]?.isPrivate == true
            || chatSheet.pages[id].flatMap({ browser.tab($0) })?.isPrivate == true { return true }
        if surfaces.pageSwipe?.before?.isPrivate == true || surfaces.pageSwipe?.after?.isPrivate == true { return true }
        if case let .chat(id)? = surfaces.menu, chats.isPrivate(id) { return true }
        if let id = chatSheet.renaming, chats.isPrivate(id) { return true }
        return false
    }

    /// The chat's origin survives page selection and sync changes. A private
    /// conversation first enters its private space under the same permission.
    func enterPrivateChat(_ action: @escaping @MainActor () -> Void) {
        guard let id = browser.spaces.first(where: \.isPrivate)?.id else { return }
        privateLock.request { [weak self] in
            guard let self else { return }
            self.browser.showSpace(id)
            action()
        }
    }

    func leaveLockedPrivate() {
        privateLock.cancel()
        // Canceling entry returns to public without destroying private tabs.
        // Private drafts remain in memory, never in the returned public field.
        if field.shown && field.place.isPrivate { surfaces.closeField() }
        if chatSheet.shown || chatSheet.flight != nil, let id = chatSheet.chatID,
           chats.isPrivate(id) || surfaces.chatPage?.isPrivate == true || chatSheet.pageSources[id]?.isPrivate == true
            || chatSheet.pages[id].flatMap({ browser.tab($0) })?.isPrivate == true {
            chatSheet.focused = false
            surfaces.closeChat()
            chatSheet.shown = false
            chatSheet.flight = nil
        }
        if let id = chatSheet.renaming, chats.isPrivate(id) {
            chatSheet.renaming = nil
            chatSheet.renameText = ""
        }
        surfaces.closeMenu()
        surfaces.pageSwipe = nil
        browser.showSpace(browser.ordinarySpaceID)
    }

    private func pageMetadata(_ id: Tab.ID, url: URL, title: String) {
        guard !fixturesEnabled, let old = browser.tab(id) else { return }
        var tab = PageFixtures.liveTab(for: url, id: id, isPrivate: old.isPrivate, title: title)
        tab.onMac = old.onMac
        tab.dark = chrome.pageDark[id] ?? old.dark
        tab.place = old.place
        if tab != old { browser.replace(id, with: tab) }
        profile?.capture(browser)
        // A page loaded out of sight only for its card's picture (All Tabs'
        // warm-up, Tabs/TabWarmup) is no visit.
        guard !pages.isBorrowed(id) else { return }
        let countsVisit = lastRecordedURL[id] != url.absoluteString
        profile?.recordVisit(tab, countsVisit: countsVisit)
        history.recorded(tab)
        lastRecordedURL[id] = url.absoluteString
    }

    /// A page that couldn't open: the field and the tab stack say the address
    /// its error names (Safari's way), not the page the navigation left. A
    /// tab the field already loaded there keeps its own words. No visit.
    private func pageFailed(_ id: Tab.ID, url: URL) {
        guard !fixturesEnabled, let old = browser.tab(id), old.navigationURL.map({ PageHistory.key($0) }) != PageHistory.key(url) else { return }
        var tab = PageFixtures.liveTab(for: url, id: id, isPrivate: old.isPrivate)
        tab.onMac = old.onMac
        tab.place = old.place
        browser.replace(id, with: tab)
        chrome.pageDark[id] = nil
        lastRecordedURL.removeValue(forKey: id)
        profile?.capture(browser)
    }

    private func watchWebsiteStores() {
        withObservationTracking { _ = browser.spaces } onChange: { [weak self] in
            Task { @MainActor in self?.watchWebsiteStores() }
        }
        if pages.reconcileWebsiteStores(browser.allTabs) { websiteStoreRevision += 1 }
    }

    /// Sync observes this store too; profile saving never replaces its callback.
    private func watchProfile() {
        withObservationTracking {
            _ = browser.spaces
            _ = browser.spaceID
            // Shared pins with Personal gone live in sync alone.
            _ = sync.pinsStamp
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchProfile() }
        }
        profile?.capture(browser)
        let ids = Set(browser.allTabs.map(\.id))
        lastRecordedURL = lastRecordedURL.filter { ids.contains($0.key) }
        if !fixturesEnabled, websiteDataStore.isPersistent, !browser.space.isPrivate {
            let space = browser.space
            // The pins its page draws, shared ones included (Seyfullah, 0.1.39).
            let pins = sync.pins(in: space)
            Task {
                await SiteIcons.shared.restoreKept()
                await SiteIcons.shared.prefetch(space, shown: pins)
            }
        }
    }

    private func watchLocalChats() {
        withObservationTracking { _ = chats.localEntries } onChange: { [weak self] in
            Task { @MainActor in self?.watchLocalChats() }
        }
        localChatProfile?.capture(chats.localEntries)
    }

    func checkpointProfile() {
        if localChatProfile != nil { localChatProfile?.capture(chats.localEntries) }
        pages.checkpoint()
        profile?.capture(browser)
    }

    func flushProfile() async {
        checkpointProfile()
        await profile?.flush()
        await localChatProfile?.flush()
        await tabClear.flush()
    }

    // MARK: - what the chrome shows

    /// The Now line's item: nothing while the field has the plate's place.
    var nowItem: NowItem? {
        let live = isFixture ? nil : tasks.liveNow(in: sync.visibleLiveTasks(in: browser.spaceID))
        let item = live ?? NowLine.item(tasks: tasks, parked: chats.parkedItem)
        // A file says where it is, unless a task needs the person.
        if item?.kind != .warn, let file = downloads.nowItem(isPrivate: pageIsPrivate) { return file }
        return item
    }

    /// Named states only: the page in front says this instead (loading, a
    /// failure, history), so the page menu's states can be pictured.
    var pageStateOverride: WebPool.PageState?

    var currentPageState: WebPool.PageState {
        if let pageStateOverride { return pageStateOverride }
        guard let tab = browser.tab, pages.represents(tab) else { return .idle }
        return chrome.pageStates[tab.id] ?? .idle
    }

    /// The page in front is dark: the status bar turns light.
    var pageIsDark: Bool {
        guard let tab = browser.tab else { return false }
        if currentPageState.readerEnabled { return false }
        // A page that couldn't open shows the error pane, on the app's own
        // ground: not the colors of the page the navigation left.
        if currentPageState.failure != nil { return AppAppearance.current == .dark }
        return chrome.pageDark[tab.id] ?? (tab.dark || tab.isPrivate)
    }

    /// Pages lost their web views (Clear History): PageHost makes the one in
    /// front again.
    func pagesReleased() { websiteStoreRevision += 1 }

    /// The tab in front changed: the chrome unfolds for the new page.
    func tabChanged() {
        chrome.unfold()
    }
}
