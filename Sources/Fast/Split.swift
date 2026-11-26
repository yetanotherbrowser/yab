import SwiftUI
import AppKit

// Two tabs side by side in the window, or one above the other; three as
// one on the left and two stacked on the right; four as a 2x2 grid
// (#71, #522).
//
// Both stay tabs like any other: in the row, in the session, in ⌃Tab's
// grid and among the open pages ⌘T finds. The pair is only which two, in
// the row's order, and how much of the width the first one has. The tab
// in front, `activeID`, is whichever half was last clicked, so everything
// that acts on the page in front, ⌘L, ⌘R, ⌘F, the zoom, acts on that half
// without knowing there are two.
//
// Each half is drawn with the address bar on top of it, whatever the
// setting: its own back, forward and reload on the left, the site in the
// middle. Downloads, the update and the extensions stand only in the right
// half's, so there is one of each.
//
// A web view made another width lays its whole page out again in WebKit,
// and the main thread can wait up to half a second on it. So nothing here
// resizes a page while anything moves: entering, separating, the divider
// under the hand. The page is held at the size it had and cut to its new
// outline (see StageView.hold), and given its new size once, when the
// motion is over.

/// Which two tabs, and the first one's share of the width; or three or
/// four, in a grid.
struct Pair: Equatable, Codable {
    /// In the row's order: the first is the left half.
    var first: Tab.ID
    var second: Tab.ID
    /// The left half's share of the room the two have, the divider aside.
    /// Two stacked, the top one's share of the height; in a grid, the left
    /// column's share of the width.
    var share: CGFloat = 0.5
    /// A third and a fourth pane, after `second` in the row. A Yab from
    /// before reads only the first two, and finds a pair.
    var more: [Tab.ID] = []
    var arrangement: Arrangement = .across
    /// In a grid, where the divider between the rows stands, as `share`
    /// does: across the right column of three, across all of four.
    var cuts: [CGFloat] = []

    enum Arrangement: String, Codable {
        /// Two side by side, as a pair always was.
        case across
        /// Two, one above the other.
        case stacked
        /// Three or four: the first on the left, the second at upper right,
        /// the third below it, the fourth below the first.
        case grid
    }

    /// Arc's Split View holds four.
    static let mostPanes = 4

    /// How many of the column's rows a split's row takes: four stand in two
    /// rows of chips.
    static func rows(_ count: Int) -> Int { count == 4 ? 2 : 1 }

    var ids: [Tab.ID] { [first, second] + more }
    var count: Int { 2 + more.count }
    /// Two side by side: the pair as it always was, laid and moved as it
    /// always was (SplitRule, SplitDeck).
    var halves: Bool { more.isEmpty && arrangement == .across }

    func contains(_ id: Tab.ID?) -> Bool { id == first || id == second || id.map(more.contains) == true }
    /// The pane after this one, round to the first: for two, the other.
    func other(than id: Tab.ID) -> Tab.ID {
        let all = ids
        guard let at = all.firstIndex(of: id) else { return first }
        return all[(at + 1) % all.count]
    }

    /// Every divider's place, `share` first.
    var allCuts: [CGFloat] { [share] + cuts }

    /// The pane in the room's top corner on that side.
    func topPane(right: Bool) -> Tab.ID {
        switch arrangement {
        case .across: right ? ids[ids.count - 1] : first
        case .stacked: first
        case .grid: right ? second : first
        }
    }

    /// Three or four are always laid as a grid; two side by side or stacked.
    static func shape(_ count: Int, _ arrangement: Arrangement) -> Arrangement {
        count > 2 ? .grid : arrangement == .grid ? .across : arrangement
    }

    /// Even dividers for `count` panes laid so.
    static func even(_ count: Int, _ arrangement: Arrangement) -> [CGFloat] {
        arrangement == .grid ? [0.5, 0.5] : (1..<max(2, count)).map { CGFloat($0) / CGFloat(count) }
    }

    /// The same panes in these places, `ids` in order, laid so, the
    /// dividers even; nil for fewer than two. Three or four are a grid.
    func with(_ ids: [Tab.ID], _ arrangement: Arrangement? = nil) -> Pair? {
        guard ids.count >= 2, ids.count <= Pair.mostPanes else { return nil }
        let shape = Pair.shape(ids.count, arrangement ?? self.arrangement)
        let cuts = Pair.even(ids.count, shape)
        return Pair(first: ids[0], second: ids[1], share: cuts[0], more: Array(ids.dropFirst(2)), arrangement: shape, cuts: Array(cuts.dropFirst()))
    }

    /// With `id` as one more pane, at the end: a third at lower right, a
    /// fourth below the first.
    func adding(_ id: Tab.ID) -> Pair? {
        guard !contains(id), count < Pair.mostPanes else { return nil }
        return with(ids + [id])
    }

    /// The same split with its tabs changed by `place`: nil when either of
    /// the first two has none; a pane past them that has none is left out,
    /// the rest laid evenly.
    func mapped(_ place: (Tab.ID) -> Tab.ID?) -> Pair? {
        guard let a = place(first), let b = place(second), a != b else { return nil }
        var next = self
        next.first = a
        next.second = b
        let more = self.more.compactMap(place)
        guard more.count != self.more.count else { next.more = more; return next }
        return next.with([a, b] + more)
    }

    /// Without `id`; nil once one pane is left.
    func removing(_ id: Tab.ID) -> Pair? {
        guard contains(id) else { return self }
        return with(ids.filter { $0 != id })
    }

    /// Pairs as a session file keeps them, by where each tab stood in it,
    /// made pairs of the tabs just made from it, `made` by that place. A
    /// pair naming a tab that isn't there, the same tab twice, or a tab
    /// another pair already has, is left out: a file written wrong must
    /// never bring back one tab in two pairs.
    /// The panes past the second are kept only as far as each is a tab of
    /// its own not taken already; the pair itself stands without them.
    static func restore(_ kept: [Session.Pair], made: [Int: Tab.ID]) -> [Pair] {
        var used = Set<Tab.ID>()
        return kept.compactMap { kept in
            guard let a = made[kept.first], let b = made[kept.second], a != b,
                  !used.contains(a), !used.contains(b), kept.share.isFinite else { return nil }
            used.insert(a)
            used.insert(b)
            var more: [Tab.ID] = []
            for place in kept.more ?? [] {
                guard more.count < Pair.mostPanes - 2, let id = made[place], !used.contains(id) else { continue }
                used.insert(id)
                more.append(id)
            }
            let shape = kept.arrangement.flatMap(Arrangement.init) ?? .across
            let pair = Pair(first: a, second: b, share: min(most, max(least, CGFloat(kept.share))))
            guard !more.isEmpty || shape != .across else { return pair }
            guard var laid = pair.with([a, b] + more, shape) else { return pair }
            let cuts = [kept.share] + (kept.cuts ?? [])
            if cuts.count == laid.allCuts.count, cuts.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }), laid.arrangement == .grid || cuts == cuts.sorted() {
                laid.share = CGFloat(cuts[0])
                laid.cuts = cuts.dropFirst().map { CGFloat($0) }
            }
            return laid
        }
    }

    /// Neither half narrower than a quarter.
    static let least: CGFloat = 0.25
    static let most: CGFloat = 0.75
    /// The divider: the room between the two cards, and what takes the hand.
    static let gap: CGFloat = 8
    /// The line round the half in front: the ink, faint, as Arc draws
    /// its; the accent there was one more color beside two sites'.
    static let ring = Palette.NS.ink.withAlphaComponent(0.3)
    /// Nor narrower than this: back, forward and reload, the way out, and
    /// between them a site's name that still reads. Where the page hasn't
    /// the room for two of these, there is no split to be had: not asked
    /// for from ⌘T or a tab's menu, nowhere to let a tab go, and a window
    /// with a pair on screen goes no narrower.
    static let narrowest: CGFloat = 320
    /// The page two halves and the divider need.
    static let room = 2 * narrowest + gap
    /// Nor, one above another, shorter than this: a band and some page.
    static let lowest: CGFloat = 180

    /// The width `count` panes laid so need.
    static func room(_ count: Int, _ arrangement: Arrangement) -> CGFloat {
        switch arrangement {
        case .across: CGFloat(count) * narrowest + CGFloat(count - 1) * gap
        case .stacked: narrowest
        case .grid: room
        }
    }

    /// The left half's width in a room this wide, at this share, kept to
    /// the quarter and the points both. A room short of two halves, a pair
    /// brought back or the column let out in a narrow window, halves.
    static func left(in width: CGFloat, share: CGFloat) -> CGFloat {
        let both = width - gap
        guard both > 0 else { return 0 }
        let least = min(0.5, max(Pair.least, narrowest / both))
        return (both * min(1 - least, max(least, share))).rounded()
    }

    /// The share the divider stands at when asked for this one, in a room
    /// this wide.
    static func held(_ share: CGFloat, in width: CGFloat) -> CGFloat {
        let both = width - gap
        guard both > 0 else { return min(most, max(least, share)) }
        return left(in: width, share: share) / both
    }
}

/// Where a tab stands in a pair, for the row and the column to join it to
/// its other half: `second` is the last, `middle` any between.
enum Joint: Equatable {
    case first, middle, second

    init(_ pair: Pair, _ id: Tab.ID) {
        self = pair.first == id ? .first : pair.ids.last == id ? .second : .middle
    }
}

/// Which part of the room a stage takes. Two side by side are `left` and
/// `right` with the `gap` between; any other split is panes by their place
/// and dividers by theirs (SplitLayout.panes).
enum Side: Equatable {
    case whole, left, right, gap
    case pane(Int), cut(Int)
}

/// The share while the divider is in the hand, watched only by the room the
/// halves stand in: it changes on every move of the mouse, and watched by the
/// window the whole window was worked out again each time.
@MainActor
final class SplitDrag: ObservableObject {
    @Published var share: CGFloat?
    /// The halves are held and the hand's moves may reach them.
    var armed = false
    /// The share when the divider was taken.
    var grabbed: CGFloat?
    /// The last share asked for before the halves were held.
    var waiting: CGFloat?
    /// The divider is moved by SplitRule's layers, not by SwiftUI: its own
    /// grip gives way to theirs.
    @Published var ruled = false
    /// Of three or four panes, or two stacked, every divider's place while
    /// one is in the hand, and as `grabbed` and `waiting` are for `share`.
    @Published var cuts: [CGFloat]?
    var grabbedCuts: [CGFloat]?
    var waitingCuts: [CGFloat]?
}

/// What the pointer is on that a half answers to, watched only by the
/// small views that show it (HalfHint, LeaveMark): a chip, whose half is
/// outlined faintly, and a half's cross, whose half dims and whose chip is
/// outlined, it being the one to go back to the list.
@MainActor
final class SplitHint: ObservableObject {
    @Published var hinted: Tab.ID?
    @Published var leaving: Tab.ID?

    func hint(_ id: Tab.ID, _ on: Bool) {
        let next = on ? id : (hinted == id ? nil : hinted)
        if next != hinted { hinted = next }
    }

    func leave(_ id: Tab.ID, _ on: Bool) {
        let next = on ? id : (leaving == id ? nil : leaving)
        if next != leaving { leaving = next }
    }
}

/// Room made beside the lone page in front for a tab carried over it
/// (Browser.previewSplit), watched only by what it moves: the halves' room,
/// which places the page in the half it keeps, that page's band and paper,
/// and its stage, held while it moves.
@MainActor
final class SplitPreview: ObservableObject {
    /// The side the carried tab would take.
    @Published var room: Side?
    /// Being made or given back: the page held, WebKit following.
    @Published var moving = false
    /// A tab is in the hand over a lone page: the band a half has is built
    /// under it already, out of sight and no height, so making room only
    /// lays it out. Built when room was made, it was a third of that
    /// frame (SplitDeck.begin).
    @Published var warm = false

    /// The side a lone page in front is laid in, `laid` otherwise.
    func side(_ laid: Side, alone: Bool) -> Side {
        guard alone, laid == .whole, let room else { return laid }
        return room == .left ? .right : .left
    }
}

/// What the split keeps that nothing draws from.
@MainActor
final class SplitBook {
    /// Each half's frame in the window, from its top left, for a click to
    /// say which half it fell in.
    var frames: [Tab.ID: CGRect] = [:]
    var clicks: Any?
    /// A change of shape under way; the stages keep the pair they had
    /// until it is over.
    var frozen = false
    var turns = 0
    /// What a change of shape under way is still to do, the pair taken
    /// apart or the tab closed, for `settleNow` to do at once.
    var pending: (() -> Void)?
    /// The half that stays when it is done, for the tab in front.
    var keep: Tab.ID?
    /// Keeping the pairs right is under way: what it assigns itself is not
    /// to start it again.
    var keeping = false
    /// Several changes to the pairs, the row and the tab in front made as
    /// one: the stages are worked out once, after the last. Worked out after
    /// each, a pair between two states took the tab it was keeping off the
    /// screen for a moment, and with it the question it had up and the
    /// frame its half was last measured at.
    var staging = false
    /// When the curves of the room being made were first handed to Core
    /// Animation (`previewSplit`).
    var roomBegun: CFTimeInterval?
    /// How wide the halves' room is, for the divider's share. Kept here,
    /// not as state of the window's, which would draw the whole window
    /// again whenever it changes.
    var room: CGFloat = 0
    /// Where the halves' room is in the window, from its top left: the
    /// page, or the two halves and the divider.
    var place: CGRect = .zero
    /// A half's band, how tall and its top corners, for SplitRule.
    var bar: CGFloat = 0
    var corner: CGFloat = 0
    /// When the last pair was asked for and when it started to move, for
    /// the bench.
    var asked: CFTimeInterval = 0
    var moved: CFTimeInterval = 0
}

extension Browser {
    // MARK: - asking

    func pair(of id: Tab.ID?) -> Pair? {
        guard let id, !pairs.isEmpty else { return nil }
        return pairs.first { $0.contains(id) }
    }

    func partner(of tab: Tab) -> Tab? {
        guard let pair = pair(of: tab.id) else { return nil }
        let other = pair.other(than: tab.id)
        return tabs.first { $0.id == other }
    }

    /// The panes past the second of the split `first` heads, on screen or
    /// in a space's parked row, for its row in the column: a space sliding
    /// in (PagedSpace) draws its rows from its parked one.
    func morePanes(of first: Tab.ID) -> [Tab] {
        if let pair = pair(of: first) { return pair.more.compactMap { id in tabs.first { $0.id == id } } }
        for row in parked.values {
            guard let pair = row.pairs.first(where: { $0.first == first }) else { continue }
            return pair.more.compactMap { id in row.tabs.first { $0.id == id } }
        }
        return []
    }

    /// How many of the column's rows a tab's own row takes: one; none for a
    /// pane after its split's first, whose row is the first's; two for the
    /// first of four.
    func rowsTaken(by id: Tab.ID) -> Int {
        guard let pair = pair(of: id) else { return 1 }
        return pair.first == id ? Pair.rows(pair.count) : 0
    }

    /// The other tabs of the split `id` is in, in the row's order.
    func mates(of id: Tab.ID) -> [Tab.ID] {
        pair(of: id)?.ids.filter { $0 != id } ?? []
    }

    func joint(of id: Tab.ID) -> Joint? {
        guard let pair = pair(of: id) else { return nil }
        return Joint(pair, id)
    }

    /// Both halves are on screen, the pair proper: not while one of them is
    /// growing over the other on the way in or out.
    var splitShown: Bool { stagePair != nil && wide == nil }

    /// A tab that is one of the two halves on screen.
    func onScreen(_ id: Tab.ID) -> Bool {
        id == activeID || stagePair?.contains(id) == true || peeking.map { $0.id == id && isLive($0) } == true
    }

    /// Whether these two can be put side by side: two tabs of yours, loose
    /// or in a folder of yours, neither a pin nor in a pair already, nor in
    /// an agent's folder.
    func canPair(_ a: Tab, _ b: Tab) -> Bool {
        guard a.id != b.id, splitFits else { return false }
        return [a, b].allSatisfy { tab in
            tab.pin == nil && !tab.bench && pair(of: tab.id) == nil
                && !folderBook.theirs(tab) && tabs.contains { $0.id == tab.id }
        }
    }

    /// The row with `other` beside `current`, the pair in one place:
    /// `current`'s. `other` is loose here, or a copy of a pin or a kept tab
    /// (`carried`), which stays where it is.
    private func pairRow(_ other: Tab, with current: Tab, leading: Bool) -> [Tab] {
        let (anchor, moving) = (current, other)
        if moving.nest !== anchor.nest || moving.kept != anchor.kept {
            moving.nest = anchor.nest
            moving.kept = anchor.kept
        }
        var row = tabs.filter { $0.id != moving.id }
        // A copy of the page in front: at the top of today's, just past
        // the pins and the kept, in the column and the strip alike.
        if !row.contains(where: { $0.id == anchor.id }) { row.insert(anchor, at: min(keptEnd, row.count)) }
        let here = row.firstIndex { $0.id == anchor.id } ?? row.count - 1
        // In the pair's order: the first on the left.
        let movingFirst = (moving.id == other.id) == leading
        row.insert(moving, at: movingFirst ? here : here + 1)
        return row
    }

    /// The page has the room for two halves.
    var splitFits: Bool { splitBook.place.width >= Pair.room }

    /// Whether this tab can take a half of a pair: a tab of yours, loose or
    /// in a folder of yours, neither a pin nor in a pair already, nor in an
    /// agent's folder.
    func canPlace(_ tab: Tab) -> Bool {
        tab.pin == nil && !tab.bench && pair(of: tab.id) == nil
            && !folderBook.theirs(tab) && tabs.contains { $0.id == tab.id }
    }

    /// Whether `tab` can be carried beside `current` to make a pair (SplitDeck):
    /// as `canPair`, but a pin, a kept tab or one in a folder of yours may be
    /// carried too, its page brought as a copy among today's while it stays
    /// where it is, as Arc does with its pinned tabs (`carried`).
    func canCarry(_ tab: Tab, beside current: Tab) -> Bool {
        guard tab.id != current.id, splitFits, !tab.bench, !folderBook.theirs(tab), pair(of: tab.id) == nil,
              tabs.contains(where: { $0.id == tab.id }), tab.address != nil else { return false }
        return !current.bench && pair(of: current.id) == nil
            && !folderBook.theirs(current) && tabs.contains { $0.id == current.id }
    }

    /// A tab that keeps its place when carried into a pair: a copy goes.
    static func stays(_ tab: Tab) -> Bool { tab.pin != nil || tab.kept || tab.nest != nil }

    /// The tab that goes into the pair for `tab`: itself, or, for one that
    /// stays where it is, a new tab of today's on the same page.
    private func carried(_ tab: Tab) -> Tab {
        guard Self.stays(tab), let address = tab.address else { return tab }
        let url = Browser.page(address)
        let copy = Tab(configuration: configuration(for: url))
        prepare(copy)
        copy.go(to: url)
        // It goes with the pair (`carriedHome`), and closed on its own it
        // goes back to the tab it is a copy of.
        copy.carriedFrom = tab.id
        copy.carriedPage = url
        copy.from = tab.id
        return copy
    }

    /// The pin, kept tab or filed one `tab` is a copy of (`carried`), while
    /// the copy is still on that page, with nowhere to go back to: a copy
    /// taken to another page since is a tab like any other. Nil for any
    /// other tab, or when the one it was copied from is gone.
    func carriedHome(_ tab: Tab) -> Tab? {
        guard let id = tab.carriedFrom, !tab.hasBackHistory else { return nil }
        // Gone to another site, by a page not counted in its history (a
        // tab asleep, an address typed over it): kept.
        let site = { (url: URL?) -> Substring? in
            guard let host = url?.host()?.lowercased() else { return nil }
            return host.hasPrefix("www.") ? host.dropFirst(4) : Substring(host)
        }
        if let was = tab.carriedPage, let now = tab.address, site(now) != site(was) { return nil }
        return tabs.first { $0.id == id && $0.id != tab.id }
    }

    /// Halves no longer in a pair that were copies of a pin, a kept tab or
    /// a filed one, still on its page: closed, as in Arc a pin's copy goes
    /// with its split; the pin stays where it is. Once nothing is moving,
    /// so a pair coming apart runs its course first.
    func dropCarried(_ ids: [Tab.ID], tries: Int = 0) {
        guard !ids.isEmpty else { return }
        if (splitBook.frozen || splitting || wide != nil || splitBook.pending != nil), tries < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.dropCarried(ids, tries: tries + 1) }
            return
        }
        for id in ids {
            guard pair(of: id) == nil, let copy = tabs.first(where: { $0.id == id }), carriedHome(copy) != nil else { continue }
            close(copy)
        }
    }

    /// The page ⌘T's "Split View" puts beside a new tab: the one left for it.
    var splitNeighbor: Tab? {
        guard let active else { return nil }
        return tabs
            .filter { $0.id != active.id && !$0.isBlank && canPair($0, active) }
            .max { $0.touched < $1.touched }
    }

    // MARK: - keeping it right

    /// The row changed: a pair whose tab is gone is gone, and the two of a
    /// pair stand side by side in the row, the first before the second,
    /// whatever put something between them.
    func keepPairs() {
        guard !splitBook.keeping, !pairs.isEmpty else { return }
        splitBook.keeping = true
        defer { splitBook.keeping = false }
        // Worked out whole, then the row and the pairs each set once: set as
        // it went, each assignment came back here through the other's didSet.
        let ids = Set(tabs.map(\.id))
        // A split a tab left is the rest of it, laid evenly; one left, none.
        var kept = pairs.compactMap { pair -> Pair? in
            guard pair.ids.allSatisfy(ids.contains) else { return pair.with(pair.ids.filter(ids.contains)) }
            return pair
        }
        var row = tabs
        var moved = false
        for index in kept.indices {
            var pair = kept[index]
            if !pair.halves {
                // Three or four: the row's order says which pane is where,
                // the panes then laid evenly; then the others follow the first.
                let order = pair.ids.sorted { a, b in (row.firstIndex { $0.id == a } ?? 0) < (row.firstIndex { $0.id == b } ?? 0) }
                if order != pair.ids, let laid = pair.with(order) { pair = laid; kept[index] = laid }
                guard var at = row.firstIndex(where: { $0.id == pair.first }) else { continue }
                for id in pair.ids.dropFirst() {
                    guard let here = row.firstIndex(where: { $0.id == id }) else { continue }
                    if here != at + 1 {
                        let tab = row.remove(at: here)
                        if here < at { at -= 1 }
                        row.insert(tab, at: at + 1)
                        moved = true
                    }
                    at += 1
                }
                continue
            }
            guard var a = row.firstIndex(where: { $0.id == pair.first }),
                  var b = row.firstIndex(where: { $0.id == pair.second }) else { continue }
            // Taken past each other: the row's order says which is left.
            if b < a {
                swap(&pair.first, &pair.second)
                pair.share = 1 - pair.share
                kept[index] = pair
                swap(&a, &b)
            }
            guard b != a + 1 else { continue }
            let tab = row.remove(at: b)
            row.insert(tab, at: a + 1)
            moved = true
        }
        if moved { lay(row) }
        if kept != pairs { pairs = kept }
    }

    /// The row with `id` moved to `index` as a lone tab would be, and its
    /// other half, if it has one, carried with it: the two land where the
    /// one would have, among the tabs that are not theirs.
    static func moving(_ order: [Tab], _ id: Tab.ID, to index: Int, with other: Tab.ID?) -> [Tab] {
        moving(order, id, to: index, with: other.map { [$0] } ?? [])
    }

    /// As above, with every other pane of a split carried along.
    static func moving(_ order: [Tab], _ id: Tab.ID, to index: Int, with others: [Tab.ID]) -> [Tab] {
        guard let here = order.firstIndex(where: { $0.id == id }) else { return order }
        var alone = order
        let held = alone.remove(at: here)
        alone.insert(held, at: min(max(0, index), alone.count))
        guard !others.isEmpty else { return alone }
        let group = order.filter { $0.id == id || others.contains($0.id) }
        let before = alone.prefix { $0.id != id }.filter { !others.contains($0.id) }.count
        var rest = order.filter { $0.id != id && !others.contains($0.id) }
        rest.insert(contentsOf: group, at: min(before, rest.count))
        return rest
    }

    /// Which stage shows which tab. A tab keeps its stage for as long as it
    /// is on screen, so a half is never handed from one view to another; a
    /// tab picked in place of the one in front takes that one's stage, so
    /// the page turns there as it always has.
    func restage(from old: Tab.ID? = nil) {
        guard !splitBook.staging else { return }
        // A page gone full screen stays one of its pair: WebKit takes it
        // to a window of its own, and the pair is there when it comes back.
        if !splitBook.frozen {
            // A pinned pair with a half put down shows the other alone.
            let pair = shownPair(of: activeID)
            if stagePair != pair { stagePair = pair }
        }
        // The tab in front first, so it is the one that takes the stage the
        // tab left had, and the page turns there, not on the other half.
        let shown: [Tab.ID] = stagePair.map { pair in
            // Leaving, one of them may be closed already.
            pair.ids
                .filter { id in tabs.contains { $0.id == id } }
                .sorted { a, _ in a == activeID }
        } ?? activeID.map { [$0] } ?? []
        var next = stages
        let preferred = (old ?? activeID).flatMap { id in stages.firstIndex(of: id) }
        for slot in next.indices where !(next[slot].map(shown.contains) ?? false) { next[slot] = nil }
        for id in shown where !next.contains(id) {
            if let preferred, next[preferred] == nil, id == activeID || stagePair == nil {
                next[preferred] = id
            } else if let free = next.firstIndex(where: { $0 == nil }) {
                next[free] = id
            }
        }
        if next != stages {
            let gone = stages.compactMap { $0 }.filter { !next.contains($0) }
            // A tab taking a stage over from another takes its frame too:
            // measured where it is drawn, and drawn in the same place, it is
            // not measured again until something moves.
            for slot in next.indices {
                if let now = next[slot], let was = stages[slot], now != was, splitBook.frames[now] == nil,
                   let frame = splitBook.frames[was] { splitBook.frames[now] = frame }
            }
            stages = next
            splitBook.frames = splitBook.frames.filter { next.contains($0.key) }
            // A half off the screen, a pair come apart or one of it put in
            // another's place, takes its question down to its tab, as a
            // tab left does (asksFollow): up over nothing, it would wait
            // unseen with nothing on the tab to say so.
            for id in gone where !onScreen(id) {
                guard let tab = tabs.first(where: { $0.id == id }) else { continue }
                // Seen until now, the half beside the tab in front as much
                // as the one in front: its time unwatched starts here. Only
                // the tab left was touched (activeID), so the other half's
                // was still counted from when the pair came up, and a page
                // read beside another for hours slept at the next look.
                tab.touch()
                if !tab.asks.isEmpty, !tab.asks[0].parked { tab.asks[0].parked = true }
            }
        }
        watchHalves()
        floorWindow()
    }

    /// Where each half is in the window, as SplitLayout places them, from
    /// the room and the share: nil with one page.
    func halves() -> (left: CGRect, right: CGRect)? {
        guard splitShown, let pair = stagePair, pair.halves else { return nil }
        let layout = SplitLayout(share: pair.share)
        return (layout.frame(for: .left, in: splitBook.place),
                layout.frame(for: .right, in: splitBook.place))
    }

    /// Which part of the room a stage's tab takes.
    func side(of id: Tab.ID) -> Side {
        guard let pair = stagePair, wide != id else { return .whole }
        guard pair.halves else { return .pane(pair.ids.firstIndex(of: id) ?? 0) }
        return pair.first == id ? .left : .right
    }

    /// How far the pane in front stands in from the room's edges, for what
    /// floats over the page in front: the find bar, the notices, an agent's
    /// question. Nil for one page or two halves.
    func frontPaneInset() -> (top: CGFloat, bottom: CGFloat, trailing: CGFloat)? {
        guard stagePair?.halves == false, let id = activeID, let frame = paneFrames()[id] else { return nil }
        let room = splitBook.place
        return (frame.minY - room.minY, room.maxY - frame.maxY, room.maxX - frame.maxX)
    }

    /// Where each pane of the split on screen is in the window, from its top
    /// left, as SplitLayout places them.
    func paneFrames() -> [Tab.ID: CGRect] {
        guard splitShown, let pair = stagePair else { return [:] }
        let laid = SplitLayout.panes(pair.count, pair.arrangement, cuts: pair.allCuts, in: splitBook.place).panes
        return Dictionary(uniqueKeysWithValues: zip(pair.ids, laid).map { ($0, $1) })
    }

    // MARK: - putting two together

    /// "Split with Current Tab": `other` beside the tab in front, on its
    /// right, and in front itself once the two have made room.
    ///
    /// The other half is put in first, where it will stand, under the page
    /// in front, which still has the whole width: its page is made its new
    /// size there, unseen. Then that page is held and draws its edge in to
    /// its half, in Core Animation, uncovering the other; and once it has
    /// stopped it is given its new size, once.
    func split(_ given: Tab, with page: Tab, leading: Bool = false) {
        guard canCarry(given, beside: page) else { return }
        let other = carried(given)
        // A pin or a kept page in front stays where it is too: a copy of it
        // among today's makes the pair, as Arc does.
        let current = carried(page)
        let copied = current !== page
        // Let go into room already made: the page in front is in its half.
        if !copied, current.id == activeID, splitRoom == (leading ? .left : .right) {
            return splitIntoRoom(other, with: current, leading: leading)
        }
        previewSplit(nil, quick: true)
        Teach.shared.used(.split)
        if !copied, current.id != activeID { select(current) }
        cancelTabEdit()
        editing = false
        typed = ""
        splitBook.turns += 1
        let turn = splitBook.turns
        // Set as they are, not in a transaction of their own: in one,
        // SwiftUI drew the window at once from the first willSet here, the
        // rest not yet set, and took no notice of the writes after it. The
        // halves stayed where they had been, the column in the pair's look
        // after the pair had gone (frames_ab split, split-drags, 2026-10-17).
        // The same holds for the hold, the let-go and the settling below.
        if floating == other.id { land(home: true) }
        // The row first: a copy carried in (`carried`) has to be among the
        // tabs before its pair is, or keeping the pairs right drops it.
        lay(pairRow(other, with: current, leading: leading))
        pairs.append(leading ? Pair(first: other.id, second: current.id) : Pair(first: current.id, second: other.id))
        // The copy in front, whole for a frame, then it makes room.
        if copied { activeID = current.id }
        splitBook.frozen = false
        wide = current.id
        splitting = true
        restage()
        if !other.wake() { other.revive() }
        other.touch()
        folderBook.refresh()
        rememberSplit()
        splitBook.asked = CACurrentMediaTime()
        let go = { [self] in
            guard splitBook.turns == turn, wide != nil else { return }
            splitBook.moved = CACurrentMediaTime()
            wide = nil
            activeID = other.id
            settleSplit(turn)
        }
        // A frame on: the other half is put in and made its size under the
        // page in front, in a pass of its own, before anything moves.
        // Measured against waiting for it to draw first (as long as 550 ms,
        // WebKit draws late for a view that is covered) and against sizing
        // it before it is in the window (no quicker, a worse first frame),
        // this is the quickest to start, 33 ms.
        // Not before the other half has drawn there, though, at most
        // 120 ms: a pair made while the window's redraw was quick showed
        // it white for a frame (perf night 2026-10-16, frames_ab).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            guard let web = other.builtPage else { return go() }
            StageView.afterPageDrawing(web) { DispatchQueue.main.async { go() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { go() }
        }
    }

    /// The page in front laid out in the half it keeps, with its band, as
    /// a tab carried over it asks for room on `side`, or given the whole
    /// room back with nil (SplitDeck). The page is held in a pass of its
    /// own first; then the window is laid out where the room ends up, the
    /// band drawn there by SwiftUI and the page's outline and paper by
    /// Core Animation on the same curve, WebKit following the width shown,
    /// so the page reads at its new width before the tab is let go. A new
    /// side or a way back starts from wherever the last one has got to.
    /// Nothing is kept: no pair, nothing in the session, the tab in front
    /// the same.
    func previewSplit(_ side: Side?, quick: Bool = false) {
        guard splitRoomAsked != side || (side == nil && splitRoom != nil) else { return }
        splitRoomAsked = side
        splitRoomMoves += 1
        let move = splitRoomMoves
        var still = Transaction()
        still.disablesAnimations = true
        guard !quick, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            withTransaction(still) {
                splitPreview.room = side
                splitPreview.moving = false
            }
            return
        }
        let pace: Reshape.Pace = side == nil ? .unroom : .room
        if !splitRooming { withTransaction(still) { splitPreview.moving = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            guard splitRoomMoves == move else { return }
            Reshape.pace = pace
            let asked = CACurrentMediaTime()
            withAnimation(pace.animation) { splitPreview.room = side }
            // Let go a frame after the curves have run, counted from when
            // Core Animation was handed them: the page is then made its
            // own width, once, where it already shows. From the first hand
            // only: with the address bar up the half's band and page are
            // laid out on every frame of SwiftUI's curve, each pass carrying
            // the held page on afresh (`Reshape.carry`), and counted from
            // the last of those the page waited a second curve's length at
            // the width the last step left it, 11 points wide of its half,
            // and was made its width only on letting go (stress.py
            // bar-right, row 382).
            splitBook.roomBegun = nil
            @MainActor func arrive() {
                if splitBook.roomBegun == nil, Reshape.started >= asked { splitBook.roomBegun = Reshape.started }
                let begun = splitBook.roomBegun
                var left = (begun ?? asked) + pace.duration + 1.0 / 60 - CACurrentMediaTime()
                // Not handed yet: looked at again a frame on, so the first
                // hand is the one counted from.
                if begun == nil { left = min(left, 1.0 / 60) }
                guard left <= 0.002 || CACurrentMediaTime() - asked > 1 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + left) { arrive() }
                    return
                }
                guard splitRoomMoves == move, splitRooming else { return }
                withTransaction(still) { splitPreview.moving = false }
                Reshape.pace = .reshape
            }
            DispatchQueue.main.async { arrive() }
        }
    }

    /// The pair made where the room for it already is: the page in front
    /// stays in the half it was shown in, at the width it has, and the
    /// other is put in beside it under the deck's card, which lands there.
    private func splitIntoRoom(_ other: Tab, with current: Tab, leading: Bool) {
        Teach.shared.used(.split)
        cancelTabEdit()
        editing = false
        typed = ""
        splitBook.turns += 1
        let turn = splitBook.turns
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if floating == other.id { land(home: true) }
            // The row first: a copy carried in (`carried`) has to be among the
            // tabs before its pair is, or keeping the pairs right drops it.
            lay(pairRow(other, with: current, leading: leading))
            pairs.append(leading ? Pair(first: other.id, second: current.id) : Pair(first: current.id, second: other.id))
            splitBook.frozen = false
            // The room is the pair's now; a curve still running goes on to
            // the same place, held until it has (`previewSplit`).
            splitPreview.room = nil
            splitRoomAsked = nil
            restage()
        }
        if !other.wake() { other.revive() }
        other.touch()
        folderBook.refresh()
        rememberSplit()
        splitBook.asked = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            guard splitBook.turns == turn, pair(of: other.id) != nil else { return }
            splitBook.moved = CACurrentMediaTime()
            withTransaction(still) { activeID = other.id }
        }
    }

    /// The page held for a change of shape let go of a frame after the
    /// change is drawn, and in any case after a second.
    private func settleSplit(_ turn: Int, then done: (() -> Void)? = nil) {
        let end = { [self] in
            guard splitBook.turns == turn, splitting else { return }
            done?()
            splitting = false
        }
        let quick = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let asked = CACurrentMediaTime()
        // A frame after the curves have run from when they were drawn, which
        // under load comes well after they were asked for; let go before,
        // the page is made its new size mid-way and jumps there. Never more
        // than two seconds in all.
        func check() {
            let begun = max(Reshape.started, asked)
            let left = begun + (quick ? 0 : Reshape.duration) + 1.0 / 30 - CACurrentMediaTime()
            guard left > 0.001, CACurrentMediaTime() - asked < 2 else { end(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + left) { check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (quick ? 1.0 / 30 : Reshape.duration + 1.0 / 30)) { check() }
    }

    /// Separate: the half in front takes the width again, growing over the
    /// other, which is let go once it is covered.
    func separate(_ pair: Pair? = nil, keeping kept: Tab.ID? = nil) {
        guard let pair = pair ?? stagePair ?? self.pair(of: activeID) else { return }
        let keep = kept ?? (pair.contains(activeID) ? activeID! : pair.first)
        // The half staying a pin's copy: the copy goes with the pair and the
        // pin, on the same page, is where you are, as in Arc.
        if let copy = tabs.first(where: { $0.id == keep }), let home = carriedHome(copy) {
            settleNow()
            pairs.removeAll { $0 == pair || ($0.first == pair.first && $0.second == pair.second) }
            rememberSplit()
            select(home)
            return
        }
        leave(pair, keeping: keep) { [self] in
            pairs.removeAll { $0 == pair || ($0.first == pair.first && $0.second == pair.second) }
        }
    }

    /// One half going, closed or separated, while the pair is on screen:
    /// the other is held, then grows to the whole width over the one going,
    /// and is made its new size once it has.
    func leave(_ pair: Pair, keeping keep: Tab.ID, change: @escaping () -> Void) {
        guard stagePair?.contains(keep) == true else {
            change()
            rememberSplit()
            return
        }
        splitBook.turns += 1
        let turn = splitBook.turns
        splitBook.frozen = true
        splitting = true
        splitBook.pending = change
        splitBook.keep = keep
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            guard splitBook.turns == turn else { return }
            splitBook.pending = nil
            splitBook.keep = nil
            change()
            wide = keep
            if activeID != keep, let tab = tabs.first(where: { $0.id == keep }) {
                activeID = tab.id
            }
            restage()
            rememberSplit()
            settleSplit(turn) { [self] in
                splitBook.frozen = false
                wide = nil
                restage()
            }
        }
    }

    /// A change of shape cut short: another tab picked, or one closed,
    /// while a pair came together or apart. What it was doing is done at
    /// once, and its later steps find they are no longer wanted; left to
    /// run, the stage kept the pair it was leaving, and the page area stood
    /// empty until it was over.
    func settleNow() {
        guard splitBook.frozen || wide != nil || splitting || splitBook.pending != nil else { return }
        splitBook.turns += 1
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            let change = splitBook.pending
            let keep = splitBook.keep
            splitBook.pending = nil
            splitBook.keep = nil
            change?()
            // The half closed was the one in front: the one staying is,
            // as the unhurried way has it.
            if let keep, !tabs.contains(where: { $0.id == activeID }), tabs.contains(where: { $0.id == keep }) {
                activeID = keep
            }
            splitBook.frozen = false
            wide = nil
            splitting = false
            restage()
        }
    }

    /// The command in ⌘T's list: from an empty private tab, the page it was
    /// opened from on the left and this tab, still asking for an address,
    /// on the right; from a page, the field, asking for the half beside it:
    /// the pair comes with the place it is for, never with an empty half.
    func splitView() {
        guard let active, pair(of: active.id) == nil else { return }
        // Asked for where it can't be had: why, in the corner, rather
        // than nothing at all.
        if let reason = splitRefusal(active) {
            announce(reason, mark: "rectangle.split.2x1")
            return
        }
        Teach.shared.used(.split)
        if active.isBlank, let neighbor = splitNeighbor {
            // The page it came from on the left, this tab on the right and
            // still in front, still asking. Nothing on screen changes shape:
            // an empty tab has no page to hold.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                var row = tabs.filter { $0.id != active.id }
                let at = (row.firstIndex { $0.id == neighbor.id } ?? row.count - 1) + 1
                row.insert(active, at: at)
                pairs.append(Pair(first: neighbor.id, second: active.id))
                lay(row)
                splitBook.frozen = false
                restage()
            }
            if !neighbor.wake() { neighbor.revive() }
            rememberSplit()
            return
        }
        // A pin too: a copy of its page makes the pair (`carried`).
        openFresh(.split)
    }

    /// Why Split View can't be had for this page in front, as the corner
    /// says it; nil when it can.
    func splitRefusal(_ page: Tab) -> String? {
        if !splitFits { return "Window is too narrow for Split View" }
        if page.isBlank { return splitNeighbor == nil ? "Open another tab to use Split View" : nil }
        if page.bench || folderBook.theirs(page) || Agents.shared.sealed(page) { return "Split View isn’t available for this tab" }
        return nil
    }

    /// Whether the page in front can take a half: as `canPlace`, or a pin,
    /// whose copy goes in while it stays in the grid (`carried`).
    func canHost(_ page: Tab) -> Bool {
        canPlace(page) || (page.pin != nil && !page.bench && !folderBook.theirs(page)
            && pair(of: page.id) == nil && page.address != nil && tabs.contains { $0.id == page.id })
    }

    /// Whether Split View's field can put this open tab beside the page:
    /// a loose tab of yours, here, or in another window of this space that
    /// Move Tab Here would bring over. Not the page itself, a pin, one in a
    /// pair or a folder, nor Yab's own work out of sight.
    func splitTakes(_ tab: Tab) -> Bool {
        guard let page = active, !page.isBlank, canHost(page), splitFits, tab.id != page.id,
              !tab.isBlank, tab.address != nil, !Agents.shared.sealed(tab) else { return false }
        if tabs.contains(where: { $0.id == tab.id }) { return canCarry(tab, beside: page) }
        guard let owner = BrowserWindows.shared.owner(of: tab.id)?.browser, owner.spaceID == spaceID else { return false }
        return tab.pin == nil && !tab.bench && !tab.shy && !tab.onCall
            && owner.partner(of: tab) == nil && owner.folderBook.place(of: tab) == nil
    }

    /// Split View's field, given a tab already open: that tab beside the
    /// page, brought over first from another window, quietly, the page
    /// staying in front until the pair comes in.
    func splitBeside(_ page: Tab, with tab: Tab) {
        if !tabs.contains(where: { $0.id == tab.id }) {
            guard let owner = BrowserWindows.shared.owner(of: tab.id)?.browser,
                  BrowserWindows.shared.move(tab, from: owner, to: self, announce: false, selecting: false) else { return }
        }
        guard canCarry(tab, beside: page) else { return select(tab) }
        split(tab, with: page)
    }

    // MARK: - ⌥-click on a tab

    /// What a click on a tab's row does with the keys held: ⇧ picks the run
    /// to it, ⌘ picks it alone, ⌥ puts it beside the page in front, ⌥⇧ with
    /// Settings › Tabs' switch on (`groups`) puts it in a folder with the
    /// page in front, as Dia's ⌥⇧-click (groupClick).
    enum RowClick: Equatable { case open, extend, gather, split, group }

    nonisolated static func rowClick(_ flags: NSEvent.ModifierFlags, groups: Bool = false) -> RowClick {
        let held = flags.intersection(.deviceIndependentFlagsMask)
        if groups, held.contains(.shift), held.contains(.option), !held.contains(.command) { return .group }
        if held.contains(.shift) { return .extend }
        if held.contains(.command) { return .gather }
        if held.contains(.option) { return .split }
        return .open
    }

    /// Where ⌥-click puts a tab: nowhere if it is the page in front; beside
    /// it; or, the page in front being half of a pair already, in place of
    /// its other half, which stays a tab just after the pair. A pair holds
    /// two, where Arc's split takes up to four. The other half itself is
    /// only brought in front, as a plain click does.
    enum SplitClick: Equatable { case nothing, open, beside, instead(Tab.ID) }

    nonisolated static func splitClick(clicked: Tab.ID, current: Tab.ID?, partner: Tab.ID?) -> SplitClick {
        guard let current else { return .open }
        if clicked == current { return .nothing }
        guard let partner else { return .beside }
        return clicked == partner ? .open : .instead(partner)
    }

    /// ⌥-click on a tab's row. A pin, a kept tab or one in a folder of yours
    /// stays where it is: a copy of its page goes in, as a drag does
    /// (`carried`). Where no pair can be made, it opens as a click would.
    func splitClick(_ tab: Tab) {
        guard let current = active, splitFits, !Agents.shared.sealed(tab) else { return select(tab) }
        switch Self.splitClick(clicked: tab.id, current: current.id, partner: pair(of: current.id)?.other(than: current.id)) {
        case .nothing:
            return
        case .open:
            select(tab)
        case .beside:
            guard canCarry(tab, beside: current) else { return select(tab) }
            split(tab, with: current)
        case .instead(let partner):
            guard let both = pair(of: current.id), pair(of: tab.id) == nil, !tab.bench,
                  !folderBook.theirs(tab), tab.address != nil else { return select(tab) }
            replace(partner, in: both, with: carried(tab))
        }
    }

    /// ⌥-click on a link: its page opens beside the one it was clicked in,
    /// as ⌥-click on a tab puts that tab there; in a pair already, in place
    /// of the other half. Where no pair can be made, a tab after the page,
    /// as ⌘-click.
    func splitLink(_ url: URL, from source: Tab?) {
        guard let source, splitFits, !source.bench, !folderBook.theirs(source),
              tabs.contains(where: { $0 === source }) else {
            openBeside(url, from: source, foreground: false)
            return
        }
        if source.id != activeID { select(source) }
        let opened = open(url, foreground: false, from: source, linked: true)
        if let both = pair(of: source.id) {
            replace(both.other(than: source.id), in: both, with: opened)
        } else {
            split(opened, with: source)
        }
    }

    /// ⌥↩ or ⌥-click on a place in ⌘T's or ⌘L's field, as in Arc's
    /// command bar: it opens beside the page in front, as ⌥-click on a link
    /// does (`splitLink`); in a pair already, in place of the other half,
    /// which stays a tab after the pair. False where no pair can be had:
    /// no page, an empty tab, a window too narrow, a tab that can't split.
    /// Whether ⌥↩ in the field would put a place beside the page in
    /// front, for the row's actions in ⌘K's list to offer it.
    var splitsBeside: Bool {
        guard let page = active, !page.isBlank, splitFits, splitRefusal(page) == nil else { return false }
        return pair(of: page.id) != nil || canHost(page)
    }

    @discardableResult
    func splitOpen(_ url: URL, beside page: Tab?) -> Bool {
        guard let page, !page.isBlank, splitFits, splitRefusal(page) == nil,
              tabs.contains(where: { $0 === page }) else { return false }
        if let both = pair(of: page.id) {
            let opened = open(url, foreground: false, from: page)
            replace(both.other(than: page.id), in: both, with: opened)
            return true
        }
        guard canHost(page) else { return false }
        let opened = open(url, foreground: false, from: page)
        if canCarry(opened, beside: page) { split(opened, with: page) } else { select(opened) }
        return true
    }

    // MARK: - a tab let go over the pages (SplitDeck)

    func dropSplit(_ tab: Tab, _ drop: SplitDeck.Drop) {
        switch drop {
        case .open:
            // Over the middle of the page: that tab, in front, as a click on
            // its row would, as Arc does.
            select(tab)
        case .beside(let side):
            guard let current = active else { return }
            split(tab, with: current, leading: side == .left)
        case .instead(let id):
            guard let pair = stagePair, pair.contains(id) else { return }
            // A pin stays in the grid: a copy of its page takes the half.
            replace(id, in: pair, with: tab.pin != nil ? carried(tab) : tab)
        case .swap:
            guard let pair = stagePair, pair.contains(tab.id) else { SplitDeck.shared.land(); return }
            swapHalves(pair)
        case .chat:
            // Over the chat's column: the tab goes with the next message,
            // as one dragged there from another window would (ChatColumn.take).
            chatAttach.add(.tab(tab.id), chat: chatHistory ? nil : Chats.shared.chat(chatID), browser: self)
            chatFocus += 1
        }
        // The card lands as the half now made, or steps aside.
        SplitDeck.shared.land()
    }

    /// The two halves change places, each keeping its width: the divider
    /// comes to where the other's share puts it. Both pages are held first,
    /// in a pass of their own, then each is carried to its new place and its
    /// outline drawn there by Core Animation (see `Reshape`), as cards
    /// regrouped travel to their slots; each is made its new width once, when
    /// that is over.
    func swapHalves(_ pair: Pair) {
        settleNow()
        // Carried by the deck, pictures of the two over pages laid out at
        // once: no hold, no pass to hold them and none to let go.
        if SplitDeck.shared.canCarrySwap, let a = tabs.firstIndex(where: { $0.id == pair.first }),
           let b = tabs.firstIndex(where: { $0.id == pair.second }) {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                var row = tabs
                row.swapAt(a, b)
                lay(row)
            }
            rememberSplit()
            return
        }
        splitBook.turns += 1
        let turn = splitBook.turns
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { splitting = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            guard splitBook.turns == turn, let a = tabs.firstIndex(where: { $0.id == pair.first }),
                  let b = tabs.firstIndex(where: { $0.id == pair.second }) else {
                withTransaction(still) { splitting = false }
                return
            }
            withTransaction(still) {
                // Taken past each other in the row: keepPairs turns the pair
                // round to match, first for second and the share with them.
                var row = tabs
                row.swapAt(a, b)
                lay(row)
            }
            rememberSplit()
            settleSplit(turn)
        }
    }

    /// `tab` in place of the half `id`, and in front: the half it takes
    /// stays a tab, just after the pair in the row.
    func replace(_ id: Tab.ID, in pair: Pair, with tab: Tab) {
        // A copy of a pin or a kept page (`carried`) is not in the row yet.
        let copy = tab.pin == nil && !tabs.contains { $0.id == tab.id }
        guard canPlace(tab) || copy, let index = pairs.firstIndex(of: pair),
              let old = tabs.first(where: { $0.id == id }) else { return }
        settleNow()
        cancelTabEdit()
        editing = false
        typed = ""
        let partner = pair.other(than: id)
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if floating == tab.id { land(home: true) }
            // One place for the pair, the kept or filed one's (pairRow).
            if let mate = tabs.first(where: { $0.id == partner }) {
                let (anchor, moving) = (tab.kept || tab.nest != nil) && !(mate.kept || mate.nest != nil) ? (tab, mate) : (mate, tab)
                moving.nest = anchor.nest
                moving.kept = anchor.kept
            }
            var row = tabs.filter { $0.id != tab.id && $0.id != id }
            guard let at = row.firstIndex(where: { $0.id == partner }) else { return }
            var next = pair
            if pair.count > 2 {
                // In the pane's place, the dividers where they are; the
                // pane it takes stays a tab just after the split.
                let ids = pair.ids.map { $0 == id ? tab.id : $0 }
                next.first = ids[0]
                next.second = ids[1]
                next.more = Array(ids.dropFirst(2))
                row = tabs.filter { $0.id != tab.id }
                guard let here = row.firstIndex(where: { $0.id == id }) else { return }
                row[here] = tab
                let end = (row.firstIndex { $0.id == ids[ids.count - 1] } ?? here) + 1
                row.insert(old, at: min(end, row.count))
            } else {
                let first = pair.first == id
                row.insert(tab, at: first ? at : at + 1)
                row.insert(old, at: at + 2)
                if first { next.first = tab.id } else { next.second = tab.id }
            }
            // The row and the pair set together: either alone, keepPairs
            // would put the other right by moving tabs about.
            splitBook.keeping = true
            splitBook.staging = true
            pairs[index] = next
            lay(row)
            activeID = tab.id
            splitBook.keeping = false
            splitBook.staging = false
            // The new half takes the stage of the one it replaces.
            restage(from: id)
        }
        if !tab.wake() { tab.revive() }
        tab.touch()
        rememberSplit()
    }

    // MARK: - three or four

    /// Whether `tab` let go on `target`'s row makes a split: beside a lone
    /// tab, as a pair, or one more pane of the split `target` is in.
    func canSplit(_ tab: Tab, onto target: Tab) -> Bool {
        if let pair = pair(of: target.id) { return canAdd(tab, to: pair) }
        return canCarry(tab, beside: target)
    }

    func split(_ tab: Tab, onto target: Tab) {
        if let pair = pair(of: target.id) { addPane(tab, to: pair) } else { split(tab, with: target) }
    }

    /// Whether `tab` can join `pair` as one more pane: a split of yours with
    /// room for one, not a pinned pair, and a tab that can be carried in, as
    /// one beside a lone page can (`canCarry`).
    func canAdd(_ tab: Tab, to pair: Pair) -> Bool {
        guard pairs.contains(pair), !pair.contains(tab.id), pinPair(of: pair.first) == nil,
              let next = pair.adding(tab.id),
              splitBook.place.width >= Pair.room(next.count, next.arrangement),
              !tab.bench, !folderBook.theirs(tab), self.pair(of: tab.id) == nil,
              tabs.contains(where: { $0.id == tab.id }), tab.address != nil else { return false }
        return pair.ids.allSatisfy { id in tabs.contains { $0.id == id && !folderBook.theirs($0) } }
    }

    /// `tab` as one more pane of `pair`, after its last, and in front. A pin,
    /// a kept tab or a filed one stays where it is and a copy of its page
    /// goes in (`carried`), as into a pair.
    func addPane(_ given: Tab, to pair: Pair) {
        guard canAdd(given, to: pair) else { return }
        settleNow()
        let tab = carried(given)
        guard let index = pairs.firstIndex(of: pair), let next = pair.adding(tab.id),
              let last = self.tab(id: pair.ids[pair.ids.count - 1]) else { return }
        Teach.shared.used(.split)
        cancelTabEdit()
        editing = false
        typed = ""
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if floating == tab.id { land(home: true) }
            // In the split's one place, as a half joins its pair's (pairRow).
            tab.nest = last.nest
            tab.kept = last.kept
            var row = tabs.filter { $0.id != tab.id }
            let at = (row.firstIndex { $0.id == last.id } ?? row.count - 1) + 1
            row.insert(tab, at: at)
            // The row and the split set together, as `replace` sets them.
            splitBook.keeping = true
            splitBook.staging = true
            pairs[index] = next
            lay(row)
            activeID = tab.id
            splitBook.keeping = false
            splitBook.staging = false
            restage()
        }
        if !tab.wake() { tab.revive() }
        tab.touch()
        folderBook.refresh()
        rememberSplit()
    }

    /// Whether the split can be laid this way: two side by side or
    /// stacked; three and four have their grid alone. A pinned pair's
    /// square holds two side by side.
    func canArrange(_ pair: Pair, _ arrangement: Pair.Arrangement) -> Bool {
        pair.count == 2 && arrangement != .grid && pair.arrangement != arrangement && pairs.contains(pair)
            && pinPair(of: pair.first) == nil && splitBook.place.width >= Pair.room(pair.count, arrangement)
    }

    /// The split laid another way, its dividers even.
    func arrange(_ pair: Pair, _ arrangement: Pair.Arrangement) {
        guard canArrange(pair, arrangement), let next = pair.with(pair.ids, arrangement) else { return }
        settleNow()
        guard let index = pairs.firstIndex(of: pair) else { return }
        pairs[index] = next
        rememberSplit()
    }

    /// One pane of three or four out of the split: it stays a tab, just
    /// after the split in the row, and the rest are laid evenly in the room.
    func removePane(_ id: Tab.ID, from pair: Pair) {
        guard pair.count > 2, let index = pairs.firstIndex(of: pair), let next = pair.removing(id) else { return }
        settleNow()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            var row = tabs.filter { $0.id != id }
            if let tab = tab(id: id), let at = row.firstIndex(where: { $0.id == next.ids[next.ids.count - 1] }) {
                row.insert(tab, at: at + 1)
            }
            splitBook.keeping = true
            splitBook.staging = true
            pairs[index] = next
            lay(row)
            // The pane in front gone: the one before it, or after the first.
            if activeID == id, let at = pair.ids.firstIndex(of: id) { activeID = next.ids[max(0, at - 1)] }
            splitBook.keeping = false
            splitBook.staging = false
            restage()
        }
        rememberSplit()
    }

    /// The cross on a half's band: that half leaves the pair and stays a
    /// tab, just after the other in the row; the other takes the width.
    func leaveSplit(_ id: Tab.ID) {
        guard let pair = pair(of: id) else { return }
        // One of three or four: the rest stay a split. A pin's copy goes
        // with the pane it was (`dropCarried`).
        if pair.count > 2 {
            splitHint.leaving = nil
            return removePane(id, from: pair)
        }
        // A half of a pinned pair: put down, the square keeps both
        // (PinPairs.swift).
        if pinPair(of: id) != nil, let half = tab(id: id) {
            splitHint.leaving = nil
            if !putDownPinHalf(half) { close(half) }
            return
        }
        // Its picture flies into its row, where it now lives, as the other
        // grows over the place it had.
        // A pin's copy goes with the pair (`dropCarried`): into the pin.
        if splitShown, let page = SplitDeck.pageFrame(of: id) {
            let home = tabs.first { $0.id == id }.flatMap(carriedHome)
            SplitDeck.shared.flyHome(home?.id ?? id, from: page, in: self)
        }
        splitHint.leaving = nil
        separate(pair, keeping: pair.other(than: id))
    }

    /// A click in the half that isn't in front: that half is.
    func focus(_ tab: Tab) {
        guard tab.id != activeID, stagePair?.contains(tab.id) == true else { return }
        cancelTabEdit()
        dropChoice()
        if editing {
            editing = false
            typed = ""
        }
        activeID = tab.id
        tab.touch()
    }

    /// The other half of the tab brought to the front, awake too: both are
    /// on screen; every other pane, of three or four.
    func wakePartner(of tab: Tab) {
        for other in mates(of: tab.id).compactMap({ self.tab(id: $0) }) where !other.pairRest {
            if !other.wake() { other.revive() }
            other.touch()
        }
    }

    // MARK: - the divider

    func beginSplitDrag() {
        splitDrag.armed = false
        splitDrag.waiting = nil
        guard !Browser.splitLive else { splitDrag.armed = true; return }
        splitHeld = true
        // Held in a pass of its own before anything moves, as for ⇧⌘S.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            guard splitHeld else { return }
            splitDrag.armed = true
            // Moved by layers from here on, if the pages can be: SwiftUI is
            // left where it is until the hand lets go.
            if SplitRule.shared.begin(self) {
                splitDrag.ruled = true
                if let waiting = splitDrag.waiting { SplitRule.shared.move(to: waiting) }
                return
            }
            if let waiting = splitDrag.waiting { splitDrag.share = waiting }
            if let waiting = splitDrag.waitingCuts { splitDrag.cuts = waiting }
        }
    }

    /// A divider of three or four panes, or of two stacked, in the hand:
    /// every divider's place, kept to what each pane needs. Never by
    /// SplitRule's layers, which know two halves. A grid's column and row
    /// dividers never meet along a line, so neither pushes the other.
    func dragCuts(to cuts: [CGFloat]) {
        guard let pair = stagePair else { return }
        let cuts = SplitLayout.held(cuts, pair.count, pair.arrangement, in: splitBook.place.size)
        if splitDrag.armed {
            if splitDrag.cuts != cuts { splitDrag.cuts = cuts }
        } else {
            splitDrag.waitingCuts = cuts
        }
    }

    func dragSplit(to share: CGFloat) {
        let share = Pair.held(share, in: splitBook.room)
        if splitDrag.ruled {
            splitDrag.waiting = share
            SplitRule.shared.move(to: share)
        } else if splitDrag.armed {
            if splitDrag.share != share { splitDrag.share = share }
            if Browser.splitLive, let pair = stagePair { setShare(share, of: pair) }
        } else {
            splitDrag.waiting = share
        }
    }

    /// Let go: the share kept, and the two pages made their new widths,
    /// once, a frame after the last move was drawn.
    ///
    /// The share and the hold are set outside a transaction. Set in one,
    /// SwiftUI drew the window at once from the first willSet, restage's
    /// `stagePair`, before it held the new share, and took no notice of
    /// the writes after it: the halves stayed at the share before, the
    /// pages at the new one (frames_ab split-drags, 11 drags of 12).
    func endSplitDrag() {
        if let share = splitDrag.share ?? splitDrag.waiting, let pair = stagePair {
            setShare(share, of: pair)
        }
        if let cuts = splitDrag.cuts ?? splitDrag.waitingCuts, let pair = stagePair {
            setCuts(cuts, of: pair)
        }
        splitDrag.grabbed = nil
        splitDrag.grabbedCuts = nil
        splitDrag.waitingCuts = nil
        splitDrag.armed = false
        splitDrag.waiting = nil
        let ruled = splitDrag.ruled
        if ruled { SplitRule.shared.end() }
        DispatchQueue.main.async { [self] in
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                splitDrag.share = nil
                splitDrag.cuts = nil
                if ruled { splitDrag.ruled = false }
            }
            splitHeld = false
        }
    }

    /// A double-click on the divider: halves again, drawn there as the
    /// halves are when a pair comes together.
    func equalizeSplit() {
        if let pair = stagePair, !pair.halves {
            let even = Pair.even(pair.count, pair.arrangement)
            guard wide == nil, zip(even, pair.allCuts).contains(where: { abs($0 - $1) > 0.001 }) else { return }
            return setCuts(even, of: pair)
        }
        guard let pair = stagePair, wide == nil, abs(pair.share - 0.5) > 0.001 else { return }
        splitBook.turns += 1
        let turn = splitBook.turns
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { splitting = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            guard splitBook.turns == turn, let pair = stagePair else { return }
            withTransaction(still) { setShare(0.5, of: pair) }
            settleSplit(turn)
        }
    }

    private func setShare(_ share: CGFloat, of pair: Pair) {
        guard let index = pairs.firstIndex(where: { $0.first == pair.first && $0.second == pair.second }) else { return }
        pairs[index].share = share
        stagePair = pairs[index]
        rememberSplit()
    }

    private func setCuts(_ cuts: [CGFloat], of pair: Pair) {
        guard let index = pairs.firstIndex(where: { $0.ids == pair.ids }), cuts.count == pair.allCuts.count else { return }
        pairs[index].share = cuts[0]
        pairs[index].cuts = Array(cuts.dropFirst())
        stagePair = pairs[index]
        rememberSplit()
    }

    /// For measuring: the pages made their new widths on every move of the
    /// divider, as a browser without the hold would (`split.drag` = live).
    /// Read once, and only in a test world: it is asked on every move.
    static var splitLive = Store.testing && Store.settings.string(forKey: "split.drag") == "live"

    // MARK: - how narrow the window goes

    /// With a pair on screen the window goes no narrower than two halves
    /// and whatever stands round them, the column, the insets; with none,
    /// as narrow as ever. Never wider than it is: a pair brought back into
    /// a window too narrow for it, or the column let out, halves the page
    /// it has, and the window is not pulled out from under the hand.
    /// Measured on this browser's own window: the active one, wider, gave
    /// a window behind it a least width over its own, and SwiftUI widened
    /// it from inside the window's layout, which AppKit stops with an
    /// exception (crash #35).
    func floorWindow() {
        var floor = Self.narrowestWindow
        let room = splitBook.place.width
        if stagePair != nil, room > 0, let window = BrowserWindows.shared.window(for: self) ?? Links.window {
            let width = window.contentRect(forFrameRect: window.frame).width
            floor = max(floor, min(width, width - room + splitWidth))
        }
        if windowFloor != floor { windowFloor = floor }
        applyWindowFloorSoon()
    }

    /// The content measured a new least size (WindowFloorLayout).
    func noteContentFloor(_ size: CGSize) {
        guard size != contentFloor else { return }
        contentFloor = size
        applyWindowFloorSoon()
    }

    /// The window's least size is Yab's to give it, on a turn of the run
    /// loop of its own: given by SwiftUI from inside a layout pass, it
    /// reshaped a full-screen window's tile in the middle of the screen
    /// being unlocked, and AppKit's full-screen toolbar threw (crash #96).
    /// A window in full screen can't be resized; it gets its least size as
    /// it leaves (BrowserWindows.register).
    func applyWindowFloorSoon() {
        guard !floorSoon else { return }
        floorSoon = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            floorSoon = false
            applyWindowFloor()
        }
    }

    func applyWindowFloor() {
        guard let window = BrowserWindows.shared.window(for: self), !window.styleMask.contains(.fullScreen) else { return }
        let least = Self.leastWindow(floor: windowFloor, content: contentFloor)
        if window.contentMinSize != least { window.contentMinSize = least }
    }

    /// The window's least content size: the pair's floor, the content's own
    /// least, and never under the narrowest window or `leastHeight`.
    nonisolated static func leastWindow(floor: CGFloat, content: CGSize) -> CGSize {
        CGSize(width: max(narrowestWindow, floor, content.width).rounded(.up),
               height: max(leastHeight, content.height).rounded(.up))
    }

    /// The widest the column can stand docked beside the pair on screen
    /// and leave both halves their least: without a pair, any width.
    var columnMost: CGFloat {
        guard stagePair != nil, splitBook.place.width > 0 else { return .infinity }
        return splitBook.place.width + sideShown - splitWidth
    }

    /// The page the split on screen needs: two halves, or every pane as it
    /// is laid.
    var splitWidth: CGFloat {
        stagePair.map { Pair.room($0.count, $0.arrangement) } ?? Pair.room
    }

    /// The window's own least width, without a pair (see YabApp).
    nonisolated static let narrowestWindow: CGFloat = 640
    /// And its least height.
    nonisolated static let leastHeight: CGFloat = 420

    // MARK: - which half a click is in

    /// Clicks are watched only while two halves are on screen: a click in
    /// the one not in front brings it to the front, and goes on to the page.
    private func watchHalves() {
        if stagePair != nil, splitBook.clicks == nil {
            splitBook.clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.clicked(event) }
                return event
            }
        } else if stagePair == nil, let clicks = splitBook.clicks {
            NSEvent.removeMonitor(clicks)
            splitBook.clicks = nil
            splitBook.frames = [:]
        }
    }

    /// Only a click that lands on a half's page itself: the view hit is
    /// that page's stage or inside it. Whatever floats over the halves, the
    /// find bar, a notice, the downloads, the field's list, the column out
    /// over the page, is its own business, wherever it stands.
    private func clicked(_ event: NSEvent) {
        guard splitShown, let window = event.window, window === Links.window,
              let content = window.contentView,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return }
        var view: NSView? = hit
        while let here = view, !(here is StageView) { view = here.superview }
        guard let stage = view as? StageView, let id = stage.shows, id != activeID,
              stagePair?.contains(id) == true, let tab = tabs.first(where: { $0.id == id }) else { return }
        focus(tab)
    }

    func rememberSplit() {
        rememberSession()
    }
}

/// The room the stages stand in: one stage over the whole of it, or two
/// halves and the divider between, by the share; or three or four panes and
/// their dividers.
struct SplitLayout: Layout {
    var share: CGFloat
    /// Room made beside a lone page (SplitPreview): the side the carried
    /// tab would take; the page is placed in the other.
    var room: Side? = nil
    var count = 2
    var arrangement: Pair.Arrangement = .across
    /// Every divider's place, for any split but two side by side.
    var cuts: [CGFloat] = []

    struct Place: LayoutValueKey {
        static let defaultValue: Side = .whole
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            var side = view[Place.self]
            if let room, side == .whole, subviews.count == 1 { side = room == .left ? .right : .left }
            let frame = frame(for: side, in: bounds)
            view.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
        }
    }

    func frame(for side: Side, in bounds: CGRect) -> CGRect {
        // SwiftUI also places children while finding the window's minimum
        // size. That room can be narrower than the divider, including zero;
        // never hand the page a negative width during those measurements.
        let gap = min(Pair.gap, bounds.width)
        let available = bounds.width - gap
        let left = min(available, Pair.left(in: bounds.width, share: share))
        switch side {
        case .whole: return bounds
        case .left: return CGRect(x: bounds.minX, y: bounds.minY, width: left, height: bounds.height)
        case .right: return CGRect(x: bounds.minX + left + gap, y: bounds.minY, width: available - left, height: bounds.height)
        case .gap: return CGRect(x: bounds.minX + left, y: bounds.minY, width: gap, height: bounds.height)
        case .pane(let at):
            let laid = Self.panes(count, arrangement, cuts: cuts, in: bounds).panes
            return laid.indices.contains(at) ? laid[at] : .zero
        case .cut(let at):
            let laid = Self.panes(count, arrangement, cuts: cuts, in: bounds).cuts
            return laid.indices.contains(at) ? laid[at] : .zero
        }
    }

    /// Where `count` panes laid so stand in `bounds`, in the row's order, and
    /// the dividers between them: down a line, each divider at its place
    /// along the room the panes have, none narrower than `narrowest` or
    /// shorter than `lowest` where there is the room, even where there
    /// isn't; in a grid, one divider between the columns and one between
    /// the rows: of three, the first on the left, the second at upper
    /// right and the third below it, the row divider across the right
    /// column; of four, the fourth below the first, the row divider across
    /// both, so no pane moves as a fourth comes or goes.
    static func panes(_ count: Int, _ arrangement: Pair.Arrangement, cuts: [CGFloat], in bounds: CGRect) -> (panes: [CGRect], cuts: [CGRect]) {
        let count = max(1, count)
        if arrangement == .grid, count >= 3 {
            let xs = line(2, cuts.first ?? 0.5, length: bounds.width, least: Pair.narrowest)
            let ys = line(2, cuts.dropFirst().first ?? 0.5, length: bounds.height, least: Pair.lowest)
            let cell = { (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) in
                CGRect(x: bounds.minX + x.lowerBound, y: bounds.minY + y.lowerBound, width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
            }
            let (left, right) = (xs.spans[0], xs.spans[1])
            let (top, bottom) = (ys.spans[0], ys.spans[1])
            let whole = CGFloat(0)...bounds.height
            let column = xs.gaps[0], row = ys.gaps[0]
            let panes = count == 3 ? [cell(left, whole), cell(right, top), cell(right, bottom)]
                : [cell(left, top), cell(right, top), cell(right, bottom), cell(left, bottom)]
            let across = count == 3 ? right : CGFloat(0)...bounds.width
            return (panes, [cell(column, whole), cell(across, row)])
        }
        let across = arrangement != .stacked
        let laid = line(count, cuts, length: across ? bounds.width : bounds.height, least: across ? Pair.narrowest : Pair.lowest)
        let place = { (span: ClosedRange<CGFloat>) in
            across ? CGRect(x: bounds.minX + span.lowerBound, y: bounds.minY, width: span.upperBound - span.lowerBound, height: bounds.height)
                : CGRect(x: bounds.minX, y: bounds.minY + span.lowerBound, width: bounds.width, height: span.upperBound - span.lowerBound)
        }
        return (laid.spans.map(place), laid.gaps.map(place))
    }

    private static func line(_ count: Int, _ cut: CGFloat, length: CGFloat, least: CGFloat) -> (spans: [ClosedRange<CGFloat>], gaps: [ClosedRange<CGFloat>]) {
        line(count, [cut], length: length, least: least)
    }

    /// `count` spans down a line this long, a divider between each two at
    /// its place among `cuts`, each span at least `least` where the line
    /// has the room for all of them at that, and two never under a quarter
    /// of it, as a pair's halves.
    private static func line(_ count: Int, _ cuts: [CGFloat], length: CGFloat, least: CGFloat) -> (spans: [ClosedRange<CGFloat>], gaps: [ClosedRange<CGFloat>]) {
        let gap = min(Pair.gap, max(0, length) / CGFloat(max(1, count)))
        let room = max(0, length - gap * CGFloat(count - 1))
        let least = min(room / CGFloat(count), max(least, count == 2 ? room * Pair.least : 0))
        var spans: [ClosedRange<CGFloat>] = []
        var gaps: [ClosedRange<CGFloat>] = []
        var start: CGFloat = 0
        for at in 0..<count {
            var end = room
            if at < count - 1 {
                let place = at < cuts.count && cuts[at].isFinite ? cuts[at] : CGFloat(at + 1) / CGFloat(count)
                let low = start + least, high = room - CGFloat(count - 1 - at) * least
                end = min(room, max(start, (min(high, max(low, room * place))).rounded()))
            }
            let offset = CGFloat(at) * gap
            spans.append((start + offset)...(end + offset))
            if at < count - 1 { gaps.append((end + offset)...(end + offset + gap)) }
            start = end
        }
        return (spans, gaps)
    }

    /// The dividers' places as a room this big shows them, kept to what each
    /// pane needs: what a divider let go of stays where it was drawn.
    static func held(_ cuts: [CGFloat], _ count: Int, _ arrangement: Pair.Arrangement, in size: CGSize) -> [CGFloat] {
        let bounds = CGRect(origin: .zero, size: size)
        let laid = panes(count, arrangement, cuts: cuts, in: bounds)
        guard size.width > 0, size.height > 0, laid.cuts.count == cuts.count else { return cuts }
        if arrangement == .grid, count >= 3 {
            let width = max(1, size.width - laid.cuts[0].width), height = max(1, size.height - laid.cuts[1].height)
            return [laid.panes[0].width / width, laid.panes[1].height / height]
        }
        let across = arrangement != .stacked
        let length = max(1, (across ? size.width : size.height) - laid.cuts.reduce(0) { $0 + (across ? $1.width : $1.height) })
        var reached: CGFloat = 0
        return laid.panes.dropLast().map { pane in
            reached += across ? pane.width : pane.height
            return reached / length
        }
    }
}

/// The window's root. SwiftUI sets a window's least and greatest size from
/// what its content measures at a zero and an infinite offer, and when
/// those change it reshapes the window then and there, inside the layout
/// pass, through a full-screen window's tile too (crash #96). Here the
/// content's least size is measured and said (`measured`, for
/// Browser.applyWindowFloor), and SwiftUI is answered the same at those
/// offers whatever the content holds, so it never touches the window again.
struct WindowFloorLayout: Layout {
    let measured: (CGSize) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return proposal.replacingUnspecifiedDimensions() }
        if proposal.width == 0 || proposal.height == 0 { measured(content.sizeThatFits(.zero)) }
        let ideal = proposal.width == nil || proposal.height == nil ? content.sizeThatFits(.unspecified) : .zero
        return CGSize(width: max(Browser.narrowestWindow, proposal.width ?? ideal.width),
                      height: max(Browser.leastHeight, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // With no host sizing options, SwiftUI need not make a zero-size
        // probe. Still tell Yab the content's floor during actual layout;
        // Browser applies it on its own turn, outside this layout pass.
        if let content = subviews.first { measured(content.sizeThatFits(.zero)) }
        for view in subviews { view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }

    /// A measurement must leave the layout pass even on the main thread:
    /// writing Observable Browser state here invalidates the graph SwiftUI
    /// is evaluating (crashes #651/#849). The queue also handles background
    /// layout without consulting Swift's current-executor bookkeeping.
    nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { AppKitMainThread.sync { work() } }
    }

    /// The browser's size, including its least size, belongs to AppKit and
    /// Browser.applyWindowFloor. Even intrinsic sizing is unnecessary here.
    @MainActor
    static func host<Content: View>(_ root: Content) -> NSHostingView<Content> {
        let host = WindowHosting.host(root)
        host.safeAreaRegions = []
        return host
    }
}

extension View {
    /// The window's root, its least size given by Yab (WindowFloorLayout).
    func windowFloor(_ browser: Browser) -> some View {
        WindowFloorLayout(measured: { [weak browser] size in
            WindowFloorLayout.onMain { browser?.noteContentFloor(size) }
        }) { self }
        // Keep the root's proposal stable too, including the first window
        // hosted by SwiftUI. The fullscreen title bar overlays our content.
        .ignoresSafeArea()
    }
}

/// The halves' room, the only thing that watches the divider while it is in
/// the hand. What stands in it is built by the window and handed in whole.
struct SplitRoom<Content: View>: View {
    @ObservedObject var drag: SplitDrag
    @ObservedObject var preview: SplitPreview
    let share: CGFloat
    /// The split on screen, for three or four panes or two stacked.
    let shape: Pair?
    let book: SplitBook
    /// The room changed width: the window's least width follows.
    let measured: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        SplitLayout(share: drag.share ?? share, room: preview.room, count: shape?.count ?? 2,
                    arrangement: shape?.arrangement ?? .across, cuts: drag.cuts ?? shape?.allCuts ?? []) { content }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [book] in
                let wider = book.room != $0.width
                book.room = $0.width
                book.place = $0
                if wider { measured() }
            }
    }
}

/// The divider: nothing drawn at rest but the room between the two cards;
/// under the pointer the resize cursor and a short grip. Drag to move it,
/// double-click to make the halves even again.
struct SplitDivider: View {
    @ObservedObject var browser: Browser
    @ObservedObject var drag: SplitDrag
    /// The window's ground shows between two pages laid edge to edge.
    let flat: Bool
    /// Of three or four panes, or two stacked, which divider this is (among
    /// `Pair.allCuts`); nil for the one between two halves.
    var cut: Int? = nil
    /// Between two panes one above the other: it lies across the room and
    /// moves up and down.
    var stacked = false

    @State private var hovering = false
    @State private var held = false
    @Environment(\.tone) private var tone

    var body: some View {
        ZStack {
            if flat {
                Palette.ground
                Rectangle().fill(Palette.ink.opacity(0.06)).frame(width: stacked ? nil : 1, height: stacked ? 1 : nil)
            }
            Capsule()
                .fill(Palette.ink.opacity(held ? 0.5 : 0.28))
                .frame(width: stacked ? 28 : 3, height: stacked ? 3 : 28)
                .opacity((hovering || held) && !drag.ruled ? 1 : 0)
                .animation(Motion.quick, value: hovering || held)
            EdgeHandle(
                changed: { travel in
                    if let cut { return move(cut, by: travel) }
                    if !held {
                        held = true
                        browser.splitDrag.grabbed = browser.stagePair?.share ?? 0.5
                        browser.beginSplitDrag()
                    }
                    let room = max(1, browser.splitBook.room - Pair.gap)
                    browser.dragSplit(to: (browser.splitDrag.grabbed ?? 0.5) + travel / room)
                },
                ended: { _, _ in
                    held = false
                    browser.endSplitDrag()
                },
                doubled: { browser.equalizeSplit() },
                hover: { hovering = $0 },
                vertical: stacked
            )
        }
        .frame(width: stacked ? nil : Pair.gap, height: stacked ? Pair.gap : nil)
        .frame(maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity)
    }

    /// This divider carried `travel` along the room, the rest where they
    /// are; up is the way a stacked one's travel counts.
    private func move(_ cut: Int, by travel: CGFloat) {
        guard let pair = browser.stagePair else { return }
        if !held {
            held = true
            browser.splitDrag.grabbedCuts = pair.allCuts
            browser.beginSplitDrag()
        }
        let place = browser.splitBook.place.size
        let lines = pair.arrangement == .grid ? 1 : pair.count - 1
        let room = max(1, (stacked ? place.height : place.width) - CGFloat(lines) * Pair.gap)
        var cuts = browser.splitDrag.grabbedCuts ?? pair.allCuts
        guard cuts.indices.contains(cut) else { return }
        cuts[cut] += (stacked ? -travel : travel) / room
        browser.dragCuts(to: cuts)
    }
}

/// The ground the two tabs of a pair share, in the row or down the column:
/// one tab's, drawn across both halves and the gap between them, with a
/// hairline where one ends and the other starts. At rest it is a pin's faint
/// ground, so the two read as one thing; on screen it is the live tab's
/// gray, across both, and how far in you are reads on the half in front.
struct JointGround: View {
    let joint: Joint
    /// The pair is on screen.
    let lit: Bool
    let hovering: Bool
    /// How far down the page in front is, on the half in front; 0 on the
    /// other.
    let reading: CGFloat
    let gap: CGFloat
    /// Side by side, in the row; one over the other, down the column.
    let across: Bool
    /// One of a pair on screen: a chip lifted off the gray, both halves
    /// alike, as in the column's row (PairRow).
    var front = false
    /// For the frost under it lit (SelectionPlate).
    let prefs: Preferences

    @Environment(\.tone) private var tone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let first = joint == .first
        // A pane between two, of three or four: square at both ends.
        let last = joint == .second
        let round = SideBar.radius
        let shape = across
            ? UnevenRoundedRectangle(
                topLeadingRadius: first ? round : 0, bottomLeadingRadius: first ? round : 0,
                bottomTrailingRadius: last ? round : 0, topTrailingRadius: last ? round : 0,
                style: .continuous)
            : UnevenRoundedRectangle(
                topLeadingRadius: first ? round : 0, bottomLeadingRadius: last ? round : 0,
                bottomTrailingRadius: last ? round : 0, topTrailingRadius: first ? round : 0,
                style: .continuous)
        ZStack(alignment: .leading) {
            // The selection the open tab wears, in this half's outline:
            // square where the halves meet, rounded at the pair's ends.
            SelectionPlate(corner: round, corners: across ? (first ? .leading : last ? .trailing : []) : (first ? .top : last ? .bottom : []),
                           state: lit ? .selected : .resting(hovering: hovering), prefs: prefs, strip: across)
            if front {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.1) : Palette.ground)
                    .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Palette.ink.opacity(0.07), lineWidth: 0.5))
                    .overlay {
                        if reading > 0 {
                            ReadingFill(progress: reading, outline: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                                .fill(Palette.ink.opacity(0.055))
                                .animation(.easeOut(duration: 0.15), value: reading)
                        }
                    }
                    .padding(3) // design: the chip the column's row has, 22 pt in a 28-pt tab
            } else if reading > 0 {
                ReadingFill(progress: reading, outline: shape)
                    .fill(Palette.ink.opacity(0.055))
                    .animation(.easeOut(duration: 0.15), value: reading)
            }
        }
        // Half the gap each, so the two meet in the middle of it.
        .padding(across ? (first ? .trailing : .leading) : (first ? .bottom : .top), -gap / 2)
        .padding(across ? .trailing : .bottom, joint == .middle ? -gap / 2 : 0)
        // The hairline in the middle of the gap, drawn by the second, which
        // lies over the first: drawn by the first, the second's ground
        // covered half of it. The padding above draws past the tab without
        // making its frame any larger, so this overlay starts where the tab
        // does, and the line is carried back by half the gap and half its
        // own width.
        .overlay(alignment: across ? .leading : .top) {
            if !first {
                if across {
                    Rectangle().fill(Palette.ink.opacity(0.1)).frame(width: 1, height: 14).offset(x: -(0.5 + gap / 2))
                } else {
                    // The hairline starts where the titles do, past the mark.
                    Rectangle().fill(Palette.ink.opacity(0.1)).frame(height: 1).padding(.leading, 33).padding(.trailing, 10).offset(y: -(0.5 + gap / 2)) // design: from where the titles start, past the mark, to the slot at the end
                }
            }
        }
    }
}

/// How far down a page is, filled in from the left of the outline it reads
/// in: one path, the outline cut where the reading stands, so no mask, and
/// the tab's corners kept at both ends.
struct ReadingFill<Outline: Shape>: Shape {
    var progress: CGFloat
    let outline: Outline

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let cut = CGRect(x: rect.minX, y: rect.minY, width: rect.width * min(1, max(0, progress)), height: rect.height)
        return outline.path(in: rect).intersection(Path(cut))
    }
}

/// Over a half: a faint outline in the accent while its chip is under the
/// pointer. At once, no curve: a state, not a move. The half whose cross is
/// under the pointer is left as it is: the page grayed over read as gone
/// before anything was pressed.
struct HalfHint: View {
    @ObservedObject var hint: SplitHint
    let id: Tab.ID
    let corner: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous) // design: the half's own corner
        ZStack {
            if hint.hinted == id {
                shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// On a chip, the outline of the one whose half's cross is under the
/// pointer: it goes back to the list.
struct LeaveMark: View {
    @ObservedObject var hint: SplitHint
    let id: Tab.ID

    var body: some View {
        if hint.leaving == id {
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }
}

extension Browser {
    /// The tab whose color the window and its chrome wear: the one in
    /// front, or none while two share the screen, so the window keeps its
    /// own look rather than turning with every click from half to half.
    var dresser: Tab? { stagePair == nil ? active : nil }
}
