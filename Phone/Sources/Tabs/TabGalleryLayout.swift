import SwiftUI

/// Where All Tabs' cards stand (Metrics.TabGallery):
/// oldest on the left, newest on the right. The focus, a little left of the
/// middle, holds the tab used before the one in front; the tab in front
/// stands to its right, mostly past the screen's edge and over it; older
/// tabs pile up to the left under it, closer and smaller the further back,
/// as iOS's app switcher, under a veil. Each card is the page's content
/// area (under the status bar, over the chrome's row) at its depth's scale.
/// A finger moves the focus: `focus` is the index (oldest 0) standing there.
struct TabGalleryLayout: Equatable {
    let screen: CGSize
    let count: Int
    var verticalControls: Bool? = nil
    var leadingRail = false
    /// What the system reserves at this surface's sides; nil, the window's.
    var sides: ChromeGeometry.Sides? = nil
    /// The stack's circle, where it stands apart from the row: the check takes its place.
    var circle: CGRect? = nil
    /// Three cards whole across an unfolded Duo, side by side, none over another.
    var across = false

    private typealias G = Metrics.TabGallery

    /// The page's content area: under the status bar, over the chrome's row.
    var content: CGRect {
        let top = Metrics.statusBar, bottom = screen.height - Metrics.Chrome.bottom - Metrics.Chrome.height
        return CGRect(x: 0, y: top, width: screen.width, height: max(1, bottom - top))
    }

    /// The page as a card shows it whole: the whole screen, the bar floating
    /// over its foot as it does over the live page.
    var page: CGRect { CGRect(x: 0, y: 0, width: screen.width, height: screen.height) }

    /// The share of a page's picture above its content area.
    var contentTop: CGFloat { screen.height > 0 ? Metrics.statusBar / screen.height : 0 }

    /// How wide a card's kept picture is, in points (TabPictures): as wide as
    /// the widest card at rest, the tab in front's beside the focus.
    var pictureWidth: CGFloat { rect(depth: -1).width }

    /// Cards that draw their pictures: from the tab in front's place on the
    /// right to four back, where cards lie wholly under the ones over them
    /// (two back shows a sliver at the screen's left edge, three back
    /// nothing), the one past that read ahead for a scroll. Cards further
    /// back show their stand-in, unseen, so All Tabs never holds more than
    /// six pictures, however many tabs there are.
    func draws(_ i: Int, focus: CGFloat) -> Bool {
        let d = depth(i, focus: focus)
        return d > -1.5 && d <= 4
    }

    /// The focus as All Tabs opens: the tab used before the one in front.
    var initialFocus: CGFloat { CGFloat(max(0, count - 2)) }
    var maxFocus: CGFloat { CGFloat(max(0, count - 1)) }

    /// How far behind the focus card `i` is (older positive, newer negative).
    func depth(_ i: Int, focus: CGFloat) -> CGFloat { focus - CGFloat(i) }

    /// A depth's left edge (share of the width) and scale, between the
    /// measured depths, and on past the ends as their last steps go.
    static func stop(_ d: CGFloat) -> (left: CGFloat, scale: CGFloat) {
        let table = G.depths
        var k = 0
        while k < table.count - 2 && d > table[k + 1].depth { k += 1 }
        let a = table[k], b = table[k + 1]
        let t = (d - a.depth) / (b.depth - a.depth)
        return (a.left + (b.left - a.left) * t, a.scale + (b.scale - a.scale) * t)
    }

    /// A card at a depth.
    /// A card at a depth: the page under the status bar, scaled whole (the
    /// cards are the page's own shape, 262 x 531 of 375 x 758, not the content
    /// area's), its height the measured one for that depth. `last` (0 to 1) is how far
    /// the newest card is coming to the focus: there, with nothing on its
    /// right, it stands in the middle of the screen.
    func rect(depth d: CGFloat, last: CGFloat = 0) -> CGRect {
        if across {
            let w = acrossWidth, h = w * (screen.height - Metrics.statusBar) / max(1, screen.width)
            return CGRect(x: (screen.width - w) / 2 - d * (w + G.acrossGap), y: G.middle * screen.height - h / 2, width: w, height: h)
        }
        var stop = Self.stop(d)
        let h = stop.scale * content.height
        let w = h * screen.width / max(1, screen.height - Metrics.statusBar)
        if last > 0, d > -1, d < 1 {
            let centered = (screen.width - w) / 2 / screen.width
            stop.left += (centered - stop.left) * last * (1 - abs(d))
        }
        return CGRect(x: stop.left * screen.width, y: G.middle * screen.height - h / 2, width: w, height: h)
    }

    private var acrossWidth: CGFloat { (screen.width - G.acrossGap * 4) / 3 }

    /// How far the newest card has come to the focus (0 to 1).
    func last(focus: CGFloat) -> CGFloat { count < 2 ? 1 : min(max(focus - CGFloat(count - 2), 0), 1) }

    func card(_ i: Int, focus: CGFloat) -> CGRect { rect(depth: depth(i, focus: focus), last: last(focus: focus)) }

    func radius(of rect: CGRect) -> CGFloat { rect.height * G.radius }

    /// The veil over a card: none from the focus forward, 20 % one back, 35 % from two back.
    static func veil(depth d: CGFloat) -> Double {
        if d <= 0 { return 0 }
        if d <= 1 { return G.veilOne * Double(d) }
        if d <= 2 { return G.veilOne + (G.veilMost - G.veilOne) * Double(d - 1) }
        return G.veilMost
    }

    /// The site's icon over a card: whole up to one back, 40 % two back, gone at three.
    static func iconOpacity(depth d: CGFloat) -> Double {
        if d <= 1 { return 1 }
        if d <= 2 { return 1 - (1 - G.iconFar) * Double(d - 1) }
        if d <= 3 { return G.iconFar * Double(3 - d) }
        return 0
    }

    /// The title: only over the card at the focus.
    static func titleOpacity(depth d: CGFloat) -> Double { Double(max(0, 1 - abs(d))) }

    /// Room for card `i`'s title: from after its icon to 16 short of the
    /// next newer card's icon, or of its own right edge for the newest.
    func titleWidth(_ i: Int, focus: CGFloat) -> CGFloat {
        let own = card(i, focus: focus)
        let start = own.minX + G.labelInset + G.labelIcon + G.labelGap
        let end = i + 1 < count ? card(i + 1, focus: focus).minX + G.labelInset : own.maxX
        return max(0, min(end, own.maxX) - G.labelEnd - start)
    }

    /// How far a finger moves to bring the next card to the focus: the focus
    /// card's way to the newer card's place.
    var step: CGFloat { across ? acrossWidth + G.acrossGap : max(1, (Self.stop(-1).left - Self.stop(0).left) * screen.width) }

    /// Where a let-go scroll comes to rest: a throw, or a
    /// third of a card's way, pages on to the next card that way (the tab in
    /// front comes to the focus with a short swipe instead of falling back
    /// to the right), a longer throw further; a slight move goes back.
    static func settle(from: CGFloat, moved: CGFloat, thrown: CGFloat) -> CGFloat {
        let start = from.rounded(), flung = thrown - start, dragged = moved - start
        guard abs(flung) >= G.pageThrow || abs(dragged) >= G.pageDrag else { return start }
        let way: CGFloat = (abs(flung) >= G.pageThrow ? flung : dragged) > 0 ? 1 : -1
        return start + way * max(1, abs(flung).rounded())
    }

    /// A finger's focus, resisting past the oldest and the newest card.
    func resisted(_ focus: CGFloat) -> CGFloat {
        if focus < 0 { return ColumnMath.rubber(focus * step, G.rubber) / step }
        if focus > maxFocus { return maxFocus + ColumnMath.rubber((focus - maxFocus) * step, G.rubber) / step }
        return focus
    }

    /// The card under a point: the newer one where two overlap.
    func card(at point: CGPoint, focus: CGFloat) -> Int? {
        (0..<count).reversed().first { card($0, focus: focus).contains(point) }
    }

    /// New Tab's + in its capsule, on the chrome's middle line.
    var plus: CGRect {
        let h = Metrics.Chrome.height, w = G.plusWidth
        return CGRect(x: (screen.width - w) / 2, y: screen.height - Metrics.Chrome.bottom - h, width: w, height: h)
    }

    /// Settings' gear: the bar's right button, as the chrome has it.
    var gear: CGRect { circle ?? chrome.space }

    /// Chats: the bar's left button, as ‹ is on a page.
    var chats: CGRect { chrome.back }

    private var chrome: ChromeGeometry {
        ChromeGeometry(size: screen, folded: false, hasNow: false, verticalControls: verticalControls, leadingRail: leadingRail,
                       sides: sides ?? ChromeGeometry.effectiveSides)
    }
}

/// The stack on the screen: its glass circle (the chrome's right button)
/// and its two cards inside it.
struct TabStackGeometry: Equatable {
    let circle: CGRect
    let front: CGRect
    let back: CGRect

    private typealias M = Metrics.TabStack

    init(button: CGRect) {
        let size = CGSize(width: M.cardWidth, height: M.cardHeight)
        func card(_ at: CGPoint) -> CGRect {
            CGRect(x: button.midX + at.x - size.width / 2, y: button.midY + at.y - size.height / 2, width: size.width, height: size.height)
        }
        circle = button
        front = card(M.front)
        back = card(M.back)
    }

    init(screen: CGSize) {
        self.init(button: ChromeGeometry(size: screen, folded: false, hasNow: false).space)
    }

    /// A card's corners as drawn, turned (its rim lies inside its edge),
    /// for checking that it sits inside the circle.
    static func corners(of rect: CGRect, turned degrees: CGFloat, rim: CGFloat = 0) -> [CGPoint] {
        let a = degrees * .pi / 180, w = rect.width / 2 + rim, h = rect.height / 2 + rim
        return [(-w, -h), (w, -h), (w, h), (-w, h)].map { x, y in
            CGPoint(x: rect.midX + x * cos(a) - y * sin(a), y: rect.midY + x * sin(a) + y * cos(a))
        }
    }
}

/// One card as All Tabs draws it at one moment: its frame before it is
/// turned (clockwise degrees about its middle), its corners, how much of its
/// picture's top is above what shows, and its label's state.
struct TabCardPose: Equatable {
    var rect: CGRect
    var angle: CGFloat = 0
    var radius: CGFloat = 0
    var cropTop: CGFloat = 0
    var opacity: Double = 1
    var veil: Double = 0
    /// The site's icon over it, and the title beside it.
    var icon: Double = 1
    var title: Double = 0
    /// The label follows the card's size as it grows and shrinks.
    var labelScale: CGFloat = 1
    var titleWidth: CGFloat = 0
    /// The stack card's white rim and shadow: 1 in the circle, 0 in All Tabs.
    var rim: CGFloat = 0
    /// Newer cards over older ones, at rest and while moving.
    var z: Double = 0
}

/// All Tabs' movement, worked out for any moment from the tap (films, held
/// states and tests see exactly what a finger does). Opening: the page in
/// front shrinks into its card on the right; the stack's front card, the
/// previous tab, grows out of its place in the circle to the focus,
/// straightening and leaving its rim; the card behind it to the place one
/// back; the older ones follow from behind it, coming in. Closing on a
/// card (`Closing`): it grows into its page, the cards lying on it fly
/// into the circle, the rest stay and go.
enum TabGalleryMotion {
    static func interactiveOpening(_ i: Int, layout: TabGalleryLayout, stack: TabStackGeometry,
                                   progress: CGFloat) -> TabCardPose {
        let a = opening(i, layout: layout, stack: stack, t: 0)
        let b = rest(i, layout: layout, focus: layout.initialFocus)
        let p = min(max(progress, 0), 1)
        if p == 0 { return a }
        if p == 1 { return b }
        var pose = b
        pose.rect = mix(a.rect, b.rect, p)
        pose.angle = lerp(a.angle, b.angle, p)
        pose.radius = lerp(a.radius, b.radius, p)
        pose.cropTop = lerp(a.cropTop, b.cropTop, p)
        pose.opacity = Double(lerp(CGFloat(a.opacity), CGFloat(b.opacity), p))
        pose.veil = Double(lerp(CGFloat(a.veil), CGFloat(b.veil), p))
        pose.icon = b.icon * Double(p)
        pose.title = b.title * Double(p)
        pose.rim = lerp(a.rim, b.rim, p)
        pose.labelScale = lerp(a.labelScale, b.labelScale, p)
        return pose
    }

    /// What a card does as All Tabs closes: the one chosen grows into its
    /// page; one lying on it that the stack shows next flies into that card
    /// of the circle; any other stays where it is and goes.
    enum Role: Equatable { case chosen, front, back, other }

    private typealias M = Metrics.TabStack
    private typealias T = TabGalleryTiming

    /// Closing on card `chosen` (oldest 0), the rule the user set in the
    /// prototype (6mGJ7hWG v3, scenes 4 to 6). The stack then shows the two
    /// newest cards but the chosen one (TabRecency puts the chosen tab first
    /// and keeps the others' order), which are the cards lying on it: those
    /// fly into the circle, rect and turn, over the growing page. A stack
    /// card that lay under the chosen one doesn't fly: it appears in its
    /// place in the circle. Cards under the chosen one stay and fade under
    /// its growing page; any further ones on it fade where they are. The top
    /// card has nothing on it, so nothing flies: the circle comes up from
    /// below with its two cards as they are.
    struct Closing: Equatable {
        /// Each card's part, oldest first.
        var roles: [Role]
        /// The stack's two cards afterwards, front first.
        var front: Int?
        var back: Int?
        /// Nothing lay on the chosen card: the circle rises with its cards.
        var rises: Bool

        /// `stack`: a circle to fly into (the phone's). Without one (iPad)
        /// the others only fade where they are.
        init(count: Int, chosen: Int, stack: Bool = true) {
            let after = stack ? (0..<count).reversed().filter { $0 != chosen } : []
            let front = after.first, back = after.dropFirst().first
            roles = (0..<count).map { i in
                if i == chosen { return .chosen }
                if i == front && i > chosen { return .front }
                if i == back && i > chosen { return .back }
                return .other
            }
            self.front = front
            self.back = back
            rises = stack && chosen == count - 1
        }

        /// The stack's cards that don't fly (they lay under the chosen one),
        /// each with its place in the circle, where it appears or comes up.
        var seated: [Seat] {
            [(front, Role.front), (back, Role.back)].compactMap { i, place in
                guard let i, roles.indices.contains(i), roles[i] == .other else { return nil }
                return Seat(index: i, place: place)
            }
        }
    }

    struct Seat: Equatable {
        let index: Int
        /// `.front` or `.back`.
        let place: Role
    }

    /// How far below its place the circle is `t` seconds after the tap:
    /// with the top card chosen it comes up from 104 on the cards' spring.
    static func rise(_ rises: Bool, t: Double) -> CGFloat {
        rises ? M.rise * (1 - T.cardToStack.value(t)) : 0
    }

    /// A stack card that doesn't fly, `t` seconds after the tap, in its
    /// place (`.front` or `.back`) in the circle: appearing there as the
    /// flying cards land, or whole and coming up with the circle.
    static func seated(_ place: Role, rises: Bool, layout: TabGalleryLayout, stack: TabStackGeometry, t: Double) -> TabCardPose {
        let front = place == .front
        let shown = rises ? 1 : min(max(T.cardToStack.value(t), 0), 1)
        let rect = (front ? stack.front : stack.back).offsetBy(dx: 0, dy: rise(rises, t: t))
        return TabCardPose(rect: rect, angle: front ? M.frontTurn : M.backTurn, radius: M.cardRadius,
                           cropTop: layout.contentTop, opacity: Double((front ? 1 : M.backOpacity) * shown),
                           veil: front ? 0 : Double(M.backVeil), icon: 0, title: 0, rim: 1,
                           z: front ? -1 : -2)
    }

    /// Card `i` at rest, the focus at `focus`.
    static func rest(_ i: Int, layout: TabGalleryLayout, focus: CGFloat) -> TabCardPose {
        let d = layout.depth(i, focus: focus)
        let rect = layout.rect(depth: d, last: layout.last(focus: focus))
        return TabCardPose(rect: rect, radius: layout.radius(of: rect), cropTop: layout.contentTop,
                           veil: layout.across ? 0 : TabGalleryLayout.veil(depth: d), icon: TabGalleryLayout.iconOpacity(depth: d),
                           title: TabGalleryLayout.titleOpacity(depth: d), titleWidth: layout.titleWidth(i, focus: focus),
                           z: Double(i))
    }

    /// Card `i`, `t` seconds after the stack was tapped.
    static func opening(_ i: Int, layout: TabGalleryLayout, stack: TabStackGeometry, t: Double) -> TabCardPose {
        let n = layout.count
        let to = rest(i, layout: layout, focus: layout.initialFocus)
        var pose = to
        let p: CGFloat
        if i == n - 1 {
            // The page in front, from the whole page to its card.
            p = T.pageToCard.value(t)
            pose.rect = mix(layout.page, to.rect, p)
            pose.radius = lerp(0, to.radius, p)
            pose.cropTop = lerp(0, to.cropTop, p)
        } else if i == n - 2 {
            p = T.stackToCard.value(t - T.frontDelay)
            pose.rect = mix(stack.front, to.rect, p)
            pose.angle = lerp(M.frontTurn, 0, T.pageToCard.value(t))
            pose.radius = lerp(M.cardRadius, to.radius, p)
            pose.veil = Double(lerp(0, CGFloat(to.veil), p))
        } else if i == n - 3 {
            p = T.stackToCard.value(t - T.backDelay)
            pose.rect = mix(stack.back, to.rect, p)
            pose.angle = lerp(M.backTurn, 0, T.pageToCard.value(t - (T.backDelay - T.frontDelay)))
            pose.radius = lerp(M.cardRadius, to.radius, p)
            pose.veil = Double(lerp(M.backVeil, CGFloat(to.veil), p))
            pose.opacity = Double(lerp(M.backOpacity, 1, p))
        } else {
            p = T.stackToCard.value(t - T.olderDelay)
            pose.rect = mix(stack.back, to.rect, p)
            pose.angle = lerp(M.backTurn, 0, T.pageToCard.value(t - (T.olderDelay - T.frontDelay)))
            pose.radius = lerp(M.cardRadius, to.radius, p)
            let fade = T.olderFade
            pose.opacity = min(max((t - fade.lowerBound) / (fade.upperBound - fade.lowerBound), 0), 1)
        }
        // The cards from the circle leave their rim there as they grow.
        if i < n - 1 { pose.rim = 1 - min(max(p, 0), 1) }
        let shown = Double(min(max(p / T.labelIn, 0), 1))
        pose.icon = to.icon * shown * pose.opacity
        pose.title = to.title * shown
        pose.labelScale = to.rect.height > 0 ? min(1.5, pose.rect.height / to.rect.height) : 1
        return pose
    }

    /// Card `i` closing, `t` seconds after the tap, from where it was then
    /// (its part from `Closing`).
    static func closing(_ role: Role, from: TabCardPose, layout: TabGalleryLayout, stack: TabStackGeometry, t: Double) -> TabCardPose {
        var pose = from
        let p: CGFloat
        switch role {
        case .chosen:
            p = T.cardToPage.value(t)
            pose.rect = mix(from.rect, layout.page, p)
            pose.angle = lerp(from.angle, 0, p)
            pose.radius = lerp(from.radius, 0, p)
            pose.cropTop = lerp(from.cropTop, 0, p)
            pose.veil = Double(lerp(CGFloat(from.veil), 0, p))
            pose.opacity = Double(lerp(CGFloat(from.opacity), 1, p))
            pose.rim = lerp(from.rim, 0, p)
        case .front, .back:
            // Into its card in the circle, rect and turn, putting its rim on.
            p = T.cardToStack.value(t)
            let front = role == .front
            pose.rect = mix(from.rect, front ? stack.front : stack.back, p)
            pose.angle = lerp(from.angle, front ? M.frontTurn : M.backTurn, p)
            pose.radius = lerp(from.radius, M.cardRadius, p)
            pose.cropTop = lerp(from.cropTop, layout.contentTop, p)
            pose.veil = Double(lerp(CGFloat(from.veil), front ? 0 : M.backVeil, p))
            pose.opacity = Double(lerp(CGFloat(from.opacity), front ? 1 : M.backOpacity, p))
            pose.rim = lerp(from.rim, 1, min(max(p, 0), 1))
        case .other:
            // Where it is, going.
            p = CGFloat(min(t / T.othersFade, 1))
            pose.opacity = from.opacity * Double(1 - p)
        }
        let kept = Double(1 - min(max(p / T.labelOut, 0), 1))
        pose.icon = from.icon * kept
        pose.title = from.title * kept
        pose.labelScale = from.rect.height > 0 ? from.labelScale * pose.rect.height / from.rect.height : from.labelScale
        return pose
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
               width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }
}
