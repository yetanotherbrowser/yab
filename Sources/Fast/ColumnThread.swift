import AppKit
import SwiftUI
import WebKit

/// Native lists share the column's thin, fading scroll bars on either axis.
/// Keep SwiftUI in charge of scrolling, anchors, readers and indicator visibility.
struct ThreadScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let showsIndicators: Bool
    private let content: Content

    init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) { content }
            .background(ColumnThread())
    }
}

/// Text editors own a scroll view too, including short fields once they grow.
struct ThreadTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .background(ColumnThread())
    }
}

/// A grouped settings page laid out the way a grouped Form lays one out,
/// a row at a time in a lazy stack, so only the rows in view are built.
struct ThreadForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ThreadScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Group(sections: content) { sections in
                    ForEach(FormPiece.all(Array(sections))) { $0 }
                }
            }
            .padding(FormGroupRow<EmptyView>.margin)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A header, row or footer as one lazy item; rows are keyed by search anchor so scrollTo finds them unbuilt.
private struct FormPiece: View, Identifiable {
    enum Kind {
        case header(SectionConfiguration)
        case row(Subview, first: Bool, last: Bool)
        case footer(SectionConfiguration)
        /// A section with nothing to show still keeps its room.
        case gap
    }
    enum Part: Hashable {
        case header(SectionConfiguration.ID), footer(SectionConfiguration.ID), gap(SectionConfiguration.ID)
    }

    let id: AnyHashable
    let kind: Kind
    var top: CGFloat = 0
    /// The room after a section, on its last piece.
    var bottom: CGFloat = 0

    static func all(_ sections: [SectionConfiguration]) -> [FormPiece] {
        var pieces: [FormPiece] = []
        for (at, section) in sections.enumerated() {
            let start = pieces.count
            if !section.header.isEmpty {
                // The Form's: 19 more after rows, 17 less right under a page's head.
                let top: CGFloat = at == 0 ? 0 : sections[at - 1].content.isEmpty ? -17 : 19
                pieces.append(FormPiece(id: Part.header(section.id), kind: .header(section), top: top))
            }
            for row in section.content {
                let key = row.containerValues.settingsAnchor.map(AnyHashable.init) ?? AnyHashable(row.id)
                pieces.append(FormPiece(id: key, kind: .row(row, first: row.id == section.content.first?.id,
                                                            last: row.id == section.content.last?.id)))
            }
            if !section.footer.isEmpty {
                pieces.append(FormPiece(id: Part.footer(section.id), kind: .footer(section)))
            }
            let room: CGFloat = section.footer.isEmpty ? 10 : 30
            if pieces.count > start {
                pieces[pieces.count - 1].bottom = room
            } else {
                pieces.append(FormPiece(id: Part.gap(section.id), kind: .gap, bottom: room))
            }
        }
        return pieces
    }

    var body: some View {
        piece.padding(.bottom, bottom)
    }

    @ViewBuilder private var piece: some View {
        switch kind {
        case .header(let section):
            HStack(spacing: 0) { section.header }
                .font(.system(size: 13, weight: FormGroupRow<EmptyView>.headWeight))
                .padding(.horizontal, 10)
                .padding(.top, top)
                .padding(.bottom, 10)
        case .row(let row, let first, let last):
            FormGroupRow(first: first, last: last, form: true) { row }
        case .footer(let section):
            HStack(spacing: 0) { section.footer }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
        case .gap:
            Color.clear.frame(height: 0)
        }
    }
}

extension ContainerValues {
    /// A Settings row's search anchor, which ThreadForm keys the row by.
    @Entry var settingsAnchor: String? = nil
}

/// A row of a group, the way a grouped Form draws one: the group is its
/// rows' backgrounds laid edge to edge, so it can be built a row at a time.
struct FormGroupRow<Content: View>: View {
    /// The Form's own measures on each design.
    static var radius: CGFloat { if #available(macOS 26.0, *) { 12 } else { 10 } }
    static var pad: CGFloat { if #available(macOS 26.0, *) { 10.5 } else { 8 } }
    static var headWeight: Font.Weight { if #available(macOS 26.0, *) { .regular } else { .semibold } }
    static var margin: CGFloat { 20 }

    let first: Bool
    let last: Bool
    /// Laid out as ThreadForm's rows: the Form's row height, separator and last-row inset.
    var form = false
    @ViewBuilder let content: Content

    var body: some View {
        let top = first ? Self.radius : 0
        let foot = last ? Self.radius : 0
        content
            .frame(maxWidth: .infinity, minHeight: form ? 0 : 22, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, Self.pad)
            // The Form's last row is a point shorter, a lone row half a point taller.
            .padding(.bottom, Self.pad + (form && last ? (first ? 0.5 : -1) : 0))
            .background {
                UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: foot, bottomTrailingRadius: foot,
                                       topTrailingRadius: top, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            }
            .overlay(alignment: .bottom) {
                if !last {
                    Rectangle().fill(form ? AnyShapeStyle(.primary.opacity(0.045)) : AnyShapeStyle(Color(nsColor: .separatorColor)))
                        .frame(height: 1).padding(.horizontal, 10)
                }
            }
    }
}

/// The column's scroll bar as a thread, as Arc's is: an overlay knob with
/// no track, even with a mouse plugged in, where macOS would otherwise draw
/// the old scroller with its gray track down the rows. 2.5 points wide, 6
/// under the pointer and 6.5 in the hand. It comes in as the rows move and
/// goes 0.6 s after they stop. AppKit still owns the scroller: a click along
/// it, a drag of the knob, VoiceOver. Arc does the same with its own
/// NSScroller (NoBackgroundScroller): no slot, overlay always.
final class ThreadScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class var preferredScrollerStyle: NSScroller.Style { .overlay }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { width }

    /// Room for the hand: a little more than the column's margin, which
    /// the rows keep clear of.
    static let width: CGFloat = 10
    private static let thin: CGFloat = 2.5
    private static let wide: CGFloat = 6
    private static let held: CGFloat = 6.5
    /// From the column's edge to the thread.
    private static let edge: CGFloat = 3
    /// How far it comes in from, sideways.
    private static let slide: CGFloat = 3
    private static let stay: CFTimeInterval = 0.6
    private static let comeIn: CFTimeInterval = 0.12
    private static let goOut: CFTimeInterval = 0.35
    private static let widen: CFTimeInterval = 0.15
    private static let grip: CFTimeInterval = 0.12

    /// Each nought to one, eased as drawn.
    private var shown: CGFloat = 0
    private var hover: CGFloat = 0
    private var hold: CGFloat = 0
    private var pointed = false
    private var dragging = false
    private var lastMove: CFTimeInterval = -.infinity
    private var lastOffset: CGFloat?
    private var link: CADisplayLink?
    private var tick: CFTimeInterval = 0
    private weak var watchedScroll: NSScrollView?
    private weak var watchedClip: NSClipView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A mouse plugged in or out turns every scroll view back to the
        // style it asks for: this one stays overlay.
        NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        watchedScroll?.removeObserver(self, forKeyPath: "scrollerStyle")
        NotificationCenter.default.removeObserver(self)
    }

    /// The thread on a scroll view, once.
    static func put(on scroll: NSScrollView) {
        var installed = false
        if scroll.hasVerticalScroller, !(scroll.verticalScroller is ThreadScroller) {
            let state = scroll.verticalScroller.map { ($0.doubleValue, $0.knobProportion, $0.isEnabled) }
            let thread = ThreadScroller(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            scroll.verticalScroller = thread
            if let state { thread.doubleValue = state.0; thread.knobProportion = state.1; thread.isEnabled = state.2 }
            installed = true
        }
        if scroll.hasHorizontalScroller, !(scroll.horizontalScroller is ThreadScroller) {
            let state = scroll.horizontalScroller.map { ($0.doubleValue, $0.knobProportion, $0.isEnabled) }
            let thread = ThreadScroller(frame: NSRect(x: 0, y: 0, width: 100, height: width))
            scroll.horizontalScroller = thread
            if let state { thread.doubleValue = state.0; thread.knobProportion = state.1; thread.isEnabled = state.2 }
            installed = true
        }
        (scroll.verticalScroller as? ThreadScroller)?.watch(scroll)
        (scroll.horizontalScroller as? ThreadScroller)?.watch(scroll)
        if scroll.scrollerStyle != .overlay {
            scroll.scrollerStyle = .overlay
            scroll.tile()
            installed = true
        }
        if installed { scroll.reflectScrolledClipView(scroll.contentView) }
    }

    /// SwiftUI reapplies the system's style after configuring a scroll view.
    /// Observe the native property so that Always cannot restore a track.
    private func watch(_ scroll: NSScrollView) {
        guard watchedScroll !== scroll else { return }
        watchedScroll?.removeObserver(self, forKeyPath: "scrollerStyle")
        if let clip = watchedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        }
        watchedScroll = scroll
        watchedClip = scroll.contentView
        lastOffset = offset(of: scroll.contentView, in: scroll)
        scroll.addObserver(self, forKeyPath: "scrollerStyle", options: [.new], context: nil)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsMoved),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "scrollerStyle", let scroll = watchedScroll {
            if scroll.scrollerStyle != .overlay { ThreadScroller.put(on: scroll) }
            return
        }
        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    @objc private func boundsMoved() { moved() }

    @objc private func restyle() {
        DispatchQueue.main.async { [weak self] in
            guard let scroll = self?.enclosingScrollView else { return }
            ThreadScroller.put(on: scroll)
        }
    }

    /// Something to scroll.
    private var needed: Bool { isEnabled && knobProportion < 1 }
    private var horizontal: Bool { bounds.width > bounds.height }

    // MARK: what wakes it

    /// Told where the rows are on every scroll, and when they grow or
    /// shrink: only a scroll brings the thread, not a tab coming or going.
    override var doubleValue: Double {
        didSet { moved() }
    }

    private func moved() {
        guard let clip = watchedClip ?? enclosingScrollView?.contentView else { return }
        let offset = self.offset(of: clip, in: watchedScroll ?? enclosingScrollView)
        let last = lastOffset
        lastOffset = offset
        guard let last, abs(offset - last) > 0.5, window != nil else { return }
        lastMove = CACurrentMediaTime()
        watchedScroll?.flashScrollers()
        wake()
    }

    /// How far the rows are scrolled from where they rest: from the inset
    /// at their start, so the rows' lead changing under them (the space's
    /// name hidden or shown) doesn't read as a scroll.
    private func offset(of clip: NSClipView, in scroll: NSScrollView?) -> CGFloat {
        let insets = scroll?.contentInsets ?? NSEdgeInsetsZero
        return horizontal ? clip.bounds.minX + insets.left : clip.bounds.minY + insets.top
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard needed else { return }
        pointed = true
        wake()
    }

    override func mouseExited(with event: NSEvent) {
        pointed = false
        lastMove = CACurrentMediaTime()
        wake()
    }

    /// AppKit's own tracking runs inside: the knob in the hand, or a page
    /// at a time for a click beside it.
    override func mouseDown(with event: NSEvent) {
        dragging = true
        wake()
        super.mouseDown(with: event)
        dragging = false
        lastMove = CACurrentMediaTime()
        if let window { pointed = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        wake()
    }

    /// Clicks go through to the rows while there is no thread to take them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        shown > 0 || pointed ? super.hitTest(point) : nil
    }

    // MARK: its motion

    private func wake() {
        guard link == nil else { return }
        tick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(step))
        // On through AppKit's tracking of a drag.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        let now = CACurrentMediaTime(), dt = CGFloat(min(0.05, now - tick))
        tick = now
        let near = pointed || dragging
        let wanted: CGFloat = needed && (near || now - lastMove < Self.stay) ? 1 : 0
        func toward(_ value: CGFloat, _ target: CGFloat, _ time: CFTimeInterval) -> CGFloat {
            target > value ? min(target, value + dt / CGFloat(time)) : max(target, value - dt / CGFloat(time))
        }
        let was = (shown, hover, hold)
        shown = toward(shown, wanted, wanted > shown ? Self.comeIn : Self.goOut)
        hover = toward(hover, near ? 1 : 0, Self.widen)
        hold = toward(hold, dragging ? 1 : 0, Self.grip)
        if was != (shown, hover, hold) { needsDisplay = true }
        // Settled: gone, or held steady under the pointer. Waiting out
        // `stay` it keeps ticking, drawing nothing.
        let still = hover == (near ? 1 : 0) && hold == (dragging ? 1 : 0)
        if still, shown == 0 || (shown == 1 && near) {
            link?.invalidate()
            link = nil
        }
    }

    // MARK: its look

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        guard shown > 0, needed else { return }
        func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
        let over = ease(hover), held = ease(hold), come = ease(shown)
        var width = Self.thin + (Self.wide - Self.thin) * over
        width += (Self.held - width) * held
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alphas: (CGFloat, CGFloat, CGFloat) = dark ? (0.4, 0.62, 0.8) : (0.28, 0.45, 0.6)
        var alpha = alphas.0 + (alphas.1 - alphas.0) * over
        alpha += (alphas.2 - alpha) * held
        let slide = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (1 - come) * Self.slide
        let knob = rect(for: .knob)
        let thread = horizontal
            ? NSRect(x: knob.minX + 1, y: bounds.maxY - Self.edge - width + slide, width: max(width, knob.width - 2), height: width)
            : NSRect(x: bounds.maxX - Self.edge - width + slide, y: knob.minY + 1, width: width, height: max(width, knob.height - 2))
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha * come).setFill()
        NSBezierPath(roundedRect: thread, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

/// Puts the thread on the scroll view it stands in, laid behind the rows.
struct ColumnThread: NSViewRepresentable {
    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) { view.fit() }

    final class Finder: NSView {
        override func layout() {
            super.layout()
            fit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fit()
        }

        func fit() {
            if let scroll = beside() ?? enclosingScrollView {
                ThreadScroller.put(on: scroll)
            } else if window != nil {
                // Laid behind a scroll view SwiftUI hasn't made yet.
                DispatchQueue.main.async { [weak self] in
                    if let self, let scroll = self.beside() ?? self.enclosingScrollView { ThreadScroller.put(on: scroll) }
                }
            }
        }

        /// Laid behind the scroll view rather than its rows (the box's
        /// lists, `edgeScroll`): the scroll view its own size beside it,
        /// a few levels up at most.
        private func beside() -> NSScrollView? {
            guard window != nil, bounds.width > 0 else { return nil }
            let mine = convert(bounds, to: nil)
            func same(_ scroll: NSScrollView) -> Bool {
                let theirs = scroll.convert(scroll.bounds, to: nil)
                let overlap = max(0, min(theirs.maxY, mine.maxY) - max(theirs.minY, mine.minY))
                // A grouped form's background stops at its safe area,
                // while its native scroll view continues under the toolbar.
                return abs(theirs.minX - mine.minX) < 2 && abs(theirs.maxX - mine.maxX) < 2
                    && abs(theirs.minY - mine.minY) < 96 && abs(theirs.maxY - mine.maxY) < 96
                    && overlap >= min(theirs.height, mine.height) * 0.9
            }
            func find(in view: NSView, depth: Int) -> NSScrollView? {
                guard !(view is WKWebView) else { return nil }
                if let scroll = view as? NSScrollView { return same(scroll) ? scroll : nil }
                guard depth > 0 else { return nil }
                for sub in view.subviews where sub !== self {
                    if let found = find(in: sub, depth: depth - 1) { return found }
                }
                return nil
            }
            var level = superview
            for _ in 0..<5 {
                guard let view = level else { return nil }
                if let found = find(in: view, depth: 5) { return found }
                level = view.superview
            }
            return nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
