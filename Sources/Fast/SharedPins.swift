import Foundation
import WebKit

// The pins every space shares, as Arc's Favorites are (docs/shared-pins.md).
// With Settings › Spaces' Pins at In Every Space, one row of pins heads every
// space that signs in where the first one does: the same live tabs whichever
// of those spaces is on screen, so a pin's music plays on through a switch
// and Gmail is loaded once, not once a space. A space with sign-ins of its
// own shows pins of its own in their place: the shared ones would open there
// signed in as somebody else.
//
// The shared row is a row like a space's, under an id of its own
// (Space.pinsID), written and read by writeRow and loadRow, to one file every
// window reads, its pages in the first space's store. In memory its tabs lead
// the row on screen while a space that shows them is, and are parked under
// that id while one that doesn't is (a space of its own, Mail). Each
// window holds a live tab of its own for each pin; what the pins are, which
// ones, in what order, with which letters, names and icons, is one list, and
// the other windows follow a change made in one.

extension Space {
    /// The shared pins' row: never a space in the list.
    static let pinsID = UUID(uuidString: "00000000-0000-0000-0000-000000000A11")!
}

@MainActor
enum SharedPins {
    nonisolated static let key = "pins.everySpace"
    /// Set while `key` holds what this Mac decided at its first launch
    /// rather than what somebody chose: that value gives way to the
    /// account's when the Mac joins sync. Never synced.
    nonisolated static let decidedKey = "pins.everySpace.decided"
    /// Set from joining sync until it has caught up, to the value this
    /// Mac had decided for itself (`joining`). Never synced.
    nonisolated static let joiningKey = "pins.everySpace.joining"

    /// Whether this Mac had Yab in use before it read the setting: the
    /// welcome done (or a session from before the welcome existed), or a
    /// list of spaces, a session or history kept. None of these is written
    /// before the first window reads its preferences, so a new Mac has none.
    nonisolated static func inUse(folder: URL, settings: UserDefaults) -> Bool {
        if settings.bool(forKey: "welcomed") || settings.object(forKey: "glyph") != nil { return true }
        return ["spaces.json", "session.json", "history.json"].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// What the pins are at launch. A choice made here or brought by sync
    /// stays. A Mac that never chose gets In Every Space when it is new, as
    /// Arc's Favorites are from the start, and In Each Space when it was
    /// in use before there was a choice, its spaces each holding pins of
    /// their own, so that nothing moves under anybody. Decided once, at
    /// the first launch, and written down, so finishing the welcome later
    /// doesn't change it. While joining sync nothing is decided: In Each
    /// Space until the account's value comes (`joining`, `joined`).
    nonisolated static func decide(settings: UserDefaults, folder: URL) -> Bool {
        if let chosen = settings.object(forKey: key) as? Bool { return chosen }
        if joiningSync(settings) { return false }
        let every = !inUse(folder: folder, settings: settings)
        settings.set(every, forKey: key)
        settings.set(true, forKey: decidedKey)
        return every
    }

    /// A choice, from Settings, an agent, the bench or sync: kept, and no
    /// longer this Mac's own default. Not written while joining: what
    /// comes in then is the account's, written by sync itself.
    nonisolated static func chose(_ every: Bool, settings: UserDefaults) {
        guard !joiningSync(settings) else { return }
        settings.set(every, forKey: key)
        settings.removeObject(forKey: decidedKey)
    }

    /// Between joining sync and its catching up.
    nonisolated static func joiningSync(_ settings: UserDefaults) -> Bool {
        settings.object(forKey: joiningKey) != nil
    }

    /// Joining an account, with Pins as this Mac decided them alone, never
    /// chosen. A new Mac's In Every Space gives way to the account's value
    /// (true when so: the pins are each space's until it comes, so no pin
    /// of another Mac's is taken for a shared one on the way in). A Mac in
    /// use keeps In Each Space through the join, the account's In Every
    /// Space not taken (`holdsApart`), and then sends it as its choice: the
    /// pins of somebody who had them before are never merged by a join.
    /// A choice made here stays and syncs as any setting does.
    @discardableResult
    nonisolated static func joining(settings: UserDefaults) -> Bool {
        guard settings.bool(forKey: decidedKey), let decided = settings.object(forKey: key) as? Bool else { return false }
        settings.set(decided, forKey: joiningKey)
        guard decided else { return false }
        settings.removeObject(forKey: key)
        settings.removeObject(forKey: decidedKey)
        return true
    }

    /// While a Mac in use joins: the account's Pins not taken.
    nonisolated static func holdsApart(_ settings: UserDefaults) -> Bool {
        settings.object(forKey: joiningKey) as? Bool == false
    }

    /// Caught up after joining: for a new Mac the account's value, or In
    /// Each Space when the account had none (its Macs all on a Yab from
    /// before the choice, so in use); for a Mac in use In Each Space. Written
    /// as a choice, so that it syncs. Nil when not joining.
    nonisolated static func joined(settings: UserDefaults) -> Bool? {
        guard let decided = settings.object(forKey: joiningKey) as? Bool else { return nil }
        settings.removeObject(forKey: joiningKey)
        let every = decided ? settings.object(forKey: key) as? Bool ?? false : false
        settings.set(every, forKey: key)
        settings.removeObject(forKey: decidedKey)
        return every
    }

    /// Sync turned off before a join caught up: what this Mac had decided
    /// comes back, unless the account's value came. Nil when not joining.
    nonisolated static func leftJoining(settings: UserDefaults) -> Bool? {
        guard let decided = settings.object(forKey: joiningKey) as? Bool else { return nil }
        settings.removeObject(forKey: joiningKey)
        if let came = settings.object(forKey: key) as? Bool { return came }
        settings.set(decided, forKey: key)
        settings.set(true, forKey: decidedKey)
        return decided
    }

    /// Whether the pins are shared now: the first window's rows as they are
    /// laid out, or, with no window open, what Settings says.
    static var on: Bool {
        BrowserWindows.shared.normalBrowsers.first { $0.windowID == nil }?.pinsShared
            ?? (Store.settings.bool(forKey: "spaces") && Store.settings.bool(forKey: key))
    }

    /// Rows of pins as one row: the first row's first, each in the order it
    /// stood, and a pin at an address already in it left out. Only the very
    /// same address: two Gmail accounts, u/0 and u/1, stay two. A pin with
    /// nothing to compare (a call in it, an agent at work there) is never
    /// left out.
    nonisolated static func merge<Pin>(_ rows: [[Pin]], address: (Pin) -> String?) -> (kept: [Pin], dropped: [Pin]) {
        var seen = Set<String>()
        var kept: [Pin] = [], dropped: [Pin] = []
        for pin in rows.joined() {
            guard let at = address(pin) else {
                kept.append(pin)
                continue
            }
            if seen.insert(at).inserted { kept.append(pin) } else { dropped.append(pin) }
        }
        return (kept, dropped)
    }

    /// The space the pins go to when they stop being shared: the one on
    /// screen when it showed them, the first one otherwise. Otherwise is a
    /// space of its own on screen, Mail, or spaces turned off, which
    /// leaves the first one on screen.
    nonisolated static func heir(onScreen: UUID, showing: Bool, spacesOn: Bool, home: UUID = Space.firstID) -> UUID {
        spacesOn && showing ? onScreen : home
    }

    /// `items` in the order `order` names them, those it doesn't name after
    /// them as they stood.
    nonisolated static func ordered<T>(_ items: [T], id: (T) -> UUID, by order: [UUID]?) -> [T] {
        guard let order else { return items }
        let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated()
            .sorted { (place[id($0.element)] ?? order.count + $0.offset, $0.offset) < (place[id($1.element)] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// A row's file without its pins, which went into the shared row: the
    /// tab in front and the pairs follow their tabs, and a row left on a
    /// pin comes back with none in front, not on its first tab.
    nonisolated static func unpinned(_ shape: Session.Shape) -> Session.Shape {
        let loose = shape.tabs.indices.filter { shape.tabs[$0].pin == nil }
        guard loose.count != shape.tabs.count else { return shape }
        let at = Dictionary(uniqueKeysWithValues: loose.enumerated().map { ($1, $0) })
        let pairs = (shape.pairs ?? []).compactMap { pair -> Session.Pair? in
            guard let a = at[pair.first], let b = at[pair.second] else { return nil }
            return Session.Pair(first: a, second: b, share: pair.share)
        }
        return Session.Shape(tabs: loose.map { shape.tabs[$0] }, front: shape.front.flatMap { at[$0] }, pairs: pairs.isEmpty ? nil : pairs)
    }

    /// The first space's row as sync sends it: the shared pins at its head,
    /// as the first space's own pins were before they were shared. Other
    /// devices, the phone and a Mac at In Each Space, know pins only as a
    /// space's, and the first space is the one every sharing Mac has. A row
    /// left on a shared pin is sent left on it.
    /// Pairs pinned as one among the pins (`pinPairs`, by where each
    /// stands among them) go with them, as the space's own pins' do.
    nonisolated static func folded(_ pins: [Session.Entry], into first: Session.Shape, pinPairs: [Session.Pair]? = nil) -> Session.Shape {
        guard !pins.isEmpty else { return first }
        let count = pins.count
        let front = first.front.flatMap { at in
            at < 0 ? min(-1 - at, count - 1) : first.tabs.indices.contains(at) ? at + count : nil
        }
        let own = (pinPairs ?? []).filter { $0.first < count && $0.second < count && $0.first >= 0 && $0.second >= 0 }
        let pairs = own + (first.pairs ?? []).map { Session.Pair(first: $0.first + count, second: $0.second + count, share: $0.share) }
        return Session.Shape(tabs: pins + first.tabs, front: front, pairs: pairs.isEmpty ? nil : pairs)
    }

    /// The pairs pinned as one in a row sync brought, by where each half
    /// stands among its pins (`unfolded`'s pins), for the shared pins' file.
    nonisolated static func pinPairs(_ shape: Session.Shape) -> [Session.Pair] {
        let pinned = shape.tabs.indices.filter { shape.tabs[$0].pin != nil }
        let at = Dictionary(uniqueKeysWithValues: pinned.enumerated().map { ($1, $0) })
        return (shape.pairs ?? []).compactMap { pair in
            guard let a = at[pair.first], let b = at[pair.second] else { return nil }
            return Session.Pair(first: a, second: b, share: pair.share)
        }
    }

    /// The first space's row as sync brings it, apart again: its pins for
    /// the shared row, the rest for the space, which says by a place below
    /// zero that it was left on one of the pins.
    nonisolated static func unfolded(_ shape: Session.Shape) -> (pins: [Session.Entry], rest: Session.Shape) {
        let pinned = shape.tabs.indices.filter { shape.tabs[$0].pin != nil }
        let loose = shape.tabs.indices.filter { shape.tabs[$0].pin == nil }
        let at = Dictionary(uniqueKeysWithValues: loose.enumerated().map { ($1, $0) })
        let front = shape.front.flatMap { front in pinned.firstIndex(of: front).map { -1 - $0 } ?? at[front] }
        let pairs = (shape.pairs ?? []).compactMap { pair -> Session.Pair? in
            guard let a = at[pair.first], let b = at[pair.second] else { return nil }
            return Session.Pair(first: a, second: b, share: pair.share)
        }
        return (pinned.map { shape.tabs[$0] }, Session.Shape(tabs: loose.map { shape.tabs[$0] }, front: front, pairs: pairs.isEmpty ? nil : pairs))
    }

    /// The first space's row with the shared pins folded in (`folded`), or
    /// any other space's file as it is: what sync reads and compares.
    /// Folded only while they head the first space here (`pinsShown`,
    /// `on`): pins a Mac doesn't show there, sent as its, stayed on every
    /// other device while gone from this one, and came back to be taken
    /// out of it (#909).
    nonisolated static func syncRow(_ space: UUID, pinsShown: Bool) -> Session.Shape {
        let row = Session.read(space: space)
        guard space == Space.firstID, pinsShown else { return row }
        let pins = Session.read(space: Space.pinsID)
        return folded(pins.tabs, into: row, pinPairs: pins.pairs)
    }

    /// Whether sync sends the shared pins as the first space's: while they
    /// head it (`on`). With no window open, any left over go to the first
    /// space now (`PinsHandBack`), so they are sent as its, where they show.
    static var sentAsFirst: Bool {
        if on { return true }
        if BrowserWindows.shared.normalBrowsers.isEmpty {
            let spaces = Spaces.read()
            if let home = spaces.first(where: \.isFirst)?.id ?? spaces.first?.id { PinsHandBack.run(to: home) }
        }
        return false
    }

    /// What every window's pins have to agree on: which pin, its letter,
    /// its name and its icon. Where each window's tab has gone since is its
    /// own.
    struct Mark: Equatable {
        var key: String?
        var pin: String?
        var name: String?
        var customMark: String?
        var pair: PairMark?

        init(_ entry: Session.Entry) {
            key = entry.id
            pin = entry.pin
            name = entry.name
            customMark = entry.customMark
        }
    }

    struct PairMark: Equatable {
        var first: String?
        var second: String?
        var share: Double
    }

    /// Pair membership and its divider are shared metadata too. A pair can
    /// change without changing either entry (Separate, or the divider).
    static func marks(_ entries: [Session.Entry], pairs: [Session.Pair]) -> [Mark] {
        var marks = entries.map(Mark.init)
        for pair in pairs where entries.indices.contains(pair.first) && entries.indices.contains(pair.second) {
            let mark = PairMark(first: entries[pair.first].id, second: entries[pair.second].id, share: pair.share)
            marks[pair.first].pair = mark
            marks[pair.second].pair = mark
        }
        return marks
    }

    /// The shared pins as last written or followed, in any window: a write
    /// that says the same tells nobody.
    static var known: [Mark]?

    /// A pin of a space as it would be shared: its entry, and whether it is
    /// busy, a call in it or an agent at work there, and so never left out
    /// as a duplicate.
    struct Candidate {
        var entry: Session.Entry
        var busy = false
    }

    /// Every window, the first one first, and the one asking if it isn't
    /// among them (a test's).
    static func windows(with browser: Browser) -> [Browser] {
        guard browser.windowPurpose == .normal else { return [] }
        var all = BrowserWindows.shared.normalBrowsers.sorted { ($0.windowID == nil ? 0 : 1) < ($1.windowID == nil ? 0 : 1) }
        if !all.contains(where: { $0 === browser }) { all.insert(browser, at: browser.windowID == nil ? 0 : all.count) }
        return all
    }

    /// In Every Space turned on or off, for these windows together. On:
    /// every window's pins of the spaces that share sign-ins become one row
    /// (`merge`), the first window's first and in each window the spaces in
    /// their order. Off: each window's shared pins become pins of the space
    /// on screen, or of the first space when one with sign-ins of its own,
    /// Mail is on screen (`heir`).
    static func turn(_ on: Bool, in browsers: [Browser], spacesOn: Bool) {
        let turning = browsers.filter { $0.pinsShared != on }
        guard !turning.isEmpty else { return }
        // The windows turn one after another: none follows another's
        // kept and pins half way (KeptEverywhere.swift); the lists are
        // compared afresh from the next row written.
        KeptEverywhere.quiet += 1
        defer {
            KeptEverywhere.quiet -= 1
            KeptEverywhere.known = [:]
        }
        if on {
            let rows = turning.flatMap { $0.pinsToShare() }
            let list = merge(rows) { $0.busy ? nil : $0.entry.url }.kept.map(\.entry)
            known = list.map(Mark.init)
            Session.write(now: true, space: Space.pinsID, .init(tabs: list, active: 0))
            for browser in turning { browser.sharePins(list) }
        } else {
            for browser in turning { browser.unsharePins(spacesOn: spacesOn) }
            known = nil
            Session.write(now: true, space: Space.pinsID, .init(tabs: [], active: 0))
        }
    }
}

extension Browser {
    /// Whether a space shows the shared pins: one that signs in where the
    /// first one does, while they are shared. Never Mail's.
    func showsShared(_ id: UUID) -> Bool {
        guard pinsShared, !blank, id != Space.mailID, id != Space.pinsID else { return false }
        return spaces.first { $0.id == id }.map { !$0.ownSignIns } ?? false
    }

    /// The shared pins in their order, wherever they are: the head of the
    /// row on screen while a space that shows them is, aside while another
    /// is, with any a call or an agent took along. Nil when they were never
    /// read in, a space of its own on screen since launch.
    var sharedPins: [Tab]? {
        let here = tabs.filter { $0.everywhere != nil }
        if showsShared(spaceID) { return here }
        guard let aside = parked[Space.pinsID] else { return here.isEmpty ? nil : here }
        let along = here.filter { tab in !aside.tabs.contains { $0 === tab } }
        return SharedPins.ordered(aside.tabs + along, id: \.id, by: aside.order)
    }

    /// The shared pins to their file. Also what writing the row on screen
    /// does whenever any of them is in it.
    func writePins(now: Bool = false) {
        guard pinsShared, let pins = sharedPins else { return }
        // A pair pinned as one goes with them (PinPairs.swift).
        writeRow(pins, active: nil, space: Space.pinsID, pairs: pinPairs(among: pins), now: now)
    }

    /// The shared pins just written: every other window follows, if what
    /// they are changed, at once, before one of them can write the list it
    /// had over this one. Only windows on screen are told; a test's browser
    /// is no window.
    func toldPins(_ entries: [Session.Entry], pairs: [Session.Pair]) {
        let marks = SharedPins.marks(entries, pairs: pairs)
        guard marks != SharedPins.known else { return }
        SharedPins.known = marks
        let windows = BrowserWindows.shared.normalBrowsers
        guard windows.contains(where: { $0 === self }) else { return }
        for other in windows where other !== self && other.pinsShared { other.followPins(entries, pairs: pairs) }
    }

    /// The pins in a row being written as they are now, whatever pinned or
    /// unpinned them (a menu, sync, Undo): unpinned, a tab is no shared pin;
    /// pinned in the row on screen of a space that shows them, it is one.
    /// A pin a call or an agent brought along from a space of its own stays
    /// that space's.
    func settleShared(_ row: [Tab], in space: UUID) {
        for tab in row where tab.everywhere != nil && tab.pin == nil { tab.everywhere = nil }
        guard space == spaceID, showsShared(space), row.count == tabs.count, row.elementsEqual(tabs, by: { $0 === $1 }) else { return }
        for tab in row where tab.pin != nil && tab.everywhere == nil && Browser.sharable(tab) && !travels(tab) { tab.everywhere = tab.id }
    }

    /// The place below zero a row's file keeps for a row left on a shared
    /// pin, the first of them -1.
    func sharedFront(_ id: Tab.ID?) -> Int? {
        guard let id, let at = sharedPins?.firstIndex(where: { $0.id == id }) else { return nil }
        return -1 - at
    }

    /// Whether a pin can be one of the shared ones: never a private tab,
    /// which keeps nothing and is no other window's, nor Yab's own work out
    /// of sight (the bench), nor a page signed in as a space of its own is,
    /// one a call brought along: each stays a pin of the space it is in.
    static func sharable(_ tab: Tab) -> Bool {
        !tab.bench && !tab.shy && !Spaces.madeStores.values.contains { $0 === tab.store }
    }

    /// The address a pin is compared by.
    static func pinAddress(_ tab: Tab) -> String? {
        (tab.pending ?? tab.address)?.absoluteString
    }

    /// A shared pin made here, asleep, for one another window or sync has.
    func madePin(_ entry: Session.Entry, key: UUID) -> Tab? {
        guard let url = URL(string: entry.url) else { return nil }
        let tab = Tab(id: Tab.returning(entry.id), configuration: Web.configuration(store: Spaces.store(for: Space.pinsID)), engine: entry.engineKind)
        prepare(tab)
        tab.restore(url: url, title: entry.title)
        tab.pin = entry.pin ?? Tab.monogram(for: url)
        tab.name = entry.name
        tab.customMark = entry.customMark
        tab.visits = entry.visits ?? 0
        if let seen = entry.seen { tab.touch(at: Date(timeIntervalSince1970: seen)) }
        tab.arrive(at: entry.depth)
        tab.everywhere = key
        tab.takeHome(entry)
        return tab
    }

    // MARK: switching

    /// A row coming on screen in a space that shows the shared pins, with
    /// them at its head: those `along` from the row it was, those put aside,
    /// or their file if they were never read in. A pin the row had of its
    /// own (sync brought it, a move from a space of its own) joins them,
    /// after them, unless one at its address is there already, and a row
    /// left on a shared pin comes back on it.
    func joinShared(_ back: Parked, along: [Tab], fromShowing: Bool, alongPairs: [Pair] = []) -> Parked {
        var shared = along
        // Pairs pinned as one among them (PinPairs.swift): those that came
        // along, and those put aside or read with them.
        var sharedPairs = alongPairs
        if !fromShowing {
            if let aside = parked.removeValue(forKey: Space.pinsID) {
                shared = SharedPins.ordered(aside.tabs + along, id: \.id, by: aside.order)
                sharedPairs += aside.pairs
            } else {
                let loaded = loadRow(Space.pinsID)
                shared = loaded.tabs + along
                sharedPairs += loaded.pairs
            }
        }
        let stray = back.tabs.filter { $0.pin != nil && $0.everywhere == nil && Browser.sharable($0) && !travels($0) }
        var front = back.active
        if !stray.isEmpty {
            let merged = SharedPins.merge([shared, stray]) { tab in self.travels(tab) ? nil : Browser.pinAddress(tab) }
            for tab in merged.kept where tab.everywhere == nil { tab.everywhere = tab.id }
            for tab in merged.dropped {
                if front == tab.id { front = merged.kept.first { Browser.pinAddress($0) == Browser.pinAddress(tab) }?.id }
                tab.close()
            }
            shared = merged.kept
            // Written once the row is on screen.
            rememberSession()
        }
        var row = back
        row.tabs = shared + back.tabs.filter { tab in !stray.contains { $0 === tab } }
        let ids = Set(row.tabs.map(\.id))
        let paired = Set(back.pairs.flatMap { [$0.first, $0.second] })
        row.pairs = back.pairs + sharedPairs.filter { ids.contains($0.first) && ids.contains($0.second) && !paired.contains($0.first) && !paired.contains($0.second) }
        if let at = back.sharedFront, front == nil || !row.tabs.contains(where: { $0.id == front }), shared.indices.contains(at) {
            front = shared[at].id
        }
        row.active = front
        row.sharedFront = nil
        return row
    }

    /// The shared pins put aside while a space that doesn't show them is on
    /// screen, in `order`, the order they all stand in, any gone along with
    /// a call keeping its place among them.
    func parkShared(_ aside: [Tab], order: [Tab.ID]?, leaving: UUID?, pairs going: [Pair] = []) {
        let kept = parked[Space.pinsID]?.tabs ?? []
        let keptPairs = parked[Space.pinsID]?.pairs ?? []
        parked[Space.pinsID] = Parked(tabs: SharedPins.ordered(kept + aside, id: \.id, by: order), active: nil,
                                      pairs: keptPairs + going, order: order)
        if let leaving { sharedLeft = leaving }
    }

    /// A parked row as a switch will lay it, for the pictures of a space
    /// coming (SpacePager, the strip): the shared pins at its head in a
    /// space that shows them, parked apart from it, and the one in front
    /// if it was left on one. Those that go with you are drawn as such.
    func withShared(_ row: Parked, in id: UUID) -> Parked {
        guard showsShared(id), let pins = sharedPins?.filter({ !travels($0) }), !pins.isEmpty else { return row }
        var shown = row
        if shown.active == nil, let at = row.sharedFront, pins.indices.contains(at) { shown.active = pins[at].id }
        shown.tabs = pins + row.tabs
        return shown
    }

    /// The space to go to for a tab of a row not on screen: the one it is
    /// parked in, or for a shared pin put aside, the space last left with
    /// them on screen, else the first that shows them.
    func spaceHolding(_ id: Tab.ID) -> UUID? {
        guard let key = parked.first(where: { $0.value.tabs.contains { $0.id == id } })?.key else { return nil }
        guard key == Space.pinsID else { return key }
        if let left = sharedLeft, showsShared(left) { return left }
        return spaces.first { showsShared($0.id) }?.id
    }

    // MARK: turning it on and off

    /// The pins as Settings says: shared or not, in every window at once.
    /// `spaces` and `every` are the values about to be set, when a setting
    /// is changing. Spaces on or off as last written, by whichever window:
    /// another window's own may be older (only Pins is handed to every
    /// window), and a window that still thought spaces off would take the
    /// pins back from all of them.
    func settlePins(spaces: Bool? = nil, every: Bool? = nil) {
        guard windowPurpose == .normal else { return }
        let on = spaces ?? Store.settings.bool(forKey: "spaces")
        let wanted = on && (every ?? prefs.pinsEverySpace)
        guard wanted != pinsShared else { return }
        SharedPins.turn(wanted, in: SharedPins.windows(with: self), spacesOn: on)
    }

    /// This window's pins of the spaces that share sign-ins, a row a space
    /// in the spaces' order: live where the row is open, its file's where
    /// it isn't.
    func pinsToShare() -> [[SharedPins.Candidate]] {
        spaces.filter { !$0.ownSignIns }.map { space in
            if let row = space.id == spaceID ? tabs : parked[space.id]?.tabs {
                return row.filter { $0.pin != nil && Browser.sharable($0) }.compactMap { tab in
                    sessionEntry(tab, id: tab.everywhere ?? tab.id).map { SharedPins.Candidate(entry: $0, busy: travels(tab)) }
                }
            }
            return Session.read(space: space.id, window: windowID).tabs.filter { $0.pin != nil }.map { entry in
                var entry = entry
                if entry.id.flatMap(UUID.init(uuidString:)) == nil { entry.id = UUID().uuidString }
                return SharedPins.Candidate(entry: entry)
            }
        }
    }

    /// In Every Space turned on: this window's pins of the spaces that share
    /// sign-ins out of their rows, and `list`, every window's as one, at the
    /// head of the row on screen if it shows them, put aside if not. This
    /// window's own tab for a pin where it has one, by key, then by address;
    /// one made asleep where it hasn't; one at an address already there
    /// closed, the one on screen giving way to the pin kept at its address.
    func sharePins(_ list: [Session.Entry]) {
        settleNow()
        var pool: [Tab] = []
        for space in spaces where !space.ownSignIns {
            if space.id == spaceID {
                pool += tabs.filter { $0.pin != nil && Browser.sharable($0) }
            } else if var row = parked[space.id] {
                let pins = row.tabs.filter { $0.pin != nil && Browser.sharable($0) }
                guard !pins.isEmpty else { continue }
                row.tabs.removeAll { tab in pins.contains { $0 === tab } }
                parked[space.id] = row
                writeRow(row.tabs, active: row.active, space: space.id, pairs: row.pairs, now: true)
                pool += pins
            } else {
                let file = Session.read(space: space.id, window: windowID)
                if file.tabs.contains(where: { $0.pin != nil }) {
                    Session.write(now: true, space: space.id, window: windowID, SharedPins.unpinned(file))
                }
            }
        }
        pinsShared = true
        var left = pool
        let shared: [Tab] = list.compactMap { entry in
            let key = entry.id.flatMap(UUID.init(uuidString:)) ?? UUID()
            if let at = left.firstIndex(where: { $0.id == key }) ?? left.firstIndex(where: { Browser.pinAddress($0) == entry.url }) {
                let tab = left.remove(at: at)
                tab.everywhere = key
                if let letter = entry.pin, tab.pin != letter { tab.pin = letter }
                return tab
            }
            return madePin(entry, key: key)
        }
        // A row left on a pin closed here comes back on the one kept at its
        // address.
        let kept = { (id: Tab.ID?) -> Tab.ID? in
            guard let gone = left.first(where: { $0.id == id }) else { return id }
            return shared.first { Browser.pinAddress($0) == Browser.pinAddress(gone) }?.id
        }
        for (space, row) in parked where left.contains(where: { $0.id == row.active }) { parked[space]?.active = kept(row.active) }
        if showsShared(spaceID) {
            let replaced = left.contains { $0.id == activeID } ? kept(activeID).flatMap { id in shared.first { $0.id == id } } : nil
            lay(shared + tabs.filter { tab in !pool.contains { $0 === tab } })
            if let replaced { select(replaced) }
        } else {
            parked[Space.pinsID] = Parked(tabs: shared, active: nil)
        }
        for tab in left { tab.close() }
        writeSession(now: true)
    }

    /// In Every Space turned off: the shared pins become pins of the space
    /// on screen if it showed them, of the first space if not (`heir`). One
    /// a call or an agent took along stays a pin of the row it is in.
    func unsharePins(spacesOn: Bool) {
        settleNow()
        let heir = SharedPins.heir(onScreen: spaceID, showing: showsShared(spaceID), spacesOn: spacesOn, home: homeSpaceID)
        let pins = sharedPins ?? loadRow(Space.pinsID).tabs
        let keys = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0.everywhere ?? KeptEverywhere.key($0)) })
        pinsShared = false
        parked[Space.pinsID] = nil
        for tab in pins { tab.everywhere = nil }
        let leaving = pins.filter { tab in !(travels(tab) && tabs.contains { $0 === tab }) }
        var nests: [String: Nest] = [:]
        // If Personal is gone, the heir may have imported sign-ins of its
        // own. Reopen its pins in that store, just as Move to Space does.
        let going = leaving.map { tab -> Tab in
            guard tab.store !== Spaces.store(for: heir),
                  let entry = sessionEntry(tab, id: keys[tab.id] ?? KeptEverywhere.key(tab)),
                  let copy = keptCopy(entry, space: heir) else { return tab }
            takeKept(entry, into: copy, nests: &nests)
            return copy
        }
        if heir == spaceID {
            lay(going + tabs.filter { tab in !leaving.contains { $0 === tab } })
        } else {
            if tabs.contains(where: { tab in leaving.contains { $0 === tab } }) {
                let wasFront = leaving.contains { $0.id == activeID }
                lay(tabs.filter { tab in !leaving.contains { $0 === tab } })
                if wasFront {
                    if let next = tabs.first(where: { !$0.bench }) { select(next) } else { activeID = nil; askNew() }
                }
            }
            var row = parked[heir] ?? loadRow(heir)
            row.tabs = going + row.tabs
            parked[heir] = row
            writeRow(row.tabs, active: row.active, space: heir, pairs: row.pairs, now: true)
        }
        for (old, replacement) in zip(leaving, going) where old !== replacement { old.close() }
        writeSession(now: true)
    }

    /// Another window changed the shared pins (or sync brought them): the
    /// same list here, each pin this window has already kept as it is, with
    /// the list's letter, name and icon, one it hasn't made asleep, one gone
    /// closed. `addresses`: from sync, where a pin asleep, and not on screen,
    /// takes the address another device left it on, as a space's tabs do.
    func followPins(_ entries: [Session.Entry], pairs savedPairs: [Session.Pair] = [], addresses: Bool = false) {
        guard windowPurpose == .normal, pinsShared else { return }
        guard let mine = sharedPins else {
            // Never read in here: their file is them. Another window wrote
            // it already; what sync brought is written now.
            if addresses { Session.write(now: true, space: Space.pinsID, .init(tabs: entries, active: 0, pairs: savedPairs.isEmpty ? nil : savedPairs)) }
            return
        }
        SharedPins.known = SharedPins.marks(entries, pairs: savedPairs)
        var byKey = Dictionary(mine.compactMap { tab in tab.everywhere.map { ($0, tab) } }, uniquingKeysWith: { a, _ in a })
        var next: [Tab] = []
        for entry in entries {
            guard let key = entry.id.flatMap(UUID.init(uuidString:)) else { continue }
            if let tab = byKey.removeValue(forKey: key) {
                if tab.pin != entry.pin, let letter = entry.pin { tab.pin = letter }
                if tab.name != entry.name { tab.name = entry.name }
                if tab.customMark != entry.customMark { tab.customMark = entry.customMark }
                tab.takeHome(entry)
                if addresses, tab.asleep, tab.id != activeID, let url = URL(string: entry.url), tab.pending != url {
                    tab.restore(url: url, title: entry.title)
                }
                next.append(tab)
            } else if let made = madePin(entry, key: key) {
                next.append(made)
            }
        }
        let byEntry = Dictionary(next.compactMap { tab in tab.everywhere.map { ($0, tab.id) } },
                                 uniquingKeysWith: { first, _ in first })
        let made = Dictionary(uniqueKeysWithValues: entries.enumerated().compactMap { index, entry in
            entry.id.flatMap(UUID.init(uuidString:)).flatMap { byEntry[$0] }.map { (index, $0) }
        })
        let restored = Pair.restore(savedPairs, made: made)
        let sharedIDs = Set(mine.map(\.id) + next.map(\.id))
        let pairedIDs = Set(restored.flatMap { [$0.first, $0.second] })
        // Replace the shared pins' pairs, including an explicit separation;
        // leave this window's other splits alone.
        let retained = pairs.filter {
            !(sharedIDs.contains($0.first) && sharedIDs.contains($0.second))
                && !pairedIDs.contains($0.first) && !pairedIDs.contains($0.second)
        }
        // Gone elsewhere: closed here, but a call or an agent's work in one
        // stays, a tab of the row it is in.
        for tab in byKey.values {
            tab.everywhere = nil
            tab.pin = nil
            if travels(tab) { continue }
            if tabs.contains(where: { $0 === tab }) { close(tab) } else {
                parked[Space.pinsID]?.tabs.removeAll { $0 === tab }
                tab.close()
            }
        }
        if showsShared(spaceID) {
            lay(next + tabs.filter { $0.everywhere == nil })
            pairs = retained + restored
        } else {
            let here = Set(tabs.map(\.id))
            pairs = retained + restored.filter { here.contains($0.first) && here.contains($0.second) }
            parked[Space.pinsID] = Parked(tabs: next.filter { tab in !tabs.contains { $0 === tab } }, active: nil,
                                         pairs: restored.filter { !here.contains($0.first) || !here.contains($0.second) }, order: next.map(\.id))
        }
        writeSession(now: true)
    }
}
