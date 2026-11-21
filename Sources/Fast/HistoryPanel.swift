import SwiftUI

// A tab's whole history, for when a swipe back is pulled past every page it
// names and let go on "Search History". It comes out of the place the list
// stood, as the list came out of the pill (family-values-motion P1, P3):
// the pages of this tab, the newest first, when each was last seen, the one
// you are on marked; the caret in a field above them to look for one; the
// arrows and Return to go, Escape or a click anywhere else to put it away;
// and last a row that looks for the words in everything you have read
// (History's place in the box). It is the rare end of the gesture, so it may be a thing
// you work in; the frequent pull never gets this far.

/// What the panel lists and what a pick does.
struct TabHistory {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let title: String
        let host: String
        let url: URL
        let current: Bool
    }

    var entries: [Entry]
    var pick: (Int) -> Void
}

/// The panel's words and times, kept apart from the page's SwiftUI so that
/// only the panel draws again when they change.
@MainActor
final class HistoryPanelModel: ObservableObject {
    @Published var seen: [String: Date] = [:]
}

extension PullView {
    static let panelWidth: CGFloat = 360

    /// Up, out of where the list stood; `all` looks for words in the whole
    /// history.
    func panel(_ history: TabHistory, of tab: Tab, all: @escaping (String) -> Void) {
        guard tab === owner, window != nil else { return }
        closePanel(animated: false)
        let model = HistoryPanelModel()
        let face = HistoryPanelView(
            history: history, model: model,
            go: { [weak self] index in
                history.pick(index)
                self?.closePanel(animated: true)
            },
            all: { [weak self] words in
                all(words)
                self?.closePanel(animated: true)
            },
            close: { [weak self] in self?.closePanel(animated: true) },
            // Fewer rows found, a shorter panel: its top stays where it is.
            resized: { [weak self] size in
                guard let host = self?.historyPanel, abs(host.frame.height - size.height) > 0.5 else { return }
                host.frame = CGRect(x: host.frame.minX, y: host.frame.maxY - size.height, width: PullView.panelWidth + 2 * PullView.margin, height: size.height)
            }
        )
        let host = NSHostingView(rootView: face)
        host.sizingOptions = []
        host.wantsLayer = true
        addSubview(host)
        historyPanel = host
        let width = PullView.panelWidth + 2 * PullView.margin
        let size = CGSize(width: width, height: host.fittingSize.height)
        let place = listPlace
        let m = PullView.margin
        let back = place?.back ?? true
        let left = back ? (place?.frame.minX ?? PullView.inset - m) : (place?.frame.maxX ?? bounds.width - PullView.inset + m) - size.width
        let top = min(bounds.height - m / 2, (place?.frame.maxY ?? bounds.midY + size.height / 2) + 40)
        let bottom = max(-m / 2, top - size.height)
        host.frame = CGRect(x: left, y: bottom, width: size.width, height: size.height).integral
        grow(host, from: place?.frame)
        Diary.shared.lastSeen(history.entries.map(\.url)) { seen in model.seen = seen }
        watchClicks()
        window?.makeFirstResponder(host)
    }

    func closePanel(animated: Bool) {
        guard let panel = historyPanel else { return }
        historyPanel = nil
        stopWatchingClicks()
        guard animated, let layer = panel.layer, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return panel.removeFromSuperview() }
        let pace = Reshape.Pace.depart
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { panel.removeFromSuperview() } }
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = pace.duration
        fade.timingFunction = pace.timing
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()
        if let page = owner?.page { window?.makeFirstResponder(page) }
    }

    /// From 0.6 of its size about the middle of where the list stood, the
    /// arrival pace; with Reduce Motion, only the fade.
    private func grow(_ panel: NSView, from: CGRect?) {
        guard let layer = panel.layer else { return }
        let pace = Reshape.Pace.arrive
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = pace.duration
        fade.timingFunction = pace.timing
        layer.add(fade, forKey: "opacity")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let spot = from.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            let point = panel.convert(spot, from: self)
            let scale: CGFloat = 0.6
            let start = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                            CATransform3DMakeTranslation((1 - scale) * point.x, (1 - scale) * point.y, 0))
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: start)
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.duration = pace.duration
            grow.timingFunction = pace.timing
            layer.add(grow, forKey: "transform")
        }
        CATransaction.commit()
    }

    /// A click anywhere but the panel puts it away, and still does what it
    /// was for.
    private func watchClicks() {
        stopWatchingClicks()
        PullView.clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = historyPanel else { return event }
            let inside = event.window === window && panel.frame.contains(convert(event.locationInWindow, from: nil))
            if !inside { closePanel(animated: true) }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let clicks = PullView.clicks { NSEvent.removeMonitor(clicks) }
        PullView.clicks = nil
    }

    nonisolated(unsafe) static var clicks: Any?
}

struct HistoryPanelView: View {
    let history: TabHistory
    @ObservedObject var model: HistoryPanelModel
    let go: (Int) -> Void
    let all: (String) -> Void
    let close: () -> Void
    let resized: (CGSize) -> Void

    @State private var words = ""
    @State private var lit = 0
    @FocusState private var typing: Bool

    /// The entries the words find, and the row that looks everywhere.
    private var found: [TabHistory.Entry] {
        let words = words.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.title.lowercased().contains(words) || $0.host.lowercased().contains(words)
                || $0.url.absoluteString.lowercased().contains(words)
        }
    }

    private var count: Int { found.count + 1 }

    var body: some View {
        let found = found
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Symbol("magnifyingglass", size: 11)
                    .foregroundStyle(Palette.muted)
                TextField("Search this tab's history", text: $words)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($typing)
                    .onSubmit { pick(lit, in: found) }
                    .onKeyPress(keys: [.downArrow], phases: .down) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        lit = min(lit + 1, count - 1)
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow], phases: .down) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        lit = max(lit - 1, 0)
                        return .handled
                    }
                    .onExitCommand { close() }
                    .onChange(of: words) { _, _ in lit = 0 }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            ScrollViewReader { scroller in
                ThreadScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(found.enumerated()), id: \.element.id) { index, entry in
                            row(entry, lit: index == lit)
                                .id(index)
                                .onTapGesture { pick(index, in: found) }
                                .onHover { if $0 { lit = index } }
                        }
                        let everywhere = words.trimmingCharacters(in: .whitespaces)
                        PullRow(title: everywhere.isEmpty ? "All History" : "“\(everywhere)” in all history",
                                detail: "", lit: lit == found.count) {
                            Symbol("clock", size: 12)
                                .foregroundStyle(lit == found.count ? Palette.ground : Palette.muted)
                                .frame(width: 20, height: 20)
                        }
                        .id(found.count)
                        .onTapGesture { pick(found.count, in: found) }
                        .onHover { if $0 { lit = found.count } }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: CGFloat(min(count, 9)) * PullList.rowHeight)
                .onChange(of: lit) { _, row in scroller.scrollTo(row) }
            }
        }
        .modifier(PanelGround())
        .padding(PullView.margin)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
        .onAppear {
            typing = true
            // The page before this one, as a swipe back would have it.
            lit = min((history.entries.firstIndex(where: \.current) ?? -1) + 1, history.entries.count)
        }
    }

    private func row(_ entry: TabHistory.Entry, lit: Bool) -> some View {
        let site = Browser.site(entry.host)
        let when = model.seen[Diary.key(entry.url)]
        return PullRow(title: entry.title, detail: entry.current ? "Now" : when.map(PanelTime.short) ?? entry.host, lit: lit) {
            Mark(icon: Favicons.shared.pageIcon(entry.url) ?? Favicons.shared.cached(entry.host) ?? Favicons.shared.cached(site),
                 letter: site.first.map { String($0).uppercased() } ?? "•", size: 20)
        }
        .opacity(entry.current && !lit ? 0.55 : 1)
    }

    private func pick(_ index: Int, in found: [TabHistory.Entry]) {
        if index < found.count {
            found[index].current ? close() : go(found[index].id)
        } else {
            all(words.trimmingCharacters(in: .whitespaces))
        }
    }
}

/// How long ago, as briefly as a row's corner has room for.
enum PanelTime {
    static func short(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400)) d" }
        return date.formatted(AppDates.dateTime.month(.abbreviated).day())
    }
}

/// Liquid Glass where there is glass and it is wanted, the dark look half
/// veiled as the swipe's list is; the list's white card otherwise. The held
/// door's list wears it too (DoorList), at the list's width.
struct PanelGround: ViewModifier {
    var width = PullView.panelWidth
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DropFrame.corner, style: .continuous)
        if #available(macOS 26.0, *), PullView.glassy {
            content
                .padding(DropFrame.inset)
                .frame(width: width, alignment: .leading)
                .background(Palette.ground.opacity(scheme == .dark ? PullView.darkVeil : 0), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.dropFrame(width: width)
        }
    }
}
