import Foundation
import Observation
import SwiftUI

/// Today's cleanup. Automatic cleanup is conservative: the shared Mac
/// authority protocol is separate, and Off never makes an old synced tab
/// local-only. A person's Clear is the Mac's (TabClearPolicy.protectManual).
@MainActor
@Observable
final class TabClearCoordinator {
    struct Receipt {
        let id: UUID
        let before: Space
        let after: Space
        let until: TimeInterval
        let memory: [Tab.ID: WebPool.ClearMemory]
        let activity: [Tab.ID: TabClearPolicy.Activity]
        /// A person's Clear: undone whatever the tabs' provenance.
        var manual = false
        var count: Int { before.today.count - after.today.count }
        /// Not seen yet: the six seconds start once its toast is on screen.
        var waiting: Bool { until == .infinity }
    }
    /// How long Undo stays once the toast is seen.
    static let undoWindow: TimeInterval = 6
    private(set) var receipt: Receipt?
    private(set) var busy = false
    private(set) var message: String?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let disk: TabActivityProfile
    @ObservationIgnored private var privateActivity: [Tab.ID: TabClearPolicy.Activity] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var automaticWake: Task<Void, Never>?
    @ObservationIgnored private var automaticRunning = false
    @ObservationIgnored private var automaticDeferred: Set<Tab.ID> = []
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var selected: Tab.ID?
    @ObservationIgnored var clock: () -> TabClearPolicy.Clock = { .now }

    #if DEBUG
    /// Tests may suspend before the actual writer to change its owned path or
    /// browser owner. The real profile flush below is never replaced.
    @ObservationIgnored var beforePublicFlushForTests: (() async -> Void)?
    #endif

    init(app: AppModel) { self.app = app; disk = TabActivityProfile(profile: app.profile) }
    private var localAuthority: Bool {
        guard let app else { return false }
        return app.sync.engine == nil && app.sync.phase == .off && (app.isFixture || app.profile?.dataStoreID != nil)
    }
    func inserted(_ tab: Tab, in space: Space) {
        let entry = TabClearPolicy.Activity(space: space.id, address: tab.url, last: clock(), localOnly: localAuthority)
        if space.isPrivate { privateActivity[tab.id] = entry }
        else { disk.put(entry, for: tab, space: space); persist() }
    }
    func activity(_ id: Tab.ID) {
        guard foreground, let app, app.browser.tab?.id == id, let tab = app.browser.tab(id),
              let owner = app.browser.space(holding: id), !owner.isPrivate || app.privateLock.mayReveal else { return }
        var entry = owner.isPrivate ? privateActivity[id] : disk.entries[id]
        // Selection records real activity, but cannot invent local provenance.
        if entry == nil { entry = .init(space: owner.id, address: tab.url, last: clock(), localOnly: false) }
        automaticDeferred.remove(id)
        entry?.last = clock(); entry?.address = tab.url; entry?.space = owner.id
        if owner.isPrivate { privateActivity[id] = entry }
        else if let entry { disk.put(entry, for: tab, space: owner) }
    }
    func selectionChanged() {
        guard let app, selected != app.browser.tab?.id else { return }
        selected = app.browser.tab?.id
        invalidate()
        automaticDeferred.removeAll()
        if let id = selected { activity(id) }
        persist()
        scheduleAutomatic()
    }
    /// Called synchronously before any public journal write. A future Off
    /// keeps these IDs shared/unknown, even across launches.
    func markShared() {
        guard let app else { return }
        disk.markShared(Set(app.browser.spaces.filter { !$0.isPrivate }.flatMap(\.allTabs).map(\.id)))
        persist()
        if !app.browser.space.isPrivate { invalidate() }
    }
    func becameActive() {
        Links.trace("tabClearActive selected=\(app?.browser.tab?.id ?? "nil") clock=\(clock())")
        foreground = true
        automaticDeferred.removeAll()
        if let id = app?.browser.tab?.id { activity(id) }
        expire()
        scheduleAutomatic()
    }
    func resigned() { foreground = false; automaticWake?.cancel(); invalidate(); persist() }
    func flush() async { await disk.flush() }
    private func invalidate() { generation = UUID(); receipt = nil; expiry?.cancel() }
    private func persist() {
        guard let app else { return }
        let ids = Set(app.browser.spaces.filter(\.isPrivate).flatMap(\.allTabs).map(\.id))
        privateActivity = privateActivity.filter { ids.contains($0.key) }
        automaticDeferred.formIntersection(Set(app.browser.allTabs.map(\.id)))
        disk.save(browser: app.browser)
    }
    private func expire() { if let receipt, clock().uptime >= receipt.until { self.receipt = nil } }

    /// The receipt's toast is on screen (ColumnClearUndo): its six seconds
    /// start now. A Clear in the spaces makes it while they still cover the
    /// toast, and the seconds ran under them (TabClearUITests had to take
    /// Undo the moment the spaces went).
    func seen(_ id: UUID) {
        guard let saved = receipt, saved.id == id, saved.waiting else { return }
        let shown = Receipt(id: saved.id, before: saved.before, after: saved.after, until: clock().uptime + Self.undoWindow,
                            memory: saved.memory, activity: saved.activity, manual: saved.manual)
        receipt = shown
        scheduleExpiry(shown)
    }

    /// One next real deadline, only for an already live local candidate. A
    /// failed native observation defers until activity/foreground/selection,
    /// instead of waking every minute to repeatedly probe unknown documents.
    func scheduleAutomatic() {
        // Observation of busy/receipt must not cancel the very native attempt
        // which changed them. Lifecycle cancellation still invalidates owner.
        guard !automaticRunning else { return }
        automaticWake?.cancel(); automaticWake = nil
        guard let app, foreground, SettingsStore.shared.autoClearToday, !busy, receipt == nil,
              !blockedSurface, app.surfaces.recede == 0,
              !app.browser.space.isPrivate || app.privateLock.mayReveal else { return }
        let space = app.browser.space, now = clock()
        let delays = space.today.compactMap { tab -> TimeInterval? in
            guard !automaticDeferred.contains(tab.id), app.pages.isLive(tab.id), app.pages.painted.contains(tab.id) else { return nil }
            let entry = space.isPrivate ? privateActivity[tab.id] : disk.entries[tab.id]
            guard TabClearPolicy.protect(tab, in: space, activity: entry, now: now, automatic: false,
                    authorityLocal: localAuthority, draft: !(app.field.draft(for: tab.id) ?? "").isEmpty,
                    task: app.tasks.top != nil) == nil, let entry,
                  let age = now.elapsed(since: entry.last) else { return nil }
            return max(0, 12 * 60 * 60 - age)
        }
        guard let delay = delays.min() else { return }
        automaticWake = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.automaticRunning = true
            _ = await self.clear(automatic: true)
            self.automaticRunning = false
            self.automaticWake = nil
            self.scheduleAutomatic()
        }
    }
    /// The batch is still this run's to put away. A person's Clear owns the
    /// space whose page it was pressed on, shared or not, as the Mac's does;
    /// an automatic one only the space in front, and only with local authority.
    private func owns(_ space: Space, generation token: UUID, manual: Bool = false) -> Bool {
        guard let app, foreground, token == generation, manual || app.browser.spaceID == space.id,
              app.browser.space(space.id) == space, !space.isPrivate || app.privateLock.mayReveal else { return false }
        return manual || space.isPrivate || localAuthority
    }
    private var blockedSurface: Bool { blocked(byTheSpaces: true) }
    /// The spaces are New Tab's field, and since the column went (aaf8443d)
    /// they are where a person's own Clear stands: that Clear isn't blocked
    /// by them, an automatic one still is.
    private func blocked(byTheSpaces spaces: Bool) -> Bool {
        guard let app else { return true }
        let field = app.field.shown && (spaces || app.field.mode != .newTab)
        return FirstLaunch.shows(app)
            || field || app.chatSheet.shown || app.surfaces.settings
            || app.surfaces.join || app.surfaces.menu != nil || app.surfaces.pageSwiping
    }
    @discardableResult
    func clear(in id: Space.ID? = nil, automatic: Bool = false) async -> Int {
        expire()
        guard let app, !busy, receipt == nil, foreground, !blocked(byTheSpaces: automatic),
              !automatic || SettingsStore.shared.autoClearToday,
              !automatic || app.surfaces.recede == 0 else { return 0 }
        // The space whose page Clear was pressed on, in front or not.
        guard let before = id.flatMap({ app.browser.space($0) }) ?? Optional(app.browser.space),
              !before.isPrivate || app.privateLock.mayReveal else { return 0 }
        busy = true
        defer { busy = false }
        let token = generation, now = clock()
        let manual = !automatic
        var proofs: [Tab.ID: WebPool.ClearProof] = [:]
        // A person's Clear: tabs with no page alive go as they are, asleep.
        var cold: Set<Tab.ID> = []
        var unknown = 0
        func protects(_ tab: Tab, now: TabClearPolicy.Clock) -> Bool {
            let entry = before.isPrivate ? privateActivity[tab.id] : disk.entries[tab.id]
            let draft = !(app.field.draft(for: tab.id) ?? "").isEmpty
            if manual { return TabClearPolicy.protectManual(tab, in: before, draft: draft, task: app.tasks.top != nil) != nil }
            return TabClearPolicy.protect(tab, in: before, activity: entry, now: now, automatic: automatic,
                                          authorityLocal: localAuthority, draft: draft, task: app.tasks.top != nil) != nil
        }
        for tab in before.today {
            if protects(tab, now: now) { unknown += 1; continue }
            guard owns(before, generation: token, manual: manual) else { return 0 }
            if manual, !app.pages.isLive(tab.id) { cold.insert(tab.id); continue }
            if let proof = await app.pages.clearProof(for: tab) { proofs[tab.id] = proof }
            else { unknown += 1; if automatic { automaticDeferred.insert(tab.id) } }
        }
        guard owns(before, generation: token, manual: manual), !blocked(byTheSpaces: automatic), !automatic || SettingsStore.shared.autoClearToday else { return 0 }
        let live = Set(proofs.filter { id, proof in
            guard let tab = before.tab(id) else { return false }
            return app.pages.acceptsClearProof(proof) && !protects(tab, now: clock())
        }.map(\.key))
        let asleep = Set(cold.filter { id in
            guard let tab = before.tab(id) else { return false }
            return !app.pages.isLive(id) && !protects(tab, now: clock())
        })
        let ids = live.union(asleep)
        if automatic { automaticDeferred.formUnion(Set(proofs.keys).subtracting(ids)) }
        guard !ids.isEmpty else {
            if !automatic { message = "No tabs cleared · active, shared or unverified pages stay"; app.say(message!, glyph: .broom) }
            return 0
        }
        let memory = Dictionary(uniqueKeysWithValues: live.compactMap { id in app.pages.clearMemory(for: id).map { (id, $0) } })
        guard memory.count == live.count else { return 0 }
        let activities = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            (before.isPrivate ? privateActivity[id] : disk.entries[id]).map { (id, $0) }
        })
        var changed = false
        // A person's Clear on the spaces' page goes to dust as the Mac's
        // (TodayDust); the batch is put away once its rows have folded, with
        // nothing left to move for it.
        let dusted = manual && app.field.shown ? await TodayDust.shared.play(before.today.map(\.id).filter(ids.contains), in: before.id) : false
        if dusted {
            var quiet = Transaction(animation: nil)
            quiet.disablesAnimations = true
            withTransaction(quiet) { changed = app.browser.clearCheckedToday(ids, expected: before) }
            TodayDust.shared.settle()
        } else {
            Motion.columnRows.run { changed = app.browser.clearCheckedToday(ids, expected: before) }
        }
        guard changed, let after = app.browser.space(before.id) else { return 0 }
        let made = Receipt(id: UUID(), before: before, after: after, until: .infinity, memory: memory, activity: activities, manual: manual)
        for id in ids { app.pages.forget(id) }
        app.profile?.capture(app.browser)
        if !before.isPrivate {
            #if DEBUG
            await beforePublicFlushForTests?()
            #endif
            await app.profile?.flush()
            if app.profile?.lastWriteError != nil {
                // The real profile write failed: restore only if still owned.
                let rolledBack = app.browser.restoreCheckedToday(before, expected: after)
                if rolledBack {
                    // Put the returned records back in the profile before its
                    // navigation callback; a refused rollback owns no memory.
                    app.profile?.capture(app.browser)
                    for (id, memory) in made.memory { app.pages.restoreClearMemory(memory, for: id) }
                }
                receipt = nil
                message = rolledBack ? "Couldn’t save Clear · tabs were kept" : "Couldn’t save Clear · browser changed"
                app.say(message!, glyph: .broom)
                return 0
            }
        }
        persist()
        message = "Cleared \(ids.count) on this \(DeviceWord.name)" + (unknown > 0 ? " · other tabs protected" : "")
        // Offer Undo after the durable public write, rather than displaying an
        // unusable Undo during that await; its six seconds start once its
        // toast is on screen (seen).
        if token == generation, manual || app.browser.spaceID == before.id, app.browser.space(before.id) == after {
            receipt = made
        }
        return ids.count
    }
    private func scheduleExpiry(_ made: Receipt) {
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            guard !Task.isCancelled, self?.receipt?.id == made.id else { return }
            self?.expire()
            self?.scheduleAutomatic()
        }
    }
    var visibleReceipt: Receipt? {
        guard let app, let receipt, clock().uptime < receipt.until, receipt.manual || app.browser.spaceID == receipt.before.id,
              !receipt.before.isPrivate || app.privateLock.mayReveal else { return nil }
        return receipt
    }
    func undo(_ id: UUID) async {
        expire()
        guard let app, !busy, foreground, let saved = receipt, saved.id == id,
              saved.manual || app.browser.spaceID == saved.before.id, !saved.before.isPrivate || app.privateLock.mayReveal,
              saved.before.isPrivate || localAuthority || saved.manual,
              app.browser.space(saved.after.id) == saved.after else { return }
        busy = true
        defer { busy = false }
        var restored = false
        Motion.columnRows.run { restored = app.browser.restoreCheckedToday(saved.before, expected: saved.after) }
        guard restored else { return }
        receipt = nil; expiry?.cancel()
        for (id, memory) in saved.memory { app.pages.restoreClearMemory(memory, for: id) }
        for (id, oldEntry) in saved.activity {
            var entry = oldEntry
            entry.last = clock() // Explicit Undo is real activity, not another stale age.
            if saved.before.isPrivate { privateActivity[id] = entry }
            else if let tab = app.browser.tab(id) { disk.put(entry, for: tab, space: saved.before) }
        }
        app.profile?.capture(app.browser)
        await app.profile?.flush()
        persist()
        if app.profile?.lastWriteError != nil { app.say("Tabs restored · couldn’t save yet", glyph: .broom) }
    }
}
