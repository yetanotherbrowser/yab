import Foundation

// How the column's spaces move, as Arc moves them (measured frame by frame,
// docs/space-switching.md): the spaces stand side by side, one column wide,
// and the column is a window onto them.
//
// Two fingers carry the row of spaces half as far as they go, never more
// than one space either way, and only as far as there is a space: past the
// last one, or past the next, it gives a little and no more. Let go while
// still moving, even slowly, and the row goes on the way it was going, to
// the next space or back where it began; let go held still, it goes to
// whichever space shows more. A key, a click or a let-go all land on one
// spring, critically damped, a fifth of a second: half the way in 50 ms,
// nine tenths in 120, all of it in about 200, never past.

enum SpacePaging {
    /// Where the column is when two fingers go sideways over it.
    enum Place {
        /// In its place beside the page.
        case docked
        /// Put away and brought out over the page by the edge, or in full
        /// screen: a card.
        case card
        /// Put away and out of sight, or the tabs on top.
        case away
    }

    /// Whether the column's spaces slide as one row there. The card does as
    /// the docked column does: in 0.0.8 it was left out, and a swipe over
    /// it faded the rows with nothing coming under them.
    static func slides(_ place: Place, spaces: Bool, reduceMotion: Bool) -> Bool {
        guard spaces, !reduceMotion else { return false }
        return place != .away
    }

    /// Who paints the column's ground while its spaces slide. Each turns
    /// to the next space's color as far as the row has gone (SpaceWash),
    /// so it must be one ground for the whole row: a ground carried by
    /// each page came in with the page as a rectangle in its own color,
    /// a seam down the column and the head left the old color until the
    /// row landed (edge to edge docked, c768dcbb to ba764a3d).
    enum Ground: Equatable {
        /// The window's backdrop under the column: the pages and the
        /// stage paint none, the backdrop turns.
        case window
        /// The column's own ground (CardGround): left out of the band's
        /// picture, laid once under the row and its doors, and turned
        /// with the column's head and foot around it.
        case row
    }

    /// Whose the ground is for a column at `place` with `backdrop`. Every
    /// way the window can be has to say: a new one doesn't compile.
    static func ground(backdrop: Backdrop, place: Place) -> Ground {
        switch (backdrop, place) {
        // Out over the page as a card the column always paints its own.
        case (_, .card): return .row
        // Edge to edge docked, the column stands on the window's backdrop
        // as on a color (Preferences.edgeBackdrop, #256); before it, on a
        // ground of its own, the one each page carried (ba764a3d).
        case (.none, .docked): return .window
        // On a color or the site's, the docked column is see-through.
        case (.color, .docked), (.site, .docked): return .window
        case (_, .away): return .window
        }
    }

    /// How far the row goes for each point the fingers go.
    static let follow: Double = 0.5
    /// The spring every landing is on: its response, in seconds, and its
    /// damping, 1 being the quickest that never goes past.
    static let response: Double = 0.2
    static let damping: Double = 1
    /// For Core Animation's spring, of mass 1.
    static var stiffness: Double { pow(2 * .pi / response, 2) }
    static var friction: Double { 4 * .pi * damping / response }
    /// How hard the row resists past where it may go: 0.15 of a page per
    /// page pushed at first, less and less after (Arc: 200 points of
    /// fingers at the last space moved it 14).
    static let give: Double = 0.15
    /// Fingers slower than this, in points a second, as they lift are
    /// held still.
    static let still: Double = 5
    /// Moves older than this as the fingers lift say nothing of their speed.
    static let recent: TimeInterval = 0.06
    /// Past the last space Arc brings a "+" in at the column's edge, driven
    /// by how far the row has given there: all the way in at 15 points, its
    /// ring full at 22.5, and a new space only for fingers lifted after it
    /// has been full more than a tenth of a second (Arc 1.173.1's
    /// EdgeFeedbackView, as github.com/VictorKildahl/cra/pull/564 read it).
    static let plusIn: Double = 15
    static let plusFull: Double = 22.5
    static let plusHeld: TimeInterval = 0.1

    /// How far in the "+" is and how full its ring, 0 to 1, for the row
    /// `past` points beyond the last space.
    static func plus(_ past: Double) -> (shown: Double, ring: Double) {
        (min(1, max(0, past / plusIn)), min(1, max(0, past / plusFull)))
    }

    /// Since when the ring has been full, the row now `past` points beyond
    /// the last space at `time`: kept while it stays full, nil once it
    /// isn't, so pulling back short of it and on again starts over.
    static func fullSince(_ was: TimeInterval?, past: Double, at time: TimeInterval) -> TimeInterval? {
        plus(past).ring >= 1 ? was ?? time : nil
    }

    /// Whether fingers lifted at `liftedAt` make a new space, the ring
    /// full since `fullSince` (nil: not full).
    static func makesSpace(fullSince: TimeInterval?, liftedAt: TimeInterval) -> Bool {
        fullSince.map { liftedAt - $0 > plusHeld } ?? false
    }

    /// What `past` points pushed beyond an end move, on a page `page` wide:
    /// nearly all of a small push's give, never a page.
    static func rubber(_ past: Double, page: Double) -> Double {
        guard past > 0, page > 0 else { return 0 }
        return (1 - 1 / (past * give / page + 1)) * page
    }

    /// Where the row stands for the fingers' travel, in points, negative
    /// toward the next space: the travel's half, as far as a whole page
    /// where there is a space that way, and rubber past it.
    static func offset(travel: Double, page: Double, back: Bool, forward: Bool) -> Double {
        let raw = travel * follow
        let low = forward ? -page : 0
        let high = back ? page : 0
        if raw < low { return low - rubber(low - raw, page: page) }
        if raw > high { return high + rubber(raw - high, page: page) }
        return raw
    }

    /// The space the row goes to as the fingers lift: -1 the one before,
    /// 0 where it began, 1 the next. `offset` is where the row stands,
    /// negative toward the next; `speed` the fingers', points a second,
    /// negative toward the next.
    static func landing(offset: Double, speed: Double, page: Double, back: Bool, forward: Bool) -> Int {
        guard page > 0 else { return 0 }
        // How far toward the next space, in spaces.
        let along = -offset / page
        var to: Int
        if abs(speed) >= still {
            // Still moving: on the way it was going, from where it is.
            to = speed < 0 ? Int(along.rounded(.up)) : Int(along.rounded(.down))
        } else {
            // Held: whichever shows more, the one it began at on a tie.
            to = abs(along) > 0.5 ? (along > 0 ? 1 : -1) : 0
        }
        to = max(back ? -1 : 0, min(forward ? 1 : 0, to))
        return to
    }

    /// How fast the fingers were going as they lifted, points a second,
    /// from their last moves, [(when, how far)], and when they lifted.
    static func speed(_ moves: [(TimeInterval, Double)], liftedAt: TimeInterval) -> Double {
        let kept = moves.filter { liftedAt - $0.0 <= recent }
        guard let first = kept.first, let last = kept.last else { return 0 }
        // Resting a moment before lifting: no speed at all.
        if liftedAt - last.0 > recent * 0.75 { return 0 }
        let span = max(last.0 - first.0, 1.0 / 120)
        let moved = kept.dropFirst().map(\.1).reduce(0, +)
        return kept.count < 2 ? last.1 * 120 : moved / span
    }

    /// The spring's way from 1 to 0 at `time`, started moving `velocity`
    /// (of the whole way, a second, toward 0 positive): for the tests and
    /// the film, which lay the measured frames against it.
    static func spring(_ time: Double, velocity: Double = 0) -> Double {
        let w = 2 * .pi / response
        let t = max(0, time)
        if abs(damping - 1) < 1e-9 { return (1 + (w - velocity) * t) * exp(-w * t) }
        if damping < 1 {
            let wd = w * (1 - damping * damping).squareRoot()
            return exp(-damping * w * t) * (cos(wd * t) + (damping * w - velocity) / wd * sin(wd * t))
        }
        let root = (damping * damping - 1).squareRoot()
        let s1 = -w * (damping - root), s2 = -w * (damping + root)
        let c2 = (-velocity - s1) / (s2 - s1)
        return (1 - c2) * exp(s1 * t) + c2 * exp(s2 * t)
    }
}
