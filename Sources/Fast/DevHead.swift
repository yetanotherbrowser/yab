import SwiftUI

/// The Developer Tools card's head, laid out as Chromium's DevTools row so a
/// hand that knows Chrome finds each thing where it reaches for it: the
/// picker and the device first, then Elements, Console, Sources, Network,
/// Performance, Memory, Application, Security; Audit, Recorder, Graphics
/// and Layers in More; at the right
/// the counts, the chat, Settings, the menu and away.
///
/// As wide as the card and no wider: with less room the tabs go under More
/// from the end, as Chromium's go under »; at the narrowest the chat and
/// Settings go into the menu too, the rule before them with them, so
/// Console still has its place on a card 460 wide. One row,
/// each button measured once (DevRowLayout), where offering SwiftUI every
/// row that might fit built and measured them all on each change.
struct DevHead: View {
    let browser: Browser
    /// Not watched: the head wants only whether it is a device, handed in,
    /// and reads the rest as a menu opens. Watched, it was drawn again for
    /// everything a tab says, a title, a load, a scroll.
    let tab: Tab
    let deviceOn: Bool
    @ObservedObject var consoleCounts: ConsoleLog.Counts
    @ObservedObject private var net = NetPrefs.shared
    let side: DevSide
    let pane: DevPane
    /// The panels extensions added to the inspector, React's Components and
    /// Profiler: tabs after Console, where they have room on a card.
    let panels: [DevPanel]
    /// How many tabs had room when the row was last laid out, and whether
    /// the chat and Settings did (DevRowLayout).
    @State private var fit = DevRowLayout.Fit(tabs: DevTab.header.count, compact: false)
    /// The row's width as it stands on screen: only a layout at it says
    /// what fits, not one SwiftUI tries on the way.
    @State private var width: CGFloat = 0

    /// The row's tabs in order: Chrome's, with the extensions' panels after
    /// Console.
    private var items: [DevItem] {
        let tabs = DevTab.header.map(DevItem.tab)
        return Array(tabs.prefix(2)) + panels.map { DevItem.panel($0.title) } + Array(tabs.dropFirst(2))
    }

    var body: some View {
        let row = items
        let rest = Array(row.dropFirst(fit.tabs)) + DevTab.more.map(DevItem.tab)
        DevRowLayout(fit: $fit, width: width) {
            icon("square.cursor", on: (pane == .elements || pane == .webkit(.elements)) && (browser.devPicking || browser.active?.webPicking == true)) { browser.inspectElement() }
                .keyTip("Pick an Element", shortcut: "Inspect Element")
                .layoutValue(key: DevRowLayout.Role.self, value: .lead)
            icon("devices", on: deviceOn) { browser.toggleDevice() }
                .keyTip("Device Mode")
                .layoutValue(key: DevRowLayout.Role.self, value: .lead)
            rule.layoutValue(key: DevRowLayout.Role.self, value: .lead)
            ForEach(Array(row.enumerated()), id: \.element) { index, item in
                tabButton(item).layoutValue(key: DevRowLayout.Role.self, value: .tab(index))
            }
            moreMenu(rest).layoutValue(key: DevRowLayout.Role.self, value: .more)
            if consoleCounts.errors + consoleCounts.warnings > 0 { counter }
            rule.layoutValue(key: DevRowLayout.Role.self, value: .spare)
            icon("bubble.sparkle", on: false) { browser.askAboutDev() }
                .keyTip("Ask in Chat")
                .layoutValue(key: DevRowLayout.Role.self, value: .spare)
            icon("gearshape", on: pane == .webkit(.settings)) {
                if let chrome = browser.chromiumDevFront?.chromiumDev { chrome.action("settings.show") }
                else { browser.devCommand.settings = .preferences }
            }
                .keyTip("Settings", keys: "F1")
                .layoutValue(key: DevRowLayout.Role.self, value: .spare)
            menu(compact: fit.compact)
            icon("xmark", on: false) { browser.closeDevTools() }
                .keyTip("Hide Developer Tools", shortcut: "Developer Tools")
                .benchSpot("dev close")
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 30 tall, as Chromium's row and Network's toolbar under it: the
        // buttons' 24 and 3 above and below, where 8 made a 40-point head.
        // The ends as far in as the top, so the first and last plates sit
        // in the card's corners as they sit under its edge.
        .padding(3) // design: 24-point buttons in a 30-point row, as Chromium's and Network's toolbar, 3 from every edge
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rule: some View {
        Rectangle().fill(Palette.ink.opacity(0.1)).frame(width: 1, height: 14).padding(.horizontal, 4)
    }

    private func icon(_ name: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Symbol(name, size: 11) }
            .buttonStyle(.yab(on ? .secondary : .quiet, .small, tint: Palette.ink, icon: .square))
            .focusable(false)
    }

    private func tabButton(_ item: DevItem) -> some View {
        // Network warns, as Chromium's tab does, while something holds the
        // network back: throttling, or a rule that blocks or slows.
        let warns = item == .tab(.network) && net.warns
        return Button { browser.pickDevPane(item.pane) } label: {
            HStack(spacing: 4) {
                if warns { Symbol("exclamationmark.triangle", size: 9).foregroundStyle(DevLook.amber) }
                Text(item.title).font(.system(size: 11.5, weight: .medium)).fixedSize()
            }
        }
        .buttonStyle(.yab(isShown(item) ? .secondary : .quiet, .small, tint: Palette.ink))
        .focusable(false)
        .keyTip(warns ? "Network throttling or request conditions are on" : "")
    }

    private func isShown(_ item: DevItem) -> Bool { pane == item.pane }

    /// Chrome's WarningErrorCounter: one button, only while Console holds
    /// an error or a warning, a group only for a count above zero, and a
    /// click opens Console itself.
    private var counter: some View {
        let errors = consoleCounts.errors, warnings = consoleCounts.warnings
        let said = [errors > 0 ? "\(errors) \(errors == 1 ? "error" : "errors")" : nil,
                    warnings > 0 ? "\(warnings) \(warnings == 1 ? "warning" : "warnings")" : nil].compactMap { $0 }.joined(separator: ", ")
        let title = "Open Console to view " + said
        return Button { browser.pickDevPane(.console) } label: {
            HStack(spacing: 4) {
                if errors > 0 { Symbol("xmark.circle.fill", size: 9).foregroundStyle(DevLook.errorMark); Text(errors.formatted()).monospacedDigit() }
                if warnings > 0 { Symbol("exclamationmark.triangle.fill", size: 9).foregroundStyle(DevLook.amber); Text(warnings.formatted()).monospacedDigit() }
            }
            .font(.system(size: 11.5, weight: .medium))
            .fixedSize()
        }
        .buttonStyle(.yab(.quiet, .small, tint: Palette.ink))
        .focusable(false)
        .keyTip(title)
        .accessibilityLabel(title)
        .benchSpot("dev counter")
    }

    /// The tabs there was no room for; the one showing named on the button,
    /// and WebKit's Network when its inspector went there by itself.
    private func moreMenu(_ rest: [DevItem]) -> some View {
        let here = rest.first(where: isShown)?.title ?? (pane == .webkit(.requests) ? WebPane.requests.title : nil)
        return Menu {
            ForEach(rest, id: \.self) { item in
                Button(item.title) { browser.pickDevPane(item.pane) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(here ?? "More").font(.system(size: 11.5, weight: .medium))
                Symbol("chevron.down", size: 8)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.yab(here != nil ? .secondary : .quiet, .small, tint: Palette.ink))
        .fixedSize()
        .focusable(false)
    }

    /// Chrome's ⋮: where the card is, WebKit's search and console drawer,
    /// its Device Settings; at the narrowest the chat and Settings too.
    private func menu(compact: Bool) -> some View {
        Menu {
            dock(.left, "Dock to Left")
            dock(.bottom, "Dock to Bottom")
            dock(.right, "Dock to Right")
            if !browser.devDetached { Button("Open in Separate Window") { browser.detachDevTools() } }
            Divider()
            if compact {
                Button("Ask in Chat") { browser.askAboutDev() }
                Button("Settings") {
                    if let chrome = browser.chromiumDevFront?.chromiumDev { chrome.action("settings.show") }
                    else { browser.devCommand.settings = .preferences }
                }
                Divider()
            }
            Button("Focus Page") { if let tab = browser.active { tab.page.window?.makeFirstResponder(tab.page) } }
            if let chrome = browser.chromiumDevFront?.chromiumDev {
                // Chrome's DevTools have these of their own, and no use for
                // WebKit's More Tools and Device Settings.
                Button("Toggle Console Drawer") { chrome.action("main.toggle-drawer") }
                Button("Search in All Files") { chrome.action("sources.search") }
                Button("Run Command") { chrome.action("quick-open.show-command-menu") }
                Button("Open File") { chrome.action("quick-open.show") }
            } else {
                Button(browser.toolDrawer.open ? "Hide Console Drawer" : "Show Console Drawer") { browser.toggleToolDrawer() }
                Button("Search in All Files") { browser.showTool(.search) }
                Button("Run Command") { browser.openDevCommand(">") }
                Button("Open File") { browser.openDevCommand("") }
                Menu("More Tools") {
                    ForEach(DevTool.allCases) { tool in
                        Button(tool.rawValue) { browser.showTool(tool) }
                    }
                }
                Menu("Device Settings") {
                    ForEach([DevOverride.images, .styles, .scripts], id: \.self) { overrideToggle($0) }
                    Divider()
                    appearance(nil, "Appearance as the Mac’s")
                    appearance("Light", "Light Appearance")
                    appearance("Dark", "Dark Appearance")
                    Divider()
                    ForEach([DevOverride.insecureMedia, .ice, .mockCapture], id: \.self) { overrideToggle($0) }
                }
            }
        } label: {
            Symbol("ellipsis", size: 11)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.yab(.quiet, .small, tint: Palette.ink, icon: .square))
        .fixedSize()
        .focusable(false)
        .keyTip("More Tools")
    }

    /// A side, ticked when the card is there; beside the page only where
    /// the window leaves the page its room.
    private func dock(_ side: DevSide, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { !browser.devDetached && browser.prefs.devSide == side }, set: { if $0 { browser.setDevSide(side) } }))
            .disabled(side.beside && !DevLook.fitsBeside(browser.devRoomWidth))
    }

    private func overrideToggle(_ setting: DevOverride) -> some View {
        Toggle(setting.title, isOn: Binding(get: { tab.devOverrides.contains(setting) }, set: { _ in browser.toggleDevOverride(setting) }))
    }

    private func appearance(_ value: String?, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { tab.devAppearance == value }, set: { if $0 { browser.setDevAppearance(value) } }))
    }
}

/// A tab of the head's row: one of Chrome's, or a panel an extension added.
enum DevItem: Hashable {
    case tab(DevTab)
    case panel(String)

    var pane: DevPane {
        switch self {
        case .tab(let tab): return tab.pane
        case .panel(let title): return .panel(title)
        }
    }

    var title: String {
        switch self {
        case .tab(let tab): return tab.title
        case .panel(let title): return title
        }
    }
}

/// The head's row: what leads, the tabs in order while they have room, More,
/// then from the right edge the counts and buttons, the chat and Settings
/// among them only while the tabs keep three. What has no room is placed
/// off the row, and the row says how many had room (`fit`), for More and
/// the menu to list the rest.
struct DevRowLayout: Layout {
    struct Fit: Equatable {
        var tabs: Int
        var compact: Bool
    }

    enum Place: Equatable {
        case lead, tab(Int), more, right, spare
    }

    struct Role: LayoutValueKey {
        static let defaultValue = Place.right
    }

    @Binding var fit: Fit
    /// The row's width on screen; a layout at any other width is SwiftUI
    /// trying one on, and says nothing.
    let width: CGFloat
    static let spacing: CGFloat = 2
    /// The least air between the tabs and the buttons at the right: their
    /// words stand some 20 apart even so, and with 8 Console missed the row
    /// of the narrowest card by a few points.
    static let gap: CGFloat = 4
    /// Chrome keeps Console in its row before it gives up anything else.
    static let fewest = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let whole = sizes.reduce(0) { $0 + $1.width } + Self.spacing * CGFloat(max(0, sizes.count - 1)) + Self.gap
        return CGSize(width: proposal.width ?? whole, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let roles = subviews.map { $0[Role.self] }
        let all = Array(subviews.indices)
        let lead = all.filter { roles[$0] == .lead }
        let tabs = all.filter { if case .tab = roles[$0] { return true } else { return false } }
        let more = all.filter { roles[$0] == .more }
        let spare = all.filter { roles[$0] == .spare }
        let right = all.filter { roles[$0] == .right || roles[$0] == .spare }
        func width(_ items: [Int]) -> CGFloat {
            items.isEmpty ? 0 : items.reduce(0) { $0 + sizes[$1].width } + Self.spacing * CGFloat(items.count)
        }
        // The widest that fits: all the tabs it can with the chat and
        // Settings, keeping three; else without them, as many as fit.
        var chosen = Fit(tabs: 0, compact: true)
        search: for compact in [false, true] {
            // Less the spacing after each run's last button: it stands in
            // the gap, not between two, and counted it took Console's room.
            let buttons = width(lead) + width(more) + Self.gap + width(compact ? right.filter { !spare.contains($0) } : right) - 2 * Self.spacing
            for count in stride(from: tabs.count, through: compact ? 0 : Self.fewest, by: -1) {
                if buttons + width(Array(tabs.prefix(count))) <= bounds.width {
                    chosen = Fit(tabs: count, compact: compact)
                    break search
                }
            }
        }
        let away = CGPoint(x: bounds.minX - 10_000, y: bounds.midY)
        var x = bounds.minX
        for index in lead + Array(tabs.prefix(chosen.tabs)) + more {
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(sizes[index]))
            x += sizes[index].width + Self.spacing
        }
        for index in tabs.dropFirst(chosen.tabs) {
            subviews[index].place(at: away, anchor: .leading, proposal: ProposedViewSize(sizes[index]))
        }
        var edge = bounds.maxX
        for index in right.reversed() {
            if chosen.compact, spare.contains(index) {
                subviews[index].place(at: away, anchor: .leading, proposal: ProposedViewSize(sizes[index]))
                continue
            }
            subviews[index].place(at: CGPoint(x: edge, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(sizes[index]))
            edge -= sizes[index].width + Self.spacing
        }
        if chosen != fit, abs(bounds.width - self.width) < 1 {
            let binding = $fit
            DispatchQueue.main.async { binding.wrappedValue = chosen }
        }
    }
}
