import Foundation
import UIKit

/// The ways into Yab from outside it, until Yab may be the default browser:
/// another app's share sheet (Phone/Share), the Search and Ask widgets
/// (Phone/Activity), Shortcuts, Siri and Spotlight (YabIntents). The widgets
/// and the share sheet open Yab at yab://<route> (YabRoute), which comes in
/// as any link does (AppModel.openLink); Shortcuts call in directly. What
/// asks before Yab can act (launched for it, or still coming to the front)
/// waits here until it can.
@MainActor
enum Entrances {
    enum Request: Equatable {
        case route(YabRoute)
        /// A web page from Shortcuts: a new tab, as a link from another app.
        case open(URL)
        /// Words from Shortcuts: a search, or the address they spell, in a new tab.
        case search(String)
    }

    private static weak var app: AppModel?
    private static var queue: SharedLinkQueue?
    private static var waiting: [Request] = []
    private static var watch: NSObjectProtocol?

    /// Called once the app is made (SceneDelegate). Test runs read no queue
    /// of the person's: only the one a UI test names (YAB_SHARED_LINKS).
    static func attach(_ app: AppModel, options: LaunchOptions = .current,
                       environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.app = app
        queue = queue(options: options, environment: environment)
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { becameActive() }
        }
        if UIApplication.shared.applicationState == .active { becameActive() }
    }

    static func queue(options: LaunchOptions, environment: [String: String]) -> SharedLinkQueue? {
        if let folder = environment["YAB_SHARED_LINKS"], !folder.isEmpty {
            return SharedLinkQueue(folder: URL(fileURLWithPath: folder, isDirectory: true))
        }
        return options.isTestRun ? nil : .shared
    }

    /// Does what was asked now when Yab is in front, else once it is.
    static func perform(_ request: Request) {
        guard let app, UIApplication.shared.applicationState == .active else {
            waiting.append(request)
            return
        }
        run(request, in: app)
    }

    /// In front again: what waited, then what the share sheet left. A link
    /// kept or opened while Yab was away is taken here even without a tap.
    private static func becameActive() {
        guard let app else { return }
        let asked = waiting
        waiting = []
        for request in asked { run(request, in: app) }
        if !asked.contains(.route(.shared)) { takeShared(in: app) }
    }

    private static func run(_ request: Request, in app: AppModel) {
        switch request {
        case .route(.shared): takeShared(in: app)
        case .route(.newTab): app.enterNewTab(privately: false)
        case .route(.privateTab): app.enterNewTab(privately: true)
        case .route(.ask): app.enterAsk()
        case let .open(url): app.openLink(url)
        case let .search(words): app.enterSearch(words)
        }
    }

    static func resumeShared() {
        guard let app, UIApplication.shared.applicationState == .active else { return }
        takeShared(in: app)
    }

    private static func takeShared(in app: AppModel) {
        var local: [SharedLink] = []
        _ = queue?.take { link in
            if let imported = app.sync.importShared(link) { return imported }
            local.append(link)
            return true
        }
        if !local.isEmpty { app.takeShared(local) }
    }
}

extension AppModel {
    // MARK: - the share sheet

    /// Links the share sheet left, oldest first. Keep for Later's become kept
    /// tabs in the space last in front, saying so when nothing else shows it;
    /// the newest Open in Yab comes to the front, and any opened before it (Yab
    /// couldn't be opened for them) wait at the top of today's.
    func takeShared(_ links: [SharedLink]) {
        let space = browser.space.isPrivate ? browser.ordinarySpaceID : browser.spaceID
        let kept = links.filter { $0.action == .keep }.compactMap { link in
            sharedTab(link).flatMap { browser.file($0, as: .kept, in: space) }
        }
        let opens = links.filter { $0.action == .open }
        for link in opens.dropLast() {
            if let tab = sharedTab(link) { browser.file(tab, as: .today, in: space) }
        }
        if let last = opens.last, let page = sharedPage(last) {
            openLink(page)
        } else if let only = kept.first {
            say(kept.count == 1 ? "Kept for later: \(only.short)" : "Kept \(kept.count) links for later", glyph: .thumbtack)
        }
    }

    /// The page a shared link asks for: the link read as the field reads
    /// an address, or a search for its words with the engine chosen in Settings.
    func sharedPage(_ link: SharedLink) -> URL? {
        if link.search { return field.searchSettings.searchSelection.url(for: link.address) }
        return Links.page(address: link.address)
    }

    /// A shared link as the tab it becomes: a real page never borrows a
    /// fixture's names; its title as the sharing app said it until it loads.
    private func sharedTab(_ link: SharedLink) -> Tab? {
        guard let page = sharedPage(link) else { return nil }
        if fixturesEnabled { return PageFixtures.tab(for: page, in: world, fixturesEnabled: true) }
        return PageFixtures.liveTab(for: page, title: link.search ? nil : link.title)
    }

    // MARK: - the widgets and Shortcuts

    /// Search (yab://new) and New Private Tab: New Tab's field with the
    /// keyboard up, over the page in front. The Search widget opens an
    /// ordinary New Tab even with Private in front; a private one asks for
    /// Face ID first when Private is locked, as the menu's does.
    func enterNewTab(privately: Bool) {
        if !privately, browser.space.isPrivate { browser.showSpace(browser.ordinarySpaceID) }
        if surfaces.field == .newTab, field.isPrivate == privately { return }
        clearForEntrance { [weak self] in self?.openNewTab(privately: privately) }
    }

    /// Ask (yab://ask): a new chat, its field ready, about nothing yet.
    func enterAsk() {
        if browser.space.isPrivate { browser.showSpace(browser.ordinarySpaceID) }
        if surfaces.chat == .newChat { return }
        clearForEntrance { [weak self] in
            guard let self else { return }
            Motion.chatGrow.run { self.surfaces.openChat(.newChat) }
        }
    }

    /// Shortcuts' Search in Yab: the words searched in a new tab at the top
    /// of today's, or the address they spell opened, as New Tab's field does.
    func enterSearch(_ words: String) {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return enterNewTab(privately: false) }
        clearForEntrance { [weak self] in
            guard let self else { return }
            let tab: Tab = if let url = Words.address(text) {
                PageFixtures.tab(for: url, in: self.world, fixturesEnabled: self.fixturesEnabled)
            } else {
                PageFixtures.search(text, fixturesEnabled: self.fixturesEnabled, selection: self.field.searchSettings.searchSelection)
            }
            self.show(tab, newTab: true)
        }
    }

    /// Whatever stood over the page goes first: the
    /// action follows once it has, at once when nothing was up.
    private func clearForEntrance(then action: @escaping @MainActor () -> Void) {
        var closed = false
        if surfaces.menu != nil { surfaces.closeMenu() }
        if surfaces.settings { surfaces.closeSettings(); closed = true }
        if surfaces.join { surfaces.closeJoin(); closed = true }
        if surfaces.chat != nil { surfaces.closeChat(); closed = true }
        if surfaces.field != nil { surfaces.closeField(); closed = true }
        guard closed, !Motion.disabled else { return action() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.fieldClose.duration + 0.05) { action() }
    }
}
