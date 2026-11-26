import SwiftUI
import UIKit
import WebKit
import os

/// The page menu's own state: it grows out of the plate (≡), its address
/// row is the plate itself moved up; Site Settings and the certificate are
/// the same sheet with another body (one surface, contents
/// replaced). `surfaces.menu == .plate` mounts it; `shown` is where it is
/// going, so closing keeps it mounted until the row has landed on the plate.
@MainActor
@Observable
final class PageMenuModel {
    enum Page: Equatable, Sendable { case menu, site, certificate, downloads }

    var shown = false
    var page: Page = .menu
    /// The Downloads page: this site's files, reached one step deeper than
    /// Site Settings. nil: every file, reached from the menu or the Now line.
    var downloadsHost: String?
    /// The finger pulling the sheet down, in points.
    var drag: CGFloat = 0
    /// A page about to come in: its body is made out of sight for a turn,
    /// measured, and only then does the spring start.
    var preparing: Page?
    /// Copy Link pressed: each copy turns the link into a tick again.
    var copies = 0
    /// Open on Mac answered in its row.
    var openedOnMac = false
    /// Clear Data's question is up.
    var confirmClear = false
    /// Find on Page: the plate, Back and + step aside for iOS's find bar.
    var finding = false
    /// The sheet shrinking into its address row as that row becomes the
    /// field (a tap on the address): 0 the sheet, 1 the field.
    var toField: CGFloat = 0

    func reset() {
        shown = false
        page = .menu
        downloadsHost = nil
        drag = 0
        openedOnMac = false
        copies = 0
        preparing = nil
        confirmClear = false
        toField = 0
    }
}

extension Motion {
    /// ≡: the plate rises into the menu's address row while the sheet grows
    /// out of it (the prototype's 0.4 / 0.9).
    static let pageMenuOpen = spring("plateMenu", response: 0.4, damping: 0.9)
    /// Every way out (swiped down, a tap beside, an action): the row lands
    /// back into the plate, the open run backwards.
    static let pageMenuClose = spring("plateMenuClose", response: 0.32)
    /// Site Settings: the same sheet, its body replaced, one spring for the height.
    static let siteSettingsIn = spring("siteSettingsIn", response: 0.38)
    static let siteSettingsOut = spring("siteSettingsOut", response: 0.34)
    /// The Now line's tap: the plate's morph with Downloads already on it, a
    /// shorter way out of a line than ≡ (the prototype's ease-out cubic).
    static let downloadsFromNow = curve("downloadsFromNow", 0.33, 1, 0.68, 1, 0.25)
}

extension Haptics.Reason {
    static let pageMenu = "menu"
    static let readerHold = "reader hold"
    static let readerNone = "reader none"
    static let linkCopied = "link copied"
    static let desktopSite = "desktop site"
    static let siteSettings = "site settings"
    static let permissionForget = "permission forget"
    static let siteCleared = "site cleared"
    static let pageKept = "page kept"
    static let openedOnMac = "opened on mac"
    static let findOnPage = "find"
}

/// What the page menu's rows do. Each answers in place, in words or a
/// changed glyph: Copy Link's link turns into a tick, as on the Mac.
extension AppModel {
    private var menuLog: Logger { Logger(subsystem: "dev.serafim.fast.iphone", category: "field") }

    /// The host a tab's settings are kept under: the page's own in a real
    /// browser, the world's address in test worlds.
    func siteHost(of tab: Tab, url: URL? = nil) -> String {
        if !fixturesEnabled, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host() {
            return SiteSettings.key(host) ?? host
        }
        if !fixturesEnabled, let host = pages.liveView(tab.id)?.url?.host() { return SiteSettings.key(host) ?? host }
        return SiteSettings.key(tab.addressHost) ?? tab.addressHost
    }

    var pageIsPrivate: Bool { browser.space.isPrivate || browser.tab?.isPrivate == true }

    // MARK: - open and close

    func openPageMenu() {
        guard browser.tab != nil else { return }
        Haptics.play(.medium, reason: Haptics.Reason.pageMenu)
        if surfaces.menu == .plate {
            // Closing, caught again: back up from where it is.
            Motion.pageMenuOpen.run { pageMenu.shown = true; pageMenu.drag = 0 }
            return
        }
        pageMenu.reset()
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        // Mounted at the plate; the layer grows it as it appears (PageMenuLayer).
        withTransaction(quiet) { surfaces.openMenu(.plate) }
    }

    /// The row lands back into the plate, as the menu came out of it.
    func closePageMenu() {
        guard pageMenu.shown else { return }
        dropPageMenu()
    }

    /// After an action too: back into the plate, then `then` (what needs the
    /// plate where it is, Find's bar or Copy Link's toast).
    func dropPageMenu(then: (@MainActor () -> Void)? = nil) {
        guard surfaces.menu == .plate else { then?(); return }
        // Timed: the row has landed when the spring has, though the native
        // glass of ‹ and + coming back keeps the transaction going for a
        // second more, the menu's row standing in for the plate meanwhile.
        Motion.pageMenuClose.run(timed: true) {
            pageMenu.shown = false
            pageMenu.drag = 0
        } completion: { [weak self] in
            guard let self else { return }
            if !self.pageMenu.shown { self.unmountPageMenu() }
            then?()
        }
    }

    private func unmountPageMenu() {
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            if surfaces.menu == .plate { surfaces.closeMenu() }
            pageMenu.reset()
        }
    }

    // MARK: - the address row

    /// A tap on the address in the menu's row, or on Site Settings' title:
    /// the same field a tap on the plate opens, grown out of that row while
    /// the menu gives way under it.
    func pageMenuEditAddress(from row: CGRect) {
        guard browser.tab != nil, surfaces.menu == .plate, pageMenu.toField == 0 else { return }
        Haptics.play(.soft, reason: Haptics.Reason.settingsOpen)
        // The field grows out of the row while the sheet shrinks around it
        // to the same place: one object, the sheet's row becoming the field.
        surfaces.openField(.address, from: row, keepingMenu: true)
        Motion.pageMenuToField.run {
            pageMenu.toField = 1
        } completion: { [weak self] in
            guard let self, self.pageMenu.toField == 1 else { return }
            self.unmountPageMenu()
        }
    }

    func pageMenuBack() {
        guard let tab = browser.tab, currentPageState.canGoBack else { return }
        Haptics.play(.soft, reason: Haptics.Reason.reload)
        Task { @MainActor in _ = await pages.back(tab.id) }
    }

    func pageMenuForward() {
        guard let tab = browser.tab, currentPageState.canGoForward else { return }
        Haptics.play(.soft, reason: Haptics.Reason.reload)
        _ = pages.goForward(tab.id)
    }

    /// 🔗: as the Mac's link, it turns into a tick where it is; the menu
    /// stays, and nothing else needs saying.
    func pageMenuCopyLink() {
        guard let tab = browser.tab else { return }
        Haptics.play(.soft, reason: Haptics.Reason.linkCopied)
        UIPasteboard.general.url = link(of: tab)
        pageMenu.copies += 1
    }

    // MARK: - tiles

    /// Ask: a new chat about the page in front, grown out of the plate, its
    /// first words carrying the page.
    func pageMenuAsk() {
        guard let tab = browser.tab, !tab.isPrivate, hasMac else { return }
        let plate = ChromeGeometry(size: screenSize, folded: false, hasNow: nowItem != nil).plate
        unmountPageMenu()
        Motion.chatGrow.run { surfaces.openChat(.newChat, from: plate, about: tab) }
    }

    func pageMenuFind() {
        guard let tab = browser.tab, !currentPageState.isLoading else { return }
        Haptics.play(.soft, reason: Haptics.Reason.findOnPage)
        dropPageMenu { [weak self] in self?.findOnPage(tab.id) }
    }

    /// The tab in front is kept (or pinned): Keep says Kept.
    var pageIsKept: Bool { browser.tab.map { $0.place != .today } ?? false }

    func pageMenuKeep() {
        guard let tab = browser.tab, !tab.isPrivate, tab.place != .pinned else { return }
        Haptics.play(.light, reason: Haptics.Reason.pageKept)
        if tab.place == .kept { browser.unkeep(tab.id) } else { browser.keep(tab.id) }
        profile?.capture(browser)
    }

    func pageMenuShare() {
        guard let tab = browser.tab else { return }
        dropPageMenu { [weak self] in self?.share(tab) }
    }

    // MARK: - the list

    func pageMenuReader() {
        guard let tab = browser.tab else { return }
        let state = currentPageState
        guard state.readerAvailable || state.readerEnabled else { return }
        dropPageMenu()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let changed = await self.pages.setReader(enabled: !state.readerEnabled, for: tab.id)
            if !changed, self.browser.tab?.id == tab.id { self.say("Reader unavailable", glyph: .bookSimple) }
        }
    }

    /// Themes & Settings: Books' card over the article being read.
    func pageMenuReaderLook() {
        dropPageMenu { ReaderCardModel.shared.open() }
    }

    /// Holding ≡: Reader at once, without the menu; a page
    /// without an article answers with a soft no.
    func holdPageLines() {
        guard let tab = browser.tab else { return }
        let state = currentPageState
        guard state.readerAvailable || state.readerEnabled else {
            Haptics.play(.soft, reason: Haptics.Reason.readerNone)
            return
        }
        Haptics.play(.soft, reason: Haptics.Reason.readerHold)
        Task { @MainActor [weak self] in
            _ = await self?.pages.setReader(enabled: !state.readerEnabled, for: tab.id)
        }
    }

    var pageZoom: Double {
        guard let tab = browser.tab else { return 1 }
        return siteSettings.zoom(siteHost(of: tab), isPrivate: pageIsPrivate)
    }

    /// − and +: a step, remembered for the site; the % itself goes back to 100 %.
    func pageMenuZoom(_ direction: Int) {
        guard let tab = browser.tab else { return }
        let host = siteHost(of: tab)
        let next: Double
        if direction == 0 {
            guard abs(pageZoom - 1) > 0.001 else { return }
            next = 1
            Haptics.play(.soft, reason: Haptics.Reason.zoomReset)
        } else {
            guard let step = SiteSettings.step(pageZoom, by: direction) else {
                Haptics.play(.soft, reason: Haptics.Reason.zoomLimit)
                return
            }
            next = step
            Haptics.play(.selection, reason: Haptics.Reason.zoomStep)
        }
        siteSettings.setZoom(next, for: host, isPrivate: pageIsPrivate)
        // Every live page of the site follows, as on the Mac.
        for other in browser.allTabs where pages.isLive(other.id) && siteHost(of: other) == host {
            pages.applyZoom(other.id)
        }
    }

    /// An iPad left to its own choice gets Safari's (.recommended): desktop
    /// at full width, mobile in a narrow pane. Then only the page can say
    /// which it is, and the switch reads it; any other choice says itself.
    var pageIsDesktop: Bool {
        guard let tab = browser.tab else { return false }
        let host = siteHost(of: tab)
        if siteSettings.contentMode(host, isPrivate: pageIsPrivate) == .recommended, let shown = currentPageState.desktop { return shown }
        return siteSettings.desktop(host, isPrivate: pageIsPrivate)
    }

    /// Request Desktop Site ↔ Mobile Site: remembered for the site, and the page again.
    func pageMenuDesktop() {
        guard let tab = browser.tab else { return }
        Haptics.play(.soft, reason: Haptics.Reason.desktopSite)
        siteSettings.setDesktop(!pageIsDesktop, for: siteHost(of: tab), isPrivate: pageIsPrivate)
        _ = pages.view(for: tab)
        pages.reload(tab.id)
    }

    /// Open on Mac answers in its row ("Opened on MacBook Pro").
    /// `mac`: one picked from the list two Macs or more bring; it stays the
    /// Mac new work goes to (MacPick).
    func pageMenuOpenOnMac(_ mac: SyncMac? = nil) {
        guard let tab = browser.tab, !tab.isPrivate, hasMac else { return }
        Haptics.play(.light, reason: Haptics.Reason.openedOnMac)
        menuLog.info("page menu: onMac")
        if let mac { sync.chosenMac = mac.id }
        if !isFixture { sync.openOnMac(tab, quietly: true, on: mac?.id) }
        withAnimation(Motion.fade) { pageMenu.openedOnMac = true }
    }

    /// A task is words too: the plate's field takes them and decides.
    func pageMenuTask() {
        let plate = ChromeGeometry(size: screenSize, folded: false, hasNow: nowItem != nil).plate
        unmountPageMenu()
        Motion.fieldOpen.run { surfaces.openField(.address, from: plate) }
    }

    // MARK: - Site Settings

    func openSiteSettings() {
        Haptics.play(.soft, reason: Haptics.Reason.siteSettings)
        bringIn(.site)
    }

    func openCertificate() {
        Haptics.play(.soft, reason: Haptics.Reason.siteSettings)
        bringIn(.certificate)
    }

    /// A finger down on Site Settings' row (or the connection's): its body
    /// is made out of sight while the finger is still there, so the lift
    /// only starts the move; a finger that slides away lets it go.
    func prepare(_ page: PageMenuModel.Page, _ pressed: Bool) {
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        if pressed {
            guard pageMenu.page != page else { return }
            withTransaction(quiet) { pageMenu.preparing = page }
            return
        }
        // Up: the tap's action comes in this same turn and takes it; only a
        // finger that slid away leaves it, and it goes a turn later.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pageMenu.preparing == page else { return }
            withTransaction(quiet) { self.pageMenu.preparing = nil }
        }
    }

    /// The body is made in this turn, out of sight, and the sheet springs to
    /// its measured height in the next: the frame that makes it is never
    /// one of the move's (Site Settings' stutter).
    func bringIn(_ page: PageMenuModel.Page) {
        // Made while the finger was down on its row: it springs at once.
        if pageMenu.preparing == page {
            Motion.siteSettingsIn.run { pageMenu.page = page }
            pageMenu.preparing = nil
            return
        }
        prepare(page, true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pageMenu.preparing == page else { return }
            Motion.siteSettingsIn.run { self.pageMenu.page = page }
            self.pageMenu.preparing = nil
        }
    }

    /// ‹ in the header: the way it came.
    func siteSettingsBack() {
        Haptics.play(.selection, reason: Haptics.Reason.sheetBack)
        Motion.siteSettingsOut.run {
            switch pageMenu.page {
            case .certificate: pageMenu.page = .site
            case .downloads: pageMenu.page = pageMenu.downloadsHost == nil ? .menu : .site
            default: pageMenu.page = .menu
            }
        }
    }

    func forgetPermission(_ kind: SiteSettings.Permission) {
        guard let tab = browser.tab else { return }
        Haptics.play(.soft, reason: Haptics.Reason.permissionForget)
        withAnimation(Motion.fade) { siteSettings.forget(kind, for: siteHost(of: tab), isPrivate: pageIsPrivate) }
    }

    func setPermission(_ kind: SiteSettings.Permission, _ decision: SiteSettings.Decision) {
        guard let tab = browser.tab else { return }
        Haptics.play(.selection, reason: Haptics.Reason.permission)
        siteSettings.setDecision(decision, kind, for: siteHost(of: tab), isPrivate: pageIsPrivate)
    }

    /// After the yes: the site's cookies and storage, and what was remembered.
    func clearSiteData() {
        guard let tab = browser.tab else { return }
        let host = siteHost(of: tab)
        siteSettings.clear(host, isPrivate: pageIsPrivate)
        Haptics.play(.success, reason: Haptics.Reason.siteCleared)
        Task { @MainActor [weak self] in await self?.pages.clearData(tab.id, host: host) }
    }

    /// Yab Settings ›: the app's own settings, not the site's.
    func pageMenuYabSettings() {
        unmountPageMenu()
        Motion.sheetGrow.run { surfaces.openSettings() }
    }
}
