import AppKit
import CoreImage
import SwiftUI

// The space on screen, said once: a capsule with its emoji and its name, at
// the right of the column's foot, or after the traffic lights with the tabs
// on top. The window's color already says which space it is; the capsule
// names it, and opens the tray (SpaceTray) that lists them all and makes a
// new one. ⌃1 to ⌃9 and two
// fingers sideways switch without it: only its word changes.
//
// The column's foot no longer wears it: there the spaces stand in a row of
// their own (SpaceRow) and the corner is a plus (FootPlus), as Arc's. It
// stays at the head of the strip with the tabs on top.
//
// It shares the foot with the downloads and extensions doors, and, when
// the player has folded after a pause, with the player's chip, which stands
// before it (docs/player.md). A newer Yab's Update button stands in its
// place while there is something to say, the note written over the foot
// (UpdateOrCapsule).
//
// Its corner is a control's, as the doors beside it; its word is a tab's
// title's, 12.5 regular; it is as wide as its word, never more than 150.
// With too little room, what gives way goes first to last: the chip's title
// fades at its end; the chip becomes its artwork alone, a door's size; the
// capsule's name fades at its end; the capsule becomes its emoji alone.
// Downloads and extensions never give way.

/// How wide the capsule and the player's chip are at a width.
struct CapsulePlan: Equatable {
    /// Nil when spaces are off.
    var width: CGFloat?
    /// Its emoji alone, a door's size.
    var bare = false
    /// Its name faded at the end.
    var cut = false
    /// The player's chip, when it is in the foot.
    var chip: CGFloat?
    var chipBare = false
    var chipCut = false

    static let inset: CGFloat = 8
    static let gap: CGFloat = 6
    static let mark: CGFloat = 14
    static let chevron: CGFloat = 10
    /// Everything in the capsule but its name: 8, the emoji, 6, the name, 6,
    /// the chevron, 8.
    static let frame = inset + mark + gap + gap + chevron + inset
    /// As tall as a tab in the strip: its 16 point mark and 6 above and
    /// below. A door's height in the column.
    static let stripHeight: CGFloat = 28
    static let most: CGFloat = 150
    static let mostInStrip: CGFloat = 140
    /// Less room than three letters and the name goes altogether.
    static let fewest: CGFloat = 22
    /// Across the top the capsule is a plate of its own, as a pin is: the
    /// emoji 10 in, the name 8 after it, 10 after the name, no chevron
    /// (StripTurn's prototype, evals/dia-top-spaces).
    static let stripInset: CGFloat = 10
    static let stripGap: CGFloat = 8
    static let stripFrame = stripInset + mark + stripGap + stripInset
    /// Between the plate and the first tab after it, as the prototype has it.
    static let stripAfter: CGFloat = 16
    static let chipFrame: CGFloat = 36
    static let chipMost: CGFloat = 120
    /// Between the left doors and the right group, at least.
    static let air: CGFloat = 8

    /// A name's width in the capsule's type, measured once: the foot is
    /// drawn again with every change of the browser, the name seldom changes.
    @MainActor static func words(_ text: String, size: CGFloat = 12.5) -> CGFloat {
        let key = "\(size)|\(text)"
        if let known = measured[key] { return known }
        let width = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
        if measured.count > 64 { measured.removeAll() }
        measured[key] = width
        return width
    }
    @MainActor private static var measured: [String: CGFloat] = [:]

    /// In the column's foot. `left`: the downloads and extensions doors;
    /// `track`: the player's chip's words, when it is folded into the foot.
    @MainActor static func side(width: CGFloat, left: CGFloat, name: String?, track: String? = nil) -> CapsulePlan {
        var plan = CapsulePlan()
        var room = width - 2 * 10 - left - air
        let capsule = name.map { min(most, words($0, size: SidebarTypography.current) + frame) } ?? 0
        if let track {
            let chip = min(chipMost, words(track) + chipFrame)
            let after = room - (name == nil ? 0 : 2 + capsule)
            if after >= chip {
                plan.chip = chip
                plan.chipCut = words(track) + chipFrame > chipMost
            } else if after - chipFrame >= fewest {
                plan.chip = after
                plan.chipCut = true
            } else {
                plan.chip = Door.side
                plan.chipBare = true
            }
            room -= (plan.chip ?? 0) + (name == nil ? 0 : 2)
        }
        guard let name else { return plan }
        if room >= capsule {
            plan.width = capsule
            plan.cut = words(name, size: SidebarTypography.current) + frame > most
        } else if room - frame >= fewest {
            plan.width = room
            plan.cut = true
        } else {
            plan.width = Door.side
            plan.bare = true
        }
        return plan
    }

    /// At the head of the strip.
    @MainActor static func strip(name: String) -> CapsulePlan {
        CapsulePlan(width: min(mostInStrip, words(name, size: SidebarTypography.current) + stripFrame), cut: words(name, size: SidebarTypography.current) + stripFrame > mostInStrip)
    }
}

/// The column's foot.
struct SideFoot: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var hoard: Hoard

    var body: some View {
        tabsFoot
    }

    /// The column on the window's right: the foot mirrored, the plus
    /// nearest the page and the downloads in the window's outer corner, as
    /// the downloads stand in the outer corner with the column on the left.
    private var mirrored: Bool { browser.flank == .right }

    private var tabsFoot: some View {
        HStack(spacing: 2) {
            if mirrored {
                corner
                mailDoor
                middle
                HoardSlot(hoard: hoard, place: .side)
            } else {
                // Downloads keeps the same outer corner, including in Mail.
                HoardSlot(hoard: hoard, place: .side)
                middle
                mailDoor
                corner
            }
        }
        .padding(.horizontal, SideBar.margin)
        .padding(.bottom, SideBar.margin)
    }

    /// The spaces, Mail's among them in its place (turnOrder), in Mail's
    /// foot too: the way back out is one of them (footShowsSpaces).
    @ViewBuilder private var middle: some View {
        if browser.footShowsSpaces {
            SpaceRow(browser: browser)
                .padding(.horizontal, 2)
        } else {
            Spacer(minLength: CapsulePlan.air - 4)
        }
    }

    /// Mail's space, in and out, only where nothing else goes there: with
    /// spaces it is one of them in the row, and the mail pin is a door of
    /// its own. Spaces off and no pin: this.
    @ViewBuilder private var mailDoor: some View {
        if MailCenter.shared.connected, !prefs.usesSpaces, browser.windowPurpose == .normal, !MailCenter.hasPin(browser) {
            MailDoor(browser: browser)
        }
    }

    /// Arc's plus: what can be made new. A newer Yab's Update button stands
    /// in its place while there is something to say.
    private var corner: some View {
        UpdateOrCapsule(browser: browser, calls: browser.calls) {
            FootPlus(browser: browser)
        }
    }
}

/// How the spaces stand in the foot, as Arc's do (its recording of
/// 2026-10-09, work/design/arc-space-dots-2026-10-09): the room between the
/// downloads and the plus shared out among them, never more than 34 points
/// each; with less than 22 each, too little for an emoji and its plate,
/// dots, in the one frame it happens. The foot keeps about 77 points for
/// its doors and edges, Arc's 82, so it gives way near Arc's widths: four
/// spaces below a column of about 165 points (narrower than the column
/// goes), five below 187, six below 209, seven below 231.
struct SpaceRowPlan: Equatable {
    var icons: Bool
    var pitch: CGFloat
    /// Automatic dots keep the current space recognizable by its icon.
    var activeIcon: Bool
    /// Too many even for dots: the row scrolls, the space on screen kept
    /// in the middle.
    var scrolls: Bool

    static let widest: CGFloat = 34
    static let fewest: CGFloat = 22
    static let dotWidest: CGFloat = 22
    static let dotFewest: CGFloat = 10
    /// Dots asked for (`prefs.spaceDots`) stand close, as Dia's do.
    static let dotsAsked: CGFloat = 14

    /// `lent`: what the Update button takes over the plus's place. For as
    /// long as it stands there the spaces keep the look the plus would
    /// leave them, closer, so an update never turns emoji to dots; with
    /// less than dots' asked pitch each they give way all the same.
    init(room: CGFloat, count: Int, dots: Bool = false, lent: CGFloat = 0) {
        let each = room / CGFloat(max(1, count))
        icons = !dots && (room + lent) / CGFloat(max(1, count)) >= Self.fewest && each >= Self.dotsAsked
        activeIcon = !dots
        // Reserve an icon slot before sharing the remaining room among dots.
        let dotRoom = !dots && count > 1 ? (room - Self.fewest) / CGFloat(count - 1) : each
        pitch = icons ? min(Self.widest, each) : min(dots ? Self.dotsAsked : Self.dotWidest, max(Self.dotFewest, dotRoom))
        let minimum = dots ? Self.dotFewest * CGFloat(count) : Self.fewest + Self.dotFewest * CGFloat(max(0, count - 1))
        scrolls = !icons && room < minimum
    }

    func width(on: Bool) -> CGFloat {
        !icons && activeIcon && on ? max(Self.fewest, pitch) : pitch
    }
}

/// The spaces in the foot, Mail's among them in its place: each its emoji,
/// gray but the one on screen, or with too little room a dot, the space on
/// screen keeping its icon unless dots were explicitly chosen. Under the
/// pointer a space shows its emoji in color, a dot too, and its tip names
/// it with its key. Dragged along the row, a space takes another place, as
/// in Arc; a right click has its menu.
struct SpaceRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var news = UpdateNews.shared
    /// The space in the hand, and how far it has come.
    @State private var lifted: UUID?
    @State private var lift: CGFloat = 0

    var body: some View {
        GeometryReader { room in
            let order = browser.turnOrder
            let plan = SpaceRowPlan(room: room.size.width, count: order.count, dots: browser.prefs.spaceDots,
                                    lent: news.sideButton > 0 ? max(0, news.sideButton - Door.side) : 0)
            ScrollViewReader { reader in
                ThreadScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(order.enumerated()), id: \.element.id) { index, space in
                            SpaceSlot(browser: browser, space: space, index: index, on: space.id == browser.spaceID, plan: plan)
                                .id(space.id)
                                .offset(x: shift(index, order, plan))
                                .zIndex(lifted == space.id ? 1 : 0)
                                .animation(lifted == nil || lifted == space.id ? nil : Motion.settle, value: shift(index, order, plan))
                                .highPriorityGesture(drag(space, order: order, plan: plan))
                        }
                    }
                    // Fewer than fill it: in the middle of the room.
                    .frame(minWidth: room.size.width, minHeight: Door.side)
                }
                .scrollDisabled(!plan.scrolls)
                .onAppear { if plan.scrolls { reader.scrollTo(browser.spaceID, anchor: .center) } }
                // Only while it scrolls: asked, the scroll view lays the
                // window out there and then, in every switch's pass.
                .onChange(of: browser.spaceID) { _, id in if plan.scrolls { reader.scrollTo(id, anchor: .center) } }
                .onChange(of: plan.scrolls) { _, scrolls in if scrolls { reader.scrollTo(browser.spaceID, anchor: .center) } }
            }
        }
        .frame(height: Door.side)
    }

    /// Where the space in the hand would land: anywhere, Mail too.
    private func landing(_ from: Int, _ order: [Space], _ plan: SpaceRowPlan) -> Int {
        var edge: CGFloat = 0
        let centers = order.map { space in
            let width = plan.width(on: space.id == browser.spaceID)
            defer { edge += width }
            return edge + width / 2
        }
        let target = centers[from] + lift
        return centers.indices.min { abs(centers[$0] - target) < abs(centers[$1] - target) } ?? from
    }

    /// Each space's way out of the one in the hand's path.
    private func shift(_ index: Int, _ order: [Space], _ plan: SpaceRowPlan) -> CGFloat {
        guard let lifted, let from = order.firstIndex(where: { $0.id == lifted }) else { return 0 }
        if index == from { return lift }
        let to = landing(from, order, plan)
        let width = plan.width(on: order[from].id == browser.spaceID)
        if from < to, index > from, index <= to { return -width }
        if from > to, index < from, index >= to { return width }
        return 0
    }

    private func drag(_ space: Space, order: [Space], plan: SpaceRowPlan) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                lifted = space.id
                lift = drag.translation.width
            }
            .onEnded { _ in
                guard lifted == space.id, let from = order.firstIndex(where: { $0.id == space.id }) else { return }
                let to = landing(from, order, plan)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    browser.moveInOrder(space.id, to: to)
                    lifted = nil
                    lift = 0
                }
            }
    }
}

/// One space in the row.
struct SpaceSlot: View {
    /// Where each space's slot stands in the column's host, for the bench.
    static var drawn: [UUID: CGRect] = [:]
    /// How strong a space's symbol or dot is off screen, as Arc's measure
    /// against its space on screen (arc-grain foot, 2026-10-23).
    static let dim = 0.4

    let browser: Browser
    let space: Space
    let index: Int
    let on: Bool
    let plan: SpaceRowPlan

    @State private var hovering = false
    /// A tab or a folder held over it (SpaceDrop): let go, it goes here.
    @ObservedObject private var drop = SpaceDrop.shared
    @Environment(\.tone) private var tone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let held = drop.slot == space.id
        Button { browser.switchSpace(to: space.id) } label: {
            ZStack {
                if plan.icons || held {
                    // The foot's doors' corner, a row's (FootPlus); held
                    // over, the ring a picked color wears, as the capsule's.
                    RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                        .fill(hovering || held ? Palette.hover(on: tone) : .clear)
                        .frame(width: min(plan.pitch - 2, Door.side))
                        .overlay {
                            if held {
                                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                }
                if hovering || held || (plan.activeIcon && on) {
                    SpaceMark(icon: space.icon, size: 12).fixedSize()
                        .foregroundStyle(Palette.ink)
                } else if plan.icons, !Spaces.isEmoji(space.icon) {
                    // A symbol dims as Arc's do: the ink at Arc's strength,
                    // not the muted words' gray, which on Glass is the ink
                    // itself and left the space on screen like the rest
                    // (register #427).
                    SpaceMark(icon: space.icon, size: 12).fixedSize()
                        .foregroundStyle(Palette.ink.opacity(SpaceSlot.dim))
                } else if plan.icons {
                    // Gray as Arc's; the space on screen and the one under
                    // the pointer in their own colors.
                    Image(nsImage: GrayMark.image(space.icon, size: 12, dark: (tone?.scheme ?? scheme) == .dark))
                        .opacity(0.5)
                } else {
                    Circle()
                        .fill(on ? Palette.strong(on: tone) : Palette.ink.opacity(SpaceSlot.dim))
                        .frame(width: on ? 7 : 4, height: on ? 7 : 4)
                        // The old one shrinks to gray as the new one grows,
                        // nothing travels (picked 2026-10-19, artifact
                        // VptJwGPe, variant A).
                        .animation(.easeOut(duration: 0.14), value: on)
                }
            }
            .frame(width: plan.width(on: on), height: Door.side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(SpaceAnchor(kind: .slot(space.id)))
        .animation(Motion.quick, value: held)
        // Where it stands, for the bench to carry a tab to (rowframes).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [id = space.id] in SpaceSlot.drawn[id] = $0 }
        .onHover { inside in
            hovering = inside
            // About to be clicked: its page made now, if it isn't, so the
            // click finds it (SpacePager.prepare).
            if inside, !on { DispatchQueue.main.async { [browser, id = space.id] in SpacePager.shared.prepare(browser, only: id) } }
        }
        .animation(Motion.quick, value: hovering)
        .keyTip(space.name, keys: keys, side: .above)
        // The space's menu, the same as from its name in the column
        // (SpaceMenu); then the whole row as dots or not (`prefs.spaceDots`).
        .steadyMenu(actions: true) {
            SpaceMenu(browser: browser, space: space)
            Divider()
            // The way the row is not drawn now, with that way's mark.
            let dots = browser.prefs.spaceDots
            Button(dots ? "Show Spaces as Emoji" : "Show Spaces as Dots", mark: dots ? "face.smiling" : "ellipsis") {
                withAnimation(Motion.quick) { browser.prefs.spaceDots = !dots }
            }
        }
        .accessibilityLabel(space.name)
        .accessibilityValue(on ? "Selected" : "")
    }

    /// ⌃1 to ⌃9, as they are set now; Mail's own ⇧⌘I for Mail, whose
    /// number by its place works too.
    private var keys: String? {
        if space.id == Space.mailID {
            let text = Keymap.shared.text(.mail)
            return text.isEmpty ? nil : text
        }
        guard index < 9, let action = Shortcut.Action(rawValue: "space\(index + 1)") else { return nil }
        let text = Keymap.shared.text(action)
        return text.isEmpty ? nil : text
    }
}

/// A space's emoji in gray, drawn once: SwiftUI's saturation doesn't reach
/// a color emoji's glyph, which keeps its colors under the filter. A mark
/// whose gray is near the ground's own is brought off it, as far as the
/// others stand: Mail's ✉️ is white, and gray at half strength it was gone
/// from a light column, its place an empty gap in the row.
@MainActor
enum GrayMark {
    private static var made: [String: NSImage] = [:]
    private static let context = CIContext()

    /// How light the ink of a gray mark stands, on light ground and dark,
    /// once it is too near the ground's to see at half strength.
    nonisolated static let onLight = 0.45
    nonisolated static let onDark = 0.6

    static func image(_ icon: String, size: CGFloat, dark: Bool = false) -> NSImage {
        let key = "\(size)|\(dark)|\(icon)"
        if let hit = made[key] { return hit }
        // As SpaceMark sets it.
        let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: size + 1)])
        let box = NSSize(width: ceil(text.size().width), height: ceil(text.size().height))
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        guard box.width > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.width * scale), pixelsHigh: Int(box.height * scale),
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = box
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        text.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        let shift = lift(ink(rep), dark: dark)
        guard let source = CIImage(bitmapImageRep: rep),
              let gray = context.createCGImage(source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputBrightnessKey: shift]),
                                               from: source.extent)
        else { return NSImage() }
        let image = NSImage(cgImage: gray, size: box)
        if made.count > 64 { made.removeAll() }
        made[key] = image
        return image
    }

    /// How much lighter (or darker, negative) a mark's gray is drawn for
    /// its ink to stand off the ground: none for one that already does.
    nonisolated static func lift(_ ink: Double?, dark: Bool) -> Double {
        guard let ink else { return 0 }
        if dark { return ink < onDark - 0.2 ? onDark - ink : 0 }
        return ink > onLight + 0.2 ? onLight - ink : 0
    }

    /// How light the mark's ink is, as gray, its pixels weighed by how
    /// much of them is drawn.
    private static func ink(_ rep: NSBitmapImageRep) -> Double? {
        guard let data = rep.bitmapData else { return nil }
        let step = rep.bitsPerPixel / 8, row = rep.bytesPerRow
        var light = 0.0, weight = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let at = data + y * row + x * step
                let alpha = Double(at[3]) / 255
                guard alpha > 0 else { continue }
                // Premultiplied: the color is over its own alpha.
                light += (0.299 * Double(at[0]) + 0.587 * Double(at[1]) + 0.114 * Double(at[2])) / 255
                weight += alpha
            }
        }
        return weight > 0 ? light / weight : nil
    }
}

/// The plus in the foot's corner, as Arc's: what can be made new, in the
/// Mac's own menu over it, the plus turned into a cross while it is up.
/// The space tray grows out of it, and a tab held over it opens the tray to
/// take it to another space.
struct FootPlus: View {
    let browser: Browser

    @State private var open = false
    @State private var hovering = false
    @State private var box = ViewBox()
    /// When a press on the cross put the menu away: the press goes on to
    /// this button, whose release would raise the menu again.
    @State private var pressClosed: Date?
    @ObservedObject private var drop = SpaceDrop.shared
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var still

    // Its corner is a row's: 8 in from the window's 18 corner, and the
    // rows over it round so too.
    var body: some View {
        Button { show() } label: {
            Symbol("plus", size: 11, weight: .medium)
                // Arc's: a cross in 0.1 s, once the menu is up.
                .rotationEffect(.degrees(open ? 45 : 0))
                .animation(still ? nil : .easeOut(duration: 0.1), value: open)
                .foregroundStyle(open || hovering ? Palette.ink : Palette.muted(on: tone))
                .frame(width: Door.side, height: Door.side)
                .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .background(
            RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                .fill(open ? Palette.wash(on: tone) : (hovering || drop.hot ? Palette.hover(on: tone) : .clear))
        )
        // A tab held over it: the ring a picked color wears.
        .overlay {
            if drop.hot {
                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .onHover { hovering = $0 }
        // Beside it, clear of the menu that rises over it, and none while
        // that menu is up.
        .keyTip(open ? "" : "New", side: .right)
        .background {
            ZStack {
                SpaceAnchor(kind: .plus)
                SpaceAnchor(kind: .dot)
                FootPlusAnchor(box: box)
            }
        }
        .accessibilityLabel("New")
    }

    private func show() {
        if let at = pressClosed {
            pressClosed = nil
            if Date().timeIntervalSince(at) < 2 { return }
        }
        guard let view = box.view else { return }
        open = true
        let menu = FootPlusMenu.make(browser)
        guard let window = view.window else { open = false; return }
        // The searchable panel (ActionMenu.swift) over the plus, rising from
        // its top-left, its search at its foot nearest the plus.
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        FootPlusMenu.shown = menu
        ActionMenu.show(menu, in: window, at: NSPoint(x: frame.minX, y: frame.maxY + 4), up: true) {
            FootPlusMenu.shown = nil
            open = false
            pressClosed = NSEvent.pressedMouseButtons & 1 != 0 ? Date() : nil
        }
    }
}

/// A plain view under the plus, for its menu to hang from.
private struct FootPlusAnchor: NSViewRepresentable {
    let box: ViewBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(FootPlusMenu.anchorID)
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// The plus's menu: Arc's, with Yab's own. What can't be made here stays
/// in its place, grayed.
@MainActor
enum FootPlusMenu {
    /// Its anchor's name, for the bench to find it by.
    static let anchorID = "yab.foot-plus"
    /// The menu while it is up, for the bench to read and let go.
    static weak var shown: NSMenu?

    static func make(_ browser: Browser) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func line(_ title: String, _ mark: String, keys action: Shortcut.Action? = nil, enabled: Bool = true, act: @escaping () -> Void) {
            let item = PageMenuItem(title, act: act)
            MenuMark.put(mark, on: item)
            if let action, let hotkey = Keymap.shared.keys(action) { item.shortcut(hotkey) }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if browser.spacesShown {
            line("New Space…", "square.2.layers.3d") { SpaceTray.open(browser) }
        }
        line("New Folder", "yab.folder.plus") {
            browser.folderBook.unfoldSpace()
            browser.newEmptyFolder()
        }
        menu.addItem(.separator())
        let tab = browser.active
        // For the site in front, or, with none, for the one the words name:
        // never a dead row (register #447).
        line("New Boost…", "wand.and.stars") { browser.newBoost() }
        menu.addItem(.separator())
        line("Split View", "yab.split.plus", keys: .split, enabled: tab.map { browser.pair(of: $0.id) == nil } ?? false) {
            browser.splitView()
        }
        line("New Tab", "yab.tab.plus", keys: .newTab) { browser.newTab() }
        return menu
    }
}

/// The space the capsule is drawn for, a frame behind the one on screen:
/// a switch lays out the whole row of tabs on the frame it happens, and a
/// curve started then spends itself with nothing drawn. The strip's tabs start after the capsule, so
/// they take their place from this too, and move with it.
@MainActor
final class SpaceShown: ObservableObject {
    static let shared = SpaceShown()
    @Published private(set) var id: UUID?
    /// Counts the switches whose rows come in on their own (SpaceTurn):
    /// not one two fingers brought, whose rows were already there.
    @Published private(set) var arrivals = 0
    /// The next switch is two fingers': its rows don't come in again.
    var pulled = false
    /// How far along the strip's turn starts: 0 for a key or a pick, as far
    /// as two fingers had taken it for a swipe let go (SpacePull).
    var handoff: CGFloat = 0

    func follow(_ next: UUID, now: Bool = false) {
        let arrives = !pulled
        pulled = false
        // The strip's rows and capsule turn in this pass (StripTurns).
        if id != next, !now, let id { StripTurns.shared.begin(from: id, start: handoff) }
        handoff = 0
        let move: @MainActor @Sendable () -> Void = { [self] in
            if id != next {
                id = next
                if arrives { arrivals += 1 }
            }
            SpacePull.shared.shown(next)
        }
        if now || id == nil { move(); return }
        DispatchQueue.main.async(execute: move)
    }

    /// The space to draw: the one followed, while it is still there.
    func space(in browser: Browser) -> Space {
        browser.spaces.first { $0.id == (id ?? browser.spaceID) } ?? browser.space
    }
}

/// A change of space across the top, begun in the switch's own pass
/// (SpaceShown.follow): the space left, how many have begun, and where the
/// one under way starts (0 for a key or a pick, as far as two fingers had
/// taken it for a swipe). Begun a frame later, the old row was gone and the
/// new one waited unseen through the switch's long pass, an empty strip for
/// 80 ms; begun with it, the old row stays on screen through that pass and
/// the two cross after it. Apart from SpaceShown, whose space comes a frame
/// later, so the strip isn't drawn again for that.
@MainActor
final class StripTurns: ObservableObject {
    static let shared = StripTurns()
    @Published private(set) var left: UUID?
    @Published private(set) var started = 0
    private(set) var start: CGFloat = 0

    func begin(from: UUID, start: CGFloat) {
        self.start = start
        left = from
        started += 1
    }
}

/// The capsule: the space on screen, and the way to all of them.
///
/// Held against one edge, the column's right or the strip's left: that edge
/// and the chevron beside it never move. A change of space opens or closes
/// the difference between two names at the other edge, on an ease with no
/// bounce: the width is
/// animated over the press's scale, never under it, since a width animated
/// under a geometry effect is drawn from the wrong edge; the chevron is laid
/// against the capsule's own edge, not after the words, so no word can push
/// it; and the words are clipped by the capsule, not by the emoji's box.
struct SpaceCapsule: View {
    @ObservedObject var browser: Browser
    let plan: CapsulePlan
    /// The tray comes up out of it in the column, down out of it in the strip.
    var up = true

    @State private var hovering = false
    /// The space it is drawn for, a frame behind the one on screen.
    @ObservedObject private var shown = SpaceShown.shared
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A tab held over it: it opens in a moment.
    @ObservedObject private var drop = SpaceDrop.shared
    /// Two fingers taking the space elsewhere: the words make way.
    @ObservedObject private var pull = SpacePull.shared
    /// A change of space across the top under way (StripTurn).
    @ObservedObject private var turns = StripTurns.shared

    /// Off at once, since a key or the fingers asked for it, and a long
    /// quiet landing: a spring's settle on an edge sliding a few points
    /// reads as a wobble.
    static let change = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.2)
    /// The old words go first and quickly, the new ones come in a beat
    /// after: the two never stand over each other half seen, and the new
    /// name arrives as the capsule has grown to take it.
    static let out = Animation.easeOut(duration: 0.08)
    static let into = SpaceTurn.pace.delay(0.05)

    private var pulling: Bool { pull.active && (pull.from?.id == browser.spaceID || pull.to?.id == browser.spaceID) }
    /// Across the top: a plate of its own, the name with no chevron, and the
    /// strip's turn (StripTurn).
    private var strip: Bool { !up }
    private var still: Bool { reduceMotion || SpaceTurn.still }

    var body: some View {
        // Across the top, the space on screen, in the switch's own pass: the
        // strip is laid out for it at once and drawn there on the turn's
        // spring (StripTurn). In the column, a frame behind (SpaceShown).
        let space = strip ? browser.space : shown.space(in: browser)
        let width = self.width(space)
        Button { SpaceTray.openSpaces(browser) } label: {
            ZStack(alignment: plan.bare ? .center : .leading) {
                if strip {
                    // Laid out at the new width at once, drawn there on the
                    // turn's spring (CapsulePlate).
                    CapsulePlate(width: width)
                        .fill(Palette.resting(on: tone, hovering: hovering || drop.hot))
                        .transaction(value: width) { StripTurn.carry(&$0, on: !(pulling || still || !StripTurn.swiftUI("slide"))) }
                } else {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(hovering || drop.hot ? Palette.hover(on: tone) : .clear)
                }
                if plan.bare {
                    SpaceMark(icon: space.icon, size: 12).fixedSize()
                } else if strip {
                    stripWords(space, width: width)
                } else {
                    words(space, width: width)
                    // Big and dark enough to be seen as the way to the others:
                    // at 7 in the muted ink it read as a speck.
                    Symbol(up ? "chevron.up" : "chevron.down", size: 9, weight: .semibold)
                        .foregroundStyle(Palette.ink.opacity(0.6))
                        .frame(width: CapsulePlan.chevron)
                        .padding(.trailing, CapsulePlan.inset)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: width, height: up ? Door.side : CapsulePlan.stripHeight)
            // A tab held over it: the ring a picked color wears, as the
            // row it would go to will.
            .overlay {
                if drop.hot {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed, anchor: up ? .trailing : .leading))
        // Over the press's scale, so the edge it is held against places it.
        // The fingers move it themselves. Across the top, on the turn's spring.
        .animation(pulling || still || strip ? nil : Self.change, value: width)
        .focusable(false)
        // Something plays in a space that isn't on screen.
        .overlay(alignment: .topTrailing) {
            if noisy {
                Circle().fill(Palette.ink)
                    .overlay(Circle().stroke(GroundFill<Circle>.ground(tone, browser: browser), lineWidth: 1.5))
                    .frame(width: 7, height: 7)
                    .offset(x: 2, y: -2)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        // What the tray grows out of, and what a new space's card lands on.
        .background {
            ZStack {
                SpaceAnchor(kind: .plus)
                SpaceAnchor(kind: .dot)
            }
        }
        // Its name under the pointer only when the capsule can't show all
        // of it. No key: ⌃N for the space already on screen does nothing.
        .modifier(CapsuleTip(title: plan.bare || plan.cut ? space.name : nil))
        .accessibilityLabel("Space: \(space.name)")
        .animation(Motion.quick, value: hovering)
        // What is on screen to begin with; each switch says the rest
        // (Browser.switchSpace).
        .onAppear { shown.follow(browser.spaceID, now: true) }
    }

    /// A name's width in the capsule, as far as the plan lets it grow.
    private func natural(_ space: Space) -> CGFloat {
        if strip { return CapsulePlan.strip(name: space.name).width ?? 0 }
        return min(up ? CapsulePlan.most : CapsulePlan.mostInStrip, CapsulePlan.words(space.name, size: nameSize) + CapsulePlan.frame)
    }

    /// Its width: a door's with the emoji alone; what the plan leaves when
    /// the name is cut; the name's own otherwise; and while two fingers take
    /// the space elsewhere, as far from this one's to the next one's as
    /// they have gone. Across the top it holds the space on screen's width
    /// under the fingers, and springs to the next one's once it comes.
    private func width(_ space: Space) -> CGFloat {
        if plan.bare { return Door.side }
        if pulling, let from = pull.from {
            if strip { return natural(from) }
            if let to = pull.to {
                let a = natural(from), b = natural(to)
                return a + (b - a) * pull.progress
            }
        }
        if plan.cut, let width = plan.width { return width }
        return natural(space)
    }

    // MARK: across the top

    /// The emoji and the name across the top, clipped by the plate: under
    /// two fingers the two spaces' names one after the other, as far as the
    /// fingers have gone (or, at an end, the name giving a little); on a
    /// switch the same carousel on the turn's spring, from where the
    /// fingers left it or from the start.
    private func stripWords(_ space: Space, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // The switch's carousel, always there so it hears each turn
            // begin, from a key or from fingers letting go: under the
            // fingers it stands aside for their own.
            // Handed over in one frame both ways: faded, the name stood
            // twice, the still one over the one under the fingers.
            turning(space).opacity(pulling ? 0 : 1)
                .animation(nil, value: pulling)
            if pulling, let from = pull.from {
                Group {
                    if pull.edge {
                        label(from).offset(x: -CGFloat(pull.dir) * pull.progress * StripTurn.giveTravel)
                    } else if let to = pull.to {
                        StripCarousel(from: from, to: to, way: pull.dir, progress: pull.progress, label: label)
                    }
                }
                .transition(.identity)
            }
        }
        .frame(height: CapsulePlan.stripHeight)
        .padding(.leading, CapsulePlan.stripInset)
        .frame(width: width, height: CapsulePlan.stripHeight, alignment: .leading)
        .transaction(value: width) { $0.animation = nil }
        .clipShape(CapsulePlate(width: width))
        .transaction(value: width) { StripTurn.carry(&$0, on: !(pulling || still || !StripTurn.swiftUI("slide"))) }
    }

    /// The name on screen, and on a switch the carousel from the space left
    /// to it, on the turn's spring from where it starts (StripTurns).
    @ViewBuilder
    private func turning(_ space: Space) -> some View {
        if still || !StripTurn.swiftUI("carousel") {
            label(space)
        } else {
            let before = browser.spaces.first { $0.id == turns.left && $0.id != space.id }
            let way = browser.spaceStep
            label(space)
                .keyframeAnimator(initialValue: CGFloat(1), trigger: turns.started) { _, p in
                    StripCarousel(from: before ?? space, to: space, way: way, progress: before == nil ? 1 : p, label: label)
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(turns.start)
                        SpringKeyframe(1, duration: StripTurn.span, spring: StripTurn.spring)
                    }
                }
        }
    }

    /// The emoji and the name, in the room between the capsule's leading
    /// edge and the chevron, clipped there. ⌃N, a pick: the new ones come in
    /// from the side the space lies on as the old go out the other, 8
    /// points, in the switch's beat, as the rows do by 24.
    /// Two fingers: the two spaces' words one behind the other, slid as far
    /// as the fingers.
    private func words(_ space: Space, width: CGFloat) -> some View {
        // From the capsule's edge, so an emoji wider than its box is never
        // cut, to the gap before the chevron.
        let room = max(0, width - CapsulePlan.inset - CapsulePlan.chevron - CapsulePlan.gap)
        return Group {
            if pulling, let from = pull.from, let to = pull.to {
                let d = CGFloat(pull.dir)
                let span = room
                ZStack(alignment: .leading) {
                    // Each fades as it goes to the edge and comes up as it
                    // comes in from the other, rather than being cut there:
                    // the leaving one gone by two thirds of the way, the
                    // coming one there from a third.
                    label(from).offset(x: -d * span * pull.progress)
                        .opacity(Double(max(0, 1 - pull.progress * 1.5)))
                    label(to).offset(x: d * span * (1 - pull.progress))
                        .opacity(Double(min(1, max(0, pull.progress * 1.5 - 0.5))))
                }
            } else {
                let step = CGFloat(browser.spaceStep)
                ZStack(alignment: .leading) {
                    label(space)
                        .id(space.id)
                        .transition(SpaceTurn.still || reduceMotion || pull.quiet ? .identity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 8 * step)).animation(Self.into),
                            removal: .opacity.combined(with: .offset(x: -8 * step)).animation(Self.out)
                        ))
                }
                .animation(SpaceTurn.still || reduceMotion || pull.quiet ? nil : SpaceTurn.pace, value: space.id)
            }
        }
        .padding(.leading, CapsulePlan.inset)
        .frame(width: room, alignment: .leading)
        .clipped()
        // Gone by the end of the way: the name that has arrived is whole.
        .modifier(EdgeFade(on: pulling, strength: min(1, (1 - pull.progress) * 3)))
    }

    private func label(_ space: Space) -> some View {
        HStack(spacing: strip ? CapsulePlan.stripGap : CapsulePlan.gap) {
            // Its own width, wider than the box it is placed by: an emoji's
            // advance runs past its drawing, and a Text held narrower than
            // that is cut on the right.
            SpaceMark(icon: space.icon, size: 12)
                .foregroundStyle(Palette.ink)
                .fixedSize()
                .frame(width: CapsulePlan.mark)
            name(space)
        }
        .fixedSize()
    }

    /// The emoji and the name across the top, as the turn pictures them
    /// (StripView): what `label` draws in the strip.
    static func stripLabel(_ space: Space) -> some View {
        HStack(spacing: CapsulePlan.stripGap) {
            SpaceMark(icon: space.icon, size: 12)
                .foregroundStyle(Palette.ink)
                .fixedSize()
                .frame(width: CapsulePlan.mark)
            Text(space.name)
                .font(.system(size: SidebarTypography.current))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// A tab title's size, in the column and the strip alike.
    private var nameSize: CGFloat { SidebarTypography.current }

    /// The name, its end faded when there is no room for all of it.
    @ViewBuilder
    private func name(_ space: Space) -> some View {
        // A tab title's type, in the strip and the column alike: the
        // capsule names a set of tabs, it doesn't shout over them.
        let text = Text(space.name)
            .font(.system(size: nameSize))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
        if plan.cut, !pulling {
            let frame = strip ? CapsulePlan.stripFrame : CapsulePlan.frame
            text.frame(width: max(0, (plan.width ?? 0) - frame), alignment: .leading)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
        } else {
            text
        }
    }

    private var noisy: Bool {
        browser.parked.contains { id, row in id != browser.spaceID && row.tabs.contains { $0.noisy } }
    }
}

/// How much of a row shows under two fingers: drawn from `progress` through
/// StripTurn's curves on every frame, so that on the way back after a cancel
/// too only one of the two rows ever shows.
struct StripCross: ViewModifier, Animatable {
    var progress: CGFloat
    let coming: Bool
    let on: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(on ? Double(coming ? StripTurn.coming(progress) : StripTurn.going(progress)) : 1)
    }
}

/// The strip capsule's plate, `width` wide from its leading edge whatever
/// the frame it is laid in: the frame takes the new space's width at once,
/// one layout, and the plate and what it clips get there on the turn's
/// spring, drawn again each frame but not laid out again (StripTurn).
struct CapsulePlate: Shape {
    var width: CGFloat
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: max(0, width), height: rect.height),
             cornerRadius: Radius.control, style: .continuous)
    }
}

/// The strip capsule's two names, one after the other, `progress` of the
/// way from `from` to `to`: the old one out the far side, faded as it
/// goes, the new one in from the side the space lies on (`way`), there by
/// a little past two thirds (StripTurn).
private struct StripCarousel<Label: View>: View {
    let from: Space
    let to: Space
    let way: Int
    let progress: CGFloat
    let label: @MainActor (Space) -> Label

    var body: some View {
        let p = min(1, max(0, progress))
        // The old name's own width and the gap: where the new one stands
        // behind it, so the two never overlap however long either is.
        let span = CapsulePlan.mark + CapsulePlan.stripGap + CapsulePlan.words(from.name, size: SidebarTypography.current) + StripTurn.nameGap
        let d = CGFloat(way == 0 ? 1 : way)
        ZStack(alignment: .leading) {
            if from.id != to.id, p < 1 {
                label(from)
                    .offset(x: -d * p * span)
                    .opacity(Double(1 - p))
            }
            label(to)
                .offset(x: from.id == to.id ? 0 : d * (1 - p) * span)
                .opacity(from.id == to.id ? 1 : Double(min(1, p * 1.4)))
        }
        .frame(maxHeight: .infinity, alignment: .leading)
    }
}

/// While two fingers slide the words, their right end fades out before the
/// chevron instead of being cut there. Only then: a mask is a layer the
/// render server draws through, and at rest there is nothing to fade.
private struct EdgeFade: ViewModifier {
    /// Kept on for the whole swipe, so the words aren't made again when it
    /// comes to nothing near the end.
    let on: Bool
    /// 1 fades the end out altogether, 0 not at all.
    let strength: CGFloat
    static let width: CGFloat = 10

    func body(content: Content) -> some View {
        if on {
            content.mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(Double(1 - strength))], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.width)
                }
            }
        } else {
            content
        }
    }
}

/// The capsule's name under the pointer, only when it isn't all there.
private struct CapsuleTip: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title { content.keyTip(title) } else { content }
    }
}

// MARK: - the turn

/// A change of space with the tabs across the top, as Dia's strip does it,
/// filmed at 60 fps (evals/dia-top-spaces, feedback #254) and kept without
/// its stalls: one critically damped spring, ω 26 rad/s (99% in about
/// 270 ms), carries the capsule's width, the window's color and the
/// space's name in from the side it lies on. The next space's page and
/// tabs are there in the first frame, the tabs 24 points in and coming up
/// over 140 ms, the old ones going 16 points the other way.
///
/// Two fingers over the capsule: the names move under them like a
/// carousel, the tabs fade and the color mixes as far as they have gone of
/// `reach`. Let go, any way toward a neighbor brings it at once; there is
/// no way round the ends, the name gives a little there and springs back.
enum StripTurn {
    static let omega: Double = 26
    static var response: Double { 2 * .pi / omega }
    /// How long the main thread draws it: by then it is 99.3% of the way,
    /// and the rest, under 2 points of the widest change, lands with the
    /// last frame. SwiftUI's own spring went on drawing for 0.7 s, a frame's
    /// work every frame of it.
    static let span: TimeInterval = 0.27
    static var animation: Animation { Animation(Curve()) }
    /// The turn's spring for what changes in `t`, or none. Set on the
    /// transaction itself: a switch writes inside `quietly`, whose
    /// disablesAnimations drops an `.animation(_:value:)`, and the plate
    /// and the tabs after it jumped to the new space's place in one frame.
    static func carry(_ t: inout Transaction, on: Bool) {
        t.animation = on ? animation : nil
    }
    static var spring: Spring { Spring(response: response, dampingRatio: 1) }

    /// The spring's way, 0 to 1, `t` seconds after it set off.
    static func way(_ t: TimeInterval) -> Double {
        guard t > 0 else { return 0 }
        return 1 - (1 + omega * t) * exp(-omega * t)
    }

    /// The spring as SwiftUI's animation, over `span` and done.
    struct Curve: CustomAnimation {
        func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
            guard time < StripTurn.span else { return nil }
            return value.scaled(by: StripTurn.way(time))
        }
    }

    /// Parts of the turn left out, for the bench to weigh each against the
    /// main thread (bench `strip-turn`): "leaving", "arrival", "carousel",
    /// "slide".
    @MainActor static var cut: Set<String> = []
    /// The strip is in a host of its own (StripView), set when one is made.
    @MainActor static var hosted = false
    /// The turn is played by Core Animation over the strip's own host
    /// (StripView), not by SwiftUI in it: those parts stand still in it.
    /// "layers" in `cut` plays it in SwiftUI as before, for the bench.
    @MainActor static var layered: Bool { hosted && !cut.contains("layers") }
    /// One part of the turn played by SwiftUI: unless left out, or layered.
    @MainActor static func swiftUI(_ part: String) -> Bool { !layered && !cut.contains(part) }

    /// The new tabs' arrival, 0 to 1, `t` seconds in.
    static func arrived(_ t: TimeInterval) -> CGFloat {
        guard t > 0 else { return 0 }
        return CGFloat(arrivalCurve.value(at: min(1, t / arrivalTime)))
    }
    /// The same spring for Core Animation, mass 1.
    @MainActor static func caSpring(keyPath: String, from: Any, to: Any, velocity: CGFloat = 0) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = CGFloat(omega * omega)
        spring.damping = CGFloat(2 * omega)
        spring.initialVelocity = velocity.isFinite ? velocity : 0
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    /// The next space's tabs: in from this far, faded up over `arrivalTime`.
    static let arrival: CGFloat = 24
    static let arrivalTime: TimeInterval = 0.14
    static let arrivalCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.33, y: 1), endControlPoint: UnitPoint(x: 0.68, y: 1))
    /// The old tabs: this far the other way, gone 1.8 times as fast.
    static let leave: CGFloat = 16
    static let leaveSpeed: Double = 1.8
    /// Between one space's name and the next in the carousel.
    static let nameGap: CGFloat = 40
    /// Under two fingers: the old tabs go this far with them.
    static let follow: CGFloat = 40
    /// Under two fingers, `p` of the way: how much of the old row shows, and
    /// of the next one. One at a time, with `crossing` between them, so no
    /// title ever stands over another: crossed with both half seen, "Inbox"
    /// stood over "Linear" for the whole swipe (films, 10-29).
    static let crossing: CGFloat = 0.4
    static func going(_ p: CGFloat) -> CGFloat { max(0, min(1, (crossing - p) / 0.25)) }
    static func coming(_ p: CGFloat) -> CGFloat { max(0, min(1, (p - crossing) / 0.25)) }

    /// The fingers' travel for a whole space, and how much of it is enough
    /// to bring the next one when they lift.
    static let reach: CGFloat = 420
    static let enough: CGFloat = 0.03
    /// At an end: how far the name gives, at most, of a space, and in points.
    static let give: CGFloat = 0.12
    static let giveTravel: CGFloat = 120

    /// Where two fingers have taken the strip: toward which space, how far
    /// of the way (0 to 1), and which way (1 the next, -1 the one before).
    /// No space there: the end, given way to as far as `progress` says.
    struct Aim: Equatable {
        var to: Int?
        var progress: CGFloat
        var way: Int
    }

    /// From space `from` of `count`, after `travel` points of fingers,
    /// negative toward the next.
    static func aim(from: Int, count: Int, travel: CGFloat) -> Aim {
        let way = travel < 0 ? 1 : -1
        let far = abs(travel) / reach
        let there = from + way
        guard count > 1, (0..<count).contains(there) else {
            return Aim(to: nil, progress: give * (1 - exp(-far / give)), way: way)
        }
        return Aim(to: there, progress: min(1, far), way: way)
    }

    /// The fingers lift there: does the next space come?
    static func commits(_ aim: Aim) -> Bool { aim.to != nil && aim.progress > enough }

    /// ⌃→ and ⌃←: the next or the one before, round the ends.
    static func step(from: Int, count: Int, by: Int) -> Int? {
        guard count > 1 else { return nil }
        return ((from + by) % count + count) % count
    }
}

/// Two fingers sideways over the strip's capsule: the space goes with them
/// (StripTurn). The names move under the fingers, the tabs go a little the
/// way they go and fade, the next space's come up in their place, and the
/// window takes on its color (SpaceWash), each as far as the fingers have
/// gone of `StripTurn.reach`. Let go, any way toward a neighbor brings it at
/// once, the rest played out on the switch's spring from where the fingers
/// left it; at an end the name gives a little and springs back.
@MainActor
final class SpacePull: ObservableObject {
    static let shared = SpacePull()
    /// The rows' slide.
    @Published var x: CGFloat = 0
    /// How far toward `to`, 0 to 1; at an end, how far the name has given.
    @Published var progress: CGFloat = 0
    /// The space on screen and the one the fingers are taking it to, while
    /// they do. At an end `to` is nil and `edge` is set.
    @Published var from: Space?
    @Published var to: Space?
    @Published private(set) var edge = false
    /// 1 to the next space, -1 to the one before.
    private(set) var dir = 0
    private var next: SpaceWash.Paint?

    /// Where the fingers' switch is: following them, or the space come and
    /// only the words and rows handing over to the capsule's own.
    private enum Phase { case following, arrived }
    private var phase = Phase.following
    /// Letting go has brought the space.
    var landing: Bool { phase != .following }

    /// The column's own swipe, where its row of spaces can't come up
    /// (SpaceSwipe, unpaged): how far is a whole space, and enough.
    static let reach: CGFloat = 110
    static let enough: CGFloat = 0.4
    static let flickEnough: CGFloat = 0.15
    /// How far the next space's rows come in by (PagedSpace), as ⌃N's do.
    static let arrival: CGFloat = StripTurn.arrival

    /// Something is under the fingers: a neighbor coming, or an end giving.
    var active: Bool { to != nil || edge }

    /// The fingers have gone `travel`, negative toward the next space.
    func follow(_ travel: CGFloat, browser: Browser) {
        // Fingers on again while the last one hands over: it is done now,
        // and this one starts from the space it brought.
        if landing { hurry() }
        let spaces = browser.turnOrder
        guard let here = spaces.firstIndex(where: { $0.id == browser.spaceID }), spaces.count > 1 else { return }
        let aim = StripTurn.aim(from: here, count: spaces.count, travel: travel)
        let turned = aim.way != dir || (aim.to == nil) != edge || (!edge && to == nil)
        if turned { self.aim(aim, in: spaces, browser: browser) }
        // In steps of a two-hundredth: a trackpad sends more moves than the
        // screen shows frames, and each one drew the capsule and the rows
        // again for a change no one could see.
        let p = (aim.progress * 200).rounded() / 200
        guard turned || p != progress else { return }
        progress = p
        x = -CGFloat(dir) * StripTurn.follow * p
        if let next { browser.spaceWash.show(next, opacity: Float(p)) }
    }

    private func aim(_ aim: StripTurn.Aim, in spaces: [Space], browser: Browser) {
        if let next, !edge, progress > 0 { browser.spaceWash.show(next, opacity: 0) }
        dir = aim.way
        self.browser = browser
        from = browser.space
        edge = aim.to == nil
        next = nil
        guard let index = aim.to else { to = nil; return }
        let there = spaces[index]
        to = there
        // Its row ready to be drawn under this one (StripComing), as it
        // would be read on the switch anyway.
        if there.id != browser.spaceID, there.id != Space.mailID, browser.parked[there.id] == nil {
            browser.parked[there.id] = browser.loadRow(there.id)
        }
        // Its page in front, and the other half when it is one of two side
        // by side, woken now: by the time the fingers lift they are drawn,
        // rather than the last space's page standing in for them while they
        // load, and a pair opening out a moment after the space came.
        if let row = browser.parked[there.id], let front = row.tabs.first(where: { $0.id == row.active }) {
            if !front.wake() { front.revive() }
            if let pair = row.pairs.first(where: { $0.first == front.id || $0.second == front.id }),
               let other = row.tabs.first(where: { $0.id == (pair.first == front.id ? pair.second : pair.first) }) {
                if !other.wake() { other.revive() }
            }
        }
        next = SpaceWash.worn(there.paint ?? SpacePaint(browser.prefs), prefs: browser.prefs)
    }

    /// The row of the space the fingers are taking `browser` to, while they
    /// do and it isn't on screen yet: what the strip draws under its own
    /// (StripComing). Without the pins every space shares, which stand
    /// ahead of the strip's capsule, not in its run.
    func coming(in browser: Browser) -> Parked? {
        guard let to, from?.id == browser.spaceID, to.id != browser.spaceID else { return nil }
        return browser.parked[to.id]
    }

    /// A key or menu selection supersedes the strip's unfinished swipe: the
    /// old strip neither left faded nor its preview over the new tabs. Not
    /// the fingers' own switch (`commit`), which hands over itself.
    func interrupt(in browser: Browser) {
        guard from != nil, phase == .following, self.browser === browser else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            x = 0
            reset()
        }
        browser.spaceWash.hide()
    }

    /// The fingers lift: the next space if they went its way at all, or
    /// everything back.
    func release(_ browser: Browser) {
        guard phase == .following else { return }
        if let to, progress > StripTurn.enough { commit(browser, to: to) } else { cancel() }
    }

    /// The space comes now, with nothing waited for: the switch takes over
    /// the window's color from where the fingers left it (the old color
    /// over the new, as much as was left of it), and the capsule's words
    /// and the next space's tabs carry on from there (SpaceShown.handoff).
    private func commit(_ browser: Browser, to: Space) {
        phase = .arrived
        self.browser = browser
        SpaceShown.shared.handoff = progress
        browser.washFrom = Float(1 - progress)
        browser.switchSpace(to: to.id)
        browser.washFrom = 1
        // In the same pass the capsule's words and the strip's rows take over
        // from the fingers' (StripTurns), where they left them.
        handOver()
    }

    private weak var browser: Browser?
    /// Set for the pass the fingers' words hand over to the capsule's own:
    /// the same words, so nothing comes in or goes out.
    @Published private(set) var quiet = false

    /// The capsule and the rows are drawn for `id` now.
    func shown(_ id: UUID) {
        if phase == .arrived, to?.id == id { handOver() }
    }

    /// A new swipe before the last one has handed over: it does at once.
    private func hurry() {
        guard let to else { return reset() }
        SpaceShown.shared.follow(to.id, now: true)
        handOver()
    }

    private func handOver() {
        var still = Transaction()
        still.disablesAnimations = true
        quiet = true
        withTransaction(still) { reset() }
        DispatchQueue.main.async { [self] in quiet = false }
    }

    /// Let go short of a switch, or at an end: all of it back where it was,
    /// on the switch's spring.
    func cancel() {
        guard phase == .following else { return }
        if let next, progress > 0 { browser?.spaceWash.clearOnStrip(next, from: Float(progress)) }
        withAnimation(StripTurn.animation) {
            x = 0
            progress = 0
        }
        let going = to?.id
        let wasEdge = edge
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            guard self.to?.id == going, self.edge == wasEdge, self.progress == 0, phase == .following else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { self.reset() }
        }
    }

    private func reset() {
        phase = .following
        from = nil
        to = nil
        edge = false
        progress = 0
        x = 0
        dir = 0
        next = nil
    }
}

/// The strip's tabs under two fingers taking the space elsewhere: as far as
/// the fingers have gone, and fading, as the column's rows go. The next
/// space's tabs stand in their place once it comes, at once, as ⌃N brings
/// them in the strip.
struct StripPull: ViewModifier {
    let space: UUID
    @ObservedObject private var pull = SpacePull.shared

    func body(content: Content) -> some View {
        let mine = pull.from?.id == space
        content
            .offset(x: mine ? pull.x : 0)
            .modifier(StripCross(progress: pull.progress, coming: false, on: mine))
    }
}

/// A new space's pins and rows come in from the side it lies on, fading up,
/// and follow two fingers before a switch.
struct SpaceTurn: ViewModifier {
    let id: UUID
    let step: Int
    @ObservedObject var pull: SpacePull = .shared
    /// The rows come in once the space is drawn (SpaceShown), a frame after
    /// the switch laid them out: started on that frame, the curve spent its
    /// first part with nothing drawn, and the rows landed half way in. Until
    /// then they wait where the curve starts.
    @ObservedObject var shown: SpaceShown = .shared
    /// Stays where it is while the space around it comes and goes: the
    /// pins every space shares, between two spaces that show them, the
    /// one two fingers are taking it to or the one it came from.
    var holds: @MainActor (SpacePull) -> Bool = { _ in false }

    /// No motion at all, for the bench to weigh the turn against.
    @MainActor static var still = false

    /// The wash's slide, the rows' arrival, the window's color: one beat.
    static let duration: TimeInterval = 0.17
    static let pace = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    private static let reach: CGFloat = 24

    private struct Arrival {
        var x: CGFloat = 0
        var opacity: Double = 1
    }

    func body(content: Content) -> some View {
        let held = holds(pull)
        // Not after two fingers: the rows they brought are in place already.
        // Not while the row of spaces slides over the column (SpacePager):
        // what is under it is masked, and moved it moved every row of every
        // space kept there, each telling where it stands (DrawnRow, KeySky),
        // twice a switch, half the main thread's hold.
        let waiting = !held && !SpaceTurn.still && shown.id != nil && shown.id != id && !pull.landing && !SpacePager.shared.active
        content
            .offset(x: held ? 0 : pull.x)
            .modifier(StripCross(progress: pull.progress, coming: false, on: !held))
            .offset(x: waiting ? Self.reach * CGFloat(step) : 0)
            .opacity(waiting ? 0.35 : 1)
            // Held, the arrival plays on nothing: a trigger that came and
            // went with it would start one when it went.
            .keyframeAnimator(initialValue: Arrival(), trigger: SpaceTurn.still ? nil : shown.arrivals) { view, arrival in
                view.offset(x: held ? 0 : arrival.x).opacity(held ? 1 : arrival.opacity)
            } keyframes: { _ in
                let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.8), endControlPoint: UnitPoint(x: 0.2, y: 1))
                KeyframeTrack(\.x) {
                    MoveKeyframe(Self.reach * CGFloat(step))
                    LinearKeyframe(0, duration: Self.duration, timingCurve: curve)
                }
                // Never an empty column between the two rows.
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0.35)
                    LinearKeyframe(1, duration: Self.duration, timingCurve: curve)
                }
            }
    }
}
