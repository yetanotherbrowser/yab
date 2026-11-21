import SwiftUI
import UIKit

/// History, in Settings' sheet and look: the search over it, Clear with its
/// ranges, then the pages by day (Today, Yesterday, dates), each row the
/// site's icon, the title, the host, the Mac's name when it was the Mac's,
/// and the time. A tap opens the page; a row swiped left says Delete, a long
/// swipe deletes it at once. The rows are lazy: History holds thousands.
struct HistoryPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private typealias M = Metrics.History

    var body: some View {
        @Bindable var history = app.history
        let days = history.days()
        let none = history.entries.isEmpty
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                search(text: $history.query)
                if none {
                    empty
                } else if days.isEmpty {
                    Text("No pages found")
                        .font(.body)
                        .foregroundStyle(SettingsInk.footer)
                        .frame(maxWidth: .infinity, minHeight: Metrics.touch)
                        .accessibilityIdentifier("history.search.empty")
                } else {
                    if history.query.isEmpty { clearRow }
                    ForEach(days) { day in
                        dayTitle(day)
                        ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                            HistoryRow(entry: entry, first: index == 0, last: index == day.entries.count - 1, swipe: $history.swipe,
                                       open: { open(entry) }, delete: { delete(entry) })
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.Settings.bodySide)
            .padding(.top, Metrics.Settings.indexTop)
            .padding(.bottom, Metrics.Settings.bodyBottom)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(SettingsInk.pageGround)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0.5 } action: { _, under in
            let ui = SettingsUI.shared
            if ui.navigation.last == .page(.history), ui.pageUnder != under { ui.pageUnder = under }
        }
        .onDisappear {
            app.history.query = ""
            app.history.swipe = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.page")
    }

    // MARK: - parts

    private func search(text: Binding<String>) -> some View {
        HStack(spacing: Metrics.Settings.headGap) {
            Glyph(.magnifyingGlass, size: Metrics.Settings.searchIcon, color: SettingsInk.value)
            SettingsSearchField(text: text, placeholder: "Search History", identifier: "history.search")
                .frame(maxWidth: .infinity)
            if !text.wrappedValue.isEmpty {
                SettingsSearchClear(identifier: "history.search.clear") { text.wrappedValue = "" }
                    .frame(width: Metrics.touch, height: Metrics.touch)
            }
        }
        .padding(.horizontal, Metrics.Settings.searchInset)
        .frame(minHeight: Metrics.Settings.searchHeight)
        .modifier(HistorySearchGlass(opaque: reduceTransparency))
        .padding(.bottom, Metrics.Settings.searchGap)
    }

    /// Clear…, its own card under the search, red as a thing that can't be
    /// undone; its ranges come out of it.
    private var clearRow: some View {
        @Bindable var history = app.history
        return Button { app.history.asksClear = true } label: {
            Text("Clear History…")
                .font(.body)
                .foregroundStyle(Color(uiColor: .systemRed))
                .padding(.horizontal, Metrics.Settings.rowPadding)
                .frame(maxWidth: .infinity, minHeight: Metrics.Settings.row, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowStyle())
        .background(SettingsInk.group)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius, style: .continuous))
        .accessibilityIdentifier("history.clear")
        .confirmationDialog("Clear History?", isPresented: $history.asksClear, titleVisibility: .visible) {
            ForEach(HistoryRange.allCases) { range in
                Button(range.title, role: .destructive) { clear(range) }
                    .accessibilityIdentifier("history.clear.\(range.rawValue)")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pages go from History on this \(DeviceWord.name). History on your Mac stays as it is.")
        }
    }

    /// A day's name over its rows, as a section of Settings says its title.
    private func dayTitle(_ day: HistoryDay) -> some View {
        Text(day.title)
            .textCase(.uppercase)
            .font(.caption.weight(.semibold))
            .tracking(Metrics.Settings.sectionTracking * Metrics.Settings.sectionFont)
            .foregroundStyle(SettingsInk.section)
            .frame(minHeight: Metrics.Settings.sectionTitle)
            .padding(.horizontal, Metrics.Settings.sectionInset)
            .padding(.top, Metrics.Settings.sectionGap)
            .padding(.bottom, Metrics.Settings.sectionTitleGap)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("history.day.\(Int(day.start.timeIntervalSince1970))")
    }

    private var empty: some View {
        VStack(spacing: M.emptyGap) {
            Glyph(.history, size: M.emptyGlyph, color: SettingsInk.footer)
            Text("No History")
                .font(.headline)
                .foregroundStyle(SettingsInk.text)
            Text("Pages you open on this \(DeviceWord.name) and on your Mac show here.")
                .font(.footnote)
                .foregroundStyle(SettingsInk.footer)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Metrics.Settings.heroSide)
        .padding(.top, M.emptyTop)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.empty")
    }

    // MARK: - what the rows do

    private func open(_ entry: HistoryEntry) {
        if app.history.swipe != nil {
            Motion.rowSwipe.run { app.history.swipe = nil }
            return
        }
        app.openFromHistory(entry)
    }

    private func delete(_ entry: HistoryEntry) {
        Haptics.play(.light, reason: Haptics.Reason.rowAction)
        Motion.rowLeave.run {
            app.history.delete(entry)
            app.history.swipe = nil
        }
    }

    private func clear(_ range: HistoryRange) {
        Haptics.play(.rigid, reason: Haptics.Reason.clear)
        Motion.rowLeave.run {
            app.history.swipe = nil
            app.history.clear(range)
        }
    }
}

/// The row a finger has swiped, and how far (negative: to the left).
struct HistorySwipe: Equatable {
    var id: String
    var x: CGFloat
}

/// One page: its icon, title, host (and the Mac's name), time. Swiped left
/// it becomes a card and Delete stands behind it, as tab rows do.
struct HistoryRow: View {
    let entry: HistoryEntry
    let first: Bool
    let last: Bool
    @Binding var swipe: HistorySwipe?
    let open: () -> Void
    let delete: () -> Void

    @State private var from: CGFloat?
    @ScaledMetric(relativeTo: .body) private var minHeight = Metrics.History.row

    private typealias M = Metrics.History
    private typealias W = Metrics.Swipe

    var body: some View {
        let x = swipe?.id == entry.id ? swipe!.x : 0
        let card = x < -4
        ZStack(alignment: .trailing) {
            if card { deleteCapsule(full: x < -W.act) }
            Button(action: open) { content }
                .buttonStyle(SettingsRowStyle())
                .clipShape(shape)
                .background {
                    if card {
                        RoundedRectangle(cornerRadius: W.tabCardRadius, style: .continuous)
                            .fill(SettingsInk.group)
                            .shadow(color: Ink.shadow.opacity(0.18), radius: 9, y: 6)
                    }
                }
                .overlay(alignment: .top) {
                    if !first && !card {
                        Rectangle().fill(SettingsInk.hairline).frame(height: Metrics.Settings.hairline)
                            .padding(.leading, M.hairlineInset)
                            .accessibilityHidden(true)
                    }
                }
                .offset(x: x)
                .gesture(HistoryRowPan(open: { swipe?.id == entry.id }, changed: move, ended: end))
                .accessibilityIdentifier("history.row.\(entry.id)")
                .accessibilityLabel(label)
                .accessibilityAction(named: "Delete") { delete() }
        }
        // The group's ground, not a clip: a swiped card stands past its corners.
        .background(SettingsInk.group, in: shape)
        .zIndex(card ? 1 : 0)
    }

    /// The row's part of its day's card: round at the day's first and last.
    private var shape: UnevenRoundedRectangle {
        let r = Metrics.Settings.groupRadius
        return UnevenRoundedRectangle(topLeadingRadius: first ? r : 0, bottomLeadingRadius: last ? r : 0,
                                      bottomTrailingRadius: last ? r : 0, topTrailingRadius: first ? r : 0, style: .continuous)
    }

    private var content: some View {
        HStack(spacing: Metrics.Settings.rowGap) {
            Favicon(icon: entry.icon, host: entry.host, size: M.favicon, url: URL(string: entry.url))
            VStack(alignment: .leading, spacing: M.lineGap) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(SettingsInk.text)
                    .lineLimit(1)
                HStack(spacing: M.deviceGap) {
                    Text(entry.host)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let device = entry.device {
                        Text("·")
                        Glyph(.macbook, size: M.deviceGlyph, color: SettingsInk.value)
                        Text(device).lineLimit(1).layoutPriority(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(SettingsInk.value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.visitedAt.formatted(date: .omitted, time: .shortened))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(SettingsInk.value)
                .fixedSize()
        }
        .padding(.horizontal, Metrics.Settings.rowPadding)
        .padding(.vertical, M.rowPadding)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
    }

    private var label: String {
        var words = [entry.name, entry.host]
        if let device = entry.device { words.append("on \(device)") }
        words.append(entry.visitedAt.formatted(date: .omitted, time: .shortened))
        return words.joined(separator: ", ")
    }

    /// Delete behind the card: a red capsule with its word, stretching across
    /// the row past a long swipe's line.
    private func deleteCapsule(full: Bool) -> some View {
        Button(action: delete) {
            HStack(spacing: M.capsuleGap) {
                Glyph(.trashCan, size: Metrics.Menu.icon, color: .white)
                Text("Delete")
                    .font(.system(size: W.tabWord, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: full ? W.fullCapsule : W.tabCapsule.width, height: W.tabCapsule.height)
            .background(Capsule().fill(Color(uiColor: .systemRed)))
        }
        .buttonStyle(.plain)
        .padding(.trailing, M.capsuleInset)
        .animation(Motion.swipeCapsule.animation, value: full)
        .accessibilityIdentifier("history.swipe.delete")
    }

    // MARK: - the swipe

    private func move(_ dx: CGFloat) {
        if from == nil {
            from = swipe?.id == entry.id ? swipe!.x : 0
            // Another row stood open: it closes as this one moves.
            if let open = swipe, open.id != entry.id { Motion.rowSwipe.run { swipe = nil } }
        }
        var x = min(0, (from ?? 0) + dx)
        if -x > W.limit { x = -(W.limit + Rubber.band(-x - W.limit, 30)) }
        let wasFull = swipe?.id == entry.id && -(swipe!.x) > W.act
        let isFull = -x > W.act
        if isFull, !wasFull { Haptics.play(.selection, reason: Haptics.Reason.swipeThreshold) }
        var still = Transaction(animation: nil)
        still.disablesAnimations = true
        withTransaction(still) { swipe = HistorySwipe(id: entry.id, x: x) }
    }

    private func end(_ dx: CGFloat, _ vx: CGFloat) {
        from = nil
        let x = swipe?.id == entry.id ? swipe!.x : 0
        if -x > W.act {
            Motion.rowSwipe.run({ swipe = HistorySwipe(id: entry.id, x: -Metrics.Chats.swipeAway) }, completion: delete)
            return
        }
        let open = -x > Metrics.Chats.swipeOpenDistance || vx < -Metrics.Chats.swipeOpenVelocity
        Motion.rowSwipe.run { swipe = open ? HistorySwipe(id: entry.id, x: -W.tabOpen) : nil }
    }
}

/// A row's pan: to the left from rest, either way once the row stands open,
/// never a rightward start at rest, which is Settings' edge swipe back.
struct HistoryRowPan: UIGestureRecognizerRepresentable {
    var open: () -> Bool
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.open = open
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: changed(dx)
        case .ended, .cancelled, .failed: ended(dx, recognizer.velocity(in: recognizer.view).x)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(open: open) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var open: () -> Bool
        init(open: @escaping () -> Bool) { self.open = open }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            let t = pan.translation(in: pan.view)
            guard abs(v.x) + abs(t.x) > abs(v.y) + abs(t.y) else { return false }
            return v.x < 0 || open()
        }
    }
}

private struct HistorySearchGlass: ViewModifier {
    let opaque: Bool
    func body(content: Content) -> some View {
        if opaque { content.background(SettingsInk.group, in: Capsule()) }
        else { content.glassEffect(.regular, in: Capsule()) }
    }
}

extension Metrics {
    /// History's rows: two lines, the site's icon at 28, the time at the right.
    enum History {
        static let row: CGFloat = 60
        static let rowPadding: CGFloat = 8
        static let favicon: CGFloat = 28
        static let lineGap: CGFloat = 2
        /// The line between rows starts after the icon.
        static let hairlineInset: CGFloat = Metrics.Settings.rowPadding + favicon + Metrics.Settings.rowGap
        static let deviceGap: CGFloat = 4
        static let deviceGlyph: CGFloat = 13
        /// Delete: its glyph and word 6 apart, 8 in from the row's end.
        static let capsuleGap: CGFloat = 6
        static let capsuleInset: CGFloat = 8
        /// Nothing yet: the clock over two lines, 60 under the search.
        static let emptyGlyph: CGFloat = 40
        static let emptyGap: CGFloat = 8
        static let emptyTop: CGFloat = 60
    }
}
