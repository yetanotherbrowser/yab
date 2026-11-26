import AppKit
import SwiftUI

// Another browser's places, laid into yab (TabImport reads them). Each
// place goes to one space: the one it came from last time (Space.origin),
// else one of its name, else, for a browser's first profile, Personal,
// else a new one, after the others, in the browser's order, wearing the
// place's emoji and color, or what its name suggests, and signed in as the
// place is: the shared sign-ins for the browser's first profile, its own
// otherwise, with that profile's cookies when sign-ins are brought too.
//
// One place, never brought in before, and there is nothing to lay out: it
// goes into the row on screen. Spaces off, each place is a folder of
// bookmarks instead, "Arc › Work", unless the one bringing them in turns
// spaces on.
//
// Pins go after the pins there, up to nine in the space; the rest, and
// the tabs it keeps, and what it has open if wanted, at the end of the
// row, all asleep: nothing loads until it is opened. A page there already,
// or brought in before and taken out since, doesn't come (Space.brought).

extension Browser {
    /// Where a place is going, said before it goes.
    enum Landing: Equatable {
        /// The row on screen: the only place brought.
        case row
        case space(UUID)
        case new
        /// Spaces off: a folder of bookmarks.
        case bookmarks
    }

    /// `among`: every place being brought, the one alone goes into the row.
    func landing(of place: TabImport.Place, among places: [TabImport.Place], asSpaces: Bool) -> Landing {
        // Brought in before: where it went then, whatever it's called now.
        if let known = spaces.first(where: { $0.origin == place.id }) { return .space(known.id) }
        if places.count == 1 {
            if place.shared, !space.ownSignIns { return .row }
            // A separate source profile must keep a separate cookie store.
            return .new
        }
        guard prefs.usesSpaces || asSpaces else { return .bookmarks }
        // A space of its name, if that space came from nowhere and is
        // signed in the way the place is: two of Arc's spaces of one name,
        // or a profile's "Work" and your shared one, stay apart.
        // A space signed in as some other profile, Arc's "Work" when Dia's
        // comes, is not this one's, or its pages would open as that profile.
        if let named = spaces.first(where: {
            $0.origin == nil && $0.name.lowercased() == place.name.lowercased() && $0.ownSignIns != place.shared
                && (place.shared || $0.signedInAs == nil || $0.signedInAs == place.signIn)
        }) { return .space(named.id) }
        // A browser's first profile is how you were signed in, which is
        // what yab's first space is.
        if place.isProfile, place.shared, spaces.contains(where: \.isFirst) { return .space(Space.firstID) }
        return .new
    }

    /// "into Personal", "new space", as the list of places says it.
    func landingWords(of place: TabImport.Place, among places: [TabImport.Place], asSpaces: Bool) -> String {
        switch landing(of: place, among: places, asSpaces: asSpaces) {
        case .row: return "into \(space.name)"
        case .space(let id): return "into \(spaces.first { $0.id == id }?.name ?? "a space")"
        case .new: return place.shared ? "new space" : "new space, its own sign-ins"
        case .bookmarks: return "as bookmarks"
        }
    }

    /// The places picked, each where `landing` says. `asSpaces`: turn
    /// spaces on for them when they're off. `signIns`: each space signed
    /// in as a profile of its own, made now or found, takes that profile's
    /// cookies, those it hasn't set already (`signsIn`). Says what came.
    @discardableResult
    func bring(_ places: [TabImport.Place], withOpen: Bool, asSpaces: Bool, signIns: Bool,
               from source: Chromium.Source) -> (spaces: Int, pinned: Int, open: Int, marked: Int) {
        // Only open tabs, and those not wanted: nothing to make a space of,
        // unless it is a profile of its own, whose space has its sign-ins.
        let places = places.filter { $0.comes(withOpen: withOpen) }
        guard !places.isEmpty else { return (0, 0, 0, 0) }
        KeptEverywhere.broughtIn(from: source, into: prefs)
        if places.count > 1, asSpaces, !prefs.usesSpaces { prefs.usesSpaces = true }
        if places.count == 1, places.first?.shared == false, !prefs.usesSpaces { prefs.usesSpaces = true }
        var made = 0, pinned = 0, open = 0, marked = 0
        var ownProfiles: Set<String> = []
        for place in places {
            let target: UUID
            switch landing(of: place, among: places, asSpaces: asSpaces) {
            case .row:
                target = spaceID
                if let at = spaces.firstIndex(where: { $0.id == spaceID }), spaces[at].origin == nil {
                    spaces[at].origin = place.id
                }
            case .space(let id):
                target = id
                // Found by name, or as the first profile: found by where
                // it came from from now on.
                if let at = spaces.firstIndex(where: { $0.id == id }), spaces[at].origin == nil {
                    spaces[at].origin = place.id
                    if !place.shared, spaces[at].signedInAs == nil { spaces[at].signedInAs = "\(source.name):\(place.profile)" }
                }
                if signsIn(id, as: place, from: source) { ownProfiles.insert(place.profile) }
            case .new:
                target = makeSpace(for: place, from: source)
                made += 1
                if !place.shared { ownProfiles.insert(place.profile) }
            case .bookmarks:
                marked += bookmark(place, withOpen: withOpen, from: source)
                continue
            }
            let took = lay(place.pinned, kept: place.kept, open: withOpen ? place.open : [], into: target)
            adopt(place.splits, into: target)
            pinned += took.pinned
            open += took.open
        }
        Spaces.write(spaces)
        writeSession(now: true)
        // The spaces with sign-ins of their own, signed in as their
        // profiles were; a sign-in made here since stays.
        if signIns, !ownProfiles.isEmpty { takeCookies(from: source, only: ownProfiles, keeping: true) { _ in } }

        var said: [String] = []
        if made > 0 { said.append(made == 1 ? "1 space" : "\(made) spaces") }
        said.append(pinned == 1 ? "1 pin" : "\(pinned) pins")
        if open > 0 { said.append(open == 1 ? "1 tab" : "\(open) tabs") }
        if marked > 0 { said.append("\(marked) bookmarked") }
        // Under the welcome, its own corner says it once it is all in.
        if !welcoming {
            announce("From \(source.name): " + said.joined(separator: ", "), mark: "tray.and.arrow.down",
                     feedback: made + pinned + open + marked > 0 ? .success : nil)
        }

        let urls = places.flatMap { $0.pinned + $0.kept + (withOpen ? $0.open : []) }.map(\.url)
        DispatchQueue.global(qos: .utility).async {
            let icons = Chromium.icons(in: source, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return (made, pinned, open, marked)
    }

    /// An agent's tabs for you (lay_out_tabs): each place into the space of
    /// its name, or a new one after the others signed in as your first
    /// space is, or, unnamed, the row on screen; laid as a browser's are
    /// brought in, asleep, pins, kept rows in their folders, and the rest
    /// at the end. Opened one by one, an agent's own tabs were 60 pages
    /// loaded at once that it could neither pin nor put in a folder
    /// (feedback #131). Says, for each place, where it went and what came.
    func layOut(_ places: [TabImport.Place]) -> [(space: String, pinned: Int, tabs: Int, skipped: Int)] {
        var out: [(String, Int, Int, Int)] = []
        var made = false
        for place in places {
            let target: UUID
            if place.name.isEmpty {
                target = spaceID
            } else if let found = spaces.first(where: { $0.name.lowercased() == place.name.lowercased() }) {
                target = found.id
            } else {
                target = makeSpace(for: place, from: nil)
                made = true
            }
            let took = lay(place.pinned, kept: place.kept, open: place.open, into: target)
            let asked = place.pinned.count + place.kept.count + place.open.count
            out.append((spaces.first { $0.id == target }?.name ?? place.name, took.pinned, took.open, asked - took.pinned - took.open))
        }
        if made, !prefs.usesSpaces { prefs.usesSpaces = true }
        Spaces.write(spaces)
        writeSession(now: true)
        return out
    }

    /// The space a place lands in keeps that place's profile's sign-ins:
    /// its own, and signed in as that profile there, never the shared ones.
    func signsIn(_ id: UUID, as place: TabImport.Place, from source: Chromium.Source) -> Bool {
        guard !place.shared, let space = spaces.first(where: { $0.id == id }) else { return false }
        return space.ownSignIns && space.signedInAs == "\(source.name):\(place.profile)"
    }

    /// A new space for a place, after the others, not switched to.
    private func makeSpace(for place: TabImport.Place, from source: Chromium.Source?) -> UUID {
        let guess = SpaceDraft.guess(place.name)
        let paint = place.paint(prefs) ?? SpacePaint(swatch: guess.swatch, color: prefs.backdropColor, grain: prefs.grain)
        var made = Space(id: UUID(), name: place.name, icon: place.emoji ?? guess.icon ?? freeIcon, ownSignIns: !place.shared, paint: paint)
        made.origin = place.id
        if !place.shared, let source {
            let identity = "\(source.name):\(place.profile)"
            made.signedInAs = identity
            // A second space of that profile signs in with the first, as
            // the two do there (row 1752).
            if let first = spaces.first(where: { $0.ownSignIns && $0.signedInAs == identity }) {
                made.signInWith = Spaces.signIn(of: first.id)
                Spaces.joining(made.id, with: Spaces.signIn(of: first.id))
            }
        }
        spaces.append(made)
        if place.shared { Spaces.sharing.insert(made.id) }
        return made.id
    }

    /// Default signs the shared space in. Other profiles always use their
    /// own stores; otherwise the last imported account replaces the first.
    /// Every profile's sign-ins, by profile folder, each to the stores
    /// `cookieSpaces` says: a profile's cookies never reach another's store.
    func cookieWork(_ found: [String: [HTTPCookie]], names: [String: String], from source: Chromium.Source) -> [(UUID?, [HTTPCookie])] {
        var reads: [(UUID?, [HTTPCookie])] = []
        for (folder, cookies) in found.sorted(by: { $0.key < $1.key }) where !cookies.isEmpty {
            for target in cookieSpaces(for: folder, name: names[folder], from: source) {
                reads.append((target, cookies))
            }
        }
        return reads
    }

    /// A space for each of the browser's profiles past its first that has
    /// none yet, signed in as that profile, even one with no tabs or
    /// sign-ins to bring: two profiles there are two spaces here. Only the
    /// profiles the browser lists (Local State), so Chrome's Guest and
    /// System folders don't count. Hands back how many were made.
    @discardableResult
    func profileSpaces(from source: Chromium.Source) -> Int {
        let names = TabImport.profileNames(in: source)
        let folders = source.profiles.map(\.lastPathComponent).filter {
            !["Default", "Guest Profile", "System Profile"].contains($0) && (names.isEmpty || names[$0] != nil)
        }
        let before = spaces.count
        for folder in folders { _ = cookieSpaces(for: folder, name: names[folder], from: source) }
        return spaces.count - before
    }

    /// Use the same profile identity as tab and cookie import, regardless
    /// of the Space's current name or the order import categories run in.
    @discardableResult
    func takeProfileBookmarks(_ nodes: [Bookmark], profile: String, name: String, from source: Chromium.Source) -> Int {
        let key = "\(source.name):\(profile)"
        let target: UUID
        if let existing = spaces.first(where: { $0.origin == key || $0.signedInAs == key }) {
            target = existing.id
        } else if profile == "Default" {
            target = spaces.first(where: \.isFirst)?.id ?? spaceID
            if let at = spaces.firstIndex(where: { $0.id == target }), spaces[at].origin == nil {
                spaces[at].origin = key
            }
        } else {
            target = cookieSpaces(for: profile, name: name, from: source).compactMap { $0 }.first!
        }
        Spaces.write(spaces)
        return bookmarks.takeProfile(nodes, key: key, name: "\(source.name) › \(name)", space: target)
    }

    func cookieSpaces(for profile: String, name: String?, from source: Chromium.Source) -> [UUID?] {
        let identity = "\(source.name):\(profile)"
        let existing = spaces.filter { $0.ownSignIns && $0.signedInAs == identity }.map(\.id)
        if !existing.isEmpty {
            // One store for the spaces that sign in together.
            var seen = Set<UUID>()
            return existing.map(Spaces.signIn(of:)).filter { seen.insert($0).inserted }.map { Optional($0) }
        }
        if profile == "Default" { return [nil] }
        let place = TabImport.Place(id: identity, name: "\(source.name) › \(name ?? profile)",
                                    profile: profile, shared: false, isProfile: true, pinned: [], open: [])
        let id = makeSpace(for: place, from: source)
        prefs.usesSpaces = true
        Spaces.write(spaces)
        return [id]
    }

    /// The most pins a space is given by bringing in: a column shows nine
    /// in three short rows, as Arc's favorites do. Dia's and Arc's exports
    /// can hold a hundred; past nine they come as tabs that stay, kept.
    static let pinLimit = 9

    /// Between the names of a folder's path, when a path is a key: a
    /// character no name has.
    static let folderStep = "\u{1F}"

    /// Restore Arc's two-pane layouts only when both pages came across.
    /// Existing pairs keep their tabs; imports never replace them.
    private func adopt(_ splits: [TabImport.Split], into id: UUID) {
        guard !splits.isEmpty else { return }
        if id == spaceID || parked[id] != nil {
            var row = id == spaceID ? Parked(tabs: tabs, active: activeID, pairs: pairs) : parked[id]!
            var used = Set(row.pairs.flatMap { [$0.first, $0.second] })
            for split in splits {
                guard split.share.isFinite,
                      let a = row.tabs.first(where: { ($0.pending ?? $0.address).map(TabImport.key) == TabImport.key(split.first) }),
                      let b = row.tabs.first(where: { ($0.pending ?? $0.address).map(TabImport.key) == TabImport.key(split.second) }),
                      a.id != b.id, !used.contains(a.id), !used.contains(b.id) else { continue }
                row.pairs.append(Pair(first: a.id, second: b.id, share: min(Pair.most, max(Pair.least, CGFloat(split.share)))))
                used.formUnion([a.id, b.id])
            }
            if id == spaceID { pairs = row.pairs }
            else {
                parked[id] = row
                writeRow(row.tabs, active: row.active, space: id, pairs: row.pairs, now: true)
            }
        } else {
            var shape = Session.read(space: id, window: windowID)
            var pairs = shape.pairs ?? []
            var used = Set(pairs.flatMap { [$0.first, $0.second] })
            for split in splits {
                guard split.share.isFinite,
                      let a = shape.tabs.firstIndex(where: { URL(string: $0.url).map(TabImport.key) == TabImport.key(split.first) }),
                      let b = shape.tabs.firstIndex(where: { URL(string: $0.url).map(TabImport.key) == TabImport.key(split.second) }),
                      a != b, !used.contains(a), !used.contains(b) else { continue }
                pairs.append(Session.Pair(first: a, second: b, share: min(0.75, max(0.25, split.share))))
                used.formUnion([a, b])
            }
            shape.pairs = pairs
            Session.write(now: true, space: id, window: windowID, shape)
        }
    }

    /// Pins, tabs kept above the line in their folders (Kept.swift), and
    /// what was open at the end of the row, into a space's row: the one on
    /// screen, a parked one, or the file of one not opened since launch,
    /// which takes lines, not tabs, so bringing in makes no web view for a
    /// space nobody is looking at.
    func lay(_ pins: [TabImport.Entry], kept: [TabImport.Entry], open: [TabImport.Entry], into id: UUID) -> (pinned: Int, open: Int) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return (0, 0) }
        if showsShared(id), !pins.isEmpty {
            writePins(now: true)
            let savedPins = Session.read(space: Space.pinsID)
            var shared = savedPins.tabs
            let row = id == spaceID ? tabs : parked[id]?.tabs
            let urls = row.map { $0.compactMap { ($0.pending ?? $0.address).map(TabImport.key) } }
                ?? Session.read(space: id, window: windowID).tabs.compactMap { URL(string: $0.url).map(TabImport.key) }
            var have = Set(shared.compactMap { URL(string: $0.url).map(TabImport.key) }).union(urls)
            have.formUnion(Self.remembered(spaces[at].brought, of: pins, among: have))
            var added: [TabImport.Entry] = [], over: [TabImport.Entry] = []
            for entry in pins where have.insert(TabImport.key(entry.url)).inserted {
                if shared.count < Self.pinLimit {
                    shared.append(Session.Entry(url: entry.url.absoluteString, title: entry.title,
                                                pin: Tab.monogram(for: entry.url), name: entry.name, seen: nil, id: UUID().uuidString))
                    added.append(entry)
                } else { over.append(entry) }
            }
            if !added.isEmpty {
                Session.write(now: true, space: Space.pinsID, .init(tabs: shared, active: 0, pairs: savedPins.pairs))
                for window in SharedPins.windows(with: self) where window.pinsShared { window.followPins(shared, pairs: savedPins.pairs ?? []) }
            }
            // Overflow stays in its destination space, with its kept tabs.
            let rest = lay([], kept: over + kept, open: open, into: id)
            spaces[at].brought = Set(spaces[at].brought ?? []).union(added.map { TabImport.key($0.url) }).sorted()
            return (added.count, rest.open)
        }
        var brought = Set(spaces[at].brought ?? [])
        defer { spaces[at].brought = brought.sorted() }

        if id == spaceID || parked[id] != nil {
            var row = id == spaceID ? Parked(tabs: tabs, active: activeID, pairs: pairs) : parked[id]!
            var have = Set(row.tabs.compactMap { ($0.pending ?? $0.address).map(TabImport.key) })
            have.formUnion(Self.remembered(spaces[at].brought, of: pins + kept + open, among: have))
            func make(_ entry: TabImport.Entry) -> Tab? {
                let key = TabImport.key(entry.url)
                guard have.insert(key).inserted else { return nil }
                brought.insert(key)
                let tab = Tab(configuration: Web.configuration(store: Spaces.store(for: id)))
                prepare(tab)
                tab.restore(url: entry.url, title: entry.title)
                tab.name = entry.name
                return tab
            }
            // Pins up to nine in the space, those there already counted;
            // the rest are tabs that stay, kept, first among the rows brought.
            let room = max(0, Self.pinLimit - row.tabs.filter { $0.pin != nil }.count)
            let fresh = pins.compactMap(make)
            let madePins = Array(fresh.prefix(room))
            madePins.forEach { $0.pin = $0.monogram }
            // A folder of the other browser's is one of yours here, one for
            // each name, whatever it already holds; one in another, one for
            // each path of names, in the folder of the path above it.
            var nests: [String: Nest] = [:]
            for tab in row.tabs {
                for nest in tab.nest?.chain ?? [] {
                    let key = (nest.today ? "today:" : "") + nest.chain.map(\.name).joined(separator: Self.folderStep)
                    if nests[key] == nil { nests[key] = nest }
                }
            }
            let over = Array(fresh.dropFirst(room))
            var madeKept: [Tab] = over
            for entry in kept {
                guard let tab = make(entry) else { continue }
                if let name = entry.folder {
                    let names = entry.path ?? [name]
                    var above: Nest?
                    for depth in names.indices.prefix(Nest.deepest) {
                        let key = names[...depth].joined(separator: Self.folderStep)
                        let nest = nests[key] ?? Nest(name: names[depth], open: false)
                        if nests[key] == nil { nest.parent = above }
                        nests[key] = nest
                        above = nest
                    }
                    tab.nest = above
                }
                madeKept.append(tab)
            }
            madeKept.forEach { $0.kept = true }
            let madeOpen = open.compactMap { entry -> Tab? in
                guard let tab = make(entry) else { return nil }
                if let name = entry.folder {
                    let nest = nests["today:" + name] ?? Nest(name: name, open: false)
                    nest.fleeting = true
                    nests["today:" + name] = nest
                    tab.nest = nest
                }
                return tab
            }
            guard !madePins.isEmpty || !madeKept.isEmpty || !madeOpen.isEmpty else { return (0, 0) }
            let after = row.tabs.lastIndex { $0.pin != nil }.map { $0 + 1 } ?? 0
            row.tabs.insert(contentsOf: madePins, at: after)
            // Each folder's tabs after those already in it; the rest after
            // the kept already there.
            for tab in madeKept {
                let at = tab.nest.flatMap { nest in row.tabs.lastIndex { $0.nest?.within(nest.chain.first ?? nest) == true } }
                    ?? row.tabs.lastIndex { $0.pin != nil || $0.kept }
                row.tabs.insert(tab, at: at.map { $0 + 1 } ?? 0)
            }
            row.tabs.append(contentsOf: madeOpen)
            if id == spaceID {
                lay(row.tabs)
            } else {
                parked[id] = row
                writeRow(row.tabs, active: row.active, space: id, pairs: row.pairs, now: true)
            }
            return (madePins.count, madeKept.count + madeOpen.count)
        }

        var shape = Session.read(space: id, window: windowID)
        var have = Set(shape.tabs.compactMap { URL(string: $0.url).map(TabImport.key) })
        have.formUnion(Self.remembered(spaces[at].brought, of: pins + kept + open, among: have))
        func line(_ entry: TabImport.Entry) -> Session.Entry? {
            let key = TabImport.key(entry.url)
            guard have.insert(key).inserted else { return nil }
            brought.insert(key)
            return Session.Entry(url: entry.url.absoluteString, title: entry.title, pin: nil, name: entry.name, seen: nil)
        }
        let room = max(0, Self.pinLimit - shape.tabs.filter { $0.pin != nil }.count)
        let fresh = pins.compactMap(line)
        let madePins = fresh.prefix(room).map { entry -> Session.Entry in
            var pinned = entry
            pinned.pin = Tab.monogram(for: URL(string: entry.url))
            return pinned
        }
        // Kept, each in the folder of its name, one already in the file's
        // or a new one; one in another by its path of names, the folders
        // above it written as its path.
        var folders: [String: String] = [:]
        for entry in shape.tabs {
            if let id = entry.folder, let name = entry.folderName {
                let above = (entry.folderPath ?? []).map(\.name)
                for (at, step) in (entry.folderPath ?? []).enumerated() {
                    let key = above.prefix(at + 1).joined(separator: Self.folderStep)
                    if folders[key] == nil { folders[key] = step.id }
                }
                let key = (entry.folderToday == true ? "today:" : "") + (above + [name]).joined(separator: Self.folderStep)
                if folders[key] == nil { folders[key] = id }
            }
        }
        var madeKept = Array(fresh.dropFirst(room))
        for entry in kept {
            guard var made = line(entry) else { continue }
            if let name = entry.folder {
                let names = Array((entry.path ?? [name]).prefix(Nest.deepest))
                var steps: [Session.Step] = []
                for depth in names.indices {
                    let key = names[...depth].joined(separator: Self.folderStep)
                    let id = folders[key] ?? UUID().uuidString
                    folders[key] = id
                    if depth < names.count - 1 { steps.append(Session.Step(id: id, name: names[depth], open: false)) }
                    else { made.folder = id }
                }
                made.folderName = names.last ?? name
                made.folderOpen = false
                made.folderPath = steps.isEmpty ? nil : steps
            }
            madeKept.append(made)
        }
        for index in madeKept.indices { madeKept[index].kept = true }
        let madeOpen = open.compactMap { entry -> Session.Entry? in
            guard var made = line(entry) else { return nil }
            if let name = entry.folder {
                let key = folders["today:" + name] ?? UUID().uuidString
                folders["today:" + name] = key
                made.folder = key
                made.folderName = name
                made.folderOpen = false
                made.folderToday = true
            }
            return made
        }
        guard !madePins.isEmpty || !madeKept.isEmpty || !madeOpen.isEmpty else { return (0, 0) }
        let after = shape.tabs.firstIndex { $0.pin == nil } ?? shape.tabs.count
        if !shape.tabs.isEmpty, after <= shape.active { shape.active += madePins.count }
        for index in (shape.pairs ?? []).indices {
            if shape.pairs![index].first >= after { shape.pairs![index].first += madePins.count }
            if shape.pairs![index].second >= after { shape.pairs![index].second += madePins.count }
            shape.pairs![index].more = shape.pairs![index].more?.map { $0 >= after ? $0 + madePins.count : $0 }
        }
        shape.tabs.insert(contentsOf: madePins, at: after)
        // After the kept already there; the row is put in order as it is read.
        let keptAt = shape.tabs.lastIndex { $0.pin != nil || $0.kept == true }.map { $0 + 1 } ?? 0
        if !shape.tabs.isEmpty, keptAt <= shape.active { shape.active += madeKept.count }
        for index in (shape.pairs ?? []).indices {
            if shape.pairs![index].first >= keptAt { shape.pairs![index].first += madeKept.count }
            if shape.pairs![index].second >= keptAt { shape.pairs![index].second += madeKept.count }
            shape.pairs![index].more = shape.pairs![index].more?.map { $0 >= keptAt ? $0 + madeKept.count : $0 }
        }
        shape.tabs.insert(contentsOf: madeKept, at: keptAt)
        shape.tabs.append(contentsOf: madeOpen)
        Session.write(now: true, space: id, window: windowID, shape)
        return (madePins.count, madeKept.count + madeOpen.count)
    }

    /// The pages brought into a space before, which bringing in again
    /// leaves out as ones taken out here on purpose: none of them when
    /// the space holds none of what is coming now (`have`), its row lost
    /// since or emptied, so Bring In fills it again rather than bringing
    /// nothing into it (request #1106).
    static func remembered(_ brought: [String]?, of coming: [TabImport.Entry], among have: Set<String>) -> Set<String> {
        guard let brought, !brought.isEmpty else { return [] }
        let keys = Set(coming.map { TabImport.key($0.url) })
        return keys.isDisjoint(with: have) ? [] : Set(brought)
    }

    /// A place's pins and the tabs it keeps as a folder of bookmarks,
    /// "Arc › Work", merged by address as any browser's bookmarks are.
    /// Returns how many were new.
    private func bookmark(_ place: TabImport.Place, withOpen: Bool, from source: Chromium.Source) -> Int {
        let name = "\(source.name) › \(place.name)"
        let nodes = (place.pinned + place.kept + (withOpen ? place.open : [])).map { Bookmark.site($0.name ?? $0.title, $0.url, added: $0.added) }
        guard !nodes.isEmpty else { return 0 }
        return bookmarks.take(nodes, from: name, brought: Bookmarks.broughtAll()[name], apart: true).added
    }
}

extension Swatch {
    /// The preset a color is closest to, if it is close enough to be that
    /// swatch; your own color otherwise. Worked in OKLCH, where distance is
    /// what the eye sees.
    static func nearest(_ color: NSColor) -> Swatch {
        let (l, c, h) = color.oklch
        func distance(_ other: NSColor) -> CGFloat {
            let (l2, c2, h2) = other.oklch
            let a = c * cos(h) - c2 * cos(h2), b = c * sin(h) - c2 * sin(h2)
            return sqrt((l - l2) * (l - l2) + a * a + b * b)
        }
        let best = presets.min { distance($0.color(dark: false, custom: color)) < distance($1.color(dark: false, custom: color)) }
        guard let best, distance(best.color(dark: false, custom: color)) < 0.06 else { return .custom }
        return best
    }
}

extension TabImport.Place {
    /// The place's own color and grain as Yab wears them: a preset only
    /// when the color is that preset's own, your own otherwise, so a color
    /// brought from Arc is worn as Arc's, not as a preset near it
    /// (request #464); nil for a place that has no color.
    @MainActor func paint(_ prefs: Preferences) -> SpacePaint? {
        guard let color = color.flatMap(NSColor.init(hex:)) else { return nil }
        let near = Swatch.nearest(color)
        let swatch = near.color(dark: false, custom: color).usingColorSpace(.sRGB)?.hex == color.hex ? near : .custom
        return SpacePaint(swatch: swatch, color: color, grain: grain ?? prefs.grain, colors: colors)
    }
}
