import Foundation
import WebKit

// A space's kept tabs and its own pins, the same in every window of it, as
// Arc's pinned tabs are in each of its windows (feedback #157, docs/kept-tabs.md,
// "In every window"). Each window keeps a row of its own per space: its
// today's tabs are its own, and so is each page, but what is kept above the
// line, and the pins of a space that has its own, are one list. A window
// opened with ⌘N shows them, asleep; a tab kept, let go, closed, moved,
// renamed or put in a folder in one window is so in the others.
//
// The list's truth is the first window's row, the file sync reads and
// writes (session.json, session-<space>.json): an entry's id there is the
// key every window knows it by. Another window holds a tab of its own for
// each entry, under that key (Tab.keptKey), never its id, so the first
// window can always take the key as its own tab's id. Whenever a row is
// written with a list that differs from the one last written or followed,
// every other window follows it (Browser.followKept), the first one too,
// which writes its file, so a change made in any window reaches sync.
// The pins every space shares are apart from this (SharedPins.swift).
//
// With Settings › Tabs' "Today's tabs in every window" on (feedback #340),
// today's tabs are the list's too, as Arc's are: every window of a space
// shows the same tabs, each window with its own tab in front and its own
// page for each. A tab opened, closed, moved or put in a folder in one
// window is so in the others; one closed elsewhere closes here even awake
// or in front, as in Arc. Off, as in Dia, each window's today's are its
// own (`turnToday`).

@MainActor
enum KeptEverywhere {
    /// Each space's list as last written or followed, as marks: a write
    /// that says the same tells nobody.
    static var known: [UUID: [Data]] = [:]
    /// Inside a follow, or while Pins turns (SharedPins.turn): rows written
    /// then tell nobody.
    static var quiet = 0

    /// Settings › Tabs' "Today's tabs in every window": today's tabs are
    /// the list's too. Mirrors the setting for code off the main actor.
    nonisolated(unsafe) static var today = Store.settings.bool(forKey: todayKey)
    nonisolated static let todayKey = "tabs.todayEveryWindow"

    /// Brought in from Arc, whose Today tabs every window of a space
    /// shares: today's tabs in every window too, unless the switch was
    /// ever set here. Only a flip stores the key (Preferences), so a stored
    /// value, off included, is a choice made and stays. Owner, row 1109.
    static func broughtIn(from source: Chromium.Source, into prefs: Preferences, store: UserDefaults = Store.settings) {
        guard source.bundle == TabImport.arc, store.object(forKey: todayKey) == nil else { return }
        prefs.todayEveryWindow = true
    }

    /// The first window, whose rows are the lists every other window reads.
    /// Nil with none open (a test's browser), when a window's row is all its
    /// own, as it was before.
    static var first: Browser? { BrowserWindows.shared.normalBrowsers.first { $0.windowID == nil } }

    /// An entry of the list: pinned (a space's own pin) or kept, and any
    /// of today's with today's in every window.
    nonisolated static func listed(_ entry: Session.Entry) -> Bool {
        listed(entry, today: today)
    }

    nonisolated static func listed(_ entry: Session.Entry, today: Bool) -> Bool {
        today || entry.pin != nil || entry.kept == true
    }

    /// The key a kept tab or a pin is known by in every window.
    static func key(_ tab: Tab) -> UUID { tab.keptKey ?? tab.id }

    /// What every window agrees on for an entry: which one, pinned or kept,
    /// its letter, name, icon and home, its folder and the folders that is
    /// in, by id, name, mark and whether each is open, as Arc's sidebar is
    /// one in all its windows. Not where each window's tab has gone since,
    /// or when it was looked at.
    nonisolated static func mark(_ entry: Session.Entry) -> Data {
        var bare = entry
        bare.url = ""
        bare.title = ""
        bare.seen = nil
        bare.visits = nil
        bare.depth = nil
        bare.homeTitle = nil
        bare.shared = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(bare)) ?? Data()
    }

    nonisolated static func marks(_ list: [Session.Entry]) -> [Data] { list.map(mark) }

    /// Whether each folder of yours in a list is open, by its id: a tab's
    /// own folder, and each folder that one is in.
    nonisolated static func opens(_ list: [Session.Entry]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for entry in list {
            for step in entry.folderPath ?? [] { if let open = step.open { out[step.id] = open } }
            if let id = entry.folder, let open = entry.folderOpen { out[id] = open }
        }
        return out
    }

    /// The same place kept twice, by two windows of a Yab from before they
    /// shared it: pinned or kept alike, at the same home or address.
    nonisolated static func same(_ a: Session.Entry, _ b: Session.Entry) -> Bool {
        (a.pin != nil) == (b.pin != nil) && (a.home ?? a.url) == (b.home ?? b.url)
    }

    /// A window's own file of a space with the list in its kept's place.
    struct Joined {
        var shape: Session.Shape
        /// How many entries lead it that are the list's (made under its keys).
        var keyed: Int
        /// How many of those this window kept alone, under a Yab from
        /// before: they join the list (`Browser.loadRow` tells the others).
        var strays: Int
        /// The window had no row of its own there: none in front.
        var fresh: Bool
    }

    /// A window's own file `own` of a space and the list every window has:
    /// the list, then what this window kept alone before every window
    /// shared it (an entry not marked `shared` and not the list's already),
    /// then its today's. The tab in front and the pairs follow their
    /// entries; a row left on a shared pin stays so (below zero).
    /// With `today`, today's are the list's: this window's own, written
    /// while they were its own, join the list as they are, none taken for
    /// another at the same address.
    nonisolated static func joined(_ own: Session.Shape, list: [Session.Entry], today shares: Bool = KeptEverywhere.today) -> Joined {
        var restored = list
        var at: [Int: Int] = [:]
        var strays: [Session.Entry] = []
        var strayAt: [Int: Int] = [:]
        var today: [Session.Entry] = []
        var todayAt: [Int: Int] = [:]
        for (index, entry) in own.tabs.enumerated() {
            if let id = entry.id, listed(entry, today: shares) || entry.shared == true, let found = list.firstIndex(where: { $0.id == id }) {
                at[index] = found
                // The list owns membership, order and folder metadata. The
                // page belongs to this window: replacing it with the first
                // window's address made a relaunch show that window's page
                // here, even though the selection still named the right tab.
                restored[found].url = entry.url
                restored[found].title = entry.title
                restored[found].seen = entry.seen
                restored[found].visits = entry.visits
                restored[found].depth = entry.depth
                continue
            }
            // Gone from the list since this window last wrote it.
            if entry.shared == true { continue }
            if shares, !listed(entry, today: false) {
                strayAt[index] = strays.count
                strays.append(entry)
                continue
            }
            if listed(entry, today: false) {
                if let found = list.firstIndex(where: { same($0, entry) }) {
                    at[index] = found
                } else if let found = strays.firstIndex(where: { same($0, entry) }) {
                    strayAt[index] = found
                } else {
                    strayAt[index] = strays.count
                    strays.append(entry)
                }
                continue
            }
            todayAt[index] = today.count
            today.append(entry)
        }
        for (index, found) in strayAt { at[index] = list.count + found }
        for (index, found) in todayAt { at[index] = list.count + strays.count + found }
        // None in front, or one gone from the list since: none.
        let front = own.front.flatMap { $0 < 0 ? $0 : at[$0] }
        let pairs = (own.pairs ?? []).compactMap { $0.moved { at[$0] } }
        return Joined(shape: Session.Shape(tabs: restored + strays + today, front: front, pairs: pairs.isEmpty ? nil : pairs),
                      keyed: list.count + strays.count, strays: strays.count, fresh: own.tabs.isEmpty)
    }

    /// The first window's file of a space it hasn't read since launch, with
    /// `list` in its kept's place: its today's stay as they were, the tab in
    /// front and the pairs with them.
    nonisolated static func replaced(_ shape: Session.Shape, with list: [Session.Entry], today: Bool = KeptEverywhere.today) -> Session.Shape {
        var at: [Int: Int] = [:]
        var rest: [Session.Entry] = []
        for (index, entry) in shape.tabs.enumerated() {
            if listed(entry, today: today) {
                if let id = entry.id, let found = list.firstIndex(where: { $0.id == id }) { at[index] = found }
            } else {
                at[index] = list.count + rest.count
                rest.append(entry)
            }
        }
        let front = shape.front.flatMap { $0 < 0 ? $0 : at[$0] }
        let pairs = (shape.pairs ?? []).compactMap { $0.moved { at[$0] } }
        return Session.Shape(tabs: list + rest, front: front, pairs: pairs.isEmpty ? nil : pairs)
    }

    /// Today's in every window turned on or off, for every window
    /// together (`first` the first window, `others` the rest). On: each
    /// space's list takes every window's today's, the first window's where
    /// they stand, then each other window's own after them, and every
    /// window follows it, nothing closed. Off: a window other than the
    /// first keeps the today's it has open (awake, in front, side by side)
    /// as its own and lets the rest go, which stay in the first window.
    static func turnToday(_ on: Bool) {
        turnToday(on, first: first, others: nil)
    }

    static func turnToday(_ on: Bool, first: Browser?, others: [Browser]?) {
        guard today != on else { return }
        today = on
        known = [:]
        guard let first else { return }
        let others = others ?? BrowserWindows.shared.normalBrowsers.filter { $0 !== first }
        guard !others.isEmpty else { return }
        quiet += 1
        defer { quiet -= 1 }
        if on {
            var spaces: [UUID] = []
            for window in [first] + others {
                for space in [window.spaceID] + window.parked.keys.sorted(by: { $0.uuidString < $1.uuidString })
                    where space != Space.pinsID && !spaces.contains(space) { spaces.append(space) }
            }
            for space in spaces {
                var list = first.row(of: space).map(first.keptList) ?? Session.read(space: space).tabs.filter { listed($0, today: true) }
                for other in others {
                    for tab in other.row(of: space) ?? [] where other.listed(tab) && tab.pin == nil && !tab.kept && tab.keptKey == nil {
                        let key = UUID()
                        guard let entry = other.sessionEntry(tab, id: key) else { continue }
                        tab.keptKey = key
                        list.append(entry)
                    }
                }
                for window in [first] + others { window.followKept(list, in: space) }
                known[space] = marks(list)
            }
        } else {
            for other in others { other.keepOwnToday() }
        }
    }

    /// A row of `space` was just written by `browser`, `list` its kept and
    /// pins: every other window follows, if it changed, at once, before one
    /// of them can write the list it had over this one. Only windows on
    /// screen are told; a test's browser is no window.
    static func wrote(_ list: [Session.Entry], space: UUID, by browser: Browser) {
        // A Blank Window's row is its own: it tells nobody, and is told nothing.
        guard space != Space.pinsID, !browser.blank else { return }
        let said = marks(list)
        if quiet > 0 {
            known[space] = said
            return
        }
        guard said != known[space] else { return }
        let windows = BrowserWindows.shared.normalBrowsers
        guard windows.contains(where: { $0 === browser }) else { return }
        known[space] = said
        quiet += 1
        defer { quiet -= 1 }
        for other in windows where other !== browser && !other.blank { other.followKept(list, in: space) }
    }
}

extension Browser {
    /// Whether a tab is one of its space's list: kept, or a pin of the
    /// space's own, a tab of yours that is written. Never a shared pin
    /// (SharedPins.swift), a private tab, Yab's own work, a call or an
    /// agent's guest, each of which stays where it is.
    /// With today's in every window, any of today's too.
    func listed(_ tab: Tab) -> Bool {
        tab.everywhere == nil && (KeptEverywhere.today || tab.kept || tab.pin != nil) && !tab.shy && !travels(tab)
    }

    /// A row's list as it would be written, each entry under its key.
    func keptList(_ row: [Tab]) -> [Session.Entry] {
        row.filter(listed).compactMap { sessionEntry($0, id: KeptEverywhere.key($0)) }
    }

    /// Whether this window shares its rows' lists with the first one: a
    /// window other than the first, with the first open.
    var sharesKept: Bool { windowPurpose == .normal && windowID != nil && !blank && KeptEverywhere.first != nil }

    /// A space's list as every window has it, for a row of it read here:
    /// another window's row in memory, the first window's first, else the
    /// first window's file. Nil in the first window, or with it not open.
    func sharedKept(for space: UUID) -> [Session.Entry]? {
        guard sharesKept, space != Space.pinsID else { return nil }
        let others = BrowserWindows.shared.normalBrowsers
            .filter { $0 !== self }
            .sorted { ($0.windowID == nil ? 0 : 1) < ($1.windowID == nil ? 0 : 1) }
        for other in others {
            if let row = other.spaceID == space ? other.tabs : other.parked[space]?.tabs { return other.keptList(row) }
        }
        return Session.read(space: space).tabs.filter(KeptEverywhere.listed)
    }

    /// This window's tab for an entry of the list, made asleep: in the
    /// first window under the key as its id where it can be, in another
    /// always under an id of its own.
    func keptCopy(_ entry: Session.Entry, space: UUID) -> Tab? {
        guard let url = URL(string: entry.url) else { return nil }
        let key = entry.id.flatMap(UUID.init(uuidString:)) ?? UUID()
        let id = windowID == nil ? Tab.returning(key.uuidString) : UUID()
        let tab = Startup.flag("LAZY_CONFIG")
            ? Tab(id: id, later: Spaces.store(for: space), engine: entry.restoredEngine)
            : Tab(id: id, configuration: Web.configuration(store: Spaces.store(for: space)), engine: entry.restoredEngine)
        if tab.id != key { tab.keptKey = key } else { tab.takeCopiesMute() }
        prepare(tab)
        tab.restore(url: url, title: entry.title)
        tab.visits = entry.visits ?? 0
        if let seen = entry.seen { tab.touch(at: Date(timeIntervalSince1970: seen)) }
        tab.arrive(at: entry.depth)
        return tab
    }

    /// What the list says of a tab, taken: its pin or kept, letter, name,
    /// icon, home, and its folder of yours and the folders that is in,
    /// found among `nests` by id or made (a folder made opens or shuts as
    /// the list says; one already here is turned by `turnKept`).
    func takeKept(_ entry: Session.Entry, into tab: Tab, nests: inout [String: Nest]) {
        if tab.pin != entry.pin { tab.pin = entry.pin }
        if tab.name != entry.name { tab.name = entry.name }
        if tab.customMark != entry.customMark { tab.customMark = entry.customMark }
        let kept = entry.kept == true && entry.pin == nil
        if tab.kept != kept { tab.kept = kept }
        tab.takeHome(entry)
        let live = kept ? entry.live : nil
        if tab.live != live { tab.live = live }
        guard kept else {
            takeTodayFolder(entry, into: tab, nests: &nests)
            return
        }
        guard let key = entry.folder else {
            if tab.nest != nil { tab.nest = nil }
            return
        }
        let nest = nests[key] ?? Nest(id: UUID(uuidString: key) ?? UUID(), name: entry.folderName ?? "Folder", open: entry.folderOpen ?? true)
        nest.ordinaryToday = false
        nest.fleeting = false
        nest.search = nil
        if let name = entry.folderName, nest.name != name { nest.name = name }
        if nest.live != entry.folderLive { nest.live = entry.folderLive }
        if nest.customMark != entry.folderMark { nest.customMark = entry.folderMark }
        if nest.color != entry.folderColor { nest.color = entry.folderColor }
        nests[key] = nest
        nest.file(in: entry.folderPath?.map { step in
            var step = step
            step.open = nil
            return step
        }, nests: &nests, update: true)
        for each in nest.chain { each.ordinaryToday = false; each.fleeting = false; each.search = nil }
        if tab.nest !== nest { tab.nest = nest }
    }

    /// One of today's folders the entry is in, a search's or one you made
    /// of today's tabs, with today's in every window; else none.
    private func takeTodayFolder(_ entry: Session.Entry, into tab: Tab, nests: inout [String: Nest]) {
        guard KeptEverywhere.today, entry.pin == nil, let key = entry.folder,
              entry.folderToday == true || entry.folderSearch != nil else {
            if tab.nest != nil { tab.nest = nil }
            return
        }
        let nest = nests[key] ?? Nest(id: UUID(uuidString: key) ?? UUID(), name: entry.folderName ?? entry.folderSearch.map(Research.name) ?? "Folder",
                                      open: entry.folderOpen ?? true, search: entry.folderSearch)
        if let name = entry.folderName, nest.name != name { nest.name = name }
        if nest.search != entry.folderSearch { nest.search = entry.folderSearch }
        nest.ordinaryToday = entry.folderOrdinaryToday == true
        let fleeting = entry.folderToday == true && !nest.ordinaryToday
        if nest.fleeting != fleeting { nest.fleeting = fleeting }
        let linked = entry.folderLinked == true
        if nest.linked != linked { nest.linked = linked }
        if nest.customMark != entry.folderMark { nest.customMark = entry.folderMark }
        if nest.color != entry.folderColor { nest.color = entry.folderColor }
        nests[key] = nest
        nest.file(in: nest.ordinaryToday ? entry.folderPath : nil, nests: &nests, update: true)
        for each in nest.chain where nest.ordinaryToday { each.ordinaryToday = true }
        if tab.nest !== nest { tab.nest = nest }
    }

    /// The folders a row's tabs are in, by id.
    func nestsByID(_ row: [Tab]) -> [String: Nest] {
        Dictionary(row.flatMap { tab in (tab.nest?.chain ?? []).map { ($0.id.uuidString, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Another window changed a space's list (or sync did, through the
    /// first): the same list here, in its order, each entry this window has
    /// a tab for kept as it is, with the list's pin, name, icon, home and
    /// folder, one it hasn't made asleep. One gone from the list goes too
    /// if it is asleep here; awake, or in front, it stays as one of today's,
    /// as Don't Keep leaves it, its page not taken from under you. A row
    /// not read here since launch: the first window writes its file; the
    /// others read the list when they come to it (`sharedKept`).
    func followKept(_ list: [Session.Entry], in space: UUID) {
        guard windowPurpose == .normal else { return }
        let onScreen = space == spaceID
        guard onScreen || parked[space] != nil else {
            if windowID == nil {
                Session.write(now: true, space: space, KeptEverywhere.replaced(Session.read(space: space), with: list))
            }
            return
        }
        var row = onScreen ? tabs : parked[space]?.tabs ?? []
        // Only those a row writes: one kept at no web address now is in no
        // other window's list, and stays as it is.
        let mine = row.filter { listed($0) && sessionEntry($0, id: $0.id) != nil }
        guard KeptEverywhere.marks(keptList(mine)) != KeptEverywhere.marks(list) else { return }
        let front = onScreen ? activeID : parked[space]?.active
        var byKey: [String: Tab] = [:]
        for tab in mine where byKey[KeptEverywhere.key(tab).uuidString] == nil { byKey[KeptEverywhere.key(tab).uuidString] = tab }
        var nests = nestsByID(row)
        let had = Set(nests.keys)
        var next: [Tab] = []
        for entry in list {
            guard let id = entry.id else { continue }
            let found = byKey.removeValue(forKey: id)
            guard let tab = found ?? keptCopy(entry, space: space) else { continue }
            // One of today's asleep here, gone on to another page elsewhere:
            // that page when it is next opened here, as sync's rows do.
            if let found, KeptEverywhere.today, entry.pin == nil, entry.kept != true, found.asleep, found.id != front,
               let url = URL(string: entry.url), (found.pending ?? found.address) != url {
                found.restore(url: url, title: entry.title)
            }
            takeKept(entry, into: tab, nests: &nests)
            next.append(tab)
        }
        let paired = Set((onScreen ? pairs : parked[space]?.pairs ?? []).flatMap(\.ids))
        var demoted: [Tab] = [], closing: [Tab] = [], shutting: [Tab] = []
        for tab in mine where !next.contains(where: { $0 === tab }) {
            if tab.asleep, tab.id != front, !paired.contains(tab.id) {
                closing.append(tab)
            } else if KeptEverywhere.today {
                // Closed elsewhere: here too, awake or in front, as in Arc.
                // Left among today's it would be the list's again, and come
                // back in the window that closed it.
                tab.pin = nil
                tab.kept = false
                tab.live = nil
                shutting.append(tab)
            } else {
                tab.pin = nil
                tab.kept = false
                tab.nest = nil
                tab.live = nil
                tab.keptKey = nil
                demoted.append(tab)
            }
        }
        let others = row.filter { tab in !mine.contains { $0 === tab } }
        let rest = others.filter { $0.everywhere == nil }
        row = others.filter { $0.everywhere != nil }
            + next.filter { $0.pin != nil } + rest.filter { $0.pin != nil }
            + next.filter { $0.pin == nil } + rest.filter { $0.pin == nil && $0.kept }
            + demoted + rest.filter { $0.pin == nil && !$0.kept }
        for tab in closing {
            AgentPage.forget(tab)
            tab.close()
        }
        KeptEverywhere.quiet += 1
        defer { KeptEverywhere.quiet -= 1 }
        // Folders opened or shut elsewhere: here too, those on screen on
        // the folder's own clock, as a click turns them.
        var turning: [(Nest, Bool)] = []
        for (id, open) in KeptEverywhere.opens(list) {
            guard let nest = nests[id], nest.open != open else { continue }
            // One just made here is made as the list says.
            if had.contains(id) { turning.append((nest, open)) } else { nest.open = open }
        }
        if onScreen {
            quietly { lay(row + shutting) }
            for (nest, open) in turning {
                if folderBook.browser === self, folderBook.folder(nest.key) != nil { folderBook.toggle(nest.key) } else { nest.open = open }
            }
            // As ⌘W closes them: the tab in front gives way to its
            // neighbor, a half of two side by side to the other.
            for tab in shutting { close(tab) }
            writeRow(tabs, active: activeID, space: space, pairs: pairs, now: true)
        } else if var held = parked[space] {
            for (nest, open) in turning { nest.open = open }
            for tab in shutting {
                AgentPage.forget(tab)
                tab.close()
            }
            let gone = Set(shutting.map(\.id))
            held.tabs = row
            // A split a closed tab was in is the rest of it, as on screen.
            held.pairs = held.pairs.compactMap { pair in
                pair.ids.contains(where: gone.contains) ? pair.with(pair.ids.filter { !gone.contains($0) }) : pair
            }
            if let active = held.active, gone.contains(active) { held.active = nil }
            parked[space] = held
            writeRow(row, active: held.active, space: space, pairs: held.pairs, now: true)
        }
    }

    /// With today's in every window: when each tab of the row on screen
    /// was last looked at in another window of its space, by key, now for
    /// one on screen there. Empty otherwise.
    func seenElsewhere() -> [UUID: Date] {
        guard KeptEverywhere.today else { return [:] }
        var out: [UUID: Date] = [:]
        let now = Date()
        for other in BrowserWindows.shared.normalBrowsers where other !== self {
            for tab in other.row(of: spaceID) ?? [] where other.listed(tab) {
                let seen = other.spaceID == spaceID && other.onScreen(tab.id) ? now : tab.touched
                let key = KeptEverywhere.key(tab)
                out[key] = max(out[key] ?? .distantPast, seen)
            }
        }
        return out
    }

    /// A space's row here, on screen or parked; nil for one not read here.
    func row(of space: UUID) -> [Tab]? {
        space == spaceID ? tabs : parked[space]?.tabs
    }

    /// Today's in every window turned off, in a window other than the
    /// first: today's open here stay, its own now; the rest, asleep, go.
    func keepOwnToday() {
        for space in [spaceID] + Array(parked.keys) where space != Space.pinsID {
            let onScreen = space == spaceID
            guard let current = self.row(of: space) else { continue }
            let front = onScreen ? activeID : parked[space]?.active
            let paired = Set((onScreen ? pairs : parked[space]?.pairs ?? []).flatMap(\.ids))
            var going: [Tab] = []
            for tab in current where tab.keptKey != nil && tab.pin == nil && !tab.kept && tab.everywhere == nil {
                if tab.asleep, tab.id != front, !paired.contains(tab.id) {
                    going.append(tab)
                } else {
                    tab.keptKey = nil
                }
            }
            let left = current.filter { tab in !going.contains { $0 === tab } }
            for tab in going {
                AgentPage.forget(tab)
                tab.close()
            }
            if onScreen {
                if !going.isEmpty { quietly { lay(left) } }
                writeRow(left, active: activeID, space: space, pairs: pairs, now: true)
            } else if var held = parked[space] {
                held.tabs = left
                parked[space] = held
                writeRow(left, active: held.active, space: space, pairs: held.pairs, now: true)
            }
        }
    }

    /// A stand-in for a kept tab or a pin leaving for another window: this
    /// window's own tab for it, asleep, in its place (BrowserWindows.move).
    func keptStandIn(for tab: Tab) -> Tab? {
        guard let entry = sessionEntry(tab, id: KeptEverywhere.key(tab)), let copy = keptCopy(entry, space: spaceID) else { return nil }
        var nests = nestsByID(tabs)
        takeKept(entry, into: copy, nests: &nests)
        return copy
    }
}

extension Tab {
    /// The other windows' tabs for the same entry: a shared pin by its key
    /// in every window (`everywhere`), a space's own pin or kept tab by the
    /// list's key, any space's row and a tab parked aside included. None
    /// for a tab of this window's own. The handing over of a page
    /// (BrowserWindows.handOff) and a test's windows count them the same.
    var copies: [Tab] {
        let windows = BrowserWindows.shared.handOffWindows ?? BrowserWindows.shared.normalBrowsers
        let key = KeptEverywhere.key(self)
        return windows.flatMap(\.everyTab).filter { other in
            other !== self && (everywhere.map { other.everywhere == $0 } ?? (other.everywhere == nil && KeptEverywhere.key(other) == key))
        }
    }
}
