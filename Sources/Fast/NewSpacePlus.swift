import AppKit
import SwiftUI

// Past the last space two fingers make a new one, as in Arc: the row gives
// on its usual rubber band, and a "+" comes in at the column's edge as far
// as it has given, its ring filling. Full, it turns over with a tick; lift
// after it has been full a moment and New Space opens. Anything less and it
// goes back out (SpacePaging has the numbers). It stands over the column
// rather than in the row, so it is the same whether the row is the live
// pages, their pictures, or, with Reduce Motion, not moving at all.

@MainActor
final class NewSpacePlus {
    static let shared = NewSpacePlus()

    private final class Host: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let state = NewSpacePlusState()
    private var host: Host?
    /// The column's words, read once as a gesture brings the "+" in.
    private var worn = false
    /// The window and space whose fingers brought it in: only their lift,
    /// still on the last space, makes one.
    private weak var owner: Browser?
    private var space: UUID?
    private var fullSince: TimeInterval?
    /// The space changed under the fingers: nothing more from this
    /// gesture, however they go on, until they come down anew.
    private var spent = false
    /// Whether a ring is full now, for the tests.
    var armed: Bool { fullSince != nil }

    private init() {
        // Fingers that went without lifting over the column: Yab left, the
        // desktop changed, a click. A swipe that pages the row hears these
        // in SpacePager too; one that doesn't has only these.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NewSpacePlus.shared.drop() }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow, window === NewSpacePlus.shared.owner?.column?.window { NewSpacePlus.shared.drop() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NewSpacePlus.shared.drop() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { NewSpacePlus.shared.drop() }
            return event
        }
    }

    /// Whether `browser`'s fingers may bring the "+" in now.
    private static func eligible(_ browser: Browser) -> Bool {
        browser.canSwipeNewSpace && browser.turnOrder.last?.id == browser.spaceID
    }

    /// The row `past` points beyond the last space, the fingers' latest
    /// move at `time`.
    func pull(_ past: CGFloat, at time: TimeInterval, browser: Browser) {
        guard !spent else { return }
        if owner !== browser || space != browser.spaceID { drop() }
        // Never armed where it can't be seen.
        guard past > 0, Self.eligible(browser), let column = browser.column, var band = column.spaceBand(browser) else {
            if state.shown != 0 || fullSince != nil { drop() }
            return
        }
        owner = browser
        space = browser.spaceID
        let was = fullSince
        fullSince = SpacePaging.fullSince(was, past: Double(past), at: time)
        // Arc ticks as the ring fills and again as it empties.
        if (was == nil) != (fullSince == nil) { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        // Out as a card, its hairline down the edge stays the card's.
        if browser.prefs.sideShut && browser.sideCard { band = band.insetBy(dx: PagerStage.rim, dy: 0) }
        place(in: column, band: band, browser: browser)
        let (shown, ring) = SpacePaging.plus(Double(past))
        if state.leaving { state.leaving = false }
        // In on Arc's spring; the ring follows the fingers as they go.
        if state.shown != shown {
            withAnimation(state.still ? nil : NewSpacePlusView.arrive) { state.shown = shown }
        }
        if state.ring != ring { state.ring = ring }
        if state.full != (fullSince != nil) { state.full = fullSince != nil }
    }

    /// Fingers that never paged the row, Reduce Motion's: `travel` points
    /// over the column, the "+" as far as the row would have given.
    func pull(unpaged travel: CGFloat, at time: TimeInterval, browser: Browser) {
        guard Self.eligible(browser), let page = browser.column?.spaceBand(browser)?.width else { return drop() }
        let x = SpacePaging.offset(travel: Double(travel), page: Double(page), back: browser.turnOrder.count > 1, forward: false)
        pull(CGFloat(max(0, -x)), at: time, browser: browser)
    }

    /// `browser`'s fingers lifted at `time`, or went without lifting (nil):
    /// New Space if the ring had been full long enough, from the space it
    /// filled on, still the last; the "+" goes either way.
    func lift(at time: TimeInterval?, browser: Browser) {
        let held = time.map { SpacePaging.makesSpace(fullSince: fullSince, liftedAt: $0) } ?? false
        guard held, owner === browser, space == browser.spaceID, Self.eligible(browser) else { return drop() }
        reset()
        // Taken: it leaves full, a little smaller, quicker than it came.
        withAnimation(.easeOut(duration: NewSpacePlusView.leave)) { state.leaving = true }
        // Gone: put back to nothing where it can't be seen, unless fingers
        // have brought it in again meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + NewSpacePlusView.leave) { [state] in
            guard state.leaving else { return }
            state.full = false
            state.shown = 0
            state.ring = 0
        }
        SpaceTray.openNamed(browser)
    }

    /// Fingers down anew: whatever the last gesture left goes.
    func begin() {
        spent = false
        drop()
    }

    /// A change of space: the "+" goes, and the gesture under way, if
    /// any, brings it in no more.
    func spend() {
        spent = true
        drop()
    }

    /// The "+" back out, nothing made.
    func drop() {
        reset()
        guard state.shown != 0 || state.ring != 0 || state.full else { return }
        state.full = false
        // Back as the row goes back, on its spring; with Reduce Motion it
        // fades where it stands.
        withAnimation(state.still ? .easeOut(duration: 0.14) : .spring(response: SpacePaging.response, dampingFraction: SpacePaging.damping)) {
            state.shown = 0
            state.ring = 0
        }
    }

    private func reset() {
        fullSince = nil
        owner = nil
        space = nil
        worn = false
    }

    /// Over the space's part of the column, in its words, clipped at its
    /// edge so the "+" comes in from past it.
    private func place(in column: ColumnView, band: CGRect, browser: Browser) {
        if host?.superview !== column {
            host?.removeFromSuperview()
            let made = Host(rootView: AnyView(EmptyView()))
            made.sizingOptions = []
            made.safeAreaRegions = []
            made.wantsLayer = true
            made.layer?.masksToBounds = true
            host = made
            worn = false
        }
        guard let host else { return }
        if !worn {
            worn = true
            state.still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            // The words the column wears now, the site's color's included
            // (ColumnRoot's ink), as its rows have them.
            let look = ColumnPages.of(browser)?.look
            let dark = (column.window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let tone = look?.tone ?? SpaceWash.grounded(in: browser).map { Tone($0.color, lifted: true, glass: $0.glass) }
            // The pager moves the row in the window's own direction, so the
            // "+" comes in where it gives, whatever the language.
            host.rootView = AnyView(NewSpacePlusView(state: state)
                .toned(tone)
                .environment(\.colorScheme, look?.scheme ?? tone?.scheme ?? (dark ? .dark : .light))
                .environment(\.layoutDirection, .leftToRight))
        }
        // The band is measured from the column's top.
        let frame = CGRect(x: band.minX, y: column.bounds.height - band.maxY, width: band.width, height: band.height)
        if host.frame != frame { host.frame = frame }
        if host.superview == nil { column.addSubview(host, positioned: .above, relativeTo: nil) }
    }
}

@MainActor
final class NewSpacePlusState: ObservableObject {
    /// How far in, 0 to 1, and how full the ring.
    @Published var shown: Double = 0
    @Published var ring: Double = 0
    @Published var full = false
    /// Taken by a lift: going, full.
    @Published var leaving = false
    /// Reduce Motion: no travel, only fades.
    var still = false
}

/// Arc's "+" past the last space (SpacePaging.plus): a 30 point disc whose
/// left edge goes from 5 points past the column's edge to 42 inside it, seen
/// from a fifth of the way in, and a light of the column's ink behind it.
/// Its ring fills from the top, counterclockwise, over a faint track; full,
/// it turns over, growing a little and back. A chip of the column's own
/// color under it, lifted, so the rows it passes over don't show through.
struct NewSpacePlusView: View {
    @ObservedObject var state: NewSpacePlusState
    @Environment(\.tone) private var tone
    @Environment(\.colorScheme) private var scheme

    static let disc: CGFloat = 30
    /// How deep the light reaches into the column, and how tall it is.
    static let light: CGFloat = 56
    static let lightTall: CGFloat = 260
    /// Arc's own, for the disc and the light coming in.
    static let arrive = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let leave: Double = 0.16

    var body: some View {
        GeometryReader { box in
            let width = box.size.width, middle = box.size.height / 2
            let shown = CGFloat(state.shown)
            let ink = Palette.strong(on: tone)
            let ground = tone.map { Color(nsColor: $0.page.withAlphaComponent(1)) } ?? Color(nsColor: Palette.NS.ground)
            let dark = scheme == .dark
            let lift = dark ? Shadow.fieldNearDark : Shadow.selection
            let turned = state.full || state.leaving
            ZStack {
                EllipticalGradient(stops: [.init(color: ink.opacity(dark ? 0.15 : 0.08), location: 0),
                                           .init(color: ink.opacity(dark ? 0.06 : 0.03), location: 0.45),
                                           .init(color: ink.opacity(dark ? 0.015 : 0.008), location: 0.78),
                                           .init(color: ink.opacity(0), location: 1)])
                    .frame(width: 2 * Self.light, height: min(box.size.height, Self.lightTall))
                    .position(x: state.still ? width : width + (Self.light - 10) * (1 - shown), y: middle)
                    .opacity(min(1, 2 * shown))
                ZStack {
                    Circle().fill(turned ? ink : ground)
                    Circle().inset(by: 1.25).stroke(ink.opacity(0.18), lineWidth: 2.5)
                    Circle().inset(by: 1.25)
                        .trim(from: 0, to: state.leaving ? 1 : CGFloat(state.ring))
                        .stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .scaleEffect(x: -1)
                    Symbol("plus", size: 12, weight: .semibold)
                        .foregroundStyle(turned ? ground : ink.opacity(0.8))
                }
                .castShadow(Circle(), color: .black.opacity(Double(lift.opacity)), radius: lift.radius, y: lift.y)
                .frame(width: Self.disc, height: Self.disc)
                .keyframeAnimator(initialValue: 1.0, trigger: state.full) { disc, scale in
                    disc.scaleEffect(scale)
                } keyframes: { _ in
                    // Grows only as it turns over, not as it empties.
                    CubicKeyframe(state.full && !state.still ? 1.14 : 1, duration: 0.1)
                    CubicKeyframe(1, duration: 0.1)
                }
                .scaleEffect(state.leaving && !state.still ? 0.85 : 1)
                // With Reduce Motion it stays where it rests and only fades.
                .position(x: (state.still ? width - 42 : width + 5 - 47 * shown) + Self.disc / 2, y: middle)
                .opacity(state.leaving ? 0 : min(1, shown / 0.2))
            }
        }
        .accessibilityHidden(true)
    }
}
