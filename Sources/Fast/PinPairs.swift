import AppKit

// A pair pinned as one (feedback #267, register row 380): Dia's pinned
// split, as the concept's variant A draws it
// (https://claude.ai/artifact/SfcVqpKa3X5GvRt26UqTas).
//
// Both halves are pins, and the pair between them is a pair like any
// other: in `pairs`, in the session by where each stands, the share with
// it. The grid draws the two as one square, both marks with a hairline
// between them (PinSquare's `mate`), so the second takes no cell of its
// own. A click on the square puts the first in front, and the pair being
// its pair, both halves are on screen at once, at the share they had.
//
// What Dia does differently, on purpose: Dia's square wears a split glyph,
// ours the two sites' marks; and in Dia one half's cross ends the pinned
// split for good, where here it only puts that half down (`pairRest`): its
// mark dims, the other half has the width, and the next click on the
// square brings the two back. Separate is the way to make two pins of it,
// Unpin Pair the way back to Today, as a pair row.

extension Browser {
    /// The field's Pin Tab acts on the split when either half is in front,
    /// as Pin Pair in that split's menu does.
    func pinActive() {
        if let pair = pair(of: activeID) {
            pinPair(pair)
        } else if let active, !active.isBlank {
            pin(active)
        }
    }

    /// The field's Unpin Tab returns a pinned split to Today as a pair.
    func unpinActive() {
        if let pair = pinPair(of: activeID) {
            unpinPair(pair)
        } else if let active {
            unpin(active)
        }
    }

    /// The pair `id` is half of, when both its halves are pins.
    func pinPair(of id: Tab.ID?) -> Pair? {
        guard let pair = pair(of: id), let a = tab(id: pair.first), let b = tab(id: pair.second),
              a.pin != nil, b.pin != nil else { return nil }
        return pair
    }

    /// The second half of a pinned pair whose first is `tab`: the square
    /// draws both. Nil for any other tab.
    func pinMate(of tab: Tab) -> Tab? {
        guard let pair = pinPair(of: tab.id), pair.first == tab.id else { return nil }
        return self.tab(id: pair.second)
    }

    /// The second half of a pinned pair: no cell of its own in the grid.
    func pinTucked(_ tab: Tab) -> Bool {
        guard tab.pin != nil, let pair = pinPair(of: tab.id) else { return false }
        return pair.second == tab.id
    }

    /// The pins as the grid has them, a pinned pair one cell.
    var gridPins: [Tab] {
        guard !pairs.isEmpty else { return tabs.filter { $0.pin != nil } }
        return tabs.filter { $0.pin != nil && !pinTucked($0) }
    }

    /// How many cells the grid has: the pins, a pinned pair one.
    var pinCellCount: Int {
        guard !pairs.isEmpty else { return pinnedCount }
        return pinnedCount - pairs.filter { pinPair(of: $0.first) != nil }.count
    }

    /// The pair on screen when `id` is in front: its pair, unless that is
    /// a pinned pair with a half put down, which leaves `id` alone.
    func shownPair(of id: Tab.ID?) -> Pair? {
        guard let pair = pair(of: id) else { return nil }
        if pinPair(of: id) != nil, [pair.first, pair.second].contains(where: { tab(id: $0)?.pairRest == true }) { return nil }
        return pair
    }

    /// Whether this pair can be pinned as one: two tabs of yours side by
    /// side, neither a pin nor sealed. A half that is a pin's copy, carried
    /// beside the other as Arc carries a pin (Split.swift's `carried`),
    /// counts as that pin: two pins put side by side pin as one square of
    /// the two (feedback #349). A kept or filed tab's copy is pinned itself.
    func canPinPair(_ pair: Pair) -> Bool {
        // A pinned pair's square holds two side by side.
        guard pair.halves, let a = tab(id: pair.first), let b = tab(id: pair.second) else { return false }
        func pinnable(_ tab: Tab) -> Bool {
            guard tab.pin == nil, !tab.bench, !tab.isBlank, tab.address != nil else { return false }
            if carriedHome(tab)?.pin != nil, pinHome(of: tab) == nil { return false }
            return !Agents.shared.sealed(tab) && !folderBook.theirs(tab)
        }
        guard pinnable(a), pinnable(b) else { return false }
        if let home = pinHome(of: a), home === pinHome(of: b) { return false }
        return true
    }

    /// The pin `tab` is a copy of, still on its page and in no pair: the
    /// one that goes into a pinned pair in the copy's place.
    func pinHome(of tab: Tab) -> Tab? {
        guard tab.pin == nil, let home = carriedHome(tab), home.pin != nil, pair(of: home.id) == nil else { return nil }
        return home
    }

    /// The pair with each pin's copy in it swapped for the pin itself, on
    /// screen in the copy's place, the copy closed: no page pinned twice.
    private func pinsInPlace(of pair: Pair) -> Pair {
        let swaps = [pair.first, pair.second].compactMap { id in tab(id: id).flatMap { copy in pinHome(of: copy).map { (copy, $0) } } }
        guard !swaps.isEmpty, let index = pairs.firstIndex(of: pair) else { return pair }
        settleNow()
        var next = pair
        for (copy, home) in swaps {
            if next.first == copy.id { next.first = home.id } else { next.second = home.id }
        }
        let front = swaps.first { $0.0.id == activeID }
        var row = tabs.filter { tab in !swaps.contains { $0.1 === tab } }
        for (copy, home) in swaps {
            if let at = row.firstIndex(where: { $0 === copy }) { row.insert(home, at: at) }
        }
        // The row and the pair set together, as `replace` sets them.
        splitBook.keeping = true
        splitBook.staging = true
        pairs[index] = next
        lay(row)
        if let front { activeID = front.1.id }
        splitBook.keeping = false
        splitBook.staging = false
        restage(from: front?.0.id)
        for (copy, home) in swaps {
            home.pairRest = false
            if !home.wake() { home.revive() }
            close(copy)
        }
        return next
    }

    /// Pin Pair: both halves pins, still a pair, one square at the grid's
    /// end; the row leaves Today. The pair stays on screen as it was.
    /// `cell`: the grid's cell the square goes to, for a pair row dragged
    /// up into the pins, as Dia pins a split by dragging it there; it
    /// lands from the hand, so it doesn't grow in.
    func pinPair(_ pair: Pair, cell: Int? = nil) {
        if startsArranging { return arranging { pinPair(pair, cell: cell) } }
        guard canPinPair(pair) else { return }
        let pair = pinsInPlace(of: pair)
        guard let a = tab(id: pair.first), let b = tab(id: pair.second) else { return }
        // Shared with every space only when both can be: a pair is one
        // square, in one place.
        let shared = showsShared(spaceID) && Browser.sharable(a) && Browser.sharable(b)
        for tab in [a, b] {
            tab.pin = tab.monogram
            tab.kept = false
            tab.nest = nil
            tab.pairRest = false
            // A kept tab's copy is a tab of its own now, never closed with
            // the pair (`dropCarried`).
            tab.carriedFrom = nil
            tab.carriedPage = nil
            // A pin shared before, in a pair that can't be: this space's.
            tab.everywhere = shared ? (tab.everywhere ?? tab.id) : nil
        }
        // At the end of the pins, or of the shared ones for a shared pair,
        // the first on the left.
        var row = tabs.filter { $0.id != a.id && $0.id != b.id }
        let pins = row.prefix { $0.pin != nil }.count
        let sharedEnd = row.prefix { $0.everywhere != nil }.count
        var at = shared ? sharedEnd : pins
        if let cell {
            at = Self.pinRow(forCell: cell, in: row, pins: pins, grid: gridPins)
            if showsShared(spaceID) { at = shared ? min(at, sharedEnd) : max(at, sharedEnd) }
        }
        row.insert(contentsOf: [a, b], at: at)
        if cell == nil { pinGrowing = a.id }
        lay(row)
        writeSession(now: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.pinGrowing == a.id { self?.pinGrowing = nil }
        }
    }

    /// Unpin Pair: both halves back among today's, as a pair row at the
    /// head of them, under the kept.
    func unpinPair(_ pair: Pair) {
        if startsArranging { return arranging { unpinPair(pair) } }
        guard let a = tab(id: pair.first), let b = tab(id: pair.second) else { return }
        for tab in [a, b] {
            tab.pairRest = false
            if editingPin == tab.id { editingPin = nil }
            tab.pin = nil
            tab.everywhere = nil
        }
        var row = tabs.filter { $0.id != a.id && $0.id != b.id }
        row.insert(contentsOf: [a, b], at: min(keptEnd, row.count))
        lay(row)
        restage()
        writeSession(now: true)
    }

    /// Separate on a pinned pair: two pins, side by side in the grid, the
    /// one in front keeping the width.
    func separatePinPair(_ pair: Pair) {
        for id in [pair.first, pair.second] { tab(id: id)?.pairRest = false }
        if stagePair == pair {
            separate(pair)
        } else {
            pairs.removeAll { $0.first == pair.first && $0.second == pair.second }
            writeSession(now: true)
        }
    }

    /// A click on a pinned pair's square: a half put down comes back, and
    /// both are on screen, the first in front, or the one clicked.
    func openPinPair(_ pair: Pair, front: Tab.ID? = nil) {
        guard let first = tab(id: front ?? pair.first) else { return }
        let rested = [pair.first, pair.second].compactMap { tab(id: $0) }.filter(\.pairRest)
        for tab in rested { tab.pairRest = false }
        if !rested.isEmpty, pair.contains(activeID) {
            // Already in front, alone: the other half comes back beside it.
            restage()
            if let active { wakePartner(of: active) }
            rememberSplit()
            if activeID != first.id { select(first) }
            return
        }
        select(first)
    }

    /// One half's cross on a pinned pair on screen: that half is put down,
    /// as a pin is, the other takes the width, and the square keeps both.
    /// False when `tab` is no half of a pinned pair on screen.
    func putDownPinHalf(_ tab: Tab) -> Bool {
        guard tab.pin != nil, let pair = pinPair(of: tab.id), stagePair == pair, let other = partner(of: tab), !other.pairRest else {
            return false
        }
        leave(pair, keeping: other.id) { [self] in
            // The other half in front however the leaving ends, cut short
            // too (`settleNow`), never the half put down.
            if activeID == tab.id { activeID = other.id }
            tab.pairRest = true
            tab.rest(closing: true)
            if tab.awayFromHome { tab.sendHome() }
            writeSession(now: true)
        }
        return true
    }

    /// Close Pair: both halves put down, as pins are, and you land where
    /// ⌘W on a pin lands you.
    func closePinPair(_ pair: Pair) {
        guard let a = tab(id: pair.first), let b = tab(id: pair.second) else { return }
        settleNow()
        let front = pair.contains(activeID) ? (activeID == a.id ? a : b) : nil
        // The one not in front first, so the one in front is a pin alone
        // when it is put down, and ⌘W's landing is had.
        for tab in [a, b] where tab !== front {
            tab.pairRest = true
            tab.rest(closing: true)
            if tab.awayFromHome { tab.sendHome() }
        }
        if let front {
            restage()
            close(front)
            front.pairRest = true
        } else {
            writeSession(now: true)
        }
    }

    /// The pairs pinned as one among `pins`, from the row on screen and
    /// the shared pins put aside, for their file.
    func pinPairs(among pins: [Tab]) -> [Pair] {
        let ids = Set(pins.filter { $0.pin != nil }.map(\.id))
        var seen = Set<Tab.ID>()
        return (pairs + (parked[Space.pinsID]?.pairs ?? [])).filter { pair in
            guard ids.contains(pair.first), ids.contains(pair.second), !seen.contains(pair.first), !seen.contains(pair.second) else { return false }
            seen.formUnion([pair.first, pair.second])
            return true
        }
    }

    /// Where in `row` a square put in at the grid's cell `cell` stands:
    /// before the pin in that cell now, a pinned pair's two places one
    /// cell, or after the pins past the last.
    static func pinRow(forCell cell: Int, in row: [Tab], pins: Int, grid: [Tab]) -> Int {
        guard cell >= 0, cell < grid.count, let at = row.firstIndex(where: { $0.id == grid[cell].id }) else { return pins }
        return min(at, pins)
    }

    /// The row index a pin dragged to cell `cell` of the grid goes to, a
    /// pinned pair taking two places in the row and one cell.
    func pinRow(forCell cell: Int, moving tab: Tab, from: Int) -> Int {
        let grid = gridPins
        guard grid.indices.contains(cell), let at = tabs.firstIndex(where: { $0.id == grid[cell].id }) else { return cell }
        // Going later, past a pair: after both of it.
        if cell > from, pinMate(of: grid[cell]) != nil { return at + 1 }
        return at
    }
}
