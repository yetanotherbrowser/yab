import SwiftUI

extension Metrics {
    enum EmptyHome {
        /// The flat mark's 1024 box, drawn this big (the blob itself is about 80).
        static let mark: CGFloat = 112
        /// Its center, this far down the screen.
        static let markHeight: CGFloat = 0.44
        /// How far the finger can pull it, rubber-banded (iOS's 0.55).
        static let markReach: CGFloat = 120
    }
}

extension AppModel {
    /// No tab in front, on an iPhone's ordinary space.
    var emptyHome: Bool { !workspace.tabletControls && browser.tab == nil && !browser.space.isPrivate }
    /// And no tab waiting in the stack: the bar is All Tabs' own, the plate has nothing to show.
    var emptyHomeBar: Bool { emptyHome && TabStack.of(self).order.isEmpty }
}

/// No tabs: All Tabs with its cards gone. The same ground and the same three
/// buttons, so the last card closed only takes its card away, and Yab's flat
/// mark in the middle to play with (`EmptyMark`). A tab waiting in the stack (one
/// a Mac opened) keeps the page's bar and its circle.
struct EmptyHomeLayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicType

    private typealias E = Metrics.EmptyHome

    var body: some View {
        GeometryReader { geo in
            if app.emptyHome {
                content(geo.size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(app.emptyHome)
    }

    private func content(_ size: CGSize) -> some View {
        let layout = TabGalleryLayout(screen: size, count: 0, verticalControls: app.workspace.verticalControls,
                                      leadingRail: app.workspace.leadingRail)
        let dark = TabGalleryGround.isDark(app)
        let ink = dark ? Ink.onDark : Ink.primary
        let bar = app.emptyHomeBar
        return ZStack(alignment: .topLeading) {
            TabGalleryGround(space: app.browser.space, dark: colorScheme == .dark)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard app.emptyHomeBar else { return }
                    let sheet = app.field.sheetAllowed && !app.workspace.tabletControls
                    app.openNewTab(from: sheet ? emptyPill(size) : layout.plus)
                }
                .gesture(lift)
                .accessibilityHidden(true)

            EmptyMark()
                .position(x: size.width / 2, y: size.height * E.markHeight)

            if bar && app.field.sheetAllowed && !app.workspace.tabletControls {
                // As All Tabs and the sidebar stand: Settings at the top left, the
                // computer (the spaces sidebar) at the top right.
                let sides = app.workspace.sides(ofSurface: size.width)
                let settings = SpacePagesCard.headButton(right: false, width: size.width, sides: sides)
                let computer = SpacePagesCard.headButton(right: true, width: size.width, sides: sides)
                // One pill where a page's plate stands, worded as the plate with no
                // tab ("+ New Tab"): the search sheet grows out of it, the pill
                // turning into the field, as from the plate.
                let pill = emptyPill(size)
                Button { app.openNewTab(from: pill) } label: {
                    HStack(spacing: 4) {
                        Glyph(.plusMedium, size: Metrics.Chrome.emptyPlus, color: ink)
                        Text("New Tab")
                            .font(Font(PlateWords.font(pointSize: Metrics.Chrome.labelFont, weight: Metrics.Chrome.labelWeight,
                                                       dynamicType: dynamicType)))
                            .kerning(-0.02 * Metrics.Chrome.labelFont)
                            .foregroundStyle(ink)
                            .lineLimit(1)
                    }
                    .frame(width: pill.width, height: pill.height)
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                .position(x: pill.midX, y: pill.midY)
                .accessibilityLabel("New Tab")
                .accessibilityHint("Opens a new tab")
                .accessibilityIdentifier("empty.new")
                button(SettingsFieldRow.glyph, settings, Circle(), ink: ink, label: "Settings", id: "empty.settings") {
                    Motion.sheetGrow.run { app.surfaces.openSettings() }
                }
                Button {
                    Haptics.play(.light, reason: Haptics.Reason.columnOpened)
                    app.field.openSpaces(from: computer)
                } label: {
                    Glyph(mac: MacGlyph.yabLaptop, size: Metrics.Chrome.spaceEmoji, color: ink)
                        .frame(width: computer.width, height: computer.height)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .position(x: computer.midX, y: computer.midY)
                .accessibilityLabel("Spaces")
                .accessibilityIdentifier("empty.sidebar")
            } else if bar {
                let new = layout.plus, chats = layout.chats, gear = layout.gear
                button(.plusMedium, new, Capsule(style: .continuous), ink: Ink.primary, label: "New Tab", id: "empty.new") {
                    app.openNewTab(from: new)
                }
                if app.field.sheetAllowed {
                    button(SettingsFieldRow.glyph, chats, Circle(), ink: ink, label: "Settings", id: "empty.settings") {
                        Motion.sheetGrow.run { app.surfaces.openSettings() }
                    }
                } else {
                    button(.bubbles, chats, Circle(), ink: ink, label: "Chats", id: "empty.chats") {
                        NewTabPager.shared.startAt = NewTabPager.chatsPage
                        app.openNewTab(from: chats)
                    }
                    button(SettingsFieldRow.glyph, gear, Circle(), ink: ink, label: "Settings", id: "empty.settings") {
                        Motion.sheetGrow.run { app.surfaces.openSettings() }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty.home")
    }

    /// The empty screen's one pill: the unfolded plate's place on this screen.
    private func emptyPill(_ size: CGSize) -> CGRect {
        ChromeGeometry(size: size, folded: false, hasNow: app.nowItem != nil).plate
    }

    private func button<S: Shape>(_ glyph: GlyphName, _ rect: CGRect, _ shape: S, ink: Color, label: String, id: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: Metrics.Chrome.spaceEmoji, color: ink)
                .frame(width: rect.width, height: rect.height)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: shape)
        .position(x: rect.midX, y: rect.midY)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Up from the ground, as from the plate: the spaces, under the finger.
    private var lift: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.height < 0 else { return }
                app.field.beginLift()
                app.field.liftMoved(value.translation.height)
            }
            .onEnded { value in
                app.field.liftEnded(value.translation.height, velocity: value.velocity.height)
            }
    }
}

extension Motion {
    /// The empty screen's mark going home after a pull: a loose spring, so it wobbles.
    static let emptyMark = spring("emptyMark", response: 0.4, damping: 0.3)
}

/// The empty screen's Yab: the flat mark (Icon/Alternates/07-flat.icon),
/// pinned where it rests. A finger stretches it toward itself and the face
/// looks along; let go and it snaps back with a wobble, like rubber
/// (picked 2026-11-09 for the empty screen's flat logo). Reduce Motion: it
/// stays put.
struct EmptyMark: View {
    @State private var pull: CGSize = .zero
    @State private var held = false
    #if DEBUG
    /// A named state's finger: the mark held at this pull (before the rubber band).
    @MainActor static var pullInTests: CGSize = .zero
    #endif

    private typealias E = Metrics.EmptyHome

    var body: some View {
        ZStack {
            Image("FlatMarkBody").resizable().modifier(MarkStretch(pull: pull, face: false))
            Image("FlatMarkFace").resizable().modifier(MarkStretch(pull: pull, face: true))
        }
        .frame(width: E.mark, height: E.mark)
        .contentShape(Circle().inset(by: E.mark * 0.14))
        .gesture(drag)
        .accessibilityHidden(true)
        .accessibilityIdentifier("empty.mark")
        #if DEBUG
        .onAppear {
            let held = Self.pullInTests
            if held != .zero { pull = CGSize(width: Self.rubber(held.width), height: Self.rubber(held.height)) }
        }
        #endif
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !held {
                    held = true
                    Haptics.play(.selection, reason: "mark")
                }
                guard !Motion.reduced else { return }
                pull = CGSize(width: Self.rubber(value.translation.width), height: Self.rubber(value.translation.height))
            }
            .onEnded { _ in
                held = false
                guard pull != .zero else { return }
                Haptics.play(.soft, reason: "mark")
                Motion.emptyMark.run { pull = .zero }
            }
    }

    /// iOS's rubber band: free at first, then ever stiffer, never past the reach.
    static func rubber(_ d: CGFloat) -> CGFloat {
        let reach = E.markReach
        return (1 - 1 / (abs(d) * 0.55 / reach + 1)) * reach * (d < 0 ? -1 : 1)
    }
}

/// One layer of the mark under a pull, drawn from the pull alone so the
/// spring home passes through the other side (the wobble): the body moves
/// half the pull and stretches along it; the face moves a little more,
/// stretches less and leans toward the finger.
private struct MarkStretch: GeometryEffect {
    var pull: CGSize
    let face: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pull.width, pull.height) }
        set { pull = CGSize(width: newValue.first, height: newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = pull.width, y = pull.height, d = hypot(x, y)
        guard d > 0.01 else { return ProjectionTransform() }
        let stretch = min(0.75, d / 150), angle = atan2(y, x)
        let move: CGFloat = face ? 0.55 * 1.25 : 0.55
        let look = face ? min(d, 110) * 0.12 : 0
        let sx = face ? 1 + stretch * 0.35 : 1 + stretch
        let sy = face ? 1 / (1 + stretch * 0.3) : 1 / (1 + stretch * 0.8)
        let t = CGAffineTransform(translationX: size.width / 2 + x * move + x / d * look,
                                  y: size.height / 2 + y * move + y / d * look)
            .rotated(by: angle)
            .scaledBy(x: sx, y: sy)
            .rotated(by: -angle)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(t)
    }
}
