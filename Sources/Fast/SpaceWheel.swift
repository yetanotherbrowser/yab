import AppKit

// A mouse's wheel sideways over the column goes to the next space or back,
// as Arc's and Dia's sidebars do (feedback #282). Two fingers on a trackpad
// carry the row of spaces under them (SpaceSwipe, SpacePager); a wheel has
// no fingers to follow and no lift, so it turns the space as a key does,
// on the same slide.
//
// What a move says is judged here, apart from AppKit, so the tests can
// play a wheel's events through it: notches of a clicking wheel, the
// same with shift held on the up-and-down wheel, and the stream of small
// moves a smooth mouse sends with no phase. A move more up or down than
// sideways is the rows' own scroll and is left alone (Arc's sidebar turns
// its space on a quick vertical flick too, where its rows end; Yab's
// doesn't).

struct SpaceWheel {
    /// One scroll event, as AppKit has it.
    struct Move: Equatable {
        /// scrollingDeltaX and scrollingDeltaY: lines for a clicking
        /// wheel, points for a precise one.
        var dx: Double
        var dy: Double
        /// hasPreciseScrollingDeltas: a trackpad, a Magic Mouse, a smooth
        /// mouse; false for a wheel that clicks.
        var precise: Bool
        /// Shift held.
        var shift = false
        var time: TimeInterval
    }

    /// The numbers, measured on Arc 1.167 (docs/space-switching.md, "A
    /// mouse's wheel"): one notch alone turned nothing there, two within
    /// 50 ms did, 80 ms apart they didn't; a smooth mouse's 10 points did.
    enum Rule {
        /// A clicking wheel's notches, in lines, a push adds up to before
        /// the space turns: a stray notch, or a tilt bumped, doesn't.
        static let notches: Double = 2
        /// A smooth mouse's points a push adds up to before it turns.
        static let points: Double = 10
        /// Before the first turn, moves further apart than this don't add
        /// up: single notches far apart are bumps, not a push.
        static let gather: TimeInterval = 0.065
        /// Once the space has turned, the push goes on while its moves come
        /// closer together than this. A hand turning a wheel on leaves 80
        /// to 150 ms between notches, and with only `gather` to hold it,
        /// every gap began a push of its own that turned the space again:
        /// one steady turn went two or three spaces (#822).
        static let quiet: TimeInterval = 0.2
        /// After a turn, the push turns nothing more for this long; moves
        /// after it add up again for the next space, as a held key repeats
        /// after a pause.
        static let hold: TimeInterval = 0.25
    }

    /// The sideways part of a move, negative toward the next space, or nil
    /// when it is the rows' scroll: more up or down than across, or none.
    /// Shift on a clicking wheel scrolls sideways; most mice already have
    /// the system turn it, and where it comes still up or down it is
    /// turned here.
    static func across(_ move: Move) -> Double? {
        var dx = move.dx, dy = move.dy
        if move.shift, !move.precise, dx == 0 { (dx, dy) = (dy, 0) }
        guard dx != 0, abs(dx) > abs(dy) else { return nil }
        return dx
    }

    /// What the push has added up to since it began or last turned.
    private var sum: Double = 0
    /// The way the push goes: the last move's sideways part.
    private var way: Double = 0
    /// When the last move of the push came.
    private var last: TimeInterval = -.infinity
    /// When the push last turned the space, nil while it hasn't.
    private var turned: TimeInterval?

    /// What a move does: 1 the next space, -1 the one before, 0 nothing.
    /// Nil when it isn't the wheel's to take (the rows' scroll); a 0 is
    /// still taken, so the rows under it don't drift sideways.
    mutating func take(_ move: Move) -> Int? {
        guard let dx = Self.across(move) else {
            // Up or down: the rows' scroll, and the end of any push, so a
            // smooth mouse's sideways wobble while scrolling never adds up.
            if move.dx != 0 || move.dy != 0 { reset() }
            return nil
        }
        // A new push after a pause, or one the other way.
        let pause = turned == nil ? Rule.gather : Rule.quiet
        if move.time - last > pause || (way != 0 && (dx < 0) != (way < 0)) {
            sum = 0
            turned = nil
        }
        way = dx
        last = move.time
        // Just turned: the rest of a quick push goes nowhere.
        if let turned, move.time - turned < Rule.hold { return 0 }
        sum += dx
        guard abs(sum) >= (move.precise ? Rule.points : Rule.notches) else { return 0 }
        sum = 0
        turned = move.time
        return dx < 0 ? 1 : -1
    }

    /// Forget the push: the pointer went elsewhere, or fingers took over.
    mutating func reset() {
        sum = 0
        way = 0
        last = -.infinity
        turned = nil
    }
}

extension SpaceWheel.Move {
    /// A scroll event's move.
    init(_ event: NSEvent) {
        self.init(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                  precise: event.hasPreciseScrollingDeltas,
                  shift: event.modifierFlags.contains(.shift), time: event.timestamp)
    }
}
