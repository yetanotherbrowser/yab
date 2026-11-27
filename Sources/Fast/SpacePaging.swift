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

    /// The row's one state: every change goes through `next`.
    enum Phase: Equatable {
        case idle
        /// Fingers carry the row, taken by a move made at `since`.
        case held(since: TimeInterval)
        /// A key, click or menu raised the row for `target`; its switch sends the spring.
        case turning(target: Int, springs: Int)
        /// A let-go is switching the space itself.
        case releasing(springs: Int)
        case landing(springs: Int)

        var held: Bool { if case .held = self { true } else { false } }
        var target: Int? { if case .turning(let target, _) = self { target } else { nil } }
    }

    enum Event: Equatable {
        case grab(at: TimeInterval)
        case turn(target: Int)
        /// The fingers lifted, seen or lost; `switching` when the row goes to another space.
        case lift(switching: Bool)
        case send
        case switched
        case landed
        case finish
    }

    /// The phase after `event`, or nil when `event` means nothing in `phase`.
    static func next(_ phase: Phase, _ event: Event) -> Phase? {
        switch (phase, event) {
        case (_, .finish): return .idle
        case (.releasing, .grab), (.releasing, .turn): return nil
        case (_, .grab(let at)): return .held(since: at)
        case (.idle, .turn(let target)), (.held, .turn(let target)): return .turning(target: target, springs: 0)
        case (.turning(_, let springs), .turn(let target)), (.landing(let springs), .turn(let target)):
            return .turning(target: target, springs: springs)
        case (.held, .lift(let switching)): return switching ? .releasing(springs: 0) : .landing(springs: 0)
        case (.turning(_, let springs), .send), (.landing(let springs), .send): return .landing(springs: springs + 1)
        case (.releasing(let springs), .send): return .releasing(springs: springs + 1)
        case (.releasing(let springs), .switched): return springs > 0 ? .landing(springs: springs) : .idle
        case (.releasing(let springs), .landed): return .releasing(springs: max(0, springs - 1))
        case (.turning(let target, let springs), .landed): return .turning(target: target, springs: max(0, springs - 1))
        case (.landing(let springs), .landed): return springs > 1 ? .landing(springs: springs - 1) : .idle
        default: return nil
        }
    }

    /// Scrolls quieter than this, with the pointer moved since, mean the lift was lost.
    static let quiet: TimeInterval = 0.3

    /// Two fingers can't move the pointer: one moved after the grab and the last scroll, scrolls quiet, means they lifted.
    static func liftedUnseen(sincePointer: TimeInterval, sinceScroll: TimeInterval, heldFor: TimeInterval) -> Bool {
        sincePointer < heldFor && sincePointer < sinceScroll && sinceScroll > quiet
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

    /// The fingers' travel that holds the row at `offset`, the inverse of `offset(travel:)`.
    static func travel(for offset: Double, page: Double, back: Bool, forward: Bool) -> Double {
        guard page > 0 else { return 0 }
        let low = forward ? -page : 0
        let high = back ? page : 0
        func unrubber(_ moved: Double) -> Double {
            let share = min(moved / page, 0.999)
            return (1 / (1 - share) - 1) * page / give
        }
        let raw: Double
        if offset < low { raw = low - unrubber(low - offset) } else if offset > high { raw = high + unrubber(offset - high) } else { raw = offset }
        return raw / follow
    }

    /// The row's speed for its landing spring, only when it heads where the row lands.
    static func handOff(_ velocity: Double, from offset: Double, to target: Double) -> Double {
        let way = target - offset
        return way * velocity > 0 ? velocity : 0
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
