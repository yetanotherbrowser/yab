import AppKit
import Combine
import SwiftUI
import SyncKit

// A new space, made in one tray that grows out of the + beside the space's
// dot and changes height with each step: what to
// start with, a name and the window's color and grain, an emoji or a color
// of your own, and whose sign-ins. The button at its foot never moves, the
// title says what the step sets, and the card that shows the space is one
// thing from the first letter to the end, when it leaves the tray and
// becomes the space's dot.
//
// Rare, so it may move: but all of it is Core Animation, one commit a
// change, handed to the render server (see AskView for why), and SwiftUI
// only draws what is in it. Every choice lands at once; only sizes and
// places animate.

/// What the tray is making, guessed from the name until changed by hand.
@MainActor
final class SpaceDraft: ObservableObject {
    enum Step: Int { case spaces, start, name, emoji, color, signIns }

    @Published var step: Step = .start
    @Published var name = "" { didSet { heard() } }
    @Published var icon = "🌱"
    @Published var swatch: Swatch = .gray
    @Published var custom: NSColor
    @Published var transparency: Double
    @Published var grain: Double
    @Published var colors: [String]
    /// What the look card adds: Shift with tabs, the site's color, drawings.
    @Published var shift: Bool
    @Published var site: Bool
    @Published var drawings: String
    @Published var strength: Double
    /// The window as Liquid Glass, the wave's step past its end.
    @Published var glass = false
    @Published var own = false
    /// The tab to take along, when there is one to take.
    let tab: Tab?
    var taking = false
    /// Tabs picked with it, taken along with it.
    var more: [Tab] = []
    var takenWords: String { folder?.name ?? (more.isEmpty ? "1 tab" : "\(more.count + 1) tabs") }
    /// A folder of yours taken whole, its tabs the ones above, into the new
    /// space as a folder (Browser.moveFolder).
    var folder: Nest?
    /// Came to New Space from the list of spaces, so back goes there.
    var fromSpaces = false
    /// The space the keys are on in the list, when the arrows have moved.
    @Published var focus: Int?
    /// The space whose emoji the emoji step is changing, from its menu in
    /// the list, rather than a new one's.
    var editing: UUID?
    /// Opened for that one change, from the space's name in the column:
    /// Done or back puts the tray away rather than going to the list.
    var alone = false
    /// Tabs held over the tray, from the column or the strip: the list is
    /// where they go (SpaceDrop).
    @Published var carrying: [Tab] = []
    /// The row they are over: a space's place, or -1 for New Space.
    @Published var over: Int?
    /// Tabs let go into a space, counted, so its emoji gives once.
    @Published var landed: [UUID: Int] = [:]
    /// How far the list is scrolled, for SpaceDrop to find a row under
    /// the hand. Not published: nothing is drawn from it.
    var scrolled: CGFloat = 0
    private var iconByHand = false
    private var swatchByHand = false

    /// The first emoji no space wears yet: a new one's, until its name
    /// suggests another or one is picked.
    let free: String

    init(prefs: Preferences, tab: Tab?, free: String = "🌱") {
        self.free = free
        icon = free
        custom = prefs.backdropColor
        transparency = prefs.backdropTransparency
        grain = prefs.grain
        colors = prefs.backdropColors
        shift = prefs.lookShift
        site = prefs.lookSite
        drawings = prefs.lookDrawings
        strength = prefs.lookDrawingsStrength
        glass = prefs.lookGlass
        window = SpacePaint(prefs)
        self.tab = tab
    }

    /// The window's color and grain as the tray opened.
    let window: SpacePaint

    var paint: SpacePaint {
        SpacePaint(swatch: swatch, color: custom, grain: grain, colors: colors, transparency: transparency,
                   shift: shift, site: site, drawings: drawings, drawingsStrength: strength, glass: glass)
    }

    /// The look card's controls on the draft (LookControls).
    var look: LookFields {
        LookFields(color: Binding(get: { self.custom }, set: { color in
                       self.custom = color
                       if self.swatch == .plain { self.swatch = .custom }
                   }),
                   transparency: Binding(get: { self.transparency }, set: { self.transparency = $0 }),
                   grain: Binding(get: { self.grain }, set: { self.grain = $0 }),
                   colors: Binding(get: { self.colors }, set: { self.colors = $0 }),
                   shift: Binding(get: { self.shift }, set: { self.shift = $0 }),
                   site: Binding(get: { self.site }, set: { self.site = $0 }),
                   drawings: Binding(get: { self.drawings }, set: { self.drawings = $0 }),
                   strength: Binding(get: { self.strength }, set: { self.strength = $0 }),
                   glass: WindowGlassPolicy.supported ? Binding(get: { self.glass }, set: { self.glass = $0 }) : nil,
                   plain: Binding(get: { self.swatch == .plain }, set: { on in
                       guard on else { return }
                       self.custom = NSColor(hex: Swatch.plainSeed) ?? .white
                       self.colors = []
                       self.swatch = .plain
                       self.swatchByHand = true
                   }))
    }
    var named: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    func pick(icon: String) { self.icon = icon; iconByHand = true }

    /// Back to a new space's start, after changing a space's emoji.
    func forget() {
        editing = nil
        iconByHand = false
        name = ""
    }
    func pick(swatch: Swatch) {
        // Your own starts from the color the card has now, not from one
        // picked long ago: the card keeps its color as the wheel comes up.
        if swatch == .custom, self.swatch != .custom { custom = self.swatch.color(dark: false, custom: custom) }
        self.swatch = swatch
        swatchByHand = true
    }

    /// An emoji typed first is the icon, not part of the name; otherwise
    /// the name says what it is about, and the icon and color follow it
    /// until either is picked by hand.
    private func heard() {
        if let first = name.first, Spaces.isEmoji(String(first)), first.unicodeScalars.first?.properties.isEmoji == true {
            icon = String(first)
            iconByHand = true
            name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
            return
        }
        let guess = SpaceDraft.guess(named)
        if !iconByHand { icon = guess.icon ?? free }
        if !swatchByHand { swatch = guess.swatch }
    }

    /// The emoji offered: those near the guess first.
    var emoji: [String] {
        var seen = Set<String>()
        return ([icon].filter(Spaces.isEmoji) + SpaceDraft.guess(named).more + SpaceDraft.all).filter { seen.insert($0).inserted }.prefix(35).map { $0 }
    }

    private static let guesses: [(keys: [String], icon: String, swatch: Swatch, more: [String])] = [
        (["shop", "store", "buy", "gift"], "🛍️", .rose, ["🛒", "🎁", "💳", "🧾", "🏷️"]),
        (["lab", "test", "experiment", "research"], "🧪", .sage, ["🔭", "🧠", "🧬", "📓", "⚗️"]),
        (["tax", "financ", "money", "budget", "bill", "invoice"], "💰", .peach, ["🧾", "📈", "🏦", "📊", "💳"]),
        (["travel", "trip", "flight", "vacation"], "✈️", .sky, ["🗺️", "🏝️", "🧳", "🏔️", "🚆"]),
        (["read", "book", "article"], "📚", .paper, ["📖", "🔖", "📰", "✏️", "🧠"]),
        (["music", "song", "playlist"], "🎧", .lavender, ["🎸", "🎹", "🎤", "📻", "🎶"]),
        (["design", "figma", "art"], "🎨", .coral, ["✏️", "📐", "🖌️", "🧩", "🪄"]),
        (["home", "family", "house"], "🏠", .sage, ["🪴", "🛋️", "🧺", "🔑", "🍳"]),
        (["code", "dev", "git", "eng"], "⌨️", .graphite, ["🧑‍💻", "🐛", "🚀", "🧩", "🛠️"]),
        (["client", "customer", "agency"], "🤝", .sky, ["💼", "📞", "🗂️", "📝", "📅"]),
        (["study", "learn", "school", "course"], "🎓", .sky, ["📚", "✏️", "🧠", "📓", "🗓️"]),
        (["health", "gym", "fit", "sport"], "🏋️", .sage, ["🏃", "🥗", "🧘", "💪", "🚴"]),
        (["food", "recipe", "cook"], "🍜", .peach, ["🍳", "🥐", "🍕", "☕️", "🧂"]),
        (["game"], "🎮", .coral, ["🕹️", "👾", "🎲", "🏆", "🎯"]),
        (["film", "movie", "video"], "🍿", .coral, ["🎬", "📺", "🎞️", "🎥", "⭐️"]),
        (["side", "project", "startup"], "🚀", .lavender, ["🛠️", "🧩", "💡", "📈", "🎯"]),
        (["work", "job", "office"], "💼", .lavender, ["🗂️", "📅", "📝", "📊", "🤝"]),
    ]

    /// The approved drawings keep their sync keys, even when this Mac
    /// has no system symbol with that name.
    static let symbolsOffered = SpaceSymbols.all.map(\.symbol).filter {
        SpaceIconArt.catalog[$0] != nil || NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    }

    static let all = ["🛍️", "🛒", "🎁", "🧪", "🔭", "💰", "🧾", "📈", "✈️", "🗺️", "🏝️", "📚", "🎧", "🎨", "🏠", "🪴",
                              "⌨️", "🤝", "🎓", "🏋️", "🍜", "☕️", "🎮", "🍿", "🚀", "💼", "🌱", "🧠", "📸", "🗂️", "🎯", "💌",
                              "🌊", "🧭", "💡"]

    /// The emoji and color a name suggests; no emoji when it suggests
    /// none, and the space takes the first one no space wears yet, never a
    /// fixed one that the space before may already wear.
    static func guess(_ name: String) -> (icon: String?, swatch: Swatch, more: [String]) {
        let lower = name.lowercased()
        guard !lower.isEmpty else { return (nil, .gray, []) }
        if let hit = guesses.first(where: { entry in entry.keys.contains { lower.contains($0) } }) {
            return (hit.icon, hit.swatch, hit.more)
        }
        return (nil, .gray, ["✨", "📁", "🎯", "💡", "🧭"])
    }
}

/// Where the tray grows from and what it lands on: the + and the space's
/// dot, in the column's foot or at the head of the strip.
/// Where the capsule is, for the tray to grow from and a new space's card
/// to land on. There can be more than one capsule: the column's, the
/// strip's, and the column's that floats over the page in full screen or
/// with the column put away. The anchor is whichever is in the browser's
/// window and on screen there, the one taken up last among them; asked for
/// the last one made alone, the floating column's, gone again, left none,
/// and the capsule did nothing.
@MainActor
enum SpaceAnchors {
    fileprivate static let marks = NSHashTable<SpaceAnchor.Mark>.weakObjects()

    static var plus: NSView? { anchor(.plus) }
    static var dot: NSView? { anchor(.dot) }

    /// The middle of a space's place in the foot's row, in the window.
    static func slotPoint(_ id: UUID) -> NSPoint? {
        guard let mark = marks.allObjects.first(where: { $0.kind == .slot(id) && $0.window != nil }) else { return nil }
        return mark.convert(NSPoint(x: mark.bounds.midX, y: mark.bounds.midY), to: nil)
    }

    /// The space in the foot's row under a point of the window, if any
    /// (SpaceSlot): where a tab or a folder let go there goes.
    static func slot(at point: NSPoint, in window: NSWindow) -> UUID? {
        for mark in marks.allObjects {
            guard case .slot(let id) = mark.kind, mark.window === window, !mark.isHiddenOrHasHiddenAncestor else { continue }
            if mark.convert(mark.bounds, to: nil).contains(point) { return id }
        }
        return nil
    }

    private static func anchor(_ kind: SpaceAnchor.Kind) -> NSView? {
        let window = Links.window
        let placed = marks.allObjects.filter { mark in
            guard mark.kind == kind, let at = mark.window, at === window ?? at, !mark.isHiddenOrHasHiddenAncestor,
                  let content = at.contentView else { return false }
            return content.bounds.intersects(mark.convert(mark.bounds.insetBy(dx: -1, dy: -1), to: content))
        }
        return placed.max { $0.taken < $1.taken }
    }
}

struct SpaceAnchor: NSViewRepresentable {
    enum Kind: Equatable { case plus, dot, slot(UUID) }
    let kind: Kind

    func makeNSView(context: Context) -> Mark { Mark(kind) }
    func updateNSView(_ view: Mark, context: Context) {}

    final class Mark: NSView {
        let kind: Kind
        /// When it last came into a window.
        fileprivate private(set) var taken: CFTimeInterval = 0

        init(_ kind: Kind) {
            self.kind = kind
            super.init(frame: .zero)
            MainActor.assumeIsolated { SpaceAnchors.marks.add(self) }
        }
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { taken = CACurrentMediaTime() }
        }
    }
}

// MARK: - the tray

@MainActor
final class SpaceTray: NSView {
    private(set) static weak var shown: SpaceTray?
    /// The browser, for the list's rows.
    var browserForList: Browser { browser }
    /// Mail's line over the list, once an account is in. Its place among
    /// the spaces is moved in the column's foot (Browser.turnOrder); it is
    /// never renamed or taken away with the others.
    var mailRoom: CGFloat { CGFloat(specials.count) * (Self.spaceRow + Self.spaceGap) }
    /// Mail's lines over the list, in the order two fingers go.
    var specials: [Space] { browser.turnOrder.filter { $0.id == Space.mailID } }
    /// Where the tray is, for the bench.
    var panelFrame: CGRect { panel.frame }
    /// Where the tray is drawn right now, mid-motion, for the bench.
    var drawn: [Double] {
        let p = panel.layer?.presentation()
        let b = p?.bounds ?? .zero
        return [b.width, b.height, Double(p?.cornerRadius ?? 0), Double(p?.opacity ?? 0)].map { Double($0) }
    }

    /// The capsule pressed: the spaces, and New Space among them.
    static func openSpaces(_ browser: Browser) {
        if let shown, shown.window != nil { shown.leave(); return }
        shown = nil
        open(browser, at: .spaces)
    }

    /// Change Emoji… off the space's name in the column: the tray at the
    /// emoji, for that space alone.
    static func changeEmoji(of space: Space, browser: Browser) {
        if let shown, shown.window != nil { shown.changeEmoji(of: space); return }
        shown = nil
        open(browser, at: .emoji, editing: space)
    }

    /// New Space, from a menu or the bench: the chain itself. `ownSignIns`:
    /// already chosen, for two accounts on one site (Teach.swift).
    static func open(_ browser: Browser, ownSignIns: Bool = false) {
        if ownSignIns { open(browser, at: .start, own: true) }
        else { SettingsWindow.shared.showNewSpace(for: browser) }
    }

    /// Tabs held over the capsule (SpaceDrop): the list, as where they go.
    static func openCarrying(_ browser: Browser, tabs: [Tab]) {
        guard shown == nil else { return }
        open(browser, at: .spaces, carrying: tabs)
    }

    /// New Space… from a folder's menu, or a folder let go over New Space
    /// in the tray: the chain from the name, the folder taken whole.
    static func open(_ browser: Browser, folder: Nest) {
        let own = browser.tabs(in: folder).filter(Browser.movable)
        shown?.leave()
        shown = nil
        open(browser, at: .name, tab: own.first, more: Array(own.dropFirst()), folder: folder)
    }

    /// New Space… from a tab's menu, or tabs let go over New Space in the
    /// tray: the chain from the name, those tabs taken along.
    static func open(_ browser: Browser, taking tabs: [Tab]) {
        let own = tabs.filter(Browser.movable)
        guard let first = own.first else { open(browser); return }
        shown?.leave()
        shown = nil
        open(browser, at: .name, tab: first, more: Array(own.dropFirst()))
    }

    private static func open(_ browser: Browser, at step: SpaceDraft.Step, tab taken: Tab? = nil, more: [Tab] = [], carrying: [Tab] = [], own: Bool = false,
                             editing: Space? = nil, folder: Nest? = nil) {
        // One taken out of its window without leaving, the window's view
        // made anew under it, is no tray: it doesn't stand in a new one's way.
        if shown?.window == nil { shown = nil }
        guard shown == nil, let window = Links.window, let content = window.contentView,
              let from = SpaceAnchors.plus?.window === window ? SpaceAnchors.plus : SpaceAnchors.dot else { return }
        let active = taken ?? browser.active.flatMap { $0.isBlank || $0.bench ? nil : $0 }
        let tray = SpaceTray(browser: browser, draft: SpaceDraft(prefs: browser.prefs, tab: active, free: browser.freeIcon))
        tray.draft.step = step
        if taken != nil || folder != nil {
            tray.draft.taking = true
            tray.draft.more = more
        }
        tray.draft.folder = folder
        tray.draft.carrying = carrying
        if own { tray.draft.own = true }
        if let editing {
            tray.draft.name = editing.name
            tray.draft.pick(icon: editing.icon)
            tray.draft.editing = editing.id
            tray.draft.alone = true
        }
        // Beside SwiftUI's view rather than in it: the hosting view keeps
        // its own layer's sublayers, and a view added to it never reached
        // the screen. The window's frame view takes one over it as it would.
        let frame = content.superview ?? content
        tray.frame = frame === content ? content.bounds : content.frame
        tray.autoresizingMask = [.width, .height]
        frame.addSubview(tray, positioned: .above, relativeTo: frame === content ? nil : content)
        shown = tray
        tray.arrive(from: tray.convert(from.bounds, from: from))
    }

    // Heights of the parts, and of each step: each step its own, so a
    // change of step is seen as a change of height.
    static let head: CGFloat = 48
    static let foot: CGFloat = ButtonSize.large.height + 2 * CardFrame.inset
    private static let row: CGFloat = 60
    private static let strip: CGFloat = 36
    private static let card: CGFloat = 88
    /// Measure the shared picker rather than maintaining a second grid layout.
    private static let pickerSize = NSHostingView(rootView:
        IconPicker(mark: "star.fill", space: [], pick: { _ in }, close: {})
    ).fittingSize

    static let spaceRow: CGFloat = 36
    /// Between two rows of the list, New Space's included: one list, so
    /// New Space never reads as set apart from the spaces.
    static let spaceGap: CGFloat = 4

    /// The list is a menu, its rows close to the edge on the bar's curve,
    /// as the find bar's; the steps that ask are cards, the card's inset
    /// and curve. Either way a row's corner is concentric with the tray's.
    static func edge(_ step: SpaceDraft.Step) -> CGFloat { step == .spaces ? BarFrame.inset : CardFrame.inset }
    static func corner(_ step: SpaceDraft.Step) -> CGFloat { step == .spaces ? Radius.floating : Radius.card }

    private func height(_ step: SpaceDraft.Step) -> CGFloat {
        let i = CardFrame.inset
        switch step {
        case .spaces:
            let n = CGFloat(browser.spaces.count)
            let whole = Self.head + mailRoom + n * Self.spaceRow + (n - 1) * Self.spaceGap + Self.spaceGap + Self.spaceRow + Self.edge(.spaces)
            return min(whole, ceiling)
        case .start: return Self.head + (draft.tab == nil ? Self.row : 2 * Self.row + 8) + i
        case .name: return Self.head + Self.card + 10 + 30 + i + Self.foot
        case .emoji: return Self.head + Self.pickerSize.height + i
        // The look card's controls, as tall as they lay out: a second color
        // brings Shift with tabs, drawings their strength (refitLook).
        case .color: return Self.head + Self.strip + 10 + lookHeight + i + Self.foot
        case .signIns: return Self.head + Self.strip + 10 + 2 * Self.row + 8 + i + Self.foot
        }
    }

    private var inner: CGFloat { width - 2 * CardFrame.inset }
    /// The tallest the tray may be: 60 short of the window's edge it grows
    /// toward; past that the list of spaces scrolls inside it.
    private var ceiling: CGFloat {
        down ? bounds.height - origin.maxY - 8 - 60 : origin.minY - 8 - 60
    }
    /// How tall the list of spaces may be inside the tray.
    var listHeight: CGFloat { max(Self.spaceRow, height(.spaces) - Self.head - mailRoom - Self.spaceGap - Self.spaceRow - Self.edge(.spaces)) }
    var wheelSide: CGFloat { min(inner, 220) }

    /// The color step's controls laid out for the draft as it is now.
    private var lookHeight: CGFloat {
        NSHostingView(rootView: TrayLook(draft: draft, width: wheelSide).fixedSize(horizontal: false, vertical: true)).fittingSize.height
    }

    /// The color step's controls changed height (a color added, drawings
    /// picked): the tray grows or shrinks to them from its foot, as a step
    /// change reshapes it.
    func refitLook() {
        let step = draft.step
        guard step == .color, !busy, !gone, window != nil else { return }
        let from = panel.frame, to = rect(step)
        guard abs(to.height - from.height) > 0.5 else { return }
        let duration: CFTimeInterval = to.height > from.height ? 0.3 : 0.24
        let radius = (Self.corner(step), Self.corner(step))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.frame = to
        shade.frame = to
        foot.frame = CGRect(x: 0, y: to.height - Self.foot, width: to.width, height: Self.foot)
        body_?.frame = bodyFrame(to.height)
        grow(panel, from: from, to: to, radius: radius, duration: duration, set: false)
        grow(shade, from: from, to: to, radius: radius, duration: duration, set: false)
        slide(foot, fromY: from.height - Self.foot, toY: to.height - Self.foot, duration: duration)
        CATransaction.commit()
    }

    private let browser: Browser
    let draft: SpaceDraft
    private let scrim = CALayer()
    /// The tray's shadow, cast by a layer of its own with a path: the tray
    /// clips what is in it, and a shadow on a clipping layer is cut off.
    private let shade = CALayer()
    private let panel = Panel()
    private var head: NSHostingView<TrayHead>!
    private var foot: NSHostingView<TrayFoot>!
    private var body_: NSView?
    private var origin: CGRect = .zero
    /// Growing up from the column's foot, or down from the head of the strip.
    private var down = false
    private var width: CGFloat = 216
    private var busy = false
    /// Put away, and only its motion left on screen.
    private var gone = false
    /// The window wears the new space's look while it is picked (preview).
    private var previewing = false
    private var making = false
    private var watch: AnyCancellable?

    private final class Panel: NSView {
        override var isFlipped: Bool { true }
    }

    override var isFlipped: Bool { true }

    init(browser: Browser, draft: SpaceDraft) {
        self.browser = browser
        self.draft = draft
        super.init(frame: .zero)
        // After each change has landed: objectWillChange comes before it.
        watch = draft.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.preview() }
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.isGeometryFlipped = true
        scrim.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        scrim.opacity = 0
        scrim.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(scrim)
        shade.shadowColor = NSColor.black.cgColor
        shade.shadowOpacity = 0.16
        shade.shadowRadius = 17
        shade.shadowOffset = CGSize(width: 0, height: 8)
        shade.actions = ["shadowPath": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shade)

        panel.wantsLayer = true
        panel.layer?.isGeometryFlipped = true
        panel.layer?.masksToBounds = true
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 1
        addSubview(panel)

        head = NSHostingView(rootView: TrayHead(draft: draft, back: { [weak self] in self?.back() }, close: { [weak self] in self?.leave() }))
        foot = NSHostingView(rootView: TrayFoot(draft: draft, press: { [weak self] in self?.forward() }))
        head.sizingOptions = []
        foot.sizingOptions = []
        panel.addSubview(head)
        panel.addSubview(foot)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = bounds
        CATransaction.commit()
    }

    /// The tray takes its own clicks; anywhere else puts it away.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Going: the window's clicks are the window's again at once.
        if gone { return nil }
        let local = convert(point, from: superview)
        if panel.frame.contains(local) {
            // The foot stays in the panel on the steps without a button,
            // only faded out, and AppKit hits a view whatever its alpha: it
            // sat over New Space and the start's choices and took their
            // clicks. There, what is under it is hit instead.
            // (hitTest takes a point in the superview's space: the panel's.)
            let inPanel = panel.convert(local, from: self)
            if !footed(draft.step), foot.frame.contains(inPanel) {
                return body_?.hitTest(inPanel) ?? panel
            }
            return super.hitTest(point)
        }
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { leave() }

    /// Esc: a step back, and from the first, away. Return: the button at
    /// the foot. The field has its own Return, and Esc comes here from it.
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { back() }
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if draft.step == .spaces {
            let n = browser.spaces.count
            let here = draft.focus ?? browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0
            if Keymap.shared.matches(event, .spaceDelete) {
                if browser.spaces.indices.contains(here) { askDelete(browser.spaces[here]) }
                return
            }
            if plain {
                switch event.keyCode {
                case 125: draft.focus = min(n - 1, here + 1); return
                case 126: draft.focus = max(0, here - 1); return
                case 36, 76:
                    if browser.spaces.indices.contains(here) { pick(browser.spaces[here].id) }
                    return
                default: break
                }
            }
        }
        if plain {
            switch event.keyCode {
            case 53: back()
            case 36, 76: forward()
            default: super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }

    /// Whatever had the keys before, given them back when the tray goes.
    private weak var before: NSResponder?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintColors()
    }

    private func paintColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            panel.layer?.backgroundColor = Palette.NS.ground.cgColor
            panel.layer?.borderColor = Palette.NS.hairline.cgColor
        }
    }

    // MARK: where

    private func rect(_ step: SpaceDraft.Step) -> CGRect {
        let h = height(step)
        let width = stepWidth(step)
        if down {
            return CGRect(x: min(max(8, origin.minX - 8), bounds.width - width - 8), y: origin.maxY + 8, width: width, height: h)
        }
        // Up from the column's foot: over the column, on whichever side it is.
        let x = browser.flank == .right ? bounds.width - width - 8 : 8
        return CGRect(x: x, y: origin.minY - 8 - h, width: width, height: h)
    }

    private func place(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.frame = frame
        panel.layer?.cornerRadius = Self.corner(draft.step)
        shade.frame = frame
        shade.shadowPath = Self.outline(frame.size, Self.corner(draft.step))
        head.frame = CGRect(x: 0, y: 0, width: frame.width, height: Self.head)
        foot.frame = CGRect(x: 0, y: frame.height - Self.foot, width: frame.width, height: Self.foot)
        body_?.frame = bodyFrame(frame.height)
        CATransaction.commit()
    }

    private func stepWidth(_ step: SpaceDraft.Step) -> CGFloat {
        step == .emoji ? max(width, Self.pickerSize.width + 2 * CardFrame.inset) : width
    }

    private func bodyFrame(_ h: CGFloat) -> CGRect {
        CGRect(x: 0, y: Self.head, width: stepWidth(draft.step), height: max(0, h - Self.head))
    }

    // MARK: coming and going

    private func arrive(from plus: CGRect) {
        paintColors()
        before = window?.firstResponder
        window?.makeFirstResponder(self)
        origin = plus
        down = plus.midY < bounds.height / 3
        let side = browser.prefs.sidebar && !down
        width = side ? max(200, browser.prefs.sideWidth - 16) : 216
        if draft.step == .start, draft.tab == nil { draft.step = .name }
        let to = rect(draft.step)
        show(draft.step, fading: false)
        place(to)
        foot.alphaValue = footed(draft.step) ? 1 : 0
        busy = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { self.busy = false; self.settled() } }
        grow(panel, from: plus, to: to, radius: (Radius.control, Self.corner(draft.step)), duration: 0.26)
        grow(shade, from: plus, to: to, radius: (Radius.control, Self.corner(draft.step)), duration: 0.26)
        slide(foot, fromY: plus.height - Self.foot, toY: to.height - Self.foot, duration: 0.26)
        // What is in it comes in as it grows; the foot only on a step
        // that has a button.
        let shown = [head, body_] + (footed(draft.step) ? [foot] : [])
        dissolve(shown.compactMap { $0?.layer }, from: 0, to: 1, duration: 0.14, delay: 0.04)
        scrim.opacity = 1
        Self.run(scrim, "opacity", from: 0, to: 1, duration: 0.22, timing: .linear)
        CATransaction.commit()
        done(after: 0.3) { self.busy = false }
    }

    /// While a new space's color and grain are picked, and after, on its
    /// sign-ins, the window wears them over its own, as Arc's does: the look
    /// is judged on the window, not on a strip. Back to the name, or the tray
    /// put away, the window's own comes back; made, the space's is worn.
    private func preview() {
        guard !gone else { return }
        guard draft.editing == nil, draft.step == .color || draft.step == .signIns,
              let paint = SpaceWash.worn(draft.paint, prefs: browser.prefs)
        else { unpreview(); return }
        if previewing {
            browser.spaceWash.show(paint, opacity: 1)
        } else {
            previewing = true
            browser.spaceWash.show(paint, opacity: 0)
            browser.spaceWash.fill(from: 0, duration: 0.2)
        }
    }

    private func unpreview() {
        guard previewing else { return }
        previewing = false
        browser.spaceWash.clear(from: 1, duration: 0.2)
    }

    /// Back into the + the way it came, quicker.
    func leave() {
        guard window != nil, Self.shown === self else { return }
        Self.shown = nil
        if !making { unpreview() }
        if let before, before !== self { window?.makeFirstResponder(before) } else { window?.makeFirstResponder(nil) }
        gone = true
        let from = panel.frame
        let to = origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown(latest: 1.2) { self.removeFromSuperview() }
        panel.frame = to
        shade.opacity = 0
        scrim.opacity = 0
        // Only what is showing: the foot, hidden on the list, faded from 1
        // flashed its Continue as the tray went.
        for layer in panel.subviews.compactMap(\.layer) where layer.opacity > 0 {
            dissolve([layer], from: layer.opacity, to: 0, duration: 0.09)
        }
        grow(panel, from: from, to: to, radius: (Self.corner(draft.step), Radius.control), duration: Self.departure, timing: Reshape.Pace.depart.timing, set: false)
        // Gone at the end whenever it is taken away: after a new space the
        // main thread may be busy with its row for a while.
        panel.layer?.opacity = 0
        let out = CAKeyframeAnimation(keyPath: "opacity")
        out.values = [1, 0.6, 0]
        out.keyTimes = [0, 0.7, 1]
        out.duration = 0.17
        panel.layer?.add(out, forKey: "tray.opacity")
        Self.run(scrim, "opacity", from: 1, to: 0, duration: 0.18, timing: .linear)
        CATransaction.commit()
    }

    // MARK: steps

    /// The steps with the button at their foot: all but the list and the
    /// choice, where the rows are the buttons.
    private func footed(_ step: SpaceDraft.Step) -> Bool { step != .spaces && step != .start && step != .emoji }

    func back() {
        guard !busy else { return }
        switch draft.step {
        case .spaces: leave()
        case .start: draft.fromSpaces ? go(.spaces) : leave()
        case .name:
            if draft.tab != nil { go(.start) } else if draft.fromSpaces { go(.spaces) } else { leave() }
        case .emoji where draft.editing != nil:
            if draft.alone { leave(); return }
            draft.forget()
            go(.spaces)
        case .emoji, .color: go(.name)
        case .signIns: go(.color)
        }
    }

    /// A space picked in the list: the tray goes back into the capsule, and
    /// the space comes on screen in the same beat, its name into the capsule.
    func pick(_ id: UUID) {
        guard !busy else { return }
        leave()
        guard id != browser.spaceID else { return }
        CATransaction.flush()
        let browser = browser
        DispatchQueue.main.async { browser.switchSpace(to: id) }
    }

    /// New Space in the list: the same tray goes on into the chain.
    func startNew() {
        if draft.tab == nil, draft.more.isEmpty, draft.folder == nil {
            leave()
            SettingsWindow.shared.showNewSpace(for: browser)
            return
        }
        draft.fromSpaces = true
        go(draft.tab == nil ? .name : .start)
    }

    /// The button at the foot, Return, or a choice that moves on.
    func forward() {
        guard !busy else { return }
        switch draft.step {
        case .spaces: break
        case .start: go(.name)
        case .name: if !draft.named.isEmpty { go(.color) }
        case .emoji: pickedEmoji()
        case .color: go(.signIns)
        case .signIns: make()
        }
    }

    // MARK: tabs held over it

    /// The row under a point in the window: a space's place, -1 for New
    /// Space, nil between rows; nil too, and `false`, once the point is
    /// past the tray's edge by more than SpaceDrop.reach.
    func dropTarget(at point: NSPoint) -> Int?? {
        guard draft.step == .spaces, !gone else { return .none }
        let p = convert(point, from: nil)
        let frame = panel.frame
        guard frame.insetBy(dx: -SpaceDrop.reach, dy: -SpaceDrop.reach).contains(p) else { return .none }
        let x = p.x - frame.minX, y = p.y - frame.minY
        let edge = Self.edge(.spaces)
        guard x >= edge, x <= frame.width - edge else { return .some(nil) }
        let list = Self.head + mailRoom
        let pitch = Self.spaceRow + Self.spaceGap
        if y >= list, y < list + listHeight {
            let at = Int(((y - list + draft.scrolled) / pitch).rounded(.down))
            let within = (y - list + draft.scrolled) - CGFloat(at) * pitch < Self.spaceRow
            return .some(browser.spaces.indices.contains(at) && within ? at : nil)
        }
        let plus = list + listHeight + Self.spaceGap
        if y >= plus, y < plus + Self.spaceRow { return .some(-1) }
        return .some(nil)
    }

    /// The middle of a row in the window, for the bench: a space's place,
    /// or -1 for New Space.
    func rowPoint(_ index: Int) -> NSPoint {
        let frame = panel.frame
        let y = index < 0
            ? Self.head + mailRoom + listHeight + Self.spaceGap + Self.spaceRow / 2
            : Self.head + mailRoom + CGFloat(index) * (Self.spaceRow + Self.spaceGap) - draft.scrolled + Self.spaceRow / 2
        return convert(NSPoint(x: frame.midX, y: frame.minY + y), to: nil)
    }

    // MARK: deleting

    /// Delete… from a row's menu, or ⌘⌫ on the arrows' row. Nothing to
    /// lose, no tabs and sign-ins shared, and the row folds away at once.
    /// Otherwise yab's own question asks, in the middle of the page, as
    /// every question that can't be taken back does: the tray goes first,
    /// since the question stands under it.
    func askDelete(_ space: Space) {
        guard !busy, browser.canDeleteSpace(space.id), draft.step == .spaces else { return }
        if !space.ownSignIns, browser.pageCount(in: space.id) == 0 {
            fold(space.id)
            return
        }
        // The tray back into the capsule first, then the question, as every
        // question of yab's comes: one thing moving at a time, and one
        // dimming, not the tray's going out under the question's coming in.
        leave()
        let browser = browser
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.departure) {
            SpaceTray.confirmDelete(space, browser: browser)
        }
    }

    /// yab's question for deleting a space: what goes with it, Delete in
    /// red and ⌘Return.
    static func confirmDelete(_ space: Space, browser: Browser) {
        let question = deletion(space, browser: browser, place: .page)
        Task { @MainActor in
            if await Questions.shared.ask(question) { browser.deleteSpace(space.id, undoable: true) }
        }
    }

    /// Changing whose sign-ins a space has signs it in or out of everything
    /// and opens its tabs again: asked first, the same from its menu and its
    /// page in Settings. True once it is changed.
    static func askSignIns(_ space: Space, own: Bool, browser: Browser, place: Question.Place) async -> Bool {
        guard !space.isFirst, space.ownSignIns != own else { return false }
        let question = own
            ? Question(title: "Give \(space.name) its own sign-ins?",
                       detail: "It starts signed out of every site, with no extensions, and its tabs open again.",
                       glyph: "person.key", space: space.well(browser.prefs), yes: "Use Its Own", place: place)
            : Question(title: "Share sign-ins with \(space.name)?",
                       detail: "It is signed in wherever your other spaces are, with their extensions. Its own sign-ins and extensions are erased from this Mac, and its tabs open again.",
                       glyph: "person.key", space: space.well(browser.prefs), yes: "Share", danger: true, place: place)
        guard await Questions.shared.ask(question) else { return false }
        browser.setSpaceSignIns(space.id, own: own)
        return true
    }

    /// The question itself, the same from the tray, a space's menu and its
    /// page in Settings: its emoji on its color with the trash in its corner.
    static func deletion(_ space: Space, browser: Browser, place: Question.Place) -> Question {
        Question(title: "Delete \(space.name)?", detail: goesWith(space, browser: browser), glyph: "trash",
                 space: space.well(browser.prefs), yes: "Delete", danger: true, place: place)
    }

    /// What goes with a space deleted: its tabs, and its own sign-ins.
    /// Empty when nothing does.
    static func goesWith(_ space: Space, browser: Browser) -> String {
        let count = browser.pageCount(in: space.id)
        let shortcut = Keymap.shared.text(.reopen)
        let restore = shortcut.isEmpty ? "It can be restored from History." : "\(shortcut) brings it back."
        let tabs = count == 0 ? "" : count == 1 ? "Its tab closes; \(restore)" : "Its \(count) tabs close; \(restore)"
        let together = browser.spaces.contains { $0.id != space.id && $0.ownSignIns && Spaces.signIn(of: $0.id) == Spaces.signIn(of: space.id) }
        return [tabs, space.ownSignIns && !together ? "Its sign-ins and extensions are erased from this Mac." : ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Deleted from the list: the row folds away, those under it come up,
    /// and the tray is that much shorter, in one beat.
    func fold(_ id: UUID) {
        let browser = browser
        withAnimation(Self.foldPace) {
            draft.focus = nil
            browser.deleteSpace(id, undoable: true)
        }
        refit()
    }

    /// The tray going back into the capsule.
    static let departure: CFTimeInterval = 0.17

    static let foldPace = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)

    /// The list's step made its new height, what is in it laid out at once
    /// and the tray's edge going to meet it.
    private func refit() {
        guard draft.step == .spaces else { return }
        let from = panel.frame
        let to = rect(.spaces)
        guard from != to else { return }
        let duration: CFTimeInterval = 0.24
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.frame = to
        shade.frame = to
        foot.frame = CGRect(x: 0, y: to.height - Self.foot, width: to.width, height: Self.foot)
        body_?.frame = bodyFrame(to.height)
        let corner = Self.corner(.spaces)
        grow(panel, from: from, to: to, radius: (corner, corner), duration: duration, set: false)
        grow(shade, from: from, to: to, radius: (corner, corner), duration: duration, set: false)
        // The list's own top stays where it was on screen while the tray
        // moves past it: the body is pinned to the tray's top, which moves.
        if let layer = body_?.layer {
            let shift = CABasicAnimation(keyPath: "transform")
            shift.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, from.minY - to.minY, 0))
            shift.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            shift.duration = duration
            shift.timingFunction = Reshape.Pace.reshape.timing
            layer.add(shift, forKey: "tray.refit")
        }
        CATransaction.commit()
    }

    /// A space's emoji to change, from its menu in the list: the same grid
    /// as a new space's, and back to the list.
    func changeEmoji(of space: Space) {
        guard !busy else { return }
        draft.name = space.name
        draft.pick(icon: space.icon)
        draft.editing = space.id
        go(.emoji)
    }

    /// An emoji picked: on to the name of a new space, or worn by the space
    /// being changed at once, and back to the list.
    func pickedEmoji() {
        guard let id = draft.editing else { go(.name); return }
        browser.setSpaceIcon(id, to: draft.icon)
        if draft.alone { leave(); return }
        draft.forget()
        go(.spaces)
    }

    func take(_ taking: Bool) {
        draft.taking = taking
        go(.name)
    }

    func go(_ step: SpaceDraft.Step) {
        guard !busy, step != draft.step else { return }
        // The color step turns the color the card has now, as your own.
        if step == .color, draft.swatch != .custom, draft.swatch != .plain { draft.pick(swatch: .custom) }
        let was = draft.step
        let old = body_
        let from = panel.frame
        // Pictures of the head and the foot as they are, taken before the
        // step changes: SwiftUI draws the next step's words the moment it
        // is asked to draw.
        let heads = picture(of: head)
        let feet = footed(was) && footed(step) ? picture(of: foot) : nil
        draft.step = step
        let to = rect(step)
        let up = to.height > from.height
        let duration: CFTimeInterval = up ? 0.3 : 0.24
        busy = true
        show(step, fading: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown(latest: duration + 1) { old?.removeFromSuperview() }
        crossfade(head, from: heads)
        if let feet { crossfade(foot, from: feet) }
        panel.frame = to
        shade.frame = to
        head.frame.size.width = to.width
        foot.frame = CGRect(x: 0, y: to.height - Self.foot, width: to.width, height: Self.foot)
        body_?.frame = bodyFrame(to.height)
        let radius = (Self.corner(was), Self.corner(step))
        grow(panel, from: from, to: to, radius: radius, duration: duration, set: false)
        grow(shade, from: from, to: to, radius: radius, duration: duration, set: false)
        slide(foot, fromY: from.height - Self.foot, toY: to.height - Self.foot, duration: duration)
        // The foot's button comes with the first step that has one, and
        // goes with the step that has none.
        let footed = footed(step)
        if footed != self.footed(was) {
            foot.alphaValue = footed ? 1 : 0
            dissolve([foot.layer].compactMap { $0 }, from: footed ? 0 : 1, to: footed ? 1 : 0, duration: footed ? 0.2 : 0.12, delay: footed ? 0.08 : 0)
        }
        // The old step out as the new one comes in over it, never an empty
        // tray between them; the new one from 8 points lower.
        // The old step gone in a few frames, before the new one is more than
        // a hint: two lists of words at half strength over each other read
        // as neither.
        if let old, let layer = old.layer {
            layer.opacity = 0
            Self.run(layer, "opacity", from: 1, to: 0, duration: 0.08, timing: Reshape.Pace.depart.timing)
        }
        if let layer = body_?.layer {
            Self.run(layer, "opacity", from: 0, to: 1, duration: 0.22, timing: Reshape.Pace.reshape.timing, delay: 0.07)
            let shift = CABasicAnimation(keyPath: "transform")
            shift.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 8, 0))
            shift.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            shift.duration = 0.24
            shift.beginTime = CACurrentMediaTime() + 0.07
            shift.fillMode = .backwards
            shift.timingFunction = Reshape.Pace.reshape.timing
            layer.add(shift, forKey: "tray.shift")
        }
        // Into the color step the card shrinks into the strip at its top,
        // and back out of it: the same card (ex-18).
        if let old, (was == .name && step == .color) || (was == .color && step == .name) {
            shrink(from: old, big: was == .name, duration: 0.3)
        }
        CATransaction.commit()
        done(after: duration + 0.02) {
            self.busy = false
            self.settled()
        }
    }

    /// A view as it is drawn now, as a layer to lay over it.
    private func picture(of view: NSView) -> CALayer? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        let layer = CALayer()
        layer.contents = image
        // Drawn to its frame, whatever the screen's scale: left to the
        // picture's own size, a Retina capture came out twice as large.
        layer.contentsGravity = .resize
        layer.frame = view.frame
        return layer
    }

    /// Words changed in place: the picture of the old ones gone in a few
    /// frames, the new ones in over the step's beat, as the body does.
    private func crossfade(_ view: NSView, from picture: CALayer?) {
        if let picture, let panel = panel.layer {
            picture.frame = view.frame
            picture.opacity = 0
            panel.addSublayer(picture)
            Self.run(picture, "opacity", from: 1, to: 0, duration: 0.08, timing: Reshape.Pace.depart.timing)
            done(after: 0.3) { picture.removeFromSuperlayer() }
        }
        guard let layer = view.layer else { return }
        Self.run(layer, "opacity", from: 0, to: layer.opacity, duration: 0.22, timing: Reshape.Pace.reshape.timing, delay: 0.07)
    }

    /// The step's own view, over the one before until that one is gone.
    private func show(_ step: SpaceDraft.Step, fading: Bool) {
        let view = NSHostingView(rootView: TrayStep(draft: draft, step: step, width: stepWidth(step), wheel: wheelSide, tray: self))
        view.sizingOptions = []
        view.wantsLayer = true
        panel.addSubview(view, positioned: .below, relativeTo: head)
        body_ = view
        view.frame = bodyFrame(height(step))
    }

    /// After a step has come in: the name field, or the icon step's search,
    /// takes the keys only now, once nothing moves, since the text field
    /// going first responder puts up macOS's input indicator, a window that
    /// holds up the commits.
    private func settled() {
        guard draft.step == .name || draft.step == .emoji else {
            window?.makeFirstResponder(self)
            return
        }
        guard Self.focusing else { return }
        DispatchQueue.main.async { [weak self] in self?.focusName?() }
    }

    /// Off only for the bench, to weigh what the field taking the keys costs.
    static var focusing = true

    /// Set by the name step's field and the icon step's search.
    var focusName: (() -> Void)?

    // MARK: making it

    /// The strip at the top of the last step leaves the tray and becomes
    /// the space's dot; the tray goes back into the +, and the window
    /// takes the space's color as its row comes on screen.
    private func make() {
        guard !draft.named.isEmpty, let body = body_ else { return }
        busy = true
        making = true
        let strip = CGRect(x: panel.frame.minX + CardFrame.inset, y: panel.frame.minY + Self.head, width: inner, height: Self.strip)
        let look = draft.paint.color(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let flight = CALayer()
        flight.frame = strip
        flight.backgroundColor = look.cgColor
        flight.cornerRadius = Radius.control
        flight.cornerCurve = .continuous
        let mark = CATextLayer()
        mark.string = draft.icon
        mark.fontSize = 16
        mark.alignmentMode = .center
        mark.contentsScale = window?.backingScaleFactor ?? 2
        mark.frame = CGRect(x: 8, y: (Self.strip - 20) / 2, width: 20, height: 20)
        flight.addSublayer(mark)
        layer?.addSublayer(flight)
        body.alphaValue = 0

        // The dot it lands on stays where it is as the space changes, so the
        // flight and the tray going start in this commit, and the space is
        // made on the next turn: its row can hold the main thread, and the
        // tray should never wait on it.
        let landing = SpaceAnchors.dot
        let dot = landing.map { convert($0.bounds, from: $0) } ?? origin
        let target = dot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown(latest: 1.4) { flight.removeFromSuperlayer() }
        flight.frame = target
        flight.opacity = 0
        mark.frame = CGRect(x: CapsulePlan.inset - 3, y: (target.height - 20) / 2, width: 20, height: 20)
        let pace = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        Self.run(flight, "position", from: NSValue(point: CGPoint(x: strip.midX, y: strip.midY)), to: NSValue(point: CGPoint(x: target.midX, y: target.midY)), duration: 0.36, timing: pace)
        Self.run(flight, "bounds", from: NSValue(rect: CGRect(origin: .zero, size: strip.size)), to: NSValue(rect: CGRect(origin: .zero, size: target.size)), duration: 0.36, timing: pace)
        Self.run(mark, "position", from: NSValue(point: CGPoint(x: 18, y: Self.strip / 2)), to: NSValue(point: CGPoint(x: CapsulePlan.inset + 7, y: target.height / 2)), duration: 0.36, timing: pace)
        let hold = CAKeyframeAnimation(keyPath: "opacity")
        hold.values = [1, 1, 0]
        hold.keyTimes = [0, 0.8, 1]
        hold.duration = 0.4
        flight.add(hold, forKey: "tray.hold")
        CATransaction.commit()
        leave()
        // Sent to the render server now: blocks on the main queue run before
        // Core Animation's own commit at the end of this turn, and the new
        // space's row would have held all of it back.
        CATransaction.flush()

        let (browser, draft, washed) = (browser, draft, previewing)
        previewing = false
        let taking = draft.taking ? [draft.tab].compactMap { $0 } + draft.more : []
        DispatchQueue.main.async {
            // The window already wears its look: worn under the preview, which
            // then goes, with nothing to cross.
            if !draft.colors.isEmpty { browser.prefs.backdrop = .color }
            if let folder = draft.folder {
                // Made, the folder sent there whole, then shown.
                let made = browser.addSpace(named: draft.named, icon: draft.icon, ownSignIns: draft.own, paint: draft.paint, show: false)
                browser.moveFolder(folder, to: made, say: false, ask: false, hand: true)
                browser.switchSpace(to: made, washed: washed)
            } else {
                browser.addSpace(named: draft.named, icon: draft.icon, ownSignIns: draft.own, paint: draft.paint, taking: taking, washed: washed)
            }
            if washed { browser.spaceWash.hide() }
        }
    }

    // MARK: motion

    /// A surface from one frame to another: its size, its place, and its
    /// corner if asked. Set to the end first unless told otherwise.
    private func grow(_ view: NSView, from: CGRect, to: CGRect, radius: (CGFloat, CGFloat)?, duration: CFTimeInterval,
                      timing: CAMediaTimingFunction = Reshape.Pace.reshape.timing, set: Bool = true) {
        guard let layer = view.layer else { return }
        let p0 = position(of: view, at: from), p1 = position(of: view, at: to)
        Self.run(layer, "position", from: NSValue(point: p0), to: NSValue(point: p1), duration: duration, timing: timing)
        Self.run(layer, "bounds", from: NSValue(rect: CGRect(origin: .zero, size: from.size)), to: NSValue(rect: CGRect(origin: .zero, size: to.size)), duration: duration, timing: timing)
        if let radius {
            layer.cornerRadius = radius.1
            Self.run(layer, "cornerRadius", from: radius.0, to: radius.1, duration: duration, timing: timing)
        }
    }

    /// Where AppKit puts a view's layer for a frame: its anchor and which
    /// way up its superlayer is are AppKit's to decide.
    private func position(of view: NSView, at frame: CGRect) -> CGPoint {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let kept = view.frame
        view.frame = frame
        let point = view.layer?.position ?? .zero
        view.frame = kept
        CATransaction.commit()
        return point
    }

    private func grow(_ layer: CALayer, from: CGRect, to: CGRect, radius: (CGFloat, CGFloat)?, duration: CFTimeInterval,
                      timing: CAMediaTimingFunction = Reshape.Pace.reshape.timing, set: Bool = true, anchor: CGPoint? = nil) {
        let a = anchor ?? layer.anchorPoint
        func point(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX + a.x * r.width, y: r.minY + a.y * r.height) }
        Self.run(layer, "position", from: NSValue(point: point(from)), to: NSValue(point: point(to)), duration: duration, timing: timing)
        Self.run(layer, "bounds", from: NSValue(rect: CGRect(origin: .zero, size: from.size)), to: NSValue(rect: CGRect(origin: .zero, size: to.size)), duration: duration, timing: timing)
        guard let radius else { return }
        // The shadow's outline is a path, which the bounds don't carry: it
        // goes with them, or the whole shadow stood at the end at once.
        if layer === shade {
            let end = Self.outline(to.size, radius.1)
            layer.shadowPath = end
            Self.run(layer, "shadowPath", from: Self.outline(from.size, radius.0), to: end, duration: duration, timing: timing)
        } else {
            layer.cornerRadius = radius.1
            Self.run(layer, "cornerRadius", from: radius.0, to: radius.1, duration: duration, timing: timing)
        }
    }

    private static func outline(_ size: CGSize, _ corner: CGFloat) -> CGPath {
        CGPath.rounded(CGRect(origin: .zero, size: size), corner: corner)
    }

    /// The foot kept on the tray's moving edge.
    private func slide(_ view: NSView, fromY: CGFloat, toY: CGFloat, duration: CFTimeInterval) {
        guard let layer = view.layer else { return }
        var from = view.frame, to = view.frame
        from.origin.y = fromY
        to.origin.y = toY
        Self.run(layer, "position", from: NSValue(point: position(of: view, at: from)), to: NSValue(point: position(of: view, at: to)), duration: duration, timing: Reshape.Pace.reshape.timing)
    }

    /// The card of the name step into the strip of the color step, or the
    /// strip out into the card: a picture of the one leaving, carried to
    /// where the other is.
    private func shrink(from old: NSView, big: Bool, duration: CFTimeInterval) {
        let cardRect = CGRect(x: CardFrame.inset, y: 0, width: inner, height: big ? Self.card : Self.strip)
        let endRect = CGRect(x: CardFrame.inset, y: 0, width: inner, height: big ? Self.strip : Self.card)
        guard let rep = old.bitmapImageRepForCachingDisplay(in: cardRect) else { return }
        old.cacheDisplay(in: cardRect, to: rep)
        let image = NSImage(size: cardRect.size)
        image.addRepresentation(rep)
        let picture = CALayer()
        picture.contents = image
        picture.contentsGravity = .resize
        picture.cornerRadius = Radius.control
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        let inPanel = cardRect.offsetBy(dx: 0, dy: Self.head)
        let endPanel = endRect.offsetBy(dx: 0, dy: Self.head)
        CATransaction.begin()
        shown(latest: duration + 1) { picture.removeFromSuperlayer() }
        picture.frame = endPanel
        picture.opacity = 0
        panel.layer?.addSublayer(picture)
        grow(picture, from: inPanel, to: endPanel, radius: nil, duration: duration, timing: CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.7, 1]
        fade.duration = duration
        picture.add(fade, forKey: "tray.fade")
        CATransaction.commit()
    }

    private func dissolve(_ layers: [CALayer], from: Float, to: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        for layer in layers {
            layer.opacity = to
            Self.run(layer, "opacity", from: from, to: to, duration: duration, timing: .linear, delay: delay)
        }
    }

    private static func run(_ layer: CALayer?, _ key: String, from: Any, to: Any, duration: CFTimeInterval,
                            timing: CAMediaTimingFunction, delay: CFTimeInterval = 0) {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: "tray." + key)
    }

    /// Runs once the motion is over, whether or not the render server said
    /// so: its completion can wait on a busy window server; the tray doesn't.
    private func done(after seconds: CFTimeInterval, _ then: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: then)
    }

    /// Runs once the motion of the transaction open now has played on
    /// screen, or at `latest` if the render server never says. Called
    /// before the transaction's animations are added. What takes a layer
    /// away waits for this, not for the main thread's clock: a window server
    /// running a few hundred milliseconds behind was sent the removal with
    /// the motion, and the tray went at once.
    private func shown(latest: CFTimeInterval, _ then: @escaping () -> Void) {
        let once = Once(then)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { once.run() } }
        done(after: latest) { once.run() }
    }

    private final class Once {
        private var then: (() -> Void)?
        init(_ then: @escaping () -> Void) { self.then = then }
        func run() {
            let now = then
            then = nil
            now?()
        }
    }
}

private extension CAMediaTimingFunction {
    static let linear = CAMediaTimingFunction(name: .linear)
}

// MARK: - what is in it

/// The tray's title, what the step sets, and its two doors.
struct TrayHead: View {
    @ObservedObject var draft: SpaceDraft
    let back: () -> Void
    let close: () -> Void

    /// A step behind: none on the list, nor on the first step of New Space
    /// when it didn't come from the list.
    private var behind: Bool {
        switch draft.step {
        case .spaces: return false
        case .start: return draft.fromSpaces
        case .name: return draft.tab != nil || draft.fromSpaces
        default: return true
        }
    }

    private var words: (String, String) {
        switch draft.step {
        case .spaces: return draft.carrying.isEmpty ? ("Spaces", "") : ("Move", "to")
        case .start: return ("New", "Space")
        // What the step sets, plainly: the space it is about is on screen,
        // in the strip at the step's top. "Your Color" read as the person's.
        case .name: return ("New", "Space")
        case .emoji: return ("Icon", "")
        // The look card's controls, under their own Color.
        case .color: return ("Look", "")
        case .signIns: return ("Sign-ins", "")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Back, where there is a step behind: not on the first, nor on
            // the name when there was no tab to take and so no first step.
            if behind {
                door("chevron.left", "Back", back)
            }
            // Changed at once: the tray crossfades the head as a whole in
            // Core Animation (SpaceTray.crossfade). SwiftUI's own fades here
            // ran on the main thread's frames and dragged to half a second,
            // the old title and the new smeared over each other.
            Text(words.1.isEmpty ? words.0 : "\(words.0) \(words.1)")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            door("xmark", "Close", close)
        }
        // The title where a card's is on every step; the × on the tray's
        // own inset, a menu's or a card's.
        .padding(.leading, CardFrame.inset) // design: the title stands where a card's does on every step
        .padding(.trailing, SpaceTray.edge(draft.step)) // design: the × on the tray's own inset, a menu's or a card's
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func door(_ icon: String, _ label: String, _ act: @escaping () -> Void) -> some View {
        CardDoor(icon: icon, label: label, act: act)
    }
}

/// A card's own ×, and its ‹: the glyph alone in the muted ink, as the
/// answer card's ×, the ink and a wash only under the pointer.
private struct CardDoor: View {
    let icon: String
    let label: String
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Symbol(icon, size: 9, weight: .semibold)
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: ButtonSize.small.height, height: ButtonSize.small.height)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Palette.hover.opacity(hovering ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: ButtonSize.small.pressed))
        .onHover { hovering = $0 }
        .keyTip(label)
        .accessibilityLabel(label)
    }
}

/// The button at the tray's foot, in the same place on every step.
struct TrayFoot: View {
    @ObservedObject var draft: SpaceDraft
    let press: () -> Void

    private var label: String {
        switch draft.step {
        case .spaces, .start, .name, .color: return "Continue"
        case .emoji: return "Done"
        case .signIns: return "Create Space"
        }
    }

    var body: some View {
        Button(action: press) {
            Text(label)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.yab(.primary, .large))
        .disabled(draft.step == .name && draft.named.isEmpty)
        .padding(CardFrame.inset)
    }
}

/// A space in the tray's list: its emoji on its color, its name, whose
/// sign-ins, something playing in it, its key.
struct SpaceLine: View {
    let space: Space
    let index: Int
    let current: Bool
    let focused: Bool
    let noisy: Bool
    let dark: Bool
    /// What a space never left since spaces had their own color wears: the
    /// window's color now.
    let fallback: SpacePaint
    let browser: Browser?
    /// Tabs held over the list: where they can't go, or where they would.
    var carry: Carry = .none
    /// Tabs just let go into it: its emoji gives once.
    var landed = 0
    /// In the hand, being put in another place: on a ground of its own
    /// over the rows it passes, as a pin lifted in the column is.
    var lifted = false
    let act: () -> Void

    enum Carry: Equatable {
        case none
        /// The space they are in already.
        case away
        /// Under them, and what letting go does.
        case here(String)
    }

    @State private var hovering = false

    var body: some View {
        let color = (space.paint ?? fallback).color(dark: dark)
        Button(action: act) {
            HStack(spacing: 8) {
                SpaceMark(icon: space.icon, size: 13)
                    .foregroundStyle(Palette.ink)
                    .frame(width: 30, height: 30)
                    .background(Color(nsColor: color), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    .environment(\.colorScheme, Tone(color, lifted: true).scheme)
                    .keyframeAnimator(initialValue: 1.0, trigger: landed) { well, scale in
                        well.scaleEffect(scale)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(1.08, duration: 0.1)
                            CubicKeyframe(1.0, duration: 0.18)
                        }
                    }
                Text(space.name)
                    .font(.system(size: SidebarTypography.current, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if case .here(let note) = carry {
                    Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor).lineLimit(1)
                } else {
                    if noisy {
                        Circle().fill(Palette.ink).frame(width: 5, height: 5)
                    }
                    if space.id == Space.mailID {
                        ShortcutGlyphs(.mail, size: 12.5, tint: Palette.muted)
                    } else if let place = browser?.turnOrder.firstIndex(where: { $0.id == space.id }) ?? Optional(index), place < 9 {
                        // Counted as ⌃1 to ⌃9 count: Mail in its place among them.
                        if let action = Shortcut.numbered("space", place + 1) {
                            ShortcutGlyphs(action, size: 12.5, tint: Palette.muted)
                        }
                    }
                }
            }
            .padding(.leading, 3) // design: the emoji's well 3 in from the row on every side, concentric in its corner
            .padding(.trailing, 10) // design: the words keep the row's own air
            .frame(height: SpaceTray.spaceRow)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(ground)
            )
            .background {
                if lifted {
                    let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    shape.fill(Palette.ground) // design: a row lifted in the hand, as the column's pin is, not a card
                        .castShadow(shape, color: .black.opacity(0.14), radius: 8, y: 3)
                }
            }
            // Where the tabs would go: the ring a picked color wears.
            .overlay {
                if case .here = carry {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .opacity(carry == .away ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .onHover { hovering = $0 }
        // Its own sign-ins said in words under the pointer: a mark for it
        // in the row read as nothing in particular.
        .modifier(OwnSignInsTip(on: space.ownSignIns))
        // Its own menu at once on a right click: rename, emoji, delete.
        .steadyMenu(actions: true) {
            if let browser { SpaceMenu(browser: browser, space: space) }
        }
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(current ? [.isSelected] : [])
    }

    private var ground: Color {
        if case .here = carry { return Palette.wash }
        if carry == .away { return .clear }
        return current ? Palette.wash : hovering || focused ? Palette.hover : .clear
    }
}

/// "Signed in on its own", under the pointer, for a space with sign-ins
/// of its own; nothing for the others.
private struct OwnSignInsTip: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.keyTip("Signed in on its own, apart from your other spaces") } else { content }
    }
}

/// A choice with words under it, the start's and the sign-ins': a well of
/// the ink, a little deeper under the pointer.
private struct OptionWell: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(Palette.ink.opacity(hovering ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// New Space, the list's last row: the same row, its words in the muted ink.
private struct NewSpaceLine: View {
    /// Tabs held over it: a new space is made around them.
    var over = false
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Symbol("plus", size: 11)
                    .frame(width: 30, height: 30)
                Text("New Space").font(.system(size: SidebarTypography.current, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering || over ? Palette.ink : Palette.muted)
            .padding(.leading, 3) // design: as the rows above it
            .padding(.trailing, 10) // design: the rows' own air
            .frame(height: SpaceTray.spaceRow)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(over ? Palette.wash : hovering ? Palette.hover : .clear)
            )
            .overlay {
                if over {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .onHover { hovering = $0 }
    }
}

/// A space's own menu, the same wherever it is asked for, as Arc's is: the
/// space's name in the column (••• or a right click), the room under its
/// rows, its dot in the foot and its row in the tray. Arc's lines in Arc's
/// order, those Yab has: Change Space Icon, Rename Space, its look, whose
/// sign-ins (Arc's Set Profile), New Folder and New Live Folder, its
/// settings (Arc's Manage Spaces), Delete Space. Its place is dragged.
struct SpaceMenu: View {
    let browser: Browser
    let space: Space

    var body: some View {
        // Mail keeps its name, its sign-ins and has no Delete of its own:
        // its emoji and its look are yours, and its settings are Settings ›
        // Mail.
        let mail = space.id == Space.mailID
        if !mail {
            Button("Rename Space…", mark: "pencil") { SpaceAsk.name(space, browser: browser) { browser.renameSpace(space.id, to: $0) } }
        }
        Button("Change Space Icon…", mark: "face.smiling") { SpaceTray.changeEmoji(of: space, browser: browser) }
        // Every space's name, at once. Not from a space folded under its
        // name: hidden, nothing would be left to unfold it. Back from this
        // menu on the column's empty room or a space's icon at its foot.
        if !mail, browser.spacesShown, !browser.blank {
            let named = browser.prefs.spaceNames
            if !named || !browser.folderBook.isShut(space.id, in: browser) {
                Button(named ? "Hide Space Name" : "Show Space Name", mark: named ? "eye.slash" : "eye") {
                    // The column's rows glide on their own (ColumnPage, `naming`).
                    withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) { browser.prefs.spaceNames = !named }
                }
            }
        }
        Button("Edit Look…", mark: "paintpalette") {
            SpaceTray.shown?.leave()
            if space.id != browser.spaceID { browser.switchSpace(to: space.id) }
            LookCard.shared.show(browser)
        }
        // The first space's are everyone's: only another can have its own.
        if !space.isFirst, !mail {
            Menu("Sign-Ins", mark: "person.key") {
                Toggle("Shared", isOn: Binding(get: { !space.ownSignIns }, set: { if $0 { signIns(own: false) } }))
                Toggle("Its Own", isOn: Binding(get: { space.ownSignIns }, set: { if $0 { signIns(own: true) } }))
            }
        }
        // Folders go into the space on screen, from its column, not from
        // the tray over it.
        if space.id == browser.spaceID, !mail, SpaceTray.shown == nil {
            Divider()
            KeptFolderItems(browser: browser)
        }
        Divider()
        Button(mail ? "Mail Settings…" : "Space Settings…", mark: "gearshape") {
            SpaceTray.shown?.leave()
            if mail { SettingsWindow.shared.show(.mail, for: browser) } else { SettingsWindow.shared.showSpace(space.id, for: browser) }
        }
        if browser.canDeleteSpace(space.id), !mail {
            Divider()
            Button("Delete Space…", mark: "trash", role: .destructive) {
                if let tray = SpaceTray.shown { tray.askDelete(space) } else { SpaceTray.confirmDelete(space, browser: browser) }
            }
                .shortcut(.spaceDelete)
        }
    }

    private func signIns(own: Bool) {
        SpaceTray.shown?.leave()
        Task { @MainActor in
            _ = await SpaceTray.askSignIns(space, own: own, browser: browser, place: .page)
        }
    }
}

/// Whether a scroll view has rows past its top and past its foot, told
/// only when that changes, not on every point of a scroll.
private struct ScrollEdges: ViewModifier {
    struct More: Equatable {
        var above = false
        var below = false
    }
    @Binding var more: More
    /// Every point of a scroll, for what finds a row by where it is.
    var scrolled: (CGFloat) -> Void = { _ in }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: More.self) { geo in
                More(above: geo.contentOffset.y > 1,
                     below: geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - 1)
            } action: { _, now in
                more = now
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in scrolled(y) }
        } else {
            content
        }
    }
}

/// New Space's look: the look card's own controls on the draft, the
/// color made your own as it moves.
struct TrayLook: View {
    @ObservedObject var draft: SpaceDraft
    let width: CGFloat

    var body: some View {
        LookControls(look: draft.look, width: width, bare: true) {
            // Grain or transparency moved on No Color: still no color.
            if draft.swatch == .plain, draft.custom.hex == Swatch.plainSeed, draft.colors.isEmpty { return }
            draft.pick(swatch: .custom)
        }
    }
}

/// One step's body.
struct TrayStep: View {
    @ObservedObject var draft: SpaceDraft
    /// The step it was made for, kept while it fades under the next one:
    /// read from the draft, it turned into the next step as it left.
    let step: SpaceDraft.Step
    let width: CGFloat
    let wheel: CGFloat
    weak var tray: SpaceTray?
    @Environment(\.colorScheme) private var scheme
    @FocusState private var naming: Bool
    private var dark: Bool { scheme == .dark }
    /// Rows past the list's top and past its foot.
    @State private var more = ScrollEdges.More()

    private func haze(_ edge: VerticalEdge) -> some View {
        LinearGradient(colors: [Palette.ground, Palette.ground.opacity(0)], startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .frame(height: 20)
            .allowsHitTesting(false)
    }
    private var look: NSColor { draft.paint.color(dark: dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .spaces: spaces
            case .start: start
            case .name: name
            case .emoji: emoji
            case .color: color
            case .signIns: signIns
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SpaceTray.edge(step))
        .frame(width: width, alignment: .topLeading)
    }

    // MARK: the spaces

    private var spaces: some View {
        let browser = tray?.browserForList
        let list = browser?.spaces ?? []
        let current = browser?.spaceID
        return VStack(spacing: SpaceTray.spaceGap) {
            if let browser, let tray {
                ForEach(tray.specials) { special in
                    SpaceLine(space: special, index: -2, current: current == special.id, focused: false, noisy: false,
                              dark: dark, fallback: draft.window, browser: browser) { tray.pick(special.id) }
                }
            }
            ScrollViewReader { reader in
                ThreadScrollView(.vertical) {
                    VStack(spacing: SpaceTray.spaceGap) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, space in
                            SpaceLine(space: space, index: index, current: space.id == current, focused: draft.focus == index,
                                          noisy: space.id != current && (browser?.parked[space.id]?.tabs.contains { $0.noisy } ?? false),
                                          dark: dark, fallback: draft.window, browser: browser,
                                          carry: carry(space, index: index, current: current, browser: browser),
                                          landed: draft.landed[space.id] ?? 0, lifted: lifted == space.id) { tray?.pick(space.id) }
                                    .offset(y: shift(index, list))
                                    .zIndex(lifted == space.id ? 1 : 0)
                                    // The others make way on the settle spring while a row is
                                    // in the hand; let go, the new order stands at once, with
                                    // no row sliding back from where it had made way.
                                    .animation(lifted == nil || lifted == space.id ? nil : Motion.settle, value: shift(index, list))
                                    .highPriorityGesture(reorder(space, list: list, browser: browser))
                        }
                    }
                }
                .modifier(ScrollEdges(more: $more, scrolled: { draft.scrolled = $0 }))
                // More above or below: the tray's ground over the last rows
                // there, laid over them rather than masking them, so a
                // scroll draws no offscreen pass.
                .overlay(alignment: .top) { haze(.top).opacity(more.above ? 1 : 0) }
                .overlay(alignment: .bottom) { haze(.bottom).opacity(more.below ? 1 : 0) }
                .animation(Motion.quick, value: more.above)
                .animation(Motion.quick, value: more.below)
                // A long list opens on the space on screen, and keeps the
                // arrows' row in sight.
                .onAppear { if let current { reader.scrollTo(current, anchor: .center) } }
                .onChange(of: draft.focus) { _, focus in
                    if let focus, list.indices.contains(focus) { reader.scrollTo(list[focus].id) }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .frame(height: tray?.listHeight ?? 0)
            NewSpaceLine(over: draft.over == -1) { tray?.startNew() }
        }
    }

    /// What tabs held over the list would do at this row.
    private func carry(_ space: Space, index: Int, current: UUID?, browser: Browser?) -> SpaceLine.Carry {
        guard !draft.carrying.isEmpty else { return .none }
        if space.id == current { return .away }
        guard draft.over == index else { return .none }
        let fresh = current.map { Spaces.store(for: $0) !== Spaces.store(for: space.id) } ?? false
        return .here(fresh ? "Opens signed out" : "Move here")
    }

    // MARK: its order

    /// The row in the hand, and how far it has come.
    @State private var lifted: UUID?
    @State private var lift: CGFloat = 0
    private var pitch: CGFloat { SpaceTray.spaceRow + SpaceTray.spaceGap }

    /// Where the row in the hand would land.
    private func landing(_ from: Int, _ count: Int) -> Int {
        min(count - 1, max(0, from + Int((lift / pitch).rounded())))
    }

    /// Each row's way out of the one in the hand's path.
    private func shift(_ index: Int, _ list: [Space]) -> CGFloat {
        guard let lifted, let from = list.firstIndex(where: { $0.id == lifted }) else { return 0 }
        if index == from { return lift }
        let to = landing(from, list.count)
        if from < to, index > from, index <= to { return -pitch }
        if from > to, index < from, index >= to { return pitch }
        return 0
    }

    /// A row dragged up or down the list: the others make way, and ⌃1 to
    /// ⌃9 follow the new order.
    private func reorder(_ space: Space, list: [Space], browser: Browser?) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                guard draft.carrying.isEmpty else { return }
                lifted = space.id
                lift = drag.translation.height
            }
            .onEnded { _ in
                guard lifted == space.id, let from = list.firstIndex(where: { $0.id == space.id }) else { return }
                let to = landing(from, list.count)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    browser?.moveSpace(space.id, to: to)
                    lifted = nil
                    lift = 0
                }
            }
    }

    // MARK: start

    private var start: some View {
        VStack(spacing: 8) {
            choice("plus", "Empty Space", "Starts with a clean row of tabs.") { tray?.take(false) }
            if let tab = draft.tab {
                choice("arrow.up.right", "Take This Tab", "\(tab.title.isEmpty ? "It" : tab.title) moves into it.") { tray?.take(true) }
            }
        }
    }

    private func choice(_ icon: String, _ title: String, _ detail: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Symbol(icon, size: 12)
                    .foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.ink.opacity(0.08)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                Symbol("chevron.right", size: 10).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 60)
            .modifier(OptionWell())
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }

    // MARK: name

    private var name: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
            TextField("", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .focused($naming)
                .modifier(CardField(hint: "Name", empty: draft.name.isEmpty, typing: naming))
                .onSubmit { tray?.forward() }
                .padding(.top, 10)
                .onAppear { tray?.focusName = { naming = true } }
        }
    }

    /// The space as it will look: its color and grain, its emoji, its name.
    private var card: some View {
        let tone = Tone(look, lifted: true)
        return ZStack(alignment: .topLeading) {
            BackdropFill(color: Color(nsColor: look), grain: draft.grain, transparency: draft.paint.wornTransparency(dark: dark), colors: draft.paint.gradient(dark: dark))
            Button { tray?.go(.emoji) } label: {
                SpaceMark(icon: draft.icon, size: 16)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(dark ? 0.14 : 0.45)))
            }
            .buttonStyle(PressStyle())
            .padding(10)
            .keyTip("Choose an emoji")
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Text(draft.named.isEmpty ? "Untitled" : draft.named)
                    .font(.system(size: 15, weight: .semibold))
                    .opacity(draft.named.isEmpty ? 0.45 : 1)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            Text(draft.taking ? draft.takenWords : "No tabs yet")
                .font(.system(size: 11, weight: .medium))
                .opacity(0.7)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .foregroundStyle(Palette.ink)
        .environment(\.colorScheme, tone.scheme)
        .frame(height: 88)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    // MARK: emoji

    // This is the same picker used by Space settings and folders, including
    // its artwork, search, keyboard navigation and plain footer switch.
    var iconPicker: IconPicker {
        IconPicker(mark: draft.icon, space: draft.emoji, pick: { mark in
            guard let mark else { return }
            draft.pick(icon: mark)
            tray?.pickedEmoji()
        }, close: { tray?.back() })
    }

    private var emoji: some View {
        iconPicker
            .frame(maxWidth: .infinity)
            .onAppear { tray?.focusName = nil }
    }

    // MARK: color

    private var strip: some View {
        let tone = Tone(look, lifted: true)
        return ZStack(alignment: .leading) {
            BackdropFill(color: Color(nsColor: look), grain: draft.grain, transparency: draft.paint.wornTransparency(dark: dark), colors: draft.paint.gradient(dark: dark))
            LookDrawingsFill(drawings: draft.drawings, strength: draft.strength, ground: look)
            HStack(spacing: 8) {
                SpaceMark(icon: draft.icon, size: 14)
                Text(draft.named.isEmpty ? "Untitled" : draft.named)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if draft.taking {
                    Text(draft.takenWords).font(.system(size: 11, weight: .medium)).opacity(0.7)
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
        }
        .environment(\.colorScheme, tone.scheme)
        .frame(height: 36)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private var color: some View {
        VStack(spacing: 0) {
            strip
            // The strip above and the window wear each move as it comes.
            TrayLook(draft: draft, width: wheel)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in tray?.refitLook() }
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: sign-ins

    private var signIns: some View {
        VStack(spacing: 8) {
            strip.padding(.bottom, 2)
            check("Shared Sign-ins", "Signed in wherever your other spaces are.", on: !draft.own) { draft.own = false }
            check("Its Own Sign-ins", "Starts signed out, with cookies of its own.", on: draft.own) { draft.own = true }
        }
    }

    private func check(_ title: String, _ detail: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().strokeBorder(Palette.ink.opacity(on ? 0 : 0.25), lineWidth: 1.5)
                    if on {
                        Circle().fill(Palette.ink)
                        Symbol("checkmark", size: 9).foregroundStyle(Palette.ground)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 10)
            .frame(height: 60)
            .modifier(OptionWell())
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}
