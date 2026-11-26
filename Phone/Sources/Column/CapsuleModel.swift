import CoreGraphics

/// The capsule of spaces after Safari's tab-group bar, as the approved
/// capsule prototype (capsule.js) moves it: one deterministic model, stepped
/// frame by frame, touched by down/move/up. Everything that moves comes from
/// six springs: where the names are (trackX), the capsule's width (capW),
/// the side buttons stepping out (side), the lens's place on the names (f),
/// the lens pressed (press), and the lens pulled to the middle while a finger
/// drags the names (pull). Nothing jumps.
///
/// Rules for the capsule with side buttons (capsule page, "Rules"):
/// 1. The current name is always in the capsule's middle, at rest and while
///    moving; neighbors are cut by a soft 18 pt edge, an end may stay empty.
/// 2. A tap on another name moves the lens and the names together; the side
///    buttons stay. A tap on the current name only presses the lens.
/// 3. Past 6 pt a drag sends the buttons out and widens the capsule; the
///    words stay under the finger, the lens eases to the middle; let go, the
///    names roll on by velocity x 0.16 and the nearest name comes to the middle.
/// 4. 0.28 s after the names rest, the buttons come back and the capsule narrows.
/// 5. Two names only (Private and one space, or Spaces off): at rest the
///    capsule hugs both words; a tap moves only the lens; after a drag, 0.3 s
///    after the buttons came back, it hugs again.
/// 6. The first or the last name at rest hugs its one neighbor as the pair
///    does, so no end stands empty; a drag still brings any name to the
///    middle, and the hug comes only once the names rest. The lens's end
///    stands `inset` in from the capsule's, as from its top.
///
/// The phone foot holds its width. When both names fit in a compact pair,
/// they stay in place and only the lens follows a drag.
///
/// Coordinates are the screen's points: `mid` is the bar's middle, `trackX`
/// where the first name's left edge stands.
struct CapsuleModel: Equatable {
    typealias C = Metrics.Column

    /// A critically damped spring (damping 1 unless `damping` says), as capsule.js steps it.
    struct Spring: Equatable {
        var v: CGFloat
        var t: CGFloat
        var vel: CGFloat = 0
        var response: CGFloat
        /// At rest within this of its target (and this x 10 per second).
        var epsilon: CGFloat

        init(_ value: CGFloat, response: CGFloat, epsilon: CGFloat = 0.002) {
            v = value; t = value; self.response = response; self.epsilon = epsilon
        }

        mutating func step(_ dt: CGFloat) {
            guard !atRest else { return }
            let w = 2 * .pi / response
            let a = -w * w * (v - t) - 2 * w * vel
            vel += a * dt
            v += vel * dt
            if abs(v - t) < epsilon && abs(vel) < epsilon * 10 { v = t; vel = 0 }
        }

        var atRest: Bool { v == t && vel == 0 }

        mutating func jump(_ value: CGFloat) { v = value; t = value; vel = 0 }
    }

    enum Mode: Equatable { case hug, center, drag }

    /// What a finger's lift did.
    enum Event: Equatable {
        /// Another name tapped: that space now.
        case tap(Int)
        /// The current name tapped: the lens pressed, nothing else.
        case pressCurrent
        /// A drag let go: the space the names roll to.
        case release(Int)
    }

    private struct Drag: Equatable {
        var x0: CGFloat
        var tx0: CGFloat
        var moved = false
        var lastX: CGFloat
        var lastT: CGFloat
        var vel: CGFloat = 0
        var startIndex: Int
        var anchor: CGFloat = 0
    }

    // The capsule page's numbers ("Numbers").
    static let inset: CGFloat = 3
    static let lensHeight: CGFloat = 44
    static let lensLess: CGFloat = 12
    static let edge: CGFloat = 18
    static let slop: CGFloat = 6
    static let back: CGFloat = 0.28
    static let hug: CGFloat = 0.3
    static let projection: CGFloat = 0.16
    static let rubber: CGFloat = 0.35
    static let sideStep: CGFloat = 70
    static let response = (track: CGFloat(0.32), cap: CGFloat(0.42), side: CGFloat(0.33), f: CGFloat(0.32), press: CGFloat(0.18))
    /// A tap moves lens and names on the strip's own spring (Motion.space, 0.2).
    static let tapResponse: CGFloat = 0.2

    let widths: [CGFloat]
    let centers: [CGFloat]
    let total: CGFloat
    let mid: CGFloat
    let restWidth: CGFloat
    let wideWidth: CGFloat
    /// Private and one other name: the capsule hugs both at rest.
    let pair: Bool
    private let fixedWidth: Bool
    let fixedPair: Bool

    private(set) var cur: Int
    private(set) var mode: Mode
    private(set) var rest: CGFloat = 9
    private(set) var viaTap = false
    private(set) var time: CGFloat = 0
    /// One selection tick per name passing under the lens; the owner plays them.
    private(set) var ticks = 0
    /// The strip of pages moves the names (a swipe on the rows), not a finger here.
    private(set) var external = false
    private var stripMoving = false
    private var from = -1
    private var drag: Drag?
    private var lastIndex: Int
    private var pressUntil: CGFloat?

    var trackX: Spring
    var capW: Spring
    var side: Spring
    var f: Spring
    var press: Spring
    var pull: Spring

    init(track: CapsuleTrack, current: Int, mid: CGFloat, restWidth: CGFloat, wideWidth: CGFloat, pair: Bool,
         fixedWidth: Bool = false) {
        widths = track.widths
        centers = track.centers
        total = track.widths.reduce(0, +)
        self.mid = mid
        self.pair = pair && track.widths.count == 2
        self.fixedWidth = fixedWidth
        let pairWidth = total - Self.lensLess + 2 * Self.inset
        fixedPair = fixedWidth && self.pair && pairWidth <= restWidth
        self.restWidth = fixedPair ? pairWidth : restWidth
        self.wideWidth = fixedWidth ? self.restWidth : wideWidth
        let i = track.widths.isEmpty ? 0 : min(max(current, 0), track.widths.count - 1)
        cur = i
        lastIndex = i
        mode = .center
        trackX = Spring(0, response: Self.response.track, epsilon: 0.01)
        capW = Spring(self.restWidth, response: Self.response.cap, epsilon: 0.01)
        side = Spring(0, response: Self.response.side)
        f = Spring(CGFloat(i), response: Self.response.f, epsilon: 0.0005)
        press = Spring(0, response: Self.response.press)
        pull = Spring(0, response: Self.response.side)
        if hugs(i) { mode = .hug }
        let pose = hugs(i) ? hugTarget(i) : (width: self.restWidth, x: centerTarget(i))
        capW.jump(pose.width)
        trackX.jump(pose.x)
    }

    var count: Int { widths.count }

    // MARK: - geometry

    func interp(_ values: [CGFloat], _ at: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let i = min(max(Int(at.rounded(.down)), 0), values.count - 1)
        let j = min(i + 1, values.count - 1)
        return values[i] + (values[j] - values[i]) * (at - CGFloat(i))
    }

    /// The current name in the middle; an end may stay empty.
    func centerTarget(_ i: Int) -> CGFloat { mid - interp(centers, CGFloat(i)) }

    /// Hugs at rest: the pair always, and the first or the last of more.
    func hugs(_ i: Int) -> Bool { pair || (count > 2 && (i == 0 || i == count - 1)) }

    /// Center the name with its neighbor if they fit. A name too wide for
    /// the capsule is centered by itself. The phone foot keeps its width.
    func hugTarget(_ i: Int) -> (width: CGFloat, x: CGFloat) {
        if fixedPair { return (restWidth, mid - total / 2) }
        guard !widths.isEmpty else { return (restWidth, mid) }
        let pad = Self.lensLess / 2 - Self.inset
        func left(_ k: Int) -> CGFloat { centers[k] - widths[k] / 2 }
        func right(_ k: Int) -> CGFloat { centers[k] + widths[k] / 2 }
        var a = i, b = i
        if let n = neighbor(i), max(right(i), right(n)) - min(left(i), left(n)) - 2 * pad <= restWidth {
            a = min(i, n); b = max(i, n)
        }
        let span = right(b) - left(a) - 2 * pad
        let width = min(restWidth, span)
        let x = span > restWidth ? mid - centers[i] : mid - width / 2 - pad - left(a)
        return (fixedWidth ? restWidth : width, x)
    }

    private func neighbor(_ i: Int) -> Int? {
        let want = i + from
        if (0..<count).contains(want) { return want }
        if i - 1 >= 0 { return i - 1 }
        if i + 1 < count { return i + 1 }
        return nil
    }

    var capLeft: CGFloat { mid - capW.v / 2 }

    /// The lens: its middle on the screen and its width (the name + 16).
    var lens: (center: CGFloat, width: CGFloat) {
        (trackX.v + interp(centers, f.v), max(0, interp(widths, f.v) - Self.lensLess))
    }

    /// Names run past the capsule's edge there: that edge fades over 18. A
    /// hugged end's slot reaches `lensLess / 2 - inset` past it (its lens 3
    /// in), its words well inside: no fade.
    var fades: (left: Bool, right: Bool) {
        let reach = Self.lensLess / 2 - Self.inset
        return (trackX.v < capLeft - reach - 0.5, trackX.v + total > capLeft + capW.v + reach + 0.5)
    }

    /// The name under a point of the screen, inside the capsule.
    func hit(_ x: CGFloat) -> Int? {
        let l = capLeft
        guard x >= l, x <= l + capW.v else { return nil }
        let u = x - trackX.v
        return centers.indices.first { abs(u - centers[$0]) <= widths[$0] / 2 }
    }

    /// Nothing will move until something touches it again.
    var isSettled: Bool {
        guard drag == nil, pressUntil == nil, !stripMoving else { return false }
        if hugs(cur), mode != .hug { return false }
        if mode == .center, side.t != 0 || capW.t != restWidth { return false }
        return trackX.atRest && capW.atRest && side.atRest && f.atRest && press.atRest && pull.atRest
    }

    var isDragging: Bool { drag?.moved == true }
    var isTouched: Bool { drag != nil }

    // MARK: - from outside

    /// The column rose on space `i`, or the spaces changed: everything at rest there.
    mutating func reset(to i: Int) {
        guard count > 0 else { return }
        let k = min(max(i, 0), count - 1)
        drag = nil; pressUntil = nil; external = false; stripMoving = false; viaTap = false
        cur = k; lastIndex = k; from = -1; rest = 9
        mode = hugs(k) ? .hug : .center
        let pose = hugs(k) ? hugTarget(k) : (width: restWidth, x: centerTarget(k))
        capW.jump(pose.width); trackX.jump(pose.x)
        side.jump(0); f.jump(CGFloat(k)); press.jump(0); pull.jump(0)
    }

    /// The strip of pages moved (a finger on the rows, or its spring): the
    /// names follow it, the current one in the middle. Fractional positions
    /// send the buttons out, as a drag here does.
    mutating func follow(_ position: CGFloat, index: Int, followingPageDrag: Bool = false) {
        guard count > 0 else { return }
        let p = min(max(position, 0), CGFloat(count - 1))
        drag = nil
        cur = min(max(index, 0), count - 1)
        if fixedPair, !followingPageDrag {
            // The content scroll starts from its old page after the lens has moved.
            mode = .hug
            external = false; stripMoving = false
            f.t = CGFloat(cur)
            return
        }
        external = true
        stripMoving = abs(p - p.rounded()) > 0.002
        if fixedPair { mode = .hug }
        else if stripMoving { mode = .center; viaTap = false; rest = 0 }
        f.jump(p)
        lastIndex = Int(p.rounded())
        if mode != .hug { trackX.jump(mid - interp(centers, p)) }
    }

    /// A finger came down at `x` (screen points) at time `now` (seconds).
    mutating func down(_ x: CGFloat, now: CGFloat) {
        external = false
        stripMoving = false
        drag = Drag(x0: x, tx0: trackX.v, lastX: x, lastT: now, startIndex: cur)
    }

    mutating func move(_ x: CGFloat, now: CGFloat) {
        guard var d = drag else { return }
        let dx = x - d.x0
        if !d.moved, abs(dx) > Self.slop {
            d.moved = true
            viaTap = false
            mode = .drag
            trackX.response = Self.response.track; f.response = Self.response.f
            d.anchor = f.v
            if !fixedPair {
                side.t = 1; capW.t = wideWidth; pull.t = 1
                d.x0 = x; d.tx0 = trackX.v
            }
        }
        guard d.moved else { return }
        if !fixedPair {
            let lo = mid - (centers.last ?? 0), hi = mid - (centers.first ?? 0)
            var tx = d.tx0 + (x - d.x0)
            if tx > hi { tx = hi + (tx - hi) * Self.rubber }
            if tx < lo { tx = lo + (tx - lo) * Self.rubber }
            trackX.jump(tx)
        }
        let dt = max(0.001, now - d.lastT)
        d.vel = d.vel * 0.6 + 0.4 * ((x - d.lastX) / dt)
        d.lastX = x; d.lastT = now
        drag = d
    }

    /// The finger lifted at `x`: a tap, a press of the current name, or a throw.
    @discardableResult
    mutating func up(_ x: CGFloat) -> Event? {
        guard let d = drag else { return nil }
        drag = nil
        if !d.moved {
            guard let i = hit(x) else { return nil }
            return select(i)
        }
        let projected = fixedPair
            ? interp(centers, d.anchor) + (x - d.x0) + d.vel * Self.projection
            : mid - (trackX.v + d.vel * Self.projection)
        var k = 0, best = CGFloat.greatestFiniteMagnitude
        for (i, c) in centers.enumerated() where abs(projected - c) < best { best = abs(projected - c); k = i }
        from = k < d.startIndex ? 1 : k > d.startIndex ? -1 : from
        cur = k
        mode = fixedPair ? .hug : .center
        rest = 0
        pull.t = 0
        trackX.response = Self.response.track; f.response = Self.response.f
        if !fixedPair {
            trackX.vel = d.vel
            trackX.t = centerTarget(k)
        }
        f.t = CGFloat(k)
        return .release(k)
    }

    /// The touch went to something else (the sheet's own drag): as if lifted
    /// where the names are, without a tap.
    mutating func cancel() {
        guard let d = drag else { return }
        drag = nil
        guard d.moved else { return }
        mode = fixedPair ? .hug : .center
        rest = 0; pull.t = 0
        if !fixedPair { trackX.t = centerTarget(cur) }
        f.t = CGFloat(cur)
    }

    /// A name chosen (a tap, or VoiceOver's action on it).
    @discardableResult
    mutating func select(_ i: Int) -> Event? {
        guard (0..<count).contains(i) else { return nil }
        external = false; stripMoving = false
        if i == cur {
            press.t = 1
            pressUntil = time + 0.09
            return .pressCurrent
        }
        from = i < cur ? 1 : -1
        cur = i
        f.t = CGFloat(i)
        tick()
        trackX.response = Self.tapResponse; f.response = Self.tapResponse
        // The pair moves only its lens; of more, an end hugs at once, the middle centers.
        if !pair {
            mode = hugs(i) ? .hug : .center
            viaTap = true
        }
        return .tap(i)
    }

    private mutating func tick() { ticks += 1 }

    // MARK: - time

    mutating func step(_ dt: CGFloat) {
        guard dt > 0 else { return }
        // Small steps keep the springs stable at any frame rate.
        let n = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / CGFloat(n)
        for _ in 0..<n { substep(h) }
    }

    private mutating func substep(_ dt: CGFloat) {
        time += dt
        if let until = pressUntil, time > until { press.t = 0; pressUntil = nil }
        switch mode {
        case .drag:
            let attached = interp(centers, drag?.anchor ?? f.v)
            let u: CGFloat
            if fixedPair, let drag {
                // In the compact pair only the lens follows the finger.
                u = attached + (drag.lastX - drag.x0)
            } else {
                u = attached + (mid - trackX.v - attached) * pull.v
            }
            var at: CGFloat = 0
            for i in 0..<max(0, count - 1) where u >= centers[i] {
                at = CGFloat(i) + min(1, (u - centers[i]) / (centers[i + 1] - centers[i]))
            }
            if count > 0, u < centers[0] { at = 0 }
            f.jump(at)
            let idx = Int(at.rounded())
            if idx != lastIndex { lastIndex = idx; tick() }
        case .center:
            if !external {
                trackX.t = centerTarget(cur)
                f.t = CGFloat(cur)
            }
            let still = external ? !stripMoving
                : abs(trackX.v - trackX.t) < 0.6 && abs(trackX.vel) < 8
            rest = still ? rest + dt : 0
            let back = viaTap || rest >= Self.back
            side.t = back ? 0 : 1
            capW.t = back ? restWidth : wideWidth
            // Names rolling past after a throw tick; a tap ticked once already.
            if !external {
                let idx = Int(f.v.rounded())
                if idx != lastIndex { lastIndex = idx; if !viaTap { tick() } }
            }
            if hugs(cur), rest >= Self.back + Self.hug { mode = .hug }
        case .hug:
            break
        }
        if mode == .hug {
            let h = hugTarget(cur)
            capW.t = h.width
            trackX.t = h.x
            side.t = 0
            if !external { f.t = CGFloat(cur) }
            lastIndex = cur
        }
        if mode != .drag, !(external && mode == .center) {
            trackX.step(dt)
            if !external { f.step(dt) }
        }
        capW.step(dt); side.step(dt); press.step(dt); pull.step(dt)
    }
}
