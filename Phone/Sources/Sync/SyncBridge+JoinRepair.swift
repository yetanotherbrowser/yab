import Foundation
import os
import SyncKit

/// The second Personal space a broken join made, found and folded back into
/// the account's first space (docs/sync.md, duplicate Personals).
extension SyncBridge {
    /// Still the starting space as Yab made it: Personal with the house.
    /// Renamed or given another icon, it is a space of the person's own.
    static func isStartingPersonal(name: String, icon: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces) == "Personal" && SpaceSymbols.emoji(icon) == "🏠"
    }

    /// The second Personal a broken join made: the starting Personal went
    /// up under an id of its own (`start`, this iPhone's mapping of it)
    /// because the account's first space wasn't in yet. Only the iPhone
    /// that made it has that mapping, so only it acts: two devices moving
    /// and deleting at once could lose a tab, a tab's removal winning. It
    /// is the copy only while still called Personal with the house, with
    /// no sign-ins or folders of its own, and every page in it pinned,
    /// kept or this iPhone's of today. Pure, for the tests: the synced id.
    static func joinDuplicate(_ mirror: SyncMirror, start: String?) -> String? {
        guard let start, mirror.spaces.values.contains(where: \.isFirst),
              let copy = mirror.spaces[start], !copy.isFirst, !copy.ownSignIns,
              isStartingPersonal(name: copy.name, icon: copy.icon) else { return nil }
        let row = mirror.row(start)
        guard row.folders.isEmpty, row.elsewhere.allSatisfy({ blankURL($0.url) }) else { return nil }
        return start
    }

    /// Once a line is caught up: the second Personal a broken join made
    /// (joinDuplicate) gives its tabs to the first space, pins pinned and
    /// kept kept, and goes on every device once nothing of it is left in
    /// the journal. Run on each launch: after the delete it finds nothing.
    @discardableResult
    func repairJoinDuplicate() -> Bool {
        guard let app, !app.isFixture, writing, line == .live, let engine,
              let copy = Self.joinDuplicate(mirror, start: ids.known(BrowserProfile.startSpace)) else { return false }
        let local = ids.local(copy), firstLocal = ids.local(SyncCollection.firstSpace)
        guard let space = app.browser.space(local), !space.isPrivate, space.folders.isEmpty,
              let target = app.browser.space(firstLocal) else { return false }
        let merged = Self.merged(space, into: target, home: pinHome)
        // What stays behind is blank tabs only. A pin the first space already
        // has, saved at the same address, isn't merged (merged) and goes with the copy.
        var left = space
        left.pins = space.pins.filter(Self.isBlank)
        left.kept = space.kept.filter { if case let .tab(tab) = $0 { return Self.isBlank(tab) }; return false }
        left.today = space.today.filter(Self.isBlank)
        left.current = nil
        let showing = app.browser.spaceID == local
        app.browser.adopt(app.browser.spaces.map { $0.id == firstLocal ? merged : $0.id == local ? left : $0 })
        if showing { app.browser.showSpace(firstLocal) }
        for tab in space.allTabs where merged.tab(tab.id) == nil && left.tab(tab.id) == nil { app.pages.forget(tab.id) }
        flushLocal()
        let row = engine.row(copy)
        guard row.folders.isEmpty, (row.all + row.elsewhere).allSatisfy({ Self.blankURL($0.url) }) else {
            log.notice("sync: the second Personal still holds tabs; its delete waits")
            return true
        }
        log.notice("sync: moved the second Personal a broken join made into the first space")
        deleteSpace(local)
        return true
    }
}
