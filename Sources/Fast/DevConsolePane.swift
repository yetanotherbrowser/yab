import AppKit
import SwiftUI

// Console's panel, as Chromium draws it (DevConsole.swift for what it holds):
// the toolbar (sidebar, clear, copy, the context, live expressions, the filter,
// the levels, the issues, the gear), the settings Chrome has under its gear,
// the sidebar, the live expressions pinned at the top, the messages, and
// right after the last of them the prompt with its completions and what it
// would answer: under the toolbar while nothing was said, at the bottom once
// the messages fill the panel.

struct DevConsolePane: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var log: ConsoleLog
    @ObservedObject var panel: ConsolePanel
    @ObservedObject var prefs = ConsolePrefs.shared
    /// In the drawer under another panel: no sidebar.
    var compact = false

    var body: some View {
        let shown = panel.shown(log)
        VStack(spacing: 0) {
            ConsoleToolbar(browser: browser, tab: tab, log: log, panel: panel, prefs: prefs, compact: compact)
            rule
            if panel.settingsOpen {
                ConsoleSettingsRow(prefs: prefs)
                rule
            }
            HStack(spacing: 0) {
                if prefs.sidebar, !compact {
                    ConsoleSidebar(log: log, panel: panel)
                        .frame(width: 180)
                    Rectangle().fill(Palette.ink.opacity(0.06)).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if !log.live.isEmpty {
                        ConsoleLiveList(browser: browser, log: log)
                        rule
                    }
                    ConsoleMessages(browser: browser, log: log, panel: panel, prefs: prefs, shown: shown)
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onAppear { browser.consoleContexts() }
        .onChange(of: log.contextsChanged) { browser.consoleContexts() }
        .onChange(of: prefs.logXHR) { browser.wire("console.prefs", ["xhr": prefs.logXHR]) }
    }

    private var rule: some View { Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1) }
}

// MARK: - toolbar

struct ConsoleToolbar: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var log: ConsoleLog
    @ObservedObject var panel: ConsolePanel
    @ObservedObject var prefs: ConsolePrefs
    let compact: Bool
    @State private var width: CGFloat = 0
    @ObservedObject private var counts: DevLog.Counts

    init(browser: Browser, tab: Tab, log: ConsoleLog, panel: ConsolePanel, prefs: ConsolePrefs, compact: Bool) {
        self.browser = browser
        self.tab = tab
        self.log = log
        self.panel = panel
        self.prefs = prefs
        self.compact = compact
        counts = tab.devLog.counts
    }

    var body: some View {
        ThreadScrollView(.horizontal, showsIndicators: false) {
            controls
                .frame(minWidth: max(0, width - 12))
                .frame(height: 30)
                .padding(.horizontal, 6)
        }
        .font(.system(size: 11.5))
        .focusable(false)
        .frame(height: 30)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .benchSpot("console toolbar")
    }

    // Keep the controls' natural widths inside the scroller. The row fills
    // a wide panel, and scrolls horizontally when its controls no longer fit.
    private var controls: some View {
        HStack(spacing: 2) {
            if !compact {
                icon("sidebar.left", "Show console sidebar", on: prefs.sidebar) { prefs.sidebar.toggle() }
            }
            icon("nosign", "Clear console", keys: "⌘K") { browser.consoleClear() }
            copyPicker
            divider
            contextMenu
            icon("eye", "Create live expression") {
                log.addLive()
                browser.consoleLive()
            }
            divider
            filterField
            levelsMenu
            Spacer(minLength: 4)
            if counts.errors + counts.warnings > 0 {
                Button { browser.pickDevPane(.errors) } label: {
                    HStack(spacing: 4) {
                        if width > 650 { Text("\(counts.errors + counts.warnings) Issues:").foregroundStyle(Palette.muted) }
                        if counts.errors > 0 { Symbol("xmark.circle.fill", size: 9).foregroundStyle(DevLook.errorMark); Text(counts.errors.formatted()) }
                        if counts.warnings > 0 { Symbol("exclamationmark.triangle.fill", size: 9).foregroundStyle(DevLook.amber); Text(counts.warnings.formatted()) }
                    }
                    .fixedSize()
                }
                .buttonStyle(.yab(.quiet, .small))
                .keyTip("Click to go to the issues tab")
            }
            if panel.hidden > 0, width > 650 {
                Text("\(panel.hidden.formatted()) hidden").foregroundStyle(Palette.muted).fixedSize().padding(.horizontal, 4)
            }
            icon("gearshape", "Console settings", on: panel.settingsOpen) { panel.settingsOpen.toggle() }
                .benchSpot("console settings")
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.ink.opacity(0.1)).frame(width: 1, height: 14).padding(.horizontal, 4)
    }

    private func icon(_ name: String, _ title: String, keys: String? = nil, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Symbol(name, size: 11) }
            .buttonStyle(.yab(on ? .secondary : .quiet, .small))
            .keyTip(title, keys: keys)
    }

    /// Copy: the button copies every shown message, one line each; the
    /// chevron beside it opens the picker, whose card shows what each way
    /// would put on the pasteboard, so a wall of stacks is asked for,
    /// never dragged along as Chromium does with whatever is unfolded.
    private var copyPicker: some View {
        HStack(spacing: 0) {
            icon("doc.on.doc", "Copy console") { browser.consoleCopy(panel.shown(log)) }
            Button { panel.copying = true } label: { Symbol("chevron.down", size: 7) }
                .buttonStyle(.yab(panel.copying ? .secondary : .quiet, .small, icon: .square))
                .keyTip("How to copy the console")
                .popover(isPresented: $panel.copying, arrowEdge: .bottom) {
                    ConsoleCopyPicker(browser: browser, panel: panel, shown: panel.shown(log))
                }
        }
    }

    /// The JavaScript context: top, each frame, each extension's world, each
    /// worker.
    private var contextMenu: some View {
        let current = log.contexts.first(where: \.on) ?? log.contexts.first(where: \.main)
        return Menu {
            ForEach(log.contexts) { context in
                Button { browser.consoleSetContext(context) } label: {
                    if context.on { Label(context.title, systemImage: "checkmark") } else { Text((context.main ? "" : "   ") + context.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current?.title ?? "top").lineLimit(1).truncationMode(.middle).frame(maxWidth: 80)
                Symbol("chevron.down", size: 7)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.yab(.quiet, .small))
        .fixedSize()
        .keyTip("JavaScript context: " + (current?.title ?? "top"))
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Symbol("line.3.horizontal.decrease", size: 10).foregroundStyle(Palette.muted)
            TextField("Filter", text: $panel.filter.text)
                .textFieldStyle(.plain)
                .font(DevMono.font(11.5))
            if panel.filter.isActive {
                Button { panel.filter.text = "" } label: { Symbol("xmark.circle.fill", size: 10).foregroundStyle(Palette.muted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 100, maxWidth: 260)
        .frame(height: ButtonSize.small.height)
        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .keyTip("e.g. /event\\d/ -cdn url:a.com")
        .benchSpot("console filter")
    }

    private var levelsMenu: some View {
        Menu {
            ForEach(ConsoleLevel.allCases, id: \.self) { level in
                Button {
                    if prefs.levels.contains(level) { prefs.levels.remove(level) } else { prefs.levels.insert(level) }
                } label: {
                    if prefs.levels.contains(level) { Label(level.rawValue, systemImage: "checkmark") } else { Text(level.rawValue) }
                }
            }
            Divider()
            Button("Default") { prefs.levels = [.info, .warning, .error] }
        } label: {
            HStack(spacing: 4) {
                Text(width < 650 ? "Levels" : prefs.levelsTitle).fixedSize()
                Symbol("chevron.down", size: 7)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.yab(.quiet, .small))
        .fixedSize()
        .keyTip("Log levels")
    }
}

/// The ways to copy the console, for the list's menu: the same rows as
/// the picker, without its card.
struct ConsoleCopyItems: View {
    let browser: Browser
    let shown: [ConsoleMessage]

    var body: some View {
        ForEach(ConsoleCopyWay.allCases) { way in
            if way == .file { Divider() }
            Button(way.title) { way.run(shown, browser: browser) }
        }
    }
}

/// The picker: the ways down the left, and beside the one under the
/// pointer a card with the piece it would copy, its first lines fading
/// out, and under them the count: messages, lines, size. The objects'
/// JSON is asked from the page as the picker opens, so the details' count
/// is the real one.
struct ConsoleCopyPicker: View {
    let browser: Browser
    @ObservedObject var panel: ConsolePanel
    let shown: [ConsoleMessage]
    @State private var json: [String: String] = [:]

    private var lit: ConsoleCopyWay { panel.copyLit }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ConsoleCopyWay.allCases) { way in
                    if way == .file { Rectangle().fill(Palette.ink.opacity(0.1)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6) }
                    Button { panel.copying = false; way.run(shown, browser: browser) } label: {
                        Text(way.title)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 28)
                            .background(lit == way ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: Radius.small + 1, style: .continuous)) // design: a list row's wash inside the popover's 6
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { panel.copyLit = way } }
                }
            }
            .frame(width: 230)
            ConsoleCopyCard(way: lit, messages: shown.count, piece: piece(lit), path: lit == .file ? browser.consoleFileURL().path : lit == .saveAs ? browser.consoleFileURL().lastPathComponent : nil)
                .frame(width: 300)
        }
        .font(.system(size: 12.5))
        .padding(8)
        .onAppear { browser.consoleObjectsJSON(shown) { json = $0 } }
    }

    private func piece(_ way: ConsoleCopyWay) -> String { way.text(shown, json: json, browser: browser) }
}

/// The card: the way's name, the piece or its blurb and path, the count.
struct ConsoleCopyCard: View {
    let way: ConsoleCopyWay
    let messages: Int
    let piece: String
    let path: String?

    private var lines: Int { piece.isEmpty ? 0 : piece.split(separator: "\n", omittingEmptySubsequences: false).count }
    private var size: String { ByteCountFormatter.string(fromByteCount: Int64(piece.utf8.count), countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(way.title).font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 12).padding(.top, 10)
            if let blurb = way.blurb {
                Text(blurb).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.top, 2)
            }
            if let path {
                Text(path)
                    .font(DevMono.font(11))
                    .foregroundStyle(way == .saveAs ? Palette.muted : Palette.ink)
                    .lineLimit(3).truncationMode(.middle)
                    .padding(.horizontal, 12).padding(.top, 10)
            } else {
                Text(piece.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n"))
                    .font(DevMono.font(11))
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 112, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .padding(.horizontal, 12).padding(.top, 10)
            }
            Text(foot)
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Palette.ink.opacity(0.1)).frame(height: 1) }
                .padding(.top, 10)
        }
        .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)) // design: the card beside the rows, a wash on the popover's own ground
    }

    /// Messages, lines and size; for the file, what the file holds and
    /// how little goes on the pasteboard.
    private var foot: String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? "1 " + one : "\(count.formatted()) " + many }
        if way == .file { return [n(lines, "line", "lines"), size + " in the file", n((path ?? "").count, "char copied", "chars copied")].joined(separator: " · ") }
        return [n(messages, "message", "messages"), n(lines, "line", "lines"), size].joined(separator: " · ")
    }
}

/// The gear's settings, in Chrome's two columns and order.
struct ConsoleSettingsRow: View {
    @ObservedObject var prefs: ConsolePrefs

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                box("Network messages", $prefs.networkMessages, "Show messages from the network: failed loads, CORS")
                box("Log XMLHttpRequests", $prefs.logXHR, "A line for each fetch and XHR that finishes")
                box("Keep log", $prefs.keepLog, "Don’t clear log on page reload / navigation")
                box("Eagerly evaluate text in the prompt", $prefs.eager, "Preview literal expressions as you type. Properties and function calls run when you press Return.")
            }
            VStack(alignment: .leading, spacing: 2) {
                box("Selected context only", $prefs.selectedContextOnly, "Only show messages from the current context (top, iframe, worker, extension)")
                box("Autocomplete from history", $prefs.historyCompletion, "Accept autocomplete suggestion from history")
                box("Group similar messages", $prefs.groupSimilar, "Group repeated messages into one with a count")
                box("Treat evaluation as user activation", $prefs.userActivation, "What runs here may open windows and play sound, as a click would")
                box("CORS errors in console", $prefs.corsErrors, "Show CORS errors in console")
            }
            VStack(alignment: .leading, spacing: 2) {
                box("Timestamps", $prefs.timestamps, "Show when each message was said")
                box("Automatically expand console.trace() messages", $prefs.expandTraces, "Open the stack of a trace as it comes")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(Palette.ink.opacity(0.025))
    }

    private func box(_ title: String, _ value: Binding<Bool>, _ tip: String) -> some View {
        Toggle(isOn: value) { Text(title).font(.system(size: 11.5)).fixedSize() }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .pointerTip(tip)
    }
}

// MARK: - sidebar

struct ConsoleSidebar: View {
    @ObservedObject var log: ConsoleLog
    @ObservedObject var panel: ConsolePanel

    var body: some View {
        let pageMessages = log.messages.filter { $0.kind == .page || $0.kind == .xhr }
        ThreadScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ConsoleGroup.allCases, id: \.self) { group in
                    let held = pageMessages.filter(group.holds)
                    row(group: group, count: held.reduce(0) { $0 + $1.count }, on: panel.group == group && panel.groupSource == nil) {
                        panel.group = group
                        panel.groupSource = nil
                    }
                    if panel.group == group, group != .all {
                        let files = Dictionary(grouping: held, by: ConsolePanel.file).map { ($0.key, $0.value.reduce(0) { $0 + $1.count }) }.sorted { $0.0 < $1.0 }
                        ForEach(files, id: \.0) { file, count in
                            Button { panel.groupSource = file } label: {
                                HStack(spacing: 6) {
                                    Symbol("doc", size: 9).foregroundStyle(Palette.muted)
                                    Text(file).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 2)
                                    Text(count.formatted()).foregroundStyle(Palette.muted)
                                }
                                .padding(.leading, 16)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(panel.groupSource == file ? Palette.ink.opacity(0.07) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .font(.system(size: 11.5))
    }

    private func row(group: ConsoleGroup, count: Int, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                mark(group).frame(width: 12)
                Text("\(count == 0 ? "No" : count.formatted()) \(group.rawValue)").lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(on ? Palette.ink.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func mark(_ group: ConsoleGroup) -> some View {
        switch group {
        case .all: Symbol("list.bullet", size: 10).foregroundStyle(Palette.muted)
        case .user: Symbol("person.circle", size: 10).foregroundStyle(Palette.muted)
        case .errors: Symbol("xmark.circle.fill", size: 10).foregroundStyle(DevLook.errorMark)
        case .warnings: Symbol("exclamationmark.triangle.fill", size: 10).foregroundStyle(DevLook.amber)
        case .info: Symbol("info.circle", size: 10).foregroundStyle(Color.accentColor)
        case .verbose: Symbol("ladybug", size: 10).foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - live expressions

struct ConsoleLiveList: View {
    let browser: Browser
    @ObservedObject var log: ConsoleLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach($log.live) { $live in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        TextField("Expression", text: $live.expression)
                            .textFieldStyle(.plain)
                            .font(DevMono.font(11.5))
                            .onSubmit { browser.consoleLive() }
                        Button { log.dropLive(live.id); browser.consoleLive() } label: { Symbol("xmark", size: 8) }
                            .buttonStyle(.yab(.quiet, .small))
                            .keyTip("Remove expression")
                    }
                    Text(live.value.map { ConsoleFormat.plainValue($0, top: false) } ?? (live.expression.isEmpty ? "" : "not available"))
                        .font(DevMono.font(11.5))
                        .foregroundStyle(ConsoleInk.of(live.value))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .background(Palette.ink.opacity(0.025))
    }
}

// MARK: - messages

/// Selectable AppKit text handles object links itself rather than opening a
/// private URL through LaunchServices. Selection and wrapping stay native.
private struct ConsoleLinkedText: NSViewRepresentable {
    let text: AttributedString
    let maxLines: Int
    let follow: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(follow: follow) }
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        AppleWritingTools.shared.apply(to: view)
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.delegate = context.coordinator
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.follow = follow
        let value = ConsoleCSS.nativeText(text)
        if view.textStorage?.isEqual(to: value) != true { view.textStorage?.setAttributedString(value) }
        view.textContainer?.maximumNumberOfLines = maxLines
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 300)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(14, ceil(layout.usedRect(for: container).height)))
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var follow: (URL) -> Void
        init(follow: @escaping (URL) -> Void) { self.follow = follow }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) { follow(url) }
            return true
        }
    }
}

struct ConsoleMessages: View {
    let browser: Browser
    @ObservedObject var log: ConsoleLog
    @ObservedObject var panel: ConsolePanel
    @ObservedObject var prefs: ConsolePrefs
    let shown: [ConsoleMessage]

    /// The list's own coordinates, where the prompt sees how much of the
    /// panel is above and below it.
    static let space = "console.messages"

    var body: some View {
        GeometryReader { geometry in
        ScrollViewReader { reader in
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { message in
                            ConsoleRow(browser: browser, log: log, message: message, open: log.opened.contains(message.id),
                                       shut: log.shut.contains(message.id), timestamps: prefs.timestamps)
                                .frame(width: max(0, geometry.size.width), alignment: .leading)
                                .id(message.id)
                        }
                    }
                    // Chrome's place for the prompt: right after the last
                    // message, so with nothing said it waits under the
                    // toolbar. Outside the lazy stack, so what is typed and
                    // the keyboard stay however far up the list is read.
                    ConsolePrompt(browser: browser, log: log, panel: panel, prefs: prefs, viewport: geometry.size.height) {
                        reader.scrollTo(-1, anchor: .bottom)
                    }
                    .frame(width: max(0, geometry.size.width), alignment: .leading)
                    .id(-1)
                }
                // The whole panel tall at least, so the completions opening
                // under a prompt at the top are inside what the list draws.
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .coordinateSpace(.named(Self.space))
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
            .background {
                Color.clear.contentShape(Rectangle()).onTapGesture {
                    panel.focusPrompt = true; ConsolePromptView.focusLatest(in: browser.devWindow)
                }
            }
            .onChange(of: log.messages.last?.id) {
                if log.messages.last?.kind == .command || log.messages.last?.kind == .result {
                    reader.scrollTo(-1, anchor: .bottom)
                }
            }
            .contextMenu {
                ConsoleCopyItems(browser: browser, shown: shown)
                Divider()
                Button("Expand all") { log.shut = [] }
                Button("Collapse all") { log.shut = Set(log.messages.filter(\.isGroup).map(\.id)) }
                Divider()
                Button("Clear console") { browser.consoleClear() }
                Button("Clear console history") { ConsolePrefs.shared.history = [] }
            }
        }
        }
        .clipped()
    }
}

/// The colors Chrome gives values in the console.
enum ConsoleInk {
    static let string = tone(0xC41A16, 0xF28B54)
    static let number = tone(0x1C00CF, 0x9980FF)
    static let keyword = tone(0x0D22AA, 0x7AB6FF)
    static let property = tone(0x881391, 0xE36EEC)
    static let tag = tone(0x881280, 0x5DB0D7)
    static let attribute = tone(0x994500, 0x9BBBDC)
    /// Elements: an attribute's value, a CSS property's name, a comment, as Chromium's.
    static let attributeValue = tone(0x1A1AA6, 0xF29766)
    static let cssName = tone(0xC80000, 0x5DB0D7)
    static let comment = tone(0x236E25, 0x747474)
    static let muted = Palette.muted

    static func tone(_ light: UInt32, _ dark: UInt32) -> Color { Color(nsColor: nsTone(light, dark)) }
    static func nsTone(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) }
    }

    /// The same inks for AppKit's drawing (Elements' tree, DevTreeTable).
    enum NS {
        static let tag = nsTone(0x881280, 0x5DB0D7)
        static let attribute = nsTone(0x994500, 0x9BBBDC)
        static let attributeValue = nsTone(0x1A1AA6, 0xF29766)
        static let comment = nsTone(0x236E25, 0x747474)
    }

    static func of(_ value: ConsoleValue?) -> Color {
        guard let value else { return muted }
        switch value.type {
        case "string": return string
        case "number", "bigint": return number
        case "boolean": return keyword
        case "undefined": return muted
        case "symbol": return string
        default: return value.subtype == "null" ? muted : Palette.ink
        }
    }
}

struct ConsoleRow: View, Equatable {
    let browser: Browser
    let log: ConsoleLog
    let message: ConsoleMessage
    let open: Bool
    let shut: Bool
    let timestamps: Bool
    @State private var hovering = false
    /// Values opened under the line, by their place among its values.
    @State private var expanded: Set<Int> = []

    static func == (a: ConsoleRow, b: ConsoleRow) -> Bool {
        a.message == b.message && a.open == b.open && a.shut == b.shut && a.timestamps == b.timestamps
    }

    private var level: String { message.level }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                mark.frame(width: 12).padding(.top, 2)
                if message.isGroup {
                    Button { if shut { log.shut.remove(message.id) } else { log.shut.insert(message.id) } } label: {
                        Symbol("chevron.right", size: 7, weight: .semibold).rotationEffect(.degrees(shut ? 0 : 90)).foregroundStyle(Palette.muted).frame(width: 10, height: 14)
                    }
                    .buttonStyle(.plain)
                } else if hasStack {
                    Button { if open { log.opened.remove(message.id) } else { log.opened.insert(message.id) } } label: {
                        Symbol("chevron.right", size: 7, weight: .semibold).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Palette.muted).frame(width: 10, height: 14)
                    }
                    .buttonStyle(.plain)
                    .keyTip(open ? "Hide the stack" : "Show the stack")
                }
                if message.count > 1 {
                    Text(message.count.formatted())
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16)
                        .background(badge, in: Capsule())
                        .padding(.top, 1)
                }
                if timestamps {
                    Text(Self.time(message.timestamp)).font(DevMono.font(11)).foregroundStyle(Palette.muted)
                }
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.level == "error", message.kind == .page {
                    Button { browser.consoleAsk([message]) } label: { Symbol("bubble.sparkle", size: 10).foregroundStyle(Color.accentColor) }
                        .buttonStyle(.plain)
                        .keyTip("Understand this error: Ask in Chat")
                }
                source
                    .frame(maxWidth: 120, alignment: .trailing)
                    .layoutPriority(1)
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(message.groups.count) * 12)
            .padding(.horizontal, DevLook.padding)
            if open, hasStack { stack }
            ForEach(Array(expanded).sorted(), id: \.self) { index in
                if index < message.values.count {
                    ConsoleTree(browser: browser, value: message.values[index], depth: 0)
                        .padding(.leading, DevLook.padding + 30 + CGFloat(message.groups.count) * 12) // design: under the line's words, past its mark
                        .padding(.bottom, 4)
                }
            }
            if message.type == "table", let first = message.values.first, let preview = first.preview {
                ConsoleTable(browser: browser, preview: preview)
                    .padding(.leading, DevLook.padding + 18 + CGFloat(message.groups.count) * 12) // design: the table stands under the line's words
                    .padding(.trailing, DevLook.padding)
                    .padding(.bottom, 4)
            }
        }
        .background(ground)
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    private var hasStack: Bool {
        !message.stack.isEmpty && (message.level == "error" || message.level == "warning" || message.type == "trace" || message.type == "assert")
    }

    private var badge: Color {
        switch level {
        case "error": return DevLook.errorMark
        case "warning": return DevLook.amber
        default: return Palette.muted
        }
    }

    @ViewBuilder private var mark: some View {
        switch message.kind {
        case .command: Text("›").font(DevMono.font(13, weight: .bold)).foregroundStyle(Color.accentColor).offset(y: -2)
        case .result: Text(message.level == "error" ? "" : "‹").font(DevMono.font(13, weight: .bold)).foregroundStyle(Palette.muted).offset(y: -2)
        case .navigated: Color.clear
        default:
            switch level {
            case "error": Symbol("xmark.circle.fill", size: 10).foregroundStyle(DevLook.errorMark)
            case "warning": Symbol("exclamationmark.triangle.fill", size: 10).foregroundStyle(DevLook.amber)
            case "debug": Color.clear
            default: Color.clear
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .navigated:
            Text("Navigated to " + (message.url.isEmpty ? "a new page" : message.url))
                .font(DevMono.font(11.5))
                .foregroundStyle(Color.accentColor)
        case .command:
            Text(message.text)
                .font(DevMono.font(11.5))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
        default:
            if message.type == "trace", message.values.isEmpty {
                styled([.text(message.text.isEmpty ? "console.trace()" : message.text, css: "")])
            } else if message.kind == .result, message.level == "error" {
                styled([.text(message.text, css: "")])
            } else {
                styled(ConsoleFormat.parts(message))
            }
        }
    }

    /// The parts as one run of words, so a long line wraps as one; each
    /// object's preview is a link that opens it under the line.
    private func styled(_ parts: [ConsoleFormat.Part]) -> some View {
        var text = AttributedString()
        var index = 0
        for part in parts {
            switch part {
            case .text(let words, let css):
                var run = AttributedString(words)
                run.foregroundColor = ink
                ConsoleCSS.apply(css, to: &run)
                text += run
            case .value(let value):
                let at = message.values.firstIndex(of: value) ?? index
                text += ConsoleRow.inline(value, top: message.kind != .result, link: value.isObject || value.type == "function" ? URL(string: "yab-console://value/\(at)") : nil, open: expanded.contains(at))
            }
            index += 1
        }
        return ConsoleLinkedText(text: text, maxLines: open || message.level == "error" ? 0 : 40) { url in
                guard url.scheme == "yab-console", let at = Int(url.lastPathComponent), at < message.values.count else { return }
                let value = message.values[at]
                if value.isNode, NSEvent.modifierFlags.contains(.command) == false, !expanded.contains(at), value.preview == nil {
                    browser.consoleReveal(value)
                    return
                }
                if expanded.contains(at) { expanded.remove(at) } else { expanded.insert(at) }
            }
    }

    private var ink: Color {
        switch level {
        case "error": return DevLook.errorInk
        case "warning": return DevLook.warningInk
        case "debug": return Palette.ink.opacity(0.75)
        default: return Palette.ink
        }
    }

    /// A value written inline as Chromium writes it: strings quoted inside
    /// objects, numbers blue, an object's preview behind ▶.
    static func inline(_ value: ConsoleValue, top: Bool, link: URL?, open: Bool) -> AttributedString {
        var run: AttributedString
        switch value.type {
        case "string":
            run = AttributedString(top ? (value.string ?? "") : "'" + (value.string ?? "") + "'")
            run.foregroundColor = top ? Palette.ink : ConsoleInk.string
        case "function":
            run = AttributedString("ƒ " + ConsoleFormat.functionHead(value))
            run.foregroundColor = Palette.ink
            run.inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.emphasized)
        case "object" where value.isNode:
            run = AttributedString(ConsoleFormat.nodeTag(value.description ?? "node"))
            run.foregroundColor = ConsoleInk.tag
        case "object" where value.isError:
            run = AttributedString(value.description ?? "Error")
            run.foregroundColor = DevLook.errorInk
        case "object" where value.subtype != "null":
            run = AttributedString((open ? "▼ " : "▶ ") + ConsoleFormat.plainValue(value, top: false))
            run.foregroundColor = Palette.ink
        default:
            run = AttributedString(ConsoleFormat.plainValue(value, top: false))
            run.foregroundColor = ConsoleInk.of(value)
        }
        if let link { run.link = link }
        return run
    }

    @ViewBuilder private var source: some View {
        if message.kind == .page, message.source == "network", !message.url.isEmpty {
            Button { browser.consoleShowRequest(message) } label: {
                Text(ConsolePanel.file(message)).font(.system(size: 11.5)).foregroundStyle(Color.accentColor).underline(color: Color.accentColor.opacity(0.35)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .keyTip("Show in Network")
        } else if message.kind == .page, let place = message.place {
            Button { browser.revealSource(place) } label: {
                Text(place.short).font(.system(size: 11.5)).foregroundStyle(Palette.muted).underline(color: Palette.muted.opacity(0.35)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .keyTip("Show in Sources")
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(message.stack.prefix(30).enumerated()), id: \.offset) { _, frame in
                if let async = frame.async {
                    Text("── " + async + " ──").foregroundStyle(Palette.muted)
                } else {
                    HStack(spacing: 6) {
                        Text(frame.function.isEmpty ? "(anonymous)" : frame.function)
                        if let place = frame.place {
                            Button { browser.revealSource(place) } label: {
                                Text("@ " + place.short).foregroundStyle(Palette.muted).underline(color: Palette.muted.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                        } else if !frame.url.isEmpty {
                            Text("@ " + frame.url).foregroundStyle(Palette.muted)
                        }
                    }
                    .opacity(frame.ours || frame.url.contains("node_modules") ? 0.5 : 1)
                }
            }
        }
        .font(DevMono.font(11))
        .foregroundStyle(ink.opacity(0.85))
        .textSelection(.enabled)
        .padding(.leading, DevLook.padding + 30 + CGFloat(message.groups.count) * 12) // design: the stack stands under the row's words
        .padding(.bottom, 4)
    }

    private var ground: Color {
        switch message.kind {
        case .page, .result:
            switch level {
            case "error": return DevLook.errorGround
            case "warning": return DevLook.warningGround
            default: return .clear
            }
        default: return .clear
        }
    }

    private var line: Color {
        switch level {
        case "error": return DevLook.errorLine
        case "warning": return DevLook.warningLine
        default: return Palette.ink.opacity(0.05)
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let date = Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        let format = AppDates.formatter()
        format.dateFormat = "HH:mm:ss.SSS"
        return format.string(from: date)
    }

    @ViewBuilder private var menu: some View {
        Button("Copy as Markdown, with the page") { browser.consoleCopyForAgent([message]) }
        Button("Ask in Chat") { browser.consoleAsk([message]) }
        Divider()
        Button("Copy") { browser.copyForAgent(ConsoleFormat.line(message), "Copied") }
        if hasStack || !message.stack.isEmpty {
            Button("Copy stack trace") { browser.copyForAgent(message.stack.map { ($0.function.isEmpty ? "(anonymous)" : $0.function) + " @ " + ($0.place?.short ?? $0.url) }.joined(separator: "\n"), "Copied stack trace") }
        }
        if let object = message.values.first(where: \.isObject) {
            Button("Store as global variable") { browser.consoleStore(object) }
            Button("Copy object") { browser.consoleCopyObject(object) }
            if object.isNode { Button("Reveal in Elements panel") { browser.consoleReveal(object) } }
        }
        if let function = message.values.first(where: { $0.type == "function" }) {
            Button("Show function definition") { browser.consoleFunction(function) }
        }
        if let string = message.values.first(where: { $0.type == "string" }), message.kind == .result {
            Button("Copy string contents") { browser.copyForAgent(string.string ?? "", "Copied") }
        }
        Divider()
        let file = ConsolePanel.file(message)
        if file != "<other>" {
            Button("Hide messages from \(file)") { browser.consolePanel.hiddenFiles.insert(file) }
        }
        if message.source == "network" {
            Button("Show in Network") { browser.consoleShowRequest(message) }
        }
        Button("Save as…") { browser.consoleSave(browser.toolsFront.map { browser.consolePanel.shown($0.devModel(ConsoleLog.self)) } ?? [message]) }
        Button("Clear console") { browser.consoleClear() }
    }
}

/// %c's CSS on a run of words: color, background, weight, style, size,
/// decoration.
enum ConsoleCSS {
    static func apply(_ css: String, to run: inout AttributedString) {
        guard !css.isEmpty else { return }
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2 else { continue }
            let (name, value) = (parts[0], parts[1])
            switch name {
            case "color": if let color = color(value) { run.foregroundColor = color }
            case "background", "background-color": if let color = color(value) { run.backgroundColor = color }
            case "font-weight": if value == "bold" || (Int(value) ?? 400) >= 600 { run.inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized) }
            case "font-style": if value == "italic" { run.inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.emphasized) }
            case "font-size":
                if let size = Double(value.replacingOccurrences(of: "px", with: "")) {
                    let size = min(48, max(8, size))
                    run.font = DevMono.font(size)
                    run.appKit.font = DevMono.nsFont(size, weight: .regular)
                }
            case "text-decoration":
                if value.contains("underline") { run.underlineStyle = .single }
                if value.contains("line-through") { run.strikethroughStyle = .single }
            default: break
            }
        }
    }

    static func nativeText(_ text: AttributedString) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: NSAttributedString(text))
        var offset = 0
        for run in text.runs {
            let length = String(text[run.range].characters).utf16.count
            let range = NSRange(location: offset, length: length)
            var font = run.appKit.font ?? DevMono.nsFont(11.5, weight: .regular)
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            value.addAttributes([.font: font, .foregroundColor: NSColor(run.foregroundColor ?? Palette.ink)], range: range)
            if let color = run.backgroundColor { value.addAttribute(.backgroundColor, value: NSColor(color), range: range) }
            if run.underlineStyle != nil { value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if run.strikethroughStyle != nil { value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            offset += length
        }
        return value
    }

    /// A CSS color: a name, #rgb, #rrggbb, rgb() or rgba().
    static func color(_ text: String) -> Color? {
        let named: [String: UInt32] = ["red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "orange": 0xFFA500, "purple": 0x800080, "gray": 0x808080,
                                       "grey": 0x808080, "black": 0x000000, "white": 0xFFFFFF, "yellow": 0xFFFF00, "pink": 0xFFC0CB, "teal": 0x008080,
                                       "navy": 0x000080, "brown": 0xA52A2A, "crimson": 0xDC143C, "gold": 0xFFD700, "lime": 0x00FF00, "magenta": 0xFF00FF, "cyan": 0x00FFFF]
        if let hex = named[text] { return rgb(hex) }
        if text.hasPrefix("#") {
            var digits = String(text.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            if let hex = UInt32(digits.prefix(6), radix: 16) { return rgb(hex) }
        }
        if text.hasPrefix("rgb") {
            let numbers = text.replacingOccurrences(of: #"[^0-9.,]"#, with: "", options: .regularExpression).split(separator: ",").compactMap { Double($0) }
            if numbers.count >= 3 {
                return Color(.sRGB, red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, opacity: numbers.count > 3 ? numbers[3] : 1)
            }
        }
        return nil
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - an object, opened

/// A property of an object, as WebKit lists it.
struct ConsoleProp: Identifiable, Equatable {
    var id: String { (isInternal ? "[[" : "") + name }
    var name: String
    var value: ConsoleValue?
    var getter: Bool
    var own: Bool
    var enumerable: Bool
    var isInternal: Bool
    var thrown: Bool
}

struct ConsoleTree: View {
    let browser: Browser
    let value: ConsoleValue
    let depth: Int
    @State private var props: [ConsoleProp]?
    @State private var entries: [(key: ConsoleValue?, value: ConsoleValue)]?
    @State private var open: Set<String> = []
    @State private var resolved: [String: ConsoleValue] = [:]
    @State private var chunk: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let props {
                let listed = Self.order(props, array: value.subtype == "array" || value.subtype == "typedarray")
                if listed.count > 100, value.subtype == "array" || value.subtype == "typedarray" {
                    chunks(listed)
                } else {
                    ForEach(listed) { prop in row(prop) }
                }
                if value.subtype == "map" || value.subtype == "set" || value.subtype == "weakmap" || value.subtype == "weakset" {
                    entriesRow
                }
            } else {
                Text("…").foregroundStyle(Palette.muted)
            }
        }
        .font(DevMono.font(11.5))
        .task(id: value.objectId) { load() }
    }

    private func load() {
        guard props == nil, let id = value.objectId else { return }
        browser.wire("console.props", ["id": id, "tg": value.target]) { raw in
            let list = (raw as? [[String: Any]] ?? []).map { p in
                ConsoleProp(name: p["n"] as? String ?? "", value: (p["v"] as? [String: Any]).map(ConsoleValue.init(json:)),
                            getter: p["g"] as? Bool ?? false, own: p["own"] as? Bool ?? true, enumerable: p["en"] as? Bool ?? true,
                            isInternal: p["i"] as? Bool ?? false, thrown: p["x"] as? Bool ?? false)
            }
            props = list
        }
    }

    /// Chrome's order: indices, then names, then [[internal]] and the
    /// prototype last; what isn't enumerable faded.
    static func order(_ props: [ConsoleProp], array: Bool) -> [ConsoleProp] {
        props.sorted { a, b in
            func rank(_ p: ConsoleProp) -> Int { p.isInternal ? 3 : (p.name == "__proto__" ? 4 : (Int(p.name) != nil ? 0 : (p.enumerable ? 1 : 2))) }
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if ra == 0, let ia = Int(a.name), let ib = Int(b.name) { return ia < ib }
            return array ? false : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder private func chunks(_ listed: [ConsoleProp]) -> some View {
        let indices = listed.filter { Int($0.name) != nil }
        let rest = listed.filter { Int($0.name) == nil }
        ForEach(Array(stride(from: 0, to: indices.count, by: 100)), id: \.self) { start in
            let end = min(start + 100, indices.count)
            VStack(alignment: .leading, spacing: 0) {
                Button { chunk = chunk == start ? nil : start } label: {
                    HStack(spacing: 4) {
                        Symbol("chevron.right", size: 7, weight: .semibold).rotationEffect(.degrees(chunk == start ? 90 : 0)).foregroundStyle(Palette.muted)
                        Text("[\(start) … \(end - 1)]")
                    }
                }
                .buttonStyle(.plain)
                if chunk == start {
                    ForEach(indices[start..<end]) { prop in row(prop) }.padding(.leading, 12)
                }
            }
        }
        ForEach(rest) { prop in row(prop) }
    }

    @ViewBuilder private func row(_ prop: ConsoleProp) -> some View {
        let shownValue = resolved[prop.id] ?? prop.value
        let opens = shownValue?.isObject == true
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                if opens {
                    Button { if open.contains(prop.id) { open.remove(prop.id) } else { open.insert(prop.id) } } label: {
                        Symbol("chevron.right", size: 7, weight: .semibold).rotationEffect(.degrees(open.contains(prop.id) ? 90 : 0)).foregroundStyle(Palette.muted).frame(width: 10, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 10, height: 14)
                }
                Text(prop.isInternal ? "[[\(prop.name)]]" : (prop.name == "__proto__" ? "[[Prototype]]" : prop.name))
                    .foregroundStyle(prop.isInternal || !prop.enumerable || prop.name == "__proto__" ? ConsoleInk.property.opacity(0.6) : ConsoleInk.property)
                Text(":").foregroundStyle(Palette.muted)
                if let shownValue {
                    Text(ConsoleRow.inline(shownValue, top: false, link: nil, open: open.contains(prop.id)))
                        .lineLimit(open.contains(prop.id) ? 1 : 3)
                        .textSelection(.enabled)
                    if shownValue.isNode {
                        Button { browser.consoleReveal(shownValue) } label: { Symbol("arrow.up.forward.square", size: 9) }
                            .buttonStyle(.plain)
                            .keyTip("Reveal in Elements panel")
                            .onHover { browser.consoleHighlight($0 ? shownValue : nil) }
                    }
                    if shownValue.type == "function" {
                        Button { browser.consoleFunction(shownValue) } label: { Symbol("arrow.up.forward.square", size: 9) }
                            .buttonStyle(.plain)
                            .keyTip("Show function definition")
                    }
                } else if prop.getter {
                    Button { invoke(prop) } label: { Text("(...)").foregroundStyle(Palette.muted) }
                        .buttonStyle(.plain)
                        .keyTip("Invoke property getter")
                }
            }
            .contextMenu {
                if let shownValue {
                    Button("Copy value") { browser.consoleCopyObject(shownValue) }
                    if shownValue.isObject { Button("Store as global variable") { browser.consoleStore(shownValue) } }
                }
                Button("Copy property path") { browser.copyForAgent(prop.name, "Copied property path") }
            }
            if open.contains(prop.id), let shownValue, shownValue.isObject {
                ConsoleTree(browser: browser, value: shownValue, depth: depth + 1).padding(.leading, 12)
            }
        }
    }

    private func invoke(_ prop: ConsoleProp) {
        guard let id = value.objectId else { return }
        browser.wire("console.getter", ["id": id, "tg": value.target, "name": prop.name]) { raw in
            guard let raw = raw as? [String: Any], let v = raw["v"] as? [String: Any] else { return }
            resolved[prop.id] = ConsoleValue(json: v)
        }
    }

    @ViewBuilder private var entriesRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if entries == nil, let id = value.objectId {
                    browser.wire("console.entries", ["id": id, "tg": value.target]) { raw in
                        entries = (raw as? [[String: Any]] ?? []).map { e in
                            (key: (e["k"] as? [String: Any]).map(ConsoleValue.init(json:)), value: ConsoleValue(json: e["v"] as? [String: Any] ?? [:]))
                        }
                    }
                } else { entries = nil }
            } label: {
                HStack(spacing: 4) {
                    Symbol("chevron.right", size: 7, weight: .semibold).rotationEffect(.degrees(entries != nil ? 90 : 0)).foregroundStyle(Palette.muted).frame(width: 10, height: 14)
                    Text("[[Entries]]").foregroundStyle(ConsoleInk.property.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            if let entries {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 4) {
                        Text("\(index)").foregroundStyle(ConsoleInk.property)
                        Text(":").foregroundStyle(Palette.muted)
                        if let key = entry.key { Text(ConsoleRow.inline(key, top: false, link: nil, open: false)); Text("=>").foregroundStyle(Palette.muted) }
                        Text(ConsoleRow.inline(entry.value, top: false, link: nil, open: false))
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }
}

/// console.table, from the value's preview: its rows and their columns.
struct ConsoleTable: View {
    let browser: Browser
    let preview: ConsolePreview

    var body: some View {
        let rows = preview.properties.filter { !$0.isInternal }
        let columns = Self.columns(rows)
        ThreadScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    cell("(index)", head: true)
                    ForEach(columns, id: \.self) { cell($0, head: true) }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        cell(row.name, head: false)
                        ForEach(columns, id: \.self) { column in
                            if column == "Value" { cell(Self.text(row), head: false) }
                            else { cell(row.preview.first?.properties.first(where: { $0.name == column }).map(Self.text) ?? "", head: false) }
                        }
                    }
                }
            }
            .font(DevMono.font(11.5))
            .overlay(Rectangle().strokeBorder(Palette.ink.opacity(0.12), lineWidth: 1))
        }
        .contextMenu {
            Button("Copy table as Markdown") { copy(markdown: true, rows: rows, columns: columns) }
            Button("Copy table as CSV") { copy(markdown: false, rows: rows, columns: columns) }
        }
    }

    static func columns(_ rows: [ConsolePreview.Property]) -> [String] {
        var out: [String] = []
        var primitive = false
        for row in rows {
            if let nested = row.preview.first {
                for p in nested.properties where !p.isInternal && !out.contains(p.name) { out.append(p.name) }
            } else { primitive = true }
        }
        if primitive { out.append("Value") }
        return out
    }

    static func text(_ p: ConsolePreview.Property) -> String {
        if p.type == "string" { return "'" + (p.value ?? "") + "'" }
        if let nested = p.preview.first { return nested.description ?? "{…}" }
        return p.value ?? p.type
    }

    private func cell(_ text: String, head: Bool) -> some View {
        Text(text)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 60, maxWidth: 240, alignment: .leading)
            .background(head ? Palette.ink.opacity(0.05) : .clear)
            .overlay(alignment: .trailing) { Rectangle().fill(Palette.ink.opacity(0.08)).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.ink.opacity(0.08)).frame(height: 1) }
    }

    private func copy(markdown: Bool, rows: [ConsolePreview.Property], columns: [String]) {
        let head = ["(index)"] + columns
        let body = rows.map { row in [row.name] + columns.map { column in column == "Value" ? Self.text(row) : (row.preview.first?.properties.first(where: { $0.name == column }).map(Self.text) ?? "") } }
        let text: String
        if markdown {
            text = (["| " + head.joined(separator: " | ") + " |", "|" + head.map { _ in " --- |" }.joined()] + body.map { "| " + $0.joined(separator: " | ") + " |" }).joined(separator: "\n")
        } else {
            text = ([head] + body).map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\n")
        }
        browser.copyForAgent(text, markdown ? "Copied table as Markdown" : "Copied table as CSV")
    }
}
