import Foundation
import Observation
import UIKit
#if canImport(SyncKit)
import SyncKit
#endif

/// History as the app holds it: this iPhone's visits (the profile's, or a
/// named state's in memory), the places sync holds from the Mac's last two
/// weeks, and the Mac's bookmarks for the field. Private pages are never
/// here: the profile never records them and no Mac sends them.
@MainActor
@Observable
final class HistoryModel {
    @ObservationIgnored private weak var app: AppModel?
    /// Named states and tests without a profile: visits in memory only.
    var fixtureVisits: [BrowserVisit] = []
    private var fixtureForgetting = HistoryForgetting()
    /// The places sync holds, by key, and this iPhone's own id in sync.
    private(set) var synced: [String: SyncedPlace] = [:]
    private(set) var ownDevice: String?
    /// The Mac's bookmarks, folders left out.
    private(set) var bookmarks: [SyncedBookmark] = []
    /// Named states: what a synced place's device is called with no Macs in sync.
    @ObservationIgnored var fixtureDevices: [String: String] = [:]
    /// The search on the History screen, kept while Settings is open.
    var query = ""
    /// Clear's ranges are asked for (the confirmation over History).
    var asksClear = false
    /// The row standing swiped open, and how far: one at a time.
    var swipe: HistorySwipe?

    @ObservationIgnored private var cache: (key: CacheKey, entries: [HistoryEntry])?
    @ObservationIgnored private var placeCache: (key: CacheKey, marks: [SyncedBookmark], places: [PlaceCandidate])?
    @ObservationIgnored private var revision = 0

    private struct CacheKey: Equatable {
        var count: Int
        var first: BrowserVisit?
        var revision: Int
        var forgetting: HistoryForgetting
        var own: String?
        /// The Macs' names as sync knows them: a name that comes later is said.
        var devices: [String]
    }

    func attach(_ app: AppModel) { self.app = app }

    // MARK: - reading

    /// This iPhone's visits, newest first.
    var localVisits: [BrowserVisit] { app?.profile?.snapshot.visits ?? fixtureVisits }

    var forgetting: HistoryForgetting { app?.profile.map { $0.snapshot.historyForgetting ?? HistoryForgetting() } ?? fixtureForgetting }

    /// Every page, newest first.
    var entries: [HistoryEntry] {
        let local = localVisits
        let key = CacheKey(count: local.count, first: local.first, revision: revision, forgetting: forgetting, own: ownDevice,
                           devices: app?.sync.macs.map { $0.id + "\u{0}" + $0.name } ?? [])
        _ = synced
        if let cache, cache.key == key { return cache.entries }
        let made = HistoryList.entries(local: local, synced: Array(synced.values), forgetting: key.forgetting,
                                       ownDevice: ownDevice, name: { [weak self] in self?.deviceName($0) })
        cache = (key, made)
        return made
    }

    /// The days the History screen shows for its search.
    func days(now: Date = Date(), calendar: Calendar = .current) -> [HistoryDay] {
        HistoryList.days(HistoryList.matching(entries, query), now: now, calendar: calendar)
    }

    /// A device's name: the account's Mac, a named state's, or "Another device".
    func deviceName(_ id: String?) -> String? {
        guard let id else { return nil }
        if let mac = app?.sync.macs.first(where: { $0.id == id }) { return mac.name }
        if let name = fixtureDevices[id] { return name }
        return app?.isFixture == true ? app?.macName : "Another device"
    }

    /// The places the field may offer: History's and the Mac's bookmarks.
    var places: [PlaceCandidate] {
        let all = entries
        guard let key = cache?.key else { return Places.candidates(history: all, bookmarks: bookmarks) }
        if let placeCache, placeCache.key == key, placeCache.marks == bookmarks { return placeCache.places }
        let made = Places.candidates(history: all, bookmarks: bookmarks)
        placeCache = (key, bookmarks, made)
        return made
    }

    // MARK: - from sync

    /// Everything sync holds, read as it starts.
    func adoptSynced(_ places: [SyncedPlace], own: String?) {
        synced = Dictionary(places.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.last >= b.last ? a : b })
        ownDevice = own
        revision += 1
    }

    /// Places another device went to, as they come.
    func syncedChanged(_ places: [SyncedPlace]) {
        guard !places.isEmpty else { return }
        // Two records can be one place (an older Yab's key without the
        // port, and a newer one's): the newer visit is the row, as in
        // adoptSynced. A record's own `last` never goes back.
        for place in places where place.last >= (synced[place.key]?.last ?? 0) {
            synced[place.key] = place
        }
        revision += 1
    }

    func adoptBookmarks(_ tree: [SyncBookmark]) {
        var out: [SyncedBookmark] = []
        func walk(_ level: [SyncBookmark]) {
            for mark in level {
                if let url = mark.url { out.append(SyncedBookmark(title: mark.title, url: url)) }
                if let children = mark.children { walk(children) }
            }
        }
        walk(tree)
        if out != bookmarks { bookmarks = out }
    }

    // MARK: - taking pages out

    /// One page out: this iPhone's visit, or the Mac's place, which stays out
    /// here until someone goes there again.
    func delete(_ entry: HistoryEntry) {
        if let key = entry.syncedKey {
            var next = forgetting
            next.forget(key, last: entry.visitedAt.timeIntervalSince1970)
            setForgetting(next)
        } else {
            forget(urls: [entry.url])
        }
    }

    /// Clear: this iPhone's visits in the range, and the Mac's places in it
    /// out of this iPhone's History (the Mac keeps its own).
    func clear(_ range: HistoryRange, now: Date = Date(), calendar: Calendar = .current) {
        let cut = HistoryList.cleared(range, local: localVisits, now: now, calendar: calendar)
        forget(urls: cut.urls)
        var next = forgetting
        next.clear(from: cut.from, to: cut.to)
        next.prune(now: now)
        setForgetting(next)
    }

    private func forget(urls: Set<String>) {
        guard !urls.isEmpty else { return }
        if let profile = app?.profile { profile.forgetVisits(urls) }
        else { fixtureVisits.removeAll { urls.contains($0.url) } }
    }

    private func setForgetting(_ value: HistoryForgetting) {
        if let profile = app?.profile { profile.setHistoryForgetting(value) }
        else { fixtureForgetting = value }
    }

    // MARK: - to sync

    /// The profile has just recorded a visit to this tab's page: it goes to
    /// the Mac's history too, unless the tab or its space is private.
    func recorded(_ tab: Tab) {
        guard let app, let profile = app.profile, !tab.isPrivate,
              app.browser.space(holding: tab.id)?.isPrivate != true,
              let address = tab.navigationURL?.absoluteString,
              let visit = profile.snapshot.visits.first(where: { $0.url == address }),
              let url = URL(string: visit.url) else { return }
        app.sync.sendVisit(url, title: visit.title, at: visit.visitedAt)
    }

    /// This iPhone's last two weeks, for the Mac's history: sent again when
    /// sync starts writing or History in Sync is turned on (only what is
    /// newer than the record is written).
    var recentForSync: [(url: URL, title: String, at: Date)] {
        let now = Date()
        return localVisits.compactMap { visit in
            guard let url = URL(string: visit.url), HistoryList.syncs(url, at: visit.visitedAt, now: now) else { return nil }
            return (url, visit.title, visit.visitedAt)
        }
    }
}

// MARK: - showing and opening

extension AppModel {
    /// History over everything, its own sheet (Settings' look, × to close):
    /// what Settings' History row opens, and what "All History" calls.
    func showHistory() {
        let ui = SettingsUI.shared
        if surfaces.settings {
            ui.openPage(.history)
            return
        }
        ui.openedAt = .page(.history)
        ui.navigation = [.page(.history)]
        Motion.sheetGrow.run { surfaces.openSettings() }
    }

    /// A page chosen in History: in the tab in front when that is an empty
    /// New Tab, else a new tab. A page
    /// already open in this space is brought up rather than opened twice.
    /// History is never private: from Private it opens in ordinary browsing.
    func openFromHistory(_ entry: HistoryEntry) {
        guard let url = URL(string: entry.url) else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        surfaces.closeSettings()
        let ordinary = !browser.space.isPrivate
        if ordinary, let open = browser.space.allTabs.first(where: { !$0.isPrivate && $0.navigationURL.map(Address.pretty) == Address.pretty(url) }) {
            browser.select(open.id)
            return
        }
        let page = fixturesEnabled ? PageFixtures.tab(for: url, in: world, fixturesEnabled: true)
            : PageFixtures.liveTab(for: url, title: entry.title)
        if ordinary, let front = browser.tab, !front.isPrivate, front.place != .pinned, Self.isEmptyPage(front) {
            load(page, into: front)
        } else {
            show(page, newTab: true)
        }
    }

    /// A New Tab with nothing in it yet.
    static func isEmptyPage(_ tab: Tab) -> Bool {
        tab.page == "blank" || (tab.navigationURL == nil && tab.page == nil) || tab.navigationURL?.absoluteString == "about:blank"
    }
}
